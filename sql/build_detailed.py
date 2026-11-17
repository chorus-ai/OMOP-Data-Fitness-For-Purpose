"""Detailed aggregate screens used by build_queries.py. No database access."""
globals().update(api)


def infusion_screen():
    ctes="""drug_names(drug_name) AS (VALUES ('norepinephrine'), ('propofol')),
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
)"""
    rows=[ratio_row("candidate_records","n",None),ratio_row("candidate_patients","patients_n",None),
          ratio_row("standard_concept_match","standard_n"),ratio_row("source_concept_match","source_n"),ratio_row("source_only_concept_match","source_only_n"),
          ratio_row("with_datetime","datetime_n"),ratio_row("with_complete_datetime_pair","complete_n"),ratio_row("chronologically_valid","chronological_n","complete_n"),ratio_row("duration_positive","positive_n","complete_n"),ratio_row("duration_zero","zero_n","complete_n"),ratio_row("duration_reversed","reversed_n","complete_n"),
          "('median_positive_duration_minutes', ROUND(median_minutes,2)::text, NULL::numeric, NULL::numeric)",
          ratio_row("with_quantity","quantity_n"),ratio_row("negative_quantity","negative_quantity_n","quantity_n"),ratio_row("with_unit_source_value","unit_n"),ratio_row("dose_rate_unit_candidate","dose_rate_n","unit_n"),ratio_row("volume_rate_unit_candidate","volume_rate_n","unit_n"),ratio_row("candidate_numeric_dose_rate","candidate_rate_n"),ratio_row("candidate_numeric_volume_rate","candidate_volume_rate_n"),ratio_row("candidate_rate_interval_visit_jointly_complete","joint_n"),
          ratio_row("with_standard_route","route_n"),ratio_row("source_iv_standard_route_mismatch","iv_mismatch_n","source_iv_n"),ratio_row("administration_type_candidate","administration_n"),ratio_row("with_visit_id","visit_n"),ratio_row("with_visit_detail_id","detail_n"),
          ratio_row("comparable_adjacent_pairs","COALESCE(i.comparable_pairs_n,0)",None),ratio_row("contiguous_within_60_seconds","COALESCE(i.contiguous_n,0)","COALESCE(i.comparable_pairs_n,0)"),ratio_row("overlapping_adjacent_pairs","COALESCE(i.overlap_n,0)","COALESCE(i.comparable_pairs_n,0)"),
          "('dose_units_observed_top20', COALESCE(u.units,'Not detected'), NULL::numeric, NULL::numeric)",
          "('drug_types_observed_top20', COALESCE(t.types,'Not detected'), NULL::numeric, NULL::numeric)",
          note_row("semantic_review_required",TOPICS['continuous_infusions']['review'])]
    sql=finish("continuous_infusions / drug_exposure",ctes,rows,"stats s LEFT JOIN interval_stats i ON i.drug_name=s.drug_name LEFT JOIN unit_inventory u ON u.drug_name=s.drug_name LEFT JOIN type_inventory t ON t.drug_name=s.drug_name")
    sql=sql.replace("'continuous_infusions / drug_exposure'::text AS category","('continuous_infusions / ' || s.drug_name || ' / drug_exposure')::text AS category")
    emit("continuous_infusions_drug_exposure","continuous_infusions",["concept","concept_ancestor","drug_exposure"],sql,"Ingredient descendants plus lexical/source candidates; drug-specific interval, dose-unit, quantity, route and provenance checks. Never assumes quantity is actual infusion rate.")
    linked_visit_check("continuous_infusions","drug_exposure")


