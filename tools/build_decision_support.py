#!/usr/bin/env python3
"""Build exercise records, scheduling state, cardio status, and workflow views."""

from __future__ import annotations

import csv
import json
import os
import sqlite3
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo


DATA = Path(
    os.environ.get(
        "KRIS_VAULT_DATA",
        Path.home() / "Documents" / "Obsidian Vault" / "Kris 健身数据",
    )
)
DB = Path(os.environ.get("SYNCHEALTH_DB", Path.home() / ".synchealth" / "health.db"))
SETS = DATA / "动作组记录.csv"
PROGRESSION = DATA / "动作进阶建议.csv"
TRAINING = DATA / "训练记录.csv"
LOAD = DATA / "训练负荷汇总.csv"
RECOVERY = DATA / "恢复状态.csv"
WEEKLY = DATA / "周教练汇总.csv"
QUALITY = DATA / "数据质量状态.csv"
SYMPTOMS = DATA / "症状事件.csv"
SNAPSHOT = DATA / "coach_snapshot.json"
WORKFLOW = DATA / "训练流程状态.json"

RECORDS_OUT = DATA / "动作纪录.csv"
SCHEDULE_OUT = DATA / "排课状态.csv"
CARDIO_OUT = DATA / "心肺能力状态.csv"
DECISION_DASHBOARD = DATA / "01-数据看板/训练决策看板.md"
WEEKLY_REVIEW_INPUT = DATA / "01-数据看板/周复盘输入.md"
CARDIO_DASHBOARD = DATA / "03-专题分析/心肺能力看板.md"
TZ = ZoneInfo("Asia/Shanghai")
E1RM_EXERCISES = {
    "史密斯卧推",
    "水平推胸",
    "上斜推胸",
    "高位下拉",
    "坐姿划船",
    "肩推",
    "腿举",
}


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


def week_start(day: date) -> date:
    return day - timedelta(days=day.weekday())


def build_records(
    set_rows: list[dict[str, str]], progression_rows: list[dict[str, str]]
) -> list[dict[str, object]]:
    progression = {
        (row["exercise"], row["equipment_variant"]): row for row in progression_rows
    }
    grouped: defaultdict[tuple[str, str, str], list[dict[str, str]]] = defaultdict(list)
    for row in set_rows:
        grouped[(row["exercise"], row["equipment_variant"], row["weight_scope"])].append(row)

    output: list[dict[str, object]] = []
    for (exercise, variant, scope), rows in sorted(grouped.items()):
        rows = sorted(rows, key=lambda row: (row["date"], row["session_name"], int(row["set_index"])))
        sessions = {(row["date"], row["session_name"]) for row in rows}
        numeric = [row for row in rows if number(row["weight_kg"]) is not None]
        if numeric:
            heaviest = max(numeric, key=lambda row: (float(row["weight_kg"]), int(row["reps"]), row["date"]))
            e1rm_candidates = [
                (
                    float(row["weight_kg"]) * (1 + int(row["reps"]) / 30),
                    row,
                )
                for row in numeric
                if exercise in E1RM_EXERCISES and int(row["reps"]) <= 15
            ]
            if e1rm_candidates:
                best_e1rm, best_e1rm_row = max(e1rm_candidates, key=lambda item: (item[0], item[1]["date"]))
            else:
                best_e1rm, best_e1rm_row = None, None
        else:
            heaviest = max(rows, key=lambda row: (int(row["reps"]), row["date"]))
            best_e1rm = None
            best_e1rm_row = None

        per_session: defaultdict[tuple[str, str], float] = defaultdict(float)
        for row in numeric:
            per_session[(row["date"], row["session_name"])] += float(row["weight_kg"]) * int(row["reps"])
        if per_session:
            best_volume_session, best_volume = max(per_session.items(), key=lambda item: (item[1], item[0][0]))
        else:
            best_volume_session, best_volume = ("", ""), None

        latest_date = max(row["date"] for row in rows)
        record_dates = {heaviest["date"]}
        if best_e1rm_row:
            record_dates.add(best_e1rm_row["date"])
        if per_session:
            record_dates.add(best_volume_session[0])
        progress = progression.get((exercise, variant), {})
        if progress.get("latest_date") != latest_date:
            progress = {}
        output.append(
            {
                "exercise": exercise,
                "equipment_variant": variant,
                "weight_scope": scope,
                "session_count": len(sessions),
                "first_date": min(row["date"] for row in rows),
                "latest_date": latest_date,
                "heaviest_weight_kg": heaviest["weight_kg"],
                "reps_at_heaviest": heaviest["reps"],
                "heaviest_date": heaviest["date"],
                "best_epley_display_kg": "" if best_e1rm is None else f"{best_e1rm:.1f}",
                "best_epley_date": "" if best_e1rm_row is None else best_e1rm_row["date"],
                "best_session_display_volume": "" if best_volume is None else f"{best_volume:.1f}",
                "best_volume_date": "" if not per_session else best_volume_session[0],
                "latest_scheme": progress.get("latest_scheme", ""),
                "current_next_action": progress.get("next_action", ""),
                "record_status": "new_or_tied_latest" if latest_date in record_dates else "historical_record",
                "confidence": "medium" if len(sessions) >= 2 else "low",
                "definition": "同动作+同器械变体+同重量口径；Epley仅用于复合力量动作的同机表现指数，不等于自由重量1RM",
            }
        )
    return output


