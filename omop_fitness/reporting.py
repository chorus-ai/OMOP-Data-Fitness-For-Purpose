"""Evidence-led feedback and compact DOCX reports for OMOP screening results.

No readiness score, clinical phenotype classification, or inferred denominator is
produced. Percentages use percentage points (0..100), not fractions. Findings
are reproducible, based on metric names and explicit result values. The row
contract and rule boundaries are documented in README_REPORT.md.
"""
from __future__ import annotations

from collections import Counter, defaultdict
from datetime import datetime, timezone
import math
from pathlib import Path
import re
from typing import Any, Iterable

SEVERITY_ORDER = {"high": 0, "review": 1, "info": 2}
STATUS_ORDER = ("observed", "not_assessed", "not_available", "reported_na", "denominator_zero", "suppressed", "needs_review", "error")
from .historical_interpretation import RULE_VERSION
from .paths import ROOT
SITE_ALIAS = re.compile(r"Site_[0-9]{2,}\Z")
SITE_REFERENCE = re.compile(r"Site_[0-9]{2,}", re.IGNORECASE)
SITE_METADATA_KEYS = {
    "site", "site_id", "site_alias", "site_label", "sites", "site_ids",
    "site_aliases", "site_labels", "selected_site", "expected_site",
}


def assert_report_scope(rows: list[dict], findings: list[dict] | None = None,
                        metadata: dict | None = None) -> str:
    """Reject empty, invalid or mixed site evidence before report output."""
    if not rows:
        raise ValueError("A report requires nonempty evidence for exactly one Site_XX alias.")
    aliases = set()
    for label, records in (("rows", rows), ("findings", findings or [])):
        for record in records:
            if not isinstance(record, dict):
                raise ValueError(f"Each {label} entry must be a dictionary.")
            site = record.get("site")
            if not isinstance(site, str) or not SITE_ALIAS.fullmatch(site):
                raise ValueError(f"Each {label} entry requires a valid Site_XX alias.")
            aliases.add(site)
    if len(aliases) != 1:
        raise ValueError("Rows and findings must refer to exactly one Site_XX alias.")
    expected = next(iter(aliases))

    def check_alias(value):
        if not isinstance(value, str) or not SITE_ALIAS.fullmatch(value) or value != expected:
            raise ValueError("Site metadata must match the report's single Site_XX alias.")

    def walk(value, site_field=False):
        if site_field:
            if isinstance(value, (list, tuple, set)):
                for item in value:
                    check_alias(item)
                return
            check_alias(value)
            return
        if isinstance(value, dict):
            for key, item in value.items():
                walk(key)
                walk(item, isinstance(key, str) and key.lower() in SITE_METADATA_KEYS)
        elif isinstance(value, (list, tuple, set)):
            for item in value:
                walk(item)
        elif isinstance(value, str):
            for alias in SITE_REFERENCE.findall(value):
                if alias.lower() != expected.lower():
                    raise ValueError("Another site's alias occurs in the selected report content.")

    walk(rows)
    walk(findings or [])
    walk(metadata or {})
    return expected


def _has_rrt_context(value: str) -> bool:
    # Billing descriptions often say "health care professional" even for a
    # direct treatment procedure; that phrase is not contextual dialysis care.
    text = re.sub(r"\bhealth[\s-]*care[\s-]+(?:professionals?|providers?|practitioners?)\b", " ", value.lower())
    return bool(re.search(
        r"\b(?:access|cannula|dependence|catheter|fistula|preoperative|comments?|"
        r"(?:re)?assess(?:ment|ments|ed|ing)?|monitor(?:ing|ed|s)?|care|aftercare|"
        r"history|status|clearance|flow|pressure)\b|\bkt\s*/\s*v\b",
        text))

SQL_METRIC_ALIASES = {
    "candidate_records": "Candidate records (n)",
    "input_candidate_records": "Fluid intake candidate records (n)",
    "output_candidate_records": "Fluid output candidate records (n)",
    "with_datetime": "Event datetime populated (%)",
    "with_complete_datetime_pair": "Start and end datetime both populated (%)",
    "with_visit_id": "visit_occurrence_id populated (%)",
    "with_visit_detail_id": "visit_detail_id populated (%)",
    "chronologically_valid": "Chronologically valid intervals among complete (%)",
    "duration_zero": "Zero-duration intervals among complete intervals (%)",
    "overlapping_adjacent_pairs": "Adjacent intervals overlapping (%)",
    "with_quantity": "quantity populated (%)",
    "with_standard_route": "Standardized route populated (%)",
    "source_iv_standard_route_mismatch": "Source indicates IV but standardized route is not IV (%)",
    "candidate_numeric_dose_rate": "Candidate numeric rate: quantity + dose-rate-like unit (%)",
    "candidate_numeric_volume_rate": "Candidate numeric rate: quantity + volume-rate-like unit (%)",
    "candidate_rate_interval_visit_jointly_complete": "Rate and interval and visit prerequisites populated (%)",
    "drug_types_observed_top20": "Drug exposure type concepts observed",
    "patient_visit_days_with_both_input_output": "Patient-visit-days with both numeric intake and output (%)",
    "both_input_output_days_with_weight": "Fluid-data visits with any body-weight measurement populated (%)",
}


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _norm(value: Any) -> str:
    return re.sub(r"\s+", " ", _text(value).lower().replace("\u2011", "-").replace("\u2013", "-"))


