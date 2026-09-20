from __future__ import annotations

import csv
import fcntl
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from companion.config import CompanionConfig


TRAINING_FIELDS = [
    "date", "session_name", "location", "equipment", "duration", "active_kcal", "total_kcal",
    "avg_hr", "max_hr", "hr_zones", "training_effect_aerobic", "training_effect_anaerobic",
    "training_load", "recovery_hours", "breath_0_10", "legs_glutes_0_10", "upper_body_0_10",
    "low_back_0_10", "overall_0_10", "notes",
]
FEELING_LABELS = {
    "easy": "轻松", "appropriate": "合适", "very_hard": "很吃力", "form_breakdown": "动作变形",
}
ENERGY_LABELS = {
    "good": "精力良好", "normal": "精力正常", "slightly_tired": "稍微疲惫",
    "exhausted": "明显疲惫", "not_recorded": "精力未记录",
}


def _duration(start: str, end: str) -> str:
    start_at = datetime.fromisoformat(start.replace("Z", "+00:00"))
    end_at = datetime.fromisoformat(end.replace("Z", "+00:00"))
    seconds = max(0, int((end_at - start_at).total_seconds()))
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def _exercise_summary(session: dict[str, Any]) -> str:
    summaries: list[str] = []
    for exercise in session.get("exercise_results", []):
        sets: list[str] = []
        for item in exercise.get("sets", []):
            weight = item.get("weight_kg")
            prefix = f"{weight:g}kg×" if isinstance(weight, (int, float)) else ""
            text = f"{prefix}{item.get('reps', 0)}"
            feeling = item.get("last_set_feeling")
            if feeling:
                text += f"（{FEELING_LABELS.get(feeling, feeling)}）"
            sets.append(text)
        actual_name = str(exercise.get("name") or "未命名动作")
        actual_equipment = str(exercise.get("equipment_variant") or "")
        identity = f"{actual_name}·{actual_equipment}" if actual_equipment else actual_name
        summaries.append(identity + " " + "/".join(sets))
    return "；".join(summaries)


def _adjustment_summary(session: dict[str, Any]) -> str:
    changes: list[str] = []
    for exercise in session.get("exercise_results", []):
        planned = exercise.get("planned") or {}
        planned_name = str(planned.get("name") or "")
        planned_equipment = str(planned.get("equipment_variant") or "")
        actual_name = str(exercise.get("name") or "")
        actual_equipment = str(exercise.get("equipment_variant") or "")
        if planned_name and (
            planned_name != actual_name or planned_equipment != actual_equipment
        ):
            changes.append(
                f"计划 {planned_name}·{planned_equipment} → 实际 {actual_name}·{actual_equipment}"
            )
    return "、".join(dict.fromkeys(changes))


def _notes(session: dict[str, Any]) -> str:
    feedback = session.get("feedback") or {}
    parts = [f"[app_session_id={session['session_id']}]", _exercise_summary(session)]
    if adjustments := _adjustment_summary(session):
        parts.append(f"现场调整：{adjustments}")
    parts.append(ENERGY_LABELS.get(feedback.get("energy"), str(feedback.get("energy") or "精力未记录")))
    if feedback.get("target_muscle_response") == "good":
        parts.append("目标肌群反应可以")
    elif feedback.get("target_muscle_response") == "weak":
        parts.append("目标肌群反应偏弱")
    symptoms = str(feedback.get("symptoms") or "").strip()
    if symptoms:
        parts.append(f"症状：{symptoms}")
    extra = str(feedback.get("notes") or "").strip()
    if extra:
        parts.append(extra)
    parts.append("由 Kris App 实际记录；未填写字段保持空白。")
    return "；".join(part for part in parts if part)


def append_session_artifacts(config: CompanionConfig, session: dict[str, Any], plan: dict[str, Any] | None) -> None:
    config.vault_dir.mkdir(parents=True, exist_ok=True)
    jsonl_path = config.vault_dir / "App训练会话.jsonl"
    session_marker = f'"session_id":"{session["session_id"]}"'
    canonical = json.dumps(session, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    with jsonl_path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        if session_marker not in handle.read():
            handle.seek(0, 2)
            handle.write(canonical + "\n")
            handle.flush()
        fcntl.flock(handle, fcntl.LOCK_UN)

    csv_path = config.vault_dir / "训练记录.csv"
    if not csv_path.is_file():
        raise FileNotFoundError(f"missing training archive: {csv_path}")
    workout = session.get("workout") or {}
    started = datetime.fromisoformat(session["started_at"].replace("Z", "+00:00")).astimezone(ZoneInfo("Asia/Shanghai"))
    equipment = ";".join(dict.fromkeys(str(item.get("equipment_variant") or "") for item in session.get("exercise_results", []) if item.get("equipment_variant")))
    row = {
        "date": started.date().isoformat(),
        "session_name": (plan or {}).get("title") or "Kris App 训练",
        "location": "App记录",
        "equipment": equipment,
        "duration": _duration(session["started_at"], session["ended_at"]),
        "active_kcal": workout.get("active_kcal") or "",
        "total_kcal": "",
        "avg_hr": workout.get("average_heart_rate") or "",
        "max_hr": workout.get("maximum_heart_rate") or "",
        "notes": _notes(session),
    }
    with csv_path.open("a+", encoding="utf-8-sig", newline="") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        existing = handle.read()
        if f"[app_session_id={session['session_id']}]" not in existing:
            handle.seek(0, 2)
            writer = csv.DictWriter(handle, fieldnames=TRAINING_FIELDS, extrasaction="ignore")
            writer.writerow(row)
            handle.flush()
        fcntl.flock(handle, fcntl.LOCK_UN)


def run_refresh(config: CompanionConfig, timeout: int = 300) -> tuple[bool, str]:
    if not config.refresh_script.is_file():
        return False, f"refresh script not found: {config.refresh_script}"
    result = subprocess.run(
        [sys.executable, str(config.refresh_script)],
        cwd=config.refresh_script.parent.parent,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    output = (result.stdout + "\n" + result.stderr).strip()
    return result.returncode == 0, output[-8000:]
