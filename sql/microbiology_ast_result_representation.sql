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
enriched AS (
 SELECT r.*,v.concept_class_id AS value_class,v.concept_name AS value_label,
  (standard_kind='ast_candidate' OR source_kind='ast_candidate') IS TRUE AS is_ast,
  (standard_kind='blood_culture_candidate' OR source_kind='blood_culture_candidate') IS TRUE AS is_primary_blood,
  (standard_kind='reflex_or_molecular_candidate' OR source_kind='reflex_or_molecular_candidate') IS TRUE AS is_reflex
 FROM candidate_rows r LEFT JOIN {{schema}}.concept v ON v.concept_id=r.value_as_concept_id
),
stats AS (
 SELECT COUNT(*) AS n,
  COUNT(*) FILTER(WHERE is_ast) AS ast_n,
  COUNT(*) FILTER(WHERE is_ast AND value_as_number IS NOT NULL) AS ast_numeric_n,
  COUNT(*) FILTER(WHERE is_ast AND value_as_number IS NOT NULL AND unit_concept_id<>0) AS ast_numeric_unit_n,
  COUNT(*) FILTER(WHERE is_ast AND value_label ~* '^susceptible$|^intermediate$|^resistant$|susceptible.{0,20}(dose|exposure)') AS ast_interpretation_n,
  COUNT(*) FILTER(WHERE value_class ~* '^organism$') AS organism_value_n,
  COUNT(*) FILTER(WHERE is_primary_blood AND NOT is_reflex) AS primary_n,
  COUNT(*) FILTER(WHERE is_reflex) AS reflex_n,
  COUNT(*) FILTER(WHERE is_primary_blood AND NOT is_reflex AND value_as_concept_id<>0) AS primary_coded_result_n,
  COUNT(*) FILTER(WHERE is_primary_blood AND NOT is_reflex AND NULLIF(TRIM(value_source_value),'') IS NOT NULL) AS primary_source_result_n,
  COUNT(*) FILTER(WHERE is_primary_blood AND NOT is_reflex AND value_class ~* '^organism$') AS primary_organism_n
 FROM enriched
)
SELECT 'microbiology_ast / result representation'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('ast_candidate_records', (ast_n)::text, (ast_n)::numeric, NULL::numeric),
    ('ast_with_numeric_value', CASE WHEN (ast_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (ast_numeric_n) / NULLIF((ast_n),0),2)::text || '%' END, (ast_numeric_n)::numeric, (ast_n)::numeric),
    ('ast_numeric_with_unit_concept', CASE WHEN (ast_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (ast_numeric_unit_n) / NULLIF((ast_n),0),2)::text || '%' END, (ast_numeric_unit_n)::numeric, (ast_n)::numeric),
    ('ast_sir_coded_interpretation_candidate', CASE WHEN (ast_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (ast_interpretation_n) / NULLIF((ast_n),0),2)::text || '%' END, (ast_interpretation_n)::numeric, (ast_n)::numeric),
    ('organism_coded_value_candidates', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (organism_value_n) / NULLIF((n),0),2)::text || '%' END, (organism_value_n)::numeric, (n)::numeric),
    ('primary_blood_culture_candidates', (primary_n)::text, (primary_n)::numeric, NULL::numeric),
    ('reflex_or_molecular_candidates', (reflex_n)::text, (reflex_n)::numeric, NULL::numeric),
    ('primary_culture_with_coded_result', CASE WHEN (primary_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (primary_coded_result_n) / NULLIF((primary_n),0),2)::text || '%' END, (primary_coded_result_n)::numeric, (primary_n)::numeric),
    ('primary_culture_with_source_result', CASE WHEN (primary_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (primary_source_result_n) / NULLIF((primary_n),0),2)::text || '%' END, (primary_source_result_n)::numeric, (primary_n)::numeric),
    ('primary_culture_organism_value_candidate', CASE WHEN (primary_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (primary_organism_n) / NULLIF((primary_n),0),2)::text || '%' END, (primary_organism_n)::numeric, (primary_n)::numeric),
    ('clinical_positivity_status', 'NOT_COMPUTED. Lexical positive/growth/detected matching is insufficient. Validate primary-culture denominator, negative overrides, organism-only values, contaminants, reflex testing and test duplication.'::text, NULL::numeric, NULL::numeric),
    ('semantic_review_required', 'Separate primary cultures from reflex or molecular panels and repeat tests; reconcile organism-only results, negatives, contamination and specimen-isolate-antibiotic endpoints. No clinical positivity is inferred by this pack.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
