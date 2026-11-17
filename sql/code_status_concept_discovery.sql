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
SELECT 'code_status / concept discovery'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('candidate_concepts', (n)::text, (n)::numeric, NULL::numeric),
    ('standard_candidate_concepts', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (standard_n) / NULLIF((n),0),2)::text || '%' END, (standard_n)::numeric, (n)::numeric),
    ('inherited_seeds_present_and_valid', CASE WHEN (seed_total) = 0 THEN NULL::text ELSE ROUND(100.0 * (seed_n) / NULLIF((seed_total),0),2)::text || '%' END, (seed_n)::numeric, (seed_total)::numeric),
    ('candidate_vocabularies', (vocabulary_n)::text, (vocabulary_n)::numeric, NULL::numeric),
    ('candidate_domains', (domain_n)::text, (domain_n)::numeric, NULL::numeric),
    ('concept_validation_status', 'DISCOVERY_ONLY. Inherited seeds and name matches require review against installed vocabulary and clinical meaning. No validated phenotype is supplied.'::text, NULL::numeric, NULL::numeric),
    ('inherited_seed_metadata', COALESCE(seed_metadata,'No inherited seed found'), NULL::numeric, NULL::numeric),
    ('semantic_review_required', 'Preserve DNR, DNI, combined/limited and full-code distinctions. Standard/source/value conflicts require manual review. Repeated records are not status changes; candidate transitions are not validated clinical changes.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
