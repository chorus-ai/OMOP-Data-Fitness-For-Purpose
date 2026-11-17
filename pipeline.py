#!/usr/bin/env python3
"""Local, aggregate-only OMOP fitness screening and evidence reporting.

Run `python pipeline.py --help`. No database is contacted by import-workbooks.
"""
from __future__ import annotations

import argparse
import csv
from datetime import date, datetime, time as daytime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent
VERSION = "0.4.0"
FIELDS = ["category", "variable", "result", "site", "topic", "status", "numeric_value",
          "unit", "numerator", "denominator", "query_id", "source_file", "source_sheet",
          "source_cell", "source_formula", "section", "note"]
DIMENSION_HEADERS = {"category", "variable", "drug_name", "section", "notes", "note", "comment", "comments"}


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def dump_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False, default=str), encoding="utf-8")


def parse_result(value, number_format="", variable=""):
    """Preserve missing, zero and reported N/A; numeric percentages use 0..100."""
    if value is None or (isinstance(value, str) and not value.strip()):
        return {"result": "", "numeric_value": None, "unit": "", "status": "not_assessed"}
    if isinstance(value, (datetime, date, daytime)):
        return {"result": value.isoformat(), "numeric_value": None, "unit": "", "status": "needs_review"}
    s = str(value).strip()
    low = s.lower()
    if low in {"tbd", "pending", "not assessed", "not tested", "to be determined"}:
        return {"result": s, "numeric_value": None, "unit": "", "status": "not_assessed"}
    if low in {"unknown", "not known"}:
        return {"result": s, "numeric_value": None, "unit": "", "status": "not_available"}
    if low in {"n/a", "na", "n.a.", "not applicable"}:
        return {"result": s, "numeric_value": None, "unit": "", "status": "reported_na"}
    if low in {"do not respond", "not responded", "no response", "not available", "not reported"}:
        return {"result": s, "numeric_value": None, "unit": "", "status": "not_available"}
    if low in {"#ref!", "#value!", "#div/0!", "#n/a", "#name?", "#num!", "#null!"}:
        return {"result": s, "numeric_value": None, "unit": "", "status": "error"}
    if isinstance(value, bool):
        return {"result": "YES" if value else "NO", "numeric_value": None, "unit": "", "status": "observed"}
    n = None
    unit = ""
    try:
        if isinstance(value, (int, float, Decimal)):
            n = float(value)
            if "%" in number_format:
                n *= 100
                unit = "%"
            elif "(%)" in variable:
                unit = "%"  # Numeric exported percentages are already 0..100.
        elif re.fullmatch(r"[-+]?\d[\d,]*(?:\.\d+)?\s*%?", s):
            unit = "%" if s.endswith("%") else ""
            n = float(s.rstrip("%").replace(",", "").strip())
    except (ValueError, InvalidOperation):
        n = None
    status = "observed"
    if n is not None and not math.isfinite(n):
        n, status = None, "error"
    if n is not None and unit == "%" and not 0 <= n <= 100:
        status = "needs_review"
    if isinstance(value, (int, float, Decimal)) and n is not None:
        s = f"{n:g}" + unit
    return {"result": s, "numeric_value": n, "unit": unit, "status": status}


def topic_for(file, sheet, variable):
    if sheet == "CDI":
        return "Continuous infusion"
    if sheet == "Microbiology":
        return "Microbiology and AST"
    if sheet == "Summary":
        if "microbio" in variable.lower() or "fact_relationship" in variable.lower():
            return "Microbiology and AST"
        if "drug" in variable.lower() or "cont infusion" in variable.lower():
            return "Continuous infusion"
        if any(x in variable.lower() for x in ["episode", "specimen", "note"]):
            return "Supporting tables"
        return "Transfusion"
    if "Dialysis" in file:
        return "Dialysis and RRT"
    return sheet