def microbiology_detail():
    # Raw result text is deliberately not interpreted as clinical positivity.
    ctes=concept_cte("microbiology_ast")+",\n"+candidate_cte("microbiology_ast","measurement")+""",
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
)"""
    rows=[ratio_row("ast_candidate_records","ast_n",None),ratio_row("ast_with_numeric_value","ast_numeric_n","ast_n"),ratio_row("ast_numeric_with_unit_concept","ast_numeric_unit_n","ast_n"),ratio_row("ast_sir_coded_interpretation_candidate","ast_interpretation_n","ast_n"),ratio_row("organism_coded_value_candidates","organism_value_n"),ratio_row("primary_blood_culture_candidates","primary_n",None),ratio_row("reflex_or_molecular_candidates","reflex_n",None),ratio_row("primary_culture_with_coded_result","primary_coded_result_n","primary_n"),ratio_row("primary_culture_with_source_result","primary_source_result_n","primary_n"),ratio_row("primary_culture_organism_value_candidate","primary_organism_n","primary_n"),note_row("clinical_positivity_status","NOT_COMPUTED. Lexical positive/growth/detected matching is insufficient. Validate primary-culture denominator, negative overrides, organism-only values, contaminants, reflex testing and test duplication."),note_row("semantic_review_required",TOPICS['microbiology_ast']['review'])]
    emit("microbiology_ast_result_representation","microbiology_ast",["concept","measurement"],finish("microbiology_ast / result representation",ctes,rows),"Separate provisional primary-culture, reflex and AST concepts, and inspect coded-organism and S/I/R representation without computing positivity.")

    ctes=concept_cte("microbiology_ast")+",\n"+candidate_cte("microbiology_ast","measurement")+""",
specimen_fields AS (
 SELECT concept_id FROM {{schema}}.concept
 WHERE LOWER(concept_code)='specimen.specimen_id' OR LOWER(concept_name)='specimen.specimen_id'
), measurement_fields AS (
 SELECT concept_id FROM {{schema}}.concept
 WHERE LOWER(concept_code)='measurement.measurement_id' OR LOWER(concept_name)='measurement.measurement_id'
), stats AS (
 SELECT COUNT(*) AS n,
  COUNT(*) FILTER(WHERE c.measurement_event_id IS NOT NULL AND c.meas_event_field_concept_id IN (SELECT concept_id FROM specimen_fields)) AS specimen_ref_n,
  COUNT(*) FILTER(WHERE s.specimen_id IS NOT NULL) AS specimen_resolved_n,
  COUNT(*) FILTER(WHERE s.specimen_id IS NOT NULL AND s.person_id=c.person_id) AS specimen_same_person_n,
  COUNT(*) FILTER(WHERE s.specimen_id IS NOT NULL AND s.person_id<>c.person_id) AS specimen_person_mismatch_n,
  COUNT(*) FILTER(WHERE c.measurement_event_id IS NOT NULL AND c.meas_event_field_concept_id IN (SELECT concept_id FROM measurement_fields)) AS measurement_ref_n,
  COUNT(*) FILTER(WHERE target.measurement_id IS NOT NULL AND target.person_id=c.person_id) AS measurement_same_person_n,
  COUNT(*) FILTER(WHERE s.specimen_datetime IS NOT NULL) AS specimen_datetime_n,
  COUNT(*) FILTER(WHERE s.specimen_concept_id IS NOT NULL AND s.specimen_concept_id<>0) AS specimen_type_n,
  (SELECT COUNT(*) FROM specimen_fields) AS specimen_field_concepts_n,
  (SELECT COUNT(*) FROM measurement_fields) AS measurement_field_concepts_n
 FROM candidate_rows c
 LEFT JOIN {{schema}}.specimen s ON s.specimen_id=c.measurement_event_id AND c.meas_event_field_concept_id IN (SELECT concept_id FROM specimen_fields)
 LEFT JOIN {{schema}}.measurement target ON target.measurement_id=c.measurement_event_id AND c.meas_event_field_concept_id IN (SELECT concept_id FROM measurement_fields)
)"""
    rows=[ratio_row("specimen_field_concepts_detected","specimen_field_concepts_n",None),ratio_row("measurement_field_concepts_detected","measurement_field_concepts_n",None),ratio_row("direct_specimen_event_references","specimen_ref_n"),ratio_row("specimen_references_resolved","specimen_resolved_n","specimen_ref_n"),ratio_row("specimen_links_same_person","specimen_same_person_n","specimen_ref_n"),ratio_row("specimen_links_person_mismatch","specimen_person_mismatch_n","specimen_ref_n"),ratio_row("linked_specimen_with_datetime","specimen_datetime_n","specimen_resolved_n"),ratio_row("linked_specimen_with_type","specimen_type_n","specimen_resolved_n"),ratio_row("direct_measurement_event_references","measurement_ref_n"),ratio_row("measurement_event_links_same_person","measurement_same_person_n","measurement_ref_n"),note_row("semantic_review_required","Exact field concepts are discovered from CDM concept metadata. A zero field-concept count makes this path unevaluable. Verify specimen/isolate/antibiotic relationship semantics; resolved IDs and matching person do not prove the intended relationship.")]
    emit("microbiology_ast_event_linkage","microbiology_ast",["concept","measurement","specimen"],finish("microbiology_ast / event linkage",ctes,rows),"Check v5.4 event-field links to specific Specimen and Measurement endpoints, resolving IDs and person identity.")

    ctes=concept_cte("microbiology_ast")+",\n"+candidate_cte("microbiology_ast","measurement")+""",
measurement_domain AS (SELECT domain_concept_id FROM {{schema}}.domain WHERE domain_id='Measurement'),
specimen_domain AS (SELECT domain_concept_id FROM {{schema}}.domain WHERE domain_id='Specimen'),
links AS MATERIALIZED (
 SELECT c.measurement_id,c.person_id,c.standard_kind,c.source_kind,fr.domain_concept_id_2 AS target_domain,fr.fact_id_2 AS target_id
 FROM candidate_rows c JOIN {{schema}}.fact_relationship fr ON fr.fact_id_1=c.measurement_id
 WHERE fr.domain_concept_id_1 IN (SELECT domain_concept_id FROM measurement_domain)
 UNION
 SELECT c.measurement_id,c.person_id,c.standard_kind,c.source_kind,fr.domain_concept_id_1,fr.fact_id_1
 FROM candidate_rows c JOIN {{schema}}.fact_relationship fr ON fr.fact_id_2=c.measurement_id
 WHERE fr.domain_concept_id_2 IN (SELECT domain_concept_id FROM measurement_domain)
), stats AS (
 SELECT (SELECT COUNT(*) FROM candidate_rows) AS n,
  COUNT(DISTINCT l.measurement_id) AS with_fact_n,
  COUNT(DISTINCT l.measurement_id) FILTER(WHERE s.specimen_id IS NOT NULL AND s.person_id=l.person_id) AS specimen_n,
  COUNT(DISTINCT l.measurement_id) FILTER(WHERE m.measurement_id IS NOT NULL AND m.person_id=l.person_id) AS measurement_n,
  COUNT(DISTINCT l.measurement_id) FILTER(WHERE (l.standard_kind='ast_candidate' OR l.source_kind='ast_candidate') AND m.person_id=l.person_id AND (m.standard_kind IN ('blood_culture_candidate','other_microbiology_candidate') OR m.source_kind IN ('blood_culture_candidate','other_microbiology_candidate'))) AS ast_culture_n,
  (SELECT COUNT(*) FROM candidate_rows WHERE standard_kind='ast_candidate' OR source_kind='ast_candidate') AS ast_n
 FROM links l
 LEFT JOIN {{schema}}.specimen s ON s.specimen_id=l.target_id AND l.target_domain IN (SELECT domain_concept_id FROM specimen_domain)
 LEFT JOIN candidate_rows m ON m.measurement_id=l.target_id AND l.target_domain IN (SELECT domain_concept_id FROM measurement_domain)
)"""
    rows=[ratio_row("microbiology_records_with_fact_relationship","with_fact_n"),ratio_row("fact_specimen_links_same_person","specimen_n"),ratio_row("fact_microbiology_measurement_links_same_person","measurement_n"),ratio_row("ast_to_culture_candidate_fact_links","ast_culture_n","ast_n"),note_row("semantic_review_required","FACT_RELATIONSHIP endpoints are checked in both directions and de-duplicated. Relationship concepts and isolate-antibiotic semantics still require review. Other valid event-link paths may exist even if these counts are zero.")]
    emit("microbiology_ast_fact_linkage","microbiology_ast",["concept","domain","measurement","specimen","fact_relationship"],finish("microbiology_ast / fact linkage",ctes,rows),"Endpoint-specific candidate microbiology relationships; does not mistake generic FACT_RELATIONSHIP population for valid culture-AST links.")


