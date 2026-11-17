"""Local one-site orchestration. Demo uses synthetic fixtures; Excel never runs SQL."""
from __future__ import annotations

import argparse
from collections import Counter
from collections.abc import Mapping
from copy import deepcopy
from decimal import Decimal
import os
from pathlib import Path
import re

from .paths import ROOT, CONFIG

RESULT_FIELDS = frozenset({"category", "variable", "result", "site", "topic", "status", "numeric_value",
    "unit", "numerator", "denominator", "query_id", "source_file", "source_sheet", "source_cell",
    "source_formula", "section", "note"})
FINDING_FIELDS = frozenset({"site", "topic", "severity", "title", "definition", "result", "status", "assessment", "evidence", "impact", "action", "source", "calculation_source", "evidence_basis", "evidence_sources", "evidence_limit"})
EXECUTION_FIELDS = frozenset({"id", "status", "sha256", "seconds", "result_rows", "sqlstate", "error_type"})


class SiteIsolationError(ValueError):
    """An input or output cannot be attributed solely to the selected site."""


def assert_private_paths(output_dir, private_mapping=None, mode=None, package_dir=None):
    """Keep real outputs and every private mapping outside the code package."""
    protected = {ROOT}
    if package_dir is not None:
        protected.add(Path(package_dir).expanduser().resolve())
    output = Path(output_dir).expanduser().resolve()
    if private_mapping is not None:
        mapping = Path(private_mapping).expanduser().resolve()
        if any(mapping == root or root in mapping.parents for root in protected):
            raise SiteIsolationError("Private mappings must remain outside the code package, including synthetic runs.")
    if mode not in {"demo", "synthetic_demo"} and any(output == root or root in output.parents for root in protected):
        raise SiteIsolationError("Non-synthetic outputs must remain outside the code package.")


def validate_site_alias(site):
    if not isinstance(site, str) or not re.fullmatch(r"Site_\d{2,}", site):
        raise SiteIsolationError("Select one neutral alias such as Site_01.")
    return site


def assert_alias_scope(obj, site):
    """Inspect nested keys/values, including aliases embedded in file names."""
    validate_site_alias(site)
    if isinstance(obj, str):
        if any(alias.lower() != site.lower() for alias in re.findall(r"Site_\d{2,}", obj, re.IGNORECASE)):
            raise SiteIsolationError("Another site's alias occurs in the selected output.")
    elif isinstance(obj, Mapping):
        for key, value in obj.items():
            assert_alias_scope(key, site)
            assert_alias_scope(value, site)
    elif isinstance(obj, (list, tuple, set)):
        for value in obj:
            assert_alias_scope(value, site)


def assert_single_site(rows, site, findings=()):
    validate_site_alias(site)
    rows = list(rows)
    if not rows:
        raise SiteIsolationError("No result rows exist for the selected site.")
    for collection, fields in ((rows, RESULT_FIELDS), (list(findings), FINDING_FIELDS)):
        for record in collection:
            if not isinstance(record, Mapping) or record.get("site") != site:
                raise SiteIsolationError("Mixed or missing site ownership; export refused.")
            if set(record) - fields:
                raise SiteIsolationError("Unknown evidence fields cannot be included in a site report.")
            if any(value is not None and not isinstance(value, (str, int, float, Decimal)) for value in record.values()):
                raise SiteIsolationError("Evidence fields must contain scalar aggregate values, not nested data.")
            assert_alias_scope(record, site)


def prepare_site_rows(rows, site):
    """Select one site's records without mutating inputs or exposing formulas."""
    validate_site_alias(site)
    selected = [deepcopy(row) for row in rows if row.get("site") == site]
    for row in selected:
        if row.get("source_formula"):
            row.update(result="Formula-derived value withheld pending dependency review",
                       numeric_value=None, numerator=None, denominator=None,
                       status="needs_review", source_formula="",
                       note="Review the source formula's dependencies before including this value in a site-specific report.")
    assert_single_site(selected, site)
    return selected


