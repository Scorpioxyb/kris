#!/usr/bin/env python3
"""Build auditable training intelligence outputs for Kris.

The script only reads existing health/training archives. Every generated value
keeps its source grain and exposes missing coverage instead of filling gaps.
"""

from __future__ import annotations

import csv
import json
import math
import os
import re
import sqlite3
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from statistics import mean, median
from zoneinfo import ZoneInfo


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
SETS_OUT = DATA / "动作组记录.csv"
VOLUME_OUT = DATA / "肌群周训练量.csv"
PROGRESSION_OUT = DATA / "动作进阶建议.csv"
LOAD_OUT = DATA / "训练负荷汇总.csv"
RECOVERY_OUT = DATA / "恢复状态.csv"
FAT_LOSS_OUT = DATA / "减脂趋势.csv"
SNAPSHOT_OUT = DATA / "coach_snapshot.json"
DASHBOARD_OUT = DATA / "01-数据看板/训练智能看板.md"
TZ = ZoneInfo("Asia/Shanghai")


@dataclass(frozen=True)
class Exercise:
    alias: str
    name: str
    variant: str
    primary: str
    secondary: tuple[str, ...] = ()
    rep_min: int = 8
    rep_max: int = 12


EXERCISES = sorted(
    [
        Exercise("常规龙门架高位下拉", "高位下拉", "常规龙门架", "背部", ("肱二头",)),
        Exercise("双臂独立式下拉", "高位下拉", "双臂独立式", "背部", ("肱二头",)),
        Exercise("插销式水平推胸", "水平推胸", "插销式", "胸部", ("肱三头", "三角肌前束")),
        Exercise("片装式倒蹬", "腿举", "片装式倒蹬", "股四头", ("臀部",)),
        Exercise("插销式坐姿腿举", "腿举", "插销式坐姿腿举", "股四头", ("臀部",)),
        Exercise("插销式坐姿腿推", "腿举", "插销式坐姿腿举", "股四头", ("臀部",)),
        Exercise("扶架保加利亚分腿蹲", "保加利亚分腿蹲", "自重扶架", "股四头", ("臀部",), 8, 12),
        Exercise("保加利亚分腿蹲", "保加利亚分腿蹲", "自重/负重", "股四头", ("臀部",), 8, 12),
        Exercise("蝴蝶机反向飞鸟", "反向飞鸟", "蝴蝶机", "三角肌后束", (), 10, 15),
        Exercise("腿举机提踵", "提踵", "腿举机", "小腿", (), 12, 15),
        Exercise("史密斯卧推", "史密斯卧推", "垂直轨迹史密斯", "胸部", ("肱三头", "三角肌前束")),
        Exercise("上斜推胸机", "上斜推胸", "器械", "胸部", ("肱三头", "三角肌前束")),
        Exercise("坐姿腿弯举", "腿弯举", "坐姿器械", "腘绳肌", (), 10, 12),
        Exercise("坐姿腿屈伸", "腿屈伸", "坐姿器械", "股四头", (), 10, 12),
        Exercise("坐姿髋外展", "髋外展", "坐姿器械", "臀部", (), 12, 15),
        Exercise("哑铃侧平举", "侧平举", "哑铃", "三角肌中束", (), 10, 15),
        Exercise("哑铃推肩", "肩推", "哑铃", "三角肌前束", ("肱三头",)),
        Exercise("器械肩推", "肩推", "器械", "三角肌前束", ("肱三头",)),
        Exercise("直臂下压", "直臂下压", "龙门架", "背部", ("肱三头长头",), 10, 15),
        Exercise("绳索下压", "绳索下压", "龙门架", "肱三头", (), 10, 12),
        Exercise("锤式弯举", "锤式弯举", "哑铃", "肱二头", (), 10, 12),
        Exercise("哑铃弯举", "哑铃弯举", "哑铃", "肱二头", (), 10, 12),
        Exercise("Pallof Press", "Pallof Press", "龙门架", "核心", (), 10, 12),
        Exercise("坐姿划船", "坐姿划船", "器械", "背部", ("肱二头",)),
        Exercise("高位下拉", "高位下拉", "器械未细分", "背部", ("肱二头",)),
        Exercise("水平推胸", "水平推胸", "器械未细分", "胸部", ("肱三头", "三角肌前束")),
        Exercise("推胸机", "水平推胸", "器械未细分", "胸部", ("肱三头", "三角肌前束")),
        Exercise("腿弯举", "腿弯举", "器械未细分", "腘绳肌", (), 10, 12),
        Exercise("腿屈伸", "腿屈伸", "器械未细分", "股四头", (), 10, 12),
        Exercise("侧平举", "侧平举", "哑铃/器械未细分", "三角肌中束", (), 10, 15),
    ],
    key=lambda item: len(item.alias),
    reverse=True,
)

SET_FIELDS = [
    "date", "session_name", "exercise", "equipment_variant", "primary_muscle",
    "secondary_muscles", "set_index", "weight_kg", "weight_scope", "reps",
    "last_set_feel", "completion", "source", "raw_clause",
]


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


def duration_minutes(value: str) -> float | None:
    parts = value.strip().split(":")
    if len(parts) != 3:
        return None
    try:
        hours, minutes, seconds = (int(part) for part in parts)
    except ValueError:
        return None
    return hours * 60 + minutes + seconds / 60


def identify_exercise(clause: str) -> Exercise | None:
    lowered = clause.lower()
    candidates: list[tuple[int, int, Exercise]] = []
    first_load = re.search(r"\d+(?:\.\d+)?kg|自重", lowered)
    load_position = first_load.start() if first_load else len(lowered)
    for exercise in EXERCISES:
        position = lowered.rfind(exercise.alias.lower(), 0, load_position)
        if position >= 0:
            candidates.append((position + len(exercise.alias), len(exercise.alias), exercise))
    if candidates:
        return max(candidates, key=lambda item: (item[0], item[1]))[2]
    return next((exercise for exercise in EXERCISES if exercise.alias.lower() in lowered), None)


