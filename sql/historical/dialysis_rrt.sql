/* ============================================================================
   DIALYSIS / RRT DATA EXPECTATIONS - LIGHTWEIGHT SCREENING
   PostgreSQL / OMOP CDM

   PURPOSE
   -------
   Screening only. This is NOT an AKI or dialysis-indication phenotype.

   Main questions:
     1. Can RRT be identified?
     2. In which OMOP table is it represented?
     3. Can modality be distinguished?
     4. Is treatment timing available?
     5. Is actual fluid removal represented quantitatively?
     6. Can RRT and fluid removal be linked within a hospitalization?

   PERFORMANCE
   -----------
   - Regex only against CONCEPT.
   - Each clinical table scanned once.
   - Source-value discovery is intentionally excluded.
   ============================================================================ */

WITH

/* ---------------------------------------------------------------------------
   1. Known fluid-removal concepts
   --------------------------------------------------------------------------- */
removal_seed(concept_id, removal_kind) AS (
    VALUES

        /* Actual fluid removal */
        (1989402,    'ACTUAL'),
        (1988590,    'ACTUAL'),
        (1989626,    'ACTUAL'),
        (1988731,    'ACTUAL'),
        (2147483313, 'ACTUAL'),
        (2147483530, 'ACTUAL'),
        (4139443,    'ACTUAL'),

        /* Prescribed / desired removal */
        (2147483188, 'TARGET'),
        (2147483064, 'TARGET')
),

/* ---------------------------------------------------------------------------
   2. Candidate RRT and removal concepts
   --------------------------------------------------------------------------- */
candidate_concepts AS MATERIALIZED (

    SELECT
        c.concept_id,
        c.concept_name,
        c.domain_id,

        CASE
            WHEN c.concept_name ~*
                'continuous[[:space:]-]*(renal|kidney)[[:space:]-]*replacement|'
                '(^|[^a-z])(crrt|ckrt|cvvh|cvvhd|cvvhdf)([^a-z]|$)|'
                'continuous.{0,15}(hemofiltration|hemodiafiltration)'
                THEN 'CRRT_CKRT'

            WHEN c.concept_name ~*
                'peritoneal[[:space:]-]*dialysis'
                THEN 'PERITONEAL_DIALYSIS'

            WHEN c.concept_name ~*
                'hemodialysis|haemodialysis|'
                'intermittent.{0,20}(dialysis|renal[[:space:]-]*replacement)'
                THEN 'HEMODIALYSIS'

            WHEN c.concept_name ~*
                '(renal|kidney)[[:space:]-]*replacement[[:space:]-]*therapy|'
                'dialysis|'
                'hemofiltration|'
                'hemodiafiltration'
                THEN 'OTHER_RRT'

            ELSE NULL
        END AS modality,

        CASE
            WHEN rs.removal_kind IS NOT NULL
                THEN rs.removal_kind

            WHEN c.domain_id = 'Measurement'
             AND c.concept_name ~*
                'ultrafiltrat.{0,20}removed|'
                'hemodialysis.{0,25}fluid.{0,15}removed|'
                '(crrt|ckrt).{0,30}(ultrafiltrat[[:space:]-]*removed|total[[:space:]-]*output)|'
                'peritoneal[[:space:]-]*dialysis.{0,30}(fluid|output)'
                THEN 'ACTUAL'

            WHEN c.domain_id = 'Measurement'
             AND c.concept_name ~*
                '(volume|fluid).{0,20}to[[:space:]-]*be[[:space:]-]*removed|'
                'desired[[:space:]-]*fluid[[:space:]-]*loss|'
                'target.{0,20}(ultrafiltrat|fluid[[:space:]-]*removal)|'
                'prescribed.{0,20}(ultrafiltrat|fluid[[:space:]-]*removal)'
                THEN 'TARGET'

            ELSE NULL
        END AS removal_kind,

        (
            c.domain_id IN ('Procedure', 'Observation')
            AND c.concept_name ~*
                'continuous[[:space:]-]*(renal|kidney)[[:space:]-]*replacement|'
                '(^|[^a-z])(crrt|ckrt|cvvh|cvvhd|cvvhdf)([^a-z]|$)|'
                'renal[[:space:]-]*replacement[[:space:]-]*therapy|'
                'kidney[[:space:]-]*replacement[[:space:]-]*therapy|'
                'hemodialysis|haemodialysis|'
                'peritoneal[[:space:]-]*dialysis|'
                'hemofiltration|hemodiafiltration'
        )
        OR
        (
            c.domain_id = 'Device'
            AND c.concept_name ~*
                'dialysis[[:space:]-]*(machine|device|system)|'
                'hemodialysis[[:space:]-]*(machine|device|system)|'
                'dialy[sz]er|hemofilter|'
                'continuous.{0,20}(renal|kidney).{0,20}(device|system)'
            AND c.concept_name !~*
                'catheter|vascular[[:space:]-]*access'
        ) AS is_rrt_event

    FROM {{schema}}.concept c

    LEFT JOIN removal_seed rs
      ON rs.concept_id = c.concept_id

    WHERE
           rs.concept_id IS NOT NULL

        OR (
            c.domain_id IN (
                'Procedure',
                'Observation',
                'Device',
                'Measurement'
            )
            AND c.concept_name ~*
                'continuous[[:space:]-]*(renal|kidney)[[:space:]-]*replacement|'
                '(^|[^a-z])(crrt|ckrt|cvvh|cvvhd|cvvhdf)([^a-z]|$)|'
                'renal[[:space:]-]*replacement[[:space:]-]*therapy|'
                'kidney[[:space:]-]*replacement[[:space:]-]*therapy|'
                'hemodialysis|haemodialysis|'
                'peritoneal[[:space:]-]*dialysis|'
                'hemofiltration|'
                'hemodiafiltration|'
                'ultrafiltrat.{0,20}removed|'
                'fluid.{0,20}removed|'
                'desired[[:space:]-]*fluid[[:space:]-]*loss'
        )
),

