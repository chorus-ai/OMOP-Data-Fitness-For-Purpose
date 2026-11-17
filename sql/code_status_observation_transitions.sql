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
candidate_rows AS MATERIALIZED (
    SELECT d.*, cs.concept_id IS NOT NULL AS standard_match,
           cc.concept_id IS NOT NULL AS source_match, cv.concept_id IS NOT NULL AS value_match,
           cs.candidate_kind AS standard_kind, cc.candidate_kind AS source_kind,
           cv.candidate_kind AS value_kind
    FROM {{schema}}.observation d
    LEFT JOIN candidate_concepts cs ON cs.concept_id = d.observation_concept_id
    LEFT JOIN candidate_concepts cc ON cc.concept_id = d.observation_source_concept_id
    LEFT JOIN candidate_concepts cv ON cv.concept_id = d.value_as_concept_id
    WHERE d.observation_concept_id IN (SELECT concept_id FROM candidate_concepts)
       OR d.observation_source_concept_id IN (SELECT concept_id FROM candidate_concepts)
       OR d.value_as_concept_id IN (SELECT concept_id FROM candidate_concepts)
),
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
)
SELECT 'code_status / provisional transitions'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('unambiguous_status_candidate', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (classified_n) / NULLIF((n),0),2)::text || '%' END, (classified_n)::numeric, (n)::numeric),
    ('standard_source_value_status_conflict', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (conflict_n) / NULLIF((n),0),2)::text || '%' END, (conflict_n)::numeric, (n)::numeric),
    ('generic_or_unclassified_status', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (generic_n) / NULLIF((n),0),2)::text || '%' END, (generic_n)::numeric, (n)::numeric),
    ('conflicting_status_timestamps', (same_time_conflict_n)::text, (same_time_conflict_n)::numeric, NULL::numeric),
    ('comparable_status_pairs', (comparable_pairs_n)::text, (comparable_pairs_n)::numeric, NULL::numeric),
    ('candidate_semantic_status_transitions', CASE WHEN (comparable_pairs_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (transition_n) / NULLIF((comparable_pairs_n),0),2)::text || '%' END, (transition_n)::numeric, (comparable_pairs_n)::numeric),
    ('transition_definition', 'Ordered distinct timestamps within person and visit; repeated labels are not changes. Conflicting timestamps break comparability. Row-level conflicts and generic rows are excluded, so apparent transitions still require source review and cannot prove clinical changes.'::text, NULL::numeric, NULL::numeric),
    ('semantic_review_required', 'Preserve DNR, DNI, combined/limited and full-code distinctions. Standard/source/value conflicts require manual review. Repeated records are not status changes; candidate transitions are not validated clinical changes.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
