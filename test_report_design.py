"""Typography and content-preservation tests using fictional values only."""
import tempfile
from pathlib import Path
import unittest
from docx import Document
from docx.oxml.ns import qn
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT
from reporting import write_docx, write_report_template
from historical_interpretation import interpret

class ReportDesignTests(unittest.TestCase):
    def row(self):
        return dict(site="Site_01", topic="microbiology_ast", query_id="microbiology_ast", variable="Microbiology - FACT_RELATIONSHIP usage", result="NO", status="observed", source_file="sql/historical/microbiology_ast.sql")

    def test_all_visible_text_uses_times_new_roman(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"report.docx"
            write_docx([self.row()],[],p,{"mode":"synthetic_demo"})
            doc=Document(p)
            paragraphs=list(doc.paragraphs)
            for section in doc.sections:
                paragraphs.extend(section.header.paragraphs)
                paragraphs.extend(section.footer.paragraphs)
            for table in doc.tables:
                for row in table.rows:
                    for cell in row.cells: paragraphs.extend(cell.paragraphs)
            for paragraph in paragraphs:
                for run in paragraph.runs:
                    if run.text.strip(): self.assertEqual(run.font.name,"Times New Roman")

    def test_tables_have_repeated_headers_and_top_aligned_cells(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"report.docx";write_docx([self.row()],[],p,{"mode":"synthetic_demo"})
            for table in Document(p).tables:
                self.assertIsNotNone(table.rows[0]._tr.get_or_add_trPr().find(qn("w:tblHeader")))
                self.assertFalse(table.autofit)
                for row in table.rows:
                    for cell in row.cells:self.assertEqual(cell.vertical_alignment,WD_CELL_VERTICAL_ALIGNMENT.TOP)

    def test_design_preserves_metric_and_interpretation_text(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"report.docx";row=self.row();write_docx([row],[],p,{"mode":"synthetic_demo"})
            text="\n".join(c.text for t in Document(p).tables for r in t.rows for c in r.cells)
            expected=interpret(row)
            for key in ("variable","definition","result","interpretation","action","source"):
                self.assertIn(expected[key],text)
            template=Path(d)/"template.docx";write_report_template(template)
            self.assertEqual(Document(template).styles["Normal"].font.name,"Times New Roman")

if __name__=="__main__":unittest.main()
