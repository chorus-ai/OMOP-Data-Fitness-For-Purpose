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
stats AS (SELECT
    COUNT(*) AS n,
    COUNT(DISTINCT person_id) AS patients_n,
    COUNT(*) FILTER (WHERE standard_match) AS standard_n,
    COUNT(*) FILTER (WHERE source_match) AS source_n,
    COUNT(*) FILTER (WHERE value_match) AS value_n,
    COUNT(*) FILTER (WHERE source_match AND NOT standard_match) AS source_only_n,
    COUNT(*) FILTER (WHERE procedure_concept_id IS NULL OR procedure_concept_id = 0) AS unmapped_n,
    COUNT(*) FILTER (WHERE procedure_datetime IS NOT NULL) AS datetime_n,
    COUNT(*) FILTER (WHERE procedure_datetime IS NOT NULL AND procedure_datetime::time = TIME '00:00:00') AS midnight_n,
    COUNT(*) FILTER (WHERE procedure_datetime::date <> procedure_date) AS date_mismatch_n,
    COUNT(*) FILTER (WHERE visit_occurrence_id IS NOT NULL) AS visit_n,
    COUNT(*) FILTER (WHERE visit_detail_id IS NOT NULL) AS detail_n,
    COUNT(*) FILTER (WHERE procedure_type_concept_id IS NOT NULL AND procedure_type_concept_id <> 0) AS type_n,
    COUNT(*) FILTER (WHERE quantity IS NOT NULL) AS numeric_n,
    COUNT(*) FILTER (WHERE quantity < 0) AS negative_n,
    COUNT(*) FILTER (WHERE quantity = 0) AS zero_n,
    COUNT(*) FILTER (WHERE procedure_datetime IS NOT NULL AND procedure_end_datetime IS NOT NULL) AS pair_n,
    COUNT(*) FILTER (WHERE procedure_end_datetime > procedure_datetime) AS duration_positive_n,
    COUNT(*) FILTER (WHERE procedure_end_datetime = procedure_datetime) AS duration_zero_n,
    COUNT(*) FILTER (WHERE procedure_end_datetime < procedure_datetime) AS duration_reversed_n
FROM candidate_rows)
SELECT 'mechanical_ventilation / procedure_occurrence'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('candidate_records', (n)::text, (n)::numeric, NULL::numeric),
    ('candidate_patients', (patients_n)::text, (patients_n)::numeric, NULL::numeric),
    ('standard_concept_match', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (standard_n) / NULLIF((n),0),2)::text || '%' END, (standard_n)::numeric, (n)::numeric),
    ('source_concept_match', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (source_n) / NULLIF((n),0),2)::text || '%' END, (source_n)::numeric, (n)::numeric),
    ('value_concept_match', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (value_n) / NULLIF((n),0),2)::text || '%' END, (value_n)::numeric, (n)::numeric),
    ('source_only_concept_match', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (source_only_n) / NULLIF((n),0),2)::text || '%' END, (source_only_n)::numeric, (n)::numeric),
    ('unmapped_standard_concept', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (unmapped_n) / NULLIF((n),0),2)::text || '%' END, (unmapped_n)::numeric, (n)::numeric),
    ('with_datetime', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (datetime_n) / NULLIF((n),0),2)::text || '%' END, (datetime_n)::numeric, (n)::numeric),
    ('midnight_among_datetimes', CASE WHEN (datetime_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (midnight_n) / NULLIF((datetime_n),0),2)::text || '%' END, (midnight_n)::numeric, (datetime_n)::numeric),
    ('date_datetime_disagreement', CASE WHEN (datetime_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (date_mismatch_n) / NULLIF((datetime_n),0),2)::text || '%' END, (date_mismatch_n)::numeric, (datetime_n)::numeric),
    ('with_visit_id', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (visit_n) / NULLIF((n),0),2)::text || '%' END, (visit_n)::numeric, (n)::numeric),
    ('with_visit_detail_id', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (detail_n) / NULLIF((n),0),2)::text || '%' END, (detail_n)::numeric, (n)::numeric),
    ('with_type_concept', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (type_n) / NULLIF((n),0),2)::text || '%' END, (type_n)::numeric, (n)::numeric),
    ('with_quantity', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (numeric_n) / NULLIF((n),0),2)::text || '%' END, (numeric_n)::numeric, (n)::numeric),
    ('negative_numeric_value', CASE WHEN (numeric_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (negative_n) / NULLIF((numeric_n),0),2)::text || '%' END, (negative_n)::numeric, (numeric_n)::numeric),
    ('zero_numeric_value', CASE WHEN (numeric_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (zero_n) / NULLIF((numeric_n),0),2)::text || '%' END, (zero_n)::numeric, (numeric_n)::numeric),
    ('with_complete_datetime_pair', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (pair_n) / NULLIF((n),0),2)::text || '%' END, (pair_n)::numeric, (n)::numeric),
    ('duration_positive', CASE WHEN (pair_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (duration_positive_n) / NULLIF((pair_n),0),2)::text || '%' END, (duration_positive_n)::numeric, (pair_n)::numeric),
    ('duration_zero', CASE WHEN (pair_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (duration_zero_n) / NULLIF((pair_n),0),2)::text || '%' END, (duration_zero_n)::numeric, (pair_n)::numeric),
    ('duration_reversed', CASE WHEN (pair_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (duration_reversed_n) / NULLIF((pair_n),0),2)::text || '%' END, (duration_reversed_n)::numeric, (pair_n)::numeric),
    ('semantic_review_required', 'Validate invasive versus noninvasive support, intubation/extubation times and episodes. Airway procedures, FiO2, PEEP or a ventilator device alone do not prove mechanical ventilation.'::text, NULL::numeric, NULL::numeric),
    ('linkage_interpretation', 'Visit IDs are presence checks, not referential integrity or ICU overlap. Event IDs need field-concept and endpoint validation; FACT_RELATIONSHIP is an additional possible path.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
