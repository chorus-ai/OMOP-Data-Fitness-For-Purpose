-- PostgreSQL 12+, OMOP CDM 5.4. READ ONLY; aggregate output only.
-- Discovery screen, not a validated phenotype. Zero hits mean not detected under this screen.
-- Regex discovery is limited to CONCEPT; clinical source text is never scanned before candidate filtering.
WITH
seed(concept_id, seed_kind) AS (VALUES (4090200, 'IN_IV'), (3037253, 'IN_IV'), (3035591, 'IN_IV'), (3037775, 'IN_IV'), (21491171, 'IN_NUTRITION'), (37153230, 'IN_NUTRITION'), (21491169, 'IN_ENTERAL_ORAL'), (3012677, 'IN_ENTERAL_ORAL'), (3002791, 'IN_ENTERAL_ORAL'), (3020617, 'IN_ENTERAL_ORAL'), (3017465, 'IN_ENTERAL_ORAL'), (3014013, 'IN_ENTERAL_ORAL'), (21491170, 'IN_ENTERAL_ORAL'), (3010494, 'IN_ENTERAL_ORAL'), (21493071, 'IN_ENTERAL_ORAL'), (21493079, 'IN_ENTERAL_ORAL'), (37311741, 'IN_ENTERAL_ORAL'), (21491173, 'OUT_URINE'), (21493221, 'OUT_URINE'), (3016267, 'OUT_URINE'), (3008828, 'OUT_URINE'), (3008071, 'OUT_URINE'), (3018727, 'OUT_URINE'), (3014835, 'OUT_URINE'), (3014315, 'OUT_URINE'), (4264378, 'OUT_URINE'), (40484209, 'OUT_DRAIN'), (4090194, 'OUT_DRAIN'), (3006376, 'OUT_DRAIN'), (3026556, 'OUT_DRAIN'), (3023454, 'OUT_DRAIN'), (3025727, 'OUT_DRAIN'), (3017152, 'OUT_DRAIN'), (3037836, 'OUT_DRAIN'), (21491180, 'OUT_DRAIN'), (21491181, 'OUT_DRAIN'), (21491183, 'OUT_DRAIN'), (21491184, 'OUT_DRAIN'), (21491185, 'OUT_DRAIN'), (3021505, 'OUT_BLOOD'), (3016687, 'OUT_BLOOD'), (21493943, 'OUT_BLOOD'), (4354266, 'OUT_BLOOD'), (3009631, 'OUT_BLOOD'), (1989402, 'OUT_RRT'), (1988590, 'OUT_RRT'), (1989626, 'OUT_RRT'), (1988731, 'OUT_RRT'), (4139443, 'OUT_RRT'), (3018366, 'OUT_TOTAL_OTHER'), (3012848, 'OUT_TOTAL_OTHER'), (3008540, 'OUT_TOTAL_OTHER'), (3020433, 'OUT_TOTAL_OTHER'), (3028277, 'OUT_TOTAL_OTHER')),
candidate_concepts AS MATERIALIZED (
    SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
           c.standard_concept, c.concept_class_id, c.concept_code,
           s.concept_id IS NOT NULL AS inherited_seed,
           COALESCE(s.seed_kind, CASE WHEN c.concept_name ~* 'body.{0,5}weight|patient.{0,5}weight' THEN 'WEIGHT'
    WHEN c.concept_name ~* 'balance' THEN 'BALANCE'
    WHEN c.concept_name ~* 'urine.{0,10}output' THEN 'OUT_URINE'
    WHEN c.concept_name ~* 'ultrafiltrat|dialysis.{0,25}(remov|output)' THEN 'OUT_RRT'
    WHEN c.concept_name ~* 'blood.{0,10}loss' THEN 'OUT_BLOOD'
    WHEN c.concept_name ~* 'output|drain' THEN 'OUT_TOTAL_OTHER'
    WHEN c.concept_name ~* 'parenteral.{0,20}nutrition' THEN 'IN_NUTRITION'
    WHEN c.concept_name ~* 'oral|enteral|formula|feeding' THEN 'IN_ENTERAL_ORAL'
    WHEN c.concept_name ~* 'intake|input|parenteral' THEN 'IN_IV'
    ELSE 'UNCLASSIFIED_FLUID' END) AS candidate_kind
    FROM {{schema}}.concept c
    LEFT JOIN seed s ON s.concept_id = c.concept_id
    WHERE c.concept_id <> 0 AND c.invalid_reason IS NULL
      AND (s.concept_id IS NOT NULL OR c.concept_name ~* 'fluid.{0,10}(intake|input|output|balance)|oral.{0,20}intake|enteral.{0,25}(intake|volume|formula)|tube.{0,25}(intake|feeding|output)|formula.{0,10}intake|parenteral.{0,20}(fluid|nutrition)|urine.{0,10}output|blood.{0,10}loss|ultrafiltrat.{0,25}(remov|output)|body.{0,5}weight|patient.{0,5}weight' )
      
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
SELECT 'fluid_balance / concept discovery'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('candidate_concepts', (n)::text, (n)::numeric, NULL::numeric),
    ('standard_candidate_concepts', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (standard_n) / NULLIF((n),0),2)::text || '%' END, (standard_n)::numeric, (n)::numeric),
    ('inherited_seeds_present_and_valid', CASE WHEN (seed_total) = 0 THEN NULL::text ELSE ROUND(100.0 * (seed_n) / NULLIF((seed_total),0),2)::text || '%' END, (seed_n)::numeric, (seed_total)::numeric),
    ('candidate_vocabularies', (vocabulary_n)::text, (vocabulary_n)::numeric, NULL::numeric),
    ('candidate_domains', (domain_n)::text, (domain_n)::numeric, NULL::numeric),
    ('concept_validation_status', 'DISCOVERY_ONLY. Inherited seeds and name matches require review against installed vocabulary and clinical meaning. No validated phenotype is supplied.'::text, NULL::numeric, NULL::numeric),
    ('inherited_seed_metadata', COALESCE(seed_metadata,'No inherited seed found'), NULL::numeric, NULL::numeric),
    ('semantic_review_required', 'Validate measured volume versus rate, interval versus cumulative totals, total-versus-component overlap, charting day/time zone and missing output. No volume summation or net balance is computed. Seed concepts inherited from the supplied source material need site vocabulary review.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
