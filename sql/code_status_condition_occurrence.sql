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
           cc.concept_id IS NOT NULL AS source_match, FALSE AS value_match,
           cs.candidate_kind AS standard_kind, cc.candidate_kind AS source_kind,
           NULL::text AS value_kind
    FROM {{schema}}.condition_occurrence d
    LEFT JOIN candidate_concepts cs ON cs.concept_id = d.condition_concept_id
    LEFT JOIN candidate_concepts cc ON cc.concept_id = d.condition_source_concept_id
    
    WHERE d.condition_concept_id IN (SELECT concept_id FROM candidate_concepts)
       OR d.condition_source_concept_id IN (SELECT concept_id FROM candidate_concepts)
       
),
stats AS (SELECT
    COUNT(*) AS n,
    COUNT(DISTINCT person_id) AS patients_n,
    COUNT(*) FILTER (WHERE standard_match) AS standard_n,
    COUNT(*) FILTER (WHERE source_match) AS source_n,
    COUNT(*) FILTER (WHERE value_match) AS value_n,
    COUNT(*) FILTER (WHERE source_match AND NOT standard_match) AS source_only_n,
    COUNT(*) FILTER (WHERE condition_concept_id IS NULL OR condition_concept_id = 0) AS unmapped_n,
    COUNT(*) FILTER (WHERE condition_start_datetime IS NOT NULL) AS datetime_n,
    COUNT(*) FILTER (WHERE condition_start_datetime IS NOT NULL AND condition_start_datetime::time = TIME '00:00:00') AS midnight_n,
    COUNT(*) FILTER (WHERE condition_start_datetime::date <> condition_start_date) AS date_mismatch_n,
    COUNT(*) FILTER (WHERE visit_occurrence_id IS NOT NULL) AS visit_n,
    COUNT(*) FILTER (WHERE visit_detail_id IS NOT NULL) AS detail_n,
    COUNT(*) FILTER (WHERE condition_type_concept_id IS NOT NULL AND condition_type_concept_id <> 0) AS type_n,
    COUNT(*) FILTER (WHERE condition_start_datetime IS NOT NULL AND condition_end_datetime IS NOT NULL) AS pair_n,
    COUNT(*) FILTER (WHERE condition_end_datetime > condition_start_datetime) AS duration_positive_n,
    COUNT(*) FILTER (WHERE condition_end_datetime = condition_start_datetime) AS duration_zero_n,
    COUNT(*) FILTER (WHERE condition_end_datetime < condition_start_datetime) AS duration_reversed_n
FROM candidate_rows)
SELECT 'code_status / condition_occurrence'::text AS category, v.variable, v.result, v.numerator, v.denominator
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
    ('with_complete_datetime_pair', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (pair_n) / NULLIF((n),0),2)::text || '%' END, (pair_n)::numeric, (n)::numeric),
    ('duration_positive', CASE WHEN (pair_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (duration_positive_n) / NULLIF((pair_n),0),2)::text || '%' END, (duration_positive_n)::numeric, (pair_n)::numeric),
    ('duration_zero', CASE WHEN (pair_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (duration_zero_n) / NULLIF((pair_n),0),2)::text || '%' END, (duration_zero_n)::numeric, (pair_n)::numeric),
    ('duration_reversed', CASE WHEN (pair_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (duration_reversed_n) / NULLIF((pair_n),0),2)::text || '%' END, (duration_reversed_n)::numeric, (pair_n)::numeric),
    ('semantic_review_required', 'Preserve DNR, DNI, combined/limited and full-code distinctions. Standard/source/value conflicts require manual review. Repeated records are not status changes; candidate transitions are not validated clinical changes.'::text, NULL::numeric, NULL::numeric),
    ('linkage_interpretation', 'Visit IDs are presence checks, not referential integrity or ICU overlap. Event IDs need field-concept and endpoint validation; FACT_RELATIONSHIP is an additional possible path.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
