"""Exact SQL-output contracts. No label-keyword inference or clinical fitness score."""
import json
import math
from pathlib import Path

RULE_VERSION = "3.1.0"
from .paths import CONFIG


def load_registry():
    registry = {}
    for path in sorted(CONFIG.glob('registry_*.json')):
        for spec in json.loads(path.read_text(encoding='utf-8')):
            key = (spec['query_id'], spec.get('section', ''), spec['variable'])
            if key in registry:
                raise ValueError('Duplicate metric contract: ' + repr(key))
            registry[key] = spec
    return registry


def contract(row):
    registry = load_registry()
    query = str(row.get('query_id') or '')
    section = str(row.get('section') or '')
    variable = str(row.get('variable') or '')
    return registry.get((query, section, variable)) or registry.get((query, '', variable))


def numeric_conflict(row, kind, number, precision_decimals=None):
    if isinstance(row.get('numeric_value'), bool) or isinstance(row.get('result'), bool):
        return kind in ('count', 'percent')
    if kind not in ('count', 'percent'):
        return False
    try:
        raw = float(str(row.get('result', '')).strip().rstrip('%').replace(',', ''))
        if number is not None and not math.isclose(raw, number, rel_tol=1e-9, abs_tol=1e-9):
            return True
    except (TypeError, ValueError):
        return True
    vals = {}
    for key in ('numerator', 'denominator'):
        value = row.get(key)
        if value is not None:
            try:
                n = float(value)
                if isinstance(value, bool) or not math.isfinite(n) or n < 0:
                    return True
                vals[key] = n
            except (TypeError, ValueError):
                return True
    if kind == 'percent':
        den, num = vals.get('denominator'), vals.get('numerator')
        if den == 0:
            return True
        if den is not None and num is not None:
            if num > den or (number is not None and abs(number - 100 * num / den) > (0.5 * 10 ** -precision_decimals + 1e-9 if precision_decimals is not None else 1e-9)):
                return True
    return False


