/* ============================================================================
   MECHANICAL VENTILATION DATA EXPECTATIONS
   OPTIMIZED LIGHTWEIGHT SCREENING
   PostgreSQL / OMOP CDM

   PURPOSE AND OUTPUT ARE IDENTICAL TO THE PREVIOUS LIGHTWEIGHT VERSION.

   PERFORMANCE CHANGES
   -------------------
   - PROCEDURE_OCCURRENCE scanned once instead of three times
   - OBSERVATION scanned once
   - DEVICE_EXPOSURE scanned once
   - Metrics aggregated once per clinical table
   - Concept names carried forward, avoiding repeated joins to CONCEPT
   ============================================================================ */

WITH

/* ---------------------------------------------------------------------------
   1. Mechanical ventilation concept set
   --------------------------------------------------------------------------- */
mv_seed(concept_id) AS (
    VALUES
        (1243692),
        (2008006),
        (2008007),
        (2008008),
        (2008009),
        (2108681),
        (3655902),
        (4039922),
        (4055375),
        (4055376),
        (4074666),
        (4177224),
        (37152408),
        (37152409),
        (37152410),
        (37152411),
        (37152412),
        (37157165),
        (37157166),
        (37158404),
        (37158487),
        (40486624)
),

/* ---------------------------------------------------------------------------
   2. Tracheal intubation concept set
   --------------------------------------------------------------------------- */
intub_seed(concept_id) AS (
    VALUES
        (765576),
        (3657544),
        (4013354),
        (4058031),
        (4119642),
        (4179373),
        (4228313),
        (4303945),
        (4335481),
        (4335583),
        (4335584),
        (4337045),
        (4337615),
        (4337616),
        (4337617),
        (4339623),
        (37206251),
        (44515633)
),

/* ---------------------------------------------------------------------------
   3. Candidate concept discovery

   Same concept logic as before.
   Regex is applied only to CONCEPT, not to clinical tables.
   --------------------------------------------------------------------------- */
candidate_concepts AS MATERIALIZED (
    SELECT
        c.concept_id,
        c.concept_name,
        c.domain_id,

        (
            c.concept_id IN (
                SELECT concept_id FROM mv_seed
            )
            OR
            c.concept_name ~*
                'mechanical.{0,15}ventilat|'
                'invasive.{0,15}ventilat|'
                'artificial.{0,15}ventilat'
        ) AS is_mv,

        (
            c.concept_id IN (
                SELECT concept_id FROM intub_seed
            )
            OR
            c.concept_name ~*
                '(endotracheal|tracheal|orotracheal|nasotracheal)'
                '.{0,25}intubat|'
                'intubat.{0,25}(trachea|endotrache)'
        ) AS is_intub,

        (
            c.concept_name ~* 'extubat'
        ) AS is_extub,

        (
            c.domain_id = 'Device'
            AND c.concept_name ~*
                'ventilator|mechanical.{0,15}ventilat'
        ) AS is_vent_device

    FROM {{schema}}.concept c

    WHERE
           c.concept_id IN (
               SELECT concept_id FROM mv_seed
           )

        OR c.concept_id IN (
               SELECT concept_id FROM intub_seed
           )

        OR c.concept_name ~*
            'mechanical.{0,15}ventilat|'
            'invasive.{0,15}ventilat|'
            'artificial.{0,15}ventilat|'
            'intubat|'
            'extubat|'
            'ventilator'
),

/* ===========================================================================
   4. PROCEDURE_OCCURRENCE

   ONE scan captures MV, intubation and extubation.
   =========================================================================== */
proc_hits AS MATERIALIZED (
    SELECT
        po.procedure_occurrence_id,
        po.person_id,
        po.procedure_concept_id,
        po.procedure_datetime,
        po.visit_occurrence_id,
        po.visit_detail_id,

        cc.concept_name,
        cc.is_mv,
        cc.is_intub,
        cc.is_extub

    FROM {{schema}}.procedure_occurrence po

    JOIN candidate_concepts cc
      ON cc.concept_id = po.procedure_concept_id

    WHERE
           cc.is_mv
        OR cc.is_intub
        OR cc.is_extub
),

/* ---------------------------------------------------------------------------
   Aggregate all procedure metrics in one pass over matched records.
   --------------------------------------------------------------------------- */
