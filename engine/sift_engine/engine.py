"""The running engine, as two processes so that nothing slows a search down:

  search process  answers the app over a private socket, and embeds passages on the GPU, pausing while you search
  reader process  (low priority) lists files, reads documents and follows changes; it only writes to the indexes

Protocol: one JSON object per line each way.
  {"op": "search", "q": "halvorsen plural", "deep": true}   -> {"docs": [...], "files": [...], "ms": 12.3}
  {"op": "status"}                                      -> {"state": ..., "names": 646466, "documents": 1696, ...}
"""

import json
import logging
import multiprocessing as mp
import os
import socketserver
import threading
import time
from pathlib import Path

from . import config
from .content import Content
from .embed import Embedder
from .names import Names

log = logging.getLogger("sift")

IDLE_BEFORE_EMBEDDING = 15.0   # seconds after the last search before the GPU goes back to indexing
IDLE_BEFORE_UNLOAD = 600.0     # with nothing left to embed, free the model after this long without a search


# ---- reader process ---------------------------------------------------------------------------------------------

def reader_main(state, parent_pid: int):
    _setup_logging()
    os.nice(10)
    config.set_priority("background")
    reader = Reader(state)
    try:
        reader.run(parent_pid)
    except Exception:
        log.exception("reader stopped")


class Reader:
    def __init__(self, state):
        self.names = Names()
        self.content = Content(None, vectors=False)
        self.state = state
        self.changed: set[str] = set()
        self.lock = threading.Lock()

    def set_state(self, text: str):
        self.state.value = text.encode()[:63]

    def run(self, parent_pid: int):
        listed_before = self.names.count() > 0
        self._watch()
        if not listed_before:
            self.set_state("listing files")
            self.names.rebuild(log=log.info)
        self.set_state("reading documents")
        self.content.sync(self._wanted(), log=log.info)
        self.content.mark_copies(log=log.info)
        if listed_before:
            # Search ran on the last run's index meanwhile; now catch what changed while Sift wasn't running.
            self.set_state("checking for changes")
            self._relist()
        last_full = time.time()
        self.set_state("up to date")
        while os.getppid() == parent_pid:
            time.sleep(2)
            self._apply_changes()
            if time.time() - last_full > 6 * 3600:
                self._relist()
                last_full = time.time()

    def _relist(self):
        self.names.rebuild(log=log.info)
        self.content.sync(self._wanted(), log=log.info)
        self.content.mark_copies(log=log.info)

    def _wanted(self) -> dict[str, tuple[float, int]]:
        exts = tuple(config.DOC_EXTS)
        with self.names.lock:
            rows = self.names.db.execute(
                "SELECT path, name, mtime, size FROM entries WHERE is_dir = 0 AND crowded = 0").fetchall()
        return {p: (m, s) for p, name, m, s in rows if name.lower().endswith(exts)}

    def _watch(self):
        from watchdog.events import FileSystemEventHandler
        from watchdog.observers import Observer
        reader = self

        class Handler(FileSystemEventHandler):
            def on_any_event(self, event):
                paths = [event.src_path, getattr(event, "dest_path", "")]
                with reader.lock:
                    reader.changed.update(p for p in paths if isinstance(p, str) and p and not _ignored(Path(p)))

        observer = Observer()
        for root in config.roots():
            try:
                observer.schedule(Handler(), str(root), recursive=True)
            except Exception:
                log.warning("can't watch %s", root)
        observer.daemon = True
        observer.start()

    def _apply_changes(self):
        with self.lock:
            paths, self.changed = self.changed, set()
        for path in paths:
            p = Path(path)
            if os.path.lexists(path):
                self.names.upsert(path)
                if p.suffix.lower() in config.DOC_EXTS and p.is_file():
                    st = p.stat()
                    known = self.content.db.execute("SELECT mtime FROM docs WHERE path = ?", (path,)).fetchone()
                    if not known or known[0] != st.st_mtime:
                        self.content.add(path, st.st_mtime, st.st_size)
                        self.content.mark_copies(log=log.info)
            else:
                self.names.remove(path)
                self.content.remove_path(path)
                for (doc_path,) in self.content.db.execute(
                        "SELECT path FROM docs WHERE path > ? AND path < ?", (path + "/", path + "0")).fetchall():
                    self.content.remove_path(doc_path)


