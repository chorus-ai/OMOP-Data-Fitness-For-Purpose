/* ============================================================================
   CODE STATUS DATA EXPECTATIONS - OPTIMIZED LIGHTWEIGHT SCREENING
   PostgreSQL / OMOP CDM

   SAME PURPOSE AND SAME 20 OUTPUT METRICS AS THE ORIGINAL QUERY.

   OPTIMIZATIONS
   -------------
   1. Candidate concept discovery calculates only fields actually used.
   2. OBSERVATION is filtered once.
   3. CONDITION_OCCURRENCE is filtered once.
   4. All basic OBSERVATION metrics are calculated in one aggregation.
   5. All basic CONDITION_OCCURRENCE metrics are calculated in one aggregation.
   6. Longitudinal metrics are calculated together.
   7. Only reusable result sets are materialized.
   8. No regex is applied to the complete clinical tables.
   ============================================================================ */

WITH

/* ---------------------------------------------------------------------------
   1. Known concepts
   --------------------------------------------------------------------------- */
seed_concepts(concept_id, seed_category) AS (
    VALUES
        (3175080, 'DNI'),
        (4119499, 'DNR'),
        (3172086, 'DNR_DNI_LIMITED'),
        (3172879, 'FULL_CODE')
),

/* ---------------------------------------------------------------------------
   2. Candidate concepts

   Only concept_id and domain_id are needed downstream.
   The previous concept_category CASE was not used in the final output.
   --------------------------------------------------------------------------- */
candidate_concepts AS MATERIALIZED (

    SELECT
        c.concept_id,
        c.domain_id

    FROM {{schema}}.concept c

    WHERE c.domain_id IN ('Observation', 'Condition')

      AND (
             c.concept_id IN (
                 SELECT concept_id
                 FROM seed_concepts
             )

          OR c.concept_name ~*
                'code[[:space:]-]*status|'
                'full[[:space:]-]*code|'
                'resuscitation[[:space:]-]*(status|preference|order)|'
                'resuscitative[[:space:]-]*(status|preference)|'
                'do[[:space:]-]*not[[:space:]-]*resuscitat|'
                'not[[:space:]-]*for[[:space:]-]*resuscitat|'
                'do[[:space:]-]*not[[:space:]-]*intubat|'
                'not[[:space:]-]*for[[:space:]-]*intubat|'
                '(^|[^a-z])dnr([^a-z]|$)|'
                '(^|[^a-z])dni([^a-z]|$)|'
                'limited[[:space:]-]*(code|resuscitat)|'
                'partial[[:space:]-]*code|'
                'allow[[:space:]-]*natural[[:space:]-]*death|'
                'advance[[:space:]-]*directive'
      )
),

/* ===========================================================================
   3. OBSERVATION

   Same inclusion logic as the original query.
   =========================================================================== */
obs_raw AS (

    SELECT
        o.person_id,
        o.observation_concept_id,
        o.observation_datetime,
        o.value_as_concept_id,
        o.value_as_string,
        o.observation_source_value,
        o.value_source_value,
        o.visit_occurrence_id,
        o.visit_detail_id

    FROM {{schema}}.observation o

    WHERE
           o.observation_concept_id IN (
               SELECT concept_id
               FROM candidate_concepts
           )

        OR o.observation_source_concept_id IN (
               SELECT concept_id
               FROM candidate_concepts
           )

        OR o.value_as_concept_id IN (
               SELECT concept_id
               FROM candidate_concepts
           )
),

/* ---------------------------------------------------------------------------
   Enrich and classify once.

   LOWER() is unnecessary because ~* is already case-insensitive.
   --------------------------------------------------------------------------- */
