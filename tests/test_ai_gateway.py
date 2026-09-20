from __future__ import annotations

import json
import re
import threading
import time
import unittest
import urllib.error
import urllib.request
from dataclasses import asdict
from datetime import UTC, datetime, timedelta
from http.server import ThreadingHTTPServer
from pathlib import Path
from uuid import UUID, uuid4

from services.ai_gateway.audit import MemoryAuditSink
from services.ai_gateway.auth import HMACDevelopmentSessionTokens
from services.ai_gateway.config import ConfigurationError, GatewayConfig
from services.ai_gateway.controls import FixedWindowRateLimiter
from services.ai_gateway.provider import ProviderError, StubPlanProvider
from services.ai_gateway.server import make_handler
from services.ai_gateway.service import GatewayService


SECRET = b"test-only-secret-with-at-least-32-bytes"
V2_REQUEST_SCHEMA = (
    Path(__file__).resolve().parents[1]
    / "shared" / "schemas" / "KrisAIPlanRequest.v2.schema.json"
)


def make_payload(request_id: str | None = None) -> dict:
    return {
        "schema_version": "KrisAIPlanRequest.v1",
        "client_request_id": request_id or str(uuid4()),
        "context": {
            "schema_version": "AIRedactedPlanContext.v1",
            "feature": "training_plan_candidate",
            "locale": "zh-CN",
            "generated_at": "2026-09-10T09:00:00+08:00",
            "user_input": {
                "date": "2026-09-10",
                "objective": "减脂保肌",
                "available_minutes": 50,
                "equipment": "常规健身房",
                "notes": "上肢",
                "symptoms": "noneReported",
            },
            "readiness": {
                "score": 68,
                "state": "train_maintain",
                "confidence": "medium",
                "safety_gate": "normal",
            },
            "local_decision": {
                "action": "maintain",
                "title": "可训练",
                "summary": "保持计划",
                "evidence": ["maintain_state"],
                "rollback_condition": "出现不适时停止",
                "rule_version": "local_plan_gate_v1",
            },
            "recent_confirmed_training": [{
                "date": "2026-09-08",
                "title": "上肢",
                "status": "completed",
                "duration_minutes": 42,
                "completed_set_count": 12,
            }],
            "current_plan": None,
            "progression_notes": [],
            "data_gaps": [],
        },
    }


def make_v2_payload(request_id: str | None = None) -> dict:
    return {
        "schema_version": "KrisAIPlanRequest.v2",
        "client_request_id": request_id or str(uuid4()),
        "context": {
            "schema_version": "TrainingContext.v2",
            "context_id": str(uuid4()),
            "feature": "training_recommendation",
            "locale": "zh-CN",
            "generated_at": "2026-09-20T09:00:00+08:00",
            "expires_at": "2099-09-20T09:10:00+08:00",
            "intent": {
                "intent_id": str(uuid4()),
                "kind": "create_plan",
                "requested_date": "2026-09-20",
                "objective": "减脂保肌",
                "available_minutes": 30,
                "equipment": [{"name": "常规健身房", "status": "available"}],
                "target_plan_revision": None,
                "target_exercise_ref": None,
                "requested_changes": [],
                "free_text": None,
            },
            "objective_health": {
                "as_of": "2026-09-20T08:00:00+08:00",
                "evidence_ids": ["ev_sleep"],
            },
            "subjective_user": {
                "reported_at": "2026-09-20T08:55:00+08:00",
                "evidence_ids": ["ev_energy"],
            },
            "training_history": {
                "confirmed_session_evidence_ids": ["ev_bench"],
                "observed_workout_evidence_ids": [],
            },
            "progression": {
                "rule_version": "gated_double_progression_v1",
                "exercise_decisions": [],
            },
            "safety": {
                "rule_version": "local_safety_v2",
                "disposition": "allow",
                "evaluated_at": "2026-09-20T08:55:00+08:00",
                "expires_at": "2099-09-20T09:10:00+08:00",
                "restrictions": [],
            },
            "current_plan": None,
            "evidence": [
                {
                    "evidence_id": "ev_sleep",
                    "category": "objective_measurement",
                    "origin": "healthkit_aggregate",
                    "observed_at": "2026-09-20T07:30:00+08:00",
                    "quality": "confirmed",
                    "payload": {
                        "type": "quantity", "metric": "sleep_duration",
                        "value": 380, "unit": "minute",
                    },
                },
                {
                    "evidence_id": "ev_energy",
                    "category": "user_reported_fact",
                    "origin": "user_report",
                    "observed_at": "2026-09-20T08:55:00+08:00",
                    "quality": "confirmed",
                    "payload": {
                        "type": "categorical", "metric": "energy", "value": "normal",
                    },
                },
                {
                    "evidence_id": "ev_bench",
                    "category": "confirmed_training_result",
                    "origin": "kris_session",
                    "observed_at": "2026-09-18T18:00:00+08:00",
                    "quality": "confirmed",
                    "payload": {
                        "type": "set_performance", "exercise": "卧推",
                        "equipment_variant": "杠铃", "weight_kg": 60,
                        "reps": [8, 8, 8],
                    },
                },
            ],
            "data_gaps": [],
        },
    }


