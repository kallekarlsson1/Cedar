"""Every file and folder name under the roots, searchable by any part of the name in a few milliseconds."""

import os
import re
import sqlite3
import threading
import time
from pathlib import Path

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS entries(
    id INTEGER PRIMARY KEY,
    path TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL COLLATE NOCASE,
    is_dir INTEGER NOT NULL,
    mtime REAL,
    size INTEGER,
    depth INTEGER,
    crowded INTEGER NOT NULL DEFAULT 0   -- in a folder with more than config.CROWDED entries (a dataset)
);
CREATE INDEX IF NOT EXISTS entries_name ON entries(name);
CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(name, tokenize='trigram remove_diacritics 1');
"""


def connect() -> sqlite3.Connection:
    config.DATA.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(config.NAMES_DB, check_same_thread=False, timeout=30)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript(SCHEMA)
    return db


def walk(root: Path):
    """Yields (path, name, is_dir, mtime, size, depth, crowded) for everything under root worth listing."""
    stack = [(root, 0)]
    while stack:
        folder, depth = stack.pop()
        try:
            with os.scandir(folder) as it:
                entries = [e for e in it if not e.name.startswith(".")]
        except OSError:
            continue
        crowded = len(entries) > config.CROWDED
        for e in entries:
            if e.name in config.SKIP_NAMES:
                continue
            try:
                is_dir = e.is_dir(follow_symlinks=False)
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            path = Path(e.path)
            if path in config.SKIP_PATHS:
                continue
            yield e.path, e.name, int(is_dir), st.st_mtime, st.st_size, depth + 1, int(crowded)
            if is_dir and not config.skip_dir(path, e.name):
                stack.append((path, depth + 1))


class Names:
    def __init__(self):
        self.db = connect()
        self.lock = threading.Lock()

    def count(self) -> int:
        with self.lock:
            return self.db.execute("SELECT COUNT(*) FROM entries").fetchone()[0]

    def rebuild(self, log=print):
        """Lists everything again into fresh tables, then swaps them in; searches keep working meanwhile."""
        started = time.time()
        db = sqlite3.connect(config.NAMES_DB, timeout=30)
        db.executescript("""
            DROP TABLE IF EXISTS entries_new; DROP TABLE IF EXISTS names_new;
            CREATE TABLE entries_new(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, name TEXT NOT NULL COLLATE NOCASE,
                is_dir INTEGER NOT NULL, mtime REAL, size INTEGER, depth INTEGER, crowded INTEGER NOT NULL DEFAULT 0);
        """)
        batch = []
        for root in config.roots():
            for row in walk(root):
                batch.append(row)
                if len(batch) >= 20000:
                    db.executemany("INSERT OR IGNORE INTO entries_new(path,name,is_dir,mtime,size,depth,crowded) "
                                   "VALUES(?,?,?,?,?,?,?)", batch)
                    batch.clear()
        db.executemany("INSERT OR IGNORE INTO entries_new(path,name,is_dir,mtime,size,depth,crowded) "
                       "VALUES(?,?,?,?,?,?,?)", batch)
        db.executescript("""
            CREATE VIRTUAL TABLE names_new USING fts5(name, tokenize='trigram remove_diacritics 1');
            INSERT INTO names_new(rowid, name) SELECT id, name FROM entries_new WHERE crowded = 0;
        """)
        db.commit()
        with self.lock:
            db.executescript("""
                BEGIN;
                DROP TABLE IF EXISTS entries; DROP TABLE IF EXISTS names;
                ALTER TABLE entries_new RENAME TO entries; ALTER TABLE names_new RENAME TO names;
                CREATE INDEX IF NOT EXISTS entries_name ON entries(name);
                COMMIT;
            """)
            db.execute("PRAGMA user_version = 2")
        db.commit()
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db.execute("VACUUM")          # the old tables' pages go back to the disk
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db.close()
        log(f"names: {self.count()} entries in {time.time() - started:.0f}s")

    def needs_rebuild(self) -> bool:
        with self.lock:
            return self.db.execute("PRAGMA user_version").fetchone()[0] < 2 or \
                self.db.execute("SELECT COUNT(*) FROM entries").fetchone()[0] == 0

    def catch_up(self, log=print) -> int:
        """Finds what changed while Sift wasn't running, without listing everything: a folder's modification time
        changes when something in it is added, removed or renamed, so only folders whose time moved are read
        again (hundreds of stat calls instead of 650,000 files)."""
        started = time.time()
        with self.lock:
            dirs = self.db.execute("SELECT path, mtime FROM entries WHERE is_dir = 1").fetchall()
        changed = [str(r) for r in config.roots()]
        for path, mtime in dirs:
            p = Path(path)
            if config.skip_dir(p, p.name):
                continue
            try:
                now = os.stat(path, follow_symlinks=False).st_mtime
            except OSError:
                self.remove(path)
                continue
            if now != mtime:
                changed.append(path)
        touched = 0
        for folder in changed:
            touched += self._reread(folder)
        log(f"names: caught up in {time.time() - started:.1f}s ({len(changed)} folders read, {touched} changes)")
        return touched

    def _reread(self, folder: str) -> int:
        """Brings one folder's direct children in line with the disk. Returns how many entries changed."""
        try:
            with os.scandir(folder) as it:
                listed = {e.path: e for e in it if not e.name.startswith(".") and e.name not in config.SKIP_NAMES
                          and Path(e.path) not in config.SKIP_PATHS}
        except OSError:
            return 0
        crowded = int(len(listed) > config.CROWDED)
        with self.lock:
            known = {r[0]: r[1] for r in self.db.execute(
                "SELECT path, crowded FROM entries WHERE path > ? AND path < ? AND instr(substr(path, ?), '/') = 0",
                (folder + "/", folder + "0", len(folder) + 2))}
        changes = 0
        for path in known.keys() - listed.keys():
            self.remove(path)
            changes += 1
        new_dirs = []
        with self.lock:
            for path in listed.keys() - known.keys():
                e = listed[path]
                try:
                    is_dir = e.is_dir(follow_symlinks=False)
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                self._insert(path, e.name, int(is_dir), st.st_mtime, st.st_size, path.count("/"), crowded)
                changes += 1
                if is_dir and not config.skip_dir(Path(path), e.name):
                    new_dirs.append(path)
            if known and next(iter(known.values())) != crowded:      # the folder crossed the dataset line
                ids = [r[0] for r in self.db.execute(
                    "SELECT id FROM entries WHERE path > ? AND path < ? AND instr(substr(path, ?), '/') = 0",
                    (folder + "/", folder + "0", len(folder) + 2))]
                for i in ids:
                    self.db.execute("UPDATE entries SET crowded = ? WHERE id = ?", (crowded, i))
                    self.db.execute("DELETE FROM names WHERE rowid = ?", (i,))
                    if not crowded:
                        self.db.execute("INSERT INTO names(rowid, name) SELECT id, name FROM entries WHERE id = ?", (i,))
            try:
                self.db.execute("UPDATE entries SET mtime = ? WHERE path = ?", (os.stat(folder).st_mtime, folder))
            except OSError:
                pass
            self.db.commit()
        for d in new_dirs:                   # a new folder: everything in it is new
            with self.lock:
                for row in walk(Path(d)):
                    self._insert(*row[:5], row[0].count("/"), row[6])
                    changes += 1
                self.db.commit()
        return changes

    def _insert(self, path, name, is_dir, mtime, size, depth, crowded):
        cur = self.db.execute(
            "INSERT OR IGNORE INTO entries(path,name,is_dir,mtime,size,depth,crowded) VALUES(?,?,?,?,?,?,?)",
            (path, name, is_dir, mtime, size, depth, crowded))
        if cur.rowcount and not crowded:
            self.db.execute("INSERT INTO names(rowid, name) VALUES(?, ?)", (cur.lastrowid, name))

    # Live updates from the file watcher.
    def upsert(self, path: str):
        p = Path(path)
        try:
            st = os.stat(path, follow_symlinks=False)
        except OSError:
            return self.remove(path)
        is_dir = int(p.is_dir() and not p.is_symlink())
        depth = len(p.parts) - len(config.HOME.parts) if p.is_relative_to(config.HOME) else len(p.parts)
        parent = str(p.parent)
        with self.lock:
            known = self.db.execute("SELECT id FROM entries WHERE path = ?", (path,)).fetchone()
            if known:
                self.db.execute("UPDATE entries SET mtime = ?, size = ? WHERE id = ?", (st.st_mtime, st.st_size, known[0]))
            else:
                sibling = self.db.execute("SELECT crowded FROM entries WHERE path > ? AND path < ? LIMIT 1",
                                          (parent + "/", parent + "0")).fetchone()
                self._insert(path, p.name, is_dir, st.st_mtime, st.st_size, depth, sibling[0] if sibling else 0)
            self.db.commit()

    def remove(self, path: str):
        with self.lock:
            # The path itself and, if it was a folder, everything under it.
            ids = [r[0] for r in self.db.execute(
                "SELECT id FROM entries WHERE path = ? OR (path > ? AND path < ?)", (path, path + "/", path + "0"))]
            for i in range(0, len(ids), 500):
                chunk = ids[i:i + 500]
                marks = ",".join("?" * len(chunk))
                self.db.execute(f"DELETE FROM entries WHERE id IN ({marks})", chunk)
                self.db.execute(f"DELETE FROM names WHERE rowid IN ({marks})", chunk)
            self.db.commit()

    def search(self, query: str, limit: int = 30) -> list[dict]:
        words = [w for w in re.split(r"\s+", query.strip().lower()) if w]
        if not words:
            return []
        long = [w for w in words if len(w) >= 3]
        with self.lock:
            if long:
                match = " AND ".join('"' + w.replace('"', '""') + '"' for w in long)
                rows = self.db.execute(
                    "SELECT e.path, e.name, e.is_dir, e.mtime, e.depth, e.crowded FROM names "
                    "JOIN entries e ON e.id = names.rowid WHERE names MATCH ? LIMIT 3000", (match,)).fetchall()
                # Files in dataset folders (99% of all names here) aren't in the trigram index: they're found by
                # how their name starts, through the ordinary index.
                w = words[0].replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                rows += self.db.execute(
                    "SELECT path, name, is_dir, mtime, depth, crowded FROM entries WHERE name LIKE ? ESCAPE '\\' "
                    "AND crowded = 1 LIMIT 40", (w + "%",)).fetchall()
            else:
                # One or two letters: names that start with them.
                w = words[0].replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                rows = self.db.execute(
                    "SELECT path, name, is_dir, mtime, depth, crowded FROM entries WHERE name LIKE ? ESCAPE '\\' "
                    "AND crowded = 0 ORDER BY depth LIMIT 3000", (w + "%",)).fetchall()
        now = time.time()
        q = " ".join(words)
        out = []
        for path, name, is_dir, mtime, depth, crowded in rows:
            low = name.lower()
            if not all(w in low for w in words):
                continue
            if low.endswith(".app"):
                continue                      # apps come from the app's own list, with icons
            stem = os.path.splitext(low)[0] if not is_dir else low
            if stem == q or low == q:
                score = 100
            elif low.startswith(q):
                score = 80
            elif all(re.search(r"(^|[\s_\-.()\[\]])" + re.escape(w), low) for w in words):
                score = 62
            else:
                score = 40
            ext = os.path.splitext(low)[1]
            if is_dir:
                score += 6
            elif ext in config.DOC_EXTS:
                score += 8
            if crowded:
                score -= 30
            score -= 1.5 * max((depth or 1) - 2, 0)
            age_days = (now - (mtime or 0)) / 86400
            score += 6 if age_days < 7 else 3 if age_days < 60 else 0
            out.append({"path": path, "name": name, "dir": bool(is_dir), "score": round(score, 2),
                        "modified": mtime})
        out.sort(key=lambda r: -r["score"])
        return out[:limit]
