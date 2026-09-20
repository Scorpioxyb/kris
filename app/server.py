#!/usr/bin/env python3
"""Local-first server for the Kris coach PWA.

The server deliberately exposes only derived coaching files and read-only CSV
history. It does not upload health data or run a background refresh.
"""

from __future__ import annotations

import csv
import json
import mimetypes
import os
import sys
from datetime import datetime
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


PROJECT = Path(__file__).resolve().parents[1]
APP_DIR = PROJECT / "app"
DATA_DIR = Path(
    os.environ.get(
        "KRIS_VAULT_DATA",
        Path.home() / "Documents" / "Obsidian Vault" / "Kris 健身数据",
    )
)
SNAPSHOT = DATA_DIR / "coach_snapshot.json"


def number(value: Any) -> float | None:
    try:
        if value in (None, "", "-", "—"):
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def read_csv(path: Path, limit: int = 21) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    return rows[-limit:]


def compact_health() -> list[dict[str, Any]]:
    rows = []
    for row in read_csv(DATA_DIR / "每日健康汇总.csv", limit=21):
        if not row.get("date"):
            continue
        rows.append(
            {
                "date": row.get("date"),
                "status": row.get("status", ""),
                "sleep": number(row.get("sleep_hours")),
                "hrv": number(row.get("hrv_sdnn_ms")),
                "rhr": number(row.get("resting_hr_bpm")),
                "steps": number(row.get("steps")),
                "active": number(row.get("active_kcal_used")),
                "training_minutes": number(row.get("training_minutes")),
            }
        )
    return rows


def compact_body() -> list[dict[str, Any]]:
    rows = []
    for row in read_csv(DATA_DIR / "体测记录.csv", limit=21):
        if not row.get("date") or number(row.get("weight_kg")) is None:
            continue
        rows.append(
            {
                "date": row.get("date"),
                "weight": number(row.get("weight_kg")),
                "body_fat": number(row.get("body_fat_pct")),
                "ffm": number(row.get("ffm_kg")),
                "source": row.get("source", ""),
            }
        )
    return rows


def compact_training() -> list[dict[str, Any]]:
    rows = []
    for row in read_csv(DATA_DIR / "训练负荷汇总.csv", limit=42):
        if not row.get("date"):
            continue
        rows.append(
            {
                "date": row.get("date"),
                "status": row.get("status", ""),
                "sessions": number(row.get("session_count")),
                "minutes": number(row.get("recorded_minutes")),
                "load": number(row.get("duration_load_points")),
                "rolling_7d": number(row.get("rolling_7d_load")),
                "weekly_28d": number(row.get("rolling_28d_weekly_average")),
                "ratio": number(row.get("load_ratio_7d_to_28d_weekly")),
                "load_status": row.get("load_status", ""),
                "short_ema": number(row.get("short_term_7d_ema")),
                "long_ema": number(row.get("long_term_42d_ema")),
                "balance": number(row.get("load_balance")),
                "balance_ratio": number(row.get("load_balance_ratio")),
                "model_days": number(row.get("performance_model_days")),
                "model_status": row.get("performance_model_status", ""),
            }
        )
    return rows


