"""Qwen3-Embedding-0.6B on the Mac's GPU. One lock: searches and indexing take turns, and a search always goes next."""

import threading

import numpy as np

from . import config

DIM = 1024


class Embedder:
    def __init__(self):
        self.model = None
        self.ready = threading.Event()
        self._lock = threading.Lock()
        self._waiting_queries = 0
        self._count_lock = threading.Lock()

    def load(self, log=print):
        import torch
        from sentence_transformers import SentenceTransformer
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.model = SentenceTransformer(config.MODEL, device=device,
                                         model_kwargs={"torch_dtype": torch.float16 if device == "mps" else torch.float32})
        self.model.max_seq_length = 512
        self.query(["warm up"])
        self.ready.set()
        log(f"model loaded on {device}")

    def query(self, texts: list[str]) -> np.ndarray:
        with self._count_lock:
            self._waiting_queries += 1
        try:
            with self._lock:
                return self.model.encode(texts, prompt_name="query", normalize_embeddings=True,
                                         convert_to_numpy=True, show_progress_bar=False).astype(np.float32)
        finally:
            with self._count_lock:
                self._waiting_queries -= 1

    def documents(self, texts: list[str], pause=lambda: False) -> np.ndarray:
        """Embeds in steps of 4 passages (~0.4 s), checking `pause` before each: when someone is searching it stops
        early and returns the vectors made so far, the first len(result) of `texts`."""
        out = []
        for i in range(0, len(texts), 4):
            if self._waiting_queries or pause():
                break
            with self._lock:
                out.append(self.model.encode(texts[i:i + 4], batch_size=4, normalize_embeddings=True,
                                             convert_to_numpy=True, show_progress_bar=False).astype(np.float16))
        return np.concatenate(out) if out else np.zeros((0, DIM), np.float16)
