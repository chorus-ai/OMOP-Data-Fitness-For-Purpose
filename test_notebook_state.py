"""Default notebook contract after retirement of the alternate notebook UI.

Shared demo/Excel functionality remains covered by test_single_site/test_pipeline.
These tests compile cells only; they do not connect to any database.
"""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent


class DefaultNotebookContractTests(unittest.TestCase):
    def setUp(self):
        self.notebook = json.loads((ROOT / "Run_site_assessment.ipynb").read_text(encoding="utf-8"))
        self.cells = [c for c in self.notebook["cells"] if c["cell_type"] == "code"]

    def test_reusable_notebook_has_no_saved_outputs(self):
        self.assertTrue(self.cells)
        for cell in self.cells:
            self.assertEqual(cell.get("outputs"), [])
            self.assertIsNone(cell.get("execution_count"))

    def test_default_notebook_uses_historical_runner(self):
        code = "\n".join("".join(c["source"]) for c in self.cells)
        self.assertIn("from historical_runner import notebook_ui", code)
        self.assertIn("notebook_ui()", code)
        self.assertNotIn("run_site_assessment(", code)

    def test_default_cells_compile_without_execution(self):
        for cell in self.cells:
            compile("".join(cell["source"]), "Run_site_assessment.ipynb", "exec")


if __name__ == "__main__":
    unittest.main()
