-- PostgreSQL 12+, OMOP CDM 5.4. READ ONLY; aggregate output only.
-- Discovery screen, not a validated phenotype. Zero hits mean not detected under this screen.
-- Regex discovery is limited to CONCEPT; clinical source text is never scanned before candidate filtering.
WITH
drug_names(drug_name) AS (VALUES ('norepinephrine'), ('propofol')),
ingredients AS MATERIALIZED (
 SELECT c.concept_id, LOWER(c.concept_name) AS drug_name
 FROM {{schema}}.concept c
 WHERE c.vocabulary_id='RxNorm' AND c.standard_concept='S'
   AND c.concept_class_id='Ingredient' AND c.invalid_reason IS NULL
   AND LOWER(c.concept_name) IN ('norepinephrine','propofol')
),
drug_sets AS MATERIALIZED (
 SELECT drug_name, concept_id FROM ingredients
 UNION
 SELECT i.drug_name, ca.descendant_concept_id
 FROM ingredients i
 JOIN {{schema}}.concept_ancestor ca ON ca.ancestor_concept_id=i.concept_id
 JOIN {{schema}}.concept c ON c.concept_id=ca.descendant_concept_id
 WHERE c.invalid_reason IS NULL AND c.standard_concept='S'
 UNION
 SELECT CASE WHEN c.concept_name ~* 'norepinephrine|noradrenaline|levophed' THEN 'norepinephrine' ELSE 'propofol' END,
        c.concept_id
 FROM {{schema}}.concept c
 WHERE c.invalid_reason IS NULL AND c.concept_id<>0
   AND c.concept_name ~* 'norepinephrine|noradrenaline|levophed|propofol|diprivan'
),
selected_ids AS MATERIALIZED (
 SELECT s.drug_name, d.drug_exposure_id
 FROM {{schema}}.drug_exposure d JOIN drug_sets s ON s.concept_id=d.drug_concept_id
 UNION
 SELECT s.drug_name, d.drug_exposure_id
 FROM {{schema}}.drug_exposure d JOIN drug_sets s ON s.concept_id=d.drug_source_concept_id
),
raw_rows AS MATERIALIZED (
 SELECT s.drug_name,d.*,
  EXISTS (SELECT 1 FROM drug_sets x WHERE x.drug_name=s.drug_name AND x.concept_id=d.drug_concept_id) AS standard_match,
  EXISTS (SELECT 1 FROM drug_sets x WHERE x.drug_name=s.drug_name AND x.concept_id=d.drug_source_concept_id) AS source_match,
  LOWER(REPLACE(REPLACE(REGEXP_REPLACE(COALESCE(d.dose_unit_source_value,''),'[[:space:]]+','','g'),'µ','u'),'μ','u')) AS unit_norm,
  COALESCE(rc.concept_name,'') ~* 'intravenous' AS standard_iv,
  COALESCE(d.route_source_value,'') ~* '(^|[^a-z])(iv|intravenous)([^a-z]|$)' AS source_iv,
  COALESCE(tc.concept_name,'') ~* 'administer|administration' AS administration_type_candidate
 FROM selected_ids s JOIN {{schema}}.drug_exposure d ON d.drug_exposure_id=s.drug_exposure_id
 LEFT JOIN {{schema}}.concept rc ON rc.concept_id=d.route_concept_id
 LEFT JOIN {{schema}}.concept tc ON tc.concept_id=d.drug_type_concept_id
),
drug_rows AS MATERIALIZED (
 SELECT *,
  unit_norm ~ '^(mcg|ug|ng|mg|g)/(kg/)?(min|minute|minutes|h|hr|hour|hours)$' AS dose_rate_unit,
  unit_norm ~ '^(ml|l)/(min|minute|minutes|h|hr|hour|hours)$' AS volume_rate_unit
 FROM raw_rows
),
ordered_intervals AS (
 SELECT drug_name,drug_exposure_id,drug_exposure_end_datetime,
  LEAD(drug_exposure_start_datetime) OVER (
   PARTITION BY drug_name,person_id,visit_occurrence_id
   ORDER BY drug_exposure_start_datetime,drug_exposure_id) AS next_start
 FROM drug_rows
 WHERE visit_occurrence_id IS NOT NULL
  AND drug_exposure_start_datetime IS NOT NULL
  AND drug_exposure_end_datetime>=drug_exposure_start_datetime
),
interval_stats AS (
 SELECT drug_name,
  COUNT(*) FILTER (WHERE next_start IS NOT NULL) AS comparable_pairs_n,
  COUNT(*) FILTER (WHERE next_start IS NOT NULL AND ABS(EXTRACT(EPOCH FROM (drug_exposure_end_datetime-next_start)))<=60) AS contiguous_n,
  COUNT(*) FILTER (WHERE next_start<drug_exposure_end_datetime) AS overlap_n
 FROM ordered_intervals GROUP BY drug_name
),
unit_counts AS (
 SELECT drug_name,LEFT(unit_norm,80) AS unit_label,COUNT(*) AS n
 FROM drug_rows WHERE unit_norm<>'' GROUP BY drug_name,LEFT(unit_norm,80)
),
unit_ranked AS (
 SELECT *,ROW_NUMBER() OVER(PARTITION BY drug_name ORDER BY n DESC,unit_label) AS rn FROM unit_counts
),
unit_inventory AS (
 SELECT drug_name,STRING_AGG(unit_label,'; ' ORDER BY n DESC,unit_label) AS units
 FROM unit_ranked WHERE rn<=20 GROUP BY drug_name
),
type_counts AS (
 SELECT r.drug_name,COALESCE(c.concept_name,'unknown concept') AS label,r.drug_type_concept_id,COUNT(*) AS n
 FROM drug_rows r LEFT JOIN {{schema}}.concept c ON c.concept_id=r.drug_type_concept_id
 GROUP BY r.drug_name,c.concept_name,r.drug_type_concept_id
),
type_ranked AS (
 SELECT *,ROW_NUMBER() OVER(PARTITION BY drug_name ORDER BY n DESC,drug_type_concept_id) AS rn FROM type_counts
),
type_inventory AS (
 SELECT drug_name,STRING_AGG(drug_type_concept_id::text || ': ' || label,'; ' ORDER BY n DESC,drug_type_concept_id) AS types
 FROM type_ranked WHERE rn<=20 GROUP BY drug_name
),
stats AS (
 SELECT names.drug_name,COUNT(d.drug_exposure_id) AS n,
  COUNT(DISTINCT d.person_id) AS patients_n,
  COUNT(*) FILTER(WHERE standard_match) AS standard_n,
  COUNT(*) FILTER(WHERE source_match) AS source_n,
  COUNT(*) FILTER(WHERE source_match AND NOT standard_match) AS source_only_n,
  COUNT(*) FILTER(WHERE d.drug_exposure_start_datetime IS NOT NULL) AS datetime_n,
  COUNT(*) FILTER(WHERE d.drug_exposure_start_datetime IS NOT NULL AND d.drug_exposure_end_datetime IS NOT NULL) AS complete_n,
  COUNT(*) FILTER(WHERE d.drug_exposure_end_datetime>=d.drug_exposure_start_datetime) AS chronological_n,
  COUNT(*) FILTER(WHERE d.drug_exposure_end_datetime>d.drug_exposure_start_datetime) AS positive_n,
  COUNT(*) FILTER(WHERE d.drug_exposure_end_datetime=d.drug_exposure_start_datetime) AS zero_n,
  COUNT(*) FILTER(WHERE d.drug_exposure_end_datetime<d.drug_exposure_start_datetime) AS reversed_n,
  (PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY EXTRACT(EPOCH FROM (d.drug_exposure_end_datetime-d.drug_exposure_start_datetime))/60.0)
   FILTER(WHERE d.drug_exposure_end_datetime>d.drug_exposure_start_datetime))::numeric AS median_minutes,
  COUNT(*) FILTER(WHERE d.quantity IS NOT NULL) AS quantity_n,
  COUNT(*) FILTER(WHERE d.quantity<0) AS negative_quantity_n,
  COUNT(*) FILTER(WHERE d.unit_norm<>'') AS unit_n,
  COUNT(*) FILTER(WHERE d.dose_rate_unit) AS dose_rate_n,
  COUNT(*) FILTER(WHERE d.volume_rate_unit) AS volume_rate_n,
  COUNT(*) FILTER(WHERE d.quantity IS NOT NULL AND d.dose_rate_unit) AS candidate_rate_n,
  COUNT(*) FILTER(WHERE d.quantity IS NOT NULL AND d.volume_rate_unit) AS candidate_volume_rate_n,
  COUNT(*) FILTER(WHERE d.route_concept_id IS NOT NULL AND d.route_concept_id<>0) AS route_n,
  COUNT(*) FILTER(WHERE d.source_iv) AS source_iv_n,
  COUNT(*) FILTER(WHERE d.source_iv AND NOT d.standard_iv) AS iv_mismatch_n,
  COUNT(*) FILTER(WHERE d.administration_type_candidate) AS administration_n,
  COUNT(*) FILTER(WHERE d.visit_occurrence_id IS NOT NULL) AS visit_n,
  COUNT(*) FILTER(WHERE d.visit_detail_id IS NOT NULL) AS detail_n,
  COUNT(*) FILTER(WHERE d.quantity IS NOT NULL AND d.dose_rate_unit AND d.drug_exposure_end_datetime>d.drug_exposure_start_datetime AND d.visit_occurrence_id IS NOT NULL) AS joint_n
 FROM drug_names names LEFT JOIN drug_rows d ON d.drug_name=names.drug_name
 GROUP BY names.drug_name
)
SELECT ('continuous_infusions / ' || s.drug_name || ' / drug_exposure')::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats s LEFT JOIN interval_stats i ON i.drug_name=s.drug_name LEFT JOIN unit_inventory u ON u.drug_name=s.drug_name LEFT JOIN type_inventory t ON t.drug_name=s.drug_name
CROSS JOIN LATERAL (VALUES
    ('candidate_records', (n)::text, (n)::numeric, NULL::numeric),
    ('candidate_patients', (patients_n)::text, (patients_n)::numeric, NULL::numeric),
    ('standard_concept_match', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (standard_n) / NULLIF((n),0),2)::text || '%' END, (standard_n)::numeric, (n)::numeric),
    ('source_concept_match', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (source_n) / NULLIF((n),0),2)::text || '%' END, (source_n)::numeric, (n)::numeric),
    ('source_only_concept_match', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (source_only_n) / NULLIF((n),0),2)::text || '%' END, (source_only_n)::numeric, (n)::numeric),
    ('with_datetime', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (datetime_n) / NULLIF((n),0),2)::text || '%' END, (datetime_n)::numeric, (n)::numeric),
    ('with_complete_datetime_pair', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (complete_n) / NULLIF((n),0),2)::text || '%' END, (complete_n)::numeric, (n)::numeric),
    ('chronologically_valid', CASE WHEN (complete_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (chronological_n) / NULLIF((complete_n),0),2)::text || '%' END, (chronological_n)::numeric, (complete_n)::numeric),
    ('duration_positive', CASE WHEN (complete_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (positive_n) / NULLIF((complete_n),0),2)::text || '%' END, (positive_n)::numeric, (complete_n)::numeric),
    ('duration_zero', CASE WHEN (complete_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (zero_n) / NULLIF((complete_n),0),2)::text || '%' END, (zero_n)::numeric, (complete_n)::numeric),
    ('duration_reversed', CASE WHEN (complete_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (reversed_n) / NULLIF((complete_n),0),2)::text || '%' END, (reversed_n)::numeric, (complete_n)::numeric),
    ('median_positive_duration_minutes', ROUND(median_minutes,2)::text, NULL::numeric, NULL::numeric),
    ('with_quantity', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (quantity_n) / NULLIF((n),0),2)::text || '%' END, (quantity_n)::numeric, (n)::numeric),
    ('negative_quantity', CASE WHEN (quantity_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (negative_quantity_n) / NULLIF((quantity_n),0),2)::text || '%' END, (negative_quantity_n)::numeric, (quantity_n)::numeric),
    ('with_unit_source_value', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (unit_n) / NULLIF((n),0),2)::text || '%' END, (unit_n)::numeric, (n)::numeric),
    ('dose_rate_unit_candidate', CASE WHEN (unit_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (dose_rate_n) / NULLIF((unit_n),0),2)::text || '%' END, (dose_rate_n)::numeric, (unit_n)::numeric),
    ('volume_rate_unit_candidate', CASE WHEN (unit_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (volume_rate_n) / NULLIF((unit_n),0),2)::text || '%' END, (volume_rate_n)::numeric, (unit_n)::numeric),
    ('candidate_numeric_dose_rate', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (candidate_rate_n) / NULLIF((n),0),2)::text || '%' END, (candidate_rate_n)::numeric, (n)::numeric),
    ('candidate_numeric_volume_rate', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (candidate_volume_rate_n) / NULLIF((n),0),2)::text || '%' END, (candidate_volume_rate_n)::numeric, (n)::numeric),
    ('candidate_rate_interval_visit_jointly_complete', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (joint_n) / NULLIF((n),0),2)::text || '%' END, (joint_n)::numeric, (n)::numeric),
    ('with_standard_route', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (route_n) / NULLIF((n),0),2)::text || '%' END, (route_n)::numeric, (n)::numeric),
    ('source_iv_standard_route_mismatch', CASE WHEN (source_iv_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (iv_mismatch_n) / NULLIF((source_iv_n),0),2)::text || '%' END, (iv_mismatch_n)::numeric, (source_iv_n)::numeric),
    ('administration_type_candidate', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (administration_n) / NULLIF((n),0),2)::text || '%' END, (administration_n)::numeric, (n)::numeric),
    ('with_visit_id', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (visit_n) / NULLIF((n),0),2)::text || '%' END, (visit_n)::numeric, (n)::numeric),
    ('with_visit_detail_id', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (detail_n) / NULLIF((n),0),2)::text || '%' END, (detail_n)::numeric, (n)::numeric),
    ('comparable_adjacent_pairs', (COALESCE(i.comparable_pairs_n,0))::text, (COALESCE(i.comparable_pairs_n,0))::numeric, NULL::numeric),
    ('contiguous_within_60_seconds', CASE WHEN (COALESCE(i.comparable_pairs_n,0)) = 0 THEN NULL::text ELSE ROUND(100.0 * (COALESCE(i.contiguous_n,0)) / NULLIF((COALESCE(i.comparable_pairs_n,0)),0),2)::text || '%' END, (COALESCE(i.contiguous_n,0))::numeric, (COALESCE(i.comparable_pairs_n,0))::numeric),
    ('overlapping_adjacent_pairs', CASE WHEN (COALESCE(i.comparable_pairs_n,0)) = 0 THEN NULL::text ELSE ROUND(100.0 * (COALESCE(i.overlap_n,0)) / NULLIF((COALESCE(i.comparable_pairs_n,0)),0),2)::text || '%' END, (COALESCE(i.overlap_n,0))::numeric, (COALESCE(i.comparable_pairs_n,0))::numeric),
    ('dose_units_observed_top20', COALESCE(u.units,'Not detected'), NULL::numeric, NULL::numeric),
    ('drug_types_observed_top20', COALESCE(t.types,'Not detected'), NULL::numeric, NULL::numeric),
    ('semantic_review_required', 'Verify administration provenance, rate versus total quantity, concentration, weight normalization, bag changes, bolus exclusion and episode rules. Adjacent or overlapping rows do not establish continuous treatment.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
