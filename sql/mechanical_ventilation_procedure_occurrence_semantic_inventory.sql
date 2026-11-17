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
kind_rows AS (
 SELECT DISTINCT c.procedure_occurrence_id AS event_id, v.provenance, v.kind
 FROM candidate_rows c
 CROSS JOIN LATERAL (VALUES ('standard', standard_kind), ('source', source_kind), ('value', value_kind)) v(provenance,kind)
 WHERE v.kind IS NOT NULL
), counts AS (
 SELECT provenance, kind, COUNT(*) AS n FROM kind_rows GROUP BY provenance,kind
)
SELECT 'mechanical_ventilation / procedure_occurrence / semantic candidates'::text AS category,
       provenance || '/' || kind AS variable, n::text AS result,
       n::numeric AS numerator, NULL::numeric AS denominator
FROM counts ORDER BY provenance, kind;