def isolate_metadata(metadata, rows, site):
    """Rebuild counts and provenance from selected rows; never copy all-site totals."""
    rows = list(rows)
    assert_single_site(rows, site)
    if not isinstance(metadata, Mapping):
        raise SiteIsolationError("Metadata must be an object.")
    if "site" in metadata and metadata["site"] != site:
        raise SiteIsolationError("Metadata belongs to another site.")
    if "sites" in metadata and metadata["sites"] != [site]:
        raise SiteIsolationError("Metadata includes an unexpected site list.")
    allowed = ("mode", "cdm_version", "vocabulary_version", "query_manifest_sha256",
               "schema", "suppression_threshold", "privacy", "scope", "executions",
               "source_revision", "cohort", "period", "generated_at", "run_id",
               "created_utc", "pipeline_version", "feedback_rule_version", "interpretation")
    result = {key: deepcopy(metadata[key]) for key in allowed if key in metadata}
    for key, value in result.items():
        if key != "executions" and value is not None and not isinstance(value, (str, int, float, Decimal)):
            raise SiteIsolationError("Metadata contains an unsupported nested field.")
    if "executions" in result:
        if not isinstance(result["executions"], list):
            raise SiteIsolationError("Executions must be a list of reviewed query-status records.")
        for execution in result["executions"]:
            if not isinstance(execution, Mapping) or set(execution) - EXECUTION_FIELDS:
                raise SiteIsolationError("Unknown query-execution metadata fields are refused.")
            if any(v is not None and not isinstance(v, (str, int, float, Decimal)) for v in execution.values()):
                raise SiteIsolationError("Nested query-execution payloads are refused.")
    result.update(site=site, sites=[site], result_rows=len(rows),
                  isolation="Only the selected site's evidence and recommendations are included.")
    lookup = {s.get("file"): s for s in metadata.get("sources", []) if isinstance(s, Mapping)}
    counts = Counter((row.get("source_file", ""), row.get("source_sheet", "")) for row in rows)
    result["sources"] = []
    for name in sorted({name for name, _ in counts if name}):
        entry = {"file": name, "sheets": [{"sheet": sheet, "rows_imported": count}
                 for (filename, sheet), count in sorted(counts.items()) if filename == name]}
        if lookup.get(name, {}).get("sha256"):
            entry["sha256"] = lookup[name]["sha256"]
        result["sources"].append(entry)
    if result.get("mode") == "synthetic_demo":
        result["scope"] = "SYNTHETIC TEST ONLY. No clinical data, workbook import, or database query was used."
    elif result.get("mode") == "workbook_import":
        result["scope"] = "Previously reported aggregates for this site only. No SQL or live database connection was executed. Confirm cohort and extraction period separately."
    assert_alias_scope(result, site)
    return result


def demo_rows(site):
    """Fictional aggregates for software testing, not clinical findings."""
    validate_site_alias(site)
    examples = [
        ("Continuous infusion", "Norepinephrine", "DRUG_EXPOSURE records (n)", "20", 20, "", 20, None),
        ("Continuous infusion", "Norepinephrine", "Start and end datetime both populated (%)", "80%", 80, "%", 16, 20),
        ("Continuous infusion", "Norepinephrine", "Source indicates IV but standardized route is not IV (%)", "10%", 10, "%", 2, 20),
        ("Continuous infusion", "Norepinephrine", "Candidate numeric rate: quantity + rate-like unit (%)", "75%", 75, "%", 15, 20),
        ("Fluid balance", "Coverage", "Fluid intake records (n)", "0", 0, "", 0, None),
        ("Code Status", "OBSERVATION", "visit_detail_id populated (%)", "100%", 100, "%", 12, 12),
    ]
    rows = [dict(site=site, topic=topic, category=category, variable=variable, result=value,
                 numeric_value=number, unit=unit, numerator=numerator, denominator=denominator,
                 status="observed", query_id="synthetic_demo", source_file="synthetic_demo",
                 source_sheet="", source_cell="", source_formula="", section="",
                 note="SYNTHETIC TEST ONLY. This metric is fictional.")
            for topic, category, variable, value, number, unit, numerator, denominator in examples]
    rows.append(dict(rows[-1], variable="Code-status categories observed", result="", numeric_value=None,
                     numerator=None, denominator=None, unit="", status="not_assessed"))
    return rows


def export_site(rows, metadata, site, output_dir, no_docx=False, include_pdf=False):
    from . import pipeline
    from . import reporting
    selected = prepare_site_rows(rows, site)
    isolated = isolate_metadata(metadata, selected, site)
    findings = reporting.assess(selected)
    assert_single_site(selected, site, findings)
    if include_pdf and not callable(getattr(reporting, "write_pdf", None)):
        raise ValueError("PDF generation is unavailable in this report module.")
    output, count = pipeline.export_outputs(selected, isolated, output_dir, no_docx)
    output = Path(output).resolve()
    result = {"site": site, "mode": isolated.get("mode"), "output_dir": str(output),
            "result_rows": len(selected), "findings_count": count,
            "files": {"summary_csv": str(output / "summary.csv"),
                      "findings_csv": str(output / "findings.csv"),
                      "docx": None if no_docx else str(output / "feedback_report.docx"),
                      "run_manifest": str(output / "run_manifest.json")}}
    if include_pdf:
        pdf_path = output / "feedback_report.pdf"
        reporting.write_pdf(selected, findings, pdf_path, pipeline.load_json(output / "run_manifest.json"))
        if not pdf_path.is_file() or pdf_path.stat().st_size == 0:
            raise ValueError("PDF generation did not produce a nonempty local file.")
        result["files"]["pdf"] = str(pdf_path)
    return result


