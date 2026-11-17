/* ============================================================================
   FLUID BALANCE DATA EXPECTATIONS - LIGHTWEIGHT SCREENING
   PostgreSQL / OMOP CDM

   PURPOSE
   -------
   Screening only. This is NOT a fluid-overload phenotype.

   Main questions:
     1. Are quantitative fluid intake and output represented?
     2. Can major input/output components be distinguished?
     3. Are numeric values, units and datetimes available?
     4. Can records be linked to hospitalization / ICU?
     5. Do patient-visit-days contain BOTH intake and output?
     6. Is body weight available for normalized analyses?

   PERFORMANCE
   -----------
   - Regex is applied to CONCEPT only.
   - MEASUREMENT is scanned once.
   - OBSERVATION is scanned once.
   - No regex is applied to full *_source_value columns.
   ============================================================================ */

WITH

/* ---------------------------------------------------------------------------
   1. High-value known concepts from the supplied inventory
   --------------------------------------------------------------------------- */
seed(concept_id, component) AS (
    VALUES

    /* IV / parenteral intake */
    (2147483497, 'IN_IV'),
    (2147483498, 'IN_IV'),
    (2147483412, 'IN_IV'),
    (4090200,    'IN_IV'),
    (21491171,   'IN_NUTRITION'),
    (3037253,    'IN_IV'),
    (3035591,    'IN_IV'),
    (3037775,    'IN_IV'),

    /* Oral / enteral intake */
    (2147483413, 'IN_ENTERAL_ORAL'),
    (21491169,   'IN_ENTERAL_ORAL'),
    (3012677,    'IN_ENTERAL_ORAL'),
    (3002791,    'IN_ENTERAL_ORAL'),
    (2147483411, 'IN_ENTERAL_ORAL'),
    (3020617,    'IN_ENTERAL_ORAL'),
    (3017465,    'IN_ENTERAL_ORAL'),
    (3014013,    'IN_ENTERAL_ORAL'),
    (21491170,   'IN_ENTERAL_ORAL'),
    (3010494,    'IN_ENTERAL_ORAL'),
    (21493071,   'IN_ENTERAL_ORAL'),
    (21493079,   'IN_ENTERAL_ORAL'),
    (37311741,   'IN_ENTERAL_ORAL'),
    (37153230,   'IN_NUTRITION'),

    /* Urine */
    (21491173,   'OUT_URINE'),
    (21493221,   'OUT_URINE'),
    (3016267,    'OUT_URINE'),
    (3008828,    'OUT_URINE'),
    (3008071,    'OUT_URINE'),
    (3018727,    'OUT_URINE'),
    (3014835,    'OUT_URINE'),
    (3014315,    'OUT_URINE'),
    (4264378,    'OUT_URINE'),

    /* Drains / GI / other physical output */
    (40484209,   'OUT_DRAIN'),
    (4090194,    'OUT_DRAIN'),
    (3006376,    'OUT_DRAIN'),
    (3026556,    'OUT_DRAIN'),
    (3023454,    'OUT_DRAIN'),
    (3025727,    'OUT_DRAIN'),
    (3017152,    'OUT_DRAIN'),
    (3037836,    'OUT_DRAIN'),
    (21491180,   'OUT_DRAIN'),
    (21491181,   'OUT_DRAIN'),
    (21491183,   'OUT_DRAIN'),
    (21491184,   'OUT_DRAIN'),
    (21491185,   'OUT_DRAIN'),

    /* Blood loss */
    (3021505,    'OUT_BLOOD'),
    (3016687,    'OUT_BLOOD'),
    (21493943,   'OUT_BLOOD'),
    (4354266,    'OUT_BLOOD'),
    (3009631,    'OUT_BLOOD'),

    /* Actual dialysis / ultrafiltration output */
    (1989402,    'OUT_RRT'),
    (1988590,    'OUT_RRT'),
    (1989626,    'OUT_RRT'),
    (1988731,    'OUT_RRT'),
    (2147483313, 'OUT_RRT'),
    (2147483530, 'OUT_RRT'),
    (4139443,    'OUT_RRT'),

    /* Total / miscellaneous output */
    (3018366,    'OUT_TOTAL_OTHER'),
    (3012848,    'OUT_TOTAL_OTHER'),
    (3008540,    'OUT_TOTAL_OTHER'),
    (3020433,    'OUT_TOTAL_OTHER'),
    (3028277,    'OUT_TOTAL_OTHER')
),

