from __future__ import annotations

from copy import deepcopy
from typing import Any, Protocol


class ProviderError(RuntimeError):
    pass


class PlanProvider(Protocol):
    name: str

    def generate_plan(self, context: dict[str, Any]) -> dict[str, Any]: ...

    def generate_recommendation(self, context: dict[str, Any]) -> dict[str, Any]: ...


class StubPlanProvider:
    """Deterministic pre-integration provider used by tests and local development."""

    name = "stub"

    model = "deterministic-stub"
    prompt_version = "training_recommendation.stub.v2"

    def __init__(
        self,
        response: dict[str, Any] | None = None,
        v2_response: dict[str, Any] | None = None,
    ):
        self.calls = 0
        self.v2_calls = 0
        self._response = deepcopy(response) if response is not None else None
        self._v2_response = deepcopy(v2_response) if v2_response is not None else None

    def generate_plan(self, context: dict[str, Any]) -> dict[str, Any]:
        self.calls += 1
        if self._response is not None:
            return deepcopy(self._response)
        user_input = context["user_input"]
        minutes = min(45, user_input["available_minutes"])
        return {
            "schema_version": "AIPlanResponse.v1",
            "rationale": "这是用于验证候选审核链路的固定开发响应，不代表真实模型建议。",
            "cautions": ["首组根据当前状态校准，不做力竭组。"],
            "plan": {
                "title": "开发环境候选计划",
                "estimated_minutes": minutes,
                "goal": user_input["objective"],
                "safety_gates": ["出现异常疼痛、胸闷、眩晕或明显呼吸困难时立即停止。"],
                "exercises": [{
                    "name": "自重深蹲",
                    "equipment_variant": "自重",
                    "target_weight_kg": None,
                    "sets": 3,
                    "target_reps": 10,
                    "rest_seconds": 90,
                    "notes": ["保持躯干稳定，动作质量优先。"],
                    "alternative": "坐姿起立",
                }],
            },
        }

    def generate_recommendation(self, context: dict[str, Any]) -> dict[str, Any]:
        self.v2_calls += 1
        if self._v2_response is not None:
            return deepcopy(self._v2_response)
        intent = context["intent"]
        evidence_id = context["evidence"][0]["evidence_id"]
        if intent["kind"] == "explain_recommendation":
            return {
                "schema_version": "AIRecommendationDraft.v2",
                "kind": "no_change",
                "recommendation": {
                    "type": "no_change",
                    "message": "当前请求只需要解释，不生成或修改训练计划。",
                },
                "reasons": [{
                    "code": "development_fixture",
                    "explanation": "这是用于验证 V2 解释链路的固定开发响应。",
                    "evidence_ids": [evidence_id],
                }],
                "evidence_ids": [evidence_id],
                "confidence": "low",
                "uncertainties": [],
                "optional_adjustment": None,
                "alternatives": [],
                "safety_considerations": [],
                "acknowledged_restriction_ids": [
                    item["restriction_id"] for item in context["safety"]["restrictions"]
                    if item["requires_acknowledgement"]
                ],
                "user_confirmation_required": True,
            }
        return {
            "schema_version": "AIRecommendationDraft.v2",
            "kind": intent["kind"],
            "recommendation": {
                "type": "candidate_plan",
                "candidate_plan": {
                    "title": "开发环境候选计划",
                    "estimated_minutes": min(30, intent["available_minutes"]),
                    "goal": intent["objective"],
                    "exercises": [{
                        "name": "自重深蹲",
                        "equipment_variant": "自重",
                        "target_weight_kg": None,
                        "sets": 3,
                        "target_reps": 10,
                        "rest_seconds": 90,
                        "notes": ["保持躯干稳定，动作质量优先。"],
                        "alternative": "坐姿起立",
                    }],
                },
            },
            "reasons": [{
                "code": "development_fixture",
                "explanation": "这是用于验证 V2 候选审核链路的固定开发响应。",
                "evidence_ids": [evidence_id],
            }],
            "evidence_ids": [evidence_id],
            "confidence": "low",
            "uncertainties": [],
            "optional_adjustment": None,
            "alternatives": [],
            "safety_considerations": [],
            "acknowledged_restriction_ids": [
                item["restriction_id"] for item in context["safety"]["restrictions"]
                if item["requires_acknowledgement"]
            ],
            "user_confirmation_required": True,
        }
