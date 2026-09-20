#!/usr/bin/env python3
"""Build an explainable, quality-gated daily coaching brief.

This is a decision layer, not a medical score. It combines the latest
HealthKit summary, personal baselines, recent load, workflow state, and data
freshness into a small contract for a widget, website, or chat response.
"""

from __future__ import annotations

import csv
import json
import math
import os
from datetime import date, datetime
from pathlib import Path
from statistics import median
from typing import Any
from zoneinfo import ZoneInfo


DATA = Path(
    os.environ.get(
        "KRIS_VAULT_DATA",
        Path.home() / "Documents" / "Obsidian Vault" / "Kris 健身数据",
    )
)
HEALTH = DATA / "每日健康汇总.csv"
TRAINING = DATA / "训练记录.csv"
SNAPSHOT = DATA / "coach_snapshot.json"
WORKFLOW = DATA / "训练流程状态.json"
RAW = Path(os.environ.get("SYNCHEALTH_RAW", Path.home() / ".synchealth" / "raw"))
BRIEF_JSON = DATA / "coach_brief.json"
BRIEF_MD = DATA / "01-数据看板/今日教练简报.md"
TZ = ZoneInfo("Asia/Shanghai")


def number(value: Any) -> float | None:
    if value in (None, ""):
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def clamp(value: float, low: float = 0.0, high: float = 100.0) -> float:
    return round(max(low, min(high, value)), 1)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def latest_raw_upload() -> dict[str, Any]:
    files = list(RAW.glob("*.json")) if RAW.is_dir() else []
    if not files:
        return {"at": None, "file_count": 0}
    latest = max(files, key=lambda path: path.stat().st_mtime)
    return {
        "at": datetime.fromtimestamp(latest.stat().st_mtime, TZ).isoformat(timespec="seconds"),
        "file_count": len(files),
    }


def baseline_values(
    rows: list[dict[str, str]], field: str, today: str, limit: int = 14
) -> list[float]:
    values: list[float] = []
    for row in rows:
        if row.get("date", "") >= today or row.get("status") != "final":
            continue
        value = number(row.get(field))
        if value is not None:
            values.append(value)
    return values[-limit:]


def component_score(
    value: float | None,
    baseline: float | None,
    scale: float,
    neutral: float = 50.0,
) -> float | None:
    if value is None:
        return None
    if baseline is None:
        return neutral
    return clamp(neutral + (value - baseline) * scale)


def readiness_decision(
    score: float | None, today_status: str, data_quality: str
) -> dict[str, str]:
    if score is None:
        return {
            "state": "insufficient_data",
            "label": "数据不足，暂不自动调整",
            "action": "维持已确认计划，不加重；先补齐睡眠、体测或训练反馈。",
        }
    if score >= 78:
        state, label, action = (
            "train_progress",
            "可推进",
            "按已确认计划训练；只有同器械连续两次达标且反馈轻松/合适时才开放最小档加重。",
        )
    elif score >= 62:
        state, label, action = (
            "train_maintain",
            "可训练，维持负荷",
            "完成计划但不主动加重；末组保持动作稳定，出现变形就降阶。",
        )
    elif score >= 45:
        state, label, action = (
            "train_reduce",
            "可训练，但降阶",
            "保留动作模式，减少一组或降低一个小档；不做力竭和高强度有氧。",
        )
    else:
        state, label, action = (
            "recover_or_light",
            "恢复优先",
            "不加重；若必须训练只做技术/低强度活动，等睡眠和次日反馈恢复后再回到正式容量。",
        )
    if today_status == "partial" or data_quality != "pass":
        label += "（临时）"
    return {"state": state, "label": label, "action": action}


def confidence_label(
    today_status: str,
    baseline_days: int,
    component_counts: dict[str, int],
    freshness_at: str | None,
) -> str:
    complete_components = sum(count >= 5 for count in component_counts.values())
    if today_status == "final" and baseline_days >= 14 and complete_components >= 3 and freshness_at:
        return "high"
    if baseline_days >= 7 and complete_components >= 2 and freshness_at:
        return "medium"
    return "low"


def weighted_readiness(components: dict[str, float | None]) -> float | None:
    weights = {"sleep": 0.45, "hrv": 0.25, "rhr": 0.15, "load": 0.15}
    available = [
        (components[name], weight)
        for name, weight in weights.items()
        if components.get(name) is not None
    ]
    if not available:
        return None
    total_weight = sum(weight for _, weight in available)
    return clamp(sum(float(value) * weight for value, weight in available) / total_weight)


