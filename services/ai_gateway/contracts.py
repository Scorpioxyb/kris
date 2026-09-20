from __future__ import annotations

import json
import math
import re
from copy import deepcopy
from datetime import date, datetime
from typing import Any
from uuid import UUID


class ContractError(ValueError):
    pass


class RequestContractError(ContractError):
    pass


class ProviderContractError(ContractError):
    pass


REQUEST_SCHEMA = "KrisAIPlanRequest.v1"
CONTEXT_SCHEMA = "AIRedactedPlanContext.v1"
RESPONSE_SCHEMA = "AIPlanResponse.v1"
REQUEST_SCHEMA_V2 = "KrisAIPlanRequest.v2"
CONTEXT_SCHEMA_V2 = "TrainingContext.v2"
PROVIDER_RESPONSE_SCHEMA_V2 = "AIRecommendationDraft.v2"
RESPONSE_SCHEMA_V2 = "AIRecommendation.v2"
MAX_REQUEST_BYTES = 64 * 1024

_EVIDENCE_ID = re.compile(r"^ev_[A-Za-z0-9_-]{1,48}$")
_RESTRICTION_ID = re.compile(r"^sr_[A-Za-z0-9_-]{1,48}$")

_FORBIDDEN_CONTEXT_KEYS = {
    "anchor",
    "device_id",
    "end_at",
    "healthkit_uuid",
    "metadata",
    "raw_samples",
    "sample_uuid",
    "samples",
    "source",
    "start_at",
}

_FORBIDDEN_NORMALIZED_KEYS = {
    key.replace("_", "").replace("-", "").lower() for key in _FORBIDDEN_CONTEXT_KEYS
} | {
    "deviceidentifier",
    "healthkitsampleid",
    "rawhealthsamples",
    "sourcename",
}


