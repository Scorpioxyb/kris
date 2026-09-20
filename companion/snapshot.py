from __future__ import annotations

import json
import csv
import hashlib
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from companion.config import CompanionConfig
from companion.readiness import ReadinessEngine
from companion.store import CompanionStore


def _read(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def _points(path: Path, field: str, limit: int = 42) -> list[dict[str, Any]]:
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            rows = list(csv.DictReader(handle))
    except OSError:
        return []
    points: list[dict[str, Any]] = []
    for row in rows:
        try:
            value = float(row.get(field) or "")
        except ValueError:
            continue
        if row.get("date"):
            points.append({"date": row["date"], "value": value})
    return points[-limit:]


def _number(value: Any) -> float | None:
    try:
        return float(value) if str(value).strip() else None
    except (TypeError, ValueError):
        return None


def _median(values: list[float]) -> float | None:
    ordered = sorted(values)
    if not ordered:
        return None
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def _readiness_history(
    health_path: Path, load_path: Path, limit: int = 42
) -> list[dict[str, Any]]:
    try:
        with health_path.open("r", encoding="utf-8-sig", newline="") as handle:
            rows = sorted(
                (row for row in csv.DictReader(handle) if row.get("date")),
                key=lambda row: str(row["date"]),
            )
    except OSError:
        return []
    try:
        with load_path.open("r", encoding="utf-8-sig", newline="") as handle:
            load_by_date = {
                str(row.get("date")): _number(row.get("load_ratio_7d_to_28d_weekly"))
                for row in csv.DictReader(handle)
                if row.get("date")
            }
    except OSError:
        load_by_date = {}

    engine = ReadinessEngine.load()
    history: list[dict[str, Any]] = []
    for index, row in enumerate(rows):
        prior = [item for item in rows[:index] if item.get("status") == "final"]
        sleep_history = [
            value for value in (_number(item.get("sleep_hours")) for item in prior)
            if value is not None
        ][-14:]
        hrv_history = [
            value for value in (_number(item.get("hrv_sdnn_ms")) for item in prior)
            if value is not None
        ][-14:]
        rhr_history = [
            value for value in (_number(item.get("resting_hr_bpm")) for item in prior)
            if value is not None
        ][-14:]
        current = {
            "sleep": _number(row.get("sleep_hours")),
            "hrv": _number(row.get("hrv_sdnn_ms")),
            "rhr": _number(row.get("resting_hr_bpm")),
        }
        history_counts = {
            "sleep": len(sleep_history), "hrv": len(hrv_history), "rhr": len(rhr_history),
        }
        complete_days = sum(
            _number(item.get("sleep_hours")) is not None
            and _number(item.get("hrv_sdnn_ms")) is not None
            and _number(item.get("resting_hr_bpm")) is not None
            for item in prior
        )
        usable_baselines = sum(value >= 5 for value in history_counts.values()) >= 2
        result = engine.evaluate({
            **current,
            "sleep_baseline": _median(sleep_history),
            "hrv_baseline": _median(hrv_history),
            "rhr_baseline": _median(rhr_history),
            "load_ratio": load_by_date.get(str(row["date"])),
            "today_status": row.get("status") or "final",
            "data_quality": "pass" if len([v for v in current.values() if v is not None]) == 3 and usable_baselines else "warning",
            "baseline_days": min(complete_days, 14),
            "history_counts": history_counts,
            "fresh": any(value is not None for value in current.values()),
            "pain": 0,
            "flags": [],
        })
        if result.score is None:
            continue
        history.append({
            "date": str(row["date"]),
            "score": result.score,
            "state": result.state,
            "confidence": result.confidence,
            "source": "mac_derived",
        })
    return history[-limit:]


def _decision_trace(brief: dict[str, Any]) -> dict[str, Any] | None:
    if not brief:
        return None
    readiness = brief.get("readiness") if isinstance(brief.get("readiness"), dict) else {}
    plan = brief.get("current_plan") if isinstance(brief.get("current_plan"), dict) else {}
    actions = [str(item) for item in brief.get("actions") or [] if str(item).strip()]
    score = _number(readiness.get("score"))
    label = str(readiness.get("label") or "").strip()
    summary = label
    if score is not None:
        summary = f"准备度 {score:g} 分" + (f" · {label}" if label else "")
    if not summary and not actions and not plan:
        return None
    return {
        "as_of": brief.get("as_of"),
        "summary": summary or "已生成本次训练决策",
        "actions": actions,
        "plan_basis": plan.get("prescription_basis"),
        "adjustment_note": plan.get("adjustment_note"),
    }


def _duration_minutes(value: Any) -> float | None:
    parts = str(value or "").strip().split(":")
    if len(parts) != 3:
        return None
    try:
        hours, minutes, seconds = (float(part) for part in parts)
    except ValueError:
        return None
    return round(hours * 60 + minutes + seconds / 60, 1)


def _training_history(path: Path, limit: int = 30) -> list[dict[str, Any]]:
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            rows = list(csv.DictReader(handle))
    except OSError:
        return []
    summaries: list[dict[str, Any]] = []
    for index, row in enumerate(rows):
        date = str(row.get("date") or "").strip()
        title = str(row.get("session_name") or "").strip()
        if not date or not title:
            continue
        notes = str(row.get("notes") or "")
        app_marker = re.search(r"\[app_session_id=([^\]]+)\]", notes)
        if app_marker:
            identifier = app_marker.group(1)
            source = "kris_coach_app"
        else:
            identity = f"{date}|{title}|{row.get('duration') or ''}|{index}"
            identifier = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:24]
            source = "obsidian_archive"
        summaries.append({
            "id": identifier,
            "date": date,
            "title": title,
            "duration_minutes": _duration_minutes(row.get("duration")),
            "active_kcal": _number(row.get("active_kcal")),
            "average_heart_rate": _number(row.get("avg_hr")),
            "maximum_heart_rate": _number(row.get("max_hr")),
            "exercise_count": None,
            "completed_set_count": None,
            "status": "archived",
            "source": source,
            "synced_to_mac": True,
        })
    return summaries[-limit:][::-1]