def session_category(name: str) -> str | None:
    if "上肢" in name:
        return "upper_strength"
    if "下肢" in name:
        return "lower_strength"
    if "游泳" in name:
        return "swimming"
    if "高强度" in name or "中高强度" in name:
        return "cardio_high"
    if any(token in name for token in ("恢复", "轻松", "走跑", "坡度走")):
        return "cardio_low_recovery"
    if any(token in name for token in ("有氧", "跑步", "爬坡", "椭圆")):
        return "cardio_other"
    return None


def workflow_validation(workflow: dict[str, object]) -> dict[str, object]:
    pipeline = workflow["completion_pipeline"]
    assert isinstance(pipeline, dict)
    order = [
        "note_read",
        "obsidian_archive",
        "derived_data_refresh",
        "next_plan_created",
        "completed_note_moved_to_recently_deleted",
    ]
    seen_pending = False
    valid = True
    for step in order:
        value = pipeline.get(step)
        if value not in {"pending", "completed"}:
            valid = False
        if value == "pending":
            seen_pending = True
        elif seen_pending and value == "completed":
            valid = False
    current_plan = workflow["current_plan"]
    assert isinstance(current_plan, dict)
    if current_plan.get("status") == "planned":
        blocking = "await_user_completion"
    else:
        blocking = next((step for step in order if pipeline.get(step) == "pending"), "none")
    return {"valid": valid, "blocking_step": blocking, "ordered_steps": order}


