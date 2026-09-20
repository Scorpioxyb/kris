from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Mapping

from .audit import JSONLineAuditSink
from .auth import HMACDevelopmentSessionTokens
from .controls import FixedWindowRateLimiter
from .provider import StubPlanProvider
from .service import GatewayService


class ConfigurationError(ValueError):
    pass


@dataclass(frozen=True)
class GatewayConfig:
    environment: str
    host: str
    port: int
    session_secret: bytes
    provider: str
    rate_limit_per_minute: int

    @classmethod
    def from_env(cls, values: Mapping[str, str] | None = None) -> "GatewayConfig":
        env = os.environ if values is None else values
        environment = env.get("KRIS_AI_GATEWAY_ENV", "development").strip().lower()
        if environment not in {"development", "test", "production"}:
            raise ConfigurationError("KRIS_AI_GATEWAY_ENV must be development, test, or production")

        host = env.get("KRIS_AI_GATEWAY_HOST", "127.0.0.1").strip()
        if not host:
            raise ConfigurationError("KRIS_AI_GATEWAY_HOST must not be empty")
        port = _integer(env.get("KRIS_AI_GATEWAY_PORT", "8787"), "KRIS_AI_GATEWAY_PORT", 1, 65_535)
        rate_limit = _integer(
            env.get("KRIS_AI_GATEWAY_RATE_LIMIT", "6"),
            "KRIS_AI_GATEWAY_RATE_LIMIT", 1, 1_000,
        )
        provider = env.get("KRIS_AI_GATEWAY_PROVIDER", "stub").strip().lower()
        secret_value = env.get("KRIS_AI_GATEWAY_SESSION_SECRET", "")
        session_secret = secret_value.encode("utf-8")
        if len(session_secret) < 32:
            raise ConfigurationError("KRIS_AI_GATEWAY_SESSION_SECRET must contain at least 32 UTF-8 bytes")

        # The development signer and deterministic stub are intentionally not
        # deployable as production authentication or model infrastructure.
        if environment == "production":
            raise ConfigurationError(
                "production mode requires App Attest sessions and a production provider; neither is enabled yet"
            )
        if provider != "stub":
            raise ConfigurationError("only the stub provider is enabled before the production security gate")
        return cls(environment, host, port, session_secret, provider, rate_limit)

    def make_service(self) -> GatewayService:
        return GatewayService(
            verifier=HMACDevelopmentSessionTokens(self.session_secret),
            provider=StubPlanProvider(),
            limiter=FixedWindowRateLimiter(self.rate_limit_per_minute),
            audit=JSONLineAuditSink(),
        )


def _integer(value: str, field: str, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ConfigurationError(f"{field} must be an integer") from exc
    if not minimum <= parsed <= maximum:
        raise ConfigurationError(f"{field} must be between {minimum} and {maximum}")
    return parsed