def make_v2_provider_response() -> dict:
    return {
        "schema_version": "AIRecommendationDraft.v2",
        "kind": "create_plan",
        "recommendation": {
            "type": "candidate_plan",
            "candidate_plan": {
                "title": "30 分钟上肢训练",
                "estimated_minutes": 30,
                "goal": "减脂保肌",
                "exercises": [{
                    "name": "杠铃卧推", "equipment_variant": "杠铃",
                    "target_weight_kg": 60, "sets": 3, "target_reps": 8,
                    "rest_seconds": 90, "notes": ["动作稳定"], "alternative": None,
                }],
            },
        },
        "reasons": [{
            "code": "recent_confirmed_performance",
            "explanation": "沿用最近一次已确认的同器械表现。",
            "evidence_ids": ["ev_bench"],
        }],
        "evidence_ids": ["ev_bench"],
        "confidence": "medium",
        "uncertainties": [],
        "optional_adjustment": None,
        "alternatives": [],
        "safety_considerations": [],
        "acknowledged_restriction_ids": [],
        "user_confirmation_required": True,
    }


class GatewayServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tokens = HMACDevelopmentSessionTokens(SECRET)
        self.token = self.tokens.issue("opaque-device-test")
        self.provider = StubPlanProvider()
        self.audit = MemoryAuditSink()
        self.service = GatewayService(
            verifier=self.tokens,
            provider=self.provider,
            limiter=FixedWindowRateLimiter(20),
            audit=self.audit,
        )

    def authorize(self, token: str | None = None) -> str:
        return f"Bearer {token or self.token}"

    def test_missing_or_tampered_session_is_rejected(self) -> None:
        self.assertEqual(self.service.generate_plan(authorization=None, payload=make_payload()).status, 401)
        tampered = self.token[:-1] + ("A" if self.token[-1] != "A" else "B")
        self.assertEqual(
            self.service.generate_plan(authorization=self.authorize(tampered), payload=make_payload()).status,
            401,
        )

    def test_expired_session_is_rejected(self) -> None:
        issued = datetime(2026, 9, 10, 8, tzinfo=UTC)
        token = self.tokens.issue("opaque-device-test", now=issued, lifetime=timedelta(minutes=1))
        verified_service = GatewayService(
            verifier=_VerifierAt(self.tokens, issued + timedelta(minutes=2)),
            provider=self.provider,
        )
        self.assertEqual(
            verified_service.generate_plan(authorization=self.authorize(token), payload=make_payload()).status,
            401,
        )

    def test_healthkit_identifiers_are_rejected_across_key_styles(self) -> None:
        for key in ("sample_uuid", "sampleUuid", "rawHealthSamples", "deviceIdentifier"):
            with self.subTest(key=key):
                payload = make_payload()
                payload["context"]["data_gaps"] = [{key: "sensitive-value"}]
                response = self.service.generate_plan(
                    authorization=self.authorize(), payload=payload,
                )
                self.assertEqual(response.status, 422)
                self.assertEqual(response.body["error"]["code"], "invalid_contract")

    def test_stub_provider_returns_valid_candidate_contract(self) -> None:
        response = self.service.generate_plan(
            authorization=self.authorize(), payload=make_payload(),
        )
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body["schema_version"], "AIPlanResponse.v1")
        self.assertEqual(response.body["plan"]["estimated_minutes"], 45)
        self.assertEqual(self.provider.calls, 1)

    def test_v2_returns_strict_structured_recommendation_with_gateway_identity(self) -> None:
        provider = StubPlanProvider(v2_response=make_v2_provider_response())
        service = GatewayService(
            verifier=self.tokens, provider=provider,
            limiter=FixedWindowRateLimiter(20), audit=self.audit,
        )

        payload = make_v2_payload()
        response = service.generate_recommendation(
            authorization=self.authorize(), payload=payload,
        )

        self.assertEqual(response.status, 200)
        self.assertEqual(response.body["schema_version"], "AIRecommendation.v2")
        self.assertEqual(response.body["request_id"], payload["client_request_id"])
        self.assertEqual(response.body["context_id"], payload["context"]["context_id"])
        self.assertIsNotNone(UUID(response.body["recommendation_id"]))
        self.assertTrue(response.body["user_confirmation_required"])
        self.assertNotIn("safety_gates", json.dumps(response.body))
        self.assertEqual(provider.v2_calls, 1)

    def test_v2_rejects_derived_body_state_scores_before_provider(self) -> None:
        for forbidden_key in (
            "readiness", "readiness_score", "recovery", "recovery_score",
            "status_score", "status-score", "body_score", "body_state_score",
            "BodyStateScore",
        ):
            with self.subTest(forbidden_key=forbidden_key):
                provider = StubPlanProvider(v2_response=make_v2_provider_response())
                service = GatewayService(
                    verifier=self.tokens, provider=provider,
                    limiter=FixedWindowRateLimiter(20), audit=self.audit,
                )
                payload = make_v2_payload()
                payload["context"][forbidden_key] = 42

                response = service.generate_recommendation(
                    authorization=self.authorize(), payload=payload,
                )

                self.assertEqual(response.status, 422)
                self.assertEqual(response.body["error"]["code"], "invalid_contract")
                self.assertEqual(provider.v2_calls, 0)

    def test_v2_rejects_derived_body_state_score_metrics_before_provider(self) -> None:
        for forbidden_metric in (
            "readiness", "readiness_score", "recovery", "recovery_score",
            "status_score", "status-score", "body_score", "body_state_score",
            "BodyStateScore",
        ):
            with self.subTest(forbidden_metric=forbidden_metric):
                provider = StubPlanProvider(v2_response=make_v2_provider_response())
                service = GatewayService(
                    verifier=self.tokens, provider=provider,
                    limiter=FixedWindowRateLimiter(20), audit=self.audit,
                )
                payload = make_v2_payload()
                payload["context"]["evidence"][0]["payload"]["metric"] = forbidden_metric

                response = service.generate_recommendation(
                    authorization=self.authorize(), payload=payload,
                )

                self.assertEqual(response.status, 422)
                self.assertEqual(response.body["error"]["code"], "invalid_contract")
                self.assertEqual(provider.v2_calls, 0)

    def test_v2_rejects_derived_body_state_data_gap_field_before_provider(self) -> None:
        provider = StubPlanProvider(v2_response=make_v2_provider_response())
        service = GatewayService(
            verifier=self.tokens, provider=provider,
            limiter=FixedWindowRateLimiter(20), audit=self.audit,
        )
        payload = make_v2_payload()
        payload["context"]["data_gaps"] = [{
            "code": "gap_status_score",
            "field": "status_score",
            "status": "missing",
            "message": "not collected",
        }]

        response = service.generate_recommendation(
            authorization=self.authorize(), payload=payload,
        )

        self.assertEqual(response.status, 422)
        self.assertEqual(response.body["error"]["code"], "invalid_contract")
        self.assertEqual(provider.v2_calls, 0)

    def test_v2_rejects_dangling_request_evidence_reference(self) -> None:
        provider = StubPlanProvider(v2_response=make_v2_provider_response())
        service = GatewayService(
            verifier=self.tokens, provider=provider,
            limiter=FixedWindowRateLimiter(20), audit=self.audit,
        )
        payload = make_v2_payload()
        payload["context"]["objective_health"]["evidence_ids"] = ["ev_missing"]

        response = service.generate_recommendation(
            authorization=self.authorize(), payload=payload,
        )

        self.assertEqual(response.status, 422)
        self.assertEqual(provider.v2_calls, 0)

    def test_v2_rejects_evidence_category_origin_mismatch(self) -> None:
        provider = StubPlanProvider(v2_response=make_v2_provider_response())
        service = GatewayService(
            verifier=self.tokens, provider=provider,
            limiter=FixedWindowRateLimiter(20), audit=self.audit,
        )
        payload = make_v2_payload()
        payload["context"]["evidence"][1]["origin"] = "healthkit_aggregate"

        response = service.generate_recommendation(
            authorization=self.authorize(), payload=payload,
        )

        self.assertEqual(response.status, 422)
        self.assertEqual(provider.v2_calls, 0)

    def test_v2_accepts_local_equipment_exclusion_with_typed_reference(self) -> None:
        provider = StubPlanProvider()
        service = GatewayService(
            verifier=self.tokens, provider=provider,
            limiter=FixedWindowRateLimiter(20), audit=self.audit,
        )
        payload = make_v2_payload()
        payload["context"]["safety"]["disposition"] = "constrain"
        payload["context"]["safety"]["restrictions"] = [{
            "restriction_id": "sr_no_barbell",
            "rule_code": "prohibit_equipment",
            "severity": "caution",
            "constraint": {
                "type": "exclude_equipment",
                "equipment_ref": "杠铃",
            },
            "evidence_ids": ["ev_energy"],
            "user_facing_message": "本次训练不得使用杠铃。",
            "requires_acknowledgement": True,
        }]

        response = service.generate_recommendation(
            authorization=self.authorize(), payload=payload,
        )

        self.assertEqual(response.status, 200)
        self.assertEqual(response.body["acknowledged_restriction_ids"], ["sr_no_barbell"])
        self.assertEqual(provider.v2_calls, 1)

    def test_v2_local_safety_block_and_needs_user_input_skip_provider(self) -> None:
        for disposition, error_code in (
            ("block", "local_safety_block"),
            ("needs_user_input", "user_input_required"),
        ):
            with self.subTest(disposition=disposition):
                provider = StubPlanProvider(v2_response=make_v2_provider_response())
                service = GatewayService(
                    verifier=self.tokens, provider=provider,
                    limiter=FixedWindowRateLimiter(20), audit=self.audit,
                )
                payload = make_v2_payload()
                payload["context"]["safety"]["disposition"] = disposition

                response = service.generate_recommendation(
                    authorization=self.authorize(), payload=payload,
                )

                self.assertEqual(response.status, 409)
                self.assertEqual(response.body["error"]["code"], error_code)
                self.assertEqual(provider.v2_calls, 0)

    def test_v2_ai_authored_restriction_is_provider_contract_error(self) -> None:
        generated = make_v2_provider_response()
        generated["safety_restrictions"] = [{"rule_code": "model_created"}]
        provider = StubPlanProvider(v2_response=generated)
        service = GatewayService(
            verifier=self.tokens, provider=provider,
            limiter=FixedWindowRateLimiter(20), audit=self.audit,
        )

        response = service.generate_recommendation(
            authorization=self.authorize(), payload=make_v2_payload(),
        )

        self.assertEqual(response.status, 502)
        self.assertEqual(response.body["error"]["code"], "invalid_provider_response")

    def test_v2_dangling_provider_evidence_reference_is_502(self) -> None:
        generated = make_v2_provider_response()
        generated["reasons"][0]["evidence_ids"] = ["ev_missing"]
        provider = StubPlanProvider(v2_response=generated)
        service = GatewayService(
            verifier=self.tokens, provider=provider,
            limiter=FixedWindowRateLimiter(20), audit=self.audit,
        )

        response = service.generate_recommendation(
            authorization=self.authorize(), payload=make_v2_payload(),
        )

        self.assertEqual(response.status, 502)
        self.assertEqual(response.body["error"]["code"], "invalid_provider_response")

    def test_v2_provider_cannot_change_the_requested_intent_kind(self) -> None:
        generated = make_v2_provider_response()
        generated["kind"] = "replace_exercise"
        provider = StubPlanProvider(v2_response=generated)
        service = GatewayService(
            verifier=self.tokens, provider=provider,
            limiter=FixedWindowRateLimiter(20), audit=self.audit,
        )

        response = service.generate_recommendation(
            authorization=self.authorize(), payload=make_v2_payload(),
        )

        self.assertEqual(response.status, 502)
        self.assertEqual(response.body["error"]["code"], "invalid_provider_response")

    def test_v2_provider_unavailable_is_503(self) -> None:
        provider = _UnavailableProvider()
        service = GatewayService(
            verifier=self.tokens, provider=provider,
            limiter=FixedWindowRateLimiter(20), audit=self.audit,
        )

        response = service.generate_recommendation(
            authorization=self.authorize(), payload=make_v2_payload(),
        )

        self.assertEqual(response.status, 503)
        self.assertEqual(response.body["error"]["code"], "provider_unavailable")

    def test_idempotent_replay_does_not_call_provider_twice(self) -> None:
        payload = make_payload()
        first = self.service.generate_plan(authorization=self.authorize(), payload=payload)
        second = self.service.generate_plan(authorization=self.authorize(), payload=payload)
        self.assertEqual((first.status, second.status), (200, 200))
        self.assertEqual(second.headers.get("Idempotency-Replayed"), "true")
        self.assertEqual(first.body, second.body)
        self.assertEqual(self.provider.calls, 1)

    def test_concurrent_idempotent_requests_execute_provider_once(self) -> None:
        provider = _BlockingProvider()
        service = GatewayService(
            verifier=self.tokens,
            provider=provider,
            limiter=FixedWindowRateLimiter(20),
            audit=self.audit,
        )
        payload = make_payload()
        barrier = threading.Barrier(3)
        responses = []

        def invoke() -> None:
            barrier.wait()
            responses.append(service.generate_plan(authorization=self.authorize(), payload=payload))

        threads = [threading.Thread(target=invoke), threading.Thread(target=invoke)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(timeout=2)

        self.assertEqual([response.status for response in responses], [200, 200])
        self.assertEqual(provider.calls, 1)
        self.assertEqual(sum(response.headers.get("Idempotency-Replayed") == "true" for response in responses), 1)

    def test_request_id_reuse_with_different_content_conflicts(self) -> None:
        request_id = str(uuid4())
        first = make_payload(request_id)
        second = make_payload(request_id)
        second["context"]["user_input"]["notes"] = "不同内容"
        self.assertEqual(self.service.generate_plan(authorization=self.authorize(), payload=first).status, 200)
        response = self.service.generate_plan(authorization=self.authorize(), payload=second)
        self.assertEqual(response.status, 409)

    def test_rate_limit_is_enforced_before_provider_call(self) -> None:
        service = GatewayService(
            verifier=self.tokens,
            provider=self.provider,
            limiter=FixedWindowRateLimiter(1),
            audit=self.audit,
        )
        self.assertEqual(service.generate_plan(authorization=self.authorize(), payload=make_payload()).status, 200)
        self.assertEqual(service.generate_plan(authorization=self.authorize(), payload=make_payload()).status, 429)
        self.assertEqual(self.provider.calls, 1)

    def test_audit_events_contain_no_request_or_response_body(self) -> None:
        payload = make_payload()
        payload["context"]["user_input"]["notes"] = "private-note-marker"
        response = self.service.generate_plan(authorization=self.authorize(), payload=payload)
        self.assertEqual(response.status, 200)
        serialized = json.dumps([asdict(event) for event in self.audit.events], ensure_ascii=False)
        self.assertNotIn("private-note-marker", serialized)
        self.assertNotIn("自重深蹲", serialized)
        self.assertNotIn("opaque-device-test", serialized)


class GatewayHTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tokens = HMACDevelopmentSessionTokens(SECRET)
        self.token = self.tokens.issue("http-device")
        self.service = GatewayService(
            verifier=self.tokens,
            provider=StubPlanProvider(),
            limiter=FixedWindowRateLimiter(20),
            audit=MemoryAuditSink(),
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def test_health_and_authenticated_plan_route(self) -> None:
        with urllib.request.urlopen(f"{self.base_url}/healthz") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Cache-Control"], "no-store")
        data = json.dumps(make_payload()).encode("utf-8")
        request = urllib.request.Request(
            f"{self.base_url}/v1/ai/training-plan-candidates",
            data=data,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(request) as response:
            body = json.load(response)
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
            self.assertEqual(body["schema_version"], "AIPlanResponse.v1")

    def test_oversized_body_is_rejected_without_reading_it(self) -> None:
        request = urllib.request.Request(
            f"{self.base_url}/v1/ai/training-plan-candidates",
            data=b"x" * (64 * 1024 + 1),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request)
        error = raised.exception
        try:
            self.assertEqual(error.code, 413)
        finally:
            error.close()

    def test_authenticated_v2_recommendation_route(self) -> None:
        data = json.dumps(make_v2_payload()).encode("utf-8")
        request = urllib.request.Request(
            f"{self.base_url}/v2/ai/training-recommendations",
            data=data,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )

        with urllib.request.urlopen(request) as response:
            body = json.load(response)
            self.assertEqual(response.status, 200)
            self.assertEqual(body["schema_version"], "AIRecommendation.v2")


class GatewayConfigTests(unittest.TestCase):
    def test_development_config_requires_secret_and_forces_stub(self) -> None:
        with self.assertRaises(ConfigurationError):
            GatewayConfig.from_env({})
        config = GatewayConfig.from_env({"KRIS_AI_GATEWAY_SESSION_SECRET": SECRET.decode()})
        self.assertEqual(config.provider, "stub")
        self.assertEqual(config.host, "127.0.0.1")

    def test_production_mode_fails_closed_until_real_auth_exists(self) -> None:
        with self.assertRaises(ConfigurationError):
            GatewayConfig.from_env({
                "KRIS_AI_GATEWAY_ENV": "production",
                "KRIS_AI_GATEWAY_SESSION_SECRET": SECRET.decode(),
            })


class GatewaySchemaContractTests(unittest.TestCase):
    def test_v2_schema_forbids_normalized_body_state_score_variants(self) -> None:
        schema = json.loads(V2_REQUEST_SCHEMA.read_text(encoding="utf-8"))
        definitions = schema["$defs"]
        forbidden_schema = definitions["forbiddenDerivedScoreName"]
        pattern = re.compile(forbidden_schema["pattern"])
        protected_fields = (
            definitions["metric"],
            definitions["dataGap"]["properties"]["field"],
        )

        for field_schema in protected_fields:
            self.assertEqual(
                field_schema["not"],
                {"$ref": "#/$defs/forbiddenDerivedScoreName"},
            )

        forbidden_variants = (
            "readiness", "ReadinessScore", "readiness-score", "readiness_score",
            "RECOVERY", "recoveryScore", "status-score", "Status_Score",
            "BodyScore", "body-score", "BodyStateScore", "body_state_score",
            "body-state-score",
        )
        for value in forbidden_variants:
            with self.subTest(value=value):
                self.assertIsNotNone(pattern.search(value))

        for value in ("sleep_duration", "training_status", "body_mass", "recovery_notes"):
            with self.subTest(allowed=value):
                self.assertIsNone(pattern.search(value))


class _VerifierAt:
    def __init__(self, tokens: HMACDevelopmentSessionTokens, now: datetime):
        self.tokens = tokens
        self.now = now

    def verify(self, token: str, *, now: datetime | None = None):
        return self.tokens.verify(token, now=self.now)


class _BlockingProvider(StubPlanProvider):
    def generate_plan(self, context: dict) -> dict:
        time.sleep(0.05)
        return super().generate_plan(context)


class _UnavailableProvider(StubPlanProvider):
    def generate_recommendation(self, context: dict) -> dict:
        raise ProviderError("fixture provider unavailable")


if __name__ == "__main__":
    unittest.main()
