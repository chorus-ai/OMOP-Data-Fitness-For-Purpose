"""Locations and containment checks for the repository's bundled assets."""
from pathlib import Path


def project_root():
    """Return the repository root independently of the caller's working directory."""
    return Path(__file__).resolve().parent.parent


ROOT = project_root()
CONFIG = ROOT / "config"
SQL = (ROOT / "sql").resolve()


def resolve_query_path(manifest_path, query_path):
    """Resolve a query without allowing an untrusted manifest to escape its root.

    Bundled manifests contain repository-relative SQL paths. Other manifests keep
    their original manifest-directory-relative semantics.
    """
    manifest = Path(manifest_path).resolve()
    rel = Path(query_path)
    if rel.is_absolute() or rel.drive or ".." in rel.parts:
        raise ValueError("Query path escapes the allowed folder")
    bundled = manifest in {(CONFIG / "manifest.json").resolve(),
                           (CONFIG / "screening_manifest.json").resolve()}
    base = ROOT if bundled else manifest.parent
    allowed = SQL if bundled else manifest.parent
    path = (base / rel).resolve()
    if not path.is_relative_to(allowed) or (bundled and not path.is_relative_to(ROOT)):
        raise ValueError("Query path escapes the allowed folder")
    return path
