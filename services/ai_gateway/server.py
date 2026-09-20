from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .config import ConfigurationError, GatewayConfig
from .contracts import MAX_REQUEST_BYTES
from .service import GatewayService


SERVER_NAME = "KrisAIGateway"
MAX_HEADER_CONTENT_LENGTH_DIGITS = 12


def make_handler(service: GatewayService) -> type[BaseHTTPRequestHandler]:
    class GatewayHandler(BaseHTTPRequestHandler):
        server_version = SERVER_NAME
        sys_version = ""

        def do_GET(self) -> None:
            if self.path != "/healthz":
                self._write_json(404, _error("not_found", "resource not found"))
                return
            self._write_json(200, {"status": "ok", "service": "kris-ai-gateway"})

        def do_POST(self) -> None:
            if self.path not in {
                "/v1/ai/training-plan-candidates",
                "/v2/ai/training-recommendations",
            }:
                self._write_json(404, _error("not_found", "resource not found"))
                return
            content_type = self.headers.get_content_type()
            if content_type != "application/json":
                self._write_json(415, _error("unsupported_media_type", "application/json is required"))
                return
            try:
                payload = self._read_json_body()
            except RequestBodyError as exc:
                self._write_json(exc.status, _error(exc.code, str(exc)))
                return
            if self.path == "/v2/ai/training-recommendations":
                response = service.generate_recommendation(
                    authorization=self.headers.get("Authorization"), payload=payload,
                )
            else:
                response = service.generate_plan(
                    authorization=self.headers.get("Authorization"), payload=payload,
                )
            self._write_json(response.status, response.body, response.headers)

        def _read_json_body(self) -> Any:
            transfer_encoding = self.headers.get("Transfer-Encoding", "").strip()
            if transfer_encoding:
                raise RequestBodyError(400, "unsupported_transfer_encoding", "chunked request bodies are not supported")
            raw_length = self.headers.get("Content-Length", "").strip()
            if not raw_length or len(raw_length) > MAX_HEADER_CONTENT_LENGTH_DIGITS:
                raise RequestBodyError(411, "content_length_required", "a valid Content-Length is required")
            try:
                length = int(raw_length)
            except ValueError as exc:
                raise RequestBodyError(411, "content_length_required", "a valid Content-Length is required") from exc
            if length < 1:
                raise RequestBodyError(400, "invalid_json", "request body must not be empty")
            if length > MAX_REQUEST_BYTES:
                raise RequestBodyError(413, "request_too_large", "request exceeds the 64 KiB context limit")
            body = self.rfile.read(length)
            if len(body) != length:
                raise RequestBodyError(400, "incomplete_body", "request body is incomplete")
            try:
                return json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise RequestBodyError(400, "invalid_json", "request body must be valid UTF-8 JSON") from exc

        def _write_json(
            self, status: int, body: dict[str, Any], headers: dict[str, str] | None = None,
        ) -> None:
            encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, format: str, *args: object) -> None:
            # Access logs deliberately exclude headers and request bodies. The
            # structured audit sink records only privacy-safe request metadata.
            super().log_message(format, *args)

    return GatewayHandler


class RequestBodyError(ValueError):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code


def _error(code: str, message: str) -> dict[str, Any]:
    return {
        "schema_version": "GatewayError.v1",
        "request_id": "unknown",
        "error": {"code": code, "message": message},
    }


def build_server(config: GatewayConfig) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((config.host, config.port), make_handler(config.make_service()))
    server.daemon_threads = True
    return server


def main() -> int:
    try:
        config = GatewayConfig.from_env()
    except ConfigurationError as exc:
        print(f"configuration error: {exc}")
        return 2
    server = build_server(config)
    print(f"{SERVER_NAME} listening on {config.host}:{config.port} ({config.environment}, {config.provider})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