/* ===========================================================================
   3. RRT event tables
   =========================================================================== */
procedure_hits AS MATERIALIZED (

    SELECT
        p.person_id,
        'PROCEDURE_OCCURRENCE' AS source_table,
        c.concept_name,
        c.modality,
        p.procedure_datetime AS event_datetime,
        p.visit_occurrence_id,
        p.visit_detail_id

    FROM {{schema}}.procedure_occurrence p

    JOIN candidate_concepts c
      ON c.concept_id = p.procedure_concept_id

    WHERE c.domain_id = 'Procedure'
      AND c.is_rrt_event
),

observation_hits AS MATERIALIZED (

    SELECT
        o.person_id,
        'OBSERVATION' AS source_table,
        c.concept_name,
        c.modality,
        o.observation_datetime AS event_datetime,
        o.visit_occurrence_id,
        o.visit_detail_id

    FROM {{schema}}.observation o

    JOIN candidate_concepts c
      ON c.concept_id = o.observation_concept_id

    WHERE c.domain_id = 'Observation'
      AND c.is_rrt_event
),

device_hits AS MATERIALIZED (

    SELECT
        d.person_id,
        'DEVICE_EXPOSURE' AS source_table,
        c.concept_name,
        c.modality,
        d.device_exposure_start_datetime AS event_datetime,
        d.visit_occurrence_id,
        d.visit_detail_id

    FROM {{schema}}.device_exposure d

    JOIN candidate_concepts c
      ON c.concept_id = d.device_concept_id

    WHERE c.domain_id = 'Device'
      AND c.is_rrt_event
),

rrt_events AS MATERIALIZED (

    SELECT * FROM procedure_hits
    UNION ALL
    SELECT * FROM observation_hits
    UNION ALL
    SELECT * FROM device_hits
),

