/* ============================================================================
   CONTINUOUS DRUG INFUSION DATA EXPECTATIONS
   Lightweight screening query
   PostgreSQL / OMOP CDM v5.4

   Drugs:
     - Norepinephrine
     - Propofol

   IMPORTANT
   ---------
   This is a SCREENING query.

   It assesses whether the current OMOP representation appears capable of
   supporting continuous-infusion analyses. It does NOT prove that:
     - each DRUG_EXPOSURE row represents an administration,
     - QUANTITY represents infusion rate,
     - records represent unique infusion episodes,
     - or the source data are absent when no standardized records are found.

   ============================================================================ */


WITH


/* ---------------------------------------------------------------------------
   1. Identify standard RxNorm ingredients dynamically
   --------------------------------------------------------------------------- */
ingredients AS MATERIALIZED (

    SELECT
        concept_id AS ingredient_concept_id,

        CASE
            WHEN LOWER(concept_name) = 'norepinephrine'
                THEN 'Norepinephrine'

            WHEN LOWER(concept_name) = 'propofol'
                THEN 'Propofol'
        END AS drug_name,

        CASE
            WHEN LOWER(concept_name) = 'norepinephrine' THEN 1
            WHEN LOWER(concept_name) = 'propofol'       THEN 2
        END AS drug_order

    FROM {{schema}}.concept

    WHERE vocabulary_id = 'RxNorm'
      AND standard_concept = 'S'
      AND concept_class_id = 'Ingredient'
      AND LOWER(concept_name) IN (
            'norepinephrine',
            'propofol'
      )
),


/* ---------------------------------------------------------------------------
   2. Obtain all descendant standard drug concepts
   --------------------------------------------------------------------------- */
drug_concepts AS MATERIALIZED (

    SELECT
        i.drug_name,
        i.drug_order,
        ca.descendant_concept_id AS drug_concept_id

    FROM ingredients i

    JOIN {{schema}}.concept_ancestor ca
      ON ca.ancestor_concept_id = i.ingredient_concept_id


    UNION


    SELECT
        drug_name,
        drug_order,
        ingredient_concept_id

    FROM ingredients
),


/* ---------------------------------------------------------------------------
   3. Pull ONLY relevant DRUG_EXPOSURE rows.

   Regex and other diagnostics therefore run only against norepinephrine
   and propofol rather than the entire DRUG_EXPOSURE table.
   --------------------------------------------------------------------------- */
drug_rows_raw AS MATERIALIZED (

    SELECT
        dc.drug_name,
        dc.drug_order,

        d.drug_exposure_id,
        d.person_id,

        d.drug_concept_id,

        d.drug_exposure_start_datetime,
        d.drug_exposure_end_datetime,

        d.quantity,

        d.dose_unit_source_value,

        d.route_source_value,
        d.route_concept_id,

        d.drug_type_concept_id,

        d.visit_occurrence_id,
        d.visit_detail_id,

        d.drug_source_value,

        rc.concept_name AS route_concept_name,

        dtc.concept_name AS drug_type_concept_name,

        /* Normalize common unit formatting only for screening */
        LOWER(
            REPLACE(
                REPLACE(
                    REGEXP_REPLACE(
                        COALESCE(TRIM(d.dose_unit_source_value), ''),
                        '[[:space:]]+',
                        '',
                        'g'
                    ),
                    'µ',
                    'u'
                ),
                'μ',
                'u'
            )
        ) AS unit_norm

    FROM {{schema}}.drug_exposure d

    JOIN drug_concepts dc
      ON dc.drug_concept_id = d.drug_concept_id

    LEFT JOIN {{schema}}.concept rc
      ON rc.concept_id = d.route_concept_id

    LEFT JOIN {{schema}}.concept dtc
      ON dtc.concept_id = d.drug_type_concept_id
),


/* ---------------------------------------------------------------------------
   4. Screening flags
   --------------------------------------------------------------------------- */
