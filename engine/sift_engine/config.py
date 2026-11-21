"""Where Sift looks, what it skips, and where it keeps its index."""

import os
from pathlib import Path

HOME = Path.home()
DATA = HOME / "Library" / "Application Support" / "Sift"
SOCKET = DATA / "engine.sock"
NAMES_DB = DATA / "names.db"
CONTENT_DB = DATA / "content.db"
LOG = DATA / "engine.log"

MODEL = "Qwen/Qwen3-Embedding-0.6B"


def roots() -> list[Path]:
    """Everything a person would look for: the home folder, apps, and plugged-in drives."""
    out = [HOME, Path("/Applications")]
    volumes = Path("/Volumes")
    if volumes.is_dir():
        for v in volumes.iterdir():
            # The startup disk shows up in /Volumes as a link to /; it's covered by the home folder.
            if v.is_dir() and not v.is_symlink() and os.path.ismount(v):
                out.append(v)
    return out


# Folders whose contents are never listed: app internals, caches, version control, package managers, environments.
SKIP_PATHS = {HOME / "Library", HOME / ".Trash"}
SKIP_NAMES = {
    "node_modules", ".git", ".hg", ".svn", ".venv", "venv", "env", "__pycache__", "site-packages",
    ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".gradle", ".idea", "DerivedData",
    ".build", "build.noindex", "Pods", "target", ".next", ".nuxt", "dist-packages", ".ipynb_checkpoints",
    "System Volume Information", "$RECYCLE.BIN", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
}
# Bundles that macOS shows as one file: listed by name, never opened up.
PACKAGES = {
    ".app", ".bundle", ".framework", ".photoslibrary", ".musiclibrary", ".tvlibrary", ".pkg", ".mpkg",
    ".xcodeproj", ".xcworkspace", ".playground", ".kext", ".plugin", ".appex", ".imovielibrary",
    ".pages", ".numbers", ".key", ".rtfd", ".fcpbundle", ".logicx", ".band", ".sparsebundle",
}

# A folder holding more files than this directly is treated as a dataset: its files are found by name only.
CROWDED = 500

# Documents whose text is read.
DOC_EXTS = {
    ".pdf", ".md", ".markdown", ".txt", ".tex", ".html", ".htm", ".docx", ".pptx", ".xlsx",
    ".rtf", ".doc", ".odt", ".rst", ".org",
}
MAX_TEXT_BYTES = 30_000_000   # plain-text files larger than this are data, not documents
MAX_PDF_BYTES = 400_000_000

# Embedding order: the first pages of everything before the rest of long documents.
FIRST_PASS_PAGES = 3
FIRST_PASS_CHUNKS = 10


def skip_dir(path: Path, name: str) -> bool:
    return (name.startswith(".") or name in SKIP_NAMES or path in SKIP_PATHS
            or os.path.splitext(name)[1].lower() in PACKAGES)
