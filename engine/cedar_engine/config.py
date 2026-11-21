"""Where Cedar looks, what it skips, and where it keeps its index."""

import os
from pathlib import Path

HOME = Path.home()
# CEDAR_DATA and CEDAR_ROOTS point a test run at its own index and folders (evals/, tests/).
DATA = Path(os.environ["CEDAR_DATA"]) if os.environ.get("CEDAR_DATA") else HOME / "Library" / "Application Support" / "Cedar"
SOCKET = DATA / "engine.sock"
NAMES_DB = DATA / "names.db"
CONTENT_DB = DATA / "content.db"
LOG = DATA / "engine.log"

MODEL_REPO = "Qwen/Qwen3-Embedding-0.6B-GGUF"
MODEL_FILE = "Qwen3-Embedding-0.6B-Q8_0.gguf"
# Names the vectors in the index. When it changes (another model, or a setup whose vectors don't compare), every
# passage is embedded again. COMPATIBLE lists earlier names whose vectors are the same within rounding (measured:
# PyTorch fp16 vs llama.cpp 8-bit, cosine 0.9997 mean / 0.9993 worst), so those indexes are kept.
VECTORS = "Qwen3-Embedding-0.6B | 512 tokens | v1"
COMPATIBLE = {"Qwen/Qwen3-Embedding-0.6B | sentence-transformers fp16 | v1"}


ICLOUD = HOME / "Library" / "Mobile Documents" / "com~apple~CloudDocs"


def is_dataless(path: str) -> bool:
    """True for a file that's only in iCloud (not downloaded). Its name is searchable; its contents are never
    read, because reading would make macOS download it."""
    try:
        return bool(os.stat(path, follow_symlinks=False).st_flags & 0x40000000)   # SF_DATALESS
    except (OSError, AttributeError):
        return False


_power = {"checked": 0.0, "battery": False}


def on_battery() -> bool:
    """True when the Mac runs on battery (checked once a minute). Heavy work waits for the charger."""
    import subprocess
    import time
    if time.time() - _power["checked"] > 60:
        try:
            out = subprocess.run(["/usr/bin/pmset", "-g", "batt"], capture_output=True, text=True, timeout=5).stdout
            _power["battery"] = "Battery Power" in out
        except Exception:
            _power["battery"] = False
        _power["checked"] = time.time()
    return _power["battery"]


def roots() -> list[Path]:
    """Everything a person would look for: the home folder, apps, and plugged-in drives."""
    if os.environ.get("CEDAR_ROOTS"):
        return [Path(p) for p in os.environ["CEDAR_ROOTS"].split(":")]
    out = [HOME, Path("/Applications")]
    if ICLOUD.is_dir():
        out.append(ICLOUD)          # iCloud Drive lives inside ~/Library, which is otherwise skipped
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


def set_priority(kind: str):
    """macOS quality of service for this thread: "search" keeps it on the performance cores and out of App Nap
    (DigUp measured App Nap and efficiency cores slowing a search from 125 to 650 ms); "background" for indexing."""
    import ctypes
    classes = {"search": 0x19, "background": 0x11}   # QOS_CLASS_USER_INITIATED, QOS_CLASS_UTILITY
    try:
        ctypes.CDLL("/usr/lib/libSystem.B.dylib").pthread_set_qos_class_self_np(classes[kind], 0)
    except Exception:
        pass