drug_rows AS MATERIALIZED (

    SELECT
        *,

        /* Typical mass/time infusion-rate units.

           Examples captured:
             mcg/kg/min
             ug/kg/min
             ng/kg/min
             mcg/min
             mg/kg/hr
             mg/hr

           This is intentionally screening logic, not a standardized
           unit ontology.
        */
        (
            unit_norm ~
            '^(mcg|ug|ng|mg|g)/(kg/)?(min|minute|minutes|h|hr|hour|hours)$'
        ) AS is_dose_rate_unit,


        /* Source route explicitly looks intravenous */
        (
            LOWER(COALESCE(route_source_value, '')) ~
            '(^|[^a-z])(iv|intravenous)([^a-z]|$)'
        ) AS source_says_iv,


        /* Standardized route looks intravenous */
        (
            LOWER(COALESCE(route_concept_name, '')) ~
            'intravenous'
        ) AS standard_says_iv

    FROM drug_rows_raw
),


/* ---------------------------------------------------------------------------
   5. Per-patient record density
   Diagnostic of source / ETL grain
   --------------------------------------------------------------------------- */
patient_record_counts AS (

    SELECT
        drug_name,
        person_id,
        COUNT(*) AS records_per_patient

    FROM drug_rows

    GROUP BY
        drug_name,
        person_id
),


patient_stats AS (

    SELECT
        drug_name,

        PERCENTILE_CONT(0.5)
        WITHIN GROUP (
            ORDER BY records_per_patient
        ) AS median_records_per_patient

    FROM patient_record_counts

    GROUP BY drug_name
),


/* ---------------------------------------------------------------------------
   6. Temporal ordering.

   Restricted to valid intervals that can be assigned to a Visit.

   This checks the previously discussed pattern:

       current.end_datetime ≈ next.start_datetime

   It is NOT an OMOP validity requirement.
   --------------------------------------------------------------------------- */
ordered_intervals AS (

    SELECT
        drug_name,
        person_id,
        visit_occurrence_id,
        drug_exposure_id,

        drug_exposure_start_datetime,
        drug_exposure_end_datetime,

        LEAD(drug_exposure_start_datetime)
        OVER (
            PARTITION BY
                drug_name,
                person_id,
                visit_occurrence_id

            ORDER BY
                drug_exposure_start_datetime,
                drug_exposure_id
        ) AS next_start_datetime

    FROM drug_rows

    WHERE visit_occurrence_id IS NOT NULL

      AND drug_exposure_start_datetime IS NOT NULL
      AND drug_exposure_end_datetime   IS NOT NULL

      AND drug_exposure_end_datetime >=
          drug_exposure_start_datetime
),


interval_stats AS (

    SELECT
        drug_name,

        COUNT(*) FILTER (
            WHERE next_start_datetime IS NOT NULL
        ) AS consecutive_pairs_n,


        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE next_start_datetime IS NOT NULL

                  AND ABS(
                      EXTRACT(
                          EPOCH FROM (
                              drug_exposure_end_datetime
                              - next_start_datetime
                          )
                      )
                  ) <= 60
            )
            /
            NULLIF(
                COUNT(*) FILTER (
                    WHERE next_start_datetime IS NOT NULL
                ),
                0
            ),
            1
        ) AS contiguous_within_1min_pct,


        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE next_start_datetime IS NOT NULL
                  AND next_start_datetime <
                      drug_exposure_end_datetime
            )
            /
            NULLIF(
                COUNT(*) FILTER (
                    WHERE next_start_datetime IS NOT NULL
                ),
                0
            ),
            1
        ) AS overlapping_intervals_pct

    FROM ordered_intervals

    GROUP BY drug_name
),


/* ---------------------------------------------------------------------------
   7. Unit inventory
   --------------------------------------------------------------------------- */
unit_counts AS (

    SELECT
        drug_name,
        TRIM(dose_unit_source_value) AS dose_unit_source_value,
        COUNT(*) AS records

    FROM drug_rows

    WHERE dose_unit_source_value IS NOT NULL
      AND TRIM(dose_unit_source_value) <> ''

    GROUP BY
        drug_name,
        TRIM(dose_unit_source_value)
),


