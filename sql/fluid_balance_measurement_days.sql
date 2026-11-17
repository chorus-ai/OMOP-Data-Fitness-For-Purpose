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
classified AS MATERIALIZED (
 SELECT *,
  (COALESCE(standard_kind,'') LIKE 'IN_%' OR COALESCE(source_kind,'') LIKE 'IN_%') AS is_input,
  (COALESCE(standard_kind,'') LIKE 'OUT_%' OR COALESCE(source_kind,'') LIKE 'OUT_%') AS is_output,
  (standard_kind='WEIGHT' OR source_kind='WEIGHT') IS TRUE AS is_weight,
  (standard_kind='BALANCE' OR source_kind='BALANCE') IS TRUE AS is_balance
 FROM candidate_rows
),
days AS (
 SELECT person_id,visit_occurrence_id,measurement_datetime::date AS chart_day,
  BOOL_OR(is_input AND NOT is_output) AS has_input,
  BOOL_OR(is_output AND NOT is_input) AS has_output,
  BOOL_OR(is_weight) AS has_weight
 FROM classified
 WHERE measurement_datetime IS NOT NULL AND visit_occurrence_id IS NOT NULL
  AND value_as_number IS NOT NULL AND unit_concept_id IS NOT NULL AND unit_concept_id<>0
 GROUP BY person_id,visit_occurrence_id,measurement_datetime::date
),
stats AS (
 SELECT (SELECT COUNT(*) FROM classified) AS n,
  (SELECT COUNT(*) FROM classified WHERE is_input AND NOT is_output) AS input_n,
  (SELECT COUNT(*) FROM classified WHERE is_output AND NOT is_input) AS output_n,
  (SELECT COUNT(*) FROM classified WHERE is_input AND is_output) AS ambiguous_direction_n,
  (SELECT COUNT(*) FROM classified WHERE is_balance) AS balance_n,
  (SELECT COUNT(*) FROM classified WHERE is_weight) AS weight_n,
  COUNT(*) FILTER(WHERE has_input OR has_output) AS fluid_days_n,
  COUNT(*) FILTER(WHERE has_input AND has_output) AS both_days_n,
  COUNT(*) FILTER(WHERE has_input AND has_output AND has_weight) AS both_weight_days_n
 FROM days
)
SELECT 'fluid_balance / quantitative candidate days'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('input_candidate_records', (input_n)::text, (input_n)::numeric, NULL::numeric),
    ('output_candidate_records', (output_n)::text, (output_n)::numeric, NULL::numeric),
    ('ambiguous_input_output_classification', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (ambiguous_direction_n) / NULLIF((n),0),2)::text || '%' END, (ambiguous_direction_n)::numeric, (n)::numeric),
    ('cumulative_or_net_balance_candidates', (balance_n)::text, (balance_n)::numeric, NULL::numeric),
    ('body_weight_candidates', (weight_n)::text, (weight_n)::numeric, NULL::numeric),
    ('patient_visit_days_with_quantitative_fluid_candidate', (fluid_days_n)::text, (fluid_days_n)::numeric, NULL::numeric),
    ('patient_visit_days_with_both_input_output', CASE WHEN (fluid_days_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (both_days_n) / NULLIF((fluid_days_n),0),2)::text || '%' END, (both_days_n)::numeric, (fluid_days_n)::numeric),
    ('both_input_output_days_with_weight', CASE WHEN (both_days_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (both_weight_days_n) / NULLIF((both_days_n),0),2)::text || '%' END, (both_weight_days_n)::numeric, (both_days_n)::numeric),
    ('day_denominator_definition', 'Denominator includes only patient-visit-calendar-days with a numeric input or output candidate, a nonzero unit concept and datetime. Days with no records are not observable here. Presence of both directions is not complete 24-hour balance.'::text, NULL::numeric, NULL::numeric),
    ('semantic_review_required', 'Validate measured volume versus rate, interval versus cumulative totals, total-versus-component overlap, charting day/time zone and missing output. No volume summation or net balance is computed. Seed concepts inherited from the supplied source material need site vocabulary review.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