/* ---------------------------------------------------------------------------
   2. Candidate concepts and component classification
   --------------------------------------------------------------------------- */
candidate_concepts AS MATERIALIZED (

    SELECT
        c.concept_id,
        c.concept_name,
        c.domain_id,

        CASE
            WHEN s.component IS NOT NULL
                THEN s.component

            WHEN c.concept_name ~* 'urine[[:space:]-]*output'
                THEN 'OUT_URINE'

            WHEN c.concept_name ~*
                'ultrafiltrat.{0,20}remov|'
                'hemodialysis.{0,25}fluid.{0,15}removed|'
                '(crrt|ckrt).{0,30}(ultrafiltrat|total[[:space:]-]*output)|'
                'peritoneal[[:space:]-]*dialysis.{0,30}(fluid|output)'
                THEN 'OUT_RRT'

            WHEN c.concept_name ~* 'blood[[:space:]-]*loss'
                THEN 'OUT_BLOOD'

            WHEN c.concept_name ~*
                'fluid[[:space:]-]*output.{0,30}(drain|tube)|'
                '(wound|chest|gastric|gastrointestinal|peritoneal|'
                'pericardial|neurolog|cerebral|subarachnoid).{0,20}'
                '(drain|tube).{0,20}(output|fluid)|'
                'fluid[[:space:]-]*output.{0,20}(emesis|ostomy|secretion)'
                THEN 'OUT_DRAIN'

            WHEN c.concept_name ~*
                'fluid[[:space:]-]*output[[:space:]-]*total|'
                'total.{0,15}fluid[[:space:]-]*output|'
                'fluid[[:space:]-]*output[[:space:]-]*miscellaneous'
                THEN 'OUT_TOTAL_OTHER'

            WHEN c.concept_name ~*
                'parenteral[[:space:]-]*nutrition|'
                'tpn.{0,20}volume|'
                'lipid.{0,25}fluid[[:space:]-]*intake'
                THEN 'IN_NUTRITION'

            WHEN c.concept_name ~*
                'oral.{0,20}(fluid[[:space:]-]*intake|intake)|'
                'enteral.{0,25}(fluid|formula|intake|volume)|'
                'tube.{0,25}(intake|feeding).{0,25}(volume|fluid)|'
                'formula[[:space:]-]*intake|'
                'infant.{0,15}(feed|formula).{0,20}(intake|volume)|'
                '(nasogastric|gastrostomy).{0,20}fluid[[:space:]-]*intake'
                THEN 'IN_ENTERAL_ORAL'

            WHEN c.concept_name ~*
                'maintenance.{0,10}iv.{0,15}volume|'
                'iv.{0,15}(maintenance|bolus|piggyback).{0,20}volume|'
                'intravascular.{0,20}fluid[[:space:]-]*intake|'
                'parenteral[[:space:]-]*fluid[[:space:]-]*input'
                THEN 'IN_IV'

            ELSE NULL
        END AS component,

        (
            c.domain_id = 'Measurement'
            AND c.concept_name ~*
                '(^|[^a-z])body[[:space:]-]*weight([^a-z]|$)|'
                'patient[[:space:]-]*weight|'
                'weight[[:space:]-]*measured'
        ) AS is_weight

    FROM {{schema}}.concept c

    LEFT JOIN seed s
      ON s.concept_id = c.concept_id

    WHERE c.domain_id IN ('Measurement', 'Observation')

      AND (
             s.concept_id IS NOT NULL

          OR c.concept_name ~*
                'fluid[[:space:]-]*(intake|input|output)|'
                'oral.{0,20}intake|'
                'enteral.{0,25}(intake|volume|formula)|'
                'tube.{0,25}(intake|feeding|output)|'
                'formula[[:space:]-]*intake|'
                'infant.{0,15}(feed|formula)|'
                'maintenance.{0,10}iv|'
                'iv.{0,15}(bolus|piggyback)|'
                'intravascular.{0,20}fluid|'
                'parenteral.{0,20}(fluid|nutrition)|'
                'urine[[:space:]-]*output|'
                'blood[[:space:]-]*loss|'
                'drain.{0,20}output|'
                'ultrafiltrat.{0,20}remov|'
                'hemodialysis.{0,25}fluid.{0,15}removed|'
                '(crrt|ckrt).{0,30}(ultrafiltrat|total[[:space:]-]*output)|'
                '(^|[^a-z])body[[:space:]-]*weight([^a-z]|$)|'
                'patient[[:space:]-]*weight|'
                'weight[[:space:]-]*measured'
      )
),

