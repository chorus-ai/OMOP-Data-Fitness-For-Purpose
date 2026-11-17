/* ============================================================================
   MICROBIOLOGY DATA EXPECTATIONS — FAST STATISTICS
   PostgreSQL / OMOP CDM

   IMPORTANT:
   This is a screening query based primarily on standardized
   MEASUREMENT concept names.

   Source-value discovery should be run separately if needed.
   ============================================================================ */

WITH

/* ---------------------------------------------------------------------------
   1. Find potentially relevant concepts in CONCEPT first.
   CONCEPT is much smaller than MEASUREMENT.
   --------------------------------------------------------------------------- */
candidate_base AS MATERIALIZED (
    SELECT
        c.concept_id,
        c.concept_name,
        c.vocabulary_id
    FROM {{schema}}.concept c
    WHERE c.domain_id = 'Measurement'
      AND c.concept_name ~*
          'culture|microbiolog|susceptib|sensitivity|'
          'minimum[[:space:]-]*inhibitory|'
          '(^|[^a-z])mic([^a-z]|$)|'
          'organism|microorganism|isolat|identif'
),


/* ---------------------------------------------------------------------------
   2. Classify candidate concepts.
   Regex now runs only against the candidate concept list.
   --------------------------------------------------------------------------- */
candidate_concepts AS MATERIALIZED (
    SELECT
        concept_id,
        concept_name,
        vocabulary_id,

        /* AST */
        (
            concept_name ~*
                'susceptib|sensitivity|'
                'antimicrobial.{0,30}suscept|'
                'antibiotic.{0,30}suscept|'
                'minimum[[:space:]-]*inhibitory[[:space:]-]*concentration|'
                '(^|[^a-z])mic([^a-z]|$)'
        ) AS is_ast,


        /* Blood culture */
        (
            concept_name ~*
                'blood.{0,50}culture|'
                'culture.{0,50}blood'
        ) AS is_blood_culture,


        /* Organism identification */
        (
            concept_name ~*
                'organism.{0,40}(identif|isolat)|'
                '(identif|isolat).{0,40}organism|'
                'microorganism.{0,40}(identif|isolat)|'
                '(identif|isolat).{0,40}microorganism|'
                'species[[:space:]-]*identif'
        ) AS is_organism_identification

    FROM candidate_base
),


/* ---------------------------------------------------------------------------
   3. Select only microbiology-related MEASUREMENT rows.
   If MEASUREMENT.measurement_concept_id is indexed, this can be very fast.
   --------------------------------------------------------------------------- */
micro_rows AS MATERIALIZED (
    SELECT
        m.measurement_id,
        m.person_id,
        m.measurement_concept_id,
        m.value_as_concept_id,
        m.value_source_value,

        cc.is_ast,
        cc.is_blood_culture,
        cc.is_organism_identification,

        (
            (
                cc.concept_name ~*
                    'culture|microbiolog|'
                    'organism.{0,40}(identif|isolat)|'
                    '(identif|isolat).{0,40}organism|'
                    'microorganism.{0,40}(identif|isolat)|'
                    'species[[:space:]-]*identif'
            )
            AND NOT cc.is_ast
        ) AS is_culture_related

    FROM {{schema}}.measurement m
    JOIN candidate_concepts cc
      ON cc.concept_id = m.measurement_concept_id
),


/* ---------------------------------------------------------------------------
   4. Basic microbiology statistics — one aggregation.
   --------------------------------------------------------------------------- */
micro_stats AS (
    SELECT

        COUNT(DISTINCT measurement_concept_id)
            FILTER (
                WHERE is_culture_related
            ) AS culture_concepts_n,


        COUNT(DISTINCT measurement_concept_id)
            FILTER (
                WHERE is_ast
            ) AS ast_concepts_n,


        COUNT(DISTINCT person_id)
            FILTER (
                WHERE is_blood_culture
            ) AS blood_culture_patients_n,


        COUNT(*)
            FILTER (
                WHERE is_blood_culture
            ) AS blood_culture_records_n,


        BOOL_OR(is_organism_identification)
            AS organism_identification_present,


        BOOL_OR(is_ast)
            AS ast_present

    FROM micro_rows
),


/* ---------------------------------------------------------------------------
   5. Only blood-culture records need result interpretation.
   Therefore VALUE concept join happens only for this subset.
   --------------------------------------------------------------------------- */
blood_culture_rows AS MATERIALIZED (
    SELECT
        mr.measurement_id,
        mr.person_id,
        mr.measurement_concept_id,
        mr.value_as_concept_id,
        mr.value_source_value,

        vc.concept_name AS value_concept_name,

        LOWER(
            CONCAT_WS(
                ' ',
                COALESCE(vc.concept_name, ''),
                COALESCE(mr.value_source_value, '')
            )
        ) AS result_text

    FROM micro_rows mr

    LEFT JOIN {{schema}}.concept vc
      ON vc.concept_id = mr.value_as_concept_id

    WHERE mr.is_blood_culture
),