def weight_scope(clause: str) -> str:
    if "两边总和" in clause or "总和" in clause:
        return "kg_total_displayed"
    if "/手" in clause or "单手" in clause:
        return "kg_per_hand"
    if "/侧" in clause or "每侧" in clause:
        return "kg_per_side"
    return "kg_displayed"


def last_set_feel(clause: str) -> str:
    if "动作变形" in clause or "代偿" in clause:
        return "动作变形/代偿"
    if "很吃力" in clause or "稍显吃力" in clause or "稍吃力" in clause:
        return "很吃力"
    if "轻松" in clause:
        return "轻松"
    if "合适" in clause or "刚好" in clause:
        return "合适"
    return ""


def extract_sets(clause: str) -> list[tuple[float | None, int]]:
    """Extract only explicitly stated work sets from one exercise clause."""
    normalized = clause.replace("*", "×").replace("x", "×").replace("X", "×")
    found: list[tuple[int, int, list[tuple[float | None, int]]]] = []

    def add(match: re.Match[str], pairs: list[tuple[float | None, int]]) -> None:
        if pairs:
            found.append((match.start(), match.end(), pairs))

    # App export notation repeats the weight for each set: 50kg×10/50kg×10/55kg×10.
    pattern = re.compile(
        r"(?<![\d.])((?:\d+(?:\.\d+)?kg(?:/手|/侧)?×\d+/)+"
        r"\d+(?:\.\d+)?kg(?:/手|/侧)?×\d+)"
    )
    pair_pattern = re.compile(r"(\d+(?:\.\d+)?)kg(?:/手|/侧)?×(\d+)")
    for match in pattern.finditer(normalized):
        add(
            match,
            [
                (float(weight), int(reps))
                for weight, reps in pair_pattern.findall(match.group(1))
            ],
        )

    # Varying weights followed by a matching repetition list: 35/35/40kg×10/10/10.
    pattern = re.compile(r"(?<![\d.])((?:\d+(?:\.\d+)?/)+\d+(?:\.\d+)?)kg(?:/手|/侧)?×((?:\d+/)+\d+)")
    for match in pattern.finditer(normalized):
        weights = [float(item) for item in match.group(1).split("/")]
        reps = [int(item) for item in match.group(2).split("/")]
        if len(weights) == len(reps):
            add(match, list(zip(weights, reps)))

    # One weight, explicit reps and set count: 40kg×10×3.
    pattern = re.compile(r"(?<![\d.\-–—])(\d+(?:\.\d+)?)kg(?:/手|/侧)?×(\d+)×(\d+)")
    for match in pattern.finditer(normalized):
        add(match, [(float(match.group(1)), int(match.group(2)))] * int(match.group(3)))

    # Side-specific core notation: 10kg左右各10×2.
    pattern = re.compile(r"(?<![\d.\-–—])(\d+(?:\.\d+)?)kg左右各(\d+)×(\d+)")
    for match in pattern.finditer(normalized):
        add(match, [(float(match.group(1)), int(match.group(2)))] * int(match.group(3)))

    # Legacy notation: 4kg/手2×12 means two sets of 12.
    pattern = re.compile(r"(?<![\d.\-–—])(\d+(?:\.\d+)?)kg/手(\d+)×(\d+)")
    for match in pattern.finditer(normalized):
        add(match, [(float(match.group(1)), int(match.group(3)))] * int(match.group(2)))

    # One displayed weight with one or multiple set reps: 40kg×12/10 or 50kg×8.
    pattern = re.compile(r"(?<![\d.\-–—])(\d+(?:\.\d+)?)kg(?:/手|/侧)?×((?:\d+/)*\d+)(?!\d|×|组)")
    for match in pattern.finditer(normalized):
        reps = [int(item) for item in match.group(2).split("/")]
        add(match, [(float(match.group(1)), rep) for rep in reps])

    # Bodyweight unilateral work: 自重左右各8次、左右各10次.
    pattern = re.compile(r"自重左右各(\d+)次(?:、左右各(\d+)次)?")
    for match in pattern.finditer(normalized):
        reps = [int(match.group(1))]
        if match.group(2):
            reps.append(int(match.group(2)))
        add(match, [(None, rep) for rep in reps])

    # Notes occasionally state the load and reps without the multiplication sign.
    pattern = re.compile(r"(?:单手)?(\d+(?:\.\d+)?)kg[^；]{0,24}?明确填写(\d+(?:/\d+)+)次")
    for match in pattern.finditer(normalized):
        add(match, [(float(match.group(1)), int(rep)) for rep in match.group(2).split("/")])
    pattern = re.compile(r"(?:单手)?(\d+(?:\.\d+)?)kg[^；]{0,24}?首组(\d+)次")
    for match in pattern.finditer(normalized):
        add(match, [(float(match.group(1)), int(match.group(2)))])

    # Keep the most specific non-overlapping matches.
    selected: list[tuple[int, int, list[tuple[float | None, int]]]] = []
    for item in sorted(found, key=lambda value: (value[0], -(value[1] - value[0]))):
        start, end, _pairs = item
        if any(not (end <= prior_start or start >= prior_end) for prior_start, prior_end, _ in selected):
            continue
        selected.append(item)
    pairs: list[tuple[float | None, int]] = []
    for _start, _end, item_pairs in sorted(selected):
        pairs.extend(item_pairs)
    return pairs