/* ===========================================================================
   3. MEASUREMENT: one scan
   =========================================================================== */
measurement_hits AS MATERIALIZED (

    SELECT
        m.person_id,
        m.measurement_concept_id AS concept_id,
        c.concept_name,
        c.component,
        c.is_weight,

        m.measurement_date AS event_date,
        m.measurement_datetime AS event_datetime,

        m.value_as_number,
        m.unit_concept_id,
        m.unit_source_value,

        m.visit_occurrence_id,
        m.visit_detail_id

    FROM {{schema}}.measurement m

    JOIN candidate_concepts c
      ON c.concept_id = m.measurement_concept_id

    WHERE c.domain_id = 'Measurement'
      AND (c.component IS NOT NULL OR c.is_weight)
),

/* ===========================================================================
   4. OBSERVATION: one scan
   =========================================================================== */
observation_hits AS MATERIALIZED (

    SELECT
        o.person_id,
        o.observation_concept_id AS concept_id,
        c.concept_name,
        c.component,

        o.observation_date AS event_date,
        o.observation_datetime AS event_datetime,

        o.value_as_number,
        o.unit_concept_id,
        o.unit_source_value,

        o.visit_occurrence_id,
        o.visit_detail_id

    FROM {{schema}}.observation o

    JOIN candidate_concepts c
      ON c.concept_id = o.observation_concept_id

    WHERE c.domain_id = 'Observation'
      AND c.component IS NOT NULL
),

/* ===========================================================================
   5. Normalized quantitative fluid event stream
   =========================================================================== */
fluid_events AS MATERIALIZED (

    SELECT
        person_id,
        concept_id,
        concept_name,
        component,
        event_date,
        event_datetime,
        value_as_number,
        unit_concept_id,
        unit_source_value,
        visit_occurrence_id,
        visit_detail_id
    FROM measurement_hits
    WHERE component IS NOT NULL

    UNION ALL

    SELECT
        person_id,
        concept_id,
        concept_name,
        component,
        event_date,
        event_datetime,
        value_as_number,
        unit_concept_id,
        unit_source_value,
        visit_occurrence_id,
        visit_detail_id
    FROM observation_hits
),

fluid_stats AS (

    SELECT
        COUNT(*) FILTER (
            WHERE component LIKE 'IN_%'
        ) AS intake_records_n,

        COUNT(DISTINCT person_id) FILTER (
            WHERE component LIKE 'IN_%'
        ) AS intake_patients_n,

        COUNT(*) FILTER (
            WHERE component LIKE 'OUT_%'
        ) AS output_records_n,

        COUNT(DISTINCT person_id) FILTER (
            WHERE component LIKE 'OUT_%'
        ) AS output_patients_n,

        COUNT(*) AS all_records_n,

        COUNT(*) FILTER (
            WHERE value_as_number IS NOT NULL
        ) AS numeric_n,

        COUNT(*) FILTER (
            WHERE value_as_number IS NOT NULL
              AND (
                     COALESCE(unit_concept_id, 0) <> 0
                  OR NULLIF(TRIM(unit_source_value), '') IS NOT NULL
              )
        ) AS numeric_unit_n,

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
            WHERE value_as_number IS NOT NULL
              AND (
                     COALESCE(unit_concept_id, 0) <> 0
                  OR NULLIF(TRIM(unit_source_value), '') IS NOT NULL
              )
              AND event_datetime IS NOT NULL
              AND visit_occurrence_id IS NOT NULL
        ) AS fully_usable_n

    FROM fluid_events
),

