-- PostgreSQL 12+, OMOP CDM 5.4. READ ONLY; aggregate output only.
-- Discovery screen, not a validated phenotype. Zero hits mean not detected under this screen.
-- Regex discovery is limited to CONCEPT; clinical source text is never scanned before candidate filtering.
WITH
seed(concept_id, seed_kind) AS (SELECT NULL::integer, NULL::text WHERE FALSE),
candidate_concepts AS MATERIALIZED (
    SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
           c.standard_concept, c.concept_class_id, c.concept_code,
           s.concept_id IS NOT NULL AS inherited_seed,
           COALESCE(s.seed_kind, CASE WHEN c.concept_name ~* 'crossmatch|compatib|screen|order|prepar|request|issue' THEN 'planning_or_compatibility'
    WHEN c.concept_name ~* 'platelet' THEN 'platelet_candidate'
    WHEN c.concept_name ~* 'cryoprecip' THEN 'cryoprecipitate_candidate'
    WHEN c.concept_name ~* 'plasma' THEN 'plasma_candidate'
    WHEN c.concept_name ~* 'red.{0,15}(cell|blood)|erythrocyte' THEN 'rbc_candidate'
    ELSE 'transfusion_unspecified' END) AS candidate_kind
    FROM {{schema}}.concept c
    LEFT JOIN seed s ON s.concept_id = c.concept_id
    WHERE c.concept_id <> 0 AND c.invalid_reason IS NULL
      AND (s.concept_id IS NOT NULL OR c.concept_name ~* 'transfus|packed.{0,15}red.{0,15}(cell|blood)|fresh.{0,10}frozen.{0,10}plasma|cryoprecip|platelet.{0,25}(administr|volume|unit)|blood.{0,15}(product|component)' )
      
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
SELECT 'transfusion / concept discovery'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('candidate_concepts', (n)::text, (n)::numeric, NULL::numeric),
    ('standard_candidate_concepts', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (standard_n) / NULLIF((n),0),2)::text || '%' END, (standard_n)::numeric, (n)::numeric),
    ('inherited_seeds_present_and_valid', CASE WHEN (seed_total) = 0 THEN NULL::text ELSE ROUND(100.0 * (seed_n) / NULLIF((seed_total),0),2)::text || '%' END, (seed_n)::numeric, (seed_total)::numeric),
    ('candidate_vocabularies', (vocabulary_n)::text, (vocabulary_n)::numeric, NULL::numeric),
    ('candidate_domains', (domain_n)::text, (domain_n)::numeric, NULL::numeric),
    ('concept_validation_status', 'DISCOVERY_ONLY. Inherited seeds and name matches require review against installed vocabulary and clinical meaning. No validated phenotype is supplied.'::text, NULL::numeric, NULL::numeric),
    ('inherited_seed_metadata', COALESCE(seed_metadata,'No inherited seed found'), NULL::numeric, NULL::numeric),
    ('semantic_review_required', 'Verify actual administration versus order, issue or crossmatch; product component, adult units versus pediatric mL, administered volume, and ICU overlap. Quantity alone is not administered volume.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
