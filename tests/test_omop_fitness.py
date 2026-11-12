from omop_fitness import assess_omop_fit_for_purpose, evaluate_fitness, validate_required_columns


def test_validate_required_columns_reports_missing_values():
    present, missing = validate_required_columns(
        "person",
        ["person_id", "year_of_birth"],
        ["person_id", "gender_concept_id", "year_of_birth"],
    )

    assert present == ["person_id", "year_of_birth"]
    assert missing == ["gender_concept_id"]


def test_evaluate_fitness_scores_good_dataset():
    schema = {
        "person": ["person_id", "gender_concept_id", "year_of_birth"],
        "observation_period": ["observation_period_id", "person_id", "observation_period_start_date", "observation_period_end_date"],
        "condition_occurrence": ["condition_occurrence_id", "person_id", "condition_concept_id", "condition_start_date"],
        "drug_exposure": ["drug_exposure_id", "person_id", "drug_concept_id", "drug_exposure_start_date"],
        "measurement": ["measurement_id", "person_id", "measurement_concept_id", "measurement_date"],
    }

    report = evaluate_fitness(schema, "general")

    assert report.passed is True
    assert report.overall_score == 1.0
    assert set(report.table_scores) == set(schema)


def test_assess_omop_fit_for_purpose_flags_incomplete_schema():
    schema = {
        "person": ["person_id", "year_of_birth"],
        "observation_period": ["person_id", "observation_period_start_date"],
    }

    result = assess_omop_fit_for_purpose(schema, "general")

    assert result["passed"] is False
    assert result["overall_score"] < 1.0
    assert "gender_concept_id" in result["missing_columns"]["person"]
