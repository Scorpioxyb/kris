from __future__ import annotations

import time
from copy import deepcopy
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

from .audit import AuditEvent, AuditSink, JSONLineAuditSink
from .auth import AuthenticationError, SessionVerifier
from .contracts import (
    ContractError,
    ProviderContractError,
    RequestContractError,
    validate_plan_request,
    validate_plan_response,
    validate_recommendation_request,
    validate_recommendation_response,
)
from .controls import (
    FixedWindowRateLimiter,
    IdempotencyConflict,
    InMemoryIdempotencyStore,
    RateLimitExceeded,
)
from .provider import PlanProvider, ProviderError


@dataclass(frozen=True)
class GatewayResponse:
    status: int
    body: dict[str, Any]
    headers: dict[str, str] = field(default_factory=dict)


class GatewayService:
    def __init__(
        self,
        *,
        verifier: SessionVerifier,
        provider: PlanProvider,
        limiter: FixedWindowRateLimiter | None = None,
        idempotency: InMemoryIdempotencyStore | None = None,
        audit: AuditSink | None = None,
    ):
        self.verifier = verifier
        self.provider = provider
        self.limiter = limiter or FixedWindowRateLimiter(6)
        self.idempotency = idempotency or InMemoryIdempotencyStore()
        self.audit = audit or JSONLineAuditSink()

    def generate_plan(self, *, authorization: str | None, payload: Any) -> GatewayResponse:
        started = time.monotonic()
        request_id = "unknown"
        subject = "unknown"
        try:
            session = self._authenticate(authorization)
            subject = session.subject
            validated = validate_plan_request(payload)
            request_id = validated["client_request_id"]
            digest = self.idempotency.digest(validated)
            with self.idempotency.serialize(subject, request_id):
                cached = self.idempotency.lookup(subject, request_id, digest)
                if cached is not None:
                    response = GatewayResponse(
                        cached.status, cached.body, {"Idempotency-Replayed": "true"},
                    )
                    self._audit(started, request_id, subject, "ok", cached=True)
                    return response
                remaining = self.limiter.check(subject)
                context = validated["context"]
                generated = self.provider.generate_plan(context)
                response_body = validate_plan_response(
                    generated,
                    available_minutes=context["user_input"]["available_minutes"],
                )
                self.idempotency.save(subject, request_id, digest, 200, response_body)
            self._audit(started, request_id, subject, "ok", cached=False)
            return GatewayResponse(200, response_body, {"X-RateLimit-Remaining": str(remaining)})
        except AuthenticationError as exc:
            self._audit(started, request_id, subject, "authentication_failed", cached=False)
            return self._error(401, "authentication_required", str(exc), request_id)
        except ContractError as exc:
            self._audit(started, request_id, subject, "invalid_contract", cached=False)
            return self._error(422, "invalid_contract", str(exc), request_id)
        except IdempotencyConflict as exc:
            self._audit(started, request_id, subject, "idempotency_conflict", cached=False)
            return self._error(409, "idempotency_conflict", str(exc), request_id)
        except RateLimitExceeded:
            self._audit(started, request_id, subject, "rate_limited", cached=False)
            return self._error(429, "rate_limited", "request rate exceeded", request_id)
        except ProviderError:
            self._audit(started, request_id, subject, "provider_unavailable", cached=False)
            return self._error(503, "provider_unavailable", "smart suggestion service is unavailable", request_id)
        except Exception:
            self._audit(started, request_id, subject, "internal_error", cached=False)
            return self._error(500, "internal_error", "request could not be completed", request_id)

    def generate_recommendation(self, *, authorization: str | None, payload: Any) -> GatewayResponse:
        started = time.monotonic()
        request_id = "unknown"
        subject = "unknown"
        feature = "training_recommendation"
        try:
            session = self._authenticate(authorization)
            subject = session.subject
            validated = validate_recommendation_request(payload)
            request_id = validated["client_request_id"]
            context = validated["context"]
            disposition = context["safety"]["disposition"]
            if disposition == "block":
                self._audit(started, request_id, subject, "local_safety_block", cached=False, feature=feature)
                return self._error(
                    409, "local_safety_block",
                    "local safety rules block AI training recommendations", request_id,
                )
            if disposition == "needs_user_input":
                self._audit(started, request_id, subject, "user_input_required", cached=False, feature=feature)
                return self._error(
                    409, "user_input_required",
                    "additional user input is required before AI reasoning", request_id,
                )

            namespaced_request_id = f"v2:{request_id}"
            digest = self.idempotency.digest(validated)
            with self.idempotency.serialize(subject, namespaced_request_id):
                cached = self.idempotency.lookup(subject, namespaced_request_id, digest)
                if cached is not None:
                    response = GatewayResponse(
                        cached.status, cached.body, {"Idempotency-Replayed": "true"},
                    )
                    self._audit(started, request_id, subject, "ok", cached=True, feature=feature)
                    return response
                remaining = self.limiter.check(subject)
                generated = self.provider.generate_recommendation(context)
                validated_draft = validate_recommendation_response(generated, context=context)
                response_body = deepcopy(validated_draft)
                response_body["schema_version"] = "AIRecommendation.v2"
                response_body["request_id"] = request_id
                response_body["recommendation_id"] = str(uuid4())
                response_body["context_id"] = context["context_id"]
                response_body["inference_metadata"] = {
                    "provider": self.provider.name,
                    "model": getattr(self.provider, "model", "managed"),
                    "prompt_version": getattr(self.provider, "prompt_version", "training_recommendation.v2"),
                    "generated_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                }
                self.idempotency.save(
                    subject, namespaced_request_id, digest, 200, response_body,
                )
            self._audit(started, request_id, subject, "ok", cached=False, feature=feature)
            return GatewayResponse(200, response_body, {"X-RateLimit-Remaining": str(remaining)})
        except AuthenticationError as exc:
            self._audit(started, request_id, subject, "authentication_failed", cached=False, feature=feature)
            return self._error(401, "authentication_required", str(exc), request_id)
        except RequestContractError as exc:
            self._audit(started, request_id, subject, "invalid_request_contract", cached=False, feature=feature)
            return self._error(422, "invalid_contract", str(exc), request_id)
        except ProviderContractError:
            self._audit(started, request_id, subject, "invalid_provider_response", cached=False, feature=feature)
            return self._error(
                502, "invalid_provider_response",
                "provider returned an invalid structured recommendation", request_id,
            )
        except IdempotencyConflict as exc:
            self._audit(started, request_id, subject, "idempotency_conflict", cached=False, feature=feature)
            return self._error(409, "idempotency_conflict", str(exc), request_id)
        except RateLimitExceeded:
            self._audit(started, request_id, subject, "rate_limited", cached=False, feature=feature)
            return self._error(429, "rate_limited", "request rate exceeded", request_id)
        except ProviderError:
            self._audit(started, request_id, subject, "provider_unavailable", cached=False, feature=feature)
            return self._error(503, "provider_unavailable", "smart suggestion service is unavailable", request_id)
        except Exception:
            self._audit(started, request_id, subject, "internal_error", cached=False, feature=feature)
            return self._error(500, "internal_error", "request could not be completed", request_id)

    def _authenticate(self, authorization: str | None):
        scheme, _, token = (authorization or "").partition(" ")
        if scheme.lower() != "bearer" or not token:
            raise AuthenticationError("Kris device session is required")
        return self.verifier.verify(token)

    def _audit(
        self, started: float, request_id: str, subject: str,
        outcome: str, *, cached: bool, feature: str = "training_plan_candidate",
    ) -> None:
        self.audit.record(AuditEvent.create(
            request_id=request_id,
            subject=subject,
            feature=feature,
            provider=self.provider.name,
            outcome=outcome,
            latency_ms=max(0, int((time.monotonic() - started) * 1000)),
            cached=cached,
        ))

    @staticmethod
    def _error(status: int, code: str, message: str, request_id: str) -> GatewayResponse:
        return GatewayResponse(status, {
            "schema_version": "GatewayError.v1",
            "request_id": request_id,
            "error": {"code": code, "message": message},
        })
