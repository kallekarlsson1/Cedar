# Cedar

A Spotlight replacement for macOS that finds documents by what's in them: by exact words and by meaning.

Press ⌘Space and type what you remember. Cedar answers on every keystroke:

- **Apps**: `saf` → Safari, `vsc` → Visual Studio Code. Things you open often rank higher.
- **Math**: `24*1.25`, `(3+4)^2`, `15% of 80`, `sqrt(2)`. A decimal comma works too.
- **Currencies**: `100 usd`, `$100 to eur`, `500 kr`. Uses the European Central Bank's daily rates.
- **Units**: `5 km in miles`, `20 c to f`, `180 cm in feet`, `3 dl`.
- **Files and folders**: any part of the name, across your home folder, Applications and plugged-in drives.
- **Document contents**: PDFs (scanned ones too), Word, PowerPoint, Excel, Markdown, text, HTML and LaTeX. Each result shows the page
  and the passage that matched.

## Why

Spotlight treats every word in a PDF the same. A paper by Halvorsen gets buried under all the papers that only *cite*
Halvorsen, and the PDF's own author field often says `arXiv GenPDF`. Cedar reads a paper's title and author block
separately from its body and its reference list, and ranks them in that order. It also searches by meaning:
"the paper about people using several chatbots for math and writing" finds the paper without those exact words.

## How it works

One binary, three roles (all Swift; no Python, nothing to install besides the app):

```
Cedar            the panel: apps, math and conversions in-process; asks the engine for the rest
   │ unix socket (yours only)
Cedar --engine   lists files, reads documents, follows changes (FSEvents) and answers searches; ~30 MB
   │ pipe
Cedar --model    Qwen3-Embedding (8-bit) on llama.cpp + Metal, ~220 MB; embeds passages while you're not
                 searching, quits after 2 idle minutes, back in under a second

~/Library/Application Support/Cedar/
   names.db     every file and folder name; trigram index for all but dataset folders' files, which are
                found by the start of their name. After the first listing, a start reads only changed folders
   content.db   passages with page numbers, FTS5 keyword index, one vector and one 128-byte code per passage
```

- **Reading.** PDFs through PDFKit, Word and RTF through macOS's own import, PowerPoint and Excel through unzip,
  scanned pages through Vision. Each document is split into a title/author block (`head`), overlapping
  ~200-word passages (`body`, with page numbers) and its reference list (`refs`).
- **Words.** SQLite FTS5 with Porter stemming. A query word counts by where it's found (file name and title
  block 1.0, body 0.5, references 0.12) and by how rare it is. Common words are left out.
- **Meaning.** [Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF), 8-bit, on the Mac's
  GPU through llama.cpp, linked into the binary. For each query every passage's cosine is turned into a z-score;
  a document is a meaning match only when a passage stands out (z ≥ 2) and is close in absolute terms
  (cosine ≥ 0.42), so a search can honestly come back empty.
- **Built to scale.** Memory holds one bit per dimension of each vector (128 bytes a passage). A search finds the
  closest codes, then scores those few hundred passages exactly from the vectors on disk: the same top 10 as
  scoring everything (30 queries on a real 22,000-passage library), and a million passages take 128 MB and a
  2.5 ms scan. Beyond its first pages, a document is embedded in full only if it changed or was opened within
  two years; opening an older one from Cedar reads it in full.
- **Light on the machine.** On battery only titles and first pages are embedded; the rest, and text recognition,
  wait for the charger. Vectors are float16 in memory and leave it, with the model, when Cedar is idle.
- **Order of work.** The keyword index of everything is built first. Embedding then covers every document's
  title block and first pages, newest first, before the rest. Text files that copy a PDF are searched by their
  words but not embedded a second time, and identical passages share one embedding.

## Private by design

Everything Cedar knows about your files stays on your Mac: the index, the model that understands meaning, and the
text recognition for scanned PDFs (Apple's Vision) all run locally. Cedar goes online for two things only, and
neither request carries anything you type or store: downloading the model once (640 MB), and fetching the day's
exchange rates. Files that are only in iCloud are listed by name and never downloaded or opened.

## Checking search quality

`evals/corpus.noindex` is a small made-up library (papers that cite each other, notes, a duplicate, a scan) and
`evals/queries.json` lists queries with the files they should find. Run it before and after any change to ranking:

```sh
scripts/check.sh                # the full check, with the model
scripts/check.sh --words-only   # fast, no model
```

## Build

Needs an Apple Silicon Mac with macOS 14+, the Xcode Command Line Tools, git, and cmake (or
[uv](https://docs.astral.sh/uv/), which can run cmake).

```sh
./build.sh          # builds llama.cpp the first time, then installs ~/Applications/Cedar.app
open ~/Applications/Cedar.app
```

Then turn off Spotlight's shortcut in System Settings → Keyboard → Keyboard Shortcuts → Spotlight, so ⌘Space reaches
Cedar. You can pick another shortcut from Cedar's menu bar icon instead.

From a terminal: `Cedar.app/Contents/MacOS/Cedar --search "halvorsen plural llm"` and `--status`.

## Keys

| Key | |
|---|---|
| ↑ ↓ | move through results |
| ↩ | open (PDFs get your words in the find pasteboard: ⌘G in Preview jumps to them) |
| ⌘↩ | show in Finder |
| ⌘Y, or Space after moving | Quick Look preview |
| ⌘C | copy the file, or the answer |
| esc | clear, then close |
