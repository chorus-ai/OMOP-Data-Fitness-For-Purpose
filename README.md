# OMOP Data Fitness For Purpose

A practical framework and knowledge base for evaluating whether harmonized OMOP CDM data are suitable for specific clinical, analytical, and observational research use cases.

This repository includes a lightweight Python utility for assessing whether a proposed OMOP schema is fit for a target purpose. The library checks core table coverage against the required columns for common use cases and produces a summary score that highlights missing fields before analysis begins.

## Quick start

```bash
python -m pip install -e .
python - <<'PY'
from omop_fitness import assess_omop_fit_for_purpose

schema = {
    'person': ['person_id', 'gender_concept_id', 'year_of_birth'],
    'observation_period': ['observation_period_id', 'person_id', 'observation_period_start_date', 'observation_period_end_date'],
    'condition_occurrence': ['condition_occurrence_id', 'person_id', 'condition_concept_id', 'condition_start_date'],
    'drug_exposure': ['drug_exposure_id', 'person_id', 'drug_concept_id', 'drug_exposure_start_date'],
    'measurement': ['measurement_id', 'person_id', 'measurement_concept_id', 'measurement_date'],
}

print(assess_omop_fit_for_purpose(schema, 'general'))
PY
```

The repository is intentionally lightweight and intentionally focused on the fitness-for-purpose assessment itself rather than a full OMOP analytics stack.
