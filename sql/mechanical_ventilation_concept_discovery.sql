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
stats AS (
 SELECT COUNT(*) AS n,
        COUNT(*) FILTER (WHERE standard_concept = 'S') AS standard_n,
        COUNT(*) FILTER (WHERE inherited_seed) AS seed_n,
        (SELECT COUNT(*) FROM seed) AS seed_total,
        COUNT(DISTINCT vocabulary_id) AS vocabulary_n,
        COUNT(DISTINCT domain_id) AS domain_n,
        (SELECT STRING_AGG(concept_id::text || ': ' || concept_name || ' [' || domain_id || '; ' || vocabulary_id || ']', '; ' ORDER BY concept_id)
         FROM (SELECT * FROM candidate_concepts WHERE inherited_seed ORDER BY concept_id LIMIT 100) s) AS seed_metadata
 FROM candidate_concepts
)
SELECT 'mechanical_ventilation / concept discovery'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('candidate_concepts', (n)::text, (n)::numeric, NULL::numeric),
    ('standard_candidate_concepts', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (standard_n) / NULLIF((n),0),2)::text || '%' END, (standard_n)::numeric, (n)::numeric),
    ('inherited_seeds_present_and_valid', CASE WHEN (seed_total) = 0 THEN NULL::text ELSE ROUND(100.0 * (seed_n) / NULLIF((seed_total),0),2)::text || '%' END, (seed_n)::numeric, (seed_total)::numeric),
    ('candidate_vocabularies', (vocabulary_n)::text, (vocabulary_n)::numeric, NULL::numeric),
    ('candidate_domains', (domain_n)::text, (domain_n)::numeric, NULL::numeric),
    ('concept_validation_status', 'DISCOVERY_ONLY. Inherited seeds and name matches require review against installed vocabulary and clinical meaning. No validated phenotype is supplied.'::text, NULL::numeric, NULL::numeric),
    ('inherited_seed_metadata', COALESCE(seed_metadata,'No inherited seed found'), NULL::numeric, NULL::numeric),
    ('semantic_review_required', 'Validate invasive versus noninvasive support, intubation/extubation times and episodes. Airway procedures, FiO2, PEEP or a ventilator device alone do not prove mechanical ventilation.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
