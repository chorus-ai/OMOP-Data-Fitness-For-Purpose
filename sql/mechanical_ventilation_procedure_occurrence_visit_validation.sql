-- PostgreSQL 12+, OMOP CDM 5.4. READ ONLY; aggregate output only.
-- Discovery screen, not a validated phenotype. Zero hits mean not detected under this screen.
-- Regex discovery is limited to CONCEPT; clinical source text is never scanned before candidate filtering.
WITH
seed(concept_id, seed_kind) AS (VALUES (1243692, 'mv_seed_candidate'), (2008006, 'mv_seed_candidate'), (2008007, 'mv_seed_candidate'), (2008008, 'mv_seed_candidate'), (2008009, 'mv_seed_candidate'), (2108681, 'mv_seed_candidate'), (3655902, 'mv_seed_candidate'), (4039922, 'mv_seed_candidate'), (4055375, 'mv_seed_candidate'), (4055376, 'mv_seed_candidate'), (4074666, 'mv_seed_candidate'), (4177224, 'mv_seed_candidate'), (37152408, 'mv_seed_candidate'), (37152409, 'mv_seed_candidate'), (37152410, 'mv_seed_candidate'), (37152411, 'mv_seed_candidate'), (37152412, 'mv_seed_candidate'), (37157165, 'mv_seed_candidate'), (37157166, 'mv_seed_candidate'), (37158404, 'mv_seed_candidate'), (37158487, 'mv_seed_candidate'), (40486624, 'mv_seed_candidate'), (765576, 'intubation_candidate'), (3657544, 'intubation_candidate'), (4013354, 'intubation_candidate'), (4058031, 'intubation_candidate'), (4119642, 'intubation_candidate'), (4179373, 'intubation_candidate'), (4228313, 'intubation_candidate'), (4303945, 'intubation_candidate'), (4335481, 'intubation_candidate'), (4335583, 'intubation_candidate'), (4335584, 'intubation_candidate'), (4337045, 'intubation_candidate'), (4337615, 'intubation_candidate'), (4337616, 'intubation_candidate'), (4337617, 'intubation_candidate'), (4339623, 'intubation_candidate'), (37206251, 'intubation_candidate'), (44515633, 'intubation_candidate')),
candidate_concepts AS MATERIALIZED (
    SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
           c.standard_concept, c.concept_class_id, c.concept_code,
           s.concept_id IS NOT NULL AS inherited_seed,
           COALESCE(s.seed_kind, CASE WHEN c.concept_name ~* 'extubat' THEN 'extubation_candidate'
    WHEN c.concept_name ~* 'intubat' THEN 'intubation_candidate'
    WHEN c.concept_name ~* 'non.?invasive|cpap|bipap' THEN 'noninvasive_candidate'
    WHEN c.concept_name ~* 'tidal|peep|fio2|inspired.{0,10}oxygen|end.{0,12}expiratory' THEN 'setting_candidate'
    WHEN c.concept_name ~* 'invasive' THEN 'invasive_candidate'
    ELSE 'ventilation_unspecified_candidate' END) AS candidate_kind
    FROM {{schema}}.concept c
    LEFT JOIN seed s ON s.concept_id = c.concept_id
    WHERE c.concept_id <> 0 AND c.invalid_reason IS NULL
      AND (s.concept_id IS NOT NULL OR c.concept_name ~* 'mechanical.{0,20}ventilat|invasive.{0,20}ventilat|artificial.{0,20}ventilat|ventilator|intubat|extubat|positive.{0,12}end.{0,12}expiratory|tidal.{0,10}volume|fraction.{0,15}inspired.{0,10}oxygen|(^|[^a-z])(fio2|peep|cpap|bipap)([^a-z]|$)' )
      
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
SELECT 'mechanical_ventilation / procedure_occurrence / visit validation'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('visit_id_resolves_same_person', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (valid_person_n) / NULLIF((linked_n),0),2)::text || '%' END, (valid_person_n)::numeric, (linked_n)::numeric),
    ('orphan_visit_id', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (orphan_n) / NULLIF((linked_n),0),2)::text || '%' END, (orphan_n)::numeric, (linked_n)::numeric),
    ('visit_person_mismatch', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (person_mismatch_n) / NULLIF((linked_n),0),2)::text || '%' END, (person_mismatch_n)::numeric, (linked_n)::numeric),
    ('event_outside_linked_visit_datetime', CASE WHEN (comparable_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (outside_n) / NULLIF((comparable_n),0),2)::text || '%' END, (outside_n)::numeric, (comparable_n)::numeric),
    ('semantic_review_required', 'Out-of-visit timestamps may reflect charting, transfers or source-time conventions. This checks start/event time only; ICU visit_detail boundaries need separate review.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
