"""Public release-layout checks. No database execution."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent

class ReleaseContractTests(unittest.TestCase):
    def test_retired_artifacts_remain_absent(self):
        self.assertFalse((ROOT / "Legacy_import_demo.ipynb").exists())
        self.assertFalse((ROOT / "historical_manifest.json").exists())
        self.assertFalse(list((ROOT / "sql" / "historical").glob("*.original.sql")))

    def test_public_manifest_retains_executable_provenance(self):
        entries = json.loads((ROOT / "screening_manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(len(entries), 6)
        for entry in entries:
            self.assertNotIn("source_url", entry)
            self.assertEqual(len(entry["sha256"]), 64)
            self.assertEqual(len(entry["source_sha256"]), 64)
            self.assertTrue((ROOT / entry["path"]).is_file())

    def test_inventory_has_no_missing_or_private_repository_paths(self):
        inventory = json.loads((ROOT / "file_hashes.json").read_text(encoding="utf-8"))
        for name in inventory:
            relative = Path(name)
            self.assertFalse(relative.is_absolute())
            self.assertNotIn("..", relative.parts)
            self.assertNotIn(".git", relative.parts)
            self.assertTrue((ROOT / relative).is_file(), name)

if __name__ == "__main__":
    unittest.main()