def import_workbooks(folder, site_map=None):
    import openpyxl
    rows, sources, warnings = [], [], []
    site_map = dict(site_map or {})
    if any(not re.fullmatch(r'Site_\d{2,}', alias) for alias in site_map.values()) or len(set(site_map.values())) != len(site_map):
        raise ValueError('Private site mapping must use unique neutral Site_01 style aliases.')
    paths = sorted(Path(folder).glob("*.xlsx"))
    if not paths:
        raise ValueError("No XLSX files found in the input folder.")
    for path in paths:
        wb = openpyxl.load_workbook(path, data_only=False)
        values = openpyxl.load_workbook(path, data_only=True)
        accepted = []
        for sheet in wb:
            header = None
            for candidate in sheet.iter_rows(max_row=min(sheet.max_row, 15)):
                labels = [str(c.value).strip() if c.value is not None else "" for c in candidate]
                if "Variable" in labels and any(x and x.lower() not in DIMENSION_HEADERS and not x.isdigit() for x in labels[labels.index('Variable')+1:]):
                    header = (candidate[0].row, labels)
                    break
            if header is None:
                continue
            hrow, labels = header
            vidx = labels.index("Variable")
            cidx = labels.index("Category") if "Category" in labels else None
            didx = labels.index("drug_name") if "drug_name" in labels else None
            sidx = labels.index("section") if "section" in labels else None
            site_cols = [(i, label) for i, label in enumerate(labels) if i > vidx and label and label.lower() not in DIMENSION_HEADERS and not label.isdigit()]
            for _, label in site_cols:
                if label not in site_map:
                    next_id = max([int(a.split('_')[1]) for a in site_map.values()] or [0]) + 1
                    site_map[label] = f'Site_{next_id:02d}'
            vrows = values[sheet.title].iter_rows(min_row=hrow + 1)
            count = 0
            for raw, cached in zip(sheet.iter_rows(min_row=hrow + 1), vrows):
                variable = raw[vidx].value
                if variable is None or not str(variable).strip():
                    continue
                variable = str(variable).strip()
                topic = topic_for(path.name, sheet.title, variable)
                category = str(raw[cidx].value or topic) if cidx is not None else topic
                if didx is not None:
                    category = str(raw[didx].value or "Unspecified drug")
                section = str(raw[sidx].value or "") if sidx is not None else ""
                if sheet.title == "Summary":
                    section = "legacy_summary"
                for col, site in site_cols:
                    cell, value_cell = raw[col], cached[col]
                    parsed = parse_result(value_cell.value, cell.number_format, variable)
                    note = "Unexpected Excel date/time in a screening metric; inspect the source cell before using it." if isinstance(value_cell.value, (datetime, date, daytime)) else ""
                    formula = str(cell.value) if cell.data_type == "f" else ""
                    if formula and value_cell.value is None:
                        parsed["status"] = "not_assessed"
                        note = "Formula has no cached value; recalculate and save the workbook in Excel."
                    if sheet.title == "Summary":
                        note += " Historical summary; do not pool with later domain screening rows."
                    if "positive blood" in variable.lower():
                        note += " Legacy positivity is method-sensitive; exclude reflex panels and validate organism-only positives before use."
                    rows.append(dict(category=category, variable=variable, site=site_map[site], topic=topic,
                                     numerator=None, denominator=None, query_id="workbook_import",
                                     source_file=path.name, source_sheet=sheet.title,
                                     source_cell=cell.coordinate, source_formula=formula,
                                     section=section, note=note.strip(), **parsed))
                    count += 1
            accepted.append({"sheet": sheet.title, "rows_imported": count})
        sources.append({"file": path.name, "sha256": sha256(path), "sheets": accepted})
        wb.close()
        values.close()
    if not rows:
        raise ValueError("No sheets with a Variable header followed by site columns were found.")
    return rows, {"sources": sources, "warnings": warnings, "_private_site_map": site_map,
                  "scope": "Previously reported site aggregates; workbook measurement dates and cohort definitions are not supplied.",
                  "mode": "workbook_import", "cdm_version": "Not supplied for imported results"}


def safe_csv_value(value):
    if value is None:
        return ""
    if isinstance(value, str) and (value.startswith(("=", "+", "-", "@", "\t", "\r")) or value.lstrip().startswith(("=", "+", "@"))):
        return "'" + value
    return value


def write_csv(path, rows, fields):
    with Path(path).open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows({k: safe_csv_value(r.get(k)) for k in fields} for r in rows)


