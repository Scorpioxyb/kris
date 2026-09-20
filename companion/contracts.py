from __future__ import annotations

from datetime import date, datetime
from typing import Any
from uuid import UUID


class ContractError(ValueError):
    pass


def _object(payload: Any, name: str) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ContractError(f"{name} must be an object")
    return payload


def _required(payload: dict[str, Any], fields: tuple[str, ...]) -> None:
    missing = [field for field in fields if field not in payload]
    if missing:
        raise ContractError(f"missing required fields: {', '.join(missing)}")


def _uuid(value: Any, field: str) -> str:
    try:
        return str(UUID(str(value)))
    except (TypeError, ValueError, AttributeError) as exc:
        raise ContractError(f"{field} must be a UUID") from exc


def _datetime(value: Any, field: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError as exc:
        raise ContractError(f"{field} must be ISO-8601") from exc
    if parsed.tzinfo is None:
        raise ContractError(f"{field} must include a timezone")
    return parsed


def _date(value: Any, field: str) -> date:
    try:
        return date.fromisoformat(str(value))
    except ValueError as exc:
        raise ContractError(f"{field} must be YYYY-MM-DD") from exc


def validate_health_batch(raw: Any) -> dict[str, Any]:
    payload = _object(raw, "HealthBatch.v1")
    _required(payload, ("schema_version", "batch_id", "device_id", "created_at", "samples", "coverage"))
    if payload["schema_version"] != "HealthBatch.v1":
        raise ContractError("unsupported HealthBatch schema_version")
    payload["batch_id"] = _uuid(payload["batch_id"], "batch_id")
    _datetime(payload["created_at"], "created_at")
    if not isinstance(payload["device_id"], str) or not payload["device_id"]:
        raise ContractError("device_id must be a non-empty string")
    samples = payload["samples"]
    coverage = payload["coverage"]
    if not isinstance(samples, list) or len(samples) > 10_000:
        raise ContractError("samples must be an array with at most 10000 items")
    if not isinstance(coverage, list) or len(coverage) > 1_000:
        raise ContractError("coverage must be an array with at most 1000 items")
    allowed_metrics = {
        "sleep", "hrv_sdnn", "resting_heart_rate", "step_count", "active_energy",
        "basal_energy", "body_mass", "body_fat_percentage", "lean_body_mass", "bmi",
        "vo2_max", "workout",
    }
    seen: set[str] = set()
    for index, sample_raw in enumerate(samples):
        sample = _object(sample_raw, f"samples[{index}]")
        _required(sample, ("sample_uuid", "metric", "start_at", "end_at", "value", "unit", "source"))
        sample_uuid = str(sample["sample_uuid"])
        if not sample_uuid or len(sample_uuid) > 128:
            raise ContractError(f"samples[{index}].sample_uuid is invalid")
        if sample_uuid in seen:
            raise ContractError(f"duplicate sample_uuid in batch: {sample_uuid}")
        seen.add(sample_uuid)
        if sample["metric"] not in allowed_metrics:
            raise ContractError(f"samples[{index}].metric is unsupported")
        start = _datetime(sample["start_at"], f"samples[{index}].start_at")
        end = _datetime(sample["end_at"], f"samples[{index}].end_at")
        if end < start:
            raise ContractError(f"samples[{index}] ends before it starts")
        if not isinstance(sample["value"], (int, float)):
            raise ContractError(f"samples[{index}].value must be numeric")
    allowed_coverage = {"complete", "partial", "denied", "unavailable"}
    for index, item_raw in enumerate(coverage):
        item = _object(item_raw, f"coverage[{index}]")
        _required(item, ("date", "metric", "status"))
        _date(item["date"], f"coverage[{index}].date")
        if item["status"] not in allowed_coverage:
            raise ContractError(f"coverage[{index}].status is unsupported")
    return payload


def validate_training_plan(raw: Any) -> dict[str, Any]:
    payload = _object(raw, "TrainingPlan.v1")
    _required(payload, ("schema_version", "plan_id", "revision", "date", "title", "estimated_minutes", "safety_gates", "exercises"))
    if payload["schema_version"] != "TrainingPlan.v1":
        raise ContractError("unsupported TrainingPlan schema_version")
    payload["plan_id"] = _uuid(payload["plan_id"], "plan_id")
    _date(payload["date"], "date")
    if not isinstance(payload["revision"], int) or payload["revision"] < 1:
        raise ContractError("revision must be a positive integer")
    if not isinstance(payload["estimated_minutes"], int) or not 1 <= payload["estimated_minutes"] <= 300:
        raise ContractError("estimated_minutes must be between 1 and 300")
    if not isinstance(payload["safety_gates"], list) or not payload["safety_gates"]:
        raise ContractError("safety_gates must not be empty")
    exercises = payload["exercises"]
    if not isinstance(exercises, list) or not exercises or len(exercises) > 40:
        raise ContractError("exercises must contain 1 to 40 items")
    orders: set[int] = set()
    for index, exercise_raw in enumerate(exercises):
        exercise = _object(exercise_raw, f"exercises[{index}]")
        _required(exercise, ("exercise_id", "order", "name", "equipment_variant", "sets", "target_reps", "rest_seconds"))
        exercise["exercise_id"] = _uuid(exercise["exercise_id"], f"exercises[{index}].exercise_id")
        order = exercise["order"]
        if not isinstance(order, int) or order < 1 or order in orders:
            raise ContractError("exercise order must be unique positive integers")
        orders.add(order)
        if not isinstance(exercise["sets"], int) or not 1 <= exercise["sets"] <= 20:
            raise ContractError(f"exercises[{index}].sets is invalid")
        if not isinstance(exercise["target_reps"], int) or not 1 <= exercise["target_reps"] <= 200:
            raise ContractError(f"exercises[{index}].target_reps is invalid")
    return payload


def validate_training_session(raw: Any) -> dict[str, Any]:
    payload = _object(raw, "TrainingSession.v1")
    _required(payload, ("schema_version", "session_id", "plan_id", "plan_revision", "started_at", "ended_at", "status", "exercise_results", "feedback"))
    if payload["schema_version"] != "TrainingSession.v1":
        raise ContractError("unsupported TrainingSession schema_version")
    payload["session_id"] = _uuid(payload["session_id"], "session_id")
    payload["plan_id"] = _uuid(payload["plan_id"], "plan_id")
    start = _datetime(payload["started_at"], "started_at")
    end = _datetime(payload["ended_at"], "ended_at")
    if end < start:
        raise ContractError("ended_at must not be before started_at")
    if payload["status"] not in {"completed", "stopped_early", "cancelled"}:
        raise ContractError("unsupported session status")
    if not isinstance(payload["exercise_results"], list):
        raise ContractError("exercise_results must be an array")
    set_ids: set[str] = set()
    for exercise_index, result_raw in enumerate(payload["exercise_results"]):
        result = _object(result_raw, f"exercise_results[{exercise_index}]")
        _required(result, ("exercise_id", "name", "equipment_variant", "sets"))
        result["exercise_id"] = _uuid(result["exercise_id"], "exercise_id")
        if result.get("planned") is not None:
            planned = _object(result["planned"], f"exercise_results[{exercise_index}].planned")
            _required(planned, ("exercise_id", "name", "equipment_variant", "sets", "target_reps", "rest_seconds"))
            planned["exercise_id"] = _uuid(planned["exercise_id"], "planned.exercise_id")
            if not isinstance(planned["sets"], int) or not 1 <= planned["sets"] <= 20:
                raise ContractError("planned sets must be between 1 and 20")
            if not isinstance(planned["target_reps"], int) or not 0 <= planned["target_reps"] <= 500:
                raise ContractError("planned target_reps must be between 0 and 500")
        if not isinstance(result["sets"], list):
            raise ContractError("sets must be an array")
        for set_index, set_raw in enumerate(result["sets"]):
            item = _object(set_raw, f"sets[{set_index}]")
            _required(item, ("set_id", "set_number", "reps", "completed_at"))
            item["set_id"] = _uuid(item["set_id"], "set_id")
            if item["set_id"] in set_ids:
                raise ContractError(f"duplicate set_id: {item['set_id']}")
            set_ids.add(item["set_id"])
            _datetime(item["completed_at"], "completed_at")
            if not isinstance(item["reps"], int) or not 0 <= item["reps"] <= 500:
                raise ContractError("reps must be between 0 and 500")
    _object(payload["feedback"], "feedback")
    return payload
