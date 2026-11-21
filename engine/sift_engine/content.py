"""The document index: passages in SQLite with a keyword index (FTS5) and a vector each, plus the search over both."""

import math
import re
import sqlite3
import threading
import time
from pathlib import Path

import numpy as np

from . import config, extract
from .embed import DIM, Embedder

SCHEMA = """
CREATE TABLE IF NOT EXISTS docs(
    id INTEGER PRIMARY KEY,
    path TEXT UNIQUE NOT NULL,
    mtime REAL, size INTEGER,
    title TEXT, pages INTEGER,
    embed INTEGER NOT NULL DEFAULT 1,
    state TEXT NOT NULL                 -- ok | unreadable
);
CREATE TABLE IF NOT EXISTS chunks(
    id INTEGER PRIMARY KEY,
    doc INTEGER NOT NULL,
    region TEXT NOT NULL,               -- name | head | body | refs
    page INTEGER,
    ord INTEGER,
    text TEXT,
    first_pass INTEGER NOT NULL DEFAULT 0,
    vec BLOB                            -- 1024 x float16, normalized; NULL until embedded (or never: name, refs)
);
CREATE INDEX IF NOT EXISTS chunks_doc ON chunks(doc);
CREATE INDEX IF NOT EXISTS chunks_todo ON chunks(first_pass, doc) WHERE vec IS NULL;
-- d holds one token naming the passage's document ("x42"), so one document's passages are found directly.
CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(name, head, body, refs, d,
    tokenize='porter unicode61 remove_diacritics 2');
-- The same text, one row per document (rowid = docs.id): which documents have a word, and where, in one lookup.
CREATE VIRTUAL TABLE IF NOT EXISTS docfts USING fts5(name, head, body, refs,
    tokenize='porter unicode61 remove_diacritics 2');
"""

# How much finding a word counts, by where it is. A paper's authors beat the names it cites.
FIELD_WEIGHT = {"name": 1.0, "head": 1.0, "body": 0.5, "refs": 0.12}
COLUMNS = ["name", "head", "body", "refs"]
Z_GATE = 2.5          # a passage counts as a meaning match when it stands this far above the rest
WORD_WEIGHT = 5.0
# Ties go to the documents people mean: a paper's PDF before a text dump of it.
KIND_PRIOR = {".pdf": 0.4, ".docx": 0.35, ".pptx": 0.35, ".xlsx": 0.2, ".doc": 0.3, ".md": 0.2, ".tex": 0.15,
              ".txt": 0.0, ".html": 0.05, ".htm": 0.05}


# Words in nearly every document: they cost the most to look up and say nothing about which document is meant. The
# meaning search still reads them.
STOPWORDS = set("""
a an the and or but if of to in on at by for with from into about as is are was were be been being it its this that
these those there here what which who whom whose when where why how i me my we our you your he she they them their
his her not no yes do does did done can could would should will shall may might must have has had having than then
so such very more most some any all each every both few other also just only own same too s t up down out over under
again further once using use used paper document file one two thing things like
och att det som en ett är på för med av till den de om inte har var jag du vi ni han hon men så kan ska från eller
när där hur vad vem vilken vilket vilka också bara efter under över mellan
""".split())


