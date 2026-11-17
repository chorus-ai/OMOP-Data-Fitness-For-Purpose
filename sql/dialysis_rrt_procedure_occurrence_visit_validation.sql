-- PostgreSQL 12+, OMOP CDM 5.4. READ ONLY; aggregate output only.
-- Discovery screen, not a validated phenotype. Zero hits mean not detected under this screen.
-- Regex discovery is limited to CONCEPT; clinical source text is never scanned before candidate filtering.
WITH
seed(concept_id, seed_kind) AS (VALUES (1989402, 'removal_seed_candidate'), (1988590, 'removal_seed_candidate'), (1989626, 'removal_seed_candidate'), (1988731, 'removal_seed_candidate'), (4139443, 'removal_seed_candidate')),
candidate_concepts AS MATERIALIZED (
    SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
           c.standard_concept, c.concept_class_id, c.concept_code,
           s.concept_id IS NOT NULL AS inherited_seed,
           COALESCE(s.seed_kind, CASE WHEN c.concept_name ~* 'target|prescri|desired|to.{0,3}be.{0,3}removed' THEN 'target_removal_candidate'
    WHEN c.concept_name ~* 'removed|fluid.{0,10}output|ultrafiltrat.{0,15}remov' THEN 'actual_removal_candidate'
    WHEN c.concept_name ~* 'catheter|access|fistula|preoperative' THEN 'access_candidate'
    WHEN REGEXP_REPLACE(c.concept_name, '(^|[^a-z])health[[:space:]-]*care[[:space:]-]+(professionals?|providers?|practitioners?)([^a-z]|$)', ' ', 'gi')
         ~* '(^|[^a-z])(comments?|(?:re)?assess(?:ment|ments|ed|ing)?|monitor(?:ing|ed|s)?|care|aftercare|history|status|clearance|flow|pressure)([^a-z]|$)' THEN 'documentation_or_monitoring_candidate'
    WHEN c.concept_name ~* 'continuous|crrt|ckrt|cvvh' THEN 'continuous_rrt_candidate'
    WHEN c.concept_name ~* 'peritoneal' THEN 'peritoneal_dialysis_candidate'
    ELSE 'other_rrt_candidate' END) AS candidate_kind
    FROM {{schema}}.concept c
    LEFT JOIN seed s ON s.concept_id = c.concept_id
    WHERE c.concept_id <> 0 AND c.invalid_reason IS NULL
      AND (s.concept_id IS NOT NULL OR c.concept_name ~* 'dialysis|ha?emofiltrat|ha?emodiafiltrat|(renal|kidney).{0,5}replacement|(^|[^a-z])(crrt|ckrt|cvvh|cvvhd|cvvhdf)([^a-z]|$)|ultrafiltrat.{0,25}(remov|target|volume)|fluid.{0,20}(removed|removal)|desired.{0,5}fluid.{0,5}loss' )
      AND c.concept_name !~* 'culture|microbiolog|bacteri|susceptib'
),
candidate_rows AS MATERIALIZED (
    SELECT d.*, cs.concept_id IS NOT NULL AS standard_match,
           cc.concept_id IS NOT NULL AS source_match, FALSE AS value_match,
           cs.candidate_kind AS standard_kind, cc.candidate_kind AS source_kind,
           NULL::text AS value_kind
    FROM {{schema}}.procedure_occurrence d
    LEFT JOIN candidate_concepts cs ON cs.concept_id = d.procedure_concept_id
    LEFT JOIN candidate_concepts cc ON cc.concept_id = d.procedure_source_concept_id
    
    WHERE d.procedure_concept_id IN (SELECT concept_id FROM candidate_concepts)
       OR d.procedure_source_concept_id IN (SELECT concept_id FROM candidate_concepts)
       
),
stats AS (
 SELECT COUNT(*) AS n,
  COUNT(*) FILTER (WHERE c.visit_occurrence_id IS NOT NULL) AS linked_n,
  COUNT(*) FILTER (WHERE c.visit_occurrence_id IS NOT NULL AND v.visit_occurrence_id IS NULL) AS orphan_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND v.person_id <> c.person_id) AS person_mismatch_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND v.person_id = c.person_id) AS valid_person_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND c.procedure_datetime IS NOT NULL AND v.visit_start_datetime IS NOT NULL AND v.visit_end_datetime IS NOT NULL) AS comparable_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND c.procedure_datetime IS NOT NULL AND v.visit_start_datetime IS NOT NULL AND v.visit_end_datetime IS NOT NULL AND (c.procedure_datetime < v.visit_start_datetime OR c.procedure_datetime > v.visit_end_datetime)) AS outside_n
 FROM candidate_rows c
 LEFT JOIN {{schema}}.visit_occurrence v ON v.visit_occurrence_id=c.visit_occurrence_id
)
SELECT 'dialysis_rrt / procedure_occurrence / visit validation'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('visit_id_resolves_same_person', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (valid_person_n) / NULLIF((linked_n),0),2)::text || '%' END, (valid_person_n)::numeric, (linked_n)::numeric),
    ('orphan_visit_id', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (orphan_n) / NULLIF((linked_n),0),2)::text || '%' END, (orphan_n)::numeric, (linked_n)::numeric),
    ('visit_person_mismatch', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (person_mismatch_n) / NULLIF((linked_n),0),2)::text || '%' END, (person_mismatch_n)::numeric, (linked_n)::numeric),
    ('event_outside_linked_visit_datetime', CASE WHEN (comparable_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (outside_n) / NULLIF((comparable_n),0),2)::text || '%' END, (outside_n)::numeric, (comparable_n)::numeric),
    ('semantic_review_required', 'Out-of-visit timestamps may reflect charting, transfers or source-time conventions. This checks start/event time only; ICU visit_detail boundaries need separate review.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
