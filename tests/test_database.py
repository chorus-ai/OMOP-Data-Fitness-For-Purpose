from argparse import Namespace
from contextlib import contextmanager
from types import SimpleNamespace
import sys
import os
import unittest
from unittest.mock import patch

from omop_fitness import pipeline


class Cursor:
    def __init__(self, plan):
        self.plan = plan
        self.description = [SimpleNamespace(name=x) for x in ['category', 'variable', 'result', 'numerator', 'denominator']]
    def __enter__(self):
        return self
    def __exit__(self, *args):
        pass
    def execute(self, sql, params=None):
        if sql.startswith('SELECT set_config') or sql.startswith('SELECT table_name'):
            return
        if self.plan.get('error'):
            raise RuntimeError('Local error detail must not be exported')
    def fetchall(self):
        return [(x,) for x in self.plan.get('tables', ['concept', 'measurement'])]
    def fetchmany(self, cap):
        return self.plan.get('rows', [])[:cap]


class Connection:
    def __init__(self, plans):
        self.plans = iter(plans)
        self.read_only = False
        self.closed = False
    @contextmanager
    def transaction(self):
        self.plan = next(self.plans)
        yield self
    def cursor(self):
        assert self.read_only is True
        return Cursor(self.plan)
    def close(self):
        self.closed = True


class DatabaseTests(unittest.TestCase):
    def run_fixture(self, plans, suppression=0, cap=100):
        conn = Connection(plans)
        entries = [dict(id=f'q{i}', topic='Test', path='test.sql', sha256='test', _sql='SELECT 1', required_tables=['measurement']) for i in range(len(plans))]
        args = Namespace(schema='omopcdm', manifest='', query=None, dsn_env='TEST_NO_DSN', site='Site_01', timeout=1,
                         max_rows=cap, suppress_below=suppression, vocabulary_version='test', confirm_site_connection=True)
        with patch.dict(os.environ, {'TEST_NO_DSN': 'synthetic-fixture'}), patch.dict(sys.modules, {'psycopg': SimpleNamespace(connect=lambda *a, **k: conn)}), patch('omop_fitness.pipeline.select_entries', return_value=entries):
            rows, meta = pipeline.run_database(args)
        self.assertTrue(conn.closed)
        return rows, meta

    def test_failure_does_not_stop_later_queries(self):
        rows, meta = self.run_fixture([dict(error=True), dict(rows=[('Measurement','records','5',5,None)])])
        self.assertEqual([r['status'] for r in rows], ['error', 'observed'])
        self.assertNotIn('Local error detail', str(rows))
        self.assertEqual(meta['executions'][1]['status'], 'completed')

    def test_missing_table_distinct_from_empty_result(self):
        rows, _ = self.run_fixture([dict(tables=['concept']), dict(rows=[])])
        self.assertEqual([r['status'] for r in rows], ['not_available', 'not_assessed'])

    def test_zero_denominator_and_suppression(self):
        rows, _ = self.run_fixture([dict(rows=[('M','with unit (%)',None,0,0), ('M','records','3',3,None), ('M','ratio (%)','10%',3,30)])], suppression=5)
        self.assertEqual(rows[0]['status'], 'denominator_zero')
        self.assertEqual(rows[1]['status'], 'suppressed')
        self.assertEqual(rows[2]['status'], 'suppressed')
        for row in rows[1:]:
            self.assertIsNone(row['numerator'])
            self.assertIsNone(row['denominator'])
            self.assertIsNone(row['numeric_value'])

    def test_row_cap(self):
        rows, _ = self.run_fixture([dict(rows=[('M','count','1',1,None)]*3)], cap=2)
        self.assertEqual(rows[0]['status'], 'error')
        self.assertEqual(len(rows), 1)


if __name__ == '__main__':
    unittest.main()