def build_schedule(
    training_rows: list[dict[str, str]],
    load_rows: list[dict[str, str]],
    recovery_rows: list[dict[str, str]],
    workflow: dict[str, object],
    today: date,
) -> tuple[list[dict[str, object]], dict[str, object]]:
    targets = {
        "upper_strength": 2,
        "lower_strength": 2,
        "cardio_high": 1,
        "cardio_low_recovery": 1,
        "swimming": 0,
    }
    labels = {
        "upper_strength": "上肢力量",
        "lower_strength": "下肢力量",
        "cardio_high": "高强度有氧",
        "cardio_low_recovery": "低强度恢复有氧",
        "swimming": "游泳",
    }
    by_category: defaultdict[str, list[date]] = defaultdict(list)
    for row in training_rows:
        category = session_category(row["session_name"])
        if category:
            by_category[category].append(date.fromisoformat(row["date"]))

    recent_start = today - timedelta(days=6)
    rows: list[dict[str, object]] = []
    for category, target in targets.items():
        dates = sorted(by_category.get(category, []))
        latest = dates[-1] if dates else None
        count_7d = sum(day >= recent_start for day in dates)
        if target == 0:
            status = "optional"
        elif count_7d > target:
            status = "above_target"
        elif count_7d == target:
            status = "target_met"
        else:
            status = "below_target"
        rows.append(
            {
                "category": category,
                "label": labels[category],
                "last_completed_date": "" if latest is None else latest.isoformat(),
                "days_since": "" if latest is None else (today - latest).days,
                "sessions_7d": count_7d,
                "weekly_target": target,
                "status": status,
            }
        )

    latest_upper = max(by_category.get("upper_strength", [date.min]))
    latest_lower = max(by_category.get("lower_strength", [date.min]))
    candidate_type = "lower_strength" if latest_lower < latest_upper else "upper_strength"
    earliest = max(today + timedelta(days=1), min(latest_upper, latest_lower) + timedelta(days=2))
    current_plan = workflow["current_plan"]
    assert isinstance(current_plan, dict)
    plan_pending = current_plan.get("status") == "planned"
    planned_rest_dates = {
        date.fromisoformat(str(item["date"]))
        for item in workflow.get("planned_microcycle", [])
        if isinstance(item, dict) and item.get("status") == "planned_rest"
    }
    while earliest in planned_rest_dates:
        earliest += timedelta(days=1)
    latest_load = load_rows[-1]
    load_ratio = number(latest_load.get("load_ratio_7d_to_28d_weekly"))
    recovery_days = int(recovery_rows[-1]["baseline_complete_days"])
    candidate = {
        "candidate_type": candidate_type,
        "candidate_label": labels[candidate_type],
        "earliest_date": earliest.isoformat(),
        "status": "locked_until_current_plan_completed" if plan_pending else "candidate_requires_daily_review",
        "current_plan_status": current_plan.get("status"),
        "load_ratio": load_ratio,
        "recovery_baseline_days": recovery_days,
        "conditions": [
            "当前恢复计划完成并归档",
            "训练后2小时及次日起床无新增腰骶/关节异常",
            "热身动作稳定",
            "近期负荷升高时不额外增加组数或有氧",
        ],
        "reason": f"最近上肢={latest_upper.isoformat()}，最近下肢={latest_lower.isoformat()}；当前7/28负荷比={load_ratio if load_ratio is not None else '建立中'}",
    }
    return rows, candidate


def build_cardio_status(
    db: sqlite3.Connection,
    load_rows: list[dict[str, str]],
    recovery_rows: list[dict[str, str]],
    symptom_rows: list[dict[str, str]],
    workflow: dict[str, object],
) -> list[dict[str, object]]:
    vo2 = db.execute(
        "SELECT day, at, value, unit FROM samples WHERE lower(metric)='vo2max' ORDER BY at"
    ).fetchall()
    latest = vo2[-1] if vo2 else None
    associated = None
    if latest:
        associated = db.execute(
            "SELECT start, end, activity, minutes FROM workouts WHERE end=? LIMIT 1",
            (latest[1],),
        ).fetchone()
    hrr_count = db.execute(
        "SELECT count(*) FROM samples WHERE lower(metric) LIKE '%heartraterecovery%'"
    ).fetchone()[0]
    latest_load = load_rows[-1]
    ratio = number(latest_load.get("load_ratio_7d_to_28d_weekly"))
    baseline_days = int(recovery_rows[-1]["baseline_complete_days"])
    red_flags = sum(row["symptom_status"] == "red_flag_present" for row in symptom_rows)
    current_plan = workflow["current_plan"]
    assert isinstance(current_plan, dict)
    reasons = []
    if current_plan.get("status") == "planned":
        reasons.append("今天已有恢复计划待完成")
    if ratio is not None and ratio > 1.3:
        reasons.append("近期负荷高于28日周均")
    if baseline_days < 14:
        reasons.append("个人恢复基线未满14日")
    if red_flags:
        reasons.append("存在红旗症状记录")
    eligibility = "eligible_for_standard_test" if not reasons else "defer_standard_test"
    return [
        {
            "as_of": datetime.now(TZ).date().isoformat(),
            "vo2max_count": len(vo2),
            "latest_vo2max": "" if latest is None else f"{latest[2]:.1f}",
            "latest_vo2max_unit": "" if latest is None else latest[3],
            "latest_vo2max_at": "" if latest is None else latest[1],
            "associated_workout": "" if associated is None else associated[2],
            "associated_workout_minutes": "" if associated is None else f"{associated[3]:.1f}",
            "heart_rate_recovery_count": hrr_count,
            "baseline_status": "missing" if not vo2 else "single_measurement" if len(vo2) < 3 else "trend_available",
            "standard_test_eligibility": eligibility,
            "eligibility_reasons": "；".join(reasons),
            "next_collection_rule": "累计至少3次可比VO2Max后才判断趋势；心率恢复需标准训练结束后继续佩戴手表",
        }
    ]


