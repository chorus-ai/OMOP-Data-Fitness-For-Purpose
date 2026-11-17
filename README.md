# OMOP data fitness for purpose, v0.4

**This is an initial, non-exhaustive screening with limited measurements. It is a starting point, not a comprehensive assessment or a site-level fitness decision.**

This version corrects automated explanations of the existing default workflow. No SQL selection, cohort logic, metric formula or query order has changed.

## Run
Open `Run_site_assessment.ipynb`, run setup cells, enter connection settings and one site alias, select its schema, confirm single-site scope and click the screening button. Supply the password at the prompt; never save it in the notebook. The site alias labels outputs; it does not filter a shared schema. See `NOTEBOOK_GUIDE.md`.

## Actual default scope: 18 SQL queries, seven themes
- Microbiology: standardized-concept candidate use, culture counts/positivity and existence flags. Does not validate specimen Р Р†РІР‚В РІР‚в„ў organism Р Р†РІР‚В РІР‚в„ў AST (antimicrobial susceptibility testing) links.
- Infusions: norepinephrine and propofol candidates, timestamps, intervals and rate-like representations. Does not reconstruct validated administered dose trajectories.
- Ventilation: candidate procedure/observation/device records, time and visit fields. Does not establish ventilation episodes or duration.
- Code status: candidate records and broad categories; DNR/DNI limitations remain combined in the historical query. Multiple categories per visit do not demonstrate temporal changes.
- Fluid balance: selected intake/output records and prerequisites. Does not compute a validated complete balance.
- Dialysis/RRT (renal replacement therapy): treatment/removal candidates and co-occurrence. Does not establish indications or validate treatment sessions.
- Transfusion: 12 adapted aggregate queries. Candidate records, semantic groups and visit validation do not establish administered red-cell units, paediatric volume or first-ICU-day overlap.

Six historical queries retain their original SQL logic with schema substitution only. Twelve transfusion queries are earlier reconstructions, not exact replay of a recovered final historical query. Other modular SQL files are supplementary and do not run from this button. Enabling them would require a separately reviewed scope change.

## Interpretation
`registry_hist_a.json`, `registry_hist_b.json` and `registry_transfusion.json` define 309 exact query/section/variable contracts, including possible dynamically emitted groups. This is not a promise that every query returns every row. `METRIC_RULES.csv` is the reviewable catalogue. Each contract identifies its measurement, denominator, next action and limitations. These are SQL-derived operational explanations, not externally validated clinical thresholds.

Unknown query/section/variable combinations remain **unmapped**, including imported legacy workbook labels without verified query provenance. No keyword-based fallback assigns them a clinical meaning. Zero, missing, reported N/A, explicit zero denominator, suppression and failed execution remain distinct. Numeric contradictions are rejected. Text inventories are described conservatively, not parsed as validated clinical facts.

Reports, CSV and JSON use one interpretation engine. `info` means mapped descriptive evidence; `review` means unavailable, invalid or unmapped evidence, not clinical severity. Denominator descriptions are not inferred numeric counts. Each site gets a separate output directory; real site exports must stay outside the code package.

## Provenance and validation
`screening_manifest.json` retains query order, executable checksums, table requirements and reconstructed-source hashes. Private discussion links remain outside this repository. Deleted hard-coded-schema originals and the legacy import notebook are not required.

The project owner reports that all SQL scripts were previously tested against real databases. No real database was accessed for this integration; the updated automated interpretations and assembled workflow are evaluated separately with offline and synthetic tests. Read `VALIDATION.md` for the current results. Previous SQL experience does not by itself validate the new interpretations or make this limited screen exhaustive.

## Example report
The current `example/` folder contains the current synthetic DOCX/PDF and matching CSV/JSON outputs. All sample values are fictional. Generated reports and the blank template use Times New Roman, clear heading levels, repeated table headers and separately labelled next actions and sources.

See [Interpretation evidence and limits](EVIDENCE.md) for per-metric provenance, rounding behavior and the limits of automated follow-up advice.
