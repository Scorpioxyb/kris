from __future__ import annotations

import hashlib
import json
import sys
from dataclasses import asdict, dataclass
from typing import Protocol


@dataclass(frozen=True)
class AuditEvent:
    request_id: str
    subject_hash: str
    feature: str
    provider: str
    outcome: str
    latency_ms: int
    cached: bool

    @staticmethod
    def create(
        *, request_id: str, subject: str, feature: str, provider: str,
        outcome: str, latency_ms: int, cached: bool,
    ) -> "AuditEvent":
        subject_hash = hashlib.sha256(subject.encode()).hexdigest()[:16]
        return AuditEvent(request_id, subject_hash, feature, provider, outcome, latency_ms, cached)


class AuditSink(Protocol):
    def record(self, event: AuditEvent) -> None: ...


class JSONLineAuditSink:
    """Records metadata only; request and response bodies are intentionally absent."""

    def record(self, event: AuditEvent) -> None:
        sys.stderr.write(json.dumps(asdict(event), sort_keys=True, separators=(",", ":")) + "\n")


class MemoryAuditSink:
    def __init__(self):
        self.events: list[AuditEvent] = []

    def record(self, event: AuditEvent) -> None:
        self.events.append(event)