def validate_sql(sql):
    """Conservative lint, not a security boundary. Use a read-only DB role as well."""
    clean, i = [], 0
    while i < len(sql):
        if sql.startswith('--', i):
            end = sql.find('\n', i)
            i = len(sql) if end < 0 else end + 1
            clean.append(' ')
        elif sql.startswith('/*', i):
            depth, i = 1, i + 2
            while i < len(sql) and depth:
                if sql.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif sql.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            if depth:
                raise ValueError('Unclosed SQL comment')
            clean.append(' ')
        elif sql[i] in "'\"":
            quote, i = sql[i], i + 1
            closed = False
            while i < len(sql):
                if sql[i] == quote:
                    if i + 1 < len(sql) and sql[i + 1] == quote:
                        i += 2
                    else:
                        i += 1
                        closed = True
                        break
                else:
                    i += 1
            if not closed:
                raise ValueError('Unclosed SQL quote')
            clean.append(' ')
        elif sql[i] == '$' and (m := re.match(r'\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$', sql[i:])):
            tag = m.group(0)
            end = sql.find(tag, i + len(tag))
            if end < 0:
                raise ValueError('Unclosed dollar-quoted string')
            i = end + len(tag)
            clean.append(' ')
        else:
            clean.append(sql[i])
            i += 1
    text = ''.join(clean).strip()
    if text.endswith(';'):
        text = text[:-1]
    if ';' in text or not re.match(r'^(SELECT|WITH)\b', text, re.I):
        raise ValueError('Only one SELECT/WITH query is allowed.')
    tokens = set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', text.upper()))
    forbidden = {"INSERT", "UPDATE", "DELETE", "MERGE", "CREATE", "DROP", "ALTER", "COPY", "CALL", "DO", "GRANT", "REVOKE", "TRUNCATE", "INTO"}
    if tokens & forbidden:
        raise ValueError('Disallowed SQL keyword: ' + ', '.join(sorted(tokens & forbidden)))


def load_manifest(path=None):
    path = Path(path or ROOT / "manifest.json").resolve()
    manifest = load_json(path)
    entries = manifest["queries"] if isinstance(manifest, dict) else manifest
    ids = [x["id"] for x in entries]
    if len(ids) != len(set(ids)):
        raise ValueError("Duplicate query IDs in manifest")
    for entry in entries:
        p = (path.parent / entry["path"]).resolve()
        if not p.is_relative_to(path.parent):
            raise ValueError("Query path escapes the manifest folder")
        text = p.read_text(encoding="utf-8-sig")
        validate_sql(text.replace("{{schema}}", '"omopcdm"'))
        entry = dict(entry)
        entry["_path"] = str(p)
        entry["_sql"] = text
        entry["sha256"] = sha256(p)
        yield entry


def schema_name(value):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", value):
        raise ValueError("Schema must be one simple SQL identifier, not a SQL expression.")
    return '"' + value + '"'


def select_entries(args):
    entries = list(load_manifest(args.manifest))
    selected = set(args.query or [])
    topics = set(getattr(args, 'topic', None) or [])
    missing = selected - {e["id"] for e in entries}
    if missing:
        raise ValueError("Unknown query IDs: " + ", ".join(sorted(missing)))
    missing_topics = topics - {e['topic'] for e in entries}
    if missing_topics:
        raise ValueError('Unknown topics: ' + ', '.join(sorted(missing_topics)))
    return [e for e in entries if ((not selected and e.get("enabled", True)) or e["id"] in selected) and (not topics or e['topic'] in topics)]


def marker_row(entry, site, status, message):
    return dict(category=entry["topic"], variable="Screening execution", result=message,
                site=site, topic=entry["topic"], status=status, numeric_value=None, unit="",
                numerator=None, denominator=None, query_id=entry["id"], source_file=entry["path"],
                source_sheet="", source_cell="", source_formula="", section="", note="")


