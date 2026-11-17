"""Independent evidence/precision checks; synthetic only, no clinical validation."""
import csv
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlparse

import historical_interpretation as hi
import historical_runner as runner
import pipeline
import reporting

ROOT = Path(__file__).resolve().parent


class EvidenceReviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry = hi.load_registry()
        cls.entries = {e["id"]: e for e in runner.entries()}
        cls.specs = list(cls.registry.values())

    def row(self, spec, result, **kwargs):
        raw = dict(variable=spec["variable"], section=spec.get("section", ""), result=result)
        raw.update(kwargs)
        return runner.normalize(raw, self.entries[spec["query_id"]], "Site_01")

    def test_all_309_have_public_sources_and_support_limits(self):
        self.assertEqual(len(self.specs), 309)
        allowed = {"ohdsi.github.io", "www.postgresql.org"}
        for spec in self.specs:
            with self.subTest(query=spec["query_id"], variable=spec["variable"]):
                ev = spec["evidence"]
                self.assertTrue(ev["public_sources"])
                self.assertTrue(ev["recommendation_basis"])
                self.assertTrue(ev["support_limit"])
                for url in ev["public_sources"]:
                    parsed = urlparse(url)
                    self.assertEqual(parsed.scheme, "https")
                    self.assertIn(parsed.netloc, allowed)
                    self.assertIsNone(parsed.username)
                self.assertRegex((ev["support_limit"] + " " + ev["recommendation_basis"]).lower(), r"not|inferen")

    def test_all_sql_hashes_and_label_locators_resolve(self):
        for spec in self.specs:
            with self.subTest(query=spec["query_id"], variable=spec["variable"]):
                ev = spec["evidence"]
                relative = Path(ev["sql_path"])
                self.assertFalse(relative.is_absolute())
                self.assertNotIn("..", relative.parts)
                source = ROOT / relative
                self.assertEqual(hashlib.sha256(source.read_bytes().replace(b"\r\n", b"\n")).hexdigest(), ev["sql_sha256"])
                lines = source.read_text(encoding="utf-8").splitlines()
                locator = ev["sql_locator"]
                positions = locator.get("output_label_lines", locator.get("metric_lines", [locator.get("line")]))
                self.assertTrue(positions)
                self.assertTrue(all(isinstance(n, int) and 1 <= n <= len(lines) for n in positions))
                snippet = "\n".join(line for n in positions for line in lines[n - 1:n + 6])
                if spec["query_id"].endswith("_semantic_inventory"):
                    # These labels are SQL concatenations, not literal strings.
                    self.assertIn("provenance || '/' || kind AS variable", snippet)
                    provenance, kind = spec["variable"].split("/", 1)
                    full_sql = "\n".join(lines)
                    self.assertIn("'" + provenance + "'", full_sql)
                    self.assertIn("'" + kind + "'", full_sql)
                else:
                    self.assertIn(spec["variable"].replace("'", "''"), snippet)

    def test_150_percentage_contracts_have_declared_precision(self):
        percents = [s for s in self.specs if s["kind"] == "percent"]
        self.assertEqual(len(percents), 150)
        self.assertEqual(sum(s["precision_decimals"] == 1 for s in percents), 46)
        self.assertEqual(sum(s["precision_decimals"] == 2 for s in percents), 104)
        for spec in percents:
            with self.subTest(query=spec["query_id"], variable=spec["variable"]):
                self.assertIn(spec["precision_decimals"], (1, 2))
                self.assertTrue(spec["denominator"])
                decimals = spec["precision_decimals"]
                good = f"{100 / 3:.{decimals}f}%"
                self.assertEqual(hi.interpret(self.row(spec, good, numerator=1, denominator=3))["assessment"], "descriptive")
                bad = f"{100 / 3 + 2 * 10 ** -decimals:.{decimals}f}%"
                self.assertEqual(hi.interpret(self.row(spec, bad, numerator=1, denominator=3))["assessment"], "invalid")

    def test_precision_tolerance_uses_declared_decimal_places(self):
        spec1 = next(s for s in self.specs if s.get("precision_decimals") == 1)
        spec2 = next(s for s in self.specs if s.get("precision_decimals") == 2)
        self.assertEqual(hi.interpret(self.row(spec1, "33.3%", numerator=1, denominator=3))["assessment"], "descriptive")
        self.assertEqual(hi.interpret(self.row(spec2, "33.3%", numerator=1, denominator=3))["assessment"], "invalid")
        self.assertEqual(hi.interpret(self.row(spec2, "33.33%", numerator=1, denominator=3))["assessment"], "descriptive")

    def test_unknown_precision_does_not_assume_rounding_tolerance(self):
        spec = dict(next(s for s in self.specs if s["kind"] == "percent"))
        spec.pop("precision_decimals", None)
        with patch.object(hi, "contract", return_value=spec):
            self.assertEqual(hi.interpret(self.row(spec, "33.33%", numerator=1, denominator=3))["assessment"], "invalid")
            self.assertEqual(hi.interpret(self.row(spec, "40%", numerator=2, denominator=5))["assessment"], "descriptive")

    def test_rounded_boundary_does_not_claim_exact_none_or_all(self):
        for spec in self.specs:
            if spec["kind"] != "percent":
                continue
            with self.subTest(query=spec["query_id"], variable=spec["variable"]):
                for value, numerator in (("0%", 1), ("100%", 999999)):
                    item = hi.interpret(self.row(spec, value, numerator=numerator, denominator=1000000))
                    self.assertEqual(item["assessment"], "descriptive")
                    self.assertIn("rounded", item["interpretation"].lower())
                    self.assertNotIn("All eligible rows met", item["interpretation"])
                    self.assertNotIn("none met this numerator condition", item["interpretation"])
                self.assertIn("round", spec["zero_action"].lower())

    def test_evidence_fields_round_trip_through_csv_and_docx(self):
        from docx import Document
        spec = next(s for s in self.specs if s["kind"] == "percent")
        row = self.row(spec, "40%", numerator=2, denominator=5)
        expected = hi.interpret(row)
        with tempfile.TemporaryDirectory(prefix="evidence_review_") as tmp:
            out = Path(tmp) / "export"
            pipeline.export_outputs([row], {"mode": "synthetic_demo"}, out)
            with (out / "findings.csv").open(encoding="utf-8-sig", newline="") as handle:
                record = next(csv.DictReader(handle))
            for field in ("calculation_source", "evidence_basis", "evidence_sources", "evidence_limit", "assessment"):
                self.assertEqual(record[field], expected[field])
            doc = Document(out / "feedback_report.docx")
            text = "\n".join(p.text for p in doc.paragraphs)
            table_text = "\n".join(c.text for t in doc.tables for r in t.rows for c in r.cells)
            self.assertIn("Methods and field-semantics references", text)
            self.assertIn("Follow-up inference, not a validated fitness decision.", table_text)
            for url in spec["evidence"]["public_sources"]:
                self.assertIn(url, text)

    def test_public_runtime_material_has_no_private_history_links(self):
        forbidden = ("chatgpt" + ".com/c/", "chatgpt" + ".com/share/", "conversation_" + "id", "message_" + "id")
        paths = list(ROOT.glob("registry_*.json")) + [ROOT / n for n in ("historical_interpretation.py", "reporting.py", "screening_manifest.json", "manifest.json")]
        for path in paths:
            with self.subTest(path=path.name):
                text = path.read_text(encoding="utf-8").lower()
                for token in forbidden:
                    self.assertNotIn(token.lower(), text)
                self.assertNotIn("c:\\users\\", text)

    def test_all_sql_files_are_byte_identical_to_supplied_live_root(self):
        root = os.environ.get("FITNESS_LIVE_ROOT")
        if not root:
            self.skipTest("Set FITNESS_LIVE_ROOT for explicit read-only comparison; no live path is embedded.")
        live = Path(root)
        copy_paths = {p.relative_to(ROOT / "sql") for p in (ROOT / "sql").rglob("*.sql")}
        live_paths = {p.relative_to(live / "sql") for p in (live / "sql").rglob("*.sql")}
        self.assertEqual(copy_paths, live_paths)
        for relative in sorted(copy_paths):
            with self.subTest(sql=str(relative)):
                self.assertEqual((ROOT / "sql" / relative).read_bytes(), (live / "sql" / relative).read_bytes())


if __name__ == "__main__":
    unittest.main()
