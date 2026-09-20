from __future__ import annotations

import hashlib
import json
import threading
import time
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import dataclass
from typing import Any


class RateLimitExceeded(RuntimeError):
    pass


class IdempotencyConflict(RuntimeError):
    pass


@dataclass
class _Window:
    started_at: float
    count: int


class FixedWindowRateLimiter:
    def __init__(self, limit: int, *, window_seconds: int = 60):
        if limit < 1 or window_seconds < 1:
            raise ValueError("rate limit and window must be positive")
        self.limit = limit
        self.window_seconds = window_seconds
        self._windows: dict[str, _Window] = {}
        self._lock = threading.Lock()

    def check(self, subject: str, *, now: float | None = None) -> int:
        current = time.monotonic() if now is None else now
        with self._lock:
            window = self._windows.get(subject)
            if window is None or current - window.started_at >= self.window_seconds:
                self._windows[subject] = _Window(started_at=current, count=1)
                return self.limit - 1
            if window.count >= self.limit:
                raise RateLimitExceeded("request rate exceeded")
            window.count += 1
            return self.limit - window.count


@dataclass(frozen=True)
class CachedResponse:
    payload_digest: str
    status: int
    body: dict[str, Any]


class InMemoryIdempotencyStore:
    def __init__(self):
        self._values: dict[tuple[str, str], CachedResponse] = {}
        self._lock = threading.Lock()
        self._request_locks: dict[tuple[str, str], threading.Lock] = {}

    @contextmanager
    def serialize(self, subject: str, request_id: str):
        """Serialize one idempotency key so concurrent retries execute once."""
        key = (subject, request_id)
        with self._lock:
            request_lock = self._request_locks.setdefault(key, threading.Lock())
        with request_lock:
            yield

    @staticmethod
    def digest(payload: dict[str, Any]) -> str:
        canonical = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(canonical).hexdigest()

    def lookup(self, subject: str, request_id: str, payload_digest: str) -> CachedResponse | None:
        with self._lock:
            cached = self._values.get((subject, request_id))
            if cached is None:
                return None
            if cached.payload_digest != payload_digest:
                raise IdempotencyConflict("request id was already used with different content")
            return CachedResponse(cached.payload_digest, cached.status, deepcopy(cached.body))

    def save(self, subject: str, request_id: str, payload_digest: str, status: int, body: dict[str, Any]) -> None:
        with self._lock:
            self._values[(subject, request_id)] = CachedResponse(
                payload_digest=payload_digest,
                status=status,
                body=deepcopy(body),
            )