rrt_stats AS (

    SELECT
        COUNT(*) AS records_n,

        COUNT(DISTINCT person_id)
            AS patients_n,

        COUNT(*) FILTER (
            WHERE event_datetime IS NOT NULL
        ) AS datetime_n,

        COUNT(*) FILTER (
            WHERE visit_occurrence_id IS NOT NULL
        ) AS visit_n,

        COUNT(*) FILTER (
            WHERE visit_detail_id IS NOT NULL
        ) AS visit_detail_n,

        COUNT(*) FILTER (
            WHERE modality = 'CRRT_CKRT'
        ) AS crrt_n,

        COUNT(*) FILTER (
            WHERE modality = 'HEMODIALYSIS'
        ) AS hd_n,

        COUNT(*) FILTER (
            WHERE modality = 'PERITONEAL_DIALYSIS'
        ) AS pd_n,

        COUNT(*) FILTER (
            WHERE modality = 'OTHER_RRT'
        ) AS other_n

    FROM rrt_events
),

/* ===========================================================================
   4. Fluid-removal MEASUREMENT
   =========================================================================== */
removal_hits AS MATERIALIZED (

    SELECT
        m.person_id,
        c.concept_name,
        c.removal_kind,

        m.measurement_datetime,
        m.value_as_number,
        m.unit_concept_id,
        m.unit_source_value,

        m.visit_occurrence_id,
        m.visit_detail_id

    FROM {{schema}}.measurement m

    JOIN candidate_concepts c
      ON c.concept_id = m.measurement_concept_id

    WHERE c.domain_id = 'Measurement'
      AND c.removal_kind IS NOT NULL
),

removal_stats AS (

    SELECT
        COUNT(*) FILTER (
            WHERE removal_kind = 'ACTUAL'
        ) AS actual_records_n,

        COUNT(DISTINCT person_id) FILTER (
            WHERE removal_kind = 'ACTUAL'
        ) AS actual_patients_n,

        COUNT(*) FILTER (
            WHERE removal_kind = 'TARGET'
        ) AS target_records_n,

        COUNT(*) FILTER (
            WHERE removal_kind = 'ACTUAL'
              AND value_as_number IS NOT NULL
        ) AS numeric_n,

        COUNT(*) FILTER (
            WHERE removal_kind = 'ACTUAL'
              AND value_as_number IS NOT NULL
              AND (
                     COALESCE(unit_concept_id, 0) <> 0
                  OR NULLIF(TRIM(unit_source_value), '') IS NOT NULL
              )
        ) AS unit_n,

        COUNT(*) FILTER (
            WHERE removal_kind = 'ACTUAL'
              AND measurement_datetime IS NOT NULL
        ) AS datetime_n,

        COUNT(*) FILTER (
            WHERE removal_kind = 'ACTUAL'
              AND visit_occurrence_id IS NOT NULL
        ) AS visit_n

    FROM removal_hits
),

/* ---------------------------------------------------------------------------
   5. Linkage between RRT and actual fluid removal
   --------------------------------------------------------------------------- */
rrt_visits AS (
    SELECT DISTINCT
        person_id,
        visit_occurrence_id
    FROM rrt_events
    WHERE visit_occurrence_id IS NOT NULL
),

removal_visits AS (
    SELECT DISTINCT
        person_id,
        visit_occurrence_id
    FROM removal_hits
    WHERE removal_kind = 'ACTUAL'
      AND visit_occurrence_id IS NOT NULL
),

link_stats AS (
    SELECT
        COUNT(*) AS rrt_visits_n,

        COUNT(*) FILTER (
            WHERE rv2.visit_occurrence_id IS NOT NULL
        ) AS linked_n

    FROM rrt_visits rv

    LEFT JOIN removal_visits rv2
      ON rv2.person_id = rv.person_id
     AND rv2.visit_occurrence_id = rv.visit_occurrence_id
),

/* ---------------------------------------------------------------------------
   6. Semantic inspection
   --------------------------------------------------------------------------- */
top_rrt AS (
    SELECT STRING_AGG(
        source_table || ': ' ||
        concept_name || ' (' || n || ')',
        '; ' ORDER BY n DESC, concept_name
    ) AS result
    FROM (
        SELECT
            source_table,
            concept_name,
            COUNT(*) AS n
        FROM rrt_events
        GROUP BY source_table, concept_name
        ORDER BY n DESC
        LIMIT 15
    ) s
),

