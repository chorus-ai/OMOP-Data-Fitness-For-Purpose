"""Public release-layout checks. No database execution."""
import json
from pathlib import Path
import unittest

from omop_fitness.inventory import inventory_sha256

ROOT = Path(__file__).resolve().parent.parent

class ReleaseContractTests(unittest.TestCase):
    def test_release_layout(self):
        expected_root_files = {"README.md", "Run_site_assessment.ipynb", "requirements.txt", ".gitignore"}
        self.assertTrue(all((ROOT / name).is_file() for name in expected_root_files))
        old_root_files = (
            "pipeline.py", "historical_runner.py", "historical_interpretation.py", "single_site.py", "reporting.py",
            "manifest.json", "screening_manifest.json", "registry_hist_a.json", "registry_hist_b.json",
            "registry_transfusion.json", "METRIC_RULES.csv", "NOTEBOOK_GUIDE.md", "README_REPORT.md", "EVIDENCE.md",
            "VALIDATION.md", "requirements-db.txt", "requirements-dev.txt", "requirements-notebook.txt",
            "requirements-pdf.txt", "file_hashes.json", "tests_report.py", "test_pipeline.py",
        )
        for name in old_root_files:
            self.assertFalse((ROOT / name).exists(), name)
        for test in (ROOT / "tests").glob("test_*.py"):
            self.assertFalse((ROOT / test.name).exists(), test.name)
        self.assertFalse((ROOT / "sql/test_sql_contract.py").exists())
        for directory in ("omop_fitness", "config", "docs", "requirements", "tests", "metadata", "example", "templates", "sql"):
            self.assertTrue((ROOT / directory).is_dir(), directory)
        for name in ("pipeline", "historical_runner", "historical_interpretation", "single_site", "reporting", "paths", "__init__"):
            self.assertTrue((ROOT / "omop_fitness" / (name + ".py")).is_file(), name)
        for name in ("manifest.json", "screening_manifest.json", "registry_hist_a.json", "registry_hist_b.json", "registry_transfusion.json", "METRIC_RULES.csv"):
            self.assertTrue((ROOT / "config" / name).is_file(), name)
        for name in ("NOTEBOOK_GUIDE.md", "README_REPORT.md", "EVIDENCE.md", "VALIDATION.md"):
            self.assertTrue((ROOT / "docs" / name).is_file(), name)
        for name in ("db.txt", "dev.txt", "notebook.txt", "pdf.txt"):
            self.assertTrue((ROOT / "requirements" / name).is_file(), name)
        self.assertTrue((ROOT / "tests/test_report.py").is_file())
        self.assertTrue((ROOT / "tests/test_sql_contract.py").is_file())
        self.assertTrue((ROOT / "metadata/file_hashes.json").is_file())

    def test_retired_artifacts_remain_absent(self):
        self.assertFalse((ROOT / "Legacy_import_demo.ipynb").exists())
        self.assertFalse((ROOT / "historical_manifest.json").exists())
        self.assertFalse(list((ROOT / "sql" / "historical").glob("*.original.sql")))

    def test_public_manifest_retains_executable_provenance(self):
        entries = json.loads((ROOT / "config/screening_manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(len(entries), 6)
        for entry in entries:
            self.assertNotIn("source_url", entry)
            self.assertEqual(len(entry["sha256"]), 64)
            self.assertEqual(len(entry["source_sha256"]), 64)
            self.assertTrue((ROOT / entry["path"]).is_file())

    def test_inventory_has_no_missing_or_private_repository_paths(self):
        inventory = json.loads((ROOT / "metadata/file_hashes.json").read_text(encoding="utf-8"))
        expected = {
            ".gitignore", "README.md", "Run_site_assessment.ipynb", "requirements.txt",
            *("omop_fitness/" + name + ".py" for name in ("__init__", "paths", "inventory", "pipeline", "historical_runner", "historical_interpretation", "single_site", "reporting")),
            *("config/" + name for name in ("manifest.json", "screening_manifest.json", "registry_hist_a.json", "registry_hist_b.json", "registry_transfusion.json", "METRIC_RULES.csv")),
            *("docs/" + name for name in ("NOTEBOOK_GUIDE.md", "README_REPORT.md", "EVIDENCE.md", "VALIDATION.md")),
            *("requirements/" + name for name in ("db.txt", "dev.txt", "notebook.txt", "pdf.txt")),
            *("tests/" + name for name in ("__init__.py", "test_inventory.py", "test_report.py", "test_sql_contract.py", "test_pipeline.py", "test_release_contract.py",
                "test_database.py", "test_database_notebook.py", "test_evidence_review.py", "test_exact_contracts.py", "test_export_isolation.py",
                "test_historical_interpretation.py", "test_historical_runner.py", "test_notebook_state.py", "test_report_design.py", "test_single_site.py", "test_widget_kernel.py")),
            *("example/" + name for name in ("feedback_report.docx", "feedback_report.pdf", "findings.csv", "findings.json", "README.md", "run_manifest.json", "summary.csv", "summary.json")),
            "templates/report_template.docx", "sql/.gitattributes", "sql/build_queries.py", "sql/build_detailed.py",
            "sql/fixtures/dialysis_classifier_cases.json", "sql/fixtures/dialysis_classifier_regression.sql",
        }
        for manifest in ("manifest.json", "screening_manifest.json"):
            entries = json.loads((ROOT / "config" / manifest).read_text(encoding="utf-8"))
            expected.update(entry["path"] for entry in entries)
        self.assertFalse(expected - inventory.keys(), expected - inventory.keys())
        for name in inventory:
            relative = Path(name)
            self.assertFalse(relative.is_absolute())
            self.assertNotIn("..", relative.parts)
            self.assertNotIn(".git", relative.parts)
            self.assertTrue((ROOT / relative).is_file(), name)
            self.assertEqual(inventory_sha256(ROOT / relative), inventory[name], name)

if __name__ == "__main__":
    unittest.main()
