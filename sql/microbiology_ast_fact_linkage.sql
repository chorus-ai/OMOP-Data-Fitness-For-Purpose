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
)
SELECT 'microbiology_ast / fact linkage'::text AS category, v.variable, v.result, v.numerator, v.denominator
FROM stats
CROSS JOIN LATERAL (VALUES
    ('microbiology_records_with_fact_relationship', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (with_fact_n) / NULLIF((n),0),2)::text || '%' END, (with_fact_n)::numeric, (n)::numeric),
    ('fact_specimen_links_same_person', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (specimen_n) / NULLIF((n),0),2)::text || '%' END, (specimen_n)::numeric, (n)::numeric),
    ('fact_microbiology_measurement_links_same_person', CASE WHEN (n) = 0 THEN NULL::text ELSE ROUND(100.0 * (measurement_n) / NULLIF((n),0),2)::text || '%' END, (measurement_n)::numeric, (n)::numeric),
    ('ast_to_culture_candidate_fact_links', CASE WHEN (ast_n) = 0 THEN NULL::text ELSE ROUND(100.0 * (ast_culture_n) / NULLIF((ast_n),0),2)::text || '%' END, (ast_culture_n)::numeric, (ast_n)::numeric),
    ('semantic_review_required', 'FACT_RELATIONSHIP endpoints are checked in both directions and de-duplicated. Relationship concepts and isolate-antibiotic semantics still require review. Other valid event-link paths may exist even if these counts are zero.'::text, NULL::numeric, NULL::numeric)
) AS v(variable, result, numerator, denominator)
ORDER BY variable;