top_removal AS (
    SELECT STRING_AGG(
        removal_kind || ': ' ||
        concept_name || ' (' || n || ')',
        '; ' ORDER BY n DESC, concept_name
    ) AS result
    FROM (
        SELECT
            removal_kind,
            concept_name,
            COUNT(*) AS n
        FROM removal_hits
        GROUP BY removal_kind, concept_name
        ORDER BY n DESC
        LIMIT 15
    ) s
),

/* ===========================================================================
   7. Final output
   =========================================================================== */
statistics AS (

    SELECT 1 AS metric_order,
           'RRT representation' AS section,
           'RRT records by table' AS variable,
           'PROCEDURE_OCCURRENCE=' ||
               (SELECT COUNT(*) FROM procedure_hits)::text ||
           '; OBSERVATION=' ||
               (SELECT COUNT(*) FROM observation_hits)::text ||
           '; DEVICE_EXPOSURE=' ||
               (SELECT COUNT(*) FROM device_hits)::text
           AS result

    UNION ALL

    SELECT 2, 'RRT representation',
           'Patients with RRT evidence (n)',
           patients_n::text
    FROM rrt_stats

    UNION ALL

    SELECT 3, 'RRT representation',
           'RRT modality records',
           'CRRT/CKRT=' || crrt_n::text ||
           '; Hemodialysis=' || hd_n::text ||
           '; Peritoneal dialysis=' || pd_n::text ||
           '; Other/unspecified RRT=' || other_n::text
    FROM rrt_stats

    UNION ALL

    SELECT 4, 'Temporal',
           'RRT event datetime populated (%)',
           COALESCE(
               ROUND(
                   100.0 * datetime_n /
                   NULLIF(records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM rrt_stats

    UNION ALL

    SELECT 5, 'Linkage',
           'RRT visit_occurrence_id populated (%)',
           COALESCE(
               ROUND(
                   100.0 * visit_n /
                   NULLIF(records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM rrt_stats

    UNION ALL

    SELECT 6, 'Linkage',
           'RRT visit_detail_id populated (%)',
           COALESCE(
               ROUND(
                   100.0 * visit_detail_n /
                   NULLIF(records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM rrt_stats

    UNION ALL

    SELECT 7, 'Fluid removal',
           'Actual fluid-removal records (n)',
           actual_records_n::text
    FROM removal_stats

    UNION ALL

    SELECT 8, 'Fluid removal',
           'Patients with actual fluid-removal records (n)',
           actual_patients_n::text
    FROM removal_stats

    UNION ALL

    SELECT 9, 'Fluid removal',
           'Numeric value populated in actual removal records (%)',
           COALESCE(
               ROUND(
                   100.0 * numeric_n /
                   NULLIF(actual_records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM removal_stats

    UNION ALL

    SELECT 10, 'Fluid removal',
           'Unit populated among numeric actual-removal records (%)',
           COALESCE(
               ROUND(
                   100.0 * unit_n /
                   NULLIF(numeric_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM removal_stats

    UNION ALL

    SELECT 11, 'Fluid removal',
           'Actual-removal measurement_datetime populated (%)',
           COALESCE(
               ROUND(
                   100.0 * datetime_n /
                   NULLIF(actual_records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM removal_stats

    UNION ALL

    SELECT 12, 'Fluid removal',
           'Actual-removal visit_occurrence_id populated (%)',
           COALESCE(
               ROUND(
                   100.0 * visit_n /
                   NULLIF(actual_records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM removal_stats

    UNION ALL

    SELECT 13, 'Fluid removal',
           'Prescribed/target fluid-removal records (n)',
           target_records_n::text
    FROM removal_stats

    UNION ALL

    SELECT 14, 'Reconstructability',
           'RRT visits with actual fluid-removal measurements (%)',
           COALESCE(
               ROUND(
                   100.0 * linked_n /
                   NULLIF(rrt_visits_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM link_stats

    UNION ALL

    SELECT 15, 'Observed representation',
           'Top RRT concepts',
           COALESCE(result, 'NONE')
    FROM top_rrt

    UNION ALL

    SELECT 16, 'Observed representation',
           'Top fluid-removal concepts',
           COALESCE(result, 'NONE')
    FROM top_removal
)

SELECT
    section,
    variable,
    result
FROM statistics
ORDER BY metric_order;
