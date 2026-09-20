from __future__ import annotations

import json
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Iterator

from companion.security import constant_time_equal, token_digest


def utc_now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class CompanionStore:
    def __init__(self, path: Path, secret: bytes):
        self.path = path
        self.secret = secret
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._migrate()

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        try:
            yield connection
            connection.commit()
        finally:
            connection.close()

    def _migrate(self) -> None:
        with self.connect() as db:
            db.executescript(
                """
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS pairing_tokens (
                    token_hash TEXT PRIMARY KEY,
                    expires_at TEXT NOT NULL,
                    consumed_at TEXT
                );
                CREATE TABLE IF NOT EXISTS devices (
                    device_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    token_hash TEXT NOT NULL UNIQUE,
                    paired_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS health_batches (
                    batch_id TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    received_at TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    sample_count INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS health_samples (
                    sample_uuid TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    metric TEXT NOT NULL,
                    start_at TEXT NOT NULL,
                    end_at TEXT NOT NULL,
                    value REAL NOT NULL,
                    unit TEXT NOT NULL,
                    source TEXT NOT NULL,
                    metadata_json TEXT NOT NULL,
                    batch_id TEXT NOT NULL REFERENCES health_batches(batch_id)
                );
                CREATE TABLE IF NOT EXISTS health_coverage (
                    device_id TEXT NOT NULL,
                    date TEXT NOT NULL,
                    metric TEXT NOT NULL,
                    status TEXT NOT NULL,
                    reason TEXT,
                    batch_id TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(device_id, date, metric)
                );
                CREATE TABLE IF NOT EXISTS plans (
                    plan_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    published_at TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    active INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY(plan_id, revision)
                );
                CREATE TABLE IF NOT EXISTS training_sessions (
                    session_id TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    received_at TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    archive_state TEXT NOT NULL,
                    archive_error TEXT
                );
                CREATE TABLE IF NOT EXISTS changes (
                    version INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    object_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    payload_json TEXT NOT NULL
                );
                """
            )

    def create_pairing_token(self, ttl_minutes: int = 10) -> str:
        token = secrets.token_urlsafe(32)
        digest = token_digest(self.secret, token)
        expires = (datetime.now(UTC) + timedelta(minutes=ttl_minutes)).isoformat(timespec="seconds")
        with self.connect() as db:
            db.execute(
                "INSERT INTO pairing_tokens(token_hash, expires_at, consumed_at) VALUES (?, ?, NULL)",
                (digest, expires),
            )
        return token

    def pair_device(self, one_time_token: str, device_id: str, name: str) -> str | None:
        digest = token_digest(self.secret, one_time_token)
        now = utc_now()
        device_token = secrets.token_urlsafe(48)
        device_digest = token_digest(self.secret, device_token)
        with self.connect() as db:
            row = db.execute(
                "SELECT token_hash, expires_at, consumed_at FROM pairing_tokens WHERE token_hash=?",
                (digest,),
            ).fetchone()
            if row is None or row["consumed_at"] is not None or row["expires_at"] < now:
                return None
            updated = db.execute(
                "UPDATE pairing_tokens SET consumed_at=? WHERE token_hash=? AND consumed_at IS NULL",
                (now, digest),
            )
            if updated.rowcount != 1:
                return None
            db.execute(
                """INSERT INTO devices(device_id, name, token_hash, paired_at, last_seen_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(device_id) DO UPDATE SET
                     name=excluded.name, token_hash=excluded.token_hash,
                     paired_at=excluded.paired_at, last_seen_at=excluded.last_seen_at""",
                (device_id, name[:200], device_digest, now, now),
            )
        return device_token

    def authenticate(self, token: str) -> str | None:
        digest = token_digest(self.secret, token)
        with self.connect() as db:
            rows = db.execute("SELECT device_id, token_hash FROM devices").fetchall()
            for row in rows:
                if constant_time_equal(str(row["token_hash"]), digest):
                    db.execute("UPDATE devices SET last_seen_at=? WHERE device_id=?", (utc_now(), row["device_id"]))
                    return str(row["device_id"])
        return None

    def ingest_health_batch(self, payload: dict[str, Any], authenticated_device: str) -> tuple[bool, int]:
        batch_id = payload["batch_id"]
        if payload["device_id"] != authenticated_device:
            raise ValueError("device_id does not match authenticated device")
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        with self.connect() as db:
            existing = db.execute("SELECT sample_count FROM health_batches WHERE batch_id=?", (batch_id,)).fetchone()
            if existing:
                return False, self.current_version(db)
            db.execute(
                "INSERT INTO health_batches VALUES (?, ?, ?, ?, ?)",
                (batch_id, authenticated_device, utc_now(), raw, len(payload["samples"])),
            )
            for sample in payload["samples"]:
                db.execute(
                    """INSERT OR IGNORE INTO health_samples
                       (sample_uuid, device_id, metric, start_at, end_at, value, unit, source, metadata_json, batch_id)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        sample["sample_uuid"], authenticated_device, sample["metric"], sample["start_at"],
                        sample["end_at"], float(sample["value"]), sample["unit"], sample["source"],
                        json.dumps(sample.get("metadata") or {}, ensure_ascii=False, separators=(",", ":")), batch_id,
                    ),
                )
            for item in payload["coverage"]:
                db.execute(
                    """INSERT INTO health_coverage(device_id, date, metric, status, reason, batch_id, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?)
                       ON CONFLICT(device_id, date, metric) DO UPDATE SET
                         status=excluded.status, reason=excluded.reason,
                         batch_id=excluded.batch_id, updated_at=excluded.updated_at""",
                    (authenticated_device, item["date"], item["metric"], item["status"], item.get("reason"), batch_id, utc_now()),
                )
            version = self._add_change(db, "health_batch", batch_id, {"batch_id": batch_id, "sample_count": len(payload["samples"])})
        return True, version

    def store_session(self, payload: dict[str, Any], device_id: str) -> tuple[bool, str]:
        session_id = payload["session_id"]
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        with self.connect() as db:
            row = db.execute("SELECT archive_state FROM training_sessions WHERE session_id=?", (session_id,)).fetchone()
            if row:
                return False, str(row["archive_state"])
            db.execute(
                "INSERT INTO training_sessions VALUES (?, ?, ?, ?, 'received', NULL)",
                (session_id, device_id, utc_now(), raw),
            )
        return True, "received"

    def session(self, session_id: str) -> dict[str, Any] | None:
        with self.connect() as db:
            row = db.execute("SELECT * FROM training_sessions WHERE session_id=?", (session_id,)).fetchone()
            return dict(row) if row else None

    def mark_session(self, session_id: str, state: str, error: str | None = None) -> int:
        with self.connect() as db:
            db.execute(
                "UPDATE training_sessions SET archive_state=?, archive_error=? WHERE session_id=?",
                (state, error, session_id),
            )
            if state == "archived":
                return self._add_change(db, "training_session", session_id, {"session_id": session_id, "archive_state": state})
            return self.current_version(db)

    def publish_plan(self, payload: dict[str, Any]) -> tuple[bool, int]:
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        with self.connect() as db:
            existing = db.execute(
                "SELECT payload_json FROM plans WHERE plan_id=? AND revision=?",
                (payload["plan_id"], payload["revision"]),
            ).fetchone()
            if existing:
                if existing["payload_json"] != raw:
                    raise ValueError("plan revision already exists with different content")
                return False, self.current_version(db)
            db.execute("UPDATE plans SET active=0")
            db.execute(
                "INSERT INTO plans VALUES (?, ?, ?, ?, 1)",
                (payload["plan_id"], payload["revision"], utc_now(), raw),
            )
            version = self._add_change(db, "training_plan", payload["plan_id"], payload)
            db.execute(
                "INSERT INTO meta(key, value) VALUES ('notes_plan_migration_complete', 'true') ON CONFLICT(key) DO UPDATE SET value='true'"
            )
        return True, version

    def current_plan(self) -> dict[str, Any] | None:
        with self.connect() as db:
            row = db.execute("SELECT payload_json FROM plans WHERE active=1 ORDER BY published_at DESC LIMIT 1").fetchone()
            return json.loads(row["payload_json"]) if row else None

    def changes_after(self, version: int, limit: int = 200) -> list[dict[str, Any]]:
        with self.connect() as db:
            rows = db.execute(
                "SELECT version, kind, object_id, created_at, payload_json FROM changes WHERE version>? ORDER BY version LIMIT ?",
                (version, min(max(limit, 1), 500)),
            ).fetchall()
            return [
                {
                    "version": row["version"], "kind": row["kind"], "object_id": row["object_id"],
                    "created_at": row["created_at"], "payload": json.loads(row["payload_json"]),
                }
                for row in rows
            ]

    def current_version(self, db: sqlite3.Connection | None = None) -> int:
        if db is not None:
            row = db.execute("SELECT COALESCE(MAX(version), 0) AS version FROM changes").fetchone()
            return int(row["version"])
        with self.connect() as connection:
            return self.current_version(connection)

    def _add_change(self, db: sqlite3.Connection, kind: str, object_id: str, payload: dict[str, Any]) -> int:
        cursor = db.execute(
            "INSERT INTO changes(kind, object_id, created_at, payload_json) VALUES (?, ?, ?, ?)",
            (kind, object_id, utc_now(), json.dumps(payload, ensure_ascii=False, separators=(",", ":"))),
        )
        return int(cursor.lastrowid)