def latest_complete_body(rows: list[dict[str, str]]) -> dict[str, Any] | None:
    """Use the latest same-timestamp complete quartet from the HealthKit summary."""
    fields = ("weight_kg", "body_fat_pct", "lean_body_mass_kg", "bmi")
    for row in reversed(rows):
        if all(number(row.get(field)) is not None for field in fields):
            return {
                "date": row.get("date"),
                "weight_kg": number(row.get("weight_kg")),
                "body_fat_pct": number(row.get("body_fat_pct")),
                "lean_body_mass_kg": number(row.get("lean_body_mass_kg")),
                "bmi": number(row.get("bmi")),
            }
    return None


def plan_age_days(plan: dict[str, Any] | None, today: str) -> int | None:
    if not isinstance(plan, dict) or not plan.get("date"):
        return None
    try:
        return (date.fromisoformat(today) - date.fromisoformat(str(plan["date"]))).days
    except ValueError:
        return None


def build_alerts(
    today: str,
    today_row: dict[str, str],
    body: dict[str, Any] | None,
    training_rows: list[dict[str, str]],
    current_plan: dict[str, Any] | None,
    baseline_sleep: float | None,
    sleep: float | None,
) -> list[dict[str, Any]]:
    alerts: list[dict[str, Any]] = []
    age = plan_age_days(current_plan, today)
    if current_plan and current_plan.get("status") == "planned" and age is not None and age >= 2:
        alerts.append({
            "id": "stale_current_plan",
            "severity": "high",
            "title": "当前计划已过期，排课被旧状态锁住",
            "evidence": f"计划日期 {current_plan['date']}，距今天 {age} 天，状态仍为 planned",
            "action": "先确认这份计划是否实际完成；若未完成，补齐实绩或明确取消后再生成下一课。",
        })
    latest_training = max((row.get("date", "") for row in training_rows), default="")
    if latest_training and latest_training < today:
        try:
            training_gap = (date.fromisoformat(today) - date.fromisoformat(latest_training)).days
        except ValueError:
            training_gap = 0
        if training_gap >= 4:
            alerts.append({
                "id": "training_record_gap",
                "severity": "medium",
                "title": "训练实绩记录出现断档",
                "evidence": f"训练记录最新日期 {latest_training}，距今天 {training_gap} 天",
                "action": "不要把设备未识别的运动当作未训练；下次训练后补记实际重量×次数和反馈。",
            })
    if body and body.get("date"):
        try:
            body_gap = (date.fromisoformat(today) - date.fromisoformat(str(body["date"]))).days
        except ValueError:
            body_gap = 0
        if body_gap >= 7:
            alerts.append({
                "id": "body_measurement_gap",
                "severity": "low",
                "title": "晨起成套体测较久未更新",
                "evidence": f"最近成套体测 {body['date']}，距今天 {body_gap} 天",
                "action": "继续按同一米家秤、起床后条件测量；在有足够窗口前不改热量目标。",
            })
    if sleep is not None and baseline_sleep is not None and sleep < baseline_sleep - 0.75:
        alerts.append({
            "id": "sleep_restriction",
            "severity": "medium",
            "title": "睡眠是今天的主要训练限制",
            "evidence": f"昨夜 {sleep:.2f}h，个人基线 {baseline_sleep:.2f}h",
            "action": "不加重量、不做力竭；优先补睡，训练只保留技术或低强度活动。",
        })
    return alerts


