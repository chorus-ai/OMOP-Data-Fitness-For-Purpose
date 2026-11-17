import csv
from datetime import datetime
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from omop_fitness import pipeline as p


class Results(unittest.TestCase):
    def test_zero_is_observed(self):
        self.assertEqual(p.parse_result(0)['numeric_value'], 0)
        self.assertEqual(p.parse_result(0)['status'], 'observed')

    def test_missing_states(self):
        for value, status in [(None, 'not_assessed'), ('', 'not_assessed'), ('TBD', 'not_assessed'), ('UNKNOWN','not_available'), ('N/A', 'reported_na'), ('do not respond', 'not_available'), ('#VALUE!', 'error')]:
            self.assertEqual(p.parse_result(value)['status'], status)

    def test_percent_scales(self):
        self.assertEqual(p.parse_result(0.25, '0.0%')['numeric_value'], 25)
        self.assertEqual(p.parse_result('25.0%')['numeric_value'], 25)
        self.assertEqual(p.parse_result(25, variable='populated (%)')['numeric_value'], 25)
        self.assertEqual(p.parse_result('120%')['status'], 'needs_review')

    def test_no_numeric_guessing(self):
        self.assertIsNone(p.parse_result('PROCEDURE=40; OBSERVATION=0')['numeric_value'])
        self.assertEqual(p.parse_result(datetime(2026, 5, 16))['status'], 'needs_review')

    def test_safe_csv(self):
        for value in ['=1+2', '+SUM(A1:A4)', '-cmd', '@evil', '\t=1', '  =1']:
            self.assertTrue(p.safe_csv_value(value).startswith("'"))
        self.assertEqual(p.safe_csv_value(-1), -1)

    def test_identifier_validation(self):
        self.assertEqual(p.schema_name('OMOP_54'), '"OMOP_54"')
        for value in ['public;DROP TABLE person', 'a.b', 'a"b', '']:
            with self.assertRaises(ValueError):
                p.schema_name(value)

    def test_report_preserves_database_missing_statuses(self):
        from omop_fitness import reporting
        for status in ['denominator_zero', 'suppressed']:
            findings = reporting.assess([dict(site='Site_01', topic='Test', category='Test', variable='ratio', result='N/A', status=status)])
            self.assertEqual(findings[0]['severity'], 'review')
            self.assertEqual(findings[0]['assessment'], 'unavailable')
            self.assertNotEqual(findings[0]['title'], 'Validate the result status')

    def test_generated_report_has_no_title_border(self):
        from omop_fitness import reporting
        from docx import Document
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'report.docx'
            reporting.write_docx([dict(site='Site_01', topic='Test', category='Test', variable='Records', result='0', status='observed')], [], path)
            doc = Document(path)
            self.assertEqual(doc.styles['Title'].element.xpath('.//w:pBdr'), [])

    def test_query_lint(self):
        for sql in ['SELECT 1', "WITH a AS (SELECT 'DROP' x) SELECT * FROM a;", '-- comment\nSELECT 1;']:
            p.validate_sql(sql)
        for sql in ['DELETE FROM x', 'SELECT 1; SELECT 2;', 'WITH d AS (DELETE FROM x RETURNING *) SELECT * FROM d', 'SELECT * INTO x FROM y']:
            with self.assertRaises(ValueError):
                p.validate_sql(sql)

    def test_manifest_path_traversal(self):
        with tempfile.TemporaryDirectory() as d:
            m = Path(d) / 'manifest.json'
            m.write_text(json.dumps([dict(id='test',path='../out.sql')]))
            with self.assertRaises(ValueError):
                list(p.load_manifest(m))

    def test_trusted_manifest_rejects_paths_outside_sql(self):
        manifest = p.ROOT / "config" / "manifest.json"
        for unsafe in ("../README.md", "sql/../../README.md", str(p.ROOT / "README.md")):
            with self.subTest(path=unsafe), patch.object(p, "load_json", return_value=[dict(id="test", path=unsafe)]):
                with self.assertRaises(ValueError):
                    list(p.load_manifest(manifest))

    def test_external_manifest_rejects_absolute_path_and_parent_traversal(self):
        with tempfile.TemporaryDirectory() as d:
            manifest = Path(d) / "manifest.json"
            outside = Path(d).parent / "outside.sql"
            for unsafe in ("../outside.sql", str(outside)):
                with self.subTest(path=unsafe):
                    manifest.write_text(json.dumps([dict(id="test", path=unsafe)]), encoding="utf-8")
                    with self.assertRaises(ValueError):
                        list(p.load_manifest(manifest))

    def test_import_headers_sources_and_formulas(self):
        import openpyxl
        with tempfile.TemporaryDirectory() as d:
            w = openpyxl.Workbook()
            s = w.active
            s.title = 'Code Status'
            s.append(['Category', 'Variable', 'Example institution A', 'Example institution B'])
            s.append(['OBSERVATION', 'Records (n)', 0, None])
            s.append(['OBSERVATION', 'populated (%)', .25, 'N/A'])
            s['C3'].number_format = '0.0%'
            s.append(['OBSERVATION', 'Computed count', '=1+1', 'do not respond'])
            w.save(Path(d) / 'Code Status Data Expectations.xlsx')
            rows, metadata = p.import_workbooks(d)
            self.assertEqual(len(rows), 6)
            self.assertEqual(rows[0]['source_cell'], 'C2')
            self.assertEqual(rows[2]['numeric_value'], 25)
            self.assertEqual(rows[4]['status'], 'not_assessed')
            self.assertEqual(rows[4]['source_formula'], '=1+1')
            self.assertIn('sha256', metadata['sources'][0])


if __name__ == '__main__':
    unittest.main()