def interpret(row):
    variable = str(row.get('variable', ''))
    result = str(row.get('result', ''))
    status = str(row.get('status') or 'observed')
    spec = contract(row)
    definition = spec['definition'] if spec else 'No reviewed exact SQL-output contract matches this query, section and variable.'
    denominator = spec.get('denominator', '') if spec else ''
    if denominator:
        definition += ' Denominator: ' + denominator
    meaning = 'Unmapped output: no automated data-quality interpretation is assigned.'
    action = 'Match this output to its source SQL and add a reviewed metric contract before using it for conclusions.'
    assessment = 'unmapped'
    number = row.get('numeric_value')
    try:
        number = float(number) if number is not None else float(result.strip().rstrip('%').replace(',', ''))
    except (TypeError, ValueError):
        number = None
    unavailable = status not in ('observed', 'ok', 'success') or result.strip().lower() in ('', 'n/a', 'na', 'null') or (result.strip().lower() == 'none' and not (spec and spec['kind'] == 'text'))
    if unavailable:
        assessment = 'unavailable'
        meaning = 'Status: ' + status + '. No interpretable measured result is available; this is not zero.'
        action = {
            'error': 'Resolve the recorded query failure and rerun this query; other successful queries do not establish coverage of this check.',
            'not_available': 'Check the recorded missing-table or permission reason and source availability, then rerun; do not infer absence of clinical events.',
            'denominator_zero': 'The supplied denominator is zero, so this percentage is undefined. Retain the zero eligible count separately.',
            'suppressed': 'Retain suppression and follow the site disclosure policy; do not reconstruct the withheld aggregate.',
            'not_assessed': 'This check has no measured result. Run it or document why it cannot be assessed.',
        }.get(status, 'Resolve the reported missing or N/A value from the source output; do not assume a zero denominator or substitute zero.')
    elif spec:
        assessment = 'descriptive'
        kind = spec['kind']
        invalid = number is not None and (not math.isfinite(number) or (kind == 'percent' and not 0 <= number <= 100) or (kind == 'count' and (number < 0 or not number.is_integer())))
        invalid = invalid or numeric_conflict(row, kind, number, spec.get("precision_decimals"))
        if kind in ('count', 'percent', 'distribution') and number is None:
            invalid = True
        if kind == 'flag' and result.strip().lower() not in ('yes', 'no', 'true', 'false', '1', '0'):
            invalid = True
        if invalid:
            assessment = 'invalid'
            meaning = 'Result violates this metric\'s numeric/type contract; no data-quality interpretation is assigned.'
            action = 'Check the raw export, unit and source calculation, then correct or rerun this metric.'
        else:
            action = spec['action']
            if kind == 'count':
                meaning = 'Query-selected count: ' + result + '. This is not independently validated clinical prevalence or episode count.'
                if number == 0:
                    meaning = 'No matching items were captured by this SQL selection; this does not prove clinical absence.'
            elif kind == 'percent':
                meaning = 'Query-defined percentage: ' + result + '. Applies only to the denominator stated here, not all patients or events.'
                if number == 0:
                    meaning += ' This is a rounded reported percentage; an exact zero numerator cannot be inferred without the underlying counts.'
                elif number == 100:
                    meaning += ' This is a rounded reported percentage; exact coverage of every eligible row cannot be inferred without the underlying counts. It is not proof of clinical validity or overall fitness.'
            elif kind == 'flag':
                absent = result.strip().lower() in ('no', 'false', '0')
                meaning = ('The queried representation was not detected.' if absent else 'The queried representation was detected; this flag does not measure completeness or validity.')
                if absent:
                    action = spec.get('zero_action') or action
            else:
                meaning = 'Query-defined descriptive output: ' + result + '. This is not a clinical reference range or a validated fitness decision.'
            if number == 0:
                action = spec.get('zero_action') or action
            if spec.get('notes'):
                meaning += ' ' + spec['notes']
    if spec and status == 'needs_review' and spec['kind'] in ('count', 'percent') and (number is None or not math.isfinite(number) or (spec['kind'] == 'percent' and not 0 <= number <= 100) or (spec['kind'] == 'count' and (number < 0 or not number.is_integer())) or numeric_conflict(row, spec['kind'], number, spec.get('precision_decimals'))):
        assessment = 'invalid'
        meaning = 'The supplied result violates the exact metric type/range contract; no data-quality interpretation is assigned.'
        action = 'Check the raw export, unit and source calculation, then correct or rerun this metric.'
    evidence = spec.get('evidence', {}) if spec else {}
    return {'variable': variable, 'definition': definition, 'result': result,
            'evidence_basis': evidence.get('recommendation_basis', ''),
            'evidence_sources': ' | '.join(evidence.get('public_sources', [])),
            'evidence_limit': evidence.get('support_limit', ''),
            'calculation_source': evidence.get('sql_path', ''),
            'interpretation': meaning, 'action': action, 'assessment': assessment,
            'source': ' | '.join(str(row.get(k) or '') for k in ('source_file', 'source_sheet', 'source_cell', 'query_id') if row.get(k))}


def findings_for_rows(rows):
    result = []
    for row in rows:
        x = interpret(row)
        result.append({'site': row['site'], 'topic': row.get('topic', ''),
                       'severity': 'info' if x['assessment'] == 'descriptive' else 'review',
                       'title': x['variable'], 'definition': x['definition'],
                       'result': x['result'], 'status': row.get('status', ''), 'assessment': x['assessment'],
                       'evidence': x['result'], 'impact': x['interpretation'],
                       'action': x['action'], 'source': x['source'],
                       'evidence_basis': x['evidence_basis'], 'evidence_sources': x['evidence_sources'],
                       'evidence_limit': x['evidence_limit'], 'calculation_source': x['calculation_source']})
    return result