proc_stats AS (
    SELECT

        COUNT(*) FILTER (
            WHERE is_mv
        ) AS mv_records_n,

        COUNT(DISTINCT person_id) FILTER (
            WHERE is_mv
        ) AS mv_patients_n,

        COUNT(*) FILTER (
            WHERE is_mv
              AND procedure_datetime IS NOT NULL
        ) AS mv_datetime_n,

        COUNT(*) FILTER (
            WHERE is_mv
              AND visit_occurrence_id IS NOT NULL
        ) AS mv_visit_n,

        COUNT(*) FILTER (
            WHERE is_mv
              AND visit_detail_id IS NOT NULL
        ) AS mv_visit_detail_n,


        COUNT(*) FILTER (
            WHERE is_intub
        ) AS intub_records_n,

        COUNT(DISTINCT person_id) FILTER (
            WHERE is_intub
        ) AS intub_patients_n,

        COUNT(*) FILTER (
            WHERE is_intub
              AND procedure_datetime IS NOT NULL
        ) AS intub_datetime_n,


        COUNT(*) FILTER (
            WHERE is_extub
        ) AS extub_records_n

    FROM proc_hits
),

/* ===========================================================================
   5. OBSERVATION

   ONE scan for mechanical-ventilation observations.
   =========================================================================== */
obs_hits AS MATERIALIZED (
    SELECT
        o.observation_id,
        o.person_id,
        o.observation_concept_id,
        o.observation_datetime,
        o.visit_occurrence_id,
        o.visit_detail_id,

        cc.concept_name

    FROM {{schema}}.observation o

    JOIN candidate_concepts cc
      ON cc.concept_id = o.observation_concept_id
     AND cc.is_mv
),

obs_stats AS (
    SELECT
        COUNT(*) AS records_n,

        COUNT(DISTINCT person_id)
            AS patients_n,

        COUNT(*) FILTER (
            WHERE observation_datetime IS NOT NULL
        ) AS datetime_n,

        COUNT(*) FILTER (
            WHERE visit_occurrence_id IS NOT NULL
        ) AS visit_n,

        COUNT(*) FILTER (
            WHERE visit_detail_id IS NOT NULL
        ) AS visit_detail_n

    FROM obs_hits
),

/* ===========================================================================
   6. DEVICE_EXPOSURE

   ONE scan for ventilator-device exposure.
   =========================================================================== */
device_hits AS MATERIALIZED (
    SELECT
        de.device_exposure_id,
        de.person_id,
        de.device_concept_id,
        de.device_exposure_start_datetime,
        de.device_exposure_end_datetime,
        de.visit_occurrence_id,
        de.visit_detail_id,

        cc.concept_name

    FROM {{schema}}.device_exposure de

    JOIN candidate_concepts cc
      ON cc.concept_id = de.device_concept_id
     AND cc.is_vent_device
),

device_stats AS (
    SELECT
        COUNT(*) AS records_n,

        COUNT(DISTINCT person_id)
            AS patients_n,

        COUNT(*) FILTER (
            WHERE device_exposure_start_datetime IS NOT NULL
              AND device_exposure_end_datetime IS NOT NULL
        ) AS complete_datetime_n,

        COUNT(*) FILTER (
            WHERE device_exposure_start_datetime IS NOT NULL
              AND device_exposure_end_datetime IS NOT NULL
              AND device_exposure_end_datetime >=
                  device_exposure_start_datetime
        ) AS valid_interval_n,

        COUNT(*) FILTER (
            WHERE visit_occurrence_id IS NOT NULL
        ) AS visit_n,

        COUNT(*) FILTER (
            WHERE visit_detail_id IS NOT NULL
        ) AS visit_detail_n

    FROM device_hits
),

/* ===========================================================================
   7. Top concepts

   No additional joins to CONCEPT are required.
   =========================================================================== */

proc_mv_top AS (
    SELECT
        STRING_AGG(
            concept_name || ' (' || n || ')',
            '; ' ORDER BY n DESC, concept_name
        ) AS result

    FROM (
        SELECT
            concept_name,
            COUNT(*) AS n

        FROM proc_hits

        WHERE is_mv

        GROUP BY concept_name

        ORDER BY n DESC, concept_name

        LIMIT 10
    ) s
),

proc_intub_top AS (
    SELECT
        STRING_AGG(
            concept_name || ' (' || n || ')',
            '; ' ORDER BY n DESC, concept_name
        ) AS result

    FROM (
        SELECT
            concept_name,
            COUNT(*) AS n

        FROM proc_hits

        WHERE is_intub

        GROUP BY concept_name

        ORDER BY n DESC, concept_name

        LIMIT 10
    ) s
),

obs_mv_top AS (
    SELECT
        STRING_AGG(
            concept_name || ' (' || n || ')',
            '; ' ORDER BY n DESC, concept_name
        ) AS result

    FROM (
        SELECT
            concept_name,
            COUNT(*) AS n

        FROM obs_hits

        GROUP BY concept_name

        ORDER BY n DESC, concept_name

        LIMIT 10
    ) s
),

device_mv_top AS (
    SELECT
        STRING_AGG(
            concept_name || ' (' || n || ')',
            '; ' ORDER BY n DESC, concept_name
        ) AS result

    FROM (
        SELECT
            concept_name,
            COUNT(*) AS n

        FROM device_hits

        GROUP BY concept_name

        ORDER BY n DESC, concept_name

        LIMIT 10
    ) s
),

