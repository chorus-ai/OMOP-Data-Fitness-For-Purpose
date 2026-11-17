-- PostgreSQL 12+, OMOP CDM 5.4. READ ONLY; aggregate output only.
-- Discovery screen, not a validated phenotype. Zero hits mean not detected under this screen.
-- Regex discovery is limited to CONCEPT; clinical source text is never scanned before candidate filtering.
WITH
seed(concept_id, seed_kind) AS (VALUES (3175080, 'DNI'), (4119499, 'DNR'), (3172086, 'DNR_DNI_LIMITED'), (3172879, 'FULL_CODE')),
candidate_concepts AS MATERIALIZED (
    SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
           c.standard_concept, c.concept_class_id, c.concept_code,
           s.concept_id IS NOT NULL AS inherited_seed,
           COALESCE(s.seed_kind, CASE WHEN c.concept_name ~* 'dnr.{0,20}dni|dni.{0,20}dnr|resuscitat.{0,40}intubat|limited.{0,3}(code|resuscitat)|partial.{0,3}code' THEN 'DNR_DNI_LIMITED'
    WHEN c.concept_name ~* 'do.{0,3}not.{0,3}intubat|not.{0,3}for.{0,3}intubat|(^|[^a-z])dni([^a-z]|$)' THEN 'DNI'
    WHEN c.concept_name ~* 'do.{0,3}not.{0,3}resuscitat|not.{0,3}for.{0,3}resuscitat|(^|[^a-z])dnr([^a-z]|$)|allow.{0,3}natural.{0,3}death' THEN 'DNR'
    WHEN c.concept_name ~* 'full.{0,3}code|full.{0,3}resuscitat|all.{0,20}resuscitative.{0,10}measure' THEN 'FULL_CODE'
    ELSE 'GENERIC_CODE_STATUS' END) AS candidate_kind
    FROM {{schema}}.concept c
    LEFT JOIN seed s ON s.concept_id = c.concept_id
    WHERE c.concept_id <> 0 AND c.invalid_reason IS NULL
      AND (s.concept_id IS NOT NULL OR c.concept_name ~* 'code.{0,3}status|full.{0,3}code|resuscitation.{0,15}(status|preference|order)|do.{0,3}not.{0,3}(resuscitat|intubat)|not.{0,3}for.{0,3}(resuscitat|intubat)|(^|[^a-z])(dnr|dni)([^a-z]|$)|limited.{0,3}(code|resuscitat)|partial.{0,3}code|allow.{0,3}natural.{0,3}death|advance.{0,3}directive' )
      
),
candidate_rows AS MATERIALIZED (
    SELECT d.*, cs.concept_id IS NOT NULL AS standard_match,
           cc.concept_id IS NOT NULL AS source_match, cv.concept_id IS NOT NULL AS value_match,
           cs.candidate_kind AS standard_kind, cc.candidate_kind AS source_kind,
           cv.candidate_kind AS value_kind
    FROM {{schema}}.observation d
    LEFT JOIN candidate_concepts cs ON cs.concept_id = d.observation_concept_id
    LEFT JOIN candidate_concepts cc ON cc.concept_id = d.observation_source_concept_id
    LEFT JOIN candidate_concepts cv ON cv.concept_id = d.value_as_concept_id
    WHERE d.observation_concept_id IN (SELECT concept_id FROM candidate_concepts)
       OR d.observation_source_concept_id IN (SELECT concept_id FROM candidate_concepts)
       OR d.value_as_concept_id IN (SELECT concept_id FROM candidate_concepts)
),
stats AS (
 SELECT COUNT(*) AS n,
  COUNT(*) FILTER (WHERE c.visit_occurrence_id IS NOT NULL) AS linked_n,
  COUNT(*) FILTER (WHERE c.visit_occurrence_id IS NOT NULL AND v.visit_occurrence_id IS NULL) AS orphan_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND v.person_id <> c.person_id) AS person_mismatch_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND v.person_id = c.person_id) AS valid_person_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND c.observation_datetime IS NOT NULL AND v.visit_start_datetime IS NOT NULL AND v.visit_end_datetime IS NOT NULL) AS comparable_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND c.observation_datetime IS NOT NULL AND v.visit_start_datetime IS NOT NULL AND v.visit_end_datetime IS NOT NULL AND (c.observation_datetime < v.visit_start_datetime OR c.observation_datetime > v.visit_end_datetime)) AS outside_n
 FROM candidate_rows c
 LEFT JOIN {{schema}}.visit_occurrence v ON v.visit_occurrence_id=c.visit_occurrence_id
)
SELECT 'code_status / observation / visit validation'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('visit_id_resolves_same_person', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (valid_person_n) / NULLIF((linked_n),0),2)::text || '%' END, (valid_person_n)::numeric, (linked_n)::numeric),
    ('orphan_visit_id', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (orphan_n) / NULLIF((linked_n),0),2)::text || '%' END, (orphan_n)::numeric, (linked_n)::numeric),
    ('visit_person_mismatch', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (person_mismatch_n) / NULLIF((linked_n),0),2)::text || '%' END, (person_mismatch_n)::numeric, (linked_n)::numeric),
    ('event_outside_linked_visit_datetime', CASE WHEN (comparable_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (outside_n) / NULLIF((comparable_n),0),2)::text || '%' END, (outside_n)::numeric, (comparable_n)::numeric),
    ('semantic_review_required', 'Out-of-visit timestamps may reflect charting, transfers or source-time conventions. This checks start/event time only; ICU visit_detail boundaries need separate review.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