def fluid_detail():
    ctes=concept_cte("fluid_balance")+",\n"+candidate_cte("fluid_balance","measurement")+""",
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
)"""
    rows=[ratio_row("input_candidate_records","input_n",None),ratio_row("output_candidate_records","output_n",None),ratio_row("ambiguous_input_output_classification","ambiguous_direction_n"),ratio_row("cumulative_or_net_balance_candidates","balance_n",None),ratio_row("body_weight_candidates","weight_n",None),ratio_row("patient_visit_days_with_quantitative_fluid_candidate","fluid_days_n",None),ratio_row("patient_visit_days_with_both_input_output","both_days_n","fluid_days_n"),ratio_row("both_input_output_days_with_weight","both_weight_days_n","both_days_n"),note_row("day_denominator_definition","Denominator includes only patient-visit-calendar-days with a numeric input or output candidate, a nonzero unit concept and datetime. Days with no records are not observable here. Presence of both directions is not complete 24-hour balance."),note_row("semantic_review_required",TOPICS['fluid_balance']['review'])]
    emit("fluid_balance_measurement_days","fluid_balance",["concept","measurement"],finish("fluid_balance / quantitative candidate days",ctes,rows),"Candidate day-level co-availability of quantitative input, output and weight; no summation, conversion or net balance.")