/* ---------------------------------------------------------------------------
   6. Component counts
   --------------------------------------------------------------------------- */
component_summary AS (
    SELECT STRING_AGG(
        component || '=' || n,
        '; ' ORDER BY component
    ) AS result
    FROM (
        SELECT component, COUNT(*) AS n
        FROM fluid_events
        GROUP BY component
    ) s
),

/* ---------------------------------------------------------------------------
   7. Can daily net balance potentially be calculated?
   --------------------------------------------------------------------------- */
fluid_day AS (
    SELECT
        person_id,
        visit_occurrence_id,
        event_date,

        COUNT(*) FILTER (
            WHERE component LIKE 'IN_%'
              AND value_as_number IS NOT NULL
        ) AS in_n,

        COUNT(*) FILTER (
            WHERE component LIKE 'OUT_%'
              AND value_as_number IS NOT NULL
        ) AS out_n

    FROM fluid_events

    WHERE visit_occurrence_id IS NOT NULL
      AND event_date IS NOT NULL

    GROUP BY
        person_id,
        visit_occurrence_id,
        event_date
),

fluid_day_stats AS (
    SELECT
        COUNT(*) AS days_n,
        COUNT(*) FILTER (
            WHERE in_n > 0 AND out_n > 0
        ) AS both_n
    FROM fluid_day
),

/* ---------------------------------------------------------------------------
   8. Weight availability
   --------------------------------------------------------------------------- */
fluid_visits AS (
    SELECT DISTINCT
        person_id,
        visit_occurrence_id
    FROM fluid_events
    WHERE visit_occurrence_id IS NOT NULL
),

weight_visits AS (
    SELECT DISTINCT
        person_id,
        visit_occurrence_id
    FROM measurement_hits
    WHERE is_weight
      AND value_as_number IS NOT NULL
      AND visit_occurrence_id IS NOT NULL
),

weight_stats AS (
    SELECT
        COUNT(*) AS fluid_visits_n,

        COUNT(*) FILTER (
            WHERE w.visit_occurrence_id IS NOT NULL
        ) AS fluid_visits_with_weight_n

    FROM fluid_visits f

    LEFT JOIN weight_visits w
      ON w.person_id = f.person_id
     AND w.visit_occurrence_id = f.visit_occurrence_id
),

/* ---------------------------------------------------------------------------
   9. Semantic inspection
   --------------------------------------------------------------------------- */
top_intake AS (
    SELECT STRING_AGG(
        concept_name || ' (' || n || ')',
        '; ' ORDER BY n DESC, concept_name
    ) AS result
    FROM (
        SELECT concept_name, COUNT(*) AS n
        FROM fluid_events
        WHERE component LIKE 'IN_%'
        GROUP BY concept_name
        ORDER BY n DESC
        LIMIT 12
    ) s
),

top_output AS (
    SELECT STRING_AGG(
        concept_name || ' (' || n || ')',
        '; ' ORDER BY n DESC, concept_name
    ) AS result
    FROM (
        SELECT concept_name, COUNT(*) AS n
        FROM fluid_events
        WHERE component LIKE 'OUT_%'
        GROUP BY concept_name
        ORDER BY n DESC
        LIMIT 12
    ) s
),

