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
stats AS (
 SELECT COUNT(*) AS n,
  COUNT(*) FILTER (WHERE c.visit_occurrence_id IS NOT NULL) AS linked_n,
  COUNT(*) FILTER (WHERE c.visit_occurrence_id IS NOT NULL AND v.visit_occurrence_id IS NULL) AS orphan_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND v.person_id <> c.person_id) AS person_mismatch_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND v.person_id = c.person_id) AS valid_person_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND c.measurement_datetime IS NOT NULL AND v.visit_start_datetime IS NOT NULL AND v.visit_end_datetime IS NOT NULL) AS comparable_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND c.measurement_datetime IS NOT NULL AND v.visit_start_datetime IS NOT NULL AND v.visit_end_datetime IS NOT NULL AND (c.measurement_datetime < v.visit_start_datetime OR c.measurement_datetime > v.visit_end_datetime)) AS outside_n
 FROM candidate_rows c
 LEFT JOIN {{schema}}.visit_occurrence v ON v.visit_occurrence_id=c.visit_occurrence_id
)
SELECT 'fluid_balance / measurement / visit validation'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('visit_id_resolves_same_person', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (valid_person_n) / NULLIF((linked_n),0),2)::text || '%' END, (valid_person_n)::numeric, (linked_n)::numeric),
    ('orphan_visit_id', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (orphan_n) / NULLIF((linked_n),0),2)::text || '%' END, (orphan_n)::numeric, (linked_n)::numeric),
    ('visit_person_mismatch', CASE WHEN (linked_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (person_mismatch_n) / NULLIF((linked_n),0),2)::text || '%' END, (person_mismatch_n)::numeric, (linked_n)::numeric),
    ('event_outside_linked_visit_datetime', CASE WHEN (comparable_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (outside_n) / NULLIF((comparable_n),0),2)::text || '%' END, (outside_n)::numeric, (comparable_n)::numeric),
    ('semantic_review_required', 'Out-of-visit timestamps may reflect charting, transfers or source-time conventions. This checks start/event time only; ICU visit_detail boundaries need separate review.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
