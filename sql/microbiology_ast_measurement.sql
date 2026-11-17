-- PostgreSQL 12+, OMOP CDM 5.4. READ ONLY; aggregate output only.
-- Discovery screen, not a validated phenotype. Zero hits mean not detected under this screen.
-- Regex discovery is limited to CONCEPT; clinical source text is never scanned before candidate filtering.
WITH
seed(concept_id, seed_kind) AS (SELECT NULL::integer, NULL::text WHERE FALSE),
candidate_concepts AS MATERIALIZED (
    SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
           c.standard_concept, c.concept_class_id, c.concept_code,
           s.concept_id IS NOT NULL AS inherited_seed,
           COALESCE(s.seed_kind, CASE WHEN c.concept_name ~* 'susceptib|antibiotic.{0,20}sensitiv|minimum.{0,12}inhibitory|(^|[^a-z])mic([^a-z]|$)' THEN 'ast_candidate'
    WHEN c.concept_name ~* 'positive.{0,25}(blood.{0,10})?culture|culture.{0,40}(panel|molecular|nucleic|pcr)' THEN 'reflex_or_molecular_candidate'
    WHEN c.concept_name ~* 'blood.{0,40}culture|culture.{0,40}blood' THEN 'blood_culture_candidate'
    WHEN c.concept_class_id ~* '^organism$' THEN 'organism_value_candidate'
    ELSE 'other_microbiology_candidate' END) AS candidate_kind
    FROM {{schema}}.concept c
    LEFT JOIN seed s ON s.concept_id = c.concept_id
    WHERE c.concept_id <> 0 AND c.invalid_reason IS NULL
      AND (s.concept_id IS NOT NULL OR c.concept_name ~* 'culture|microbiolog|susceptib|antibiotic.{0,20}sensitiv|minimum.{0,12}inhibitory|(^|[^a-z])mic([^a-z]|$)|organism.{0,20}(identif|isolat)|species.{0,10}identif' OR c.concept_class_id ~* '^organism$')
      
),
candidate_rows AS MATERIALIZED (
    SELECT d.*, cs.concept_id IS NOT NULL AS standard_match,
           cc.concept_id IS NOT NULL AS source_match, cv.concept_id IS NOT NULL AS value_match,
           cs.candidate_kind AS standard_kind, cc.candidate_kind AS source_kind,
           cv.candidate_kind AS value_kind
    FROM {{schema}}.measurement d
    LEFT JOIN candidate_concepts cs ON cs.concept_id = d.measurement_concept_id
    LEFT JOIN candidate_concepts cc ON cc.concept_id = d.measurement_source_concept_id
    LEFT JOIN candidate_concepts cv ON cv.concept_id = d.value_as_concept_id
    WHERE d.measurement_concept_id IN (SELECT concept_id FROM candidate_concepts)
       OR d.measurement_source_concept_id IN (SELECT concept_id FROM candidate_concepts)
       OR d.value_as_concept_id IN (SELECT concept_id FROM candidate_concepts)
),
stats AS (SELECT
    COUNT(*) AS n,
    COUNT(DISTINCT person_id) AS patients_n,
    COUNT(*) FILTER (WHERE standard_match) AS standard_n,
    COUNT(*) FILTER (WHERE source_match) AS source_n,
    COUNT(*) FILTER (WHERE value_match) AS value_n,
    COUNT(*) FILTER (WHERE source_match AND NOT standard_match) AS source_only_n,
    COUNT(*) FILTER (WHERE measurement_concept_id IS NULL OR measurement_concept_id = 0) AS unmapped_n,
    COUNT(*) FILTER (WHERE measurement_datetime IS NOT NULL) AS datetime_n,
    COUNT(*) FILTER (WHERE measurement_datetime IS NOT NULL AND measurement_datetime::time = TIME '00:00:00') AS midnight_n,
    COUNT(*) FILTER (WHERE measurement_datetime::date <> measurement_date) AS date_mismatch_n,
    COUNT(*) FILTER (WHERE visit_occurrence_id IS NOT NULL) AS visit_n,
    COUNT(*) FILTER (WHERE visit_detail_id IS NOT NULL) AS detail_n,
    COUNT(*) FILTER (WHERE measurement_type_concept_id IS NOT NULL AND measurement_type_concept_id <> 0) AS type_n,
    COUNT(*) FILTER (WHERE value_as_number IS NOT NULL) AS numeric_n,
    COUNT(*) FILTER (WHERE value_as_number < 0) AS negative_n,
    COUNT(*) FILTER (WHERE value_as_number = 0) AS zero_n,
    COUNT(*) FILTER (WHERE unit_concept_id IS NOT NULL AND unit_concept_id <> 0) AS unit_n,
    COUNT(*) FILTER (WHERE unit_concept_id IN (SELECT concept_id FROM {{schema}}.concept WHERE invalid_reason IS NULL AND (LOWER(concept_code) IN ('ml','l','ul','dl','[foz_us]') OR LOWER(concept_name) IN ('milliliter','liter','microliter','deciliter')))) AS volume_unit_n,
    COUNT(*) FILTER (WHERE value_as_number IS NOT NULL AND unit_concept_id IS NOT NULL AND unit_concept_id <> 0 AND measurement_datetime IS NOT NULL AND visit_occurrence_id IS NOT NULL) AS joint_n,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(unit_source_value), '') IS NOT NULL) AS unit_source_n,
    COUNT(*) FILTER (WHERE measurement_event_id IS NOT NULL AND meas_event_field_concept_id IS NOT NULL AND meas_event_field_concept_id <> 0) AS event_link_n
FROM candidate_rows)
SELECT 'microbiology_ast / measurement'::text AS category, v.variable, v.result, v.numerator, v.denominator
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
    ('with_numeric_value', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (numeric_n) / NULLIF((n),0),2)::text || '%' END, (numeric_n)::numeric, (n)::numeric),
    ('negative_numeric_value', CASE WHEN (numeric_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (negative_n) / NULLIF((numeric_n),0),2)::text || '%' END, (negative_n)::numeric, (numeric_n)::numeric),
    ('zero_numeric_value', CASE WHEN (numeric_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (zero_n) / NULLIF((numeric_n),0),2)::text || '%' END, (zero_n)::numeric, (numeric_n)::numeric),
    ('with_unit_concept', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (unit_n) / NULLIF((n),0),2)::text || '%' END, (unit_n)::numeric, (n)::numeric),
    ('volume_unit_concept_candidate', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (volume_unit_n) / NULLIF((n),0),2)::text || '%' END, (volume_unit_n)::numeric, (n)::numeric),
    ('numeric_unit_datetime_visit_jointly_complete', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (joint_n) / NULLIF((n),0),2)::text || '%' END, (joint_n)::numeric, (n)::numeric),
    ('with_unit_source_value', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (unit_source_n) / NULLIF((n),0),2)::text || '%' END, (unit_source_n)::numeric, (n)::numeric),
    ('with_event_id_and_field', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (event_link_n) / NULLIF((n),0),2)::text || '%' END, (event_link_n)::numeric, (n)::numeric),
    ('semantic_review_required', 'Separate primary cultures from reflex or molecular panels and repeat tests; reconcile organism-only results, negatives, contamination and specimen-isolate-antibiotic endpoints. No clinical positivity is inferred by this pack.'::text, NULL::numeric, NULL::numeric),
    ('linkage_interpretation', 'Visit IDs are presence checks, not referential integrity or ICU overlap. Event IDs need field-concept and endpoint validation; FACT_RELATIONSHIP is an additional possible path.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