def _num(value: Any) -> float | None:
    if value is None or isinstance(value, (bool, datetime)):
        return None
    try:
        n = float(str(value).strip().replace(",", ""))
        return n if math.isfinite(n) else None
    except (TypeError, ValueError):
        return None


def _value(row: dict) -> float | None:
    numerator, denominator = _num(row.get("numerator")), _num(row.get("denominator"))
    if numerator is not None and denominator is not None:
        return 100 * numerator / denominator if denominator > 0 else None
    n = _num(row.get("numeric_value"))
    if n is not None:
        return n
    raw = _text(row.get("result"))
    if re.fullmatch(r"[-+]?\d[\d,]*(?:\.\d+)?\s*%?", raw):
        return _num(raw.replace("%", ""))
    return None


def _is_pct(row: dict) -> bool:
    return "%" in _text(row.get("variable")) or _norm(row.get("unit")) in ("%", "percent", "percentage") or (row.get("numerator") is not None and row.get("denominator") is not None)


def _source(row: dict) -> str:
    # PureWindowsPath would be platform-specific; splitting both separators
    # preserves useful file names when reports run on Linux against Windows data.
    name = re.split(r"[\\/]", _text(row.get("source_file")))[-1]
    sheet = _text(row.get("source_sheet"))
    cell = _text(row.get("source_cell"))
    query = _text(row.get("query_id"))
    return "; ".join(x for x in (name, (sheet + ("!" + cell if cell else "")) if sheet else cell, "query " + query if query else "") if x) or "Source locator not supplied"


def _evidence(row: dict) -> str:
    result = _text(row.get("result")) or "[blank]"
    context = _text(row.get("category"))
    text = (context + " | " if context else "") + f"{_text(row.get('variable'))}: {result}"
    if row.get("denominator") is not None:
        text += f"; denominator={row['denominator']}"
    if row.get("numerator") is not None:
        text += f"; numerator={row['numerator']}"
    return text


def _finding(row: dict, severity: str, title: str, impact: str, action: str, evidence: str | None = None) -> dict:
    return {"site": _text(row.get("site")) or "Unspecified site", "topic": _text(row.get("topic")) or "Unspecified topic",
            "severity": severity, "title": title, "evidence": evidence or _evidence(row),
            "impact": impact, "action": action, "source": _source(row)}


def _domain(row: dict) -> str:
    text = " ".join(_norm(row.get(k)).replace("_", " ") for k in ("topic", "source_sheet", "category", "variable"))
    if any(x in text for x in ("microbi", "blood-culture", "blood culture", "susceptibility")):
        return "Microbiology"
    if any(x in text for x in ("continuous", "infusion", "norepinephrine", "propofol")) or _norm(row.get("source_sheet")) == "cdi":
        return "Continuous infusion"
    if any(x in text for x in ("code status", "code-status")):
        return "Code status"
    if any(x in text for x in ("dialysis", "rrt", "fluid-removal", "actual-removal")):
        return "Renal replacement therapy"
    if any(x in text for x in ("fluid balance", "fluid intake", "fluid output", "intake and output")):
        return "Fluid balance"
    if any(x in text for x in ("ventilat", "intubation", "extubation")):
        return "Mechanical ventilation"
    if "transfusion" in text:
        return "Transfusion"
    return "Other screening"


def assess(rows: Iterable[dict]) -> list[dict]:
    """Deprecated compatibility entry point; use the same exact-contract engine as exports."""
    rows = list(rows)
    assert_report_scope(rows)
    from .historical_interpretation import findings_for_rows
    return findings_for_rows(rows)


def _short(text: Any, limit: int) -> str:
    text = re.sub(r"\s+", " ", _text(text))
    return text if len(text) <= limit else text[:limit - 3].rsplit(" ", 1)[0] + "..."


