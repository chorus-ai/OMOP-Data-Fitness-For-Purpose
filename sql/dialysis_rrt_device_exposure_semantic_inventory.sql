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
candidate_rows AS MATERIALIZED (
    SELECT d.*, cs.concept_id IS NOT NULL AS standard_match,
           cc.concept_id IS NOT NULL AS source_match, FALSE AS value_match,
           cs.candidate_kind AS standard_kind, cc.candidate_kind AS source_kind,
           NULL::text AS value_kind
    FROM {{schema}}.device_exposure d
    LEFT JOIN candidate_concepts cs ON cs.concept_id = d.device_concept_id
    LEFT JOIN candidate_concepts cc ON cc.concept_id = d.device_source_concept_id
    
    WHERE d.device_concept_id IN (SELECT concept_id FROM candidate_concepts)
       OR d.device_source_concept_id IN (SELECT concept_id FROM candidate_concepts)
       
),
kind_rows AS (
 SELECT DISTINCT c.device_exposure_id AS event_id, v.provenance, v.kind
 FROM candidate_rows c
 CROSS JOIN LATERAL (VALUES ('standard', standard_kind), ('source', source_kind), ('value', value_kind)) v(provenance,kind)
 WHERE v.kind IS NOT NULL
), counts AS (
 SELECT provenance, kind, COUNT(*) AS n FROM kind_rows GROUP BY provenance,kind
)
SELECT 'dialysis_rrt / device_exposure / semantic candidates'::text AS category,
       provenance || '/' || kind AS variable, n::text AS result,
       n::numeric AS numerator, NULL::numeric AS denominator
FROM counts ORDER BY provenance, kind;