unit_summary AS (

    SELECT
        drug_name,

        STRING_AGG(
            dose_unit_source_value
            || ' (' || records::text || ')',
            ' | '
            ORDER BY records DESC, dose_unit_source_value
        ) AS dose_units_observed

    FROM unit_counts

    GROUP BY drug_name
),


/* ---------------------------------------------------------------------------
   8. DRUG_TYPE inventory

   Critical for distinguishing orders, prescriptions, administrations, etc.
   --------------------------------------------------------------------------- */
drug_type_counts AS (

    SELECT
        drug_name,

        COALESCE(
            drug_type_concept_name,
            '[unknown concept ' || drug_type_concept_id::text || ']'
        ) AS drug_type,

        COUNT(*) AS records

    FROM drug_rows

    GROUP BY
        drug_name,
        drug_type_concept_name,
        drug_type_concept_id
),


drug_type_summary AS (

    SELECT
        drug_name,

        STRING_AGG(
            drug_type
            || ' (' || records::text || ')',
            ' | '
            ORDER BY records DESC, drug_type
        ) AS drug_types_observed

    FROM drug_type_counts

    GROUP BY drug_name
),


/* ---------------------------------------------------------------------------
   9. Route inventory
   --------------------------------------------------------------------------- */
route_counts AS (

    SELECT
        drug_name,

        COALESCE(
            NULLIF(TRIM(route_source_value), ''),
            '[NULL]'
        ) AS source_route,

        route_concept_id,

        CASE
            WHEN route_concept_id = 0
                THEN '[0 / unmapped]'

            WHEN route_concept_id IS NULL
                THEN '[NULL]'

            ELSE COALESCE(
                route_concept_name,
                '[concept name unavailable]'
            )
        END AS standard_route,

        COUNT(*) AS records

    FROM drug_rows

    GROUP BY
        drug_name,
        route_source_value,
        route_concept_id,
        route_concept_name
),


route_summary AS (

    SELECT
        drug_name,

        STRING_AGG(
            source_route
            || ' → '
            || standard_route
            || ' (' || records::text || ')',
            ' | '
            ORDER BY records DESC, source_route
        ) AS route_mappings_observed

    FROM route_counts

    GROUP BY drug_name
),


/* ---------------------------------------------------------------------------
   10. Main statistics
   --------------------------------------------------------------------------- */
