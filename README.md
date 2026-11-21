# Sift

A Spotlight replacement for macOS that finds documents by what's in them: by exact words and by meaning.

Press ⌘Space and type what you remember. Sift answers on every keystroke:

- **Apps**: `saf` → Safari, `vsc` → Visual Studio Code. Things you open often rank higher.
- **Math**: `24*1.25`, `(3+4)^2`, `15% of 80`, `sqrt(2)`. A decimal comma works too.
- **Currencies**: `100 usd`, `$100 to eur`, `500 kr`. Uses the European Central Bank's daily rates.
- **Units**: `5 km in miles`, `20 c to f`, `180 cm in feet`, `3 dl`.
- **Files and folders**: any part of the name, across your home folder, Applications and plugged-in drives.
- **Document contents**: PDFs, Word, PowerPoint, Excel, Markdown, text, HTML and LaTeX. Each result shows the page
  and the passage that matched.

## Why

Spotlight treats every word in a PDF the same. A paper by Halvorsen gets buried under all the papers that only *cite*
Halvorsen, and the PDF's own author field often says `arXiv GenPDF`. Sift reads a paper's title and author block
separately from its body and its reference list, and ranks them in that order. It also searches by meaning:
"the paper about people using several chatbots for math and writing" finds the paper without those exact words.

## How it works

```
Sift.app (Swift, AppKit)          the panel: apps, math, conversions in-process; asks the engine for the rest
   │ unix socket (yours only)
engine, search process (Python)   keyword + meaning search; ~80 MB
engine, reader process            lists files, reads documents, follows changes (FSEvents), at low priority
engine, model process             Qwen3-Embedding (8-bit) on llama.cpp + Metal, ~450 MB; embeds passages while
                                  you're not searching, quits after 2 idle minutes, back in 0.4 s
   │
~/Library/Application Support/Sift/
   names.db     every file and folder name; trigram index for all but dataset folders' files, which are
                found by the start of their name. After the first listing, a start reads only changed folders
   content.db   passages with page numbers, FTS5 keyword index, Qwen3-Embedding-0.6B vectors
```

- **Reading.** Each document is split into a title/author block (`head`), overlapping ~200-word passages
  (`body`, with page numbers) and its reference list (`refs`).
- **Words.** SQLite FTS5 with Porter stemming. A query word counts by where it's found (file name and title
  block 1.0, body 0.5, references 0.12) and by how rare it is. Common words are left out.
- **Meaning.** [Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF), 8-bit, runs on the
  Mac's GPU through llama.cpp.
  For each query, every passage's cosine score is turned into a z-score. A document counts as a meaning match
  only when one of its passages stands out (z ≥ 2.5), so a search can honestly come back empty. All vectors are
  compared directly in memory, with no vector database.
- **Light on the machine.** On battery only titles and first pages are embedded; the rest waits for the charger.
  Vectors are float16 in memory and leave it, with the model, when Sift is idle (~180 MB then).
- **Order of work.** The keyword index of everything is built first, in about a minute. Embedding then covers
  every document's title block and first pages, newest first, before the rest. Text files that copy a PDF are
  searched by their words but not embedded a second time.
- **Privacy.** Nothing about your files leaves the computer. Sift goes online for two things only: the
  one-time model download and the daily exchange rates. Neither request carries anything you type or store.

## Build

Needs macOS 14+, Apple Silicon, the Xcode Command Line Tools and [uv](https://docs.astral.sh/uv/).

```sh
./build.sh          # installs ~/Applications/Sift.app
open ~/Applications/Sift.app
```

Then turn off Spotlight's shortcut in System Settings → Keyboard → Keyboard Shortcuts → Spotlight, so ⌘Space reaches
Sift. You can pick another shortcut from Sift's menu bar icon instead.

Search from the terminal: `cd engine && .venv/bin/python -m sift_engine.ask "halvorsen plural llm"`.

## Keys

| Key | |
|---|---|
| ↑ ↓ | move through results |
| ↩ | open (PDFs get your words in the find pasteboard: ⌘G in Preview jumps to them) |
| ⌘↩ | show in Finder |
| ⌘Y, or Space after moving | Quick Look preview |
| ⌘C | copy the file, or the answer |
| esc | clear, then close |
