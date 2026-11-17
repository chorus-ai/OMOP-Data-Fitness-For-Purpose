"""Independent synthetic regression checks; no PostgreSQL or clinical validation.

Each registered contract is exercised through the actual runner normalizer. This
checks routing, output types and interpretation behaviour, not SQL execution.
"""
import unittest

from omop_fitness import historical_runner as runner
from omop_fitness.historical_interpretation import contract, findings_for_rows, interpret, load_registry


class ExactContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry = load_registry()
        cls.entries = {e['id']: e for e in runner.entries()}

    def row(self, spec, value, **extra):
        raw = {'variable': spec['variable'], 'result': value}
        if spec['query_id'].startswith('transfusion'):
            # Transfusion returns category, not section. Do not construct an
            # artificial section from the registry, which hid a routing bug.
            raw['category'] = spec['query_id'].replace('_', ' / ')
        else:
            raw['section'] = spec.get('section', '')
        if spec['query_id'] == 'continuous_infusions':
            raw['drug_name'] = 'Norepinephrine'
        raw.update(extra)
        return runner.normalize(raw, self.entries[spec['query_id']], 'Site_01')

    def pick(self, query, variable, section=None):
        matches = [s for s in self.registry.values() if s['query_id'] == query and s['variable'] == variable and (section is None or s.get('section', '') == section)]
        self.assertEqual(len(matches), 1)
        return matches[0]

    def test_inventory_exact_keys_and_active_scope(self):
        self.assertEqual(len(self.entries), 18)
        self.assertEqual(len(self.registry), 309)
        self.assertEqual({s['query_id'] for s in self.registry.values()}, set(self.entries))
        for spec in self.registry.values():
            with self.subTest(query=spec['query_id'], variable=spec['variable']):
                self.assertTrue(spec['definition'])
                self.assertTrue(spec['action'])
                if spec['kind'] == 'percent':
                    self.assertTrue(spec['denominator'])

    def test_all_contracts_survive_actual_normalization(self):
        examples = {'count': '7', 'percent': '40%', 'flag': 'YES', 'text': 'Synthetic descriptive text', 'distribution': '12.5'}
        for spec in self.registry.values():
            with self.subTest(query=spec['query_id'], section=spec.get('section'), variable=spec['variable']):
                row = self.row(spec, examples[spec['kind']])
                self.assertEqual(contract(row), spec)
                item = interpret(row)
                self.assertEqual(item['assessment'], 'descriptive')
                self.assertEqual(item['result'], row['result'])
                self.assertIn(spec['definition'], item['definition'])

    def test_all_zero_or_negative_flags_remain_measured(self):
        for spec in self.registry.values():
            if spec['kind'] not in ('count', 'percent', 'flag'):
                continue
            with self.subTest(query=spec['query_id'], variable=spec['variable']):
                value = 'NO' if spec['kind'] == 'flag' else '0%' if spec['kind'] == 'percent' else '0'
                item = interpret(self.row(spec, value))
                self.assertEqual(item['assessment'], 'descriptive')
                self.assertEqual(item['action'], spec.get('zero_action') or spec['action'])
                if spec['kind'] == 'count':
                    self.assertIn('does not prove clinical absence', item['interpretation'])

    def test_all_missing_results_are_not_zero(self):
        for spec in self.registry.values():
            for value in (None, '', 'N/A'):
                with self.subTest(query=spec['query_id'], variable=spec['variable'], value=value):
                    row = self.row(spec, value)
                    self.assertEqual(row['status'], 'reported_na' if value == 'N/A' else 'not_assessed')
                    item = interpret(row)
                    self.assertEqual(item['assessment'], 'unavailable')
                    self.assertIn('not zero', item['interpretation'])

    def test_all_numeric_and_flag_contracts_reject_invalid_values(self):
        bad = {'count': ('-1', '1.5', 'NaN', 'infinity', 'not a count'),
               'percent': ('-1%', '101%', 'NaN', 'infinity', 'not a percentage'),
               'flag': ('maybe', '2', 'unknown flag')}
        for spec in self.registry.values():
            for value in bad.get(spec['kind'], ()):
                with self.subTest(query=spec['query_id'], variable=spec['variable'], value=value):
                    self.assertNotEqual(interpret(self.row(spec, value))['assessment'], 'descriptive')

    def test_numeric_evidence_must_agree(self):
        spec = self.pick('microbiology_ast', 'Microbiology - positive blood cultures (%)')
        for extra in ({'numeric_value': 60}, {'numeric_value': True},
                      {'numerator': 100, 'denominator': 0},
                      {'numerator': 2, 'denominator': 2},
                      {'numerator': -1, 'denominator': 10},
                      {'numerator': 1, 'denominator': float('inf')}):
            with self.subTest(extra=extra):
                row = self.row(spec, '40%')
                row.update(extra)
                self.assertNotEqual(interpret(row)['assessment'], 'descriptive')
        row = self.row(spec, '33.33%', numerator=1, denominator=3)
        self.assertEqual(interpret(row)['assessment'], 'descriptive')

    def test_explicit_zero_denominator_distinct_from_na(self):
        spec = self.pick('transfusion_procedure_occurrence_visit_validation', 'orphan_visit_id')
        zero = self.row(spec, None, numerator=0, denominator=0)
        unknown = self.row(spec, 'N/A')
        self.assertEqual(zero['status'], 'denominator_zero')
        self.assertEqual(unknown['status'], 'reported_na')
        self.assertIn('undefined', interpret(zero)['action'])
        self.assertIn('do not assume', interpret(unknown)['action'])
        self.assertNotEqual(interpret(zero)['action'], interpret(unknown)['action'])

    def test_query_failure_unavailable_and_suppressed_stay_distinct(self):
        spec = self.pick('microbiology_ast', 'Microbiology - blood-culture records (n)')
        actions = set()
        for status in ('error', 'not_available', 'suppressed', 'not_assessed'):
            row = self.row(spec, '0'); row['status'] = status
            item = interpret(row)
            self.assertEqual(item['assessment'], 'unavailable')
            self.assertIn('not zero', item['interpretation'])
            actions.add(item['action'])
        self.assertEqual(len(actions), 4)

    def test_unknown_labels_fail_closed(self):
        # A plausible keyword-rich label must not reactivate heuristic rules.
        for variable in ('visit_occurrence_id populated (%)', 'Records (n)', 'Overlapping intervals (%)'):
            item = interpret({'query_id': 'unreviewed_query', 'variable': variable, 'result': '100%', 'status': 'observed'})
            self.assertEqual(item['assessment'], 'unmapped')
            self.assertIn('no automated', item['interpretation'])

    def test_specific_regressions_rate_joint_readiness_fact_flag(self):
        rate = self.pick('continuous_infusions', 'Dose-rate-like units among populated dose units (%)')
        item = interpret(self.row(rate, '50%'))
        self.assertIn(rate['denominator'], item['definition'])
        self.assertEqual(rate['kind'], 'percent')
        self.assertNotIn('of the eligible records have the field populated', item['interpretation'])
        joint = self.pick('fluid_balance', 'Records with numeric value + unit + datetime + visit (%)')
        self.assertEqual(joint['kind'], 'percent')
        self.assertIn('percentage', interpret(self.row(joint, '50%'))['interpretation'])
        fact = self.pick('microbiology_ast', 'Microbiology - FACT_RELATIONSHIP usage')
        self.assertEqual(fact['kind'], 'flag')
        self.assertIn('not detected', interpret(self.row(fact, 'NO'))['interpretation'])

    def test_code_status_section_specific_denominators(self):
        a = self.pick('code_status', 'visit_occurrence_id populated (%)', 'OBSERVATION')
        b = self.pick('code_status', 'visit_occurrence_id populated (%)', 'CONDITION_OCCURRENCE')
        self.assertNotEqual(a['denominator'], b['denominator'])
        self.assertNotEqual(interpret(self.row(a, '50%'))['definition'], interpret(self.row(b, '50%'))['definition'])
        row = self.row(a, '50%'); row['section'] = ''
        self.assertEqual(interpret(row)['assessment'], 'unmapped')

    def test_infusion_drug_context_is_retained(self):
        spec = self.pick('continuous_infusions', 'DRUG_EXPOSURE records (n)')
        a = self.row(spec, '7', drug_name='Norepinephrine')
        b = self.row(spec, '7', drug_name='Propofol')
        self.assertEqual(a['category'], 'Norepinephrine')
        self.assertEqual(b['category'], 'Propofol')
        self.assertEqual(a['section'], spec['section'])
        self.assertEqual(contract(a), contract(b))

    def test_canonical_findings_parity_for_every_contract(self):
        examples = {'count': '7', 'percent': '40%', 'flag': 'YES', 'text': 'Synthetic descriptive text', 'distribution': '12.5'}
        for spec in self.registry.values():
            with self.subTest(query=spec['query_id'], variable=spec['variable']):
                row = self.row(spec, examples[spec['kind']])
                item = interpret(row); finding = findings_for_rows([row])[0]
                for source, destination in [('definition', 'definition'), ('result', 'evidence'), ('interpretation', 'impact'), ('action', 'action'), ('source', 'source'), ('assessment', 'assessment')]:
                    self.assertEqual(item[source], finding[destination])
                self.assertEqual(finding['severity'], 'info')
                self.assertEqual(finding['site'], 'Site_01')


if __name__ == '__main__':
    unittest.main()