def _group_findings(findings: list[dict]) -> list[list[dict]]:
    grouped: dict[str, list[dict]] = defaultdict(list)
    for f in findings:
        grouped[f["title"]].append(f)
    semantic_priority = {
        "Verify the source value before analysis": 0,
        "Resolve the failed screening metric": 1,
        "Repair discordant intravenous route mapping": 2,
        "Remove nonvolume concepts from fluid removal": 3,
        "Exclude intake assessments from measured volume": 4,
        "Separate direct RRT events from contextual evidence": 5,
        "Check DNI and DNR semantic separation": 6,
        "Repair reversed event intervals": 7,
    }
    return sorted(grouped.values(), key=lambda g: (min(SEVERITY_ORDER.get(f["severity"], 3) for f in g), semantic_priority.get(g[0]["title"], 20), -len(g), g[0]["title"]))


DOMAIN_NOTES = {
    "Continuous infusion": "For norepinephrine rate-change timestamps within a visit, verify the source rate or change-event representation, its timestamp and visit link. Point events can be usable; a positive duration is not required. Review overlapping order versions before ordering changes. Numeric dose conversion, concentration and timed weight are needed only if a separate dose calculation is intended. These aggregates screen prerequisites; they do not reconstruct rate-change times.",
    "Microbiology": "Culture tests, specimens, organism identification and susceptibility results are distinct objects. Separate primary cultures from reflex molecular panels, define result-level positivity and a specimen/episode denominator, and verify relevant links before comparison. This query does not validate the complete linkage chain or all local linkage mechanisms.",
    "Renal replacement therapy": "For RRT exposure or session analysis, review candidate treatment events separately from access placement, imaging, dependence, care and comments. Distinguish actual removal, targets and rates in the source. Broad dialysis matches alone do not validate modality or clinical indication; indication analysis requires its own clinically reviewed, time-aligned specification. These are review prerequisites, not findings about this site.",
    "Fluid balance": "For net-balance calculations, align intake and output by patient, visit and defined time window. Distinguish incremental volumes, rates and cumulative totals; use qualitative observations as context rather than numeric volumes. Specify day boundaries, coverage, missing-period handling and overlap rules before subtraction. Observing both sides alone does not demonstrate complete recording. These are analytical prerequisites, not findings about this site.",
    "Mechanical ventilation": "Procedures, intubation/extubation and ventilator-device records are distinct candidate signals. Review event meaning and timestamps before defining ventilation episodes; assess modality and ICU linkage only if required by the intended analysis. This query does not assess MEASUREMENT-based ventilator settings or establish continuous invasive ventilation duration.",
    "Code status": "For longitudinal code-status analysis, preserve full code, DNR, DNI, combined limitations and unresolved categories where supported by source semantics. A pre-coordinated observation can convey status without a separate result; inspect the concept and available value fields before judging a generic observation uninterpretable. Review effective time, reversals and historical versus active orders before constructing trajectories. These are review prerequisites, not findings about this site.",
    "Transfusion": "Validate component and product mappings across relevant OMOP domains. A transfusion record or procedure count is not a count of bags, units or millilitres. Establish administered quantity, unit, event time and encounter linkage separately, and distinguish orders from actual administration.",
}


def _new_document(title: str):
    """Apply the shared report typography and neutral document properties."""
    from docx import Document
    from docx.oxml.ns import qn
    from docx.shared import Inches, Pt, RGBColor
    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Inches(8.5), Inches(11)
    sec.top_margin = sec.bottom_margin = Inches(0.7)
    sec.left_margin = sec.right_margin = Inches(0.75)
    for name in ("Normal", "Title", "Subtitle", "Heading 1", "Heading 2", "Heading 3"):
        style = doc.styles[name]
        style.font.name = "Times New Roman"
        for script in ("ascii", "hAnsi", "eastAsia", "cs"):
            style.element.get_or_add_rPr().get_or_add_rFonts().set(qn("w:" + script), "Times New Roman")
        style.font.color.rgb = RGBColor(0, 0, 0)
    for style in doc.styles:
        for border in list(style.element.iter(qn('w:pBdr'))):
            border.getparent().remove(border)
    normal = doc.styles["Normal"]
    normal.font.size = Pt(11)
    normal.paragraph_format.space_after = Pt(6)
    normal.paragraph_format.line_spacing = 1.12
    doc.styles["Title"].font.size = Pt(22)
    doc.styles["Title"].paragraph_format.space_after = Pt(10)
    for name, size in (("Heading 1", 15), ("Heading 2", 12)):
        doc.styles[name].font.size = Pt(size)
        doc.styles[name].paragraph_format.space_before = Pt(12)
        doc.styles[name].paragraph_format.space_after = Pt(5)
        doc.styles[name].paragraph_format.keep_with_next = True
    doc.core_properties.title = title
    doc.core_properties.subject = "Evidence-led screening feedback"
    doc.core_properties.author = ""
    doc.core_properties.last_modified_by = ""
    doc.core_properties.keywords = ""
    doc.core_properties.comments = ""
    doc.core_properties.created = datetime.now(timezone.utc)
    doc.core_properties.modified = datetime.now(timezone.utc)
    return doc