def write_dashboards(
    records: list[dict[str, object]],
    schedule: list[dict[str, object]],
    candidate: dict[str, object],
    cardio: list[dict[str, object]],
    workflow: dict[str, object],
    workflow_check: dict[str, object],
    weekly_rows: list[dict[str, str]],
    quality_rows: list[dict[str, str]],
    load_rows: list[dict[str, str]],
    today: date,
) -> None:
    current_plan = workflow["current_plan"]
    pipeline = workflow["completion_pipeline"]
    assert isinstance(current_plan, dict) and isinstance(pipeline, dict)
    recent_records = sorted(
        records,
        key=lambda row: (str(row["heaviest_date"]), str(row["latest_date"])),
        reverse=True,
    )[:14]
    decision = [
        "---",
        'title: "训练决策看板"',
        "type: fitness-decision-dashboard",
        f"updated: {today.isoformat()}",
        "source: 动作纪录.csv, 排课状态.csv, 训练流程状态.json",
        "---",
        "",
        "# 训练决策看板",
        "",
        "[[总览|← 返回总览]]　[[训练智能看板]]　[[教练监控看板]]　[[周复盘输入]]　[[心肺能力看板]]",
        "",
        "> [!tldr] 当前计划与下一课",
        f"> 当前计划：{current_plan['title']}，状态 `{current_plan['status']}`。下一课候选为{candidate['candidate_label']}，目前 `{candidate['status']}`，最早日期{candidate['earliest_date']}。",
        "",
        "## 微周期状态",
        "",
        "| 类型 | 最近完成 | 近7日 | 周目标 | 状态 |",
        "|---|---|---:|---:|---|",
    ]
    for row in schedule:
        decision.append(f"| {row['label']} | {row['last_completed_date'] or '—'} | {row['sessions_7d']} | {row['weekly_target']} | {row['status']} |")
    decision.extend(
        [
            "",
            "## 下一课候选条件",
            "",
            f"- 原因：{candidate['reason']}。",
            *[f"- {condition}。" for condition in candidate["conditions"]],
            "",
            "## 动作纪录",
            "",
            "| 动作/器械/口径 | 最重组 | Epley同机指数 | 最佳单课容量 | 纪录状态 |",
            "|---|---|---:|---:|---|",
        ]
    )
    for row in recent_records:
        heaviest_display = (
            f"自重×{row['reps_at_heaviest']}"
            if row["weight_scope"] == "bodyweight"
            else f"{row['heaviest_weight_kg']}kg×{row['reps_at_heaviest']}"
        )
        decision.append(
            f"| {row['exercise']}·{row['equipment_variant']}·{row['weight_scope']} | {heaviest_display}（{row['heaviest_date']}） | {row['best_epley_display_kg'] or '—'} | {row['best_session_display_volume'] or '—'} | {row['record_status']} |"
        )
    decision.extend(
        [
            "",
            "> [!note] 纪录口径",
            "> 所有纪录只在同动作、同器械变体、同重量显示口径内比较；Epley只对复合力量动作计算，数值是同机表现指数，不代表自由重量真实1RM。",
            "",
            "## 训练完成工作流",
            "",
            f"- 流程有效：`{str(workflow_check['valid']).lower()}`；当前阻塞步骤：`{workflow_check['blocking_step']}`。",
        ]
    )
    for step in workflow_check["ordered_steps"]:
        decision.append(f"- {step}: `{pipeline[step]}`")
    decision.append("")
    DECISION_DASHBOARD.write_text("\n".join(decision), encoding="utf-8")

    cardio_row = cardio[0]
    cardio_lines = [
        "---",
        'title: "心肺能力看板"',
        "type: fitness-cardio-dashboard",
        f"updated: {today.isoformat()}",
        "source: 心肺能力状态.csv, SyncHealth health.db",
        "---",
        "",
        "# 心肺能力看板",
        "",
        "[[总览|← 返回总览]]　[[训练决策看板]]　[[健康日结看板]]",
        "",
        "> [!tldr] 当前基线",
        f"> VO₂Max {cardio_row['latest_vo2max'] or '—'} {cardio_row['latest_vo2max_unit']}，共{cardio_row['vo2max_count']}条，状态 `{cardio_row['baseline_status']}`。标准测试资格 `{cardio_row['standard_test_eligibility']}`。",
        "",
        "## 最新记录",
        "",
        f"- 时间：{cardio_row['latest_vo2max_at'] or '—'}。",
        f"- 同时段运动：{cardio_row['associated_workout'] or '未匹配'}，{cardio_row['associated_workout_minutes'] or '—'}分钟。",
        f"- 心率恢复记录：{cardio_row['heart_rate_recovery_count']}条。",
        f"- 暂缓原因：{cardio_row['eligibility_reasons'] or '无'}。",
        "",
        "> [!note] 使用边界",
        "> 单次Apple Watch VO₂Max只建立设备基线；至少3次可比记录后才看趋势，不凭单次值改变训练强度或作医疗判断。",
        "",
    ]
    CARDIO_DASHBOARD.write_text("\n".join(cardio_lines), encoding="utf-8")

    current_week = weekly_rows[-1]
    previous_week = weekly_rows[-2] if len(weekly_rows) >= 2 else None
    warnings = [row for row in quality_rows if row["status"] == "warning"]
    review = [
        "---",
        'title: "周复盘输入"',
        "type: fitness-weekly-review-input",
        f"updated: {today.isoformat()}",
        f"week_start: {current_week['week_start']}",
        "status: partial",
        "source: 周教练汇总.csv, 数据质量状态.csv, 动作纪录.csv",
        "---",
        "",
        "# 周复盘输入",
        "",
        "[[总览|← 返回总览]]　[[训练决策看板]]　[[教练监控看板]]",
        "",
        "> [!warning] 当前周尚未结束",
        "> 今天的低强度有氧仍处于计划中，本页只作为复盘输入，不把计划计为完成，也不写最终下周处方。",
        "",
        "## 本周摘要",
        "",
        "| 指标 | 本周当前 | 上一周 |",
        "|---|---:|---:|",
        f"| 训练次数 | {current_week['training_sessions']} | {previous_week['training_sessions'] if previous_week else '—'} |",
        f"| 力量/有氧 | {current_week['strength_sessions']}/{current_week['cardio_sessions']} | {previous_week['strength_sessions'] + '/' + previous_week['cardio_sessions'] if previous_week else '—'} |",
        f"| 训练时长 | {current_week['recorded_minutes']}分 | {previous_week['recorded_minutes'] + '分' if previous_week else '—'} |",
        f"| 明确直接组 | {current_week['confirmed_direct_sets']} | {previous_week['confirmed_direct_sets'] if previous_week else '—'} |",
        f"| 平均体重 | {current_week['average_weight_kg'] or '—'}kg（{current_week['weight_measurements']}次） | {previous_week['average_weight_kg'] or '—'}kg（{previous_week['weight_measurements']}次） |",
        f"| 平均睡眠 | {current_week['average_sleep_hours'] or '—'}h（{current_week['sleep_measurements']}晚） | {previous_week['average_sleep_hours'] or '—'}h（{previous_week['sleep_measurements']}晚） |",
        f"| 明确症状阳性 | {current_week['symptom_positive_sessions']} | {previous_week['symptom_positive_sessions'] if previous_week else '—'} |",
        "",
        "## 当前负荷与流程",
        "",
        f"- 近7日负荷：{load_rows[-1]['rolling_7d_load']}；7/28比：{load_rows[-1]['load_ratio_7d_to_28d_weekly']}，状态 `{load_rows[-1]['load_status']}`。",
        f"- 当前训练计划：`{current_plan['status']}`；工作流阻塞在 `{workflow_check['blocking_step']}`。",
        "",
        "## 数据缺口",
        "",
    ]
    review.extend(f"- {row['evidence']}：{row['impact']}。" for row in warnings)
    review.extend(["", "## 周末完成后再判断", "", "- 本周训练完成率与今天恢复课反馈。", "- 训练后2小时及次日起床恢复。", "- 是否维持二分化、削减有氧强度或安排下肢A。", ""])
    WEEKLY_REVIEW_INPUT.write_text("\n".join(review), encoding="utf-8")


