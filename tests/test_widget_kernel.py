"""Real Jupyter kernel/widget comm and report rendering, synthetic DB adapter only."""
import json, sys, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent

class KernelTest(unittest.TestCase):
    def test_widget_button_to_report_in_kernel(self):
        import nbformat
        from nbclient import NotebookClient
        from jupyter_client import KernelManager
        from jupyter_client.kernelspec import KernelSpecManager
        with tempfile.TemporaryDirectory() as d:
            base=Path(d);spec=base/'kernels'/'python3';spec.mkdir(parents=True)
            (spec/'kernel.json').write_text(json.dumps({'argv':[sys.executable,'-m','ipykernel_launcher','-f','{connection_file}'],'display_name':'QA','language':'python'}))
            source=f'''
import sys, json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0,{str(ROOT)!r})
from omop_fitness import historical_runner as h
from tests.test_historical_runner import Connection
import IPython.display
original_display=IPython.display.display
boxes=[]
def capture(x):
    boxes.append(x);original_display(x)
with patch('IPython.display.display',side_effect=capture),patch('getpass.getpass',return_value='synthetic_only'),patch.dict('sys.modules',{{'psycopg':SimpleNamespace(connect=lambda **kw:Connection(41))}}):
    button=h.notebook_ui()
    box=boxes[0]
    box.children[1].value='synthetic'
    box.children[2].value='readonly'
    box.children[7].value={str(base/'results')!r}
    box.children[8].value=True
    button.click()
out=list(Path({str(base/'results')!r}).iterdir())[0]
assert (out/'feedback_report.docx').is_file()
assert (out/'feedback_report.pdf').is_file()
rows=json.loads((out/'summary.json').read_text())
assert all(r['site']=='Site_01' and r['result']=='41' for r in rows)
assert not button.disabled
print('KERNEL_WIDGET_REPORT_PASS_SYNTHETIC_DATABASE')
'''
            nb=nbformat.v4.new_notebook(cells=[nbformat.v4.new_code_cell(source)])
            manager=KernelManager(kernel_name='python3',kernel_spec_manager=KernelSpecManager(kernel_dirs=[str(spec.parent)]))
            try:
                NotebookClient(nb,km=manager,timeout=90,resources={'metadata':{'path':str(ROOT)}}).execute()
            finally:
                if manager.has_kernel:manager.shutdown_kernel(now=True)
            self.assertTrue(any('KERNEL_WIDGET_REPORT_PASS' in o.get('text','') for o in nb.cells[0].outputs))

if __name__=='__main__':unittest.main()
