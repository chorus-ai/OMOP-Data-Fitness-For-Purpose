"""Offline contract tests; do not represent PostgreSQL or real-OMOP execution."""
import hashlib, json, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from omop_fitness import historical_runner as h

class Scope:
    def __enter__(self): return self
    def __exit__(self,*a): return False

class Cursor(Scope):
    def __init__(self,conn): self.conn=conn; self.description=[]
    def execute(self,sql,params=None):
        self.conn.calls.append((sql,params))
        if 'information_schema.tables' in sql:
            self.rows=[(t,) for t in self.conn.tables]
        elif sql.startswith('SELECT set_config'): self.rows=[]
        else:
            if self.conn.fail: raise RuntimeError('password=secret_should_not_leak')
            self.description=[SimpleNamespace(name=x) for x in ['variable','result']]
            self.rows=[('Records (n)',str(self.conn.count))]
    def fetchall(self):return self.rows
    def fetchmany(self,n):return self.rows[:n]

class Connection:
    def __init__(self,count=12,fail=False):
        self.count=count;self.fail=fail;self.calls=[];self.closed=False;self.read_only=False
        self.tables=set(t for e in h.entries() for t in e['required_tables'])
    def transaction(self):return Scope()
    def cursor(self):return Cursor(self)
    def close(self):self.closed=True

class HistoricalTests(unittest.TestCase):
    def args(self,out,site='Site_01'):
        return dict(host='localhost',port=5432,dbname='synthetic',user='readonly',password='secret_should_not_leak',schema='omopcdm',site=site,output_dir=out,confirm_site_connection=True,include_pdf=False)
    def test_all_seven_topics_and_hashes(self):
        pack=h.entries();self.assertEqual(len(pack),18);self.assertEqual(len({e['topic'] for e in pack}),7)
        self.assertEqual(sum(e['status']=='source-preserving' for e in pack),6)
    def test_default_query_order_is_stable(self):
        self.assertEqual([entry["id"] for entry in h.entries()], [
            "microbiology_ast", "continuous_infusions", "mechanical_ventilation", "code_status", "fluid_balance", "dialysis_rrt",
            "transfusion_concept_discovery", "transfusion_procedure_occurrence", "transfusion_procedure_occurrence_semantic_inventory",
            "transfusion_drug_exposure", "transfusion_drug_exposure_semantic_inventory", "transfusion_device_exposure",
            "transfusion_device_exposure_semantic_inventory", "transfusion_measurement", "transfusion_measurement_semantic_inventory",
            "transfusion_observation", "transfusion_observation_semantic_inventory", "transfusion_procedure_occurrence_visit_validation",
        ])

    def test_exact_reversible_source_transformation(self):
        for e in h.entries():
            if e['status']=='source-preserving':
                reconstructed=e['_sql'].replace('{{schema}}.','omopcdm.')
                self.assertEqual(hashlib.sha256(reconstructed.encode('utf-8')).hexdigest(),e['source_sha256'])
    def test_ventilation_does_not_scan_measurement(self):
        e=next(e for e in h.entries() if e['id']=='mechanical_ventilation')
        self.assertNotIn('measurement',e['required_tables'])
    def test_real_execution_path_mock_and_isolation(self):
        with tempfile.TemporaryDirectory() as d:
            for i,count in [(1,12),(2,87)]:
                site=f'Site_{i:02d}';conn=Connection(count)
                result=h.run_screening(**self.args(Path(d)/site,site),connect=lambda **kw:conn)
                self.assertTrue(conn.read_only);self.assertTrue(conn.closed)
                self.assertEqual(len(result['executions']),18)
                self.assertTrue(all(e['status']=='completed' for e in result['executions']))
                rows=json.loads((Path(d)/site/'summary.json').read_text())
                self.assertTrue(all(r['site']==site and r['result']==str(count) for r in rows))
                files=''.join(p.read_text(encoding='utf-8') for p in (Path(d)/site).rglob('*') if p.suffix in ['.json','.csv'])
                self.assertNotIn('secret_should_not_leak',files)
                self.assertNotIn('Site_02' if i==1 else 'Site_01',files)
    def test_missing_tables_are_not_zero(self):
        with tempfile.TemporaryDirectory() as d:
            c=Connection();c.tables=set()
            result=h.run_screening(**self.args(Path(d)/'out'),connect=lambda **kw:c)
            self.assertEqual(result['status'],'partial')
            rows=json.loads((Path(d)/'out'/'summary.json').read_text())
            self.assertTrue(all(r['status']=='not_available' for r in rows))
    def test_errors_sanitized_and_not_success(self):
        with tempfile.TemporaryDirectory() as d:
            c=Connection(fail=True)
            result=h.run_screening(**self.args(Path(d)/'out'),connect=lambda **kw:c)
            self.assertEqual(result['status'],'partial')
            self.assertTrue(all(e['status']=='error' for e in result['executions']))
            self.assertNotIn('secret_should_not_leak',(Path(d)/'out'/'summary.json').read_text())
    def test_schema_injection_rejected_before_connection(self):
        with tempfile.TemporaryDirectory() as d:
            a=self.args(Path(d)/'out');a['schema']='omop; DROP TABLE person'
            with self.assertRaises(ValueError):h.run_screening(**a,connect=lambda **kw:self.fail('must not connect'))
    def test_explicit_scope_required(self):
        with tempfile.TemporaryDirectory() as d:
            a=self.args(Path(d)/'out');a['confirm_site_connection']=False
            with self.assertRaises(ValueError):h.run_screening(**a,connect=lambda **kw:self.fail('must not connect'))
    def test_existing_output_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d)/'keep').write_text('unchanged')
            with self.assertRaises(ValueError):h.run_screening(**self.args(d),connect=lambda **kw:self.fail('must not connect'))
            self.assertEqual((Path(d)/'keep').read_text(),'unchanged')

if __name__=='__main__':unittest.main()
