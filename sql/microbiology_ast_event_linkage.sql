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
)
SELECT 'microbiology_ast / event linkage'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('specimen_field_concepts_detected', (specimen_field_concepts_n)::text, (specimen_field_concepts_n)::numeric, NULL::numeric),
    ('measurement_field_concepts_detected', (measurement_field_concepts_n)::text, (measurement_field_concepts_n)::numeric, NULL::numeric),
    ('direct_specimen_event_references', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (specimen_ref_n) / NULLIF((n),0),2)::text || '%' END, (specimen_ref_n)::numeric, (n)::numeric),
    ('specimen_references_resolved', CASE WHEN (specimen_ref_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (specimen_resolved_n) / NULLIF((specimen_ref_n),0),2)::text || '%' END, (specimen_resolved_n)::numeric, (specimen_ref_n)::numeric),
    ('specimen_links_same_person', CASE WHEN (specimen_ref_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (specimen_same_person_n) / NULLIF((specimen_ref_n),0),2)::text || '%' END, (specimen_same_person_n)::numeric, (specimen_ref_n)::numeric),
    ('specimen_links_person_mismatch', CASE WHEN (specimen_ref_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (specimen_person_mismatch_n) / NULLIF((specimen_ref_n),0),2)::text || '%' END, (specimen_person_mismatch_n)::numeric, (specimen_ref_n)::numeric),
    ('linked_specimen_with_datetime', CASE WHEN (specimen_resolved_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (specimen_datetime_n) / NULLIF((specimen_resolved_n),0),2)::text || '%' END, (specimen_datetime_n)::numeric, (specimen_resolved_n)::numeric),
    ('linked_specimen_with_type', CASE WHEN (specimen_resolved_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (specimen_type_n) / NULLIF((specimen_resolved_n),0),2)::text || '%' END, (specimen_type_n)::numeric, (specimen_resolved_n)::numeric),
    ('direct_measurement_event_references', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (measurement_ref_n) / NULLIF((n),0),2)::text || '%' END, (measurement_ref_n)::numeric, (n)::numeric),
    ('measurement_event_links_same_person', CASE WHEN (measurement_ref_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (measurement_same_person_n) / NULLIF((measurement_ref_n),0),2)::text || '%' END, (measurement_same_person_n)::numeric, (measurement_ref_n)::numeric),
    ('semantic_review_required', 'Exact field concepts are discovered from CDM concept metadata. A zero field-concept count makes this path unevaluable. Verify specimen/isolate/antibiotic relationship semantics; resolved IDs and matching person do not prove the intended relationship.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