def _ignored(p: Path) -> bool:
    if any(part.startswith(".") for part in p.parts[1:]) or any(part in config.SKIP_NAMES for part in p.parts):
        return True
    if any(p.is_relative_to(s) for s in config.SKIP_PATHS):
        return True
    return any(os.path.splitext(part)[1].lower() in config.PACKAGES for part in p.parts[:-1])


# ---- search process ---------------------------------------------------------------------------------------------

class Engine:
    def __init__(self):
        self.names = Names()
        self.embedder = Embedder()
        self.content = Content(self.embedder)
        self.reader_state = mp.Array("c", 64)
        self.last_search = 0.0

    def start(self):
        ctx = mp.get_context("spawn")
        self.reader = ctx.Process(target=reader_main, args=(self.reader_state, os.getpid()), daemon=True)
        self.reader.start()
        threading.Thread(target=self._embed_loop, daemon=True).start()

    def _wake(self):
        """Vectors and model back in memory (after an idle unload, or at start)."""
        self.content.load_vectors()
        self.embedder.load(log=log.info)

    def _sleep(self):
        self.embedder.unload(log=log.info)
        self.content.release_vectors()

    def _embed_loop(self):
        config.set_priority("background")
        try:
            self._wake()
        except Exception:
            log.exception("model failed to load; searching by words only")
            return
        last_cleanup = time.time()
        while True:
            idle = time.time() - self.last_search
            if idle < IDLE_BEFORE_EMBEDDING:
                time.sleep(0.5)
                continue
            if time.time() - last_cleanup > 600:
                self.content.forget_deleted()
                last_cleanup = time.time()
            if not self.embedder.loaded:
                # Unloaded while idle: come back only when there's new work.
                if self.content.progress()["to_embed"]:
                    self._wake()
                else:
                    time.sleep(5)
                continue
            try:
                done = self.content.embed_some(
                    limit=32, pause=lambda: time.time() - self.last_search < IDLE_BEFORE_EMBEDDING)
            except Exception:
                log.exception("embedding failed")
                done = 0
            if not done:
                if idle > IDLE_BEFORE_UNLOAD:
                    self._sleep()
                time.sleep(3)

    def search(self, q: str, deep: bool) -> dict:
        self.last_search = time.time()
        started = time.time()
        if deep and not self.embedder.loaded:
            # Back from idle: words answer now; meaning joins once the model is in (~2 s), for this search if it can.
            threading.Thread(target=self._wake, daemon=True).start()
            self.embedder.ready.wait(2.5)
        docs = self.content.search(q, deep=deep)
        # A copy of the same file ("paper (1).pdf") shows once.
        seen, unique = set(), []
        for d in docs:
            key = (d["title"] or Path(d["path"]).stem.split(" (")[0].lower(), d["pages"])
            if key in seen:
                continue
            seen.add(key)
            unique.append(d)
        doc_paths = {d["path"] for d in unique}
        files = [f for f in self.names.search(q) if f["path"] not in doc_paths]
        self.last_search = time.time()
        return {"docs": unique[:12], "files": files[:12], "ms": round((time.time() - started) * 1000, 1)}

    def status(self) -> dict:
        reading = self.reader_state.value.decode() or "starting"
        progress = self.content.progress()
        if reading == "up to date" and progress["to_embed"]:
            reading = "embedding"
        return {"state": reading, "names": self.names.count(), "model": self.embedder.ready.is_set(), **progress}


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        config.set_priority("search")
        engine: Engine = self.server.engine
        for line in self.rfile:
            try:
                req = json.loads(line)
                if req.get("op") == "search":
                    reply = engine.search(str(req.get("q", "")), bool(req.get("deep")))
                elif req.get("op") == "status":
                    reply = engine.status()
                else:
                    reply = {"error": "unknown op"}
            except Exception as e:
                log.exception("request failed")
                reply = {"error": str(e)}
            self.wfile.write((json.dumps(reply, ensure_ascii=False) + "\n").encode())
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def _setup_logging():
    config.DATA.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=config.LOG, level=logging.INFO, format="%(asctime)s %(process)d %(message)s")


def main():
    _setup_logging()
    logging.getLogger().addHandler(logging.StreamHandler())
    engine = Engine()
    config.SOCKET.unlink(missing_ok=True)
    old = os.umask(0o077)   # the socket is usable by this user only
    server = Server(str(config.SOCKET), Handler)
    os.umask(old)
    server.engine = engine
    engine.start()
    log.info("listening on %s", config.SOCKET)
    try:
        server.serve_forever()
    finally:
        config.SOCKET.unlink(missing_ok=True)