def _format_report_tables(doc):
    """Consistent, readable tables for every generated report and blank template."""
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.shared import Inches, Pt, RGBColor
    from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    for table in doc.tables:
        count = len(table.columns)
        widths = (2.25, 0.65, 4.10) if count == 3 else (1.5, 1.1, 1.1, 1.1, 1.1, 1.1) if count == 6 else (7.0 / count,) * count
        table.autofit = False
        for column, width in zip(table.columns, widths):
            column.width = Inches(width)
        for index, row in enumerate(table.rows):
            trpr = row._tr.get_or_add_trPr()
            if trpr.find(qn("w:cantSplit")) is None:
                trpr.append(OxmlElement("w:cantSplit"))
            if index == 0 and trpr.find(qn("w:tblHeader")) is None:
                trpr.append(OxmlElement("w:tblHeader"))
            for col, (cell, width) in enumerate(zip(row.cells, widths)):
                cell.width = Inches(width)
                cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.TOP
                tcpr = cell._tc.get_or_add_tcPr()
                for old in list(tcpr):
                    if old.tag in (qn("w:shd"), qn("w:tcMar"), qn("w:tcBorders")):
                        tcpr.remove(old)
                fill = OxmlElement("w:shd")
                fill.set(qn("w:fill"), "E9EEF3" if index == 0 else "FFFFFF")
                tcpr.append(fill)
                margins = OxmlElement("w:tcMar")
                for side in ("top", "left", "bottom", "right"):
                    item = OxmlElement("w:" + side)
                    item.set(qn("w:w"), "110")
                    item.set(qn("w:type"), "dxa")
                    margins.append(item)
                tcpr.append(margins)
                borders = OxmlElement("w:tcBorders")
                for side in ("top", "left", "bottom", "right"):
                    border = OxmlElement("w:" + side)
                    for key, value in (("val", "single"), ("sz", "4"), ("color", "CDD5DD")):
                        border.set(qn("w:" + key), value)
                    borders.append(border)
                tcpr.append(borders)
                for paragraph in cell.paragraphs:
                    paragraph.paragraph_format.space_before = Pt(0)
                    paragraph.paragraph_format.space_after = Pt(5)
                    paragraph.paragraph_format.line_spacing = 1.08
                    paragraph.paragraph_format.keep_with_next = index == 0
                    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER if (count == 3 and col == 1) or (count == 6 and col > 0) else WD_ALIGN_PARAGRAPH.LEFT
                    for run in paragraph.runs:
                        run.font.name = "Times New Roman"
                        if run.font.size is None:
                            run.font.size = Pt(10.5)
                        if index == 0:
                            run.bold = True
                        run.font.color.rgb = RGBColor.from_string("243746" if index == 0 else "202020")
    footer = doc.sections[0].footer.paragraphs[0]
    footer.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    footer.add_run("Page ")
    field = OxmlElement("w:fldSimple")
    field.set(qn("w:instr"), "PAGE")
    footer._p.append(field)
    for run in footer.runs:
        run.font.name = "Times New Roman"
        run.font.size = Pt(9)
    paragraphs = list(doc.paragraphs)
    for section in doc.sections:
        paragraphs.extend(section.header.paragraphs)
        paragraphs.extend(section.footer.paragraphs)
    for table in doc.tables:
        for row in table.rows:
            for cell in row.cells:
                paragraphs.extend(cell.paragraphs)
    for paragraph in paragraphs:
        for run in paragraph.runs:
            run.font.name = "Times New Roman"
            fonts = run._element.get_or_add_rPr().get_or_add_rFonts()
            for attribute in list(fonts.attrib):
                if "theme" in attribute.lower():
                    del fonts.attrib[attribute]
            for script in ("ascii", "hAnsi", "eastAsia", "cs"):
                fonts.set(qn("w:" + script), "Times New Roman")