def dashboard_payload() -> dict[str, Any]:
    snapshot = read_json(SNAPSHOT)
    brief = snapshot.get("coach_brief", {})
    body = snapshot.get("latest_body", {})
    health = dict(snapshot.get("today_health", {}))
    health_history = compact_health()
    latest_health = next((row for row in reversed(health_history) if row.get("date") == health.get("date")), None)
    if latest_health:
        health.update({"steps": latest_health.get("steps"), "active_kcal": latest_health.get("active")})
    readiness = brief.get("readiness", {})
    plan = brief.get("current_plan") or snapshot.get("decision_support", {}).get("current_plan", {})
    nutrition = snapshot.get("nutrition", {})
    quality = snapshot.get("data_quality", {})
    monitor = snapshot.get("monitor", {})
    training_load = snapshot.get("training_load", {})
    progression = snapshot.get("progression_engine", {})
    cardio = snapshot.get("decision_support", {}).get("cardio_fitness", {})
    return {
        "meta": {
            "generated_at": snapshot.get("generated_at"),
            "timezone": snapshot.get("timezone", "Asia/Shanghai"),
            "snapshot_mtime": datetime.fromtimestamp(SNAPSHOT.stat().st_mtime).astimezone().isoformat(),
            "app_version": "v1.3.0",
            "schema_version": snapshot.get("schema_version"),
        },
        "today": {
            "date": health.get("date") or brief.get("as_of"),
            "status": health.get("status") or brief.get("data_status", {}).get("today_status"),
            "readiness": readiness,
            "health": health,
            "body": body,
            "plan": plan,
            "evidence": brief.get("evidence", []),
            "actions": brief.get("actions", []),
            "alerts": brief.get("alerts", []),
            "data_gaps": brief.get("data_gaps", []),
            "guardrails": brief.get("guardrails", []),
        },
        "trends": {
            "health": health_history,
            "body": compact_body(),
            "training": compact_training(),
        },
        "nutrition": nutrition,
        "training_intelligence": {
            "current_load": {
                "date": training_load.get("date"),
                "status": training_load.get("status"),
                "rolling_7d": number(training_load.get("rolling_7d_load")),
                "weekly_28d": number(training_load.get("rolling_28d_weekly_average")),
                "ratio": number(training_load.get("load_ratio_7d_to_28d_weekly")),
                "load_status": training_load.get("load_status"),
                "short_ema": number(training_load.get("short_term_7d_ema")),
                "long_ema": number(training_load.get("long_term_42d_ema")),
                "balance": number(training_load.get("load_balance")),
                "balance_ratio": number(training_load.get("load_balance_ratio")),
                "model_days": number(training_load.get("performance_model_days")),
                "model_status": training_load.get("performance_model_status"),
                "definition": training_load.get("definition"),
            },
            "progression": {
                "gate_version": progression.get("gate_version"),
                "exercise_count": progression.get("exercise_count"),
                "states": progression.get("states", {}),
                "recent_decisions": progression.get("recent_decisions", []),
            },
            "cardio": {
                "latest_vo2max": number(cardio.get("latest_vo2max")),
                "latest_vo2max_unit": cardio.get("latest_vo2max_unit"),
                "latest_vo2max_at": cardio.get("latest_vo2max_at"),
                "baseline_status": cardio.get("baseline_status"),
            },
        },
        "quality": {
            "overall": monitor.get("overall_data_status"),
            "structured_set_rows": quality.get("structured_set_rows"),
            "recovery_baseline_days": quality.get("recovery_baseline_complete_days"),
            "today_is_partial": quality.get("today_is_partial"),
            "checks": monitor.get("quality_checks", []),
        },
    }


class Handler(SimpleHTTPRequestHandler):
    server_version = "KrisCoach/1.0"

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, directory=str(APP_DIR), **kwargs)

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/api/dashboard":
            self.send_json(dashboard_payload())
            return
        if path == "/healthz":
            self.send_json({"ok": True, "snapshot": SNAPSHOT.exists()})
            return
        if path == "/":
            self.path = "/index.html"
        super().do_GET()

    def send_json(self, payload: dict[str, Any]) -> None:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[kris-app] " + (fmt % args) + "\n")


def main() -> None:
    host = os.environ.get("KRIS_HOST", "127.0.0.1")
    port = int(os.environ.get("KRIS_PORT", "8765"))
    if not SNAPSHOT.exists():
        raise SystemExit(f"找不到教练快照：{SNAPSHOT}")
    server = ThreadingHTTPServer((host, port), Handler)
    display_host = "127.0.0.1" if host == "0.0.0.0" else host
    print(f"Kris V1 running at http://{display_host}:{port}")
    if host == "0.0.0.0":
        print("局域网访问已开启；仅建议在可信 Wi-Fi 使用，不要直接暴露到公网。")
    print("数据源为本机派生文件；不会自动刷新或上传健康数据。")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nKris stopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
