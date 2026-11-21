"""Qwen3-Embedding-0.6B on the Mac's GPU, in a helper process of its own.

The model takes ~2 GB while loaded (PyTorch keeps GPU memory until its process ends), so it lives in a child process
that the engine starts when there's work and stops after a while without any: then the memory goes back to macOS.
Searches and indexing take turns on it, and a waiting search always goes next.
"""

import logging
import multiprocessing as mp
import threading
import time

import numpy as np

from . import config

DIM = 1024
log = logging.getLogger("sift")


def worker_main(conn):
    """The helper process: loads the model, then embeds what it's sent until told to stop (or the engine goes)."""
    logging.basicConfig(filename=config.LOG, level=logging.INFO, format="%(asctime)s %(process)d %(message)s")
    try:
        import torch
        from sentence_transformers import SentenceTransformer
        started = time.time()
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        kwargs = dict(device=device, model_kwargs={"torch_dtype": torch.float16 if device == "mps" else torch.float32})
        try:
            # Once downloaded, the model loads without going online.
            model = SentenceTransformer(config.MODEL, local_files_only=True, **kwargs)
        except Exception:
            log.info("downloading the model (once)")
            model = SentenceTransformer(config.MODEL, **kwargs)
        model.max_seq_length = 512
        model.encode(["warm up"], prompt_name="query", show_progress_bar=False)
        conn.send(("ready", f"{device} in {time.time() - started:.1f}s"))
    except Exception as e:
        conn.send(("error", repr(e)))
        return
    while True:
        try:
            op, texts = conn.recv()
        except (EOFError, OSError):
            return                                   # the engine is gone
        if op == "quit":
            return
        try:
            if op == "query":
                v = model.encode(texts, prompt_name="query", normalize_embeddings=True, convert_to_numpy=True,
                                 show_progress_bar=False).astype(np.float32)
            else:
                v = model.encode(texts, batch_size=len(texts), normalize_embeddings=True, convert_to_numpy=True,
                                 show_progress_bar=False).astype(np.float16)
                if device == "mps":
                    torch.mps.empty_cache()
            conn.send(("ok", v))
        except Exception as e:
            conn.send(("error", repr(e)))


class Embedder:
    def __init__(self):
        self.ready = threading.Event()
        self._conn = None
        self._process = None
        self._lock = threading.Lock()          # one request on the pipe at a time
        self._load_lock = threading.Lock()
        self._waiting_queries = 0
        self._count_lock = threading.Lock()

    @property
    def loaded(self) -> bool:
        return self._process is not None and self._process.is_alive() and self.ready.is_set()

    def load(self, log=log.info):
        with self._load_lock:
            if self.loaded:
                return
            ctx = mp.get_context("spawn")
            parent, child = ctx.Pipe()
            process = ctx.Process(target=worker_main, args=(child,), daemon=True)
            process.start()
            child.close()
            status, detail = parent.recv()
            if status != "ready":
                process.join(1)
                raise RuntimeError(f"model failed to load: {detail}")
            self._conn, self._process = parent, process
            self.ready.set()
            log(f"model loaded on {detail}")

    def unload(self, log=log.info):
        """Stops the helper process; macOS gets its ~2 GB back. `load` starts it again in a few seconds."""
        with self._load_lock, self._lock:
            if self._process is None:
                return
            self.ready.clear()
            try:
                self._conn.send(("quit", None))
            except OSError:
                pass
            self._process.join(5)
            if self._process.is_alive():
                self._process.terminate()
            self._conn.close()
            self._conn = self._process = None
        log("model unloaded while idle")

    def _ask(self, op: str, texts: list[str]) -> np.ndarray:
        if not self.loaded:
            raise RuntimeError("model not loaded")
        try:
            self._conn.send((op, texts))
            status, value = self._conn.recv()
        except (EOFError, OSError) as e:
            self.ready.clear()
            raise RuntimeError("model process ended") from e
        if status != "ok":
            raise RuntimeError(value)
        return value

    def query(self, texts: list[str]) -> np.ndarray:
        with self._count_lock:
            self._waiting_queries += 1
        try:
            with self._lock:
                return self._ask("query", texts)
        finally:
            with self._count_lock:
                self._waiting_queries -= 1

    def documents(self, texts: list[str], pause=lambda: False) -> np.ndarray:
        """Embeds in steps of 4 passages (~0.4 s), checking `pause` before each: when someone is searching it stops
        early and returns the vectors made so far, the first len(result) of `texts`."""
        out = []
        for i in range(0, len(texts), 4):
            if self._waiting_queries or pause() or not self.loaded:
                break
            with self._lock:
                out.append(self._ask("docs", texts[i:i + 4]))
        return np.concatenate(out) if out else np.zeros((0, DIM), np.float16)
