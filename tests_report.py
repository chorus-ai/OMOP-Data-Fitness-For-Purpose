"""Regression tests for evidence status and report generation."""
import copy
from pathlib import Path
import tempfile
import unittest

from reporting import assess, assert_report_scope, write_docx, write_pdf, write_report_template


def row(variable="Numeric value populated (%)", result="0.0%", **kwargs):
    data = dict(site="Site_01", topic="Fluid balance", category="Quantitative readiness", variable=variable,
                result=result, numeric_value=None, unit="", status="observed", source_file="screening.xlsx",
                source_sheet="Results", source_cell="C2", numerator=None, denominator=None, query_id="")
    data.update(kwargs)
    return data


class ReportScopeTests(unittest.TestCase):
    def assert_rejected_without_output(self, rows, findings=None, metadata=None):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "not_created" / "report.docx"
            with self.assertRaises(ValueError):
                write_docx(rows, findings or [], output, metadata)
            self.assertFalse(output.parent.exists())

    def test_empty_report_rejected_even_with_metadata_site(self):
        self.assert_rejected_without_output([], metadata={"site": "Site_01"})

    def test_mixed_rows_rejected_before_output(self):
        self.assert_rejected_without_output([row(), row(site="Site_02")])

    def test_invalid_or_missing_row_alias_rejected(self):
        for alias in (None, "", "Site_1", "site_01", " Site_01", "Site_XX", "Example institution"):
            with self.subTest(alias=alias):
                self.assert_rejected_without_output([row(site=alias)])
        missing = row()
        del missing["site"]
        self.assert_rejected_without_output([missing])

    def test_findings_must_match_rows(self):
        foreign = assess([row(site="Site_02")])
        self.assert_rejected_without_output([row()], foreign)
        missing = assess([row()])
        del missing[0]["site"]
        self.assert_rejected_without_output([row()], missing)

    def test_nested_metadata_site_references_rejected(self):
        cases = (
            {"site": "Site_02"},
            {"run": {"sites": ["Site_01", "Site_02"]}},
            {"sources": [{"site_alias": "Site_02"}]},
            {"context": {"Site_02": {"count": 3}}},
            {"run": {"notes": "Comparison with Site_02 is not allowed"}},
            {"run": {"site": "Some institution"}},
            {"path": "Site_02_summary.csv"},
            {"run": {"sites": ["Site_01", "Site_XX"]}},
        )
        for metadata in cases:
            with self.subTest(metadata=metadata):
                self.assert_rejected_without_output([row()], metadata=metadata)

    def test_foreign_alias_inside_evidence_rejected(self):
        self.assert_rejected_without_output([row(source_file="Site_02.xlsx")])
        self.assert_rejected_without_output([row(source_file="prefixsite_02_results.csv")])
        self.assert_rejected_without_output([row(result="SITE_02")])
        fs = assess([row()])
        fs[0]["evidence"] += "; also Site_02"
        self.assert_rejected_without_output([row()], fs)

    def test_valid_repeated_alias_in_nested_metadata_allowed(self):
        metadata = {"site": "Site_01", "run": {"sites": ["Site_01"], "file": "Site_01_summary.csv"}}
        self.assertEqual(assert_report_scope([row()], [], metadata), "Site_01")

    def test_assess_rejects_empty_or_mixed_sites(self):
        for rows in ([], [row(), row(site="Site_02")]):
            with self.assertRaises(ValueError):
                assess(rows)

    def test_existing_output_not_overwritten_on_validation_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.docx"
            output.write_bytes(b"original content")
            with self.assertRaises(ValueError):
                write_docx([row(), row(site="Site_02")], [], output)
            self.assertEqual(output.read_bytes(), b"original content")

    def test_synthetic_demo_label_in_body_and_every_page_header(self):
        from docx import Document
        from zipfile import ZipFile
        rows = [row(source_file="synthetic_metrics.csv")]
        with tempfile.TemporaryDirectory() as tmp:
            output = write_docx(rows, assess(rows), Path(tmp) / "synthetic.docx", {"mode": "synthetic_demo"})
            doc = Document(output)
            body = "\n".join(p.text for p in doc.paragraphs)
            self.assertIn("SYNTHETIC DEMONSTRATION", body)
            self.assertIn("do not describe any actual institution", body)
            self.assertIn("SYNTHETIC DEMONSTRATION", doc.sections[0].header.paragraphs[0].text)
            self.assertIn("Evidence coverage for Site_01", body)
            with ZipFile(output) as z:
                self.assertNotIn(b"<w:pBdr", z.read("word/styles.xml"))

    def test_blank_template_is_editable_and_has_no_findings(self):
        from docx import Document
        with tempfile.TemporaryDirectory() as tmp:
            output = write_report_template(Path(tmp) / "template.docx", site="Site_01")
            doc = Document(output)
            body = "\n".join(p.text for p in doc.paragraphs)
            self.assertIn("BLANK EDITABLE TEMPLATE", body)
            self.assertIn("[Research question", body)
            self.assertIn("no screening results", body)
            self.assertNotIn("Recorded findings:", body)
            self.assertEqual(doc.core_properties.author, "")
            self.assertEqual(doc.core_properties.last_modified_by, "")

    def test_template_rejects_foreign_metadata_before_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "not_created" / "template.docx"
            with self.assertRaises(ValueError):
                write_report_template(output, "Site_01", {"nested": {"sites": ["Site_02"]}})
            self.assertFalse(output.parent.exists())

    def test_detailed_appendix_contains_findings_beyond_summary(self):
        from docx import Document
        rows = [row("source_iv_standard_route_mismatch", "10%", numerator=1, denominator=10),
                row("Event datetime populated (%)", "0%"),
                row("with_quantity", "0%", numerator=0, denominator=10),
                row("Fluid intake records (n)", "0")]
        findings = assess(rows)
        with tempfile.TemporaryDirectory() as tmp:
            p = write_docx(rows, findings, Path(tmp) / "report.docx", {"max_actions_per_site": 1})
            doc = Document(p)
            body = "\n".join(p.text for p in doc.paragraphs)
            appendix = "\n".join(c.text for t in doc.tables[1:] for r in t.rows for c in r.cells)
            from historical_interpretation import findings_for_rows
            for f in findings_for_rows(rows):
                self.assertIn(f["evidence"], appendix)
                self.assertIn(f["action"], appendix)
                self.assertIn(f["source"], appendix)

    def test_pdf_rejects_mixed_site_before_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "not_created" / "report.pdf"
            with self.assertRaises(ValueError):
                write_pdf([row(), row(site="Site_02")], [], output)
            self.assertFalse(output.parent.exists())

    def test_docx_rejects_real_report_inside_package_before_output(self):
        rows = [row()]
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as tmp:
            output = Path(tmp) / "not_created" / "report.docx"
            for metadata in (None, {"mode": "workbook_import"}, {"mode": "database"}):
                with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                    write_docx(rows, assess(rows), output, metadata)
                self.assertFalse(output.parent.exists())
                self.assertFalse(output.exists())

    def test_pdf_rejects_real_report_inside_package_before_output(self):
        rows = [row()]
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as tmp:
            output = Path(tmp) / "not_created" / "report.pdf"
            for metadata in (None, {"mode": "workbook_import"}, {"mode": "database"}):
                with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                    write_pdf(rows, assess(rows), output, metadata)
                self.assertFalse(output.parent.exists())
                self.assertFalse(output.exists())

    def test_private_path_rejection_preserves_existing_reports(self):
        rows = [row()]
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as tmp:
            for writer, suffix in ((write_docx, "docx"), (write_pdf, "pdf")):
                output = Path(tmp) / ("report." + suffix)
                output.write_bytes(b"existing report")
                with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                    writer(rows, assess(rows), output, {"mode": "workbook_import"})
                self.assertEqual(output.read_bytes(), b"existing report")

    def test_synthetic_reports_allowed_inside_package(self):
        rows = [row(source_file="synthetic_demo")]
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as tmp:
            for writer, suffix in ((write_docx, "docx"), (write_pdf, "pdf")):
                with self.subTest(suffix=suffix):
                    output = writer(rows, assess(rows), Path(tmp) / ("synthetic." + suffix),
                                    {"mode": "synthetic_demo"})
                    self.assertGreater(output.stat().st_size, 0)

    def test_blank_template_allowed_inside_package(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as tmp:
            output = write_report_template(Path(tmp) / "template.docx")
            self.assertGreater(output.stat().st_size, 0)

    def test_pdf_uses_same_complete_evidence(self):
        from pypdf import PdfReader
        rows = [row("Fluid intake records (n)", "0", source_file="synthetic_demo")]
        findings = assess(rows)
        with tempfile.TemporaryDirectory() as tmp:
            p = write_pdf(rows, findings, Path(tmp) / "example.pdf", {"mode": "synthetic_demo"})
            reader = PdfReader(p)
            text = " ".join(page.extract_text() for page in reader.pages)
            text = " ".join(text.split())
            self.assertIn("SYNTHETIC DEMONSTRATION", text)
            self.assertIn("Variable-level findings and next actions", text)
            from historical_interpretation import findings_for_rows
            findings = findings_for_rows(rows)
            self.assertIn(findings[0]["title"], text)
            self.assertIn(findings[0]["evidence"], text)
            self.assertIn(findings[0]["action"], text)
            self.assertEqual(reader.metadata.get("/Author"), "")


if __name__ == "__main__":
    unittest.main()
