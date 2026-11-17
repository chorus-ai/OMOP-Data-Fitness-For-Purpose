"""Regression tests for direct CLI and export isolation boundaries."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from argparse import Namespace
from unittest.mock import patch

import pipeline


def row(site='Site_01', value='10'):
    return dict(site=site, category='Measurement', topic='Test', variable='Records (n)', result=value,
                status='observed', numeric_value=int(value), unit='', numerator=None, denominator=None,
                query_id='fixture', source_file='', source_sheet='', source_cell='', source_formula='', section='', note='')


class ExportIsolation(unittest.TestCase):
    def test_mixed_and_empty_export_rejected_before_writes(self):
        with tempfile.TemporaryDirectory() as d:
            for index, rows in enumerate(([], [row(), row('Site_02')])):
                out = Path(d) / str(index)
                with self.assertRaises(ValueError):
                    pipeline.export_outputs(rows, {}, out, no_docx=True)
                self.assertFalse(out.exists())

    def test_nested_foreign_metadata_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):
                pipeline.export_outputs([row()], {'scope': 'Site_02 results'}, Path(d)/'new', no_docx=True)

    def test_single_export_no_consolidated_subtree(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)/'new'
            pipeline.export_outputs([row()], {'mode': 'synthetic_demo'}, out, no_docx=True)
            self.assertFalse((out/'sites').exists())
            manifest=json.loads((out/'run_manifest.json').read_text())
            self.assertEqual(manifest['sites'], ['Site_01'])
            self.assertEqual(manifest['result_rows'], 1)
            self.assertEqual(json.loads((out/'summary.json').read_text()), [row()])

    def test_direct_export_rejects_private_output_in_code(self):
        out = pipeline.ROOT / "private_test_output_must_not_exist"
        self.assertFalse(out.exists())
        with self.assertRaises(ValueError):
            pipeline.export_outputs([row()], {"mode": "workbook_import"}, out, no_docx=True)
        self.assertFalse(out.exists())

    def test_cli_refuses_private_mapping_in_code_before_import(self):
        with tempfile.TemporaryDirectory() as d, patch("pipeline.import_workbooks") as importer:
            result = pipeline.main(["import-workbooks", "--site", "Site_01", "--input", d,
                                    "--output", str(Path(d)/"new"),
                                    "--private-site-map", str(pipeline.ROOT/"site_mapping.json")])
            self.assertEqual(result, 1)
            importer.assert_not_called()
            self.assertFalse((pipeline.ROOT/"site_mapping.json").exists())

    def test_database_no_confirmation_or_credentials_fails_before_connect(self):
        import sys
        from types import SimpleNamespace
        args=Namespace(site='Site_01', schema='omopcdm', dsn_env=None, confirm_site_connection=False,
                       manifest='',query=None,topic=None)
        with patch.dict(sys.modules, {'psycopg': SimpleNamespace(connect=lambda *a,**k: self.fail('Unexpected connection'))}), patch('pipeline.select_entries',return_value=[]), patch.dict(os.environ, {},clear=True):
            with self.assertRaises(ValueError): pipeline.run_database(args)
            args.confirm_site_connection=True
            with self.assertRaises(ValueError): pipeline.run_database(args)


if __name__=='__main__':
    unittest.main()