obs_status AS MATERIALIZED (

    SELECT
        x.*,

        CASE

            WHEN x.status_text ~*
                'full[[:space:]-]*code|'
                'full[[:space:]-]*resuscitat|'
                'use[[:space:]-]*all.{0,30}resuscitation[[:space:]-]*measures|'
                'all[[:space:]-]*resuscitative[[:space:]-]*measures'
                THEN 'FULL_CODE'

            WHEN x.status_text ~*
                'dnr.{0,20}dni|'
                'dni.{0,20}dnr|'
                'limited[[:space:]-]*(code|resuscitat)|'
                'partial[[:space:]-]*code|'
                'limited[[:space:]-]*life[[:space:]-]*sustain|'
                'no[[:space:]-]*cpr.{0,40}no[[:space:]-]*intubat'
                THEN 'DNR_DNI_LIMITED'

            WHEN x.status_text ~*
                'do[[:space:]-]*not[[:space:]-]*intubat|'
                'not[[:space:]-]*for[[:space:]-]*intubat|'
                '(^|[^a-z])dni([^a-z]|$)|'
                'no[[:space:]-]*intubat'
                THEN 'DNI'

            WHEN x.status_text ~*
                'do[[:space:]-]*not[[:space:]-]*resuscitat|'
                'not[[:space:]-]*for[[:space:]-]*resuscitat|'
                '(^|[^a-z])dnr([^a-z]|$)|'
                'no[[:space:]-]*cpr|'
                'allow[[:space:]-]*natural[[:space:]-]*death'
                THEN 'DNR'

            ELSE 'OTHER_OR_UNRESOLVED'

        END AS status_category

    FROM (

        SELECT
            o.*,

            oc.concept_name
                AS observation_concept_name,

            vc.concept_name
                AS value_concept_name,

            CONCAT_WS(
                ' ',
                oc.concept_name,
                vc.concept_name,
                o.observation_source_value,
                o.value_source_value,
                o.value_as_string
            ) AS status_text

        FROM obs_raw o

        LEFT JOIN {{schema}}.concept oc
          ON oc.concept_id =
             o.observation_concept_id

        LEFT JOIN {{schema}}.concept vc
          ON vc.concept_id =
             o.value_as_concept_id

    ) x
),

/* ---------------------------------------------------------------------------
   All basic OBSERVATION metrics in ONE pass.
   --------------------------------------------------------------------------- */
obs_stats AS (

    SELECT

        COUNT(*)
            AS records_n,

        COUNT(DISTINCT person_id)
            AS patients_n,

        COUNT(
            DISTINCT (person_id, visit_occurrence_id)
        ) FILTER (
            WHERE visit_occurrence_id IS NOT NULL
        ) AS visits_n,

        COUNT(*) FILTER (
            WHERE observation_datetime IS NOT NULL
        ) AS datetime_n,

        COUNT(*) FILTER (
            WHERE visit_occurrence_id IS NOT NULL
        ) AS visit_n,

        COUNT(*) FILTER (
            WHERE visit_detail_id IS NOT NULL
        ) AS visit_detail_n,

        COUNT(*) FILTER (
            WHERE COALESCE(value_as_concept_id, 0) <> 0
        ) AS value_concept_n,

        COUNT(*) FILTER (
            WHERE NULLIF(
                TRIM(value_source_value),
                ''
            ) IS NOT NULL
        ) AS value_source_n,

        COUNT(*) FILTER (
            WHERE status_category = 'FULL_CODE'
        ) AS full_code_n,

        COUNT(*) FILTER (
            WHERE status_category = 'DNR'
        ) AS dnr_n,

        COUNT(*) FILTER (
            WHERE status_category = 'DNI'
        ) AS dni_n,

        COUNT(*) FILTER (
            WHERE status_category = 'DNR_DNI_LIMITED'
        ) AS dnr_dni_limited_n,

        COUNT(*) FILTER (
            WHERE status_category = 'OTHER_OR_UNRESOLVED'
        ) AS unresolved_n

    FROM obs_status
),

/* ===========================================================================
   4. CONDITION_OCCURRENCE
   =========================================================================== */
cond_raw AS (

    SELECT
        co.person_id,
        co.condition_concept_id,
        co.condition_start_datetime,
        co.condition_source_value,
        co.visit_occurrence_id

    FROM {{schema}}.condition_occurrence co

    WHERE
           co.condition_concept_id IN (
               SELECT concept_id
               FROM candidate_concepts
           )

        OR co.condition_source_concept_id IN (
               SELECT concept_id
               FROM candidate_concepts
           )
),