def build_snapshot(config: CompanionConfig, store: CompanionStore) -> dict[str, Any]:
    machine = _read(config.vault_dir / "coach_snapshot.json")
    brief = _read(config.vault_dir / "coach_brief.json")
    readiness = brief.get("readiness") or machine.get("coach_brief", {}).get("readiness") or {}
    current_plan = store.current_plan()
    return {
        "schema_version": "CoachSnapshot.v1",
        "version": store.current_version(),
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "readiness": {
            "score": readiness.get("score"),
            "state": readiness.get("state") or "insufficient_data",
            "label": readiness.get("label") or "数据不足，暂不自动调整",
            "confidence": readiness.get("confidence") or "low",
            "safety_gate": readiness.get("safety_gate") or "normal",
            "components": readiness.get("components") or {},
        },
        "evidence": brief.get("evidence") or [],
        "data_gaps": brief.get("data_gaps") or ["Mac 尚未生成教练简报"],
        "training_load": machine.get("training_load") or {},
        "progression": (machine.get("progression") or {}).get("recent_decisions", []) if isinstance(machine.get("progression"), dict) else [],
        "trends": {
            "latest_body": machine.get("latest_body") or {},
            "latest_complete_health_day": machine.get("latest_complete_health_day") or {},
            "recovery": machine.get("recovery") or {},
            "fat_loss": machine.get("fat_loss") or {},
            "weight": _points(config.vault_dir / "每日健康汇总.csv", "weight_kg"),
            "body_fat": _points(config.vault_dir / "每日健康汇总.csv", "body_fat_pct"),
            "sleep": _points(config.vault_dir / "每日健康汇总.csv", "sleep_hours"),
            "training_load_7d": _points(config.vault_dir / "训练负荷汇总.csv", "short_term_7d_ema"),
            "training_load_42d": _points(config.vault_dir / "训练负荷汇总.csv", "long_term_42d_ema"),
            "readiness": _readiness_history(
                config.vault_dir / "每日健康汇总.csv",
                config.vault_dir / "训练负荷汇总.csv",
            ),
        },
        "recent_training": _training_history(config.vault_dir / "训练记录.csv"),
        "decision_trace": _decision_trace(brief),
        "current_plan": current_plan,
    }