/* ---------------------------------------------------------------------------
   6. Detect explicitly positive blood-culture results.
   --------------------------------------------------------------------------- */
blood_stats AS (
    SELECT

        COUNT(*) FILTER (
            WHERE

                (
                    result_text ~*
                        'positive|detected|growth|isolat|present'
                )

                AND

                (
                    result_text !~*
                        'negative|'
                        'not[[:space:]-]*detected|'
                        'no[[:space:]-]*growth|'
                        'without[[:space:]-]*growth|'
                        'absent|'
                        'not[[:space:]-]*isolated'
                )

        ) AS positive_blood_culture_records_n,

        COUNT(*) AS blood_culture_records_n

    FROM blood_culture_rows
),


/* ---------------------------------------------------------------------------
   7. Dynamically obtain Measurement domain concept_id.
   --------------------------------------------------------------------------- */
measurement_domain AS (
    SELECT domain_concept_id
    FROM {{schema}}.domain
    WHERE domain_id = 'Measurement'
),


/* ---------------------------------------------------------------------------
   8. FACT_RELATIONSHIP statistics.

   The first EXISTS is trivial.

   For microbiology usage, test both directions separately.
   Avoid an OR condition in the JOIN because that often produces a poor plan.
   --------------------------------------------------------------------------- */
fact_stats AS (
    SELECT

        EXISTS (
            SELECT 1
            FROM {{schema}}.fact_relationship
            LIMIT 1
        ) AS fact_relationship_populated,


        (
            EXISTS (
                SELECT 1
                FROM {{schema}}.fact_relationship fr

                JOIN {{schema}}.measurement m
                  ON m.measurement_id = fr.fact_id_1

                JOIN candidate_concepts cc
                  ON cc.concept_id = m.measurement_concept_id

                WHERE fr.domain_concept_id_1 =
                      (
                          SELECT domain_concept_id
                          FROM measurement_domain
                      )

                LIMIT 1
            )

            OR

            EXISTS (
                SELECT 1
                FROM {{schema}}.fact_relationship fr

                JOIN {{schema}}.measurement m
                  ON m.measurement_id = fr.fact_id_2

                JOIN candidate_concepts cc
                  ON cc.concept_id = m.measurement_concept_id

                WHERE fr.domain_concept_id_2 =
                      (
                          SELECT domain_concept_id
                          FROM measurement_domain
                      )

                LIMIT 1
            )

        ) AS microbiology_fact_relationship_present
),


/* ===========================================================================
   9. Final result
   =========================================================================== */
statistics AS (

    SELECT
        1 AS metric_order,
        'Microbiology - culture-related MEASUREMENT concepts (n)'
            AS variable,
        ms.culture_concepts_n::text AS result
    FROM micro_stats ms


    UNION ALL


    SELECT
        2,
        'Microbiology - antimicrobial susceptibility MEASUREMENT concepts (n)',
        ms.ast_concepts_n::text
    FROM micro_stats ms


    UNION ALL


    SELECT
        3,
        'FACT_RELATIONSHIP is populated',
        CASE
            WHEN fs.fact_relationship_populated
            THEN 'YES'
            ELSE 'NO'
        END
    FROM fact_stats fs


    UNION ALL


    SELECT
        4,
        'Microbiology - FACT_RELATIONSHIP usage',
        CASE
            WHEN fs.microbiology_fact_relationship_present
            THEN 'YES'
            ELSE 'NO'
        END
    FROM fact_stats fs


    UNION ALL


    SELECT
        5,
        'Microbiology - patients with blood-culture records (n)',
        ms.blood_culture_patients_n::text
    FROM micro_stats ms


    UNION ALL


    SELECT
        6,
        'Microbiology - blood-culture records (n)',
        ms.blood_culture_records_n::text
    FROM micro_stats ms


    UNION ALL


    SELECT
        7,
        'Microbiology - positive blood-culture records (n)',
        bs.positive_blood_culture_records_n::text
    FROM blood_stats bs


    UNION ALL


    SELECT
        8,
        'Microbiology - positive blood cultures (%)',

        CASE
            WHEN bs.blood_culture_records_n = 0
                THEN 'N/A'

            ELSE
                ROUND(
                    100.0
                    * bs.positive_blood_culture_records_n
                    / bs.blood_culture_records_n,
                    2
                )::text || '%'
        END
    FROM blood_stats bs


    UNION ALL


    SELECT
        9,
        'Microbiology - organism identification represented (Yes/No)',
        CASE
            WHEN ms.organism_identification_present
            THEN 'YES'
            ELSE 'NO'
        END
    FROM micro_stats ms


    UNION ALL


    SELECT
        10,
        'Microbiology - AST represented (Yes/No)',
        CASE
            WHEN ms.ast_present
            THEN 'YES'
            ELSE 'NO'
        END
    FROM micro_stats ms
)

SELECT
    variable,
    result
FROM statistics
ORDER BY metric_order;