def build_brief() -> dict[str, Any]:
    snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    health_rows = read_csv(HEALTH)
    today_row = health_rows[-1] if health_rows else {}
    today = today_row.get("date") or date.today().isoformat()
    recovery = snapshot.get("recovery") or {}
    load = snapshot.get("training_load") or {}
    decision_support = snapshot.get("decision_support") or {}
    monitor = snapshot.get("monitor") or {}
    workflow = json.loads(WORKFLOW.read_text(encoding="utf-8")) if WORKFLOW.is_file() else {}
    training_rows = read_csv(TRAINING) if TRAINING.is_file() else []
    freshness = latest_raw_upload()

    sleep = number(today_row.get("sleep_hours"))
    hrv = number(today_row.get("hrv_sdnn_ms"))
    rhr = number(today_row.get("resting_hr_bpm"))
    prior_sleep = baseline_values(health_rows, "sleep_hours", today)
    prior_hrv = baseline_values(health_rows, "hrv_sdnn_ms", today)
    prior_rhr = baseline_values(health_rows, "resting_hr_bpm", today)
    baseline_sleep = median(prior_sleep) if prior_sleep else number(recovery.get("baseline_sleep_median"))
    baseline_hrv = median(prior_hrv) if prior_hrv else number(recovery.get("baseline_hrv_median"))
    baseline_rhr = median(prior_rhr) if prior_rhr else number(recovery.get("baseline_rhr_median"))

    # RHR is capped around neutral so one low sample cannot manufacture a
    # falsely excellent recovery result.
    components = {
        "sleep": component_score(sleep, baseline_sleep, 22.0),
        "hrv": component_score(hrv, baseline_hrv, 1.6),
        "rhr": component_score(rhr, baseline_rhr, -1.5),
        "load": None,
    }
    load_ratio = number(load.get("load_ratio_7d_to_28d_weekly"))
    if load_ratio is not None:
        if load_ratio > 1.5:
            components["load"] = clamp(75.0 - (load_ratio - 1.5) * 35.0)
        elif load_ratio < 0.5:
            components["load"] = 68.0
        else:
            components["load"] = clamp(82.0 - abs(load_ratio - 1.0) * 20.0)

    readiness = weighted_readiness(components)
    data_quality = str(monitor.get("overall_data_status") or "usable_with_known_gaps")
    confidence = confidence_label(
        str(today_row.get("status") or "partial"),
        int(number(recovery.get("baseline_complete_days")) or 0),
        {"sleep": len(prior_sleep), "hrv": len(prior_hrv), "rhr": len(prior_rhr)},
        str(freshness.get("at") or "") or None,
    )
    decision = readiness_decision(readiness, str(today_row.get("status") or "partial"), data_quality)

    evidence: list[dict[str, Any]] = []
    if sleep is not None:
        evidence.append({
            "signal": "sleep",
            "value": round(sleep, 2),
            "unit": "h",
            "baseline": None if baseline_sleep is None else round(baseline_sleep, 2),
            "delta": None if baseline_sleep is None else round(sleep - baseline_sleep, 2),
            "impact": "限制因素" if baseline_sleep is not None and sleep < baseline_sleep - 0.75 else "中性/支持",
            "confidence": "medium" if len(prior_sleep) >= 5 else "low",
        })
    if hrv is not None:
        evidence.append({
            "signal": "hrv_sdnn",
            "value": round(hrv, 1),
            "unit": "ms",
            "baseline": None if baseline_hrv is None else round(baseline_hrv, 1),
            "delta_pct": None if not baseline_hrv else round((hrv / baseline_hrv - 1) * 100, 1),
            "impact": "略低" if baseline_hrv is not None and hrv < baseline_hrv else "中性/支持",
            "confidence": "medium" if len(prior_hrv) >= 5 else "low",
        })
    if rhr is not None:
        evidence.append({
            "signal": "resting_hr",
            "value": round(rhr, 1),
            "unit": "bpm",
            "baseline": None if baseline_rhr is None else round(baseline_rhr, 1),
            "delta": None if baseline_rhr is None else round(rhr - baseline_rhr, 1),
            "impact": "不单独视为恢复良好；样本量有限",
            "confidence": "medium" if len(prior_rhr) >= 5 else "low",
        })
    if load_ratio is not None:
        evidence.append({
            "signal": "acute_to_baseline_load",
            "value": round(load_ratio, 2),
            "unit": "ratio",
            "baseline": 1.0,
            "impact": "近期负荷偏低，不构成加量许可",
            "confidence": "medium",
        })

    gaps: list[str] = []
    body = latest_complete_body(health_rows)
    if today_row.get("status") == "partial":
        gaps.append("今天尚未结束，活动/静息能量不能用于日结TDEE")
    if not body or not body.get("date") or body["date"] < today:
        gaps.append(f"最近成套晨起体测为 {body.get('date') if body else '未知'}，不能判断今天体重趋势")
    latest_complete_day = snapshot.get("latest_complete_health_day") or {}
    if not latest_complete_day.get("estimated_total_kcal"):
        gaps.append("最近完整日静息能量质量门槛未通过，不输出TDEE")
    if decision_support.get("workflow_validation", {}).get("blocking_step") == "await_user_completion":
        gaps.append("当前计划仍待用户完成反馈，设备运动记录不自动替代完成确认")

    current_plan = workflow.get("current_plan") if isinstance(workflow, dict) else None
    next_candidate = decision_support.get("next_session_candidate")
    alerts = build_alerts(today, today_row, body, training_rows, current_plan, baseline_sleep, sleep)
    actions = [decision["action"]]
    if sleep is not None and baseline_sleep is not None and sleep < baseline_sleep - 0.75:
        actions.append("今晚把睡眠优先级放在训练加量之前；白天不以咖啡或运动热量抵消睡眠不足。")
    actions.append("下一次同步后继续观察同口径晨起体重、训练实际重量×次数和次日起床反馈。")

    return {
        "schema_version": "coach_brief.v1",
        "generated_at": datetime.now(TZ).isoformat(timespec="seconds"),
        "as_of": today,
        "data_status": {
            "today_status": today_row.get("status") or "partial",
            "overall_quality": data_quality,
            "latest_raw_upload_at": freshness.get("at"),
            "raw_payload_file_count": freshness.get("file_count", 0),
            "recovery_baseline_days": int(number(recovery.get("baseline_complete_days")) or 0),
            "recovery_baseline_target": 14,
            "latest_complete_body": body,
        },
        "readiness": {
            "score": readiness,
            "state": decision["state"],
            "label": decision["label"],
            "confidence": confidence,
            "components": components,
            "interpretation": "这是个人趋势决策分，不是医疗评分；睡眠、HRV、静息心率和近期负荷必须结合解释。",
        },
        "evidence": evidence,
        "actions": actions,
        "alerts": alerts,
        "data_gaps": gaps,
        "current_plan": current_plan,
        "current_plan_age_days": plan_age_days(current_plan, today),
        "next_session_candidate": next_candidate,
        "guardrails": [
            "不凭单日体脂秤、手表热量或单次HRV自动改变减脂目标。",
            "出现胸痛、晕厥、明显呼吸困难、异常心悸，或腰部放射痛/麻木/无力时停止相关训练并及时就医。",
        ],
    }