def write_docx(rows: Iterable[dict], findings: Iterable[dict], path: str | Path, metadata: dict | None = None) -> Path:
    """Write one site's evidence report after validating all site references.

    Full findings remain external. Metadata supports generated_at, mode,
    source_revision, cohort, period, findings_filename, summary_filename,
    max_actions_per_site (default 3), and max_evidence_per_action (default 2).
    Set mode to synthetic_demo only for independently generated demonstration data.
    """
    rows, findings, metadata = list(rows), list(findings), dict(metadata or {})
    site = assert_report_scope(rows, findings, metadata)
    from .historical_interpretation import findings_for_rows
    findings = findings_for_rows(rows)
    from .single_site import assert_private_paths
    assert_private_paths(Path(path).parent, mode=metadata.get("mode"), package_dir=ROOT)
    from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.shared import Inches, Pt

    output = Path(path)
    title = f"{site} | Initial OMOP screening report"
    doc = _new_document(title)
    synthetic = metadata.get("mode") == "synthetic_demo"
    header = doc.sections[0].header.paragraphs[0]
    header.text = site + ("  SYNTHETIC DEMONSTRATION" if synthetic else "")
    for run in header.runs:
        run.font.size = Pt(9)

    doc.add_paragraph(title, "Title")
    doc.add_paragraph("Scope: this is an initial, non-exhaustive screening based on a limited set of measurements. It is a starting point for investigation, not a comprehensive data-quality assessment or a conclusion that a site is fit for a use case.")
    if synthetic:
        p = doc.add_paragraph()
        p.paragraph_format.keep_with_next = True
        run = p.add_run("SYNTHETIC DEMONSTRATION")
        run.bold = True
        run.font.size = Pt(14)
        doc.add_paragraph("All values in this demonstration are generated examples. They do not describe any actual institution, dataset or patients and must not be used to make a data-fitness decision.")
    sites = [site]
    status_counts = Counter(_norm(r.get("status")) or "observed" for r in rows)
    severity_counts = Counter(f["severity"] for f in findings)
    doc.add_paragraph(f"This report contains {len(rows):,} screening results for {site}. Findings identify prerequisites to verify for the planned analysis; they are not a clinical validation.")
    doc.add_paragraph(f"Variable summaries: {severity_counts['review']:,} results requiring review, {severity_counts['info']:,} mapped descriptive notes. These labels are not a clinical severity scale.")
    meta_parts = ["Generated " + _text(metadata.get("generated_at") or datetime.now(timezone.utc).date().isoformat()), "Rule version " + RULE_VERSION]
    for key, label in (("mode", "Evidence mode"), ("source_revision", "Source revision"), ("cohort", "Cohort"), ("period", "Data period")):
        if metadata.get(key):
            meta_parts.append(label + ": " + _text(metadata[key]))
    p = doc.add_paragraph(" | ".join(meta_parts))
    for run in p.runs:
        run.font.size = Pt(9)

    doc.add_heading(f"Evidence coverage for {site}", level=1)
    doc.add_paragraph("Zero, unavailable, unassessed and reported N/A are distinct. N/A is not interpreted as a zero denominator.")
    cols = ("Site", "Results", "Mapped", "Review", "N/A", "Invalid")
    widths = (1.8, 0.85, 1.0, 1.05, 0.65, 0.65)
    table = doc.add_table(rows=1, cols=len(cols))
    table.autofit = False
    for c, label, width in zip(table.rows[0].cells, cols, widths):
        c.text = label
        c.width = Inches(width)
    header = OxmlElement("w:tblHeader")
    table.rows[0]._tr.get_or_add_trPr().append(header)
    for site in sites:
        subset = [r for r in rows if (_text(r.get("site")) or "Unspecified site") == site]
        counts = Counter(_norm(r.get("status")) or "observed" for r in subset)
        from .historical_interpretation import interpret
        assessed = Counter(interpret(r)['assessment'] for r in subset)
        unresolved = len(subset) - assessed['descriptive']
        vals = (site, str(len(subset)), str(assessed["descriptive"]), str(unresolved), str(counts["reported_na"]), str(assessed["invalid"]))
        for c, val, width in zip(table.add_row().cells, vals, widths):
            c.text = val
            c.width = Inches(width)
    for row_index, tr in enumerate(table.rows):
        for j, cell in enumerate(tr.cells):
            cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
            tcpr = cell._tc.get_or_add_tcPr()
            borders = OxmlElement("w:tcBorders")
            for side in ("top", "left", "bottom", "right"):
                border = OxmlElement("w:" + side)
                for attr, val in (("val", "single"), ("sz", "4"), ("color", "D9D9D9")):
                    border.set(qn("w:" + attr), val)
                borders.append(border)
            tcpr.append(borders)
            margins = OxmlElement("w:tcMar")
            for side in ("top", "left", "bottom", "right"):
                m = OxmlElement("w:" + side)
                m.set(qn("w:w"), "80")
                m.set(qn("w:type"), "dxa")
                margins.append(m)
            tcpr.append(margins)
            shd = OxmlElement("w:shd")
            shd.set(qn("w:fill"), "E7EDF3" if row_index == 0 else "FFFFFF")
            tcpr.append(shd)
            for p in cell.paragraphs:
                p.paragraph_format.space_after = Pt(2)
                p.paragraph_format.space_before = Pt(2)
                p.alignment = WD_ALIGN_PARAGRAPH.LEFT if j == 0 else WD_ALIGN_PARAGRAPH.CENTER
                for r in p.runs:
                    r.font.size = Pt(10)
                    r.bold = row_index == 0
    coverage_note = doc.add_paragraph("Review includes unavailable, undefined, suppressed, invalid and unmapped results. Mapped means a usable descriptive contract, not fitness. N/A and invalid are subsets, not additional rows.")
    coverage_note.paragraph_format.space_before = Pt(6)

    doc.add_heading("Variable-level findings and next actions", level=1)
    doc.add_paragraph("Each table retains one measured output and its source. Recommendations are conditional screening rules, not clinical validation. Counts are not treatment episodes unless the source query explicitly defines them as such.")
    from .historical_interpretation import interpret
    reference_urls = sorted({url for row in rows for url in interpret(row)['evidence_sources'].split(' | ') if url})
    reference_ids = {url: 'S' + str(i + 1) for i, url in enumerate(reference_urls)}
    previous_topic = None
    for row in rows:
        topic = str(row.get("topic", "Unspecified"))
        if topic != previous_topic:
            doc.add_heading(topic.replace("_", " ").title(), level=2)
            table = doc.add_table(rows=1, cols=3)
            table.style = "Table Grid"
            for cell, text in zip(table.rows[0].cells, ("Variable and definition", "Result", "Interpretation and next action")):
                cell.text = text
            repeat = OxmlElement("w:tblHeader")
            table.rows[0]._tr.get_or_add_trPr().append(repeat)
            previous_topic = topic
        item = interpret(row)
        category = str(row.get("category") or row.get("section") or "")
        cells = table.add_row().cells
        if category:
            context = cells[0].paragraphs[0].add_run(category)
            context.font.size = Pt(9)
            context.italic = True
            metric = cells[0].add_paragraph()
        else:
            metric = cells[0].paragraphs[0]
        metric.add_run(item["variable"]).bold = True
        cells[0].add_paragraph(item["definition"])
        result_run = cells[1].paragraphs[0].add_run(item["result"])
        result_run.bold = True
        result_run.font.size = Pt(11)
        cells[2].paragraphs[0].add_run(item["interpretation"])
        action = cells[2].add_paragraph()
        action.add_run("Next: ").bold = True
        action.add_run(item["action"])
        source = cells[2].add_paragraph()
        source_run = source.add_run("Source: " + item["source"])
        source_run.font.size = Pt(9)
        if item['evidence_sources']:
            refs = ', '.join(reference_ids[url] for url in item['evidence_sources'].split(' | ') if url)
            cells[2].add_paragraph('Method basis: ' + refs + '. Follow-up inference, not a validated fitness decision.').runs[0].font.size = Pt(9)
    if reference_urls:
        doc.add_heading('Methods and field-semantics references', level=1).paragraph_format.page_break_before = True
        doc.add_paragraph('These sources support field definitions and analytical checks, not clinical validation of the custom selection or this site. Recommendations are conditional follow-up inferences. Exact SQL locators, hashes and support limitations are retained in the metric registry; findings exports include source URLs and evidence limitations.')
        for url in reference_urls:
            doc.add_paragraph(reference_ids[url] + ': ' + url)
    output.parent.mkdir(parents=True, exist_ok=True)
    _format_report_tables(doc)
    doc.save(output)
    return output