drug_stats AS (

    SELECT
        drug_name,

        COUNT(*) AS records_n,

        COUNT(DISTINCT person_id) AS patients_n,

        COUNT(DISTINCT drug_concept_id)
            AS distinct_drug_concepts_n,


        /* ---------------------------------------------------------------
           Datetime completeness
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE drug_exposure_start_datetime IS NOT NULL
                  AND drug_exposure_end_datetime   IS NOT NULL
            )
            / NULLIF(COUNT(*), 0),
            1
        ) AS complete_datetime_pct,


        /* ---------------------------------------------------------------
           Chronological validity among complete intervals
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE drug_exposure_start_datetime IS NOT NULL
                  AND drug_exposure_end_datetime   IS NOT NULL
                  AND drug_exposure_end_datetime >=
                      drug_exposure_start_datetime
            )
            /
            NULLIF(
                COUNT(*) FILTER (
                    WHERE drug_exposure_start_datetime IS NOT NULL
                      AND drug_exposure_end_datetime   IS NOT NULL
                ),
                0
            ),
            1
        ) AS chronologically_valid_pct,


        /* ---------------------------------------------------------------
           Zero-duration rows among complete intervals
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE drug_exposure_start_datetime IS NOT NULL
                  AND drug_exposure_end_datetime   IS NOT NULL
                  AND drug_exposure_end_datetime =
                      drug_exposure_start_datetime
            )
            /
            NULLIF(
                COUNT(*) FILTER (
                    WHERE drug_exposure_start_datetime IS NOT NULL
                      AND drug_exposure_end_datetime   IS NOT NULL
                ),
                0
            ),
            1
        ) AS zero_duration_pct,


        /* ---------------------------------------------------------------
           Median POSITIVE interval duration
           --------------------------------------------------------------- */
        ROUND(
            (
                PERCENTILE_CONT(0.5)
                WITHIN GROUP (
                    ORDER BY
                        EXTRACT(
                            EPOCH FROM (
                                drug_exposure_end_datetime
                                - drug_exposure_start_datetime
                            )
                        ) / 60.0
                )
                FILTER (
                    WHERE drug_exposure_start_datetime IS NOT NULL
                      AND drug_exposure_end_datetime   IS NOT NULL
                      AND drug_exposure_end_datetime >
                          drug_exposure_start_datetime
                )
            )::numeric,
            1
        ) AS median_interval_minutes,


        /* ---------------------------------------------------------------
           Unit availability
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE dose_unit_source_value IS NOT NULL
                  AND TRIM(dose_unit_source_value) <> ''
            )
            / NULLIF(COUNT(*), 0),
            1
        ) AS dose_unit_populated_pct,


        /* ---------------------------------------------------------------
           How many populated units actually look like dose rates?
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE is_dose_rate_unit
            )
            /
            NULLIF(
                COUNT(*) FILTER (
                    WHERE dose_unit_source_value IS NOT NULL
                      AND TRIM(dose_unit_source_value) <> ''
                ),
                0
            ),
            1
        ) AS dose_rate_unit_pct,


        /* ---------------------------------------------------------------
           Quantity availability
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE quantity IS NOT NULL
            )
            / NULLIF(COUNT(*), 0),
            1
        ) AS quantity_populated_pct,


        /* ---------------------------------------------------------------
           Candidate numeric infusion rate.

           IMPORTANT:
           This is only a screening signal.
           QUANTITY semantics must still be validated locally.
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE quantity IS NOT NULL
                  AND is_dose_rate_unit
            )
            / NULLIF(COUNT(*), 0),
            1
        ) AS candidate_numeric_rate_pct,


        /* ---------------------------------------------------------------
           Route
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE route_source_value IS NOT NULL
                  AND TRIM(route_source_value) <> ''
            )
            / NULLIF(COUNT(*), 0),
            1
        ) AS route_source_populated_pct,


        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE route_concept_id IS NOT NULL
                  AND route_concept_id <> 0
            )
            / NULLIF(COUNT(*), 0),
            1
        ) AS standardized_route_populated_pct,


        /* ---------------------------------------------------------------
           Source says IV but standardized route does not.
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE source_says_iv
                  AND (
                        route_concept_id IS NULL
                        OR route_concept_id = 0
                        OR NOT standard_says_iv
                  )
            )
            /
            NULLIF(
                COUNT(*) FILTER (
                    WHERE source_says_iv
                ),
                0
            ),
            1
        ) AS iv_route_mismatch_pct,


        /* ---------------------------------------------------------------
           Visit linkage
           --------------------------------------------------------------- */
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE visit_occurrence_id IS NOT NULL
            )
            / NULLIF(COUNT(*), 0),
            1
        ) AS visit_occurrence_populated_pct,


        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE visit_detail_id IS NOT NULL
            )
            / NULLIF(COUNT(*), 0),
            1
        ) AS visit_detail_populated_pct

    FROM drug_rows

    GROUP BY drug_name
)


/* ===========================================================================
   FINAL NORMALIZED OUTPUT
   =========================================================================== */

SELECT
    i.drug_order,
    i.drug_name,
    v.section,
    v.metric_order,
    v.variable,
    v.result

FROM ingredients i

LEFT JOIN drug_stats s
    ON s.drug_name = i.drug_name

LEFT JOIN patient_stats ps
    ON ps.drug_name = i.drug_name

LEFT JOIN interval_stats ints
    ON ints.drug_name = i.drug_name

