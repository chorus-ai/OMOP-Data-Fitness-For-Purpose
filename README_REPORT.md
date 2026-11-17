# Site report contract, v0.4

This is an initial, non-exhaustive screening based on limited measurements. It cannot certify a dataset, site or clinical use case as fit.

One site only. Raw variable/result/status and query/source locators are retained. Numeric numerators and denominators are used only when supplied. Reports show a reviewed SQL-specific definition, denominator description, value, interpretation and next action. Findings CSV/JSON additionally expose `assessment`: descriptive, unmapped, unavailable or invalid.

All supported exports and `reporting.assess()` use `historical_interpretation.py`. The former keyword-based engine and obsolete assertions were replaced; the pre-merge files are retained in the external backup. A plausible label without matching query and section does not receive a guessed interpretation. Legacy workbook imports therefore require provenance reconciliation before automatic interpretation; their data are still preserved.

`info` means a mapped descriptive result, not acceptable quality. `review` means invalid, unavailable or unmapped evidence, not a clinical severity level. Coverage counts describe these interpretation states, not the completeness of the clinical domain. N/A and invalid counts are overlapping subsets of review, not additional results.

Zero is distinct from no result. A percentage with explicitly supplied denominator zero is undefined. Historical N/A without a supplied denominator stays reported N/A. Counts are not incidence or validated episodes. Percentages apply to their stated eligible subset. Presence is not correctness, co-occurrence is not linkage, and candidate terminology is not confirmed treatment.

Unrecognized text inventories remain descriptive. No external clinical thresholds, automated corrections, site ranking or readiness score are supplied. Recommended actions are follow-up checks, not actions already executed. Sources point to SQL provenance, not evidence that the recommendations have been clinically validated.

Mixed-site outputs are rejected. Real exports belong outside the code package. The selected schema must already contain only the intended site: the output alias is not a database filter.

## Document design
The generator and blank template use Times New Roman, with a 22-point title, 15/12-point section headings and readable 10.5-point table text. Table headers repeat across pages; results, next actions and source locators are visually separated without changing their meaning. PDF uses installed Times New Roman, with an installed serif fallback when unavailable. The current fictional example is in `example/`.

## Evidence-aware rules
Rule version 3.1.0 adds per-metric SQL locators, public semantic sources and explicit support limitations. Rounded percentage endpoints are not treated as exact counts. See EVIDENCE.md. Findings exports carry calculation_source, evidence_basis, evidence_sources and evidence_limit; DOCX/PDF provide matching source references.