def write_report_template(path: str | Path, site: str = "Site_01", metadata: dict | None = None) -> Path:
    """Create a blank editable single-site report with no example metrics."""
    metadata = dict(metadata or {})
    site = assert_report_scope([{"site": site}], [], metadata)
    from docx.shared import Pt

    output = Path(path)
    title = f"{site} | Initial OMOP screening template"
    doc = _new_document(title)
    doc.sections[0].header.paragraphs[0].text = f"{site}  BLANK REPORT TEMPLATE"
    doc.add_paragraph(title, "Title")
    doc.add_paragraph("Scope: this is an initial, non-exhaustive screening based on a limited set of measurements. It is a starting point for investigation, not a comprehensive data-quality assessment or a conclusion that a site is fit for a use case.")
    p = doc.add_paragraph()
    p.add_run("BLANK EDITABLE TEMPLATE").bold = True
    doc.add_paragraph("Complete this template for one site only. Replace bracketed prompts with verified evidence. It contains no screening results, and no fitness conclusion has been reached.")

    doc.add_heading("Study scope and evidence", level=1)
    for label, prompt in (
        ("Site alias", site),
        ("Intended analysis", "[Research question and required clinical variables]"),
        ("Cohort and observation period", "[Eligibility criteria and dates]"),
        ("Source and versions", "[CDM, vocabulary, ETL and query versions]"),
        ("Assessment date", "[Date]"),
    ):
        p = doc.add_paragraph()
        p.add_run(label + ": ").bold = True
        p.add_run(prompt)

    doc.add_heading(f"Evidence coverage for {site}", level=1)
    doc.add_paragraph("[Record result counts by observed, not assessed, not available, reported N/A, undefined, suppressed, error and needs-review status. Identify domains not assessed.]")
    doc.add_paragraph("Keep numeric zero separate from blank or unavailable evidence. Record numerator, denominator, unit and source locator for each ratio. A reported N/A does not establish a zero denominator unless the denominator is explicitly supplied.")

    doc.add_heading("Variable-level screening results", level=1)
    table = doc.add_table(rows=1, cols=3)
    table.style = "Table Grid"
    for cell, text in zip(table.rows[0].cells, ("Variable and definition", "Result", "Interpretation and next action")):
        cell.text = text
    cells = table.add_row().cells
    cells[0].text = "[Exact variable; definition and eligible subset]"
    cells[1].text = "[Value/unit or unresolved status]"
    cells[2].text = "[Meaning for the use case; action conditional on this result; query/cell source]"
    doc.add_heading("Limits and unresolved items", level=1)
    doc.add_paragraph("[State what remains unavailable or ambiguous for this site's intended use case. No universal readiness score. Preserve zero versus unavailable, and candidate records versus clinical events.]")
    for paragraph in doc.sections[0].header.paragraphs:
        for run in paragraph.runs:
            run.font.size = Pt(9)
    output.parent.mkdir(parents=True, exist_ok=True)
    _format_report_tables(doc)
    doc.save(output)
    return output