def build_set_rows(training_rows: list[dict[str, str]]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    indexes: defaultdict[tuple[str, str, str, str], int] = defaultdict(int)
    for session in training_rows:
        notes = session.get("notes", "")
        for clause in re.split(r"[；。]", notes):
            exercise = identify_exercise(clause)
            if exercise is None:
                continue
            pairs = extract_sets(clause)
            if not pairs:
                continue
            key = (session["date"], session["session_name"], exercise.name, exercise.variant)
            for weight, reps in pairs:
                indexes[key] += 1
                rows.append(
                    {
                        "date": session["date"],
                        "session_name": session["session_name"],
                        "exercise": exercise.name,
                        "equipment_variant": exercise.variant,
                        "primary_muscle": exercise.primary,
                        "secondary_muscles": ";".join(exercise.secondary),
                        "set_index": indexes[key],
                        "weight_kg": "" if weight is None else f"{weight:g}",
                        "weight_scope": "bodyweight" if weight is None else weight_scope(clause),
                        "reps": reps,
                        "last_set_feel": last_set_feel(clause),
                        "completion": "confirmed_explicit",
                        "source": "训练记录.csv:notes",
                        "raw_clause": clause.strip(),
                    }
                )
    return rows


def week_start(day_text: str) -> str:
    day = date.fromisoformat(day_text)
    return (day - timedelta(days=day.weekday())).isoformat()


def build_muscle_volume(set_rows: list[dict[str, object]]) -> list[dict[str, object]]:
    stats: defaultdict[tuple[str, str], dict[str, object]] = defaultdict(
        lambda: {"direct": 0, "secondary": 0.0, "sessions": set(), "sets": 0}
    )
    for row in set_rows:
        week = week_start(str(row["date"]))
        primary_key = (week, str(row["primary_muscle"]))
        stats[primary_key]["direct"] = int(stats[primary_key]["direct"]) + 1
        stats[primary_key]["sets"] = int(stats[primary_key]["sets"]) + 1
        cast_sessions = stats[primary_key]["sessions"]
        assert isinstance(cast_sessions, set)
        cast_sessions.add(f"{row['date']}|{row['session_name']}")
        for muscle in str(row["secondary_muscles"]).split(";"):
            if not muscle:
                continue
            key = (week, muscle)
            stats[key]["secondary"] = float(stats[key]["secondary"]) + 0.5
            stats[key]["sets"] = int(stats[key]["sets"]) + 1
            secondary_sessions = stats[key]["sessions"]
            assert isinstance(secondary_sessions, set)
            secondary_sessions.add(f"{row['date']}|{row['session_name']}")

    rows: list[dict[str, object]] = []
    for (week, muscle), values in sorted(stats.items()):
        direct = int(values["direct"])
        secondary = float(values["secondary"])
        sessions = values["sessions"]
        assert isinstance(sessions, set)
        rows.append(
            {
                "week_start": week,
                "muscle_group": muscle,
                "confirmed_direct_sets": direct,
                "secondary_equivalent_sets": f"{secondary:.1f}",
                "total_stimulus_sets": f"{direct + secondary:.1f}",
                "session_count": len(sessions),
                "coverage": "lower_bound_from_explicit_sets",
                "definition": "直接组=1.0；复合动作次要肌群=0.5；未明确次数的完成动作不计",
            }
        )
    return rows


def exercise_meta(name: str, variant: str) -> Exercise | None:
    return next((item for item in EXERCISES if item.name == name and item.variant == variant), None)


def progression_decision(
    latest_sets: list[dict[str, object]],
    prior_sets: list[dict[str, object]],
    rep_min: int,
    rep_max: int,
) -> dict[str, object]:
    """Return an auditable double-progression state for one exercise.

    The gate is intentionally conservative: load only increases after two
    comparable sessions reach the top of the repetition range with explicit
    acceptable form feedback. Missing feedback never counts as proof of good
    form.
    """

    def weights(rows: list[dict[str, object]]) -> list[float | None]:
        return [None if row["weight_kg"] == "" else float(row["weight_kg"]) for row in rows]

    def feels(rows: list[dict[str, object]]) -> list[str]:
        return [str(row["last_set_feel"]) for row in rows if row.get("last_set_feel")]

    def technique_issue(rows: list[dict[str, object]]) -> bool:
        return any(
            "变形" in str(row.get("last_set_feel", ""))
            or "代偿" in str(row.get("last_set_feel", ""))
            for row in rows
        )

    def acceptable_feedback(rows: list[dict[str, object]]) -> bool:
        recorded = feels(rows)
        return bool(recorded) and all(feel in {"轻松", "合适"} for feel in recorded)

    latest_reps = [int(row["reps"]) for row in latest_sets]
    prior_reps = [int(row["reps"]) for row in prior_sets]
    latest_raw = "；".join(str(row.get("raw_clause", "")) for row in latest_sets)
    same_scheme = bool(prior_sets) and len(latest_sets) == len(prior_sets) and weights(latest_sets) == weights(prior_sets)
    latest_at_top = len(latest_sets) >= 2 and min(latest_reps) >= rep_max
    prior_at_top = len(prior_sets) >= 2 and min(prior_reps) >= rep_max

    if len(latest_sets) < 2:
        state = "establish_baseline"
        action = "先补全至少2个明确工作组，建立可比较基线"
        evidence = f"最近仅{len(latest_sets)}个明确工作组"
        rollback = "基线未建立，不执行自动进阶"
    elif technique_issue(latest_sets):
        state = "technique_hold"
        action = "先消除动作变形/代偿，不加重"
        evidence = "最近一次明确记录动作变形或代偿"
        rollback = "连续一次完整工作组无变形后，再回到补次数阶段"
    elif "小臂力量偏弱" in latest_raw:
        state = "limiter_hold"
        action = "维持同器械负重，先确认握力不再限制目标肌群"
        evidence = "最近一次明确记录握力或小臂先成为限制因素"
        rollback = "目标肌群仍未成为主要限制因素时继续维持，不加重"
    elif latest_at_top and prior_at_top and same_scheme and acceptable_feedback(latest_sets) and acceptable_feedback(prior_sets):
        state = "increase_smallest_step"
        action = "下次按同器械最小档加重，并回到次数下限"
        evidence = f"连续2次相同方案全部工作组达到{rep_max}次，且末组反馈均为轻松/合适"
        rollback = f"加重后任一组低于{rep_min}次或出现动作变形，退回原重量"
    elif latest_at_top:
        state = "confirm_top_range"
        action = f"维持最新方案，再确认一次全部工作组达到{rep_max}次且动作稳定"
        missing = []
        if not prior_at_top:
            missing.append("前一次未全部达上限")
        if prior_sets and not same_scheme:
            missing.append("两次负重/组数方案不同")
        if not acceptable_feedback(latest_sets) or (prior_sets and not acceptable_feedback(prior_sets)):
            missing.append("缺少连续两次轻松/合适反馈")
        evidence = "；".join(missing) or "仅确认1次达到次数上限"
        rollback = "出现动作变形、关节或腰骶代偿时转为技术维持"
    elif min(latest_reps) >= rep_min:
        state = "add_repetitions"
        action = f"维持同器械负重，先把全部工作组补到{rep_max}次"
        evidence = f"最近全部工作组达到{rep_min}次，但尚未全部达到{rep_max}次"
        rollback = f"任一组低于{rep_min}次或动作变形时，维持或回退最小档"
    else:
        state = "rebuild_at_lower_bound"
        action = f"维持或回退最小档，先让全部工作组回到至少{rep_min}次"
        evidence = f"最近至少一组低于{rep_min}次"
        rollback = f"连续一次全部工作组回到{rep_min}次后，再进入补次数阶段"

    return {
        "progression_state": state,
        "next_action": action,
        "decision_evidence": evidence,
        "rollback_condition": rollback,
        "gate_version": "gated_double_progression_v1",
    }


def build_progression(set_rows: list[dict[str, object]]) -> list[dict[str, object]]:
    sessions: defaultdict[tuple[str, str], defaultdict[tuple[str, str], list[dict[str, object]]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for row in set_rows:
        key = (str(row["exercise"]), str(row["equipment_variant"]))
        session_key = (str(row["date"]), str(row["session_name"]))
        sessions[key][session_key].append(row)

    output: list[dict[str, object]] = []
    for (exercise, variant), grouped in sorted(sessions.items()):
        ordered = sorted(grouped.items())
        (latest_date, latest_name), latest_sets = ordered[-1]
        prior_sets = ordered[-2][1] if len(ordered) >= 2 else []
        meta = exercise_meta(exercise, variant)
        rep_min = meta.rep_min if meta else 8
        rep_max = meta.rep_max if meta else 12

        def summary(rows: list[dict[str, object]]) -> tuple[int, float, float, str]:
            reps = [int(row["reps"]) for row in rows]
            weighted = [float(row["weight_kg"]) * int(row["reps"]) for row in rows if row["weight_kg"] != ""]
            max_weight = max((float(row["weight_kg"]) for row in rows if row["weight_kg"] != ""), default=0.0)
            scheme = " / ".join(
                f"{'自重' if row['weight_kg'] == '' else str(row['weight_kg']) + 'kg'}×{row['reps']}"
                for row in rows
            )
            return sum(reps), sum(weighted), max_weight, scheme

        latest_reps, latest_volume, latest_max, latest_scheme = summary(latest_sets)
        prior_reps, prior_volume, prior_max, _prior_scheme = summary(prior_sets) if prior_sets else (0, 0.0, 0.0, "")
        if not prior_sets:
            trend = "baseline_building"
        elif latest_volume and prior_volume and latest_volume > prior_volume * 1.03:
            trend = "progressing"
        elif latest_max > prior_max and latest_reps >= prior_reps * 0.9:
            trend = "progressing"
        elif not latest_volume and latest_reps > prior_reps and latest_max >= prior_max:
            trend = "progressing"
        else:
            trend = "stable_or_context_limited"

        decision = progression_decision(latest_sets, prior_sets, rep_min, rep_max)

        output.append(
            {
                "exercise": exercise,
                "equipment_variant": variant,
                "session_count": len(ordered),
                "latest_date": latest_date,
                "latest_session": latest_name,
                "latest_scheme": latest_scheme,
                "latest_total_reps": latest_reps,
                "latest_display_volume_kg_reps": f"{latest_volume:.1f}" if latest_volume else "",
                "previous_total_reps": prior_reps or "",
                "previous_display_volume_kg_reps": f"{prior_volume:.1f}" if prior_volume else "",
                "trend": trend,
                **decision,
                "quality": "same_variant_explicit_sets_only",
            }
        )
    return output


def classify_session(name: str) -> tuple[str, float]:
    if "上肢" in name or "下肢" in name:
        return "strength", 1.00
    if "游泳" in name:
        return "swim", 0.90
    if "高强度" in name or "中高强度" in name:
        return "cardio_high", 1.15
    if "有氧" in name or "跑步" in name or "走跑" in name or "爬坡" in name or "坡度走" in name:
        if "恢复" in name or "轻松" in name:
            return "cardio_low", 0.65
        return "cardio_moderate", 0.85
    if "自重训练" in name or "恢复训练" in name:
        return "strength_reconditioning", 0.75
    if "腰盆" in name or "活动度" in name:
        return "mobility_recovery", 0.50
    return "other", 0.75


def build_load(training_rows: list[dict[str, str]], today: date) -> list[dict[str, object]]:
    per_day: defaultdict[date, dict[str, object]] = defaultdict(
        lambda: {"sessions": 0, "minutes": 0.0, "points": 0.0, "missing": 0, "types": set()}
    )
    first_day = min(date.fromisoformat(row["date"]) for row in training_rows)
    for row in training_rows:
        day = date.fromisoformat(row["date"])
        per_day[day]["sessions"] = int(per_day[day]["sessions"]) + 1
        minutes = duration_minutes(row.get("duration", ""))
        session_type, factor = classify_session(row.get("session_name", ""))
        cast_types = per_day[day]["types"]
        assert isinstance(cast_types, set)
        cast_types.add(session_type)
        if minutes is None:
            per_day[day]["missing"] = int(per_day[day]["missing"]) + 1
            continue
        per_day[day]["minutes"] = float(per_day[day]["minutes"]) + minutes
        per_day[day]["points"] = float(per_day[day]["points"]) + minutes * factor

    rows: list[dict[str, object]] = []
    cursor = first_day
    short_term_load = 0.0
    long_term_load = 0.0
    previous_balance = 0.0
    while cursor <= today:
        values = per_day[cursor]
        acute_start = cursor - timedelta(days=6)
        chronic_start = cursor - timedelta(days=27)
        acute = sum(float(per_day[day]["points"]) for day in per_day if acute_start <= day <= cursor)
        chronic_total = sum(float(per_day[day]["points"]) for day in per_day if chronic_start <= day <= cursor)
        chronic_weekly = chronic_total / 4
        mature = (cursor - first_day).days >= 27
        ratio = acute / chronic_weekly if mature and chronic_weekly > 0 else None
        if ratio is None:
            status = "baseline_building"
        elif ratio > 1.5:
            status = "elevated_recent_load"
        elif ratio > 1.3:
            status = "above_28d_baseline"
        elif ratio >= 0.8:
            status = "within_28d_baseline"
        else:
            status = "below_28d_baseline"

        daily_points = float(values["points"])
        model_days = (cursor - first_day).days + 1
        if model_days == 1:
            short_term_load = daily_points
            long_term_load = daily_points
        else:
            short_term_load += (daily_points - short_term_load) * (1 - math.exp(-1 / 7))
            long_term_load += (daily_points - long_term_load) * (1 - math.exp(-1 / 42))
        load_balance = previous_balance
        balance_ratio = load_balance / long_term_load if long_term_load > 0 else None
        if model_days < 42:
            performance_status = "baseline_building"
        elif balance_ratio is not None and balance_ratio < -0.35:
            performance_status = "short_term_load_high"
        elif balance_ratio is not None and balance_ratio < -0.10:
            performance_status = "short_term_above_long_term"
        elif balance_ratio is not None and balance_ratio <= 0.15:
            performance_status = "balanced_load_context"
        else:
            performance_status = "fresh_or_low_recent_load_context"
        previous_balance = long_term_load - short_term_load
        types = values["types"]
        assert isinstance(types, set)
        rows.append(
            {
                "date": cursor.isoformat(),
                "status": "partial" if cursor == today else "final",
                "session_count": values["sessions"],
                "recorded_minutes": f"{float(values['minutes']):.1f}",
                "duration_load_points": f"{float(values['points']):.1f}",
                "session_types": ";".join(sorted(types)),
                "missing_duration_sessions": values["missing"],
                "rolling_7d_load": f"{acute:.1f}",
                "rolling_28d_weekly_average": f"{chronic_weekly:.1f}" if mature else "",
                "load_ratio_7d_to_28d_weekly": f"{ratio:.2f}" if ratio is not None else "",
                "load_status": status,
                "short_term_7d_ema": f"{short_term_load:.1f}",
                "long_term_42d_ema": f"{long_term_load:.1f}",
                "load_balance": f"{load_balance:.1f}",
                "load_balance_ratio": "" if balance_ratio is None else f"{balance_ratio:.2f}",
                "performance_model_days": model_days,
                "performance_model_status": performance_status,
                "definition": "时长分钟×类型系数；7/42日指数趋势只用于个人负荷语境，不等于生理疲劳或伤病预测",
            }
        )
        cursor += timedelta(days=1)
    return rows


def build_recovery(health_rows: list[dict[str, str]]) -> list[dict[str, object]]:
    output: list[dict[str, object]] = []
    for index, row in enumerate(health_rows):
        day = date.fromisoformat(row["date"])
        prior = [
            candidate
            for candidate in health_rows[:index]
            if 0 < (day - date.fromisoformat(candidate["date"])).days <= 14
            and candidate.get("status") == "final"
            and number(candidate.get("sleep_hours")) is not None
            and number(candidate.get("resting_hr_bpm")) is not None
            and number(candidate.get("hrv_sdnn_ms")) is not None
        ]
        baseline_days = len(prior)
        rhr_base = median([number(item["resting_hr_bpm"]) for item in prior if number(item["resting_hr_bpm"]) is not None]) if prior else None
        hrv_base = median([number(item["hrv_sdnn_ms"]) for item in prior if number(item["hrv_sdnn_ms"]) is not None]) if prior else None
        sleep_base = median([number(item["sleep_hours"]) for item in prior if number(item["sleep_hours"]) is not None]) if prior else None
        current_rhr = number(row.get("resting_hr_bpm"))
        current_hrv = number(row.get("hrv_sdnn_ms"))
        current_sleep = number(row.get("sleep_hours"))
        status = "baseline_building"
        reasons: list[str] = []
        if baseline_days >= 14 and current_rhr is not None and current_hrv is not None and current_sleep is not None:
            rhr_delta = current_rhr - float(rhr_base)
            hrv_delta_pct = 100 * (current_hrv - float(hrv_base)) / float(hrv_base)
            if rhr_delta >= 8 or hrv_delta_pct <= -20 or current_sleep < 6:
                status = "reduce_intensity"
                reasons.append("恢复指标明显偏离个人14日基线")
            elif rhr_delta >= 5 or hrv_delta_pct <= -12 or current_sleep < 6.5:
                status = "caution"
                reasons.append("至少一项恢复指标偏弱")
            else:
                status = "normal"
                reasons.append("设备恢复指标处于个人基线范围")
        else:
            reasons.append(f"个人恢复基线建立中：{baseline_days}/14个完整日")
        output.append(
            {
                "date": row["date"],
                "day_status": row.get("status", ""),
                "sleep_hours": row.get("sleep_hours", ""),
                "resting_hr_bpm": row.get("resting_hr_bpm", ""),
                "hrv_sdnn_ms": row.get("hrv_sdnn_ms", ""),
                "respiratory_rate": row.get("respiratory_rate", ""),
                "oxygen_saturation_pct": row.get("oxygen_saturation_pct", ""),
                "wrist_temperature_c": row.get("wrist_temperature_c", ""),
                "baseline_complete_days": baseline_days,
                "baseline_rhr_median": "" if rhr_base is None else f"{rhr_base:.1f}",
                "baseline_hrv_median": "" if hrv_base is None else f"{hrv_base:.1f}",
                "baseline_sleep_median": "" if sleep_base is None else f"{sleep_base:.2f}",
                "recovery_status": status,
                "reason": "；".join(reasons),
            }
        )
    return output


def comparable_body_rows(body_rows: list[dict[str, str]]) -> list[dict[str, str]]:
    by_day: dict[str, dict[str, str]] = {}
    for row in body_rows:
        if "米家" not in row.get("source", ""):
            continue
        if "起床后" not in row.get("measurement_context", ""):
            continue
        if number(row.get("weight_kg")) is None:
            continue
        by_day[row["date"]] = row
    return [by_day[key] for key in sorted(by_day)]


def build_fat_loss(body_rows: list[dict[str, str]], today: date) -> list[dict[str, object]]:
    rows = comparable_body_rows(body_rows)
    latest = rows[-1] if rows else None
    recent = [row for row in rows if 0 <= (today - date.fromisoformat(row["date"])).days <= 6]
    prior = [row for row in rows if 7 <= (today - date.fromisoformat(row["date"])).days <= 13]
    recent_avg = mean([float(row["weight_kg"]) for row in recent]) if recent else None
    prior_avg = mean([float(row["weight_kg"]) for row in prior]) if prior else None
    change = recent_avg - prior_avg if recent_avg is not None and prior_avg is not None else None
    waist_rows = read_csv(DATA / "围度记录.csv") if (DATA / "围度记录.csv").is_file() else []
    recent_waist = [row for row in waist_rows if row.get("date") and 0 <= (today - date.fromisoformat(row["date"])).days <= 13]
    if len(recent) >= 5 and len(prior) >= 5 and change is not None:
        if change >= -0.1 and len(recent_waist) >= 2:
            status = "plateau_candidate"
            action = "触发3天低负担饮食审计，并核对腰围与训练表现"
        elif change >= -0.1:
            status = "needs_waist_confirmation"
            action = "先补同情境腰围；不因体重单项直接削减热量"
        else:
            status = "progressing"
            action = "维持当前策略，继续观察7日均重、腰围和力量"
    else:
        status = "insufficient_comparable_days"
        action = "继续晨起同口径称重；累计两个各至少5天的7日窗口后再判平台"
    return [
        {
            "as_of": today.isoformat(),
            "latest_measurement_date": latest["date"] if latest else "",
            "latest_weight_kg": latest.get("weight_kg", "") if latest else "",
            "latest_body_fat_pct": latest.get("body_fat_pct", "") if latest else "",
            "recent_7d_measurements": len(recent),
            "recent_7d_average_weight_kg": "" if recent_avg is None else f"{recent_avg:.2f}",
            "prior_7d_measurements": len(prior),
            "prior_7d_average_weight_kg": "" if prior_avg is None else f"{prior_avg:.2f}",
            "average_weight_change_kg": "" if change is None else f"{change:.2f}",
            "recent_14d_waist_records": len(recent_waist),
            "plateau_status": status,
            "next_action": action,
            "definition": "仅米家S800晨起记录；两个7日窗口各至少5次，且腰围用于确认平台",
        }
    ]


def cardio_fitness_status(db: sqlite3.Connection) -> dict[str, object]:
    metrics = {row[0]: row[1] for row in db.execute("SELECT metric, count(*) FROM samples GROUP BY metric")}
    vo2_rows = sum(count for metric, count in metrics.items() if "vo2" in metric.lower())
    recovery_rows = sum(count for metric, count in metrics.items() if "recovery" in metric.lower() and "heart" in metric.lower())
    latest_vo2 = db.execute(
        "SELECT day, at, value, unit FROM samples WHERE lower(metric)='vo2max' ORDER BY at DESC LIMIT 1"
    ).fetchone()
    return {
        "vo2max_rows": vo2_rows,
        "latest_vo2max_day": None if latest_vo2 is None else latest_vo2[0],
        "latest_vo2max_at": None if latest_vo2 is None else latest_vo2[1],
        "latest_vo2max_value": None if latest_vo2 is None else latest_vo2[2],
        "latest_vo2max_unit": None if latest_vo2 is None else latest_vo2[3],
        "heart_rate_recovery_rows": recovery_rows,
        "status": "available" if vo2_rows else "baseline_missing",
        "collection_protocol": "Apple Watch户外步行/跑步/徒步且GPS良好；标准化比较时使用至少20分钟固定协议，训练结束后继续佩戴以保留恢复心率",
    }


def optional_health_context(db: sqlite3.Connection) -> dict[str, object]:
    state_row = db.execute(
        "SELECT count(*), max(day) FROM generic_events WHERE section='state_of_mind'"
    ).fetchone()
    ecg_row = db.execute(
        "SELECT count(*), max(day) FROM generic_events WHERE section='ecg_recordings'"
    ).fetchone()
    classifications = [
        row[0]
        for row in db.execute(
            """
            SELECT DISTINCT json_extract(payload, '$.classification')
            FROM generic_events
            WHERE section='ecg_recordings'
              AND json_extract(payload, '$.classification') IS NOT NULL
            ORDER BY 1
            """
        )
    ]
    return {
        "state_of_mind_rows": state_row[0],
        "state_of_mind_latest_day": state_row[1],
        "state_of_mind_usage": "low_weight_context_only",
        "ecg_rows": ecg_row[0],
        "ecg_latest_day": ecg_row[1],
        "ecg_classifications": classifications,
        "ecg_usage": "coverage_only_no_diagnosis_no_progression",
    }


def latest_final_health(health_rows: list[dict[str, str]]) -> dict[str, str] | None:
    return next((row for row in reversed(health_rows) if row.get("status") == "final"), None)


def write_dashboard(
    set_rows: list[dict[str, object]],
    volume_rows: list[dict[str, object]],
    progression_rows: list[dict[str, object]],
    load_rows: list[dict[str, object]],
    recovery_rows: list[dict[str, object]],
    fat_rows: list[dict[str, object]],
    cardio: dict[str, object],
    today: date,
) -> None:
    latest_load = load_rows[-1]
    latest_recovery = recovery_rows[-1]
    fat = fat_rows[-1]
    current_week = week_start(today.isoformat())
    week_volume = [row for row in volume_rows if row["week_start"] == current_week]
    recent_progression = sorted(progression_rows, key=lambda row: str(row["latest_date"]), reverse=True)[:12]
    lines = [
        "---",
        'title: "训练智能看板"',
        "type: fitness-intelligence-dashboard",
        f"updated: {today.isoformat()}",
        "source: 训练记录.csv, 体测记录.csv, 每日健康汇总.csv, SyncHealth health.db",
        "---",
        "",
        "# 训练智能看板",
        "",
        "[[总览|← 返回总览]]　[[训练看板]]　[[健康日结看板]]　[[教练监控看板]]　[[训练决策看板]]　[[腰骶与活动度跟踪]]",
        "",
        "> [!tldr] 当前状态",
        f"> 近7日时长负荷 {latest_load['rolling_7d_load']} 点；7日/28日周均比 {latest_load['load_ratio_7d_to_28d_weekly'] or '建立中'}，状态 `{latest_load['load_status']}`。恢复基线 {latest_recovery['baseline_complete_days']}/14 个完整日，当前仅作观察。",
        "",
        "## 本周肌群容量",
        "",
        "| 肌群 | 明确直接组 | 次要等效组 | 总刺激组 | 记录口径 |",
        "|---|---:|---:|---:|---|",
    ]
    if week_volume:
        for row in sorted(week_volume, key=lambda item: float(item["total_stimulus_sets"]), reverse=True):
            lines.append(
                f"| {row['muscle_group']} | {row['confirmed_direct_sets']} | {row['secondary_equivalent_sets']} | {row['total_stimulus_sets']} | 明确组下限 |"
            )
    else:
        lines.append("| — | — | — | — | 本周暂无可解析组记录 |")

    lines.extend(
        [
            "",
            "> [!note] 容量口径",
            "> 只统计已明确写出重量/次数的工作组；复合动作对次要肌群按0.5组估算。未填写次数但口头确认完成的动作不会被伪造，因此这里是训练量下限。",
            "",
            "## 动作进阶",
            "",
            "| 动作/器械 | 最近实绩 | 决策状态 | 证据 | 下一步 |",
            "|---|---|---|---|---|",
        ]
    )
    for row in recent_progression:
        lines.append(
            f"| {row['exercise']}·{row['equipment_variant']} | {row['latest_date']}：{row['latest_scheme']} | {row['progression_state']} | {row['decision_evidence']} | {row['next_action']} |"
        )

    lines.extend(
        [
            "",
            "## 负荷与恢复",
            "",
            "| 指标 | 当前值 | 判断 |",
            "|---|---:|---|",
            f"| 近7日时长负荷 | {latest_load['rolling_7d_load']} | {latest_load['load_status']} |",
            f"| 28日折算周均 | {latest_load['rolling_28d_weekly_average'] or '建立中'} | 同一人趋势代理，不用于伤病预测 |",
            f"| 7日/28日周均比 | {latest_load['load_ratio_7d_to_28d_weekly'] or '建立中'} | 只解释近期负荷相对变化 |",
            f"| 短期/长期负荷 | {latest_load['short_term_7d_ema']} / {latest_load['long_term_42d_ema']} | `{latest_load['performance_model_status']}`，模型覆盖{latest_load['performance_model_days']}/42日 |",
            f"| 负荷平衡 | {latest_load['load_balance']}（比值{latest_load['load_balance_ratio'] or '—'}） | 使用训练前一日平衡，避免把当天训练结果当作训练前状态 |",
            f"| 恢复基线 | {latest_recovery['baseline_complete_days']}/14日 | {latest_recovery['reason']} |",
            f"| 心肺能力 | VO2Max {cardio['vo2max_rows']}条（最新{cardio['latest_vo2max_value'] if cardio['latest_vo2max_value'] is not None else '—'}）；心率恢复 {cardio['heart_rate_recovery_rows']}条 | {cardio['status']} |",
            "",
            "## 减脂平台监测",
            "",
            f"- 最近7日晨起均重：{fat['recent_7d_average_weight_kg'] or '数据不足'} kg（{fat['recent_7d_measurements']}次）。",
            f"- 前一7日晨起均重：{fat['prior_7d_average_weight_kg'] or '数据不足'} kg（{fat['prior_7d_measurements']}次）。",
            f"- 状态：`{fat['plateau_status']}`；{fat['next_action']}。",
            "",
            "## 机器可读数据",
            "",
            "- `coach_snapshot.json`：未来小组件、程序或网站的统一快照入口。",
            "- `动作组记录.csv`：逐组训练实绩。",
            "- `肌群周训练量.csv`、`动作进阶建议.csv`、`训练负荷汇总.csv`、`恢复状态.csv`、`减脂趋势.csv`：可直接用于图表和规则引擎。",
            "",
        ]
    )
    DASHBOARD_OUT.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    today = datetime.now(TZ).date()
    if not (DATA.parent / ".obsidian").is_dir():
        raise SystemExit(f"不是有效的 Obsidian vault: {DATA.parent}")
    for required in (TRAINING, BODY, HEALTH, DB):
        if not required.is_file():
            raise SystemExit(f"缺少数据源: {required}")

    training_rows = read_csv(TRAINING)
    body_rows = read_csv(BODY)
    health_rows = read_csv(HEALTH)
    set_rows = build_set_rows(training_rows)
    volume_rows = build_muscle_volume(set_rows)
    progression_rows = build_progression(set_rows)
    load_rows = build_load(training_rows, today)
    recovery_rows = build_recovery(health_rows)
    fat_rows = build_fat_loss(body_rows, today)
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        cardio = cardio_fitness_status(db)
        optional_context = optional_health_context(db)
    finally:
        db.close()

    write_csv(SETS_OUT, SET_FIELDS, set_rows)
    write_csv(
        VOLUME_OUT,
        ["week_start", "muscle_group", "confirmed_direct_sets", "secondary_equivalent_sets", "total_stimulus_sets", "session_count", "coverage", "definition"],
        volume_rows,
    )
    write_csv(
        PROGRESSION_OUT,
        ["exercise", "equipment_variant", "session_count", "latest_date", "latest_session", "latest_scheme", "latest_total_reps", "latest_display_volume_kg_reps", "previous_total_reps", "previous_display_volume_kg_reps", "trend", "progression_state", "next_action", "decision_evidence", "rollback_condition", "gate_version", "quality"],
        progression_rows,
    )
    write_csv(
        LOAD_OUT,
        ["date", "status", "session_count", "recorded_minutes", "duration_load_points", "session_types", "missing_duration_sessions", "rolling_7d_load", "rolling_28d_weekly_average", "load_ratio_7d_to_28d_weekly", "load_status", "short_term_7d_ema", "long_term_42d_ema", "load_balance", "load_balance_ratio", "performance_model_days", "performance_model_status", "definition"],
        load_rows,
    )
    write_csv(
        RECOVERY_OUT,
        ["date", "day_status", "sleep_hours", "resting_hr_bpm", "hrv_sdnn_ms", "respiratory_rate", "oxygen_saturation_pct", "wrist_temperature_c", "baseline_complete_days", "baseline_rhr_median", "baseline_hrv_median", "baseline_sleep_median", "recovery_status", "reason"],
        recovery_rows,
    )
    write_csv(
        FAT_LOSS_OUT,
        ["as_of", "latest_measurement_date", "latest_weight_kg", "latest_body_fat_pct", "recent_7d_measurements", "recent_7d_average_weight_kg", "prior_7d_measurements", "prior_7d_average_weight_kg", "average_weight_change_kg", "recent_14d_waist_records", "plateau_status", "next_action", "definition"],
        fat_rows,
    )
    write_dashboard(set_rows, volume_rows, progression_rows, load_rows, recovery_rows, fat_rows, cardio, today)

    latest_health = health_rows[-1]
    final_health = latest_final_health(health_rows)
    snapshot = {
        "schema_version": "1.0.0",
        "generated_at": datetime.now(TZ).isoformat(timespec="seconds"),
        "timezone": "Asia/Shanghai",
        "sources": {
            "health": str(HEALTH),
            "training": str(TRAINING),
            "body": str(BODY),
            "sync_health": str(DB),
        },
        "latest_body": {
            "date": fat_rows[-1]["latest_measurement_date"],
            "weight_kg": number(str(fat_rows[-1]["latest_weight_kg"])),
            "body_fat_pct": number(str(fat_rows[-1]["latest_body_fat_pct"])),
            "source_rule": "Xiaomi S800 morning complete set only",
        },
        "today_health": {
            "date": latest_health["date"],
            "status": latest_health["status"],
            "sleep_hours": number(latest_health.get("sleep_hours")),
            "resting_hr_bpm": number(latest_health.get("resting_hr_bpm")),
            "hrv_sdnn_ms": number(latest_health.get("hrv_sdnn_ms")),
        },
        "latest_complete_health_day": None if final_health is None else {
            "date": final_health["date"],
            "estimated_total_kcal": number(final_health.get("estimated_total_kcal")),
            "energy_method": final_health.get("tdee_method", ""),
        },
        "training_load": load_rows[-1],
        "progression_engine": {
            "gate_version": "gated_double_progression_v1",
            "exercise_count": len(progression_rows),
            "states": {
                state: sum(row["progression_state"] == state for row in progression_rows)
                for state in sorted({str(row["progression_state"]) for row in progression_rows})
            },
            "recent_decisions": sorted(
                progression_rows,
                key=lambda row: str(row["latest_date"]),
                reverse=True,
            )[:12],
        },
        "recovery": recovery_rows[-1],
        "fat_loss": fat_rows[-1],
        "cardio_fitness": cardio,
        "optional_health_context": optional_context,
        "data_quality": {
            "structured_set_rows": len(set_rows),
            "progression_exercises": len(progression_rows),
            "recovery_baseline_complete_days": recovery_rows[-1]["baseline_complete_days"],
            "today_is_partial": latest_health["status"] == "partial",
        },
    }
    SNAPSHOT_OUT.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"动作组: {len(set_rows)} 行")
    print(f"动作进阶: {len(progression_rows)} 个同器械动作")
    print(
        "最新负荷: "
        f"7日={load_rows[-1]['rolling_7d_load']} "
        f"28日周均={load_rows[-1]['rolling_28d_weekly_average'] or '-'} "
        f"比值={load_rows[-1]['load_ratio_7d_to_28d_weekly'] or '-'} "
        f"状态={load_rows[-1]['load_status']}"
    )
    print(f"恢复基线: {recovery_rows[-1]['baseline_complete_days']}/14 完整日")
    print(f"减脂监测: {fat_rows[-1]['plateau_status']}")
    print(f"机器快照: {SNAPSHOT_OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
