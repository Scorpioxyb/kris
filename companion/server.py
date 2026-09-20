from __future__ import annotations

import argparse
import json
import ssl
import subprocess
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

from companion.archive import append_session_artifacts, run_refresh
from companion.config import CompanionConfig
from companion.contracts import ContractError, validate_health_batch, validate_training_session
from companion.security import ensure_certificate, ensure_secret
from companion.snapshot import build_snapshot
from companion.store import CompanionStore


MAX_BODY_BYTES = 5 * 1024 * 1024


class CompanionHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], config: CompanionConfig, store: CompanionStore):
        super().__init__(address, CompanionHandler)
        self.config = config
        self.store = store


class CompanionHandler(BaseHTTPRequestHandler):
    server_version = "KrisCoachCompanion/1.0"
    protocol_version = "HTTP/1.1"

    @property
    def app(self) -> CompanionHTTPServer:
        return self.server  # type: ignore[return-value]

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self._json(HTTPStatus.OK, {"status": "ok", "tls": True, "version": self.app.store.current_version()})
            return
        device_id = self._authenticated_device()
        if not device_id:
            return
        if parsed.path == "/v1/snapshot":
            self._json(HTTPStatus.OK, build_snapshot(self.app.config, self.app.store))
            return
        if parsed.path == "/v1/changes":
            query = parse_qs(parsed.query)
            try:
                after = max(0, int((query.get("after") or ["0"])[0]))
            except ValueError:
                self._error(HTTPStatus.BAD_REQUEST, "invalid_after", "after must be an integer")
                return
            changes = self.app.store.changes_after(after)
            self._json(
                HTTPStatus.OK,
                {"after": after, "current_version": self.app.store.current_version(), "changes": changes},
            )
            return
        self._error(HTTPStatus.NOT_FOUND, "not_found", "endpoint not found")

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        try:
            payload = self._read_json()
        except ContractError as exc:
            self._error(HTTPStatus.BAD_REQUEST, "invalid_json", str(exc))
            return
        if parsed.path == "/v1/pair":
            self._pair(payload)
            return
        device_id = self._authenticated_device()
        if not device_id:
            return
        if parsed.path == "/v1/health/batches":
            try:
                batch = validate_health_batch(payload)
                inserted, version = self.app.store.ingest_health_batch(batch, device_id)
            except (ContractError, ValueError) as exc:
                self._error(HTTPStatus.BAD_REQUEST, "invalid_health_batch", str(exc))
                return
            self._json(HTTPStatus.OK, {"acknowledged": True, "duplicate": not inserted, "version": version})
            return
        if parsed.path == "/v1/training/sessions":
            self._training_session(payload, device_id)
            return
        if parsed.path == "/v1/refresh":
            self._refresh()
            return
        self._error(HTTPStatus.NOT_FOUND, "not_found", "endpoint not found")

    def _pair(self, payload: dict[str, Any]) -> None:
        token = str(payload.get("token") or "")
        device_id = str(payload.get("device_id") or "")
        device_name = str(payload.get("device_name") or "iPhone")
        if not token or not device_id or len(device_id) > 128:
            self._error(HTTPStatus.BAD_REQUEST, "invalid_pair_request", "token and device_id are required")
            return
        issued = self.app.store.pair_device(token, device_id, device_name)
        if not issued:
            self._error(HTTPStatus.UNAUTHORIZED, "pair_token_rejected", "pairing token is invalid, expired, or already used")
            return
        self._json(
            HTTPStatus.OK,
            {"device_token": issued, "snapshot_version": self.app.store.current_version(), "schema_version": "PairResponse.v1"},
        )

    def _training_session(self, raw: dict[str, Any], device_id: str) -> None:
        try:
            session = validate_training_session(raw)
        except ContractError as exc:
            self._error(HTTPStatus.BAD_REQUEST, "invalid_training_session", str(exc))
            return
        inserted, state = self.app.store.store_session(session, device_id)
        stored = self.app.store.session(session["session_id"])
        if stored is None:
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "session_store_failed", "session could not be read back")
            return
        stored_payload = json.loads(stored["payload_json"])
        if stored_payload != session:
            self._error(HTTPStatus.CONFLICT, "session_id_conflict", "session_id already exists with different content")
            return
        if state == "archived":
            self._json(
                HTTPStatus.OK,
                {"acknowledged": True, "duplicate": True, "archive_state": "archived", "version": self.app.store.current_version()},
            )
            return
        try:
            append_session_artifacts(self.app.config, session, self.app.store.current_plan())
            self.app.store.mark_session(session["session_id"], "artifacts_written")
            refreshed, output = run_refresh(self.app.config)
        except Exception as exc:  # Keep the phone queue until a later retry.
            self.app.store.mark_session(session["session_id"], "archive_failed", str(exc))
            self._error(HTTPStatus.SERVICE_UNAVAILABLE, "archive_failed", str(exc))
            return
        if not refreshed:
            self.app.store.mark_session(session["session_id"], "refresh_failed", output)
            self._error(HTTPStatus.SERVICE_UNAVAILABLE, "pipeline_failed", output[-1000:] or "derived pipeline failed")
            return
        version = self.app.store.mark_session(session["session_id"], "archived")
        self._json(
            HTTPStatus.OK,
            {"acknowledged": True, "duplicate": not inserted, "archive_state": "archived", "version": version},
        )

    def _refresh(self) -> None:
        try:
            refreshed, output = run_refresh(self.app.config)
        except Exception as exc:
            self._error(HTTPStatus.SERVICE_UNAVAILABLE, "pipeline_failed", str(exc))
            return
        if not refreshed:
            self._error(HTTPStatus.SERVICE_UNAVAILABLE, "pipeline_failed", output[-1000:] or "derived pipeline failed")
            return
        self._json(
            HTTPStatus.OK,
            {"acknowledged": True, "duplicate": False, "version": self.app.store.current_version()},
        )

    def _authenticated_device(self) -> str | None:
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "bearer" or not token:
            self._error(HTTPStatus.UNAUTHORIZED, "authorization_required", "bearer token required")
            return None
        device_id = self.app.store.authenticate(token)
        if not device_id:
            self._error(HTTPStatus.UNAUTHORIZED, "invalid_device_token", "device token is invalid")
            return None
        return device_id

    def _read_json(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ContractError("invalid Content-Length") from exc
        if length <= 0 or length > MAX_BODY_BYTES:
            raise ContractError(f"request body must be between 1 and {MAX_BODY_BYTES} bytes")
        try:
            value = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ContractError("request body is not valid UTF-8 JSON") from exc
        if not isinstance(value, dict):
            raise ContractError("request body must be a JSON object")
        return value

    def _error(self, status: HTTPStatus, code: str, message: str) -> None:
        self._json(status, {"error": {"code": code, "message": message}})

    def _json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[kris-companion] " + (fmt % args) + "\n")


def serve(config: CompanionConfig) -> None:
    certificate, private_key = ensure_certificate(config)
    secret = ensure_secret(config)
    store = CompanionStore(config.database_path, secret)
    server = CompanionHTTPServer((config.host, config.port), config, store)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certificate, private_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    bonjour: subprocess.Popen[str] | None = None
    try:
        bonjour = subprocess.Popen(
            ["/usr/bin/dns-sd", "-R", config.service_name, "_kriscoach._tcp", "local", str(config.port), "version=1"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        print(f"Kris companion: https://127.0.0.1:{config.port}")
        print("TLS is required; use companion/pair.py to create a one-time pairing QR.")
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nKris companion stopped.")
    finally:
        server.server_close()
        if bonjour is not None:
            bonjour.terminate()


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the encrypted Kris Mac companion")
    parser.parse_args()
    serve(CompanionConfig())


if __name__ == "__main__":
    main()
