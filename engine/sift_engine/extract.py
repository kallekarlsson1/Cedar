"""Turns a document into a title and a list of passages.

Every passage belongs to a region:
  head  the top of a document: a paper's title, authors and affiliations (everything before "Abstract")
  body  the text, in overlapping passages of about 200 words, each with its page number
  refs  a paper's reference list. Kept for exact-word search but weighted low, and never embedded, so a paper
        isn't found by the names it cites.
"""

import html
import re
import subprocess
import zipfile
from dataclasses import dataclass
from pathlib import Path

import pymupdf

from . import config

pymupdf.TOOLS.mupdf_display_errors(False)

WORDS = 200
OVERLAP = 40


@dataclass
class Passage:
    region: str          # head | body | refs
    page: int | None     # 1-based PDF page
    text: str


@dataclass
class Document:
    title: str | None
    pages: int | None
    passages: list[Passage]
    embed: bool = True   # False: keyword search only (number tables, text dumps of PDFs)


ABSTRACT = re.compile(r"^\s*(abstract|a b s t r a c t|summary|introduction|1\.?\s+introduction|sammanfattning)\b",
                      re.I | re.M)
REFERENCES = re.compile(r"^\s*(\d+\.?\s*)?(references|bibliography|works cited|literature cited|referenser|"
                        r"literaturverzeichnis|cited literature)\s*$", re.I | re.M)
JUNK_TITLE = re.compile(r"arxiv|untitled|microsoft word|^\s*$|\.(docx?|pdf|tex|dvi)$|^[\d\W_]+$", re.I)


def read(path: Path) -> Document | None:
    ext = path.suffix.lower()
    try:
        if ext == ".pdf":
            return _pdf(path)
        if ext in (".docx", ".pptx", ".xlsx"):
            text = _office(path, ext)
        elif ext in (".doc", ".rtf", ".odt"):
            text = subprocess.run(["/usr/bin/textutil", "-convert", "txt", "-stdout", str(path)],
                                  capture_output=True, timeout=60).stdout.decode("utf-8", "ignore")
        else:
            if path.stat().st_size > config.MAX_TEXT_BYTES:
                return None
            text = path.read_text("utf-8", errors="ignore")
            if ext in (".html", ".htm"):
                text = _strip_html(text)
    except Exception:
        return None
    return _plain(path, text)


