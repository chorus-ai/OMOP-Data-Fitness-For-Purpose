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
SELECT 'dialysis_rrt / concept discovery'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('candidate_concepts', (n)::text, (n)::numeric, NULL::numeric),
    ('standard_candidate_concepts', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (standard_n) / NULLIF((n),0),2)::text || '%' END, (standard_n)::numeric, (n)::numeric),
    ('inherited_seeds_present_and_valid', CASE WHEN (seed_total) = 0 THEN NULL::text ELSE ROUND(100.0 * (seed_n) / NULLIF((seed_total),0),2)::text || '%' END, (seed_n)::numeric, (seed_total)::numeric),
    ('candidate_vocabularies', (vocabulary_n)::text, (vocabulary_n)::numeric, NULL::numeric),
    ('candidate_domains', (domain_n)::text, (domain_n)::numeric, NULL::numeric),
    ('concept_validation_status', 'DISCOVERY_ONLY. Inherited seeds and name matches require review against installed vocabulary and clinical meaning. No validated phenotype is supplied.'::text, NULL::numeric, NULL::numeric),
    ('inherited_seed_metadata', COALESCE(seed_metadata,'No inherited seed found'), NULL::numeric, NULL::numeric),
    ('semantic_review_required', 'Separate direct treatment from access and monitoring; actual removed fluid from prescribed targets. Same-visit co-occurrence is not session linkage. No dialysis indication, AKI phenotype or session count is inferred.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
