"""Qwen3-Embedding-0.6B (8-bit GGUF) on llama.cpp with Metal, in a helper process of its own.

Measured on this Mac against the PyTorch fp16 model it replaced: the same vectors (cosine 0.9997 mean, 0.9993
worst over 96 passages), ~0.6 GB instead of 2.1-2.8 GB, loads in 0.3 s instead of 1.5-5 s, the same 29 ms per query.
One passage at a time is the fastest way through this model (4.8/s vs 3.9/s in fours) and means a search never
waits behind more than one passage. The CPU is 10x slower than the GPU, so everything runs on the GPU.

The helper process starts when there's work and stops after a while without any; searches and indexing take turns
on it, and a waiting search always goes next.
"""

import logging
import multiprocessing as mp
import threading
import time
from collections import OrderedDict

import numpy as np

from . import config

DIM = 1024
MAX_TOKENS = 512
QUERY_PROMPT = "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"
log = logging.getLogger("cedar")


def model_file() -> str:
    from huggingface_hub import hf_hub_download
    try:
        return hf_hub_download(config.MODEL_REPO, config.MODEL_FILE, local_files_only=True)
    except Exception:
        log.info("downloading the model (once, 640 MB)")
        return hf_hub_download(config.MODEL_REPO, config.MODEL_FILE)


def worker_main(conn):
    """The helper process: loads the model, then embeds what it's sent until told to stop (or the engine goes)."""
    config.DATA.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=config.LOG, level=logging.INFO, format="%(asctime)s %(process)d %(message)s")
    config.set_priority("search")   # a search waits on this process; indexing goes one passage at a time
    try:
        import llama_cpp
        started = time.time()
        model = llama_cpp.Llama(model_path=model_file(), embedding=True, n_gpu_layers=-1, n_ctx=1024, n_batch=1024,
                                n_ubatch=1024, pooling_type=llama_cpp.LLAMA_POOLING_TYPE_LAST, verbose=False)

        def embed(text: str) -> np.ndarray:
            ids = model.tokenize(text.encode("utf-8", "ignore"), add_bos=False, special=False)
            if len(ids) >= MAX_TOKENS:
                text = model.detokenize(ids[:MAX_TOKENS - 1]).decode("utf-8", "ignore")
            return np.asarray(model.embed(text, normalize=True), dtype=np.float32)

        embed("warm up")
        conn.send(("ready", f"llama.cpp in {time.time() - started:.1f}s"))
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
                v = np.stack([embed(QUERY_PROMPT + t) for t in texts])
            else:
                v = np.stack([embed(t) for t in texts]).astype(np.float16)
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
        self._recent: OrderedDict[str, np.ndarray] = OrderedDict()   # query vectors: retyping costs nothing

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
        """Stops the helper process; macOS gets its memory back. `load` starts it again in under a second."""
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
        key = texts[0].strip() if len(texts) == 1 else None
        if key and key in self._recent:
            self._recent.move_to_end(key)
            return self._recent[key][None, :]
        with self._count_lock:
            self._waiting_queries += 1
        try:
            with self._lock:
                v = self._ask("query", texts)
        finally:
            with self._count_lock:
                self._waiting_queries -= 1
        if key:
            self._recent[key] = v[0]
            while len(self._recent) > 256:
                self._recent.popitem(last=False)
        return v

    def documents(self, texts: list[str], pause=lambda: False) -> np.ndarray:
        """Embeds one passage at a time (~0.2 s), checking `pause` before each: when someone is searching it stops
        early and returns the vectors made so far, the first len(result) of `texts`."""
        out = []
        for text in texts:
            if self._waiting_queries or pause() or not self.loaded:
                break
            with self._lock:
                out.append(self._ask("docs", [text]))
        return np.concatenate(out) if out else np.zeros((0, DIM), np.float16)
