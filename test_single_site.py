"""Single-site contracts. Fixtures are synthetic; no live database is contacted."""
import copy
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import pipeline
import single_site as s


class IsolationContracts(unittest.TestCase):
    def setUp(self):
        self.rows = s.demo_rows("Site_01")

    def test_field_contract_matches_core(self):
        self.assertEqual(s.RESULT_FIELDS, set(pipeline.FIELDS))

    def test_private_mapping_inside_code_is_rejected_for_every_mode(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            package = root / "package"
            package.mkdir()
            for mode in (None, "demo", "synthetic_demo", "excel", "database"):
                with self.subTest(mode=mode), self.assertRaises(s.SiteIsolationError):
                    s.assert_private_paths(root / "outputs", package / "private.json", mode, package)

    def test_non_synthetic_output_inside_code_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            package = Path(d) / "package"
            package.mkdir()
            for mode in (None, "excel", "workbook_import", "database"):
                with self.subTest(mode=mode), self.assertRaises(s.SiteIsolationError):
                    s.assert_private_paths(package / "outputs", mode=mode, package_dir=package)

    def test_external_private_paths_are_allowed(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            s.assert_private_paths(root / "outputs", root / "private.json", "excel", root / "package")

    def test_explicit_synthetic_output_inside_code_is_allowed(self):
        with tempfile.TemporaryDirectory() as d:
            package = Path(d) / "package"
            for mode in ("demo", "synthetic_demo"):
                s.assert_private_paths(package / "examples" / "synthetic", mode=mode, package_dir=package)

    def test_adapter_rejects_private_map_before_import_or_write(self):
        package = Path(s.__file__).resolve().parent
        mapping = package / "must_not_create_private_mapping.json"
        self.assertFalse(mapping.exists())
        with tempfile.TemporaryDirectory() as d, patch.dict("sys.modules", {"pipeline": None}):
            with self.assertRaisesRegex(s.SiteIsolationError, "Private mappings"):
                s.run_site_assessment(mode="demo", site="Site_01", output_dir=Path(d) / "out", private_mapping=mapping)
            self.assertFalse((Path(d) / "out").exists())
        self.assertFalse(mapping.exists())

    def test_adapter_rejects_real_output_before_database_import(self):
        output = Path(s.__file__).resolve().parent / "must_not_create_real_output"
        self.assertFalse(output.exists())
        with patch.dict("sys.modules", {"pipeline": None}):
            with self.assertRaisesRegex(s.SiteIsolationError, "Non-synthetic outputs"):
                s.run_site_assessment(mode="database", site="Site_01", output_dir=output)
        self.assertFalse(output.exists())

    def test_alias_format(self):
        for value in ("example", "Site_1", "site_01", "Site_01/Site_02", None):
            with self.assertRaises(s.SiteIsolationError):
                s.validate_site_alias(value)

    def test_selected_rows_only_and_inputs_unchanged(self):
        combined = self.rows + s.demo_rows("Site_02")
        original = copy.deepcopy(combined)
        result = s.prepare_site_rows(combined, "Site_01")
        self.assertEqual(len(result), len(self.rows))
        self.assertEqual(combined, original)

    def test_unknown_site_has_no_report(self):
        with self.assertRaises(s.SiteIsolationError):
            s.prepare_site_rows(self.rows, "Site_02")

    def test_mixed_rows_refused(self):
        with self.assertRaises(s.SiteIsolationError):
            s.assert_single_site(self.rows + s.demo_rows("Site_02"), "Site_01")

    def test_unknown_row_field_refused(self):
        self.rows[0]["extra"] = {"result": 999}
        with self.assertRaises(s.SiteIsolationError):
            s.prepare_site_rows(self.rows, "Site_01")

    def test_nested_known_row_field_refused(self):
        self.rows[0]["result"] = {"unreviewed": 999}
        with self.assertRaises(s.SiteIsolationError):
            s.prepare_site_rows(self.rows, "Site_01")

    def test_formula_is_withheld_without_mutation(self):
        self.rows[0].update(source_formula="='Site_02'!A1", result="999", numeric_value=999)
        selected = s.prepare_site_rows(self.rows, "Site_01")
        self.assertEqual(selected[0]["source_formula"], "")
        self.assertEqual(selected[0]["status"], "needs_review")
        self.assertIsNone(selected[0]["numeric_value"])
        self.assertEqual(self.rows[0]["numeric_value"], 999)

    def test_embedded_case_insensitive_alias_refused(self):
        for value in ("prefix_site_02_results.csv", {"x": [{"SITE_02": "bad"}]}):
            with self.assertRaises(s.SiteIsolationError):
                s.assert_alias_scope(value, "Site_01")
        s.assert_alias_scope("prefix_site_01_results.csv", "Site_01")

    def test_mismatched_metadata_owner_refused(self):
        for metadata in ({"site": "Site_02"}, {"sites": ["Site_01", "Site_02"]}, {"sites": "Site_01"}):
            with self.assertRaises(s.SiteIsolationError):
                s.isolate_metadata(metadata, self.rows, "Site_01")

    def test_unknown_execution_field_refused(self):
        with self.assertRaises(s.SiteIsolationError):
            s.isolate_metadata({"executions": [{"id": "q", "clinicaldata": 999}]}, self.rows, "Site_01")

    def test_nested_execution_payload_refused(self):
        for executions in ({"id": "q"}, [{"id": "q", "status": {"result": 999}}]):
            with self.assertRaises(s.SiteIsolationError):
                s.isolate_metadata({"executions": executions}, self.rows, "Site_01")

    def test_unknown_metadata_payload_not_copied(self):
        metadata = s.isolate_metadata({"extra": {"unreviewed": 999}, "result_rows": 999}, self.rows, "Site_01")
        self.assertNotIn("extra", metadata)
        self.assertEqual(metadata["result_rows"], len(self.rows))

    def test_source_counts_rebuilt(self):
        source = {"file": "synthetic_demo", "sha256": "fixture", "sheets": [{"sheet": "", "rows_imported": 999}]}
        metadata = s.isolate_metadata({"sources": [source]}, self.rows, "Site_01")
        self.assertEqual(metadata["sources"][0]["sheets"][0]["rows_imported"], len(self.rows))
        self.assertEqual(metadata["sources"][0]["sha256"], "fixture")

    def test_nonempty_output_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            sentinel = Path(d) / "keep.txt"
            sentinel.write_text("preserve")
            with self.assertRaises(ValueError):
                s.run_site_assessment(mode="demo", site="Site_01", output_dir=d)
            self.assertEqual(sentinel.read_text(), "preserve")

    def test_database_requires_scope_confirmation(self):
        with tempfile.TemporaryDirectory() as d, patch.object(pipeline, "run_database") as runner:
            with self.assertRaises(s.SiteIsolationError):
                s.run_site_assessment(mode="database", site="Site_01", output_dir=Path(d) / "out")
            runner.assert_not_called()

    def test_database_does_not_use_generic_fallback(self):
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {"OMOP_DSN": "synthetic-not-a-real-dsn"}, clear=True), patch.object(pipeline, "run_database") as runner:
            with self.assertRaises(ValueError):
                s.run_site_assessment(mode="database", site="Site_01", output_dir=Path(d) / "out", confirm_site_connection=True)
            runner.assert_not_called()

    def test_database_passes_explicit_scope_and_selected_key(self):
        metadata = {"mode": "database", "site": "Site_01"}
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {"OMOP_SITE_01_DSN": "synthetic-not-a-real-dsn"}), patch.object(pipeline, "run_database", return_value=(self.rows, metadata)) as runner, patch.object(s, "export_site", return_value={"fixture": True}):
            result = s.run_site_assessment(mode="database", site="Site_01", output_dir=Path(d) / "out", confirm_site_connection=True)
            self.assertTrue(result["fixture"])
            args = runner.call_args.args[0]
            self.assertTrue(args.confirm_site_connection)
            self.assertEqual(args.dsn_env, "OMOP_SITE_01_DSN")


if __name__ == "__main__":
    unittest.main()