def run_database(args):
    try:
        import psycopg
    except ImportError as e:
        raise ValueError('Database mode needs psycopg: install requirements-db.txt.') from e
    quoted_schema = schema_name(args.schema)
    if not re.fullmatch(r'Site_\d{2,}', args.site):
        raise ValueError('Use a neutral Site_01 style alias for --site.')
    entries = select_entries(args)
    rows, executions = [], []
    # DSN stays in the environment and is never included in outputs or errors.
    if not getattr(args, "confirm_site_connection", False):
        raise ValueError("Confirm that the connection and schema contain only the selected site. A site alias does not filter database rows.")
    dsn_key = args.dsn_env or f"OMOP_{args.site.upper()}_DSN"
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", dsn_key):
        raise ValueError("Invalid connection environment variable name.")
    dsn = os.environ.get(dsn_key, "")
    if not dsn.strip():
        raise ValueError("The selected site's connection environment variable is not configured. Generic connection defaults are not used.")
    try:
        conn = psycopg.connect(dsn, connect_timeout=10, application_name="omop_fitness_readonly")
    except Exception as e:
        raise ValueError(f"Database connection failed ({type(e).__name__}); check local environment settings. Details are not logged to avoid credential disclosure.") from None
    try:
        conn.read_only = True
        for entry in entries:
            start = time.monotonic()
            try:
                with conn.transaction():
                    with conn.cursor() as cur:
                        cur.execute("SELECT set_config('statement_timeout', %s, true)", (str(args.timeout * 1000),))
                        cur.execute("SELECT set_config('lock_timeout', '5000', true)")
                        cur.execute("SELECT table_name FROM information_schema.tables WHERE table_schema=%s", (args.schema,))
                        available = {r[0] for r in cur.fetchall()}
                        absent = set(entry.get("required_tables", [])) - available
                        if absent:
                            rows.append(marker_row(entry, args.site, "not_available", "Missing table or no visibility: " + ", ".join(sorted(absent))))
                            executions.append({"id": entry["id"], "status": "not_available", "sha256": entry["sha256"], "seconds": round(time.monotonic()-start, 3)})
                            continue
                        cur.execute(entry["_sql"].replace("{{schema}}", quoted_schema))
                        columns = [c.name for c in cur.description]
                        expected = {"category", "variable", "result", "numerator", "denominator"}
                        if set(columns) != expected or len(columns) != 5:
                            raise ValueError("SQL output must contain exactly category, variable, result, numerator, denominator.")
                        data = cur.fetchmany(args.max_rows + 1)
                        if len(data) > args.max_rows:
                            raise ValueError("Aggregate row cap exceeded; output was not exported.")
                        for values in data:
                            raw = dict(zip(columns, values))
                            parsed = parse_result(raw["result"], variable=str(raw["variable"]))
                            num, den = raw.get("numerator"), raw.get("denominator")
                            if den is not None and float(den) == 0 and raw["result"] is None:
                                parsed.update(status="denominator_zero", result="N/A (zero denominator)")
                            row = marker_row(entry, args.site, "observed", "")
                            row.update(raw)
                            row.update(parsed)
                            row["numerator"], row["denominator"] = num, den
                            if args.suppress_below > 0:
                                sensitive = [float(x) for x in (num, den) if x is not None]
                                if any(0 < x < args.suppress_below for x in sensitive):
                                    row.update(result="Suppressed", numeric_value=None, numerator=None, denominator=None, status="suppressed")
                            rows.append(row)
                        if not data:
                            rows.append(marker_row(entry, args.site, "not_assessed", "Query returned no aggregate rows; absence is not zero."))
                        executions.append({"id": entry["id"], "status": "completed", "sha256": entry["sha256"], "result_rows": len(data), "seconds": round(time.monotonic()-start, 3)})
            except Exception as e:
                code = getattr(e, "sqlstate", None)
                message = f"Query failed ({type(e).__name__}, SQLSTATE {code or 'n/a'}). Check local schema and query contract."
                rows.append(marker_row(entry, args.site, "error", message))
                executions.append({"id": entry["id"], "status": "error", "sqlstate": code, "error_type": type(e).__name__, "sha256": entry["sha256"], "seconds": round(time.monotonic()-start, 3)})
    finally:
        conn.close()
    return rows, {"mode": "database", "cdm_version": "5.4 target", "vocabulary_version": args.vocabulary_version,
                  "query_manifest_sha256": sha256(args.manifest) if Path(args.manifest).is_file() else "not supplied",
                  "scope": "All rows visible to the configured database role; no cohort or date restriction is applied.",
                  "schema": args.schema, "site": args.site, "executions": executions,
                  "suppression_threshold": args.suppress_below,
                  "privacy": "Local aggregate output, not automatically safe for external sharing. No complementary suppression guarantee."}


