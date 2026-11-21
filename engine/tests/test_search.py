"""Fast checks on the made-up library (no model): `cd engine && uv run --with pytest pytest -q`."""

import os
import sys
import tempfile
from pathlib import Path

import pytest

tmp = Path(tempfile.mkdtemp(prefix="cedar-test-"))
os.environ["CEDAR_DATA"] = str(tmp / "index")
os.environ["CEDAR_ROOTS"] = str(tmp / "corpus")
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "evals"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import make_corpus  # noqa: E402
from cedar_engine import config, extract  # noqa: E402
from cedar_engine.content import Content  # noqa: E402
from cedar_engine.names import Names  # noqa: E402


@pytest.fixture(scope="session")
def content():
    make_corpus.main(tmp / "corpus")
    c = Content(None, vectors=False)
    wanted = {str(p): (p.stat().st_mtime, p.stat().st_size) for p in (tmp / "corpus").rglob("*")
              if p.suffix.lower() in config.DOC_EXTS}
    c.sync(wanted, log=lambda m: None)
    c.mark_copies(log=lambda m: None)
    return c


def first(content, q):
    hits = content.search(q, deep=False)
    return Path(hits[0]["path"]).name if hits else None


def test_regions(content):
    doc = extract.read(tmp / "corpus" / "papers" / "halvorsen_plural.pdf")
    regions = {p.region for p in doc.passages}
    assert regions == {"head", "body", "refs"}
    head = next(p.text for p in doc.passages if p.region == "head")
    assert "Mira Halvorsen" in head and "Abstract" not in head
    assert doc.title == "Human Reasoning under Plural Assistant Support"
    assert all("Journal of Sleep Research" not in p.text for p in doc.passages if p.region == "body")


def test_author_beats_citation(content):
    # Every paper cites Halvorsen; only two are by Halvorsen.
    hits = [Path(h["path"]).name for h in content.search("halvorsen", deep=False)][:3]
    assert hits[0] in ("halvorsen_plural.pdf", "bee_navigation.pdf")
    assert first(content, "brennan") == "sleep_memory.pdf"


def test_title_when_file_name_says_nothing(content):
    assert first(content, "quiet saboteurs") == "3706598.pdf"


def test_half_typed_word(content):
    assert first(content, "sourdo") == "sourdough.pdf"


def test_exact_code(content):
    assert first(content, "INV-20417") == "Meeting notes 12 March.md"


def test_note_title_from_metadata(content):
    assert first(content, "reading list for the seminar") == "Reading list.md"


def test_text_copy_ranks_below_its_pdf(content):
    hits = [Path(h["path"]).name for h in content.search("plural llm", deep=False)]
    assert hits.index("halvorsen_plural.pdf") < hits.index("halvorsen_plural.txt")
    assert content.db.execute("SELECT embed FROM docs WHERE path LIKE '%halvorsen_plural.txt'").fetchone()[0] == 0


def test_names_and_catch_up():
    names = Names()
    names.rebuild(log=lambda m: None)
    assert names.search("sourdough")[0]["name"] == "sourdough.pdf"
    new = tmp / "corpus" / "notes" / "zebrafinch.md"
    new.write_text("x")
    (tmp / "corpus" / "notes" / "Reading list.md").rename(tmp / "corpus" / "notes" / "Seminar reading.md")
    names.catch_up(log=lambda m: None)
    assert names.search("zebrafinch") and names.search("seminar reading")
    assert not names.search("reading list")
    (tmp / "corpus" / "notes" / "Seminar reading.md").rename(tmp / "corpus" / "notes" / "Reading list.md")
    new.unlink()
