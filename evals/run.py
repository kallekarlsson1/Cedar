"""Builds an index of the made-up library and checks that searches find what they should.

    cd engine && CEDAR_APP=~/Applications/Cedar.app/Contents/MacOS/Cedar .venv/bin/python ../evals/run.py [--words-only]

Prints a table per kind of query and exits 1 when a kind falls below its bar. With --words-only the model isn't
loaded and meaning queries are skipped (fast: for the tests). The scan queries need CEDAR_APP (text recognition).
"""

import json
import os
import sys
import tempfile
import time
from pathlib import Path

here = Path(__file__).resolve().parent
if "CEDAR_EVAL_DIR" not in os.environ:      # (the model's helper process imports this file again)
    os.environ["CEDAR_EVAL_DIR"] = tempfile.mkdtemp(prefix="cedar-eval-")
tmp = Path(os.environ["CEDAR_EVAL_DIR"])
os.environ["CEDAR_DATA"] = str(tmp / "index")
os.environ["CEDAR_ROOTS"] = str(tmp / "corpus")
sys.path.insert(0, str(here.parent / "engine"))
sys.path.insert(0, str(here))

import make_corpus  # noqa: E402
from cedar_engine import config  # noqa: E402
from cedar_engine.content import Content  # noqa: E402
from cedar_engine.embed import Embedder  # noqa: E402

# Share of queries whose expected file must come first / in the first three.
BARS = {"author": (0.8, 1.0), "title": (1.0, 1.0), "typing": (1.0, 1.0), "exact": (1.0, 1.0), "words": (1.0, 1.0),
        "scan": (1.0, 1.0), "meaning": (0.8, 0.9), "nothing": (1.0, 1.0)}


def build(words_only: bool) -> Content:
    make_corpus.main(tmp / "corpus")
    embedder = None if words_only else Embedder()
    content = Content(embedder)
    wanted = {str(p): (p.stat().st_mtime, p.stat().st_size) for p in (tmp / "corpus").rglob("*")
              if p.suffix.lower() in config.DOC_EXTS}
    content.sync(wanted, log=lambda m: None)
    content.mark_copies(log=lambda m: None)
    if embedder:
        embedder.load(log=lambda m: None)
        started, n = time.time(), 0
        while (done := content.embed_some(limit=16)):
            n += done
        print(f"embedded {n} passages in {time.time() - started:.0f}s")
    return content


def run(content: Content, words_only: bool) -> bool:
    queries = json.loads((here / "queries.json").read_text())
    scores: dict[str, list] = {}
    for item in queries:
        tag = item["tag"]
        if words_only and tag in ("meaning", "nothing"):
            continue
        if tag == "scan" and not os.environ.get("CEDAR_APP"):
            continue
        hits = [Path(h["path"]).name for h in content.search(item["q"], deep=not words_only)]
        if tag == "nothing":
            meant = [h for h in content.search(item["q"], deep=True) if h["z"] is not None and h["words"] < 0.45]
            first = top3 = not meant
        else:
            first = bool(hits) and hits[0] in item["expect"]
            top3 = any(h in item["expect"] for h in hits[:3])
        scores.setdefault(tag, []).append((first, top3))
        if not first:
            print(f"  miss [{tag}] {item['q']!r}: got {hits[:3]}, wanted {item['expect']}")
    ok = True
    print(f"\n{'kind':10} {'queries':>7} {'first':>6} {'top 3':>6}")
    for tag, rows in scores.items():
        first = sum(r[0] for r in rows) / len(rows)
        top3 = sum(r[1] for r in rows) / len(rows)
        passed = first >= BARS[tag][0] and top3 >= BARS[tag][1]
        ok &= passed
        print(f"{tag:10} {len(rows):7} {first:6.2f} {top3:6.2f}  {'' if passed else '<- below the bar'}")
    return ok


if __name__ == "__main__":
    words_only = "--words-only" in sys.argv
    content = build(words_only)
    passed = run(content, words_only)
    if content.embedder:
        content.embedder.unload(log=lambda m: None)
    sys.exit(0 if passed else 1)
