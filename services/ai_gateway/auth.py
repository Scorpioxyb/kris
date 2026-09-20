from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Protocol


class AuthenticationError(ValueError):
    pass


@dataclass(frozen=True)
class VerifiedSession:
    subject: str
    expires_at: datetime
    token_id: str


class SessionVerifier(Protocol):
    def verify(self, token: str, *, now: datetime | None = None) -> VerifiedSession: ...


def _encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    try:
        return base64.urlsafe_b64decode(value + padding)
    except Exception as exc:
        raise AuthenticationError("session token is malformed") from exc


class HMACDevelopmentSessionTokens:
    """Development-only session tokens.

    Production issuance must be backed by App Attest verification and a
    revocable server-side device session. This signer exists so the gateway
    contract can be exercised before that external dependency is enabled.
    """

    audience = "kris-ai-gateway"

    def __init__(self, secret: bytes):
        if len(secret) < 32:
            raise ValueError("development session secret must be at least 32 bytes")
        self._secret = secret

    def issue(
        self,
        subject: str,
        *,
        now: datetime | None = None,
        lifetime: timedelta = timedelta(minutes=30),
    ) -> str:
        issued = (now or datetime.now(UTC)).astimezone(UTC)
        payload = {
            "v": 1,
            "sub": subject,
            "aud": self.audience,
            "iat": int(issued.timestamp()),
            "exp": int((issued + lifetime).timestamp()),
            "jti": secrets.token_urlsafe(12),
        }
        encoded = _encode(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode())
        signature = _encode(hmac.new(self._secret, encoded.encode("ascii"), hashlib.sha256).digest())
        return f"{encoded}.{signature}"

    def verify(self, token: str, *, now: datetime | None = None) -> VerifiedSession:
        encoded, separator, supplied_signature = token.partition(".")
        if not separator or not encoded or not supplied_signature:
            raise AuthenticationError("session token is malformed")
        expected = _encode(hmac.new(self._secret, encoded.encode("ascii"), hashlib.sha256).digest())
        if not hmac.compare_digest(expected, supplied_signature):
            raise AuthenticationError("session token signature is invalid")
        try:
            payload = json.loads(_decode(encoded))
            subject = payload["sub"]
            issued_at = datetime.fromtimestamp(int(payload["iat"]), UTC)
            expires_at = datetime.fromtimestamp(int(payload["exp"]), UTC)
            token_id = payload["jti"]
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise AuthenticationError("session token claims are invalid") from exc
        if payload.get("v") != 1 or payload.get("aud") != self.audience:
            raise AuthenticationError("session token audience is invalid")
        if not isinstance(subject, str) or not subject or len(subject) > 128:
            raise AuthenticationError("session subject is invalid")
        if not isinstance(token_id, str) or not token_id or len(token_id) > 128:
            raise AuthenticationError("session token id is invalid")
        checked_at = (now or datetime.now(UTC)).astimezone(UTC)
        if issued_at > checked_at + timedelta(minutes=2):
            raise AuthenticationError("session token was issued in the future")
        if expires_at <= issued_at or expires_at <= checked_at:
            raise AuthenticationError("session token has expired")
        return VerifiedSession(subject=subject, expires_at=expires_at, token_id=token_id)
