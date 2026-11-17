"""Hash the public file inventory consistently across Git checkouts."""
import hashlib
from pathlib import Path


TEXT_SUFFIXES = frozenset({".py", ".md", ".json", ".csv", ".txt", ".ipynb"})
TEXT_FILENAMES = frozenset({".gitignore", ".gitattributes"})


def inventory_sha256(path):
    """Return the inventory SHA-256; only recognized UTF-8 text uses LF.

    CRLF is normalized to LF for listed text types after validating UTF-8.
    SQL, binary and unknown file types are hashed as exact bytes.
    """
    path = Path(path)
    data = path.read_bytes()
    if path.name in TEXT_FILENAMES or path.suffix.lower() in TEXT_SUFFIXES:
        data.decode("utf-8", errors="strict")
        data = data.replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()
