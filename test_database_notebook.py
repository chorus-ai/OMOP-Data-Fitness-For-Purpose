import json, unittest, tempfile
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace
import historical_runner as h

class NotebookTests(unittest.TestCase):
    def setUp(self):
        # Headless unit test only: a kernel normally supplies the comm transport.
        from comm.base_comm import BaseComm
        class DummyComm(BaseComm):
            def publish_msg(self, *args, **kwargs): pass
        self.transport=patch('comm.create_comm',side_effect=DummyComm)
        self.transport.start()
        self.addCleanup(self.transport.stop)
    def test_notebook_clean_and_compile(self):
        n=json.loads((h.ROOT/'Run_site_assessment.ipynb').read_text(encoding='utf-8'))
        for c in n['cells']:
            if c['cell_type']=='code':
                self.assertEqual(c.get('outputs'),[])
                self.assertIsNone(c.get('execution_count'))
                compile(''.join(c['source']),'notebook','exec')
    def test_ui_does_not_connect_until_explicit_click(self):
        with patch('IPython.display.display') as disp,patch('historical_runner.run_screening') as run:
            button=h.notebook_ui()
            run.assert_not_called()
            box=disp.call_args.args[0]
            self.assertEqual([x.description for x in box.children[:5]],['host','dbname','user','schema','site'])
            button.click();run.assert_not_called();self.assertFalse(button.disabled)
    def test_click_passes_selection_and_password_not_widget(self):
        with patch('IPython.display.display') as disp,patch('getpass.getpass',return_value='test_secret'),patch('historical_runner.run_screening',return_value={'status':'partial','executions':[],'output_dir':'private'}) as run:
            button=h.notebook_ui();box=disp.call_args.args[0]
            box.children[1].value='study';box.children[2].value='readonly';box.children[3].value='site_schema';box.children[8].value=True
            button.click()
            self.assertEqual(run.call_args.kwargs['user'],'readonly')
            self.assertEqual(run.call_args.kwargs['schema'],'site_schema')
            self.assertEqual(run.call_args.kwargs['password'],'test_secret')
            self.assertFalse(button.disabled)
            self.assertNotIn('test_secret',repr(box))
    def test_button_to_site_report_with_fake_database(self):
        from test_historical_runner import Connection
        with tempfile.TemporaryDirectory() as d, patch('IPython.display.display') as disp, patch('getpass.getpass',return_value='test_secret'), patch.dict('sys.modules',{'psycopg':SimpleNamespace(connect=lambda **kw:Connection(23))}):
            button=h.notebook_ui();box=disp.call_args.args[0]
            box.children[1].value='synthetic';box.children[2].value='readonly'
            box.children[7].value=d;box.children[8].value=True
            button.click()
            folders=list(Path(d).iterdir());self.assertEqual(len(folders),1)
            self.assertTrue((folders[0]/'feedback_report.docx').exists())
            self.assertTrue((folders[0]/'feedback_report.pdf').exists())
            rows=json.loads((folders[0]/'summary.json').read_text())
            self.assertTrue(all(r['site']=='Site_01' and r['result']=='23' for r in rows))
            self.assertFalse(button.disabled)

if __name__=='__main__':unittest.main()