def main() -> int:
    today = datetime.now(TZ).date()
    required = (SETS, PROGRESSION, TRAINING, LOAD, RECOVERY, WEEKLY, QUALITY, SYMPTOMS, SNAPSHOT, WORKFLOW, DB)
    for path in required:
        if not path.is_file():
            raise SystemExit(f"缺少数据源: {path}")
    sets = read_csv(SETS)
    progression = read_csv(PROGRESSION)
    training = read_csv(TRAINING)
    load = read_csv(LOAD)
    recovery = read_csv(RECOVERY)
    weekly = read_csv(WEEKLY)
    quality = read_csv(QUALITY)
    symptoms = read_csv(SYMPTOMS)
    workflow = json.loads(WORKFLOW.read_text(encoding="utf-8"))

    records = build_records(sets, progression)
    schedule, candidate = build_schedule(training, load, recovery, workflow, today)
    workflow_check = workflow_validation(workflow)
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        cardio = build_cardio_status(db, load, recovery, symptoms, workflow)
    finally:
        db.close()

    write_csv(
        RECORDS_OUT,
        ["exercise", "equipment_variant", "weight_scope", "session_count", "first_date", "latest_date", "heaviest_weight_kg", "reps_at_heaviest", "heaviest_date", "best_epley_display_kg", "best_epley_date", "best_session_display_volume", "best_volume_date", "latest_scheme", "current_next_action", "record_status", "confidence", "definition"],
        records,
    )
    write_csv(
        SCHEDULE_OUT,
        ["category", "label", "last_completed_date", "days_since", "sessions_7d", "weekly_target", "status"],
        schedule,
    )
    write_csv(
        CARDIO_OUT,
        ["as_of", "vo2max_count", "latest_vo2max", "latest_vo2max_unit", "latest_vo2max_at", "associated_workout", "associated_workout_minutes", "heart_rate_recovery_count", "baseline_status", "standard_test_eligibility", "eligibility_reasons", "next_collection_rule"],
        cardio,
    )
    write_dashboards(records, schedule, candidate, cardio, workflow, workflow_check, weekly, quality, load, today)

    snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    snapshot["decision_support"] = {
        "generated_at": datetime.now(TZ).isoformat(timespec="seconds"),
        "current_plan": workflow["current_plan"],
        "workflow_validation": workflow_check,
        "next_session_candidate": candidate,
        "schedule": schedule,
        "cardio_fitness": cardio[0],
        "exercise_record_count": len(records),
    }
    SNAPSHOT.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"动作纪录: {len(records)}个同器械/口径组合")
    print(f"下一课候选: {candidate['candidate_label']}，状态={candidate['status']}")
    print(f"心肺基线: VO2Max {cardio[0]['latest_vo2max'] or '-'}，记录{cardio[0]['vo2max_count']}条")
    print(f"训练流程: valid={workflow_check['valid']}，blocking={workflow_check['blocking_step']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