def _pdf_font_family() -> str:
    """Use an installed Unicode font without copying fonts into the project."""
    import os
    import reportlab
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont

    family = "FitnessReport"
    if family in pdfmetrics.getRegisteredFontNames():
        return family
    windows_fonts = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts"
    candidates = [
        (windows_fonts, "times.ttf", "timesbd.ttf", "timesi.ttf", "timesbi.ttf"),
        (Path("/usr/share/fonts/truetype/liberation2"), "LiberationSerif-Regular.ttf", "LiberationSerif-Bold.ttf", "LiberationSerif-Italic.ttf", "LiberationSerif-BoldItalic.ttf"),
        (Path("/usr/share/fonts/truetype/dejavu"), "DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "DejaVuSans-Oblique.ttf", "DejaVuSans-BoldOblique.ttf"),
        (Path(reportlab.__file__).parent / "fonts", "Vera.ttf", "VeraBd.ttf", "VeraIt.ttf", "VeraBI.ttf"),
    ]
    for folder, regular, bold, italic, bold_italic in candidates:
        names = (regular, bold, italic, bold_italic)
        if all((folder / name).is_file() for name in names):
            for suffix, name in zip(("", "-Bold", "-Italic", "-BoldItalic"), names):
                pdfmetrics.registerFont(TTFont(family + suffix, str(folder / name)))
            pdfmetrics.registerFontFamily(family, normal=family, bold=family + "-Bold", italic=family + "-Italic", boldItalic=family + "-BoldItalic")
            return family
    raise RuntimeError("PDF generation requires a Unicode TrueType font family such as Times New Roman or Liberation Serif.")


def _docx_content_to_pdf(document, output: Path, site: str, synthetic: bool) -> None:
    """Render the report's existing text and tables without recalculating findings."""
    from html import escape
    from docx.table import Table as DocxTable
    from docx.text.paragraph import Paragraph as DocxParagraph
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_CENTER, TA_LEFT
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle, Spacer, PageBreak

    family = _pdf_font_family()
    base = ParagraphStyle("Body", fontName=family, fontSize=10.5, leading=14,
                          spaceAfter=6, textColor=colors.black, splitLongWords=True)
    styles = {
        "Normal": base,
        "Title": ParagraphStyle("Title", parent=base, fontName=family + "-Bold", fontSize=23, leading=27, spaceAfter=12, keepWithNext=True),
        "Heading 1": ParagraphStyle("Heading1", parent=base, fontName=family + "-Bold", fontSize=15, leading=19, spaceBefore=12, spaceAfter=6, keepWithNext=True),
        "Heading 2": ParagraphStyle("Heading2", parent=base, fontName=family + "-Bold", fontSize=12, leading=16, spaceBefore=9, spaceAfter=5, keepWithNext=True),
        "Small": ParagraphStyle("Small", parent=base, fontSize=8.5, leading=11),
        "Banner": ParagraphStyle("Banner", parent=base, fontName=family + "-Bold", fontSize=14, leading=18, keepWithNext=True),
    }

    def rich_text(paragraph):
        parts = []
        for run in paragraph.runs:
            text = escape(run.text).replace("\n", "<br/>")
            if run.font.size is not None:
                text = "<font size=\"" + str(run.font.size.pt) + "\">" + text + "</font>"
            if run.bold:
                text = "<b>" + text + "</b>"
            if run.italic:
                text = "<i>" + text + "</i>"
            parts.append(text)
        return "".join(parts) or escape(paragraph.text)

    story = []
    for element in document.element.body:
        tag = element.tag.rsplit("}", 1)[-1]
        if tag == "p":
            p = DocxParagraph(element, document)
            if not p.text.strip():
                continue
            if p.paragraph_format.page_break_before:
                story.append(PageBreak())
            style = styles.get(p.style.name, base)
            if p.text in ("SYNTHETIC DEMONSTRATION", "BLANK EDITABLE TEMPLATE"):
                style = styles["Banner"]
            elif p.text.startswith(("Source: ", "Generated ", "Complete category-variable-result")):
                style = styles["Small"]
            elif p.runs and all(r.font.size is not None and r.font.size.pt <= 9 for r in p.runs):
                style = styles["Small"]
            if p.paragraph_format.keep_with_next and not getattr(style, "keepWithNext", False):
                style = ParagraphStyle("KeepWithNext", parent=style, keepWithNext=True)
            if p.style.name == "List Bullet":
                story.append(Paragraph(rich_text(p), style, bulletText="-"))
            else:
                story.append(Paragraph(rich_text(p), style))
        elif tag == "tbl":
            source_table = DocxTable(element, document)
            values = []
            for row_index, row in enumerate(source_table.rows):
                cells = []
                for column_index, cell in enumerate(row.cells):
                    cell_style = ParagraphStyle("Cell", parent=base, fontName=family + ("-Bold" if row_index == 0 else ""),
                                                fontSize=10.5, leading=13, spaceAfter=0,
                                                alignment=TA_CENTER if len(row.cells) == 3 and column_index == 1 else TA_LEFT)
                    cells.append(Paragraph("<br/><br/>".join(rich_text(p) for p in cell.paragraphs), cell_style))
                values.append(cells)
            column_count = len(values[0]) if values else 0
            if column_count == 3:
                widths = [162, 46.8, 295.2]
            elif column_count == 6:
                widths = [108, 79.2, 79.2, 79.2, 79.2, 79.2]
            else:
                widths = [504 / column_count] * column_count
            table = Table(values, colWidths=widths, repeatRows=1, hAlign="LEFT", splitByRow=1, splitInRow=1)
            table.setStyle(TableStyle([
                ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#D9D9D9")),
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#E7EDF3")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 6), ("RIGHTPADDING", (0, 0), (-1, -1), 6),
                ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ]))
            story.extend([table, Spacer(1, 7)])

    def draw_page(canvas, _doc):
        canvas.saveState()
        canvas.setFont(family, 8)
        canvas.setFillColor(colors.black)
        label = site + ("  SYNTHETIC DEMONSTRATION" if synthetic else "")
        canvas.drawString(54, 764, label)
        canvas.drawRightString(558, 28, f"Page {canvas.getPageNumber()}")
        canvas.restoreState()

    pdf = SimpleDocTemplate(str(output), pagesize=letter, rightMargin=54, leftMargin=54,
                            topMargin=49, bottomMargin=44, title=document.core_properties.title,
                            author="", subject="Evidence-led single-site screening feedback",
                            creator="OMOP Fitness Pipeline", keywords="")
    while story and isinstance(story[-1], Spacer):
        story.pop()
    pdf.build(story, onFirstPage=draw_page, onLaterPages=draw_page)


def write_pdf(rows: Iterable[dict], findings: Iterable[dict], path: str | Path, metadata: dict | None = None) -> Path:
    """Write a single-site PDF using the same content as the editable DOCX."""
    rows, findings, metadata = list(rows), list(findings), dict(metadata or {})
    site = assert_report_scope(rows, findings, metadata)
    from .historical_interpretation import findings_for_rows
    findings = findings_for_rows(rows)
    from .single_site import assert_private_paths
    assert_private_paths(Path(path).parent, mode=metadata.get("mode"), package_dir=ROOT)
    from tempfile import TemporaryDirectory
    from docx import Document
    # Fail on missing optional dependencies before creating an output directory.
    import reportlab  # noqa: F401

    output = Path(path)
    with TemporaryDirectory(prefix="fitness_report_") as tmp:
        docx_path = write_docx(rows, findings, Path(tmp) / "report.docx", metadata)
        pdf_path = Path(tmp) / "report.pdf"
        _docx_content_to_pdf(Document(docx_path), pdf_path, site, metadata.get("mode") == "synthetic_demo")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(pdf_path.read_bytes())
    return output
