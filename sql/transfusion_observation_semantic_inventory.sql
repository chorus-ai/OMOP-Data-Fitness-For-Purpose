-- PostgreSQL 12+, OMOP CDM 5.4. READ ONLY; aggregate output only.
-- Discovery screen, not a validated phenotype. Zero hits mean not detected under this screen.
-- Regex discovery is limited to CONCEPT; clinical source text is never scanned before candidate filtering.
WITH
seed(concept_id, seed_kind) AS (SELECT NULL::integer, NULL::text WHERE FALSE),
candidate_concepts AS MATERIALIZED (
    SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
           c.standard_concept, c.concept_class_id, c.concept_code,
           s.concept_id IS NOT NULL AS inherited_seed,
           COALESCE(s.seed_kind, CASE WHEN c.concept_name ~* 'crossmatch|compatib|screen|order|prepar|request|issue' THEN 'planning_or_compatibility'
    WHEN c.concept_name ~* 'platelet' THEN 'platelet_candidate'
    WHEN c.concept_name ~* 'cryoprecip' THEN 'cryoprecipitate_candidate'
    WHEN c.concept_name ~* 'plasma' THEN 'plasma_candidate'
    WHEN c.concept_name ~* 'red.{0,15}(cell|blood)|erythrocyte' THEN 'rbc_candidate'
    ELSE 'transfusion_unspecified' END) AS candidate_kind
    FROM {{schema}}.concept c
    LEFT JOIN seed s ON s.concept_id = c.concept_id
    WHERE c.concept_id <> 0 AND c.invalid_reason IS NULL
      AND (s.concept_id IS NOT NULL OR c.concept_name ~* 'transfus|packed.{0,15}red.{0,15}(cell|blood)|fresh.{0,10}frozen.{0,10}plasma|cryoprecip|platelet.{0,25}(administr|volume|unit)|blood.{0,15}(product|component)' )
      
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
kind_rows AS (
 SELECT DISTINCT c.observation_id AS event_id, v.provenance, v.kind
 FROM candidate_rows c
 CROSS JOIN LATERAL (VALUES ('standard', standard_kind), ('source', source_kind), ('value', value_kind)) v(provenance,kind)
 WHERE v.kind IS NOT NULL
), counts AS (
 SELECT provenance, kind, COUNT(*) AS n FROM kind_rows GROUP BY provenance,kind
)
SELECT 'transfusion / observation / semantic candidates'::text AS category,
       provenance || '/' || kind AS variable, n::text AS result,
       n::numeric AS numerator, NULL::numeric AS denominator
FROM counts ORDER BY provenance, kind;