def code_status_detail():
    ctes=concept_cte("code_status")+",\n"+candidate_cte("code_status","observation")+""",
classified AS MATERIALIZED (
 SELECT r.*,k.classes_n,k.status_kind
 FROM candidate_rows r
 CROSS JOIN LATERAL (
  SELECT COUNT(DISTINCT kind) AS classes_n,MIN(kind) AS status_kind
  FROM (VALUES (r.standard_kind),(r.source_kind),(r.value_kind)) x(kind)
  WHERE kind IN ('DNR','DNI','DNR_DNI_LIMITED','FULL_CODE')
 ) k
),
timestamp_classes AS (
 SELECT person_id,visit_occurrence_id,observation_datetime,
  MIN(status_kind) AS status_kind,COUNT(DISTINCT status_kind) AS classes_n
 FROM classified
 WHERE classes_n=1 AND visit_occurrence_id IS NOT NULL AND observation_datetime IS NOT NULL
 GROUP BY person_id,visit_occurrence_id,observation_datetime
),
ordered AS (
 SELECT *,LAG(status_kind) OVER(PARTITION BY person_id,visit_occurrence_id ORDER BY observation_datetime) AS prior_kind,
  LAG(classes_n) OVER(PARTITION BY person_id,visit_occurrence_id ORDER BY observation_datetime) AS prior_classes_n
 FROM timestamp_classes
),
stats AS (
 SELECT (SELECT COUNT(*) FROM classified) AS n,
  (SELECT COUNT(*) FROM classified WHERE classes_n=1) AS classified_n,
  (SELECT COUNT(*) FROM classified WHERE classes_n>1) AS conflict_n,
  (SELECT COUNT(*) FROM classified WHERE classes_n=0) AS generic_n,
  COUNT(*) FILTER(WHERE classes_n>1) AS same_time_conflict_n,
  COUNT(*) FILTER(WHERE classes_n=1 AND prior_classes_n=1) AS comparable_pairs_n,
  COUNT(*) FILTER(WHERE classes_n=1 AND prior_classes_n=1 AND status_kind<>prior_kind) AS transition_n
 FROM ordered
)"""
    rows=[ratio_row("unambiguous_status_candidate","classified_n"),ratio_row("standard_source_value_status_conflict","conflict_n"),ratio_row("generic_or_unclassified_status","generic_n"),ratio_row("conflicting_status_timestamps","same_time_conflict_n",None),ratio_row("comparable_status_pairs","comparable_pairs_n",None),ratio_row("candidate_semantic_status_transitions","transition_n","comparable_pairs_n"),note_row("transition_definition","Ordered distinct timestamps within person and visit; repeated labels are not changes. Conflicting timestamps break comparability. Row-level conflicts and generic rows are excluded, so apparent transitions still require source review and cannot prove clinical changes."),note_row("semantic_review_required",TOPICS['code_status']['review'])]
    emit("code_status_observation_transitions","code_status",["concept","observation"],finish("code_status / provisional transitions",ctes,rows),"Keep DNR/DNI/full-code/limited classes distinct, flag provenance conflicts, and count only provisional semantic changes.")


infusion_screen()
microbiology_detail()
fluid_detail()
code_status_detail()