def run_site_assessment(*, mode, site, output_dir, input_folder=None, private_mapping=None,
                        schema="omopcdm", topics=None, timeout=300, suppress_below=5,
                        vocabulary_version="not supplied", manifest=None, no_docx=False,
                        dsn_env=None, confirm_site_connection=False, include_pdf=False):
    """Execute one site's workflow, retaining secrets only in the environment."""
    assert_private_paths(output_dir, private_mapping, mode)
    validate_site_alias(site)
    if mode not in {"demo", "database", "excel"}:
        raise ValueError("Mode must be demo, database, or excel.")
    out = Path(output_dir).expanduser().resolve()
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        raise ValueError("Use a new or empty output directory; existing results are preserved.")
    if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout < 1:
        raise ValueError("Timeout must be a positive integer number of seconds.")
    if not isinstance(suppress_below, int) or isinstance(suppress_below, bool) or suppress_below < 0:
        raise ValueError("Suppression must be a non-negative integer.")
    if topics is not None and (not isinstance(topics, (list, tuple)) or any(not isinstance(t, str) or not t.strip() for t in topics)):
        raise ValueError("Topics must be a list of nonempty manifest topic names.")
    from . import pipeline
    pending_mapping = None
    if mode == "database":
        pipeline.schema_name(schema)
        if confirm_site_connection is not True:
            raise SiteIsolationError("Confirm the selected connection and schema contain only this site's data. The site alias is not a SQL filter.")
        dsn_env = dsn_env or f"OMOP_{site.upper()}_DSN"
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", dsn_env):
            raise ValueError("Specify a connection environment variable name, not a DSN.")
        if not os.environ.get(dsn_env, "").strip():
            raise ValueError("The selected site's connection variable is missing; no generic fallback is used.")
        args = argparse.Namespace(site=site, schema=schema, topic=list(topics or []), query=None,
            manifest=str(manifest or CONFIG / "manifest.json"),
            timeout=timeout, max_rows=10000, suppress_below=suppress_below,
            vocabulary_version=vocabulary_version, dsn_env=dsn_env, confirm_site_connection=True)
        rows, metadata = pipeline.run_database(args)
        assert_single_site(rows, site)
    elif mode == "excel":
        if not input_folder or not Path(input_folder).is_dir():
            raise ValueError("Excel mode requires an existing local aggregate-workbook directory.")
        source = Path(input_folder).expanduser().resolve()
        if source == out or source in out.parents or out in source.parents:
            raise ValueError("Keep input and output directories separate.")
        mapping_path = Path(private_mapping).expanduser().resolve() if private_mapping else None
        if mapping_path:
            if mapping_path == out or out in mapping_path.parents:
                raise SiteIsolationError("The private mapping must remain outside the report directory.")
            if mapping_path.suffix.lower() != ".json" or not mapping_path.parent.is_dir():
                raise ValueError("The private mapping must be a JSON file in an existing local directory.")
            if mapping_path.exists() and not mapping_path.is_file():
                raise ValueError("The private mapping path is not a file.")
        mapping = pipeline.load_json(mapping_path) if mapping_path and mapping_path.exists() else None
        rows, metadata = pipeline.import_workbooks(source, mapping)
        prepare_site_rows(rows, site)
        if mapping_path:
            pending_mapping = (mapping_path, metadata["_private_site_map"])
    else:
        rows = demo_rows(site)
        metadata = {"mode": "synthetic_demo", "cdm_version": "Not applicable to synthetic fixtures"}
    result = export_site(rows, metadata, site, out, no_docx, include_pdf)
    if pending_mapping:
        pipeline.dump_json(*pending_mapping)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["demo", "database", "excel"], required=True)
    parser.add_argument("--site", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--input")
    parser.add_argument("--private-site-map")
    parser.add_argument("--schema", default="omopcdm")
    parser.add_argument("--topic", action="append")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--suppress-below", type=int, default=5)
    parser.add_argument("--vocabulary-version", default="not supplied")
    parser.add_argument("--dsn-env")
    parser.add_argument("--confirm-site-connection", action="store_true")
    parser.add_argument("--include-pdf", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = run_site_assessment(mode=args.mode, site=args.site, output_dir=args.output,
            input_folder=args.input, private_mapping=args.private_site_map, schema=args.schema,
            topics=args.topic, timeout=args.timeout, suppress_below=args.suppress_below,
            vocabulary_version=args.vocabulary_version, dsn_env=args.dsn_env,
            confirm_site_connection=args.confirm_site_connection, include_pdf=args.include_pdf)
    except Exception:
        parser.exit(1, "Assessment failed. Check local settings and sanitized diagnostics; raw errors are hidden to protect private information.\n")
    print(f"Created {result['result_rows']} rows for {result['site']} ({result['mode']}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
