# Run one site

This is an initial, non-exhaustive screen using limited measurements, not a fitness certification.

Create or activate your project Python environment, then run:

```text
python -m pip install -r requirements-notebook.txt -r requirements-db.txt
python -m jupyter lab Run_site_assessment.ipynb
```

The package does not install dependencies automatically. Select this environment as the notebook kernel.

1. Open `Run_site_assessment.ipynb` in Jupyter with the required Python dependencies installed.
2. Run the import/setup cells to display the controls.
3. Enter host, port, database, database user, schema and an anonymized site alias (`Site_01`, etc.). Select a private output directory outside the package.
4. Confirm that the connection/schema contains only this site's authorized data. A site alias labels output; it does not filter a multisite database.
5. Click the screening button and enter the password at the prompt. Do not put credentials in cells, saved outputs or source control.
6. Review every query execution status before interpreting the report. The button runs the historical pack, normalizes returned metrics and writes site-specific outputs. Failed or unavailable queries remain unresolved rather than becoming zero.

## Read the result
The report contains variable definitions, values, interpretation and next actions. Raw CSVs and the normalized summary retain source evidence. Numeric presence, plausible timestamps or matching concepts alone do not establish fitness for the clinical question.

## If a query fails
Check the sanitized error type/SQLSTATE, schema, table availability and source query locally. Raw database errors are not written to the report because they may disclose connection or data details. Resolve the specific problem and rerun. Do not replace an unavailable result with zero, silently alter selection criteria or infer a missing denominator. Any substantive SQL correction needs its own provenance and comparison with the original query.

## Scope and sharing
Use a read-only database account with permission for the selected schema. The workflow is for one site per run. Share only the selected site's report; keep real results and credentials out of the repository. Prior workbook imports remain historical evidence, not newly executed database results.