class Content:
    def __init__(self, embedder: Embedder | None, vectors: bool = True):
        """`vectors=False`: for the reader process, which only writes passages and never searches by meaning."""
        config.DATA.mkdir(parents=True, exist_ok=True)
        self.embedder = embedder
        self._local = threading.local()
        self.db.executescript(SCHEMA)
        self.vec_lock = threading.Lock()
        self.rows = 0
        self.dead_docs: set[int] = set()
        if vectors:
            self._load_vectors()

    @property
    def db(self) -> sqlite3.Connection:
        """One connection per thread."""
        db = getattr(self._local, "db", None)
        if db is None:
            db = sqlite3.connect(config.CONTENT_DB, timeout=30)
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA synchronous=NORMAL")
            self._local.db = db
        return db

    # ---- vectors in memory ------------------------------------------------------------------------------------

    def _load_vectors(self):
        rows = self.db.execute("SELECT id, doc, vec FROM chunks WHERE vec IS NOT NULL ORDER BY id").fetchall()
        n = len(rows)
        cap = max(1024, int(n * 1.3))
        self.matrix = np.zeros((cap, DIM), np.float32)
        self.row_chunk = np.zeros(cap, np.int64)
        self.row_doc = np.zeros(cap, np.int64)
        for i, (cid, doc, vec) in enumerate(rows):
            self.matrix[i] = np.frombuffer(vec, np.float16)
            self.row_chunk[i] = cid
            self.row_doc[i] = doc
        self.rows = n
        self.dead_docs = set()

    def forget_deleted(self):
        """Drops from meaning search the documents another process deleted."""
        live = {d for (d,) in self.db.execute("SELECT id FROM docs")}
        with self.vec_lock:
            present = set(np.unique(self.row_doc[: self.rows]).tolist())
        self.dead_docs = present - live

    def _append_vectors(self, chunk_ids, doc_ids, vecs):
        with self.vec_lock:
            need = self.rows + len(chunk_ids)
            if need > len(self.matrix):
                cap = int(need * 1.5)
                for name in ("matrix", "row_chunk", "row_doc"):
                    old = getattr(self, name)
                    new = np.zeros((cap,) + old.shape[1:], old.dtype)
                    new[: self.rows] = old[: self.rows]
                    setattr(self, name, new)
            self.matrix[self.rows:need] = vecs.astype(np.float32)
            self.row_chunk[self.rows:need] = chunk_ids
            self.row_doc[self.rows:need] = doc_ids
            self.rows = need

    # ---- indexing ---------------------------------------------------------------------------------------------

    def sync(self, wanted: dict[str, tuple[float, int]], log=print, stop=None):
        """Brings the index in line with `wanted` (path -> (mtime, size)): reads new and changed documents, drops
        the ones that are gone. Keyword search covers each document as soon as it's read."""
        have = {p: (m, i) for i, p, m in self.db.execute("SELECT id, path, mtime FROM docs")}
        gone = [have[p][1] for p in have.keys() - wanted.keys()]
        for doc in gone:
            self._delete(doc)
        todo = [p for p, (m, s) in wanted.items() if p not in have or have[p][0] != m]
        # Newest first: what you worked on lately is what you're likely to look for.
        todo.sort(key=lambda p: -wanted[p][0])
        started = time.time()
        for n, path in enumerate(todo, 1):
            if stop and stop.is_set():
                return
            self.add(path, *wanted[path])
            if n % 100 == 0:
                log(f"read {n}/{len(todo)} documents ({time.time() - started:.0f}s)")
        if todo or gone:
            log(f"documents: {len(todo)} read, {len(gone)} removed")

    def add(self, path: str, mtime: float, size: int):
        old = self.db.execute("SELECT id FROM docs WHERE path = ?", (path,)).fetchone()
        if old:
            self._delete(old[0])
        doc = extract.read(Path(path))
        db = self.db
        with db:
            if doc is None:
                db.execute("INSERT INTO docs(path, mtime, size, state, embed) VALUES(?, ?, ?, 'unreadable', 0)",
                           (path, mtime, size))
                return
            cur = db.execute("INSERT INTO docs(path, mtime, size, title, pages, embed, state) VALUES(?,?,?,?,?,?,'ok')",
                             (path, mtime, size, doc.title, doc.pages, int(doc.embed)))
            doc_id = cur.lastrowid
            stem = Path(path).stem
            name_text = stem + (" — " + doc.title if doc.title else "")
            # The name row also gets the file name split at _ - . so "Halvorsen_et_al_2026" matches "halvorsen".
            name_text += " " + re.sub(r"[_\-.]+", " ", stem)
            self._insert(doc_id, "name", None, 0, name_text, first=0)
            regions = {"name": [name_text], "head": [], "body": [], "refs": []}
            for p in doc.passages:
                regions[p.region].append(p.text)
            db.execute("INSERT INTO docfts(rowid, name, head, body, refs) VALUES(?,?,?,?,?)",
                       (doc_id, *(" ".join(regions[c]) for c in COLUMNS)))
            for i, p in enumerate(doc.passages):
                first = int(p.region == "head" or (p.page or 0) <= config.FIRST_PASS_PAGES and p.page is not None
                            or p.page is None and i < config.FIRST_PASS_CHUNKS)
                self._insert(doc_id, p.region, p.page, i, p.text, first)

    def _insert(self, doc, region, page, order, text, first):
        cur = self.db.execute("INSERT INTO chunks(doc, region, page, ord, text, first_pass) VALUES(?,?,?,?,?,?)",
                              (doc, region, page, order, text, first))
        values = [None] * 4
        values[COLUMNS.index(region)] = text
        self.db.execute("INSERT INTO fts(rowid, name, head, body, refs, d) VALUES(?,?,?,?,?,?)",
                        (cur.lastrowid, *values, f"x{doc}"))

    def _delete(self, doc: int):
        with self.db as db:
            db.execute("DELETE FROM fts WHERE rowid IN (SELECT id FROM chunks WHERE doc = ?)", (doc,))
            db.execute("DELETE FROM docfts WHERE rowid = ?", (doc,))
            db.execute("DELETE FROM chunks WHERE doc = ?", (doc,))
            db.execute("DELETE FROM docs WHERE id = ?", (doc,))
        self.dead_docs.add(doc)

    def remove_path(self, path: str):
        row = self.db.execute("SELECT id FROM docs WHERE path = ?", (path,)).fetchone()
        if row:
            self._delete(row[0])

    def embed_some(self, limit=64) -> int:
        """Embeds the next passages: first pages of every document before the rest. Returns how many it did."""
        rows = self.db.execute("""
            SELECT c.id, c.doc, c.text, c.region FROM chunks c JOIN docs d ON d.id = c.doc
            WHERE c.vec IS NULL AND d.embed = 1 AND c.region IN ('head', 'body')
            ORDER BY c.first_pass DESC, CASE WHEN c.first_pass = 1 THEN -d.mtime ELSE d.size END, c.ord
            LIMIT ?""", (limit,)).fetchall()
        if not rows:
            return 0
        vecs = self.embedder.documents([r[2] for r in rows])
        with self.db as db:
            db.executemany("UPDATE chunks SET vec = ? WHERE id = ?",
                           [(v.tobytes(), r[0]) for v, r in zip(vecs, rows)])
        # A document deleted meanwhile keeps no vectors.
        live = {d for (d,) in self.db.execute(
            f"SELECT id FROM docs WHERE id IN ({','.join('?' * len(rows))})", [r[1] for r in rows])}
        keep = [i for i, r in enumerate(rows) if r[1] in live]
        self._append_vectors(np.array([rows[i][0] for i in keep]), np.array([rows[i][1] for i in keep]), vecs[keep])
        return len(rows)

    def progress(self) -> dict:
        docs = self.db.execute("SELECT COUNT(*) FROM docs WHERE state = 'ok'").fetchone()[0]
        todo = self.db.execute("""SELECT COUNT(*), SUM(c.first_pass) FROM chunks c JOIN docs d ON d.id = c.doc
            WHERE c.vec IS NULL AND d.embed = 1 AND c.region IN ('head', 'body')""").fetchone()
        return {"documents": docs, "vectors": self.rows, "to_embed": todo[0] or 0, "first_pass_left": todo[1] or 0}

    # ---- search -----------------------------------------------------------------------------------------------

    def search(self, query: str, deep: bool, limit: int = 15) -> list[dict]:
        every = re.findall(r"\w+", query.lower())
        terms = [t for t in every if t not in STOPWORDS] or every
        if not terms:
            return []
        typing_last = not query.endswith(" ")
        db = self.db
        total = max(db.execute("SELECT COUNT(*) FROM docs").fetchone()[0], 1)

        # Words: where in each document each word is found, weighted by how rare the word is.
        patterns, weights = [], []
        found: dict[int, list[float]] = {}
        for t, term in enumerate(terms):
            pattern = '"' + term + '"'
            if (typing_last and t == len(terms) - 1 and len(term) >= 2) or not self._indexed(term):
                pattern += "*"
            patterns.append(pattern)
            per_doc: dict[int, float] = {}
            for col in COLUMNS:
                for (doc,) in db.execute("SELECT rowid FROM docfts WHERE docfts MATCH ?", (f"{col} : {pattern}",)):
                    per_doc[doc] = max(per_doc.get(doc, 0), FIELD_WEIGHT[col])
            df = len(per_doc)
            weights.append(math.log((total + 1) / (df + 1)) + 0.1)
            for doc, w in per_doc.items():
                found.setdefault(doc, [0.0] * len(terms))[t] = w
        weight_sum = sum(weights)
        strength: dict[int, float] = {}
        if found:
            ranked = [d for (d,) in db.execute(
                "SELECT rowid FROM docfts WHERE docfts MATCH ? ORDER BY bm25(docfts, 4.0, 4.0, 1.0, 0.1) LIMIT 500",
                (" OR ".join(patterns),))]
            strength = {d: 1 - i / len(ranked) for i, d in enumerate(ranked)}
        words = {doc: sum(w * ws[t] for t, w in enumerate(weights)) / weight_sum for doc, ws in found.items()}

        # Meaning: every passage scored, put on this query's scale, best passage per document.
        meaning: dict[int, tuple[float, int]] = {}
        if deep and self.embedder and self.embedder.ready.is_set() and self.rows > 50:
            q = self.embedder.query([query])[0]
            with self.vec_lock:
                n = self.rows
                scores = self.matrix[:n] @ q
                docs = self.row_doc[:n].copy()
                chunks = self.row_chunk[:n].copy()
            alive = ~np.isin(docs, list(self.dead_docs)) if self.dead_docs else np.ones(n, bool)
            mean, std = scores[alive].mean(), max(scores[alive].std(), 0.02)
            z = (scores - mean) / std
            top = np.argsort(-z)[:400]
            for i in top:
                if not alive[i]:
                    continue
                d = int(docs[i])
                if d not in meaning:
                    meaning[d] = (float(z[i]), int(chunks[i]))

        candidates = {d for d, w in words.items() if w >= 0.45} | {d for d, (z, _) in meaning.items() if z >= Z_GATE}
        kinds = {}
        if candidates:
            marks = ",".join("?" * len(candidates))
            kinds = {d: KIND_PRIOR.get(Path(p).suffix.lower(), 0.0) for d, p in
                     db.execute(f"SELECT id, path FROM docs WHERE id IN ({marks})", list(candidates))}
        scored = []
        for d in candidates:
            z = meaning.get(d, (0.0, None))[0]
            w = words.get(d, 0.0)
            scored.append((max(z, 0) + WORD_WEIGHT * w ** 1.5 + strength.get(d, 0.0) + kinds.get(d, 0.0), d))
        scored.sort(reverse=True)

        out = []
        for score, d in scored[:limit]:
            row = db.execute("SELECT path, title, pages FROM docs WHERE id = ?", (d,)).fetchone()
            if not row:
                continue
            path, title, pages = row
            z, meaning_chunk = meaning.get(d, (None, None))
            w = words.get(d, 0.0)
            page, snippet, where = None, None, None
            if w > 0 and (w >= 0.99 or not meaning_chunk or z < Z_GATE):
                hit = db.execute("""SELECT c.page, c.region,
                    snippet(fts, CASE c.region WHEN 'head' THEN 1 WHEN 'body' THEN 2 ELSE 3 END, '«', '»', '…', 24)
                    FROM fts JOIN chunks c ON c.id = fts.rowid WHERE fts MATCH ? AND c.region != 'name'
                    ORDER BY bm25(fts, 1.0, 3.0, 1.0, 0.1, 0.0) LIMIT 1""",
                    (f'd : "x{d}" AND ({" OR ".join(patterns)})',)).fetchone()
                if hit:
                    page, where, snippet = hit
            if snippet is None and meaning_chunk:
                hit = db.execute("SELECT page, region, text FROM chunks WHERE id = ?", (meaning_chunk,)).fetchone()
                if hit:
                    page, where, text = hit
                    snippet = text[:260] + ("…" if len(text) > 260 else "")
            out.append({"path": path, "title": title, "pages": pages, "page": page, "snippet": snippet,
                        "region": where, "score": round(score, 3), "z": None if z is None else round(z, 2),
                        "words": round(w, 3)})
        return out

    def _indexed(self, term: str) -> bool:
        """True when the word occurs as written somewhere (else it's matched as the start of longer words)."""
        try:
            return self.db.execute("SELECT 1 FROM fts WHERE fts MATCH ? LIMIT 1", ('"' + term + '"',)).fetchone() is not None
        except sqlite3.OperationalError:
            return False
