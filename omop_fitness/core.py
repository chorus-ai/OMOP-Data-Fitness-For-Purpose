from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Mapping


DEFAULT_USE_CASES = {
    "general": {
        "person": {"person_id", "gender_concept_id", "year_of_birth"},
        "observation_period": {"observation_period_id", "person_id", "observation_period_start_date", "observation_period_end_date"},
        "condition_occurrence": {"condition_occurrence_id", "person_id", "condition_concept_id", "condition_start_date"},
        "drug_exposure": {"drug_exposure_id", "person_id", "drug_concept_id", "drug_exposure_start_date"},
        "measurement": {"measurement_id", "person_id", "measurement_concept_id", "measurement_date"},
    },
    "transfusion": {
        "person": {"person_id", "gender_concept_id", "year_of_birth"},
        "procedure_occurrence": {"procedure_occurrence_id", "person_id", "procedure_concept_id", "procedure_date"},
        "condition_occurrence": {"condition_occurrence_id", "person_id", "condition_concept_id", "condition_start_date"},
    },
    "microbiology": {
        "person": {"person_id", "gender_concept_id", "year_of_birth"},
        "measurement": {"measurement_id", "person_id", "measurement_concept_id", "measurement_date", "value_as_number"},
        "specimen": {"specimen_id", "person_id", "specimen_concept_id", "specimen_date"},
    },
}


@dataclass(frozen=True)
class UseCaseRequirement:
    name: str
    required_tables: Mapping[str, set[str]]

    @classmethod
    def from_mapping(cls, name: str, required_tables: Mapping[str, Iterable[str]]) -> "UseCaseRequirement":
        return cls(name=name, required_tables={table: set(columns) for table, columns in required_tables.items()})


@dataclass
class FitnessReport:
    use_case: str
    table_scores: dict[str, float]
    overall_score: float
    missing_columns: dict[str, list[str]]
    passed: bool

    def to_dict(self) -> dict:
        return {
            "use_case": self.use_case,
            "table_scores": self.table_scores,
            "overall_score": self.overall_score,
            "missing_columns": self.missing_columns,
            "passed": self.passed,
        }


def validate_required_columns(
    table_name: str,
    available_columns: Iterable[str],
    required_columns: Iterable[str],
) -> tuple[list[str], list[str]]:
    available = {str(column).strip() for column in available_columns}
    required = {str(column).strip() for column in required_columns}
    present = sorted(required & available)
    missing = sorted(required - available)
    return present, missing


def assess_table(
    table_name: str,
    available_columns: Iterable[str],
    required_columns: Iterable[str],
) -> tuple[float, list[str]]:
    _, missing = validate_required_columns(table_name, available_columns, required_columns)
    if not required_columns:
        return 1.0, []
    required = set(required_columns)
    coverage = 1.0 - (len(missing) / len(required))
    return max(0.0, min(1.0, coverage)), missing


def evaluate_fitness(
    schema: Mapping[str, Iterable[str]],
    use_case: str | Mapping[str, Iterable[str]] = "general",
) -> FitnessReport:
    if isinstance(use_case, str):
        requirement_map = DEFAULT_USE_CASES.get(use_case.lower(), DEFAULT_USE_CASES["general"])
    else:
        requirement_map = {table: set(columns) for table, columns in use_case.items()}

    table_scores: dict[str, float] = {}
    missing_columns: dict[str, list[str]] = {}
    total_score = 0.0
    total_required = 0

    for table_name, required_columns in requirement_map.items():
        available_columns = schema.get(table_name, [])
        score, missing = assess_table(table_name, available_columns, required_columns)
        table_scores[table_name] = score
        missing_columns[table_name] = missing
        total_score += score * len(required_columns)
        total_required += len(required_columns)

    if total_required == 0:
        overall_score = 1.0
    else:
        overall_score = total_score / total_required

    passed = overall_score >= 0.80
    return FitnessReport(
        use_case=(use_case if isinstance(use_case, str) else "custom"),
        table_scores=table_scores,
        overall_score=round(overall_score, 3),
        missing_columns=missing_columns,
        passed=passed,
    )


def assess_omop_fit_for_purpose(
    schema: Mapping[str, Iterable[str]],
    use_case: str | Mapping[str, Iterable[str]] = "general",
) -> dict:
    report = evaluate_fitness(schema, use_case)
    return report.to_dict()