top_units AS (
    SELECT STRING_AGG(
        unit_name || ' (' || n || ')',
        '; ' ORDER BY n DESC, unit_name
    ) AS result
    FROM (
        SELECT
            COALESCE(
                uc.concept_name,
                NULLIF(TRIM(f.unit_source_value), ''),
                'UNSPECIFIED'
            ) AS unit_name,
            COUNT(*) AS n

        FROM fluid_events f

        LEFT JOIN {{schema}}.concept uc
          ON uc.concept_id = f.unit_concept_id

        WHERE f.value_as_number IS NOT NULL

        GROUP BY 1
        ORDER BY n DESC
        LIMIT 12
    ) s
),

/* ===========================================================================
   10. Final output
   =========================================================================== */
statistics AS (

    SELECT 1 AS metric_order,
           'Coverage' AS section,
           'Fluid intake records (n)' AS variable,
           intake_records_n::text AS result
    FROM fluid_stats

    UNION ALL
    SELECT 2, 'Coverage',
           'Patients with fluid intake records (n)',
           intake_patients_n::text
    FROM fluid_stats

    UNION ALL
    SELECT 3, 'Coverage',
           'Fluid output records (n)',
           output_records_n::text
    FROM fluid_stats

    UNION ALL
    SELECT 4, 'Coverage',
           'Patients with fluid output records (n)',
           output_patients_n::text
    FROM fluid_stats

    UNION ALL
    SELECT 5, 'Representation',
           'Fluid components observed',
           COALESCE(result, 'NONE')
    FROM component_summary

    UNION ALL
    SELECT 6, 'Quantitative readiness',
           'Numeric value populated (%)',
           COALESCE(
               ROUND(
                   100.0 * numeric_n /
                   NULLIF(all_records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM fluid_stats

    UNION ALL
    SELECT 7, 'Quantitative readiness',
           'Unit populated among numeric records (%)',
           COALESCE(
               ROUND(
                   100.0 * numeric_unit_n /
                   NULLIF(numeric_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM fluid_stats

    UNION ALL
    SELECT 8, 'Temporal',
           'Event datetime populated (%)',
           COALESCE(
               ROUND(
                   100.0 * datetime_n /
                   NULLIF(all_records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM fluid_stats

    UNION ALL
    SELECT 9, 'Linkage',
           'visit_occurrence_id populated (%)',
           COALESCE(
               ROUND(
                   100.0 * visit_n /
                   NULLIF(all_records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM fluid_stats

    UNION ALL
    SELECT 10, 'Linkage',
           'visit_detail_id populated (%)',
           COALESCE(
               ROUND(
                   100.0 * visit_detail_n /
                   NULLIF(all_records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM fluid_stats

    UNION ALL
    SELECT 11, 'Quantitative readiness',
           'Records with numeric value + unit + datetime + visit (%)',
           COALESCE(
               ROUND(
                   100.0 * fully_usable_n /
                   NULLIF(all_records_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM fluid_stats

    UNION ALL
    SELECT 12, 'Reconstructability',
           'Patient-visit-days with both numeric intake and output (%)',
           COALESCE(
               ROUND(
                   100.0 * both_n /
                   NULLIF(days_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM fluid_day_stats

    UNION ALL
    SELECT 13, 'Normalization',
           'Fluid-data visits with any body-weight measurement (%)',
           COALESCE(
               ROUND(
                   100.0 * fluid_visits_with_weight_n /
                   NULLIF(fluid_visits_n, 0), 1
               )::text || '%',
               'N/A'
           )
    FROM weight_stats

    UNION ALL
    SELECT 14, 'Observed representation',
           'Top intake concepts',
           COALESCE(result, 'NONE')
    FROM top_intake

    UNION ALL
    SELECT 15, 'Observed representation',
           'Top output concepts',
           COALESCE(result, 'NONE')
    FROM top_output

    UNION ALL
    SELECT 16, 'Observed representation',
           'Top units among numeric records',
           COALESCE(result, 'NONE')
    FROM top_units
)

SELECT
    section,
    variable,
    result
FROM statistics
ORDER BY metric_order;
