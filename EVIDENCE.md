# Interpretation evidence and limits

This is an initial, non-exhaustive screen based on limited measurements. It does not certify a site, dataset or clinical use case as fit.

## Traceability
Each of the 309 exact metric contracts contains a repository-relative SQL path, SHA256 and output locator, plus public semantic references, recommendation basis and support limitations. METRIC_RULES.csv exposes the same definitions, advice and public references. Findings CSV/JSON separate the result provenance from the evidence supporting follow-up advice. DOCX/PDF rows cite the corresponding methods references.

SQL-derived definitions explain what was counted. Official OMOP documentation explains field conventions. Recommended next checks are qualified analytical inferences, not observed causes or automatically executed repairs. A source citation does not validate a local concept selection, ETL mapping or clinical phenotype.

## Percentage precision
Percentages retain the source SQL precision. Rounded zero or 100 does not establish an exact zero numerator or complete coverage. When numerical numerator and denominator are supplied, consistency checks allow half the source rounding unit plus floating-point tolerance. Historical N/A remains unknown unless a zero denominator is supplied explicitly.

## Scope
Missing optional CDM fields can restrict a specific analysis without violating CDM conformance. Populated timestamps and identifiers do not establish effective event time, timestamp accuracy or valid linkage. Candidate records are not treatment episodes. Recommendations to investigate duplication do not authorize deleting genuine repeated events. General analysis prerequisites are not measured findings.

The project owner reports prior real-database SQL testing. The revised interpretation layer has offline/synthetic checks only and still needs review against representative site results and source conventions before substantive conclusions.

## Public methodological references
- OHDSI. OMOP Common Data Model v5.4: https://ohdsi.github.io/CommonDataModel/cdm54.html . Field semantics and required/optional conventions; not validation of this workflow.
- OHDSI. Data Quality Dashboard check definitions: https://ohdsi.github.io/DataQualityDashboard/articles/CheckTypeDescriptions.html . Distinct conformance, completeness and plausibility checks; not universal fitness thresholds.
- Blacketer C, Defalco FJ, Ryan PB, Rijnbeek PR. Increasing trust in real-world evidence through evaluation of observational data quality. J Am Med Inform Assoc. 2021;28(10):2251-2257. doi:10.1093/jamia/ocab132. https://pubmed.ncbi.nlm.nih.gov/34313749/ . Methodological support for transparent, configurable quality assessment, not clinical validation of these custom rules.

SQL evidence hashes normalize CRLF to LF for portable Git checkouts and preserve every other UTF-8 byte. The separate file_hashes.json is a byte-level inventory of this generated package snapshot.
