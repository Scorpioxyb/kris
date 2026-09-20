#!/usr/bin/env python3
"""Build data-quality, weekly-review, and symptom-monitoring outputs."""

from __future__ import annotations

import csv
import json
import os
import re
import sqlite3
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path
from statistics import mean
from zoneinfo import ZoneInfo

import build_training_intelligence as intelligence


DATA = Path(
    os.environ.get(
        "KRIS_VAULT_DATA",
        Path.home() / "Documents" / "Obsidian Vault" / "Kris 健身数据",
    )
)
DB = Path(os.environ.get("SYNCHEALTH_DB", Path.home() / ".synchealth" / "health.db"))
TRAINING = DATA / "训练记录.csv"
BODY = DATA / "体测记录.csv"
HEALTH = DATA / "每日健康汇总.csv"
LOAD = DATA / "训练负荷汇总.csv"
VOLUME = DATA / "肌群周训练量.csv"
RECOVERY = DATA / "恢复状态.csv"
FAT_LOSS = DATA / "减脂趋势.csv"
SETS = DATA / "动作组记录.csv"
SNAPSHOT = DATA / "coach_snapshot.json"
CURATED_SYMPTOMS = DATA / "03-专题分析/腰骶与活动度跟踪.md"

QUALITY_OUT = DATA / "数据质量状态.csv"
SYMPTOMS_OUT = DATA / "症状事件.csv"
TRIGGERS_OUT = DATA / "症状触发汇总.csv"
WEEKLY_OUT = DATA / "周教练汇总.csv"
MONITOR_DASHBOARD = DATA / "01-数据看板/教练监控看板.md"
SYMPTOM_DASHBOARD = DATA / "03-专题分析/腰骶触发看板.md"
TZ = ZoneInfo("Asia/Shanghai")


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, fields: list[str], rows: list[dict[str, object]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def number(value: str | None) -> float | None:
    if value is None or not value.strip():
        return None
    try:
        return float(value)
    except ValueError:
        return None


def average(values: list[float]) -> str:
    return "" if not values else f"{mean(values):.2f}"


def week_start(day_text: str) -> str:
    day = date.fromisoformat(day_text)
    return (day - timedelta(days=day.weekday())).isoformat()


def has_non_negated_term(text: str, term: str) -> bool:
    for match in re.finditer(re.escape(term), text):
        boundary = max(text.rfind("；", 0, match.start()), text.rfind("。", 0, match.start()))
        prefix = text[boundary + 1 : match.start()]
        if not re.search(
            r"(?:无|未报告|没有|否认|不伴|尚未明确|未明确|未填写)[^；。]{0,40}$",
            prefix,
        ):
            # A note can state the symptom first and qualify it afterwards,
            # e.g. "胸痛……尚未确认". Unknown is not a positive red flag.
            suffix = text[match.end() :]
            punctuation = re.search(r"[；。]", suffix)
            if punctuation:
                suffix = suffix[: punctuation.start()]
            if re.search(r"(?:尚未确认|尚未明确|未确认|未明确|未报告|未填写|待确认)", suffix[:40]):
                continue
            return True
    return False


def has_non_negated_pattern(text: str, pattern: str) -> bool:
    for match in re.finditer(pattern, text):
        matched = match.group(0)
        if re.search(r"无(?:明显)?不适|无异常|没有不适|未报告|不加重", matched):
            continue
        prefix = text[max(0, match.start() - 5) : match.start()]
        if re.search(r"(?:无|未|没有|否认|不伴).{0,2}$", prefix):
            continue
        return True
    return False


def trigger_tags(session_name: str, notes: str) -> list[str]:
    text = f"{session_name}；{notes}"
    context_rules = [
        ("running", r"跑步|走跑"),
        ("incline_cardio", r"爬坡|坡度走"),
        ("swimming", r"游泳"),
        ("elliptical", r"椭圆"),
        ("leg_press", r"腿举|倒蹬"),
        ("core_control", r"死虫|鸟狗|Pallof|登山者|侧桥"),
        ("bridge_hip_extension", r"臀桥"),
        ("breathing_position", r"90/90|呼吸"),
    ]
    session_rules = [
        ("upper_strength", r"上肢"),
        ("lower_strength", r"下肢"),
        ("high_intensity", r"高强度|中高强度"),
    ]
    tags = [name for name, pattern in context_rules if re.search(pattern, text, re.IGNORECASE)]
    tags.extend(name for name, pattern in session_rules if re.search(pattern, session_name, re.IGNORECASE))
    return tags or ["general_training"]


def symptom_rows(training_rows: list[dict[str, str]]) -> list[dict[str, object]]:
    output: list[dict[str, object]] = []
    positive_rules = [
        ("腰部紧张", r"腰部.{0,6}(?:紧张|紧绷)|腰骶.{0,6}(?:紧张|紧绷)"),
        ("腰部代偿", r"腰部.{0,6}代偿|腰骶.{0,6}代偿"),
        ("腰骶不适", r"腰骶.{0,8}不适|腰部.{0,8}不适"),
        ("腰部乏力", r"腰部.{0,6}(?:没劲|乏力)"),
        ("腰骶受影响", r"(?:动作|训练).{0,12}(?:影响腰骶|腰骶部)"),
    ]
    clear_pattern = re.compile(
        r"(?:腰骶|腰背|腰部).{0,10}(?:无不适|无异常|正常|0/10)|"
        r"(?:训练后|全程|完成后).{0,10}(?:无不适|无异常|一切正常)|本次没有不适"
    )
    red_flag_terms = ["放射痛", "麻木", "无力", "大小便异常", "鞍区麻木", "胸痛", "头晕", "异常心悸"]

    for row in training_rows:
        notes = row.get("notes", "")
        score = number(row.get("low_back_0_10"))
        signals = [label for label, pattern in positive_rules if has_non_negated_pattern(notes, pattern)]
        red_flags = [term for term in red_flag_terms if has_non_negated_term(notes, term)]
        if score is not None and score > 0:
            signals.insert(0, f"腰骶评分{score:g}/10")
        explicit_clear = score == 0 or bool(clear_pattern.search(notes))
        conflict = score == 0 and bool(signals)
        if red_flags:
            status = "red_flag_present"
            severity = "high"
            confidence = "high"
        elif conflict:
            status = "conflicting_record"
            severity = "low"
            confidence = "low"
        elif signals:
            status = "symptom_present"
            severity = "moderate" if score is not None and score >= 4 else "low"
            confidence = "high" if score is not None else "medium"
        elif explicit_clear:
            status = "explicit_clear"
            severity = "none"
            confidence = "medium"
        else:
            status = "not_recorded"
            severity = "unknown"
            confidence = "low"
        output.append(
            {
                "event_id": f"session|{row['date']}|{row['session_name']}",
                "record_type": "session_summary",
                "date": row["date"],
                "session_name": row["session_name"],
                "trigger_tags": ";".join(trigger_tags(row["session_name"], notes)),
                "low_back_score": "" if score is None else f"{score:g}",
                "symptom_status": status,
                "severity": severity,
                "signals": ";".join(dict.fromkeys(signals)),
                "red_flags": ";".join(red_flags),
                "confidence": confidence,
                "source": "训练记录.csv",
            }
        )
    return output


def curated_symptom_rows() -> list[dict[str, object]]:
    text = CURATED_SYMPTOMS.read_text(encoding="utf-8")
    start = text.find("## 已记录反应")
    end = text.find("\n## ", start + 1)
    section = text[start : end if end >= 0 else None]
    output: list[dict[str, object]] = []
    red_flag_terms = ["放射痛", "麻木", "无力", "大小便异常", "鞍区麻木", "胸痛", "头晕", "异常心悸"]
    for line in section.splitlines():
        if not re.match(r"^\| 20\d{2}-\d{2}-\d{2} \|", line):
            continue
        parts = [part.strip() for part in line.strip().strip("|").split("|")]
        if len(parts) != 5:
            continue
        day, action, reaction, red_flag_text, _follow_up = parts
        clear = bool(re.search(r"无不适|均正常|无不良反应|按0/10记录|完全无", reaction))
        positive = bool(re.search(r"不适|紧张|没劲|影响|变硬|发力|代偿", reaction)) and not clear
        red_flags = [term for term in red_flag_terms if has_non_negated_term(red_flag_text, term)]
        score_match = re.search(r"(\d+(?:\.\d+)?)\s*/10", reaction)
        score = float(score_match.group(1)) if score_match else None
        if score is not None and score > 0:
            positive = True
        if red_flags:
            status = "red_flag_present"
            severity = "high"
        elif positive:
            status = "symptom_present"
            severity = "moderate" if score is not None and score >= 4 else "low"
        elif clear:
            status = "explicit_clear"
            severity = "none"
        else:
            status = "not_recorded"
            severity = "unknown"
        signals = [] if not positive else [reaction[:160]]
        output.append(
            {
                "event_id": f"curated|{day}|{action}",
                "record_type": "curated_event",
                "date": day,
                "session_name": action,
                "trigger_tags": ";".join(trigger_tags(action, reaction)),
                "low_back_score": "" if score is None else f"{score:g}",
                "symptom_status": status,
                "severity": severity,
                "signals": ";".join(signals),
                "red_flags": ";".join(red_flags),
                "confidence": "high",
                "source": "腰骶与活动度跟踪.md#已记录反应",
            }
        )
    return output


def trigger_summary(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    stats: defaultdict[str, dict[str, object]] = defaultdict(
        lambda: {"sessions": 0, "recorded": 0, "positive": 0, "red_flags": 0, "last_positive": ""}
    )
    for row in rows:
        for trigger in str(row["trigger_tags"]).split(";"):
            values = stats[trigger]
            values["sessions"] = int(values["sessions"]) + 1
            if row["symptom_status"] != "not_recorded":
                values["recorded"] = int(values["recorded"]) + 1
            if row["symptom_status"] in {"symptom_present", "red_flag_present"}:
                values["positive"] = int(values["positive"]) + 1
                values["last_positive"] = max(str(values["last_positive"]), str(row["date"]))
            if row["symptom_status"] == "red_flag_present":
                values["red_flags"] = int(values["red_flags"]) + 1

    output: list[dict[str, object]] = []
    for trigger, values in stats.items():
        recorded = int(values["recorded"])
        positive = int(values["positive"])
        rate = positive / recorded if recorded else None
        output.append(
            {
                "trigger": trigger,
                "session_count": values["sessions"],
                "symptom_recorded_sessions": recorded,
                "symptom_positive_sessions": positive,
                "positive_rate": "" if rate is None else f"{rate:.2f}",
                "red_flag_sessions": values["red_flags"],
                "last_positive_date": values["last_positive"],
                "confidence": "medium" if recorded >= 3 else "low",
                "definition": "仅明确症状或明确无异常记录；未填写不按无症状处理",
            }
        )
    return sorted(
        output,
        key=lambda row: (
            float(row["positive_rate"]) if row["positive_rate"] != "" else -1,
            int(row["symptom_recorded_sessions"]),
        ),
        reverse=True,
    )


def weekly_rows(
    training_rows: list[dict[str, str]],
    load_rows: list[dict[str, str]],
    volume_rows: list[dict[str, str]],
    health_rows: list[dict[str, str]],
    body_rows: list[dict[str, str]],
    symptoms: list[dict[str, object]],
    today: date,
) -> list[dict[str, object]]:
    weeks: defaultdict[str, dict[str, object]] = defaultdict(
        lambda: {
            "sessions": 0, "strength": 0, "cardio": 0, "minutes": 0.0,
            "missing_duration": 0, "load": 0.0, "direct_sets": 0,
            "sleep": [], "rhr": [], "hrv": [], "recovery_days": 0,
            "weight": [], "symptom_recorded": 0, "symptom_positive": 0, "red_flags": 0,
        }
    )
    for row in training_rows:
        week = week_start(row["date"])
        values = weeks[week]
        values["sessions"] = int(values["sessions"]) + 1
        session_type, _factor = intelligence.classify_session(row["session_name"])
        if session_type.startswith("strength"):
            values["strength"] = int(values["strength"]) + 1
        elif session_type.startswith("cardio") or session_type == "swim":
            values["cardio"] = int(values["cardio"]) + 1
        minutes = intelligence.duration_minutes(row.get("duration", ""))
        if minutes is None:
            values["missing_duration"] = int(values["missing_duration"]) + 1
        else:
            values["minutes"] = float(values["minutes"]) + minutes

    for row in load_rows:
        weeks[week_start(row["date"])]["load"] = float(weeks[week_start(row["date"])]["load"]) + (number(row.get("duration_load_points")) or 0)
    for row in volume_rows:
        weeks[row["week_start"]]["direct_sets"] = int(weeks[row["week_start"]]["direct_sets"]) + int(row["confirmed_direct_sets"])
    for row in health_rows:
        values = weeks[week_start(row["date"])]
        for field, key in (("sleep_hours", "sleep"), ("resting_hr_bpm", "rhr"), ("hrv_sdnn_ms", "hrv")):
            value = number(row.get(field))
            if value is not None:
                cast_values = values[key]
                assert isinstance(cast_values, list)
                cast_values.append(value)
        if row.get("status") == "final" and all(number(row.get(field)) is not None for field in ("sleep_hours", "resting_hr_bpm", "hrv_sdnn_ms")):
            values["recovery_days"] = int(values["recovery_days"]) + 1
    for row in intelligence.comparable_body_rows(body_rows):
        cast_weight = weeks[week_start(row["date"])]["weight"]
        assert isinstance(cast_weight, list)
        cast_weight.append(float(row["weight_kg"]))
    for row in symptoms:
        values = weeks[week_start(str(row["date"]))]
        if row["symptom_status"] != "not_recorded":
            values["symptom_recorded"] = int(values["symptom_recorded"]) + 1
        if row["symptom_status"] in {"symptom_present", "red_flag_present"}:
            values["symptom_positive"] = int(values["symptom_positive"]) + 1
        if row["symptom_status"] == "red_flag_present":
            values["red_flags"] = int(values["red_flags"]) + 1

    current_week = week_start(today.isoformat())
    weeks[current_week]
    output: list[dict[str, object]] = []
    for week, values in sorted(weeks.items()):
        sleep = values["sleep"]
        rhr = values["rhr"]
        hrv = values["hrv"]
        weight = values["weight"]
        assert isinstance(sleep, list) and isinstance(rhr, list) and isinstance(hrv, list) and isinstance(weight, list)
        output.append(
            {
                "week_start": week,
                "status": "current_partial" if week == current_week else "final",
                "training_sessions": values["sessions"],
                "strength_sessions": values["strength"],
                "cardio_sessions": values["cardio"],
                "recorded_minutes": f"{float(values['minutes']):.1f}",
                "duration_load_points": f"{float(values['load']):.1f}",
                "confirmed_direct_sets": values["direct_sets"],
                "average_weight_kg": average(weight),
                "weight_measurements": len(weight),
                "average_sleep_hours": average(sleep),
                "sleep_measurements": len(sleep),
                "average_resting_hr_bpm": average(rhr),
                "resting_hr_measurements": len(rhr),
                "average_hrv_ms": average(hrv),
                "hrv_measurements": len(hrv),
                "complete_recovery_days": values["recovery_days"],
                "symptom_recorded_sessions": values["symptom_recorded"],
                "symptom_positive_sessions": values["symptom_positive"],
                "red_flag_sessions": values["red_flags"],
                "missing_duration_sessions": values["missing_duration"],
            }
        )
    return output


def quality_rows(
    db: sqlite3.Connection,
    training_rows: list[dict[str, str]],
    health_rows: list[dict[str, str]],
    set_rows: list[dict[str, str]],
    recovery_rows: list[dict[str, str]],
    fat_rows: list[dict[str, str]],
    symptoms: list[dict[str, object]],
    today: date,
) -> list[dict[str, object]]:
    output: list[dict[str, object]] = []

    def add(check_id: str, category: str, source: str, latest: str, count: int, status: str, severity: str, evidence: str, impact: str, remediation: str) -> None:
        output.append(
            {
                "check_id": check_id,
                "category": category,
                "source": source,
                "latest_date": latest,
                "row_count": count,
                "status": status,
                "severity": severity,
                "evidence": evidence,
                "impact": impact,
                "remediation": remediation,
            }
        )

    daily_count, daily_latest = db.execute("SELECT count(*), max(day) FROM daily").fetchone()
    add("synchealth_daily_freshness", "freshness", "health.db/daily", daily_latest or "", daily_count, "pass" if daily_latest == today.isoformat() else "warning", "high" if daily_latest != today.isoformat() else "none", f"最新日期={daily_latest}", "影响当天恢复与活动判断", "在SyncHealth点击syncnow")

    quartet = db.execute(
        """
        SELECT max(weight.day)
        FROM samples weight
        JOIN samples fat ON fat.day=weight.day AND fat.at=weight.at
        JOIN samples lean ON lean.day=weight.day AND lean.at=weight.at
        JOIN samples bmi ON bmi.day=weight.day AND bmi.at=weight.at
        WHERE weight.metric='BodyMass' AND fat.metric='BodyFatPercentage'
          AND lean.metric='LeanBodyMass' AND bmi.metric='BodyMassIndex'
        """
    ).fetchone()[0]
    add("body_quartet_freshness", "freshness", "health.db/samples", quartet or "", 1 if quartet else 0, "pass" if quartet == today.isoformat() else "warning", "medium" if quartet != today.isoformat() else "none", f"最新完整四项体测={quartet}", "影响体重体脂趋势", "晨起称重后同步")

    health_latest = health_rows[-1]
    add("daily_summary_current", "freshness", "每日健康汇总.csv", health_latest["date"], len(health_rows), "partial" if health_latest["status"] == "partial" else "pass", "none", f"最新行status={health_latest['status']}", "当天数据不可作日结", "当天结束后再次同步")

    usable_energy = [row for row in health_rows if row.get("status") == "final" and row.get("estimated_total_kcal")]
    energy_latest = usable_energy[-1]["date"] if usable_energy else ""
    energy_current = bool(energy_latest and (today - date.fromisoformat(energy_latest)).days <= 1)
    energy_status = "pass" if energy_current and len(usable_energy) >= 7 else "info" if energy_current else "warning"
    energy_severity = "none" if energy_status == "pass" else "low" if energy_status == "info" else "medium"
    add("energy_complete_day", "coverage", "每日健康汇总.csv", energy_latest, len(usable_energy), energy_status, energy_severity, f"可用完整TDEE日={len(usable_energy)}/至少7日趋势", "影响热量趋势校准", "继续累积完整手表日")

    recent_start = today - timedelta(days=7)
    coverage_gaps = [row for row in health_rows if date.fromisoformat(row["date"]) >= recent_start and row.get("status") == "final" and int(row.get("training_count") or 0) > 0 and int(row.get("healthkit_workout_count") or 0) == 0]
    add("healthkit_workout_coverage", "consistency", "训练记录.csv ↔ health.db/workouts", max((row["date"] for row in coverage_gaps), default=""), len(coverage_gaps), "warning" if coverage_gaps else "pass", "medium" if coverage_gaps else "none", "缺口日期=" + ",".join(row["date"] for row in coverage_gaps), "这些日期不生成TDEE", "保持手表运动记录并在训练后同步")

    set_keys = [(row["date"], row["session_name"], row["exercise"], row["equipment_variant"], row["set_index"]) for row in set_rows]
    duplicates = len(set_keys) - len(set(set_keys))
    add("structured_set_uniqueness", "uniqueness", "动作组记录.csv", max((row["date"] for row in set_rows), default=""), len(set_rows), "pass" if duplicates == 0 else "fail", "critical" if duplicates else "none", f"重复复合键={duplicates}", "重复会放大容量和进阶", "修复解析器后重建")

    baseline_days = int(recovery_rows[-1]["baseline_complete_days"])
    add("recovery_baseline", "coverage", "恢复状态.csv", recovery_rows[-1]["date"], baseline_days, "info" if baseline_days < 14 else "pass", "low", f"完整日={baseline_days}/14", "基线不足时不输出正式恢复分级", "继续佩戴手表睡眠并每日同步")

    plateau_status = fat_rows[-1]["plateau_status"]
    add("fat_loss_plateau_window", "coverage", "减脂趋势.csv", fat_rows[-1]["as_of"], int(fat_rows[-1]["recent_7d_measurements"]), "info" if plateau_status.startswith("insufficient") else "pass", "low", f"状态={plateau_status}", "证据不足时不下调热量", "继续晨起同口径称重并补同情境腰围")

    vo2_count, vo2_latest = db.execute(
        "SELECT count(*), max(day) FROM samples WHERE lower(metric)='vo2max'"
    ).fetchone()
    vo2_status = "info" if vo2_count == 0 else "pass"
    add("cardio_fitness_coverage", "coverage", "health.db/samples", vo2_latest or "", vo2_count, vo2_status, "low" if vo2_count == 0 else "none", f"VO2Max记录={vo2_count}", "少于3条时仅建立基线，不判断趋势", "继续自然积累；标准测试另行安排")

    recorded_symptoms = sum(row["symptom_status"] != "not_recorded" for row in symptoms)
    symptom_rate = recorded_symptoms / len(symptoms) if symptoms else 0
    add("symptom_feedback_coverage", "completeness", "训练记录.csv", max((str(row["date"]) for row in symptoms), default=""), recorded_symptoms, "pass" if symptom_rate >= 0.7 else "warning", "medium" if symptom_rate < 0.7 else "none", f"明确记录={recorded_symptoms}/{len(symptoms)} ({symptom_rate:.0%})", "缺失会降低触发统计可信度", "训练后填写腰骶和异常反应")
    return output


def overall_quality(rows: list[dict[str, object]]) -> str:
    if any(row["status"] == "fail" or row["severity"] in {"critical", "high"} and row["status"] == "warning" for row in rows):
        return "blocked_or_stale"
    if any(row["status"] == "warning" for row in rows):
        return "usable_with_known_gaps"
    return "healthy"


def write_dashboards(
    quality: list[dict[str, object]],
    weekly: list[dict[str, object]],
    symptoms: list[dict[str, object]],
    triggers: list[dict[str, object]],
    today: date,
) -> None:
    current_week = weekly[-1]
    status = overall_quality(quality)
    quality_labels = {
        "synchealth_daily_freshness": "手机健康当日新鲜度",
        "body_quartet_freshness": "晨起完整体测",
        "daily_summary_current": "每日健康汇总",
        "energy_complete_day": "完整能量日覆盖",
        "healthkit_workout_coverage": "手表运动覆盖",
        "structured_set_uniqueness": "动作组唯一性",
        "recovery_baseline": "恢复基线",
        "fat_loss_plateau_window": "减脂平台窗口",
        "cardio_fitness_coverage": "心肺能力覆盖",
        "symptom_feedback_coverage": "症状反馈完整度",
    }
    trigger_labels = {
        "general_training": "综合训练",
        "core_control": "核心控制动作",
        "lower_strength": "下肢力量",
        "upper_strength": "上肢力量",
        "breathing_position": "呼吸/体位",
        "bridge_hip_extension": "臀桥/髋伸",
        "running": "跑步",
        "incline_cardio": "爬坡有氧",
        "high_intensity": "高强度有氧",
        "leg_press": "腿举/倒蹬",
        "swimming": "游泳",
        "elliptical": "椭圆机",
    }
    monitor = [
        "---",
        'title: "教练监控看板"',
        "type: fitness-coaching-monitor",
        f"updated: {today.isoformat()}",
        "source: 数据质量状态.csv, 周教练汇总.csv, 症状事件.csv",
        "---",
        "",
        "# 教练监控看板",
        "",
        "[[总览|← 返回总览]]　[[训练智能看板]]　[[训练决策看板]]　[[健康日结看板]]　[[腰骶触发看板]]",
        "",
        "> [!tldr] 当前状态",
        f"> 数据状态 `{status}`。本周{current_week['training_sessions']}次训练、{current_week['recorded_minutes']}分钟、{current_week['confirmed_direct_sets']}个明确直接组；恢复完整日{current_week['complete_recovery_days']}天。",
        "",
        "## 本周教练输入",
        "",
        "| 力量 | 有氧 | 时长 | 负荷点 | 直接组 | 均重 | 睡眠 | 症状有记录/阳性 |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|",
        f"| {current_week['strength_sessions']} | {current_week['cardio_sessions']} | {current_week['recorded_minutes']}分 | {current_week['duration_load_points']} | {current_week['confirmed_direct_sets']} | {current_week['average_weight_kg'] or '—'}kg | {current_week['average_sleep_hours'] or '—'}h（{current_week['sleep_measurements']}晚） | {current_week['symptom_recorded_sessions']}/{current_week['symptom_positive_sessions']} |",
        "",
        "## 数据质量",
        "",
        "| 检查 | 状态 | 证据 | 影响/处理 |",
        "|---|---|---|---|",
    ]
    for row in quality:
        monitor.append(f"| {quality_labels.get(str(row['check_id']), row['check_id'])} | {row['status']} | {row['evidence'] or '—'} | {row['impact']}；{row['remediation']} |")
    monitor.extend(
        [
            "",
            "> [!note] 解释",
            "> `partial`表示当天尚未结束；`info`表示功能仍在建立，不是故障；`warning`表示数据可用但必须带缺口解释。",
            "",
        ]
    )
    MONITOR_DASHBOARD.write_text("\n".join(monitor), encoding="utf-8")

    session_symptoms = [row for row in symptoms if row.get("record_type") == "session_summary"]
    curated_symptoms = [row for row in symptoms if row.get("record_type") == "curated_event"]
    positive_source = curated_symptoms or session_symptoms
    recent_positive = [row for row in positive_source if row["symptom_status"] in {"symptom_present", "red_flag_present"}][-10:]
    symptom_lines = [
        "---",
        'title: "腰骶触发看板"',
        "type: fitness-symptom-dashboard",
        f"updated: {today.isoformat()}",
        "source: 症状事件.csv, 症状触发汇总.csv",
        "---",
        "",
        "# 腰骶触发看板",
        "",
        "[[腰骶与活动度跟踪|← 返回腰骶专题]]　[[教练监控看板]]　[[训练智能看板]]",
        "",
        "> [!warning] 使用边界",
        "> 本看板只整理训练档案里的明确描述，不诊断组织或病因；“未填写”不会被当成“无症状”。",
        "",
        "## 情境统计",
        "",
        "| 情境 | 有记录训练 | 阳性训练 | 阳性率 | 最近阳性 | 可信度 |",
        "|---|---:|---:|---:|---|---|",
    ]
    for row in triggers:
        if int(row["symptom_recorded_sessions"]) == 0:
            continue
        rate = "—" if row["positive_rate"] == "" else f"{float(row['positive_rate']):.0%}"
        symptom_lines.append(f"| {trigger_labels.get(str(row['trigger']), row['trigger'])} | {row['symptom_recorded_sessions']} | {row['symptom_positive_sessions']} | {rate} | {row['last_positive_date'] or '—'} | {row['confidence']} |")
    symptom_lines.extend(["", "## 最近明确症状", "", "| 日期 | 训练 | 情境 | 信号 | 严重度 |", "|---|---|---|---|---|"])
    if recent_positive:
        for row in reversed(recent_positive):
            readable_triggers = "；".join(trigger_labels.get(value, value) for value in str(row["trigger_tags"]).split(";"))
            symptom_lines.append(f"| {row['date']} | {row['session_name']} | {readable_triggers} | {row['signals'] or row['red_flags']} | {row['severity']} |")
    else:
        symptom_lines.append("| — | — | — | 当前训练档案无明确阳性症状 | — |")
    symptom_lines.extend(["", "## 记录完整度", "", f"- 训练级记录中已明确填写症状或无异常：{sum(row['symptom_status'] != 'not_recorded' for row in session_symptoms)}/{len(session_symptoms)}次。", f"- 腰骶专题人工复核事件：{len(curated_symptoms)}条；情境触发率优先使用这些事件。", "- 统计是下限；后续优先补训练中、训练后2小时和次日起床三个时点。", ""])
    SYMPTOM_DASHBOARD.write_text("\n".join(symptom_lines), encoding="utf-8")


def main() -> int:
    today = datetime.now(TZ).date()
    required = (TRAINING, BODY, HEALTH, LOAD, VOLUME, RECOVERY, FAT_LOSS, SETS, SNAPSHOT, CURATED_SYMPTOMS, DB)
    for path in required:
        if not path.is_file():
            raise SystemExit(f"缺少数据源: {path}")

    training = read_csv(TRAINING)
    body = read_csv(BODY)
    health = read_csv(HEALTH)
    load = read_csv(LOAD)
    volume = read_csv(VOLUME)
    recovery = read_csv(RECOVERY)
    fat_loss = read_csv(FAT_LOSS)
    sets = read_csv(SETS)

    session_symptoms = symptom_rows(training)
    curated_symptoms = curated_symptom_rows()
    symptoms = session_symptoms + curated_symptoms
    triggers = trigger_summary(curated_symptoms or session_symptoms)
    weekly = weekly_rows(training, load, volume, health, body, session_symptoms, today)
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        quality = quality_rows(db, training, health, sets, recovery, fat_loss, session_symptoms, today)
    finally:
        db.close()

    write_csv(
        SYMPTOMS_OUT,
        ["event_id", "record_type", "date", "session_name", "trigger_tags", "low_back_score", "symptom_status", "severity", "signals", "red_flags", "confidence", "source"],
        symptoms,
    )
    write_csv(
        TRIGGERS_OUT,
        ["trigger", "session_count", "symptom_recorded_sessions", "symptom_positive_sessions", "positive_rate", "red_flag_sessions", "last_positive_date", "confidence", "definition"],
        triggers,
    )
    write_csv(
        WEEKLY_OUT,
        ["week_start", "status", "training_sessions", "strength_sessions", "cardio_sessions", "recorded_minutes", "duration_load_points", "confirmed_direct_sets", "average_weight_kg", "weight_measurements", "average_sleep_hours", "sleep_measurements", "average_resting_hr_bpm", "resting_hr_measurements", "average_hrv_ms", "hrv_measurements", "complete_recovery_days", "symptom_recorded_sessions", "symptom_positive_sessions", "red_flag_sessions", "missing_duration_sessions"],
        weekly,
    )
    write_csv(
        QUALITY_OUT,
        ["check_id", "category", "source", "latest_date", "row_count", "status", "severity", "evidence", "impact", "remediation"],
        quality,
    )
    write_dashboards(quality, weekly, symptoms, triggers, today)

    snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    snapshot["monitor"] = {
        "generated_at": datetime.now(TZ).isoformat(timespec="seconds"),
        "overall_data_status": overall_quality(quality),
        "current_week": weekly[-1],
        "quality_checks": quality,
        "top_symptom_triggers": triggers[:5],
        "symptom_feedback_coverage": {
            "recorded_sessions": sum(row["symptom_status"] != "not_recorded" for row in session_symptoms),
            "total_sessions": len(session_symptoms),
        },
    }
    SNAPSHOT.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"数据质量检查: {len(quality)}项，状态={overall_quality(quality)}")
    print(f"症状事件: 训练汇总{len(session_symptoms)}行＋专项事件{len(curated_symptoms)}行")
    print(f"触发情境: {len(triggers)}类")
    print(f"周汇总: {len(weekly)}周，当前周训练={weekly[-1]['training_sessions']}次")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