def write_markdown(brief: dict[str, Any]) -> None:
    readiness = brief["readiness"]
    status = brief["data_status"]
    lines = [
        "---",
        'title: "今日教练简报"',
        "type: coach-daily-brief",
        f"updated: {brief['as_of']}",
        "source: coach_snapshot.json, 每日健康汇总.csv, SyncHealth raw payloads",
        "---",
        "",
        "# 今日教练简报",
        "",
        "[[总览|← 返回总览]]　[[健康日结看板]]　[[训练决策看板]]　[[教练监控看板]]",
        "",
        f"> [!tldr] 今日结论\n> **{readiness['label']}**；个人准备度 {readiness['score'] if readiness['score'] is not None else '—'}/100；置信度 `{readiness['confidence']}`。",
        f"> {readiness['interpretation']}",
        "",
        "## 为什么这样判断",
        "",
        "| 信号 | 当前 | 个人基线 | 变化/影响 | 可信度 |",
        "|---|---:|---:|---|---|",
    ]
    for item in brief["evidence"]:
        baseline = item.get("baseline")
        if "delta_pct" in item:
            change = f"{item['delta_pct']:+.1f}%；{item['impact']}"
        elif item.get("delta") is not None:
            change = f"{item['delta']:+.2f}；{item['impact']}"
        else:
            change = str(item["impact"])
        lines.append(
            f"| {item['signal']} | {item['value']} {item['unit']} | {baseline if baseline is not None else '—'} | {change} | {item['confidence']} |"
        )
    lines.extend(["", "## 现在怎么做", ""])
    lines.extend(f"- {action}" for action in brief["actions"])
    lines.extend(["", "## 优先告警", ""])
    if brief["alerts"]:
        lines.extend(
            f"- **[{alert['severity']}] {alert['title']}**：{alert['evidence']}。处理：{alert['action']}"
            for alert in brief["alerts"]
        )
    else:
        lines.append("- 当前没有需要立即处理的告警。")
    lines.extend(["", "## 数据质量与缺口", ""])
    lines.append(f"- 今日数据：`{status['today_status']}`；总体质量：`{status['overall_quality']}`；最近上传：`{status['latest_raw_upload_at'] or '未知'}`。")
    if brief["data_gaps"]:
        lines.extend(f"- {gap}" for gap in brief["data_gaps"])
    else:
        lines.append("- 当前没有影响今日决策的主要数据缺口。")
    lines.extend(["", "## 回退条件", ""])
    lines.extend(f"- {guardrail}" for guardrail in brief["guardrails"])
    lines.append("")
    BRIEF_MD.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    for path in (HEALTH, SNAPSHOT):
        if not path.is_file():
            raise SystemExit(f"缺少数据源: {path}")
    brief = build_brief()
    BRIEF_JSON.write_text(json.dumps(brief, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_markdown(brief)
    snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    snapshot["coach_brief"] = brief
    snapshot["generated_at"] = brief["generated_at"]
    SNAPSHOT.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"教练简报: {BRIEF_MD}")
    print(f"准备度: {brief['readiness']['score'] or '-'} | {brief['readiness']['label']} | 置信度={brief['readiness']['confidence']}")
    print(f"数据缺口: {len(brief['data_gaps'])}项")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