def _pdf(path: Path) -> Document | None:
    if path.stat().st_size > config.MAX_PDF_BYTES:
        return None
    doc = pymupdf.open(path)
    if doc.needs_pass:
        return None
    pages = [p.get_text() for p in doc]
    title = _pdf_title(doc)
    doc.close()

    passages: list[Passage] = []
    first = pages[0] if pages else ""
    m = ABSTRACT.search(first)
    head = first[: m.start()] if m and m.start() > 40 else first[:1500]
    if head.strip():
        passages.append(Passage("head", 1, _squash(head)))

    # The reference list starts at the last "References" heading in the second half of the document.
    refs_at: tuple[int, int] | None = None
    for i in range(len(pages) - 1, len(pages) // 2 - 1, -1):
        hits = list(REFERENCES.finditer(pages[i]))
        if hits:
            refs_at = (i, hits[-1].start())
            break

    for i, text in enumerate(pages):
        if refs_at and i > refs_at[0]:
            passages += [Passage("refs", i + 1, t) for t in _windows(text)]
            continue
        if refs_at and i == refs_at[0]:
            body, refs = text[: refs_at[1]], text[refs_at[1]:]
            passages += [Passage("body", i + 1, t) for t in _windows(body)]
            passages += [Passage("refs", i + 1, t) for t in _windows(refs)]
            continue
        passages += [Passage("body", i + 1, t) for t in _windows(text)]
    return Document(title, len(pages), passages, embed=_wordy(passages))


def _pdf_title(doc) -> str | None:
    meta = (doc.metadata or {}).get("title") or ""
    if len(meta) > 8 and not JUNK_TITLE.search(meta):
        return meta.strip()
    # Otherwise the biggest text on page 1, which is the title in nearly every paper.
    try:
        spans = []
        for block in doc[0].get_text("dict")["blocks"]:
            for line in block.get("lines", []):
                for s in line["spans"]:
                    if s["text"].strip():
                        spans.append((round(s["size"], 1), s["bbox"][1], s["text"].strip()))
        if not spans:
            return None
        biggest = max(s[0] for s in spans)
        parts = [t for size, _, t in sorted((s for s in spans if s[0] == biggest), key=lambda s: s[1])]
        title = " ".join(parts)
        if 8 < len(title) < 300 and not JUNK_TITLE.search(title):
            return re.sub(r"\s+", " ", title)
    except Exception:
        pass
    return None


def _plain(path: Path, text: str) -> Document:
    passages: list[Passage] = []
    title = None
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    if lines:
        if path.suffix.lower() in (".md", ".markdown", ".org", ".rst"):
            title = md_title(text)
        # The head keeps a note's metadata block: its author: and aliases: lines are what you'd search for.
        passages.append(Passage("head", None, _squash("\n".join(lines[:12]))[:1500]))
    passages += [Passage("body", None, t) for t in _windows(text)]
    # A text copy of a PDF ("paper.pdf.txt") is found by its words; its PDF carries the meaning.
    embed = not path.name.lower().endswith(".pdf.txt") and _wordy(passages)
    return Document(title, None, passages, embed=embed)


def md_title(text: str) -> str | None:
    """A note's title: `title:` in its metadata block, else its first heading. None: show the file name."""
    body = text
    m = re.match(r"\A---\s*\n(.*?)\n---\s*(\n|\Z)", text, re.S)
    if m:
        t = re.search(r"^title:\s*[\"']?(.+?)[\"']?\s*$", m.group(1), re.M)
        if t and 2 < len(t.group(1)) < 200:
            return t.group(1)
        body = text[m.end():]
    h = re.search(r"^#{1,3}\s+(.+?)\s*#*\s*$", body, re.M)
    if h and 2 < len(h.group(1)) < 200:
        return h.group(1)
    return None


def _office(path: Path, ext: str) -> str:
    """Text from Word, PowerPoint and Excel files (they're zips of XML)."""
    out = []
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if ext == ".docx":
            parts = [n for n in names if re.match(r"word/(document|footnotes|endnotes)\.xml$", n)]
            tag = r"<w:t[^>]*>([^<]*)</w:t>|</w:p>"
        elif ext == ".pptx":
            parts = sorted((n for n in names if re.match(r"ppt/(slides|notesSlides)/\w+\d+\.xml$", n)),
                           key=lambda n: int(re.findall(r"\d+", n)[-1]))
            tag = r"<a:t>([^<]*)</a:t>|</a:p>"
        else:
            parts = [n for n in names if n == "xl/sharedStrings.xml" or n.startswith("xl/worksheets/sheet")]
            tag = r"<t[^>]*>([^<]*)</t>|<v>([^<]*)</v>"
        for part in parts:
            xml = z.read(part).decode("utf-8", "ignore")
            for m in re.finditer(tag, xml):
                piece = next((g for g in m.groups() if g is not None), None)
                out.append(html.unescape(piece) if piece is not None else "\n")
            out.append("\n")
    return " ".join(out)


def _strip_html(text: str) -> str:
    text = re.sub(r"(?is)<(script|style|head)[^>]*>.*?</\1>", " ", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    return html.unescape(text)


def _windows(text: str) -> list[str]:
    words = text.split()
    if not words:
        return []
    out = []
    step = WORDS - OVERLAP
    for start in range(0, max(len(words) - OVERLAP, 1), step):
        out.append(" ".join(words[start:start + WORDS]))
    return out


def _squash(text: str) -> str:
    return re.sub(r"[ \t]+", " ", re.sub(r"\n\s*\n+", "\n", text)).strip()


def _wordy(passages: list[Passage]) -> bool:
    """Mostly letters, not a table of numbers."""
    sample = " ".join(p.text for p in passages[:20])
    if not sample:
        return False
    letters = sum(c.isalpha() for c in sample)
    return letters / max(len(sample.replace(" ", "")), 1) > 0.55