LEFT JOIN unit_summary us
    ON us.drug_name = i.drug_name

LEFT JOIN drug_type_summary dts
    ON dts.drug_name = i.drug_name

LEFT JOIN route_summary rs
    ON rs.drug_name = i.drug_name


CROSS JOIN LATERAL (

    VALUES

    /* CORE ------------------------------------------------------------ */

    (
        'CORE',
        1,
        'DRUG_EXPOSURE records (n)',
        COALESCE(s.records_n, 0)::text
    ),

    (
        'CORE',
        2,
        'Patients with DRUG_EXPOSURE records (n)',
        COALESCE(s.patients_n, 0)::text
    ),

    (
        'CORE',
        3,
        'Drug exposure type concepts observed',
        COALESCE(dts.drug_types_observed, '[none]')
    ),

    (
        'CORE',
        4,
        'Start and end datetime both populated (%)',
        COALESCE(s.complete_datetime_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        5,
        'Chronologically valid intervals among complete intervals (%)',
        COALESCE(s.chronologically_valid_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        6,
        'Zero-duration intervals among complete intervals (%)',
        COALESCE(s.zero_duration_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        7,
        'Median positive record duration (minutes)',
        COALESCE(s.median_interval_minutes::text, 'N/A')
    ),

    (
        'CORE',
        8,
        'Adjacent intervals contiguous within ±1 minute (%)',
        COALESCE(ints.contiguous_within_1min_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        9,
        'Adjacent intervals overlapping (%)',
        COALESCE(ints.overlapping_intervals_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        10,
        'dose_unit_source_value populated (%)',
        COALESCE(s.dose_unit_populated_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        11,
        'Dose unit source values observed',
        COALESCE(us.dose_units_observed, '[none]')
    ),

    (
        'CORE',
        12,
        'quantity populated (%)',
        COALESCE(s.quantity_populated_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        13,
        'Candidate numeric rate: quantity + rate-like unit (%)',
        COALESCE(s.candidate_numeric_rate_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        14,
        'Standardized route populated (%)',
        COALESCE(s.standardized_route_populated_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        15,
        'Source indicates IV but standardized route is not IV (%)',
        COALESCE(s.iv_route_mismatch_pct::text || '%', 'N/A')
    ),

    (
        'CORE',
        16,
        'visit_detail_id populated (%)',
        COALESCE(s.visit_detail_populated_pct::text || '%', 'N/A')
    ),


    /* DIAGNOSTIC ------------------------------------------------------ */

    (
        'DIAGNOSTIC',
        17,
        'Distinct standardized drug_concept_ids used (n)',
        COALESCE(s.distinct_drug_concepts_n, 0)::text
    ),

    (
        'DIAGNOSTIC',
        18,
        'Median DRUG_EXPOSURE records per patient',
        COALESCE(
            ROUND(ps.median_records_per_patient::numeric, 1)::text,
            'N/A'
        )
    ),

    (
        'DIAGNOSTIC',
        19,
        'Dose-rate-like units among populated dose units (%)',
        COALESCE(s.dose_rate_unit_pct::text || '%', 'N/A')
    ),

    (
        'DIAGNOSTIC',
        20,
        'route_source_value populated (%)',
        COALESCE(s.route_source_populated_pct::text || '%', 'N/A')
    ),

    (
        'DIAGNOSTIC',
        21,
        'Observed source → standardized route mappings',
        COALESCE(rs.route_mappings_observed, '[none]')
    ),

    (
        'DIAGNOSTIC',
        22,
        'visit_occurrence_id populated (%)',
        COALESCE(s.visit_occurrence_populated_pct::text || '%', 'N/A')
    ),

    (
        'DIAGNOSTIC',
        23,
        'Consecutive interval pairs evaluated (n)',
        COALESCE(ints.consecutive_pairs_n, 0)::text
    )

) AS v (
    section,
    metric_order,
    variable,
    result
)

ORDER BY
    i.drug_order,
    v.metric_order;