/* ===========================================================================
   8. Final statistics

   Same 22 output rows as the previous query.
   =========================================================================== */

statistics AS (

    SELECT
        1 AS metric_order,
        'Mechanical ventilation' AS section,
        'PROCEDURE_OCCURRENCE records (n)' AS variable,
        mv_records_n::text AS result
    FROM proc_stats


    UNION ALL

    SELECT
        2,
        'Mechanical ventilation',
        'PROCEDURE_OCCURRENCE patients (n)',
        mv_patients_n::text
    FROM proc_stats


    UNION ALL

    SELECT
        3,
        'Mechanical ventilation',
        'Procedure datetime populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                mv_datetime_n /
                NULLIF(mv_records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM proc_stats


    UNION ALL

    SELECT
        4,
        'Mechanical ventilation',
        'Procedure visit_occurrence_id populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                mv_visit_n /
                NULLIF(mv_records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM proc_stats


    UNION ALL

    SELECT
        5,
        'Mechanical ventilation',
        'Procedure visit_detail_id populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                mv_visit_detail_n /
                NULLIF(mv_records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM proc_stats


    /* ---------------- Intubation / extubation ---------------- */

    UNION ALL

    SELECT
        6,
        'Airway',
        'Tracheal intubation records (n)',
        intub_records_n::text
    FROM proc_stats


    UNION ALL

    SELECT
        7,
        'Airway',
        'Patients with tracheal intubation (n)',
        intub_patients_n::text
    FROM proc_stats


    UNION ALL

    SELECT
        8,
        'Airway',
        'Intubation datetime populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                intub_datetime_n /
                NULLIF(intub_records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM proc_stats


    UNION ALL

    SELECT
        9,
        'Airway',
        'Extubation candidate records (n)',
        extub_records_n::text
    FROM proc_stats


    /* ---------------- Observation ---------------- */

    UNION ALL

    SELECT
        10,
        'OBSERVATION',
        'Mechanical-ventilation records (n)',
        records_n::text
    FROM obs_stats


    UNION ALL

    SELECT
        11,
        'OBSERVATION',
        'Mechanical-ventilation patients (n)',
        patients_n::text
    FROM obs_stats


    UNION ALL

    SELECT
        12,
        'OBSERVATION',
        'Observation datetime populated (%)',

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
        13,
        'OBSERVATION',
        'Observation visit linkage',

        'visit_occurrence_id=' ||

        COALESCE(
            ROUND(
                100.0 *
                visit_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

        ||

        '; visit_detail_id=' ||

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


    /* ---------------- Device exposure ---------------- */

    UNION ALL

    SELECT
        14,
        'DEVICE_EXPOSURE',
        'Ventilator device records (n)',
        records_n::text
    FROM device_stats


    UNION ALL

    SELECT
        15,
        'DEVICE_EXPOSURE',
        'Ventilator device patients (n)',
        patients_n::text
    FROM device_stats


    UNION ALL

    SELECT
        16,
        'DEVICE_EXPOSURE',
        'Start and end datetime both populated (%)',

        COALESCE(
            ROUND(
                100.0 *
                complete_datetime_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM device_stats


    UNION ALL

    SELECT
        17,
        'DEVICE_EXPOSURE',
        'Chronologically valid intervals among complete (%)',

        COALESCE(
            ROUND(
                100.0 *
                valid_interval_n /
                NULLIF(complete_datetime_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM device_stats


    UNION ALL

    SELECT
        18,
        'DEVICE_EXPOSURE',
        'Ventilator device visit linkage',

        'visit_occurrence_id=' ||

        COALESCE(
            ROUND(
                100.0 *
                visit_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

        ||

        '; visit_detail_id=' ||

        COALESCE(
            ROUND(
                100.0 *
                visit_detail_n /
                NULLIF(records_n, 0),
                1
            )::text || '%',
            'N/A'
        )

    FROM device_stats


    /* ---------------- Observed concepts ---------------- */

    UNION ALL

    SELECT
        19,
        'Observed concepts',
        'Mechanical-ventilation procedure concepts',
        COALESCE(result, 'NONE')
    FROM proc_mv_top


    UNION ALL

    SELECT
        20,
        'Observed concepts',
        'Tracheal-intubation procedure concepts',
        COALESCE(result, 'NONE')
    FROM proc_intub_top


    UNION ALL

    SELECT
        21,
        'Observed concepts',
        'Mechanical-ventilation observation concepts',
        COALESCE(result, 'NONE')
    FROM obs_mv_top


    UNION ALL

    SELECT
        22,
        'Observed concepts',
        'Ventilator device concepts',
        COALESCE(result, 'NONE')
    FROM device_mv_top
)

SELECT
    section,
    variable,
    result

FROM statistics

ORDER BY metric_order;
