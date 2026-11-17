"""Static SQL/manifest checks; these do not replace PostgreSQL execution tests.

Run: python -m unittest tests.test_sql_contract
Optional full PostgreSQL syntax parsing: install pglast in a QA environment.
"""
from pathlib import Path
import json
import re
import sqlite3
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from omop_fitness.pipeline import validate_sql

try:
    from pglast import parse_sql
except ImportError:
    parse_sql = None


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, (tuple, list)):
        for child in value:
            yield from walk(child)


class SQLContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entries = json.loads((ROOT / 'config/manifest.json').read_text(encoding='utf-8'))

    def test_unique_ids_and_seven_topics(self):
        self.assertEqual(len(self.entries), len({q['id'] for q in self.entries}))
        self.assertEqual({q['topic'] for q in self.entries}, {
            'transfusion', 'microbiology_ast', 'continuous_infusions',
            'mechanical_ventilation', 'code_status', 'fluid_balance', 'dialysis_rrt'})

    def test_manifest_paths_and_static_safety(self):
        for q in self.entries:
            with self.subTest(query=q['id']):
                path = (ROOT / q['path']).resolve()
                self.assertTrue(path.is_relative_to(ROOT / 'sql'))
                self.assertNotIn('legacy', path.parts)
                text = path.read_text(encoding='utf-8')
                self.assertTrue('{{schema}}' in text)
                self.assertEqual(set(re.findall(r'\{\{.*?\}\}', text)), {'{{schema}}'})
                self.assertTrue(all(re.fullmatch('[a-z_]+', t) for t in q['required_tables']))
                validate_sql(text.replace('{{schema}}', '"omopcdm"'))

    @unittest.skipIf(parse_sql is None, 'pglast is not installed: syntax parsing not run')
    def test_postgres_ast_and_result_contract(self):
        expected = ['category', 'variable', 'result', 'numerator', 'denominator']
        for q in self.entries:
            with self.subTest(query=q['id']):
                text = (ROOT / q['path']).read_text(encoding='utf-8').replace('{{schema}}', '"omopcdm"')
                parsed = parse_sql(text)
                self.assertEqual(len(parsed), 1)
                stmt = parsed[0]()['stmt']
                self.assertEqual(stmt['@'], 'SelectStmt')
                names = [t['name'] or t['val']['fields'][-1]['sval'] for t in stmt['targetList']]
                self.assertEqual(names, expected)
                nodes = list(walk(stmt))
                for node in nodes:
                    self.assertNotIn(node.get('@'), ['InsertStmt', 'UpdateStmt', 'DeleteStmt', 'MergeStmt', 'CopyStmt', 'CallStmt'])
                    if node.get('@') == 'SelectStmt':
                        self.assertIsNone(node.get('intoClause'))
                        self.assertIsNone(node.get('lockingClause'))
                tables = {n['relname'] for n in nodes if n.get('@') == 'RangeVar' and n.get('schemaname') == 'omopcdm'}
                self.assertEqual(tables, set(q['required_tables']))

    def test_legacy_references_disabled(self):
        self.assertTrue(all('legacy' not in q['path'] for q in self.entries))
        path = ROOT / 'sql/legacy/legacy_manifest.json'
        if not path.exists():
            return  # Private source references are excluded from the distributable package.
        legacy = json.loads(path.read_text(encoding='utf-8'))
        self.assertGreaterEqual(len(legacy), 5)
        for q in legacy:
            self.assertIs(q['enabled'], False)
            self.assertIs(q['requires_review'], True)
            self.assertTrue((ROOT / q['path']).is_file())
            self.assertTrue((ROOT / q['original_path']).is_file())

    def test_rate_and_median_contract(self):
        from sql.build_queries import ratio_row
        rate = ratio_row('completeness', 'complete_n', 'n')
        self.assertIn("THEN NULL::text", rate)
        self.assertIn("|| '%'", rate)
        median_sql = (ROOT / 'sql/continuous_infusions_drug_exposure.sql').read_text(encoding='utf-8')
        self.assertIn("('median_positive_duration_minutes', ROUND(median_minutes,2)::text, NULL::numeric, NULL::numeric)", median_sql)

    def test_dialysis_classification_synthetic_labels(self):
        """Evaluate the production CASE with Python regex in an in-memory SQL harness.

        This covers the ASCII fixtures, not PostgreSQL execution or all possible
        vocabulary names. The native PostgreSQL fixture is supplied separately.
        """
        from sql.build_queries import TOPICS
        cases = json.loads((ROOT / 'sql/fixtures/dialysis_classifier_cases.json').read_text(encoding='utf-8'))

        def pattern_for_python(pattern):
            return pattern.replace('[[:space:]-]', r'[\s-]')

        def regexp(pattern, value):
            return re.search(pattern_for_python(pattern), value, flags=re.IGNORECASE) is not None

        def regexp_replace(value, pattern, replacement, flags):
            return re.sub(pattern_for_python(pattern), replacement, value,
                          count=0 if 'g' in flags else 1,
                          flags=re.IGNORECASE if 'i' in flags else 0)

        case_expression = TOPICS['dialysis_rrt']['kind'].replace('~*', 'REGEXP')
        with sqlite3.connect(':memory:') as conn:
            conn.create_function('regexp', 2, regexp)
            conn.create_function('regexp_replace', 4, regexp_replace)
            for case in cases:
                with self.subTest(concept_name=case['concept_name']):
                    actual = conn.execute('SELECT ' + case_expression +
                                          ' FROM (SELECT ? AS concept_name) c',
                                          (case['concept_name'],)).fetchone()[0]
                    self.assertEqual(actual, case['expected_kind'])

    def test_generated_dialysis_classifier_matches_generator(self):
        from sql.build_queries import TOPICS
        case_expression = TOPICS['dialysis_rrt']['kind']
        for entry in self.entries:
            if entry['topic'] == 'dialysis_rrt':
                with self.subTest(query=entry['id']):
                    self.assertIn(case_expression, (ROOT / entry['path']).read_text(encoding='utf-8'))
        fixture = (ROOT / 'sql/fixtures/dialysis_classifier_regression.sql').read_text(encoding='utf-8')
        self.assertIn(case_expression, fixture)

    @unittest.skipIf(parse_sql is None, 'pglast is not installed: fixture syntax parsing not run')
    def test_dialysis_regression_fixture_postgres_syntax(self):
        fixture = (ROOT / 'sql/fixtures/dialysis_classifier_regression.sql').read_text(encoding='utf-8')
        parsed = parse_sql(fixture)
        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]()['stmt']['@'], 'SelectStmt')


if __name__ == '__main__':
    unittest.main(verbosity=2)