def _object(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{name} must be an object")
    return value


def _strict_keys(value: dict[str, Any], *, required: set[str], optional: set[str], name: str) -> None:
    missing = sorted(required - value.keys())
    extra = sorted(value.keys() - required - optional)
    if missing:
        raise ContractError(f"{name} is missing: {', '.join(missing)}")
    if extra:
        raise ContractError(f"{name} contains unsupported fields: {', '.join(extra)}")


def _bounded_string(value: Any, field: str, *, minimum: int = 0, maximum: int) -> str:
    if not isinstance(value, str) or not minimum <= len(value.strip()) <= maximum:
        raise ContractError(f"{field} length is invalid")
    return value


def _aware_datetime(value: Any, field: str) -> None:
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError as exc:
        raise ContractError(f"{field} must be ISO-8601") from exc
    if parsed.tzinfo is None:
        raise ContractError(f"{field} must include a timezone")


def _calendar_date(value: Any, field: str) -> None:
    try:
        date.fromisoformat(str(value))
    except ValueError as exc:
        raise ContractError(f"{field} must be YYYY-MM-DD") from exc


def _uuid(value: Any, field: str) -> str:
    try:
        return str(UUID(str(value)))
    except (TypeError, ValueError, AttributeError) as exc:
        raise ContractError(f"{field} must be a UUID") from exc


def _scan_forbidden_keys(value: Any, path: str = "context") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized_key = str(key).replace("_", "").replace("-", "").lower()
            if normalized_key in _FORBIDDEN_NORMALIZED_KEYS:
                raise ContractError(f"{path}.{key} is not allowed in AI context")
            _scan_forbidden_keys(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _scan_forbidden_keys(child, f"{path}[{index}]")


def validate_plan_request(raw: Any) -> dict[str, Any]:
    payload = _object(deepcopy(raw), REQUEST_SCHEMA)
    if len(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()) > MAX_REQUEST_BYTES:
        raise ContractError("request exceeds the 64 KiB context limit")
    _strict_keys(
        payload,
        required={"schema_version", "client_request_id", "context"},
        optional=set(),
        name=REQUEST_SCHEMA,
    )
    if payload["schema_version"] != REQUEST_SCHEMA:
        raise ContractError("unsupported request schema_version")
    payload["client_request_id"] = _uuid(payload["client_request_id"], "client_request_id")
    context = _object(payload["context"], "context")
    _scan_forbidden_keys(context)
    _strict_keys(
        context,
        required={
            "schema_version", "feature", "locale", "generated_at", "user_input",
            "local_decision", "recent_confirmed_training", "progression_notes", "data_gaps",
        },
        optional={"readiness", "current_plan"},
        name="context",
    )
    if context["schema_version"] != CONTEXT_SCHEMA or context["feature"] != "training_plan_candidate":
        raise ContractError("unsupported AI context schema or feature")
    _bounded_string(context["locale"], "context.locale", minimum=2, maximum=16)
    _aware_datetime(context["generated_at"], "context.generated_at")
    _validate_user_input(_object(context["user_input"], "context.user_input"))
    _validate_local_decision(_object(context["local_decision"], "context.local_decision"))
    if context.get("readiness") is not None:
        _validate_readiness(_object(context["readiness"], "context.readiness"))
    _validate_recent_training(context["recent_confirmed_training"])
    if context.get("current_plan") is not None:
        _validate_current_plan(_object(context["current_plan"], "context.current_plan"))
    _string_list(context["progression_notes"], "context.progression_notes", maximum_items=12, item_maximum=500)
    _string_list(context["data_gaps"], "context.data_gaps", maximum_items=16, item_maximum=500)
    return payload


def _validate_user_input(value: dict[str, Any]) -> None:
    _strict_keys(
        value,
        required={"date", "objective", "available_minutes", "equipment", "notes", "symptoms"},
        optional=set(),
        name="context.user_input",
    )
    _calendar_date(value["date"], "context.user_input.date")
    _bounded_string(value["objective"], "context.user_input.objective", minimum=1, maximum=300)
    _bounded_string(value["equipment"], "context.user_input.equipment", minimum=1, maximum=300)
    _bounded_string(value["notes"], "context.user_input.notes", maximum=1000)
    if not isinstance(value["available_minutes"], int) or not 20 <= value["available_minutes"] <= 120:
        raise ContractError("context.user_input.available_minutes must be between 20 and 120")
    if value["symptoms"] not in {"notReported", "noneReported", "limitingDiscomfort", "emergencyReported"}:
        raise ContractError("context.user_input.symptoms is unsupported")


def _validate_local_decision(value: dict[str, Any]) -> None:
    _strict_keys(
        value,
        required={"action", "title", "summary", "evidence", "rollback_condition", "rule_version"},
        optional=set(),
        name="context.local_decision",
    )
    if value["action"] not in {"needsPlan", "needsAssessment", "maintain", "reduce", "recovery", "stop"}:
        raise ContractError("context.local_decision.action is unsupported")
    for field in ("title", "summary", "rollback_condition", "rule_version"):
        _bounded_string(value[field], f"context.local_decision.{field}", minimum=1, maximum=500)
    _string_list(value["evidence"], "context.local_decision.evidence", maximum_items=20, item_maximum=80)


def _validate_readiness(value: dict[str, Any]) -> None:
    _strict_keys(
        value,
        required={"state", "confidence", "safety_gate"},
        optional={"score"},
        name="context.readiness",
    )
    score = value.get("score")
    if score is not None and (not isinstance(score, (int, float)) or not 0 <= score <= 100):
        raise ContractError("context.readiness.score must be null or between 0 and 100")
    for field in ("state", "confidence", "safety_gate"):
        _bounded_string(value[field], f"context.readiness.{field}", minimum=1, maximum=80)


def _validate_recent_training(value: Any) -> None:
    if not isinstance(value, list) or len(value) > 12:
        raise ContractError("context.recent_confirmed_training must have at most 12 items")
    for index, raw in enumerate(value):
        item = _object(raw, f"context.recent_confirmed_training[{index}]")
        _strict_keys(
            item,
            required={"date", "title", "status"},
            optional={"duration_minutes", "completed_set_count"},
            name=f"context.recent_confirmed_training[{index}]",
        )
        _calendar_date(item["date"], f"context.recent_confirmed_training[{index}].date")
        _bounded_string(item["title"], f"context.recent_confirmed_training[{index}].title", minimum=1, maximum=120)
        _bounded_string(item["status"], f"context.recent_confirmed_training[{index}].status", minimum=1, maximum=40)
        duration = item.get("duration_minutes")
        if duration is not None and (not isinstance(duration, int) or not 0 <= duration <= 1_440):
            raise ContractError(f"context.recent_confirmed_training[{index}].duration_minutes is invalid")
        set_count = item.get("completed_set_count")
        if set_count is not None and (not isinstance(set_count, int) or not 0 <= set_count <= 200):
            raise ContractError(f"context.recent_confirmed_training[{index}].completed_set_count is invalid")


def _validate_current_plan(value: dict[str, Any]) -> None:
    _strict_keys(
        value,
        required={"title", "date", "revision", "exercise_prescriptions"},
        optional=set(),
        name="context.current_plan",
    )
    _bounded_string(value["title"], "context.current_plan.title", minimum=1, maximum=120)
    _calendar_date(value["date"], "context.current_plan.date")
    if not isinstance(value["revision"], int) or value["revision"] < 1:
        raise ContractError("context.current_plan.revision must be positive")
    _string_list(value["exercise_prescriptions"], "context.current_plan.exercise_prescriptions", maximum_items=20, item_maximum=500)


def _string_list(value: Any, field: str, *, maximum_items: int, item_maximum: int) -> None:
    if not isinstance(value, list) or len(value) > maximum_items:
        raise ContractError(f"{field} has too many items")
    for item in value:
        _bounded_string(item, field, maximum=item_maximum)


def validate_plan_response(raw: Any, *, available_minutes: int) -> dict[str, Any]:
    payload = _object(deepcopy(raw), RESPONSE_SCHEMA)
    _strict_keys(
        payload,
        required={"schema_version", "rationale", "cautions", "plan"},
        optional=set(),
        name=RESPONSE_SCHEMA,
    )
    if payload["schema_version"] != RESPONSE_SCHEMA:
        raise ContractError("unsupported response schema_version")
    _bounded_string(payload["rationale"], "rationale", minimum=1, maximum=1000)
    _string_list(payload["cautions"], "cautions", maximum_items=12, item_maximum=500)
    plan = _object(payload["plan"], "plan")
    _strict_keys(
        plan,
        required={"title", "estimated_minutes", "goal", "safety_gates", "exercises"},
        optional=set(),
        name="plan",
    )
    _bounded_string(plan["title"], "plan.title", minimum=1, maximum=120)
    _bounded_string(plan["goal"], "plan.goal", minimum=1, maximum=500)
    if not isinstance(plan["estimated_minutes"], int) or not 10 <= plan["estimated_minutes"] <= min(120, available_minutes):
        raise ContractError("plan.estimated_minutes exceeds the accepted range")
    _string_list(plan["safety_gates"], "plan.safety_gates", maximum_items=12, item_maximum=500)
    if not plan["safety_gates"]:
        raise ContractError("plan.safety_gates must not be empty")
    exercises = plan["exercises"]
    if not isinstance(exercises, list) or not 1 <= len(exercises) <= 12:
        raise ContractError("plan.exercises must contain 1 to 12 items")
    for index, raw in enumerate(exercises):
        exercise = _object(raw, f"plan.exercises[{index}]")
        _strict_keys(
            exercise,
            required={"name", "equipment_variant", "target_weight_kg", "sets", "target_reps", "rest_seconds", "notes", "alternative"},
            optional=set(),
            name=f"plan.exercises[{index}]",
        )
        _bounded_string(exercise["name"], f"plan.exercises[{index}].name", minimum=1, maximum=100)
        _bounded_string(exercise["equipment_variant"], f"plan.exercises[{index}].equipment_variant", minimum=1, maximum=120)
        weight = exercise["target_weight_kg"]
        if weight is not None and (not isinstance(weight, (int, float)) or not 0 <= weight <= 500):
            raise ContractError(f"plan.exercises[{index}].target_weight_kg is invalid")
        if not isinstance(exercise["sets"], int) or not 1 <= exercise["sets"] <= 10:
            raise ContractError(f"plan.exercises[{index}].sets is invalid")
        if not isinstance(exercise["target_reps"], int) or not 1 <= exercise["target_reps"] <= 50:
            raise ContractError(f"plan.exercises[{index}].target_reps is invalid")
        if not isinstance(exercise["rest_seconds"], int) or not 0 <= exercise["rest_seconds"] <= 600:
            raise ContractError(f"plan.exercises[{index}].rest_seconds is invalid")
        _string_list(exercise["notes"], f"plan.exercises[{index}].notes", maximum_items=8, item_maximum=300)
        if exercise["alternative"] is not None:
            _bounded_string(exercise["alternative"], f"plan.exercises[{index}].alternative", maximum=200)
    return payload


def validate_recommendation_request(raw: Any) -> dict[str, Any]:
    try:
        return _validate_recommendation_request(raw)
    except RequestContractError:
        raise
    except ContractError as exc:
        raise RequestContractError(str(exc)) from exc


def _validate_recommendation_request(raw: Any) -> dict[str, Any]:
    payload = _object(deepcopy(raw), REQUEST_SCHEMA_V2)
    if len(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()) > MAX_REQUEST_BYTES:
        raise RequestContractError("request exceeds the 64 KiB context limit")
    _strict_keys(
        payload,
        required={"schema_version", "client_request_id", "context"},
        optional=set(),
        name=REQUEST_SCHEMA_V2,
    )
    if payload["schema_version"] != REQUEST_SCHEMA_V2:
        raise RequestContractError("unsupported request schema_version")
    payload["client_request_id"] = _uuid(payload["client_request_id"], "client_request_id")
    context = _object(payload["context"], "context")
    _scan_forbidden_keys(context)
    _scan_v2_score_fields(context)
    _strict_keys(
        context,
        required={
            "schema_version", "context_id", "feature", "locale", "generated_at", "expires_at",
            "intent", "objective_health", "subjective_user", "training_history", "progression",
            "safety", "current_plan", "evidence", "data_gaps",
        },
        optional=set(),
        name="context",
    )
    if context["schema_version"] != CONTEXT_SCHEMA_V2 or context["feature"] != "training_recommendation":
        raise RequestContractError("unsupported V2 context schema or feature")
    context["context_id"] = _uuid(context["context_id"], "context.context_id")
    _bounded_string(context["locale"], "context.locale", minimum=2, maximum=16)
    generated_at = _parsed_datetime(context["generated_at"], "context.generated_at")
    expires_at = _parsed_datetime(context["expires_at"], "context.expires_at")
    if expires_at <= generated_at:
        raise RequestContractError("context.expires_at must be later than generated_at")

    _validate_v2_intent(_object(context["intent"], "context.intent"))
    evidence_categories = _validate_v2_evidence(context["evidence"])
    _validate_v2_evidence_section(
        _object(context["objective_health"], "context.objective_health"),
        "context.objective_health", evidence_categories,
        allowed_categories={"objective_measurement", "missing_signal"}, timestamp_field="as_of",
    )
    _validate_v2_evidence_section(
        _object(context["subjective_user"], "context.subjective_user"),
        "context.subjective_user", evidence_categories,
        allowed_categories={"user_reported_fact", "missing_signal"}, timestamp_field="reported_at",
    )
    _validate_v2_training_history(
        _object(context["training_history"], "context.training_history"), evidence_categories,
    )
    _validate_v2_progression(_object(context["progression"], "context.progression"), evidence_categories)
    _validate_v2_safety(_object(context["safety"], "context.safety"), evidence_categories)
    if context["current_plan"] is not None:
        _validate_v2_current_plan(_object(context["current_plan"], "context.current_plan"))
    _validate_v2_data_gaps(context["data_gaps"])
    return payload


def validate_recommendation_response(
    raw: Any,
    *,
    context: dict[str, Any],
) -> dict[str, Any]:
    try:
        return _validate_recommendation_response(raw, context=context)
    except ProviderContractError:
        raise
    except ContractError as exc:
        raise ProviderContractError(str(exc)) from exc


def _validate_recommendation_response(raw: Any, *, context: dict[str, Any]) -> dict[str, Any]:
    payload = _object(deepcopy(raw), PROVIDER_RESPONSE_SCHEMA_V2)
    _scan_ai_restriction_fields(payload)
    _strict_keys(
        payload,
        required={
            "schema_version", "kind", "recommendation", "reasons", "evidence_ids", "confidence",
            "uncertainties", "optional_adjustment", "alternatives", "safety_considerations",
            "acknowledged_restriction_ids", "user_confirmation_required",
        },
        optional=set(),
        name=PROVIDER_RESPONSE_SCHEMA_V2,
    )
    if payload["schema_version"] != PROVIDER_RESPONSE_SCHEMA_V2:
        raise ProviderContractError("unsupported provider response schema_version")
    valid_kinds = {
        "create_plan", "revise_plan", "replace_exercise", "adapt_equipment", "shorten_plan",
        "no_change", "decline_unsafe_request",
    }
    if payload["kind"] not in valid_kinds:
        raise ProviderContractError("recommendation kind is unsupported")
    requested_kind = context["intent"]["kind"]
    allowed_response_kinds = {"no_change", "decline_unsafe_request"}
    if requested_kind != "explain_recommendation":
        allowed_response_kinds.add(requested_kind)
    if payload["kind"] not in allowed_response_kinds:
        raise ProviderContractError("recommendation kind does not match the requested intent")
    _validate_v2_recommendation(
        _object(payload["recommendation"], "recommendation"),
        kind=payload["kind"], available_minutes=context["intent"]["available_minutes"],
    )
    known_evidence = {item["evidence_id"] for item in context["evidence"]}
    top_evidence = set(_identifier_list(
        payload["evidence_ids"], "evidence_ids", pattern=_EVIDENCE_ID, maximum_items=32,
    ))
    if not top_evidence.issubset(known_evidence):
        raise ProviderContractError("recommendation references unknown evidence")
    reasons = payload["reasons"]
    if not isinstance(reasons, list) or not 1 <= len(reasons) <= 12:
        raise ProviderContractError("reasons must contain 1 to 12 items")
    for index, raw_reason in enumerate(reasons):
        reason = _object(raw_reason, f"reasons[{index}]")
        _strict_keys(
            reason, required={"code", "explanation", "evidence_ids"}, optional=set(),
            name=f"reasons[{index}]",
        )
        _bounded_string(reason["code"], f"reasons[{index}].code", minimum=1, maximum=80)
        _bounded_string(reason["explanation"], f"reasons[{index}].explanation", minimum=1, maximum=500)
        refs = set(_identifier_list(
            reason["evidence_ids"], f"reasons[{index}].evidence_ids",
            pattern=_EVIDENCE_ID, maximum_items=12,
        ))
        if not refs.issubset(known_evidence) or not refs.issubset(top_evidence):
            raise ProviderContractError("reason evidence must exist in the request and top-level evidence_ids")
    if payload["confidence"] not in {"low", "medium", "high"}:
        raise ProviderContractError("confidence must be low, medium, or high")
    _validate_v2_uncertainties(payload["uncertainties"], known_evidence, top_evidence)
    if payload["optional_adjustment"] is not None:
        _validate_v2_adjustment(
            _object(payload["optional_adjustment"], "optional_adjustment"),
            context["intent"]["available_minutes"], known_evidence, top_evidence,
        )
    _validate_v2_alternatives(
        payload["alternatives"], context["intent"]["available_minutes"], known_evidence, top_evidence,
    )
    restriction_ids = {item["restriction_id"] for item in context["safety"]["restrictions"]}
    _validate_v2_safety_considerations(
        payload["safety_considerations"], known_evidence, top_evidence, restriction_ids,
    )
    acknowledged = set(_identifier_list(
        payload["acknowledged_restriction_ids"], "acknowledged_restriction_ids",
        pattern=_RESTRICTION_ID, maximum_items=20,
    ))
    if not acknowledged.issubset(restriction_ids):
        raise ProviderContractError("acknowledged_restriction_ids contains an unknown restriction")
    required_acknowledgements = {
        item["restriction_id"] for item in context["safety"]["restrictions"]
        if item["requires_acknowledgement"]
    }
    if not required_acknowledgements.issubset(acknowledged):
        raise ProviderContractError("provider did not acknowledge every required safety restriction")
    if payload["user_confirmation_required"] is not True:
        raise ProviderContractError("user_confirmation_required must be true")
    return payload


def _parsed_datetime(value: Any, field: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError as exc:
        raise ContractError(f"{field} must be ISO-8601") from exc
    if parsed.tzinfo is None:
        raise ContractError(f"{field} must include a timezone")
    return parsed


def _strict_integer(value: Any, field: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ContractError(f"{field} is invalid")
    return value


def _strict_number(value: Any, field: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ContractError(f"{field} is invalid")
    parsed = float(value)
    if not math.isfinite(parsed) or not minimum <= parsed <= maximum:
        raise ContractError(f"{field} is invalid")
    return parsed


def _identifier_list(
    value: Any, field: str, *, pattern: re.Pattern[str], maximum_items: int,
) -> list[str]:
    if not isinstance(value, list) or len(value) > maximum_items:
        raise ContractError(f"{field} has too many items")
    result: list[str] = []
    for item in value:
        if not isinstance(item, str) or pattern.fullmatch(item) is None:
            raise ContractError(f"{field} contains an invalid identifier")
        result.append(item)
    if len(set(result)) != len(result):
        raise ContractError(f"{field} contains duplicate identifiers")
    return result


def _scan_v2_score_fields(value: Any, path: str = "context") -> None:
    forbidden = {
        "readiness", "readinessscore", "recovery", "recoveryscore",
        "statusscore", "bodyscore", "bodystatescore",
    }
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = str(key).replace("_", "").replace("-", "").lower()
            if normalized in forbidden:
                raise RequestContractError(f"{path}.{key} is not allowed in TrainingContext.v2")
            normalized_child = (
                child.replace("_", "").replace("-", "").lower()
                if isinstance(child, str) else None
            )
            if key in {"metric", "signal", "field"} and normalized_child in forbidden:
                raise RequestContractError(f"{path}.{key} cannot contain a derived body-state score")
            _scan_v2_score_fields(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _scan_v2_score_fields(child, f"{path}[{index}]")


def _scan_ai_restriction_fields(value: Any, path: str = "provider_response") -> None:
    forbidden = {"safetygates", "safetyrestrictions", "restrictions"}
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = str(key).replace("_", "").replace("-", "").lower()
            if normalized in forbidden:
                raise ProviderContractError(f"{path}.{key} is not allowed in AI output")
            _scan_ai_restriction_fields(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _scan_ai_restriction_fields(child, f"{path}[{index}]")


def _validate_v2_intent(value: dict[str, Any]) -> None:
    _strict_keys(
        value,
        required={
            "intent_id", "kind", "requested_date", "objective", "available_minutes", "equipment",
            "target_plan_revision", "target_exercise_ref", "requested_changes", "free_text",
        },
        optional=set(), name="context.intent",
    )
    value["intent_id"] = _uuid(value["intent_id"], "context.intent.intent_id")
    if value["kind"] not in {
        "create_plan", "revise_plan", "replace_exercise", "adapt_equipment", "shorten_plan",
        "explain_recommendation",
    }:
        raise ContractError("context.intent.kind is unsupported")
    _calendar_date(value["requested_date"], "context.intent.requested_date")
    _bounded_string(value["objective"], "context.intent.objective", minimum=1, maximum=300)
    _strict_integer(value["available_minutes"], "context.intent.available_minutes", 10, 180)
    equipment = value["equipment"]
    if not isinstance(equipment, list) or not 1 <= len(equipment) <= 24:
        raise ContractError("context.intent.equipment must contain 1 to 24 items")
    for index, raw in enumerate(equipment):
        item = _object(raw, f"context.intent.equipment[{index}]")
        _strict_keys(item, required={"name", "status"}, optional=set(), name=f"context.intent.equipment[{index}]")
        _bounded_string(item["name"], f"context.intent.equipment[{index}].name", minimum=1, maximum=120)
        if item["status"] not in {"available", "unavailable", "unknown"}:
            raise ContractError(f"context.intent.equipment[{index}].status is unsupported")
    revision = value["target_plan_revision"]
    if revision is not None:
        _strict_integer(revision, "context.intent.target_plan_revision", 1, 1_000_000)
    exercise_ref = value["target_exercise_ref"]
    if exercise_ref is not None:
        _bounded_string(exercise_ref, "context.intent.target_exercise_ref", minimum=1, maximum=80)
    _string_list(value["requested_changes"], "context.intent.requested_changes", maximum_items=12, item_maximum=300)
    if value["free_text"] is not None:
        _bounded_string(value["free_text"], "context.intent.free_text", maximum=1000)


def _validate_v2_evidence(value: Any) -> dict[str, str]:
    if not isinstance(value, list) or not 1 <= len(value) <= 64:
        raise ContractError("context.evidence must contain 1 to 64 items")
    categories: dict[str, str] = {}
    valid_categories = {
        "objective_measurement", "user_reported_fact", "confirmed_training_result",
        "device_observation", "deterministic_assessment", "missing_signal",
    }
    valid_origins = {
        "healthkit_aggregate", "user_report", "kris_session", "healthkit_workout",
        "local_rule", "current_plan",
    }
    allowed_origins = {
        "objective_measurement": {"healthkit_aggregate"},
        "user_reported_fact": {"user_report"},
        "confirmed_training_result": {"kris_session"},
        "device_observation": {"healthkit_workout"},
        "deterministic_assessment": {"local_rule", "current_plan"},
        "missing_signal": {"healthkit_aggregate", "user_report", "kris_session", "healthkit_workout", "local_rule"},
    }
    for index, raw in enumerate(value):
        item = _object(raw, f"context.evidence[{index}]")
        _strict_keys(
            item,
            required={"evidence_id", "category", "origin", "observed_at", "quality", "payload"},
            optional=set(), name=f"context.evidence[{index}]",
        )
        evidence_id = _bounded_string(item["evidence_id"], f"context.evidence[{index}].evidence_id", minimum=1, maximum=51)
        if _EVIDENCE_ID.fullmatch(evidence_id) is None or evidence_id in categories:
            raise ContractError("context.evidence contains an invalid or duplicate evidence_id")
        if item["category"] not in valid_categories or item["origin"] not in valid_origins:
            raise ContractError(f"context.evidence[{index}] category or origin is unsupported")
        if item["origin"] not in allowed_origins[item["category"]]:
            raise ContractError(f"context.evidence[{index}] category and origin do not match")
        if item["observed_at"] is not None:
            _aware_datetime(item["observed_at"], f"context.evidence[{index}].observed_at")
        if item["quality"] not in {"confirmed", "partial", "stale", "missing"}:
            raise ContractError(f"context.evidence[{index}].quality is unsupported")
        _validate_v2_evidence_payload(
            _object(item["payload"], f"context.evidence[{index}].payload"),
            f"context.evidence[{index}].payload",
        )
        categories[evidence_id] = item["category"]
    for index, item in enumerate(value):
        payload = item["payload"]
        if payload["type"] == "rule_result":
            refs = _identifier_list(
                payload["input_evidence_ids"], f"context.evidence[{index}].payload.input_evidence_ids",
                pattern=_EVIDENCE_ID, maximum_items=20,
            )
            if not set(refs).issubset(categories):
                raise ContractError("rule_result references unknown evidence")
    return categories


def _validate_v2_evidence_payload(value: dict[str, Any], name: str) -> None:
    payload_type = value.get("type")
    if payload_type == "quantity":
        _strict_keys(value, required={"type", "metric", "value", "unit"}, optional=set(), name=name)
        _bounded_string(value["metric"], f"{name}.metric", minimum=1, maximum=80)
        _strict_number(value["value"], f"{name}.value", -100_000, 100_000)
        if value["unit"] not in {"minute", "millisecond", "bpm", "count", "kg", "kcal", "percent"}:
            raise ContractError(f"{name}.unit is unsupported")
    elif payload_type == "categorical":
        _strict_keys(value, required={"type", "metric", "value"}, optional=set(), name=name)
        _bounded_string(value["metric"], f"{name}.metric", minimum=1, maximum=80)
        _bounded_string(value["value"], f"{name}.value", minimum=1, maximum=120)
    elif payload_type == "set_performance":
        _strict_keys(
            value, required={"type", "exercise", "equipment_variant", "weight_kg", "reps"},
            optional=set(), name=name,
        )
        _bounded_string(value["exercise"], f"{name}.exercise", minimum=1, maximum=100)
        _bounded_string(value["equipment_variant"], f"{name}.equipment_variant", minimum=1, maximum=120)
        if value["weight_kg"] is not None:
            _strict_number(value["weight_kg"], f"{name}.weight_kg", 0, 1_000)
        reps = value["reps"]
        if not isinstance(reps, list) or not 1 <= len(reps) <= 20:
            raise ContractError(f"{name}.reps must contain 1 to 20 items")
        for index, item in enumerate(reps):
            _strict_integer(item, f"{name}.reps[{index}]", 0, 500)
    elif payload_type == "missing_signal":
        _strict_keys(value, required={"type", "signal", "reason"}, optional=set(), name=name)
        _bounded_string(value["signal"], f"{name}.signal", minimum=1, maximum=80)
        _bounded_string(value["reason"], f"{name}.reason", minimum=1, maximum=300)
    elif payload_type == "rule_result":
        _strict_keys(
            value, required={"type", "rule_code", "outcome", "input_evidence_ids"},
            optional=set(), name=name,
        )
        _bounded_string(value["rule_code"], f"{name}.rule_code", minimum=1, maximum=100)
        _bounded_string(value["outcome"], f"{name}.outcome", minimum=1, maximum=120)
    else:
        raise ContractError(f"{name}.type is unsupported")


def _validate_v2_evidence_section(
    value: dict[str, Any], name: str, categories: dict[str, str],
    *, allowed_categories: set[str], timestamp_field: str,
) -> None:
    _strict_keys(value, required={timestamp_field, "evidence_ids"}, optional=set(), name=name)
    _aware_datetime(value[timestamp_field], f"{name}.{timestamp_field}")
    refs = _identifier_list(value["evidence_ids"], f"{name}.evidence_ids", pattern=_EVIDENCE_ID, maximum_items=32)
    for evidence_id in refs:
        if evidence_id not in categories or categories[evidence_id] not in allowed_categories:
            raise ContractError(f"{name} references missing or incompatible evidence")


def _validate_v2_training_history(value: dict[str, Any], categories: dict[str, str]) -> None:
    _strict_keys(
        value, required={"confirmed_session_evidence_ids", "observed_workout_evidence_ids"},
        optional=set(), name="context.training_history",
    )
    mappings = (
        ("confirmed_session_evidence_ids", "confirmed_training_result"),
        ("observed_workout_evidence_ids", "device_observation"),
    )
    for field, category in mappings:
        refs = _identifier_list(value[field], f"context.training_history.{field}", pattern=_EVIDENCE_ID, maximum_items=24)
        if any(categories.get(item) != category for item in refs):
            raise ContractError(f"context.training_history.{field} references incompatible evidence")


def _validate_v2_progression(value: dict[str, Any], categories: dict[str, str]) -> None:
    _strict_keys(value, required={"rule_version", "exercise_decisions"}, optional=set(), name="context.progression")
    _bounded_string(value["rule_version"], "context.progression.rule_version", minimum=1, maximum=100)
    decisions = value["exercise_decisions"]
    if not isinstance(decisions, list) or len(decisions) > 24:
        raise ContractError("context.progression.exercise_decisions has too many items")
    for index, raw in enumerate(decisions):
        item = _object(raw, f"context.progression.exercise_decisions[{index}]")
        _strict_keys(
            item,
            required={"exercise_ref", "disposition", "allowed_adjustment", "evidence_ids", "rollback_condition"},
            optional=set(), name=f"context.progression.exercise_decisions[{index}]",
        )
        _bounded_string(item["exercise_ref"], f"context.progression.exercise_decisions[{index}].exercise_ref", minimum=1, maximum=80)
        if item["disposition"] not in {"maintain", "increase_allowed", "hold", "reduce", "blocked", "insufficient_data"}:
            raise ContractError("progression disposition is unsupported")
        if item["allowed_adjustment"] is not None:
            adjustment = _object(item["allowed_adjustment"], "allowed_adjustment")
            _strict_keys(adjustment, required={"type", "maximum_delta_kg"}, optional=set(), name="allowed_adjustment")
            if adjustment["type"] != "load_delta_kg":
                raise ContractError("allowed_adjustment.type is unsupported")
            _strict_number(adjustment["maximum_delta_kg"], "allowed_adjustment.maximum_delta_kg", 0, 100)
        refs = _identifier_list(item["evidence_ids"], "progression evidence_ids", pattern=_EVIDENCE_ID, maximum_items=20)
        if not set(refs).issubset(categories):
            raise ContractError("progression references unknown evidence")
        _bounded_string(item["rollback_condition"], "progression rollback_condition", minimum=1, maximum=500)


def _validate_v2_safety(value: dict[str, Any], categories: dict[str, str]) -> None:
    _strict_keys(
        value, required={"rule_version", "disposition", "evaluated_at", "expires_at", "restrictions"},
        optional=set(), name="context.safety",
    )
    _bounded_string(value["rule_version"], "context.safety.rule_version", minimum=1, maximum=100)
    if value["disposition"] not in {"allow", "constrain", "needs_user_input", "block"}:
        raise ContractError("context.safety.disposition is unsupported")
    evaluated_at = _parsed_datetime(value["evaluated_at"], "context.safety.evaluated_at")
    expires_at = _parsed_datetime(value["expires_at"], "context.safety.expires_at")
    if expires_at <= evaluated_at:
        raise ContractError("context.safety.expires_at must be later than evaluated_at")
    restrictions = value["restrictions"]
    if not isinstance(restrictions, list) or len(restrictions) > 20:
        raise ContractError("context.safety.restrictions has too many items")
    seen: set[str] = set()
    for index, raw in enumerate(restrictions):
        item = _object(raw, f"context.safety.restrictions[{index}]")
        _strict_keys(
            item,
            required={
                "restriction_id", "rule_code", "severity", "constraint", "evidence_ids",
                "user_facing_message", "requires_acknowledgement",
            },
            optional=set(), name=f"context.safety.restrictions[{index}]",
        )
        restriction_id = item["restriction_id"]
        if not isinstance(restriction_id, str) or _RESTRICTION_ID.fullmatch(restriction_id) is None or restriction_id in seen:
            raise ContractError("context.safety.restrictions contains an invalid or duplicate restriction_id")
        seen.add(restriction_id)
        _bounded_string(item["rule_code"], "restriction.rule_code", minimum=1, maximum=100)
        if item["severity"] not in {"info", "caution", "hard_stop"}:
            raise ContractError("restriction.severity is unsupported")
        constraint = _object(item["constraint"], "restriction.constraint")
        _strict_keys(
            constraint, required={"type"}, optional={
                "exercise_ref", "equipment_ref", "maximum_delta_kg", "maximum_sets",
            },
            name="restriction.constraint",
        )
        if constraint["type"] not in {
            "prohibit_training", "prohibit_load_increase", "reduce_volume", "exclude_exercise",
            "exclude_equipment",
            "require_symptom_confirmation", "recovery_only",
        }:
            raise ContractError("restriction.constraint.type is unsupported")
        if "exercise_ref" in constraint:
            _bounded_string(constraint["exercise_ref"], "restriction.constraint.exercise_ref", minimum=1, maximum=80)
        if "equipment_ref" in constraint:
            _bounded_string(constraint["equipment_ref"], "restriction.constraint.equipment_ref", minimum=1, maximum=120)
        if constraint["type"] == "exclude_exercise":
            if "exercise_ref" not in constraint or "equipment_ref" in constraint:
                raise ContractError("exclude_exercise requires only exercise_ref")
        if constraint["type"] == "exclude_equipment":
            if "equipment_ref" not in constraint or "exercise_ref" in constraint:
                raise ContractError("exclude_equipment requires only equipment_ref")
        if "maximum_delta_kg" in constraint:
            _strict_number(constraint["maximum_delta_kg"], "restriction.constraint.maximum_delta_kg", 0, 100)
        if "maximum_sets" in constraint:
            _strict_integer(constraint["maximum_sets"], "restriction.constraint.maximum_sets", 0, 100)
        refs = _identifier_list(item["evidence_ids"], "restriction.evidence_ids", pattern=_EVIDENCE_ID, maximum_items=20)
        if not set(refs).issubset(categories):
            raise ContractError("restriction references unknown evidence")
        _bounded_string(item["user_facing_message"], "restriction.user_facing_message", minimum=1, maximum=500)
        if not isinstance(item["requires_acknowledgement"], bool):
            raise ContractError("restriction.requires_acknowledgement must be boolean")


def _validate_v2_current_plan(value: dict[str, Any]) -> None:
    _strict_keys(
        value,
        required={"plan_ref", "revision", "date", "title", "estimated_minutes", "goal", "exercises"},
        optional=set(), name="context.current_plan",
    )
    _bounded_string(value["plan_ref"], "context.current_plan.plan_ref", minimum=1, maximum=80)
    _strict_integer(value["revision"], "context.current_plan.revision", 1, 1_000_000)
    _calendar_date(value["date"], "context.current_plan.date")
    _bounded_string(value["title"], "context.current_plan.title", minimum=1, maximum=120)
    _strict_integer(value["estimated_minutes"], "context.current_plan.estimated_minutes", 1, 300)
    _bounded_string(value["goal"], "context.current_plan.goal", maximum=500)
    exercises = value["exercises"]
    if not isinstance(exercises, list) or not 1 <= len(exercises) <= 40:
        raise ContractError("context.current_plan.exercises must contain 1 to 40 items")
    for index, raw in enumerate(exercises):
        item = _object(raw, f"context.current_plan.exercises[{index}]")
        _strict_keys(
            item,
            required={"exercise_ref", "name", "equipment_variant", "target_weight_kg", "sets", "target_reps", "rest_seconds"},
            optional=set(), name=f"context.current_plan.exercises[{index}]",
        )
        _bounded_string(item["exercise_ref"], "current_plan exercise_ref", minimum=1, maximum=80)
        _bounded_string(item["name"], "current_plan exercise name", minimum=1, maximum=100)
        _bounded_string(item["equipment_variant"], "current_plan equipment_variant", minimum=1, maximum=120)
        if item["target_weight_kg"] is not None:
            _strict_number(item["target_weight_kg"], "current_plan target_weight_kg", 0, 1_000)
        _strict_integer(item["sets"], "current_plan sets", 1, 20)
        _strict_integer(item["target_reps"], "current_plan target_reps", 1, 200)
        _strict_integer(item["rest_seconds"], "current_plan rest_seconds", 0, 900)


def _validate_v2_data_gaps(value: Any) -> None:
    if not isinstance(value, list) or len(value) > 20:
        raise ContractError("context.data_gaps has too many items")
    for index, raw in enumerate(value):
        item = _object(raw, f"context.data_gaps[{index}]")
        _strict_keys(item, required={"code", "field", "status", "message"}, optional=set(), name=f"context.data_gaps[{index}]")
        _bounded_string(item["code"], "data_gap.code", minimum=1, maximum=80)
        _bounded_string(item["field"], "data_gap.field", minimum=1, maximum=120)
        if item["status"] not in {"missing", "partial", "stale"}:
            raise ContractError("data_gap.status is unsupported")
        _bounded_string(item["message"], "data_gap.message", minimum=1, maximum=300)


def _validate_v2_recommendation(value: dict[str, Any], *, kind: str, available_minutes: int) -> None:
    recommendation_type = value.get("type")
    if recommendation_type == "candidate_plan":
        _strict_keys(value, required={"type", "candidate_plan"}, optional=set(), name="recommendation")
        if kind in {"no_change", "decline_unsafe_request"}:
            raise ProviderContractError("recommendation type does not match kind")
        _validate_v2_candidate_plan(
            _object(value["candidate_plan"], "recommendation.candidate_plan"), available_minutes,
            "recommendation.candidate_plan",
        )
    elif recommendation_type in {"no_change", "decline_unsafe_request"}:
        _strict_keys(value, required={"type", "message"}, optional=set(), name="recommendation")
        if kind != recommendation_type:
            raise ProviderContractError("recommendation type does not match kind")
        _bounded_string(value["message"], "recommendation.message", minimum=1, maximum=500)
    else:
        raise ProviderContractError("recommendation.type is unsupported")


def _validate_v2_candidate_plan(value: dict[str, Any], available_minutes: int, name: str) -> None:
    _strict_keys(
        value, required={"title", "estimated_minutes", "goal", "exercises"}, optional=set(), name=name,
    )
    _bounded_string(value["title"], f"{name}.title", minimum=1, maximum=120)
    minutes = _strict_integer(value["estimated_minutes"], f"{name}.estimated_minutes", 10, 180)
    if minutes > available_minutes:
        raise ProviderContractError(f"{name}.estimated_minutes exceeds the user's available time")
    _bounded_string(value["goal"], f"{name}.goal", minimum=1, maximum=500)
    exercises = value["exercises"]
    if not isinstance(exercises, list) or not 1 <= len(exercises) <= 12:
        raise ProviderContractError(f"{name}.exercises must contain 1 to 12 items")
    for index, raw in enumerate(exercises):
        exercise = _object(raw, f"{name}.exercises[{index}]")
        _strict_keys(
            exercise,
            required={"name", "equipment_variant", "target_weight_kg", "sets", "target_reps", "rest_seconds", "notes", "alternative"},
            optional=set(), name=f"{name}.exercises[{index}]",
        )
        _bounded_string(exercise["name"], "exercise.name", minimum=1, maximum=100)
        _bounded_string(exercise["equipment_variant"], "exercise.equipment_variant", minimum=1, maximum=120)
        if exercise["target_weight_kg"] is not None:
            _strict_number(exercise["target_weight_kg"], "exercise.target_weight_kg", 0, 500)
        _strict_integer(exercise["sets"], "exercise.sets", 1, 10)
        _strict_integer(exercise["target_reps"], "exercise.target_reps", 1, 50)
        _strict_integer(exercise["rest_seconds"], "exercise.rest_seconds", 0, 600)
        notes = exercise["notes"]
        if not isinstance(notes, list) or len(notes) > 8:
            raise ProviderContractError("exercise.notes has too many items")
        for note in notes:
            _bounded_string(note, "exercise.notes", minimum=1, maximum=300)
        if exercise["alternative"] is not None:
            _bounded_string(exercise["alternative"], "exercise.alternative", minimum=1, maximum=200)


def _validate_v2_uncertainties(value: Any, known: set[str], top: set[str]) -> None:
    if not isinstance(value, list) or len(value) > 12:
        raise ProviderContractError("uncertainties has too many items")
    for index, raw in enumerate(value):
        item = _object(raw, f"uncertainties[{index}]")
        _strict_keys(
            item, required={"code", "explanation", "evidence_ids", "data_gap_codes"},
            optional=set(), name=f"uncertainties[{index}]",
        )
        _bounded_string(item["code"], "uncertainty.code", minimum=1, maximum=80)
        _bounded_string(item["explanation"], "uncertainty.explanation", minimum=1, maximum=500)
        refs = set(_identifier_list(item["evidence_ids"], "uncertainty.evidence_ids", pattern=_EVIDENCE_ID, maximum_items=12))
        if not refs.issubset(known) or not refs.issubset(top):
            raise ProviderContractError("uncertainty references unknown evidence")
        _string_list(item["data_gap_codes"], "uncertainty.data_gap_codes", maximum_items=12, item_maximum=80)


def _validate_v2_adjustment(
    value: dict[str, Any], available_minutes: int, known: set[str], top: set[str],
) -> None:
    _strict_keys(value, required={"trigger", "candidate_plan", "evidence_ids"}, optional=set(), name="optional_adjustment")
    _bounded_string(value["trigger"], "optional_adjustment.trigger", minimum=1, maximum=300)
    _validate_v2_candidate_plan(_object(value["candidate_plan"], "optional_adjustment.candidate_plan"), available_minutes, "optional_adjustment.candidate_plan")
    refs = set(_identifier_list(value["evidence_ids"], "optional_adjustment.evidence_ids", pattern=_EVIDENCE_ID, maximum_items=12))
    if not refs.issubset(known) or not refs.issubset(top):
        raise ProviderContractError("optional_adjustment references unknown evidence")


def _validate_v2_alternatives(
    value: Any, available_minutes: int, known: set[str], top: set[str],
) -> None:
    if not isinstance(value, list) or len(value) > 2:
        raise ProviderContractError("alternatives has too many items")
    for index, raw in enumerate(value):
        item = _object(raw, f"alternatives[{index}]")
        _strict_keys(item, required={"title", "when", "candidate_plan", "evidence_ids"}, optional=set(), name=f"alternatives[{index}]")
        _bounded_string(item["title"], "alternative.title", minimum=1, maximum=120)
        _bounded_string(item["when"], "alternative.when", minimum=1, maximum=300)
        _validate_v2_candidate_plan(_object(item["candidate_plan"], "alternative.candidate_plan"), available_minutes, "alternative.candidate_plan")
        refs = set(_identifier_list(item["evidence_ids"], "alternative.evidence_ids", pattern=_EVIDENCE_ID, maximum_items=12))
        if not refs.issubset(known) or not refs.issubset(top):
            raise ProviderContractError("alternative references unknown evidence")


def _validate_v2_safety_considerations(
    value: Any, known: set[str], top: set[str], restriction_ids: set[str],
) -> None:
    if not isinstance(value, list) or len(value) > 12:
        raise ProviderContractError("safety_considerations has too many items")
    for index, raw in enumerate(value):
        item = _object(raw, f"safety_considerations[{index}]")
        _strict_keys(
            item, required={"code", "message", "evidence_ids", "restriction_ids"},
            optional=set(), name=f"safety_considerations[{index}]",
        )
        _bounded_string(item["code"], "safety_consideration.code", minimum=1, maximum=80)
        _bounded_string(item["message"], "safety_consideration.message", minimum=1, maximum=500)
        evidence_refs = set(_identifier_list(item["evidence_ids"], "safety_consideration.evidence_ids", pattern=_EVIDENCE_ID, maximum_items=12))
        restriction_refs = set(_identifier_list(item["restriction_ids"], "safety_consideration.restriction_ids", pattern=_RESTRICTION_ID, maximum_items=12))
        if not evidence_refs.issubset(known) or not evidence_refs.issubset(top):
            raise ProviderContractError("safety_consideration references unknown evidence")
        if not restriction_refs.issubset(restriction_ids):
            raise ProviderContractError("safety_consideration references unknown restrictions")
