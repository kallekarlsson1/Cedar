"""The running engine, as two processes so that nothing slows a search down:

  search process  answers the app over a private socket, and embeds passages on the GPU, pausing while you search
  reader process  (low priority) lists files, reads documents and follows changes; it only writes to the indexes

Protocol: one JSON object per line each way.
  {"op": "search", "q": "halvorsen plural", "deep": true}   -> {"docs": [...], "files": [...], "ms": 12.3}
  {"op": "status"}                                      -> {"state": ..., "names": 646466, "documents": 1696, ...}
"""

import json
import logging
import subprocess
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

log = logging.getLogger("cedar")

IDLE_BEFORE_EMBEDDING = 15.0   # seconds after the last search before the GPU goes back to indexing
IDLE_BEFORE_UNLOAD = 120.0     # with nothing left to embed, free the model after this long without a search
                               # (it's back in 0.3 s, so there's no reason to hold 0.6 GB for longer)


on_battery = config.on_battery


# ---- reader process ---------------------------------------------------------------------------------------------

def reader_main(state, work, parent_pid: int):
    _setup_logging()
    os.nice(10)
    config.set_priority("background")
    reader = Reader(state, work)
    try:
        reader.run(parent_pid)
    except Exception:
        log.exception("reader stopped")


class Reader:
    def __init__(self, state, work):
        self.work = work                       # counts up when there may be new passages to embed
        self.woke = threading.Event()
        self.names = Names()
        self.content = Content(None, vectors=False)
        self.state = state
        self.changed: set[str] = set()
        self.lock = threading.Lock()

    def set_state(self, text: str):
        self.state.value = text.encode()[:63]

    def run(self, parent_pid: int):
        self._watch()
        if self.names.needs_rebuild():
            self.set_state("listing files")
            self.names.rebuild(log=log.info)
        else:
            # Search is already up on the last run's index; find what changed while Cedar wasn't running.
            self.set_state("checking for changes")
            self.names.catch_up(log=log.info)
            for (path,) in self.content.db.execute("SELECT path FROM docs").fetchall():
                self.names.upsert(path)          # a document edited in place: its new time (or its absence)
        self.set_state("reading documents")
        self._sync()
        last_full = time.time()
        self.set_state("up to date")
        while os.getppid() == parent_pid:
            self.woke.wait(60)                   # sleeps until a file changes
            self.woke.clear()
            time.sleep(2)                        # let a burst of changes (a download, a save) finish
            self._apply_changes()
            if self.content.read_scans(log=log.info):      # scans that waited for the charger
                self._more_work()
            if time.time() - last_full > 7 * 24 * 3600:   # a safety net; changes arrive live
                self._relist()
                last_full = time.time()

    def _sync(self):
        self.content.sync(self._wanted(), log=log.info)
        self.content.read_scans(log=log.info)
        self.content.mark_copies(log=log.info)
        self._more_work()

    def _more_work(self):
        with self.work.get_lock():
            self.work.value += 1

    def _relist(self):
        self.names.rebuild(log=log.info)
        self._sync()

    def _wanted(self) -> dict[str, tuple[float, int]]:
        exts = tuple(config.DOC_EXTS)
        with self.names.lock:
            rows = self.names.db.execute(
                "SELECT path, name, mtime, size FROM entries WHERE is_dir = 0 AND crowded = 0").fetchall()
        # Files that are only in iCloud keep their names searchable; their contents aren't read (no downloads).
        return {p: (m, s) for p, name, m, s in rows if name.lower().endswith(exts) and not config.is_dataless(p)}

    def _watch(self):
        from watchdog.events import FileSystemEventHandler
        from watchdog.observers import Observer
        reader = self

        class Handler(FileSystemEventHandler):
            def on_any_event(self, event):
                paths = [event.src_path, getattr(event, "dest_path", "")]
                with reader.lock:
                    reader.changed.update(p for p in paths if isinstance(p, str) and p and not _ignored(Path(p)))
                    if reader.changed:
                        reader.woke.set()

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
                if p.suffix.lower() in config.DOC_EXTS and p.is_file() and not config.is_dataless(path):
                    st = p.stat()
                    known = self.content.db.execute("SELECT mtime FROM docs WHERE path = ?", (path,)).fetchone()
                    if not known or known[0] != st.st_mtime:
                        self.content.add(path, st.st_mtime, st.st_size)
                        self.content.mark_copies(log=log.info, only=path)
                        self._more_work()
            else:
                self.names.remove(path)
                self.content.remove_path(path)
                for (doc_path,) in self.content.db.execute(
                        "SELECT path FROM docs WHERE path > ? AND path < ?", (path + "/", path + "0")).fetchall():
                    self.content.remove_path(doc_path)


def _ignored(p: Path) -> bool:
    if any(part.startswith(".") for part in p.parts[1:]) or any(part in config.SKIP_NAMES for part in p.parts):
        return True
    if p.is_relative_to(config.ICLOUD):
        p = p.relative_to(config.ICLOUD)            # iCloud Drive is inside ~/Library but wanted
    elif any(p.is_relative_to(s) for s in config.SKIP_PATHS):
        return True
    return any(os.path.splitext(part)[1].lower() in config.PACKAGES for part in p.parts[:-1])


# ---- search process ---------------------------------------------------------------------------------------------

class Engine:
    def __init__(self):
        self.names = Names()
        self.embedder = Embedder()
        self.content = Content(self.embedder)
        self.reader_state = mp.get_context("spawn").Array("c", 64)
        self.work = mp.get_context("spawn").Value("i", 0)
        self.last_search = 0.0

    def start(self):
        ctx = mp.get_context("spawn")
        self.reader = ctx.Process(target=reader_main, args=(self.reader_state, self.work, os.getpid()), daemon=True)
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
        checked = None
        while True:
            idle = time.time() - self.last_search
            if idle < IDLE_BEFORE_EMBEDDING:
                time.sleep(0.5)
                continue
            if time.time() - last_cleanup > 600:
                self.content.forget_deleted()
                last_cleanup = time.time()
            battery = on_battery()
            if not self.embedder.loaded:
                # Unloaded while idle: come back only when there's work it's allowed to do now. The database is
                # asked only when the reader reported something new or the charger was (un)plugged.
                seen = (self.work.value, battery)
                if seen == checked:
                    time.sleep(5)
                    continue
                checked = seen
                progress = self.content.progress()
                if progress["first_pass_left"] or (progress["to_embed"] and not battery):
                    self._wake()
                else:
                    time.sleep(5)
                continue
            try:
                done = self.content.embed_some(
                    limit=8, pause=lambda: time.time() - self.last_search < IDLE_BEFORE_EMBEDDING,
                    first_pass_only=battery)
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
            reading = "waiting for the charger" if on_battery() and not progress["first_pass_left"] else "embedding"
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