def export_outputs(rows, metadata, output, no_docx=False):
    from single_site import assert_single_site, assert_alias_scope, isolate_metadata, prepare_site_rows, assert_private_paths
    assert_private_paths(output, mode=metadata.get("mode"), package_dir=ROOT)
    rows = list(rows)
    sites = {r.get("site") for r in rows}
    if len(sites) != 1:
        raise ValueError("Export requires results from exactly one selected site.")
    site = next(iter(sites))
    assert_single_site(rows, site)
    rows = prepare_site_rows(rows, site)
    metadata = isolate_metadata(dict(metadata), rows, site)
    assert_alias_scope(metadata, site)
    out = Path(output).resolve()
    if out.exists() and any(out.iterdir()):
        raise ValueError("Output directory is non-empty. Choose a new directory so existing results are preserved.")
    out.mkdir(parents=True, exist_ok=True)
    metadata.pop('_private_site_map', None)
    metadata.update(run_id=str(uuid.uuid4()), created_utc=datetime.now(timezone.utc).isoformat(), pipeline_version=VERSION,
                    result_rows=len(rows), sites=sorted({r["site"] for r in rows}),
                    interpretation="Screening evidence only; no validated clinical phenotype or universal fitness score.")
    from reporting import write_docx
    from historical_interpretation import RULE_VERSION, findings_for_rows
    metadata['feedback_rule_version'] = RULE_VERSION
    findings = findings_for_rows(rows)
    assert_single_site(rows, site, findings)
    write_csv(out / "summary.csv", rows, FIELDS)
    dump_json(out / "summary.json", rows)
    finding_fields = ["site", "topic", "severity", "title", "definition", "result", "status", "assessment", "evidence", "impact", "action", "source", "calculation_source", "evidence_basis", "evidence_sources", "evidence_limit"]
    write_csv(out / "findings.csv", findings, finding_fields)
    dump_json(out / "findings.json", findings)
    dump_json(out / "run_manifest.json", metadata)
    if not no_docx:
        write_docx(rows, findings, out / "feedback_report.docx", metadata)
    return out, len(findings)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    imp = sub.add_parser("import-workbooks", help="Import existing cross-site Excel aggregates; never runs embedded code or SQL")
    imp.add_argument("--input", required=True)
    imp.add_argument("--site", required=True, help="One neutral site alias; no combined output is produced")
    imp.add_argument("--output", required=True)
    imp.add_argument("--no-docx", action="store_true")
    imp.add_argument("--private-site-map", help="Optional local JSON mapping to reuse/create outside the output folder; never include it in a shared package")
    db = sub.add_parser("run-db", help="Run reviewed aggregate screening queries in read-only PostgreSQL transactions")
    for parser in (db, sub.add_parser("validate", help="Validate the enabled SQL pack without database access"), sub.add_parser("export-sql", help="Render schema-qualified SQL for local review")):
        parser.add_argument("--manifest", default=str(ROOT / "manifest.json"))
        parser.add_argument("--query", action="append", help="Specific query ID; repeat to select several")
        parser.add_argument("--topic", action="append", help="Manifest topic to run; repeat to select several")
        parser.add_argument("--schema", default="omopcdm")
    db.add_argument("--site", required=True)
    db.add_argument("--output", required=True)
    db.add_argument("--dsn-env", default=None, help="Selected-site connection environment key; default OMOP_SITE_01_DSN for Site_01")
    db.add_argument("--confirm-site-connection", action="store_true", help="Attest that the configured database/schema contains only the selected site's data")
    db.add_argument("--timeout", type=int, default=180)
    db.add_argument("--max-rows", type=int, default=10000)
    db.add_argument("--suppress-below", type=int, default=0, help="Optional basic small-cell suppression; not a de-identification guarantee")
    db.add_argument("--vocabulary-version", default="not supplied")
    db.add_argument("--no-docx", action="store_true")
    sub.choices["export-sql"].add_argument("--output", required=True)
    a = p.parse_args(argv)
    try:
        if a.command in {"import-workbooks", "run-db"}:
            from single_site import assert_private_paths
            assert_private_paths(a.output, getattr(a, "private_site_map", None),
                                 mode="workbook_import" if a.command == "import-workbooks" else "database", package_dir=ROOT)
        if getattr(a, 'output', None):
            target = Path(a.output)
            if target.exists() and (not target.is_dir() or any(target.iterdir())):
                raise ValueError('Output directory must be new or empty; existing results are never overwritten.')
        if a.command == "import-workbooks":
            site_map = load_json(a.private_site_map) if a.private_site_map and Path(a.private_site_map).exists() else None
            rows, metadata = import_workbooks(a.input, site_map)
            if a.private_site_map:
                mp = Path(a.private_site_map).resolve()
                if mp.is_relative_to(Path(a.output).resolve()):
                    raise ValueError('Private site mapping must be outside the output folder.')
                dump_json(mp, metadata['_private_site_map'])
            from single_site import prepare_site_rows
            rows = prepare_site_rows(rows, a.site)
        elif a.command == "run-db":
            if a.timeout < 1 or a.max_rows < 1 or a.suppress_below < 0:
                raise ValueError("Timeout/row cap must be positive and suppression non-negative.")
            rows, metadata = run_database(a)
        else:
            entries = select_entries(a)
            quoted = schema_name(a.schema)
            if a.command == "export-sql":
                out = Path(a.output)
                if out.exists() and any(out.iterdir()):
                    raise ValueError("SQL output directory must be empty.")
                out.mkdir(parents=True, exist_ok=True)
                for e in entries:
                    (out / (e["id"] + ".sql")).write_text(e["_sql"].replace("{{schema}}", quoted), encoding="utf-8")
            print(f"Validated {len(entries)} queries (static checks only; no database execution).")
            return 0
        out, count = export_outputs(rows, metadata, a.output, a.no_docx)
        print(f"Created {len(rows)} result rows and {count} findings in {out}")
        return 2 if any(r.get("status") == "error" for r in rows) else 0
    except (ValueError, FileNotFoundError, ImportError) as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