cond_status AS MATERIALIZED (

    SELECT
        x.*,

        CASE

            WHEN x.status_text ~*
                'full[[:space:]-]*code|'
                'full[[:space:]-]*resuscitat|'
                'use[[:space:]-]*all.{0,30}resuscitation[[:space:]-]*measures'
                THEN 'FULL_CODE'

            WHEN x.status_text ~*
                'dnr.{0,20}dni|'
                'dni.{0,20}dnr|'
                'limited[[:space:]-]*(code|resuscitat)|'
                'partial[[:space:]-]*code|'
                'limited[[:space:]-]*life[[:space:]-]*sustain'
                THEN 'DNR_DNI_LIMITED'

            WHEN x.status_text ~*
                'do[[:space:]-]*not[[:space:]-]*intubat|'
                'not[[:space:]-]*for[[:space:]-]*intubat|'
                '(^|[^a-z])dni([^a-z]|$)|'
                'no[[:space:]-]*intubat'
                THEN 'DNI'

            WHEN x.status_text ~*
                'do[[:space:]-]*not[[:space:]-]*resuscitat|'
                'not[[:space:]-]*for[[:space:]-]*resuscitat|'
                '(^|[^a-z])dnr([^a-z]|$)|'
                'no[[:space:]-]*cpr|'
                'allow[[:space:]-]*natural[[:space:]-]*death'
                THEN 'DNR'

            ELSE 'OTHER_OR_UNRESOLVED'

        END AS status_category

    FROM (

        SELECT
            co.*,

            c.concept_name
                AS condition_concept_name,

            CONCAT_WS(
                ' ',
                c.concept_name,
                co.condition_source_value
            ) AS status_text

        FROM cond_raw co

        LEFT JOIN {{schema}}.concept c
          ON c.concept_id =
             co.condition_concept_id

    ) x
),

/* ---------------------------------------------------------------------------
   All CONDITION_OCCURRENCE statistics in ONE pass.
   --------------------------------------------------------------------------- */
cond_stats AS (

    SELECT

        COUNT(*)
            AS records_n,

        COUNT(DISTINCT person_id)
            AS patients_n,

        COUNT(*) FILTER (
            WHERE condition_start_datetime IS NOT NULL
        ) AS datetime_n,

        COUNT(*) FILTER (
            WHERE visit_occurrence_id IS NOT NULL
        ) AS visit_n

    FROM cond_status
),

/* ===========================================================================
   5. Longitudinal representation

   event_datetime was removed because it was never used by the original
   visit-level calculations.
   =========================================================================== */
all_status_events AS (

    SELECT
        person_id,
        visit_occurrence_id,
        status_category
    FROM obs_status

    UNION ALL

    SELECT
        person_id,
        visit_occurrence_id,
        status_category
    FROM cond_status
),

visit_status_summary AS (

    SELECT
        person_id,
        visit_occurrence_id,

        COUNT(*)
            AS records_n,

        COUNT(
            DISTINCT status_category
        ) FILTER (
            WHERE status_category <>
                  'OTHER_OR_UNRESOLVED'
        ) AS distinct_status_categories_n

    FROM all_status_events

    WHERE visit_occurrence_id IS NOT NULL

    GROUP BY
        person_id,
        visit_occurrence_id
),

long_stats AS (

    SELECT

        COUNT(*)
            AS visits_n,

        COUNT(*) FILTER (
            WHERE records_n > 1
        ) AS repeated_n,

        COUNT(*) FILTER (
            WHERE distinct_status_categories_n > 1
        ) AS changed_n

    FROM visit_status_summary
),

/* ===========================================================================
   6. Semantic inspection
   =========================================================================== */

obs_patterns_top AS (

    SELECT
        STRING_AGG(
            pattern || ' (' || n || ')',
            '; ' ORDER BY n DESC, pattern
        ) AS result

    FROM (

        SELECT
            COALESCE(
                observation_concept_name,
                'NULL'
            )
            || ' -> '
            ||
            COALESCE(
                value_concept_name,
                'NULL'
            ) AS pattern,

            COUNT(*) AS n

        FROM obs_status

        GROUP BY
            observation_concept_name,
            value_concept_name

        ORDER BY n DESC

        LIMIT 15

    ) s
),

obs_source_values_top AS (

    SELECT
        STRING_AGG(
            source_pattern || ' (' || n || ')',
            '; ' ORDER BY n DESC, source_pattern
        ) AS result

    FROM (

        SELECT
            COALESCE(
                observation_source_value,
                'NULL'
            )
            || ' -> '
            ||
            COALESCE(
                value_source_value,
                'NULL'
            ) AS source_pattern,

            COUNT(*) AS n

        FROM obs_status

        GROUP BY
            observation_source_value,
            value_source_value

        ORDER BY n DESC

        LIMIT 15

    ) s
),

cond_concepts_top AS (

    SELECT
        STRING_AGG(
            concept_name || ' (' || n || ')',
            '; ' ORDER BY n DESC, concept_name
        ) AS result

    FROM (

        SELECT
            COALESCE(
                condition_concept_name,
                'NULL'
            ) AS concept_name,

            COUNT(*) AS n

        FROM cond_status

        GROUP BY
            condition_concept_name

        ORDER BY n DESC

        LIMIT 15

    ) s
),

/* ===========================================================================
   7. SAME FINAL OUTPUT
   =========================================================================== */

statistics AS (

    /* ---------------- Vocabulary ---------------- */

    SELECT
        1 AS metric_order,
        'Vocabulary' AS section,
        'Known mapping concepts present in local vocabulary'
            AS variable,
        COUNT(c.concept_id)::text || ' / 4'
            AS result

    FROM seed_concepts s

    LEFT JOIN {{schema}}.concept c
      ON c.concept_id = s.concept_id


    UNION ALL

    SELECT
        2,
        'Vocabulary',
        'Candidate code-status concepts found by domain',

        'Observation=' ||
        COUNT(*) FILTER (
            WHERE domain_id = 'Observation'
        )::text

        ||

        '; Condition=' ||
        COUNT(*) FILTER (
            WHERE domain_id = 'Condition'
        )::text

    FROM candidate_concepts


    /* ---------------- OBSERVATION ---------------- */

    UNION ALL

    SELECT
        3,
        'OBSERVATION',
        'Code-status records (n)',
        records_n::text
    FROM obs_stats


    UNION ALL

    SELECT
        4,
        'OBSERVATION',
        'Patients with code-status records (n)',
        patients_n::text
    FROM obs_stats


    UNION ALL

    SELECT
        5,
        'OBSERVATION',
        'Visits with code-status records (n)',
        visits_n::text
    FROM obs_stats


    UNION ALL

    SELECT
        6,
        'OBSERVATION',
        'observation_datetime populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                datetime_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM obs_stats


    UNION ALL

    SELECT
        7,
        'OBSERVATION',
        'visit_occurrence_id populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                visit_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM obs_stats


    UNION ALL

    SELECT
        8,
        'OBSERVATION',
        'visit_detail_id populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                visit_detail_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM obs_stats


    UNION ALL

    SELECT
        9,
        'OBSERVATION',
        'value_as_concept_id populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                value_concept_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM obs_stats


    UNION ALL

    SELECT
        10,
        'OBSERVATION',
        'value_source_value populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                value_source_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM obs_stats


    UNION ALL

    SELECT
        11,
        'OBSERVATION',
        'Code-status categories observed',

        'FULL_CODE=' ||
        full_code_n::text

        ||

        '; DNR=' ||
        dnr_n::text

        ||

        '; DNI=' ||
        dni_n::text

        ||

        '; DNR_DNI_LIMITED=' ||
        dnr_dni_limited_n::text

        ||

        '; OTHER/UNRESOLVED=' ||
        unresolved_n::text

    FROM obs_stats


    /* ---------------- CONDITION_OCCURRENCE ---------------- */

    UNION ALL

    SELECT
        12,
        'CONDITION_OCCURRENCE',
        'Code-status-related records (n)',
        records_n::text
    FROM cond_stats


    UNION ALL

    SELECT
        13,
        'CONDITION_OCCURRENCE',
        'Patients with code-status-related records (n)',
        patients_n::text
    FROM cond_stats


    UNION ALL

    SELECT
        14,
        'CONDITION_OCCURRENCE',
        'condition_start_datetime populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                datetime_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM cond_stats


    UNION ALL

    SELECT
        15,
        'CONDITION_OCCURRENCE',
        'visit_occurrence_id populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                visit_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM cond_stats


    /* ---------------- Longitudinal ---------------- */

    UNION ALL

    SELECT
        16,
        'Longitudinal',
        'Visits with >1 code-status record (%)',

        COALESCE(
            ROUND(
                100.0 *
                repeated_n /
                NULLIF(visits_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM long_stats


    UNION ALL

    SELECT
        17,
        'Longitudinal',
        'Visits with >1 distinct code-status category (%)',

        COALESCE(
            ROUND(
                100.0 *
                changed_n /
                NULLIF(visits_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM long_stats


    /* ---------------- Semantic inspection ---------------- */

    UNION ALL

    SELECT
        18,
        'Observed representation',
        'Top OBSERVATION concept -> value patterns',
        COALESCE(result, 'NONE')
    FROM obs_patterns_top


    UNION ALL

    SELECT
        19,
        'Observed representation',
        'Top OBSERVATION source -> value patterns',
        COALESCE(result, 'NONE')
    FROM obs_source_values_top


    UNION ALL

    SELECT
        20,
        'Observed representation',
        'Top CONDITION_OCCURRENCE concepts',
        COALESCE(result, 'NONE')
    FROM cond_concepts_top
)

SELECT
    section,
    variable,
    result

FROM statistics

ORDER BY metric_order;
