#!/usr/bin/env python3
"""Build a quality-gated daily fitness summary from the local SyncHealth DB."""

from __future__ import annotations

import csv
import json
import os
import sqlite3
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path
from statistics import median
from zoneinfo import ZoneInfo


SYNC_HOME = Path(os.environ.get("SYNCHEALTH_HOME", Path.home() / ".synchealth"))
DB = Path(os.environ.get("SYNCHEALTH_DB", SYNC_HOME / "health.db"))
RAW = Path(os.environ.get("SYNCHEALTH_RAW", SYNC_HOME / "raw"))
COMPANION_DB = Path(
    os.environ.get(
        "KRIS_COMPANION_DB",
        Path(os.environ.get("KRIS_COMPANION_STATE", Path(__file__).parents[1] / "companion" / ".state"))
        / "companion.sqlite3",
    )
)
DATA = Path(
    os.environ.get(
        "KRIS_VAULT_DATA",
        Path.home() / "Documents" / "Obsidian Vault" / "Kris 健身数据",
    )
)
TRAINING_CSV = DATA / "训练记录.csv"
CSV_OUT = DATA / "每日健康汇总.csv"
DASHBOARD_OUT = DATA / "01-数据看板/健康日结看板.md"
TZ = ZoneInfo("Asia/Shanghai")

FIELDS = [
    "date",
    "status",
    "weight_kg",
    "body_fat_pct",
    "lean_body_mass_kg",
    "bmi",
    "sleep_hours",
    "sleep_core_min",
    "sleep_deep_min",
    "sleep_rem_min",
    "sleep_awake_min",
    "nap_min",
    "steps",
    "walking_running_km",
    "active_kcal_raw",
    "ring_active_kcal",
    "active_kcal_used",
    "active_quality",
    "resting_kcal_raw",
    "resting_kcal_used",
    "resting_quality",
    "estimated_total_kcal",
    "tdee_method",
    "exercise_min",
    "stand_hours",
    "stand_minutes",
    "resting_hr_bpm",
    "hrv_sdnn_ms",
    "avg_hr_bpm",
    "max_hr_bpm",
    "respiratory_rate",
    "oxygen_saturation_pct",
    "physical_effort_met",
    "daylight_min",
    "walking_hr_bpm",
    "vo2max_ml_kg_min",
    "walking_speed_m_s",
    "walking_step_length_m",
    "walking_double_support_pct",
    "walking_asymmetry_pct",
    "wrist_temperature_c",
    "flights_climbed",
    "stair_ascent_speed_m_s",
    "stair_descent_speed_m_s",
    "environmental_audio_db",
    "workout_effort_score_avg",
    "estimated_workout_effort_score_avg",
    "swimming_distance_m",
    "swimming_stroke_count",
    "state_of_mind_count",
    "state_of_mind_valence_avg",
    "ecg_count",
    "ecg_classifications",
    "training_count",
    "training_minutes",
    "training_names",
    "healthkit_workout_count",
    "healthkit_workout_minutes",
    "healthkit_workout_types",
    "notes",
]


def fmt(value: float | None, digits: int = 1) -> str:
    if value is None:
        return ""
    return f"{value:.{digits}f}"


def metric_value(metrics: dict[str, sqlite3.Row], name: str) -> float | None:
    row = metrics.get(name)
    return None if row is None else row["value"]


def metric_sum(metrics: dict[str, sqlite3.Row], name: str) -> float | None:
    row = metrics.get(name)
    return None if row is None else row["sum"]


def energy_shape(db: sqlite3.Connection) -> dict[tuple[str, str], dict[str, float]]:
    rows = db.execute(
        """
        WITH slots AS (
          SELECT day, metric, at, count(*) AS samples_at
          FROM samples
          WHERE metric IN ('ActiveEnergyBurned', 'BasalEnergyBurned')
          GROUP BY day, metric, at
        )
        SELECT day, metric, count(*) AS hour_slots,
               sum(CASE WHEN samples_at > 1 THEN 1 ELSE 0 END) AS overlapping_slots,
               max(samples_at) AS max_samples_same_slot
        FROM slots
        GROUP BY day, metric
        """
    ).fetchall()
    return {
        (row["day"], row["metric"]): {
            "hour_slots": row["hour_slots"],
            "overlapping_slots": row["overlapping_slots"],
            "max_samples_same_slot": row["max_samples_same_slot"],
        }
        for row in rows
    }


def parse_duration_minutes(value: str) -> float | None:
    parts = value.strip().split(":")
    if len(parts) != 3:
        return None
    try:
        hours, minutes, seconds = (int(part) for part in parts)
    except ValueError:
        return None
    return hours * 60 + minutes + seconds / 60


def parse_health_datetime(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S %z")


def interval_union_minutes(
    intervals: list[tuple[datetime, datetime]],
) -> float:
    """Return elapsed minutes after merging duplicate and overlapping intervals."""
    valid = sorted((start, end) for start, end in intervals if end > start)
    if not valid:
        return 0.0
    merged: list[list[datetime]] = []
    for start, end in valid:
        if not merged or start > merged[-1][1]:
            merged.append([start, end])
        elif end > merged[-1][1]:
            merged[-1][1] = end
    return sum((end - start).total_seconds() / 60 for start, end in merged)


def iphone_health_overrides(path: Path = COMPANION_DB) -> dict[str, object]:
    """Build source-exclusive daily overlays from complete iPhone HealthKit metrics."""
    empty = {"daily": {}, "sleep": {}, "workouts": {}, "energy_shape": {}, "complete": set()}
    if not path.is_file():
        return empty
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        coverage_rows = db.execute(
            """SELECT device_id, date, metric, status, updated_at
               FROM health_coverage ORDER BY updated_at"""
        ).fetchall()
        sample_rows = db.execute(
            """SELECT device_id, metric, start_at, end_at, value, source, metadata_json
               FROM health_samples"""
        ).fetchall()
    except sqlite3.Error:
        return empty
    finally:
        if "db" in locals():
            db.close()

    selected_device: dict[tuple[str, str], str] = {}
    for row in coverage_rows:
        key = (str(row["date"]), str(row["metric"]))
        if row["status"] == "complete":
            selected_device[key] = str(row["device_id"])
        else:
            selected_device.pop(key, None)

    grouped: defaultdict[tuple[str, str], list[dict[str, object]]] = defaultdict(list)
    for row in sample_rows:
        try:
            started = datetime.fromisoformat(str(row["start_at"]).replace("Z", "+00:00")).astimezone(TZ)
            ended = datetime.fromisoformat(str(row["end_at"]).replace("Z", "+00:00")).astimezone(TZ)
        except ValueError:
            continue
        key = (started.date().isoformat(), str(row["metric"]))
        if selected_device.get(key) != row["device_id"]:
            continue
        try:
            metadata = json.loads(row["metadata_json"] or "{}")
        except json.JSONDecodeError:
            metadata = {}
        grouped[key].append(
            {
                "start": started, "end": ended, "value": float(row["value"]),
                "source": str(row["source"]), "metadata": metadata,
            }
        )

    daily: defaultdict[str, dict[str, dict[str, float]]] = defaultdict(dict)
    sleep: dict[str, dict[str, float]] = {}
    workouts: defaultdict[str, list[dict[str, object]]] = defaultdict(list)
    energy_shapes: dict[tuple[str, str], dict[str, float]] = {}
    complete = set(selected_device)
    mapping = {
        "hrv_sdnn": ("HeartRateVariabilitySDNN", "average"),
        "resting_heart_rate": ("RestingHeartRate", "average"),
        "step_count": ("StepCount", "sum"),
        "active_energy": ("ActiveEnergyBurned", "sum"),
        "basal_energy": ("BasalEnergyBurned", "sum"),
        "vo2_max": ("VO2Max", "latest"),
    }
    for (day, metric), rows in grouped.items():
        if metric == "sleep":
            intervals = [(row["start"], row["end"]) for row in rows]
            sleep[day] = {"hours": interval_union_minutes(intervals) / 60}
            continue
        if metric == "workout":
            for row in rows:
                workouts[day].append(
                    {
                        "activity": "iPhone HealthKit workout",
                        "minutes": max(0.0, (row["end"] - row["start"]).total_seconds() / 60),
                    }
                )
            continue
        definition = mapping.get(metric)
        if definition is None:
            continue
        sync_name, mode = definition
        values = [float(row["value"]) for row in rows]
        value = sum(values) if mode == "sum" else values[-1] if mode == "latest" else sum(values) / len(values)
        daily[day][sync_name] = {"value": value, "sum": value, "avg": value, "max": max(values)}
        if metric in {"active_energy", "basal_energy"}:
            intervals = [(row["start"], row["end"]) for row in rows if row["end"] > row["start"]]
            slots: set[tuple[int, int, int, int]] = set()
            for start, end in intervals:
                cursor = start.replace(minute=0, second=0, microsecond=0)
                while cursor < end:
                    slots.add((cursor.year, cursor.month, cursor.day, cursor.hour))
                    cursor += timedelta(hours=1)
            raw_minutes = sum((end - start).total_seconds() / 60 for start, end in intervals)
            union_minutes = interval_union_minutes(intervals)
            energy_shapes[(day, sync_name)] = {
                "hour_slots": float(len(slots)),
                "overlapping_slots": 1.0 if raw_minutes > union_minutes + 1 else 0.0,
                "max_samples_same_slot": 1.0,
            }

    body_metrics = {
        "body_mass": "BodyMass", "body_fat_percentage": "BodyFatPercentage",
        "lean_body_mass": "LeanBodyMass", "bmi": "BodyMassIndex",
    }
    body_days = {day for day, metric in complete if metric in body_metrics}
    for day in body_days:
        if not all((day, metric) in complete for metric in body_metrics):
            continue
        candidates = grouped.get((day, "body_mass"), [])
        for anchor in sorted(candidates, key=lambda row: row["start"], reverse=True):
            values: dict[str, float] = {}
            for metric, sync_name in body_metrics.items():
                matches = [
                    row for row in grouped.get((day, metric), [])
                    if row["source"] == anchor["source"]
                    and abs((row["start"] - anchor["start"]).total_seconds()) <= 120
                ]
                if matches:
                    values[sync_name] = float(min(matches, key=lambda row: abs((row["start"] - anchor["start"]).total_seconds()))["value"])
            if len(values) == len(body_metrics):
                for sync_name, value in values.items():
                    daily[day][sync_name] = {"value": value, "sum": value, "avg": value, "max": value}
                break

    return {
        "daily": dict(daily), "sleep": sleep, "workouts": dict(workouts),
        "energy_shape": energy_shapes, "complete": complete,
    }


def deduplicated_sleep(
    db: sqlite3.Connection,
) -> tuple[dict[str, dict[str, float]], dict[tuple[str, str, str], float], set[str]]:
    """Rebuild sleep totals from raw sample intervals instead of summed duplicates."""
    segment_rows = list(
        db.execute("SELECT id, night, state, kind FROM sleep_segments")
    )
    segments = {row["id"]: row for row in segment_rows}
    intervals: defaultdict[
        tuple[str, str, str], list[tuple[datetime, datetime]]
    ] = defaultdict(list)
    matched_ids: set[str] = set()

    if RAW.is_dir() and segments:
        for path in RAW.glob("*.json"):
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                continue
            samples = payload.get("data", {}).get("category_samples", [])
            if not isinstance(samples, list):
                continue
            for sample in samples:
                if not isinstance(sample, dict):
                    continue
                segment_id = sample.get("id")
                row = segments.get(segment_id)
                if row is None:
                    continue
                start_text = sample.get("start_date")
                end_text = sample.get("end_date")
                if not isinstance(start_text, str) or not isinstance(end_text, str):
                    continue
                try:
                    start = parse_health_datetime(start_text)
                    end = parse_health_datetime(end_text)
                except ValueError:
                    continue
                intervals[(row["night"], row["state"], row["kind"])].append(
                    (start, end)
                )
                matched_ids.add(segment_id)

    complete_nights = {
        row["night"]
        for row in segment_rows
        if row["id"] in matched_ids
    }
    for row in segment_rows:
        if row["id"] not in matched_ids:
            complete_nights.discard(row["night"])

    fallback_nights = {
        row["night"]: {"hours": row["hours"] or 0.0}
        for row in db.execute("SELECT night, hours FROM sleep_nights")
    }
    fallback_states = {
        (row["night"], row["state"], row["kind"]): row["minutes"] or 0.0
        for row in db.execute("SELECT night, state, kind, minutes FROM sleep")
    }

    sleep_nights = dict(fallback_nights)
    sleep_states = dict(fallback_states)
    for night in complete_nights:
        night_intervals: list[tuple[datetime, datetime]] = []
        for (row_night, state, kind), values in intervals.items():
            if row_night != night:
                continue
            sleep_states[(row_night, state, kind)] = interval_union_minutes(values)
            if kind == "night" and state.startswith("Asleep"):
                night_intervals.extend(values)
        sleep_nights[night] = {
            "hours": interval_union_minutes(night_intervals) / 60
        }

    return sleep_nights, sleep_states, complete_nights


def archived_training() -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = defaultdict(
        lambda: {"count": 0, "minutes": 0.0, "names": []}
    )
    if not TRAINING_CSV.is_file():
        return result
    with TRAINING_CSV.open("r", encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            day = (row.get("date") or "").strip()
            if not day:
                continue
            result[day]["count"] = int(result[day]["count"]) + 1
            result[day]["names"].append((row.get("session_name") or "").strip())
            duration = parse_duration_minutes(row.get("duration") or "")
            if duration is not None:
                result[day]["minutes"] = float(result[day]["minutes"]) + duration
    return result


def build_rows(db: sqlite3.Connection) -> list[dict[str, str]]:
    today = datetime.now(TZ).date()
    daily: dict[str, dict[str, sqlite3.Row]] = defaultdict(dict)
    for row in db.execute("SELECT * FROM daily ORDER BY day, metric"):
        daily[row["day"]][row["metric"]] = row
    iphone = iphone_health_overrides()
    iphone_daily = iphone["daily"]
    assert isinstance(iphone_daily, dict)
    for day_text, metrics in iphone_daily.items():
        daily[day_text].update(metrics)
    iphone_complete = iphone["complete"]
    assert isinstance(iphone_complete, set)

    rings = {
        row["day"]: row
        for row in db.execute("SELECT * FROM rings ORDER BY day")
    }
    sleep_nights, sleep_states, deduplicated_nights = deduplicated_sleep(db)
    iphone_sleep = iphone["sleep"]
    assert isinstance(iphone_sleep, dict)
    for night, summary in iphone_sleep.items():
        sleep_nights[night] = summary
        for key in [key for key in sleep_states if key[0] == night]:
            del sleep_states[key]
        deduplicated_nights.add(night)

    workouts: dict[str, list[sqlite3.Row]] = defaultdict(list)
    for row in db.execute("SELECT * FROM workouts ORDER BY start"):
        workouts[row["start"][:10]].append(row)
    iphone_workouts = iphone["workouts"]
    assert isinstance(iphone_workouts, dict)
    for day_text, rows in iphone_workouts.items():
        workouts[day_text] = rows

    state_of_mind = {
        row["day"]: row
        for row in db.execute(
            """
            SELECT day, count(*) AS event_count,
                   avg(json_extract(payload, '$.valence')) AS valence_avg
            FROM generic_events
            WHERE section='state_of_mind' AND day IS NOT NULL
            GROUP BY day
            """
        )
    }
    ecg: defaultdict[str, dict[str, object]] = defaultdict(
        lambda: {"count": 0, "classifications": set()}
    )
    for row in db.execute(
        """
        SELECT day, json_extract(payload, '$.classification') AS classification
        FROM generic_events
        WHERE section='ecg_recordings' AND day IS NOT NULL
        """
    ):
        ecg[row["day"]]["count"] = int(ecg[row["day"]]["count"]) + 1
        if row["classification"]:
            classifications = ecg[row["day"]]["classifications"]
            assert isinstance(classifications, set)
            classifications.add(row["classification"])

    complete_body: dict[str, sqlite3.Row] = {}
    for row in db.execute(
        """
        SELECT weight.day, weight.at, weight.value AS weight_kg,
               fat.value AS body_fat_pct, lean.value AS lean_body_mass_kg,
               bmi.value AS bmi
        FROM samples AS weight
        JOIN samples AS fat ON fat.day=weight.day AND fat.at=weight.at
        JOIN samples AS lean ON lean.day=weight.day AND lean.at=weight.at
        JOIN samples AS bmi ON bmi.day=weight.day AND bmi.at=weight.at
        WHERE weight.metric='BodyMass'
          AND fat.metric='BodyFatPercentage'
          AND lean.metric='LeanBodyMass'
          AND bmi.metric='BodyMassIndex'
        ORDER BY weight.day, weight.at
        """
    ):
        complete_body[row["day"]] = row

    training_archive = archived_training()

    shape = energy_shape(db)
    iphone_shape = iphone["energy_shape"]
    assert isinstance(iphone_shape, dict)
    shape.update(iphone_shape)
    accepted_resting: list[tuple[date, float]] = []
    output: list[dict[str, str]] = []

    iphone_sleep_days = {
        (date.fromisoformat(night) + timedelta(days=1)).isoformat()
        for night in iphone_sleep
    }
    all_days = set(daily) | set(iphone_workouts) | iphone_sleep_days
    for day_text in sorted(all_days):
        day = date.fromisoformat(day_text)
        metrics = daily[day_text]
        iphone_body_complete = all(
            (day_text, metric) in iphone_complete
            for metric in ("body_mass", "body_fat_percentage", "lean_body_mass", "bmi")
        )
        body = None if iphone_body_complete else complete_body.get(day_text)
        state_event = state_of_mind.get(day_text)
        ecg_event = ecg.get(day_text, {"count": 0, "classifications": set()})
        status = "partial" if day == today else "final"
        ring = rings.get(day_text)
        notes: list[str] = []
        iphone_metrics = sorted(metric for date_text, metric in iphone_complete if date_text == day_text)
        if iphone_metrics:
            notes.append("完整指标优先采用iPhone HealthKit：" + ",".join(iphone_metrics))
        day_workouts = workouts.get(day_text, [])
        workout_types = ";".join(row["activity"] for row in day_workouts)
        workout_minutes = sum((row["minutes"] or 0.0) for row in day_workouts)
        training = training_archive.get(
            day_text, {"count": 0, "minutes": 0.0, "names": []}
        )
        missing_workout_coverage = int(training["count"]) > 0 and not day_workouts

        active_raw = metric_value(metrics, "ActiveEnergyBurned")
        iphone_active = (day_text, "active_energy") in iphone_complete
        ring_active = None if ring is None or iphone_active else ring["active_kcal"]
        active_shape = shape.get((day_text, "ActiveEnergyBurned"), {})
        if iphone_active and active_raw is not None:
            active_used = active_raw
            active_quality = "iphone_healthkit_complete"
        elif ring_active is not None:
            active_used = ring_active
            active_quality = "partial_ring" if status == "partial" else "ring_primary"
            if active_raw is not None and ring_active:
                gap_pct = 100.0 * (active_raw - ring_active) / ring_active
                if abs(gap_pct) >= 5:
                    notes.append(f"daily活动能量与圆环相差{gap_pct:.1f}%")
        elif active_raw is not None:
            active_used = active_raw
            overlaps = int(active_shape.get("overlapping_slots", 0))
            active_quality = "daily_overlap" if overlaps else "daily_fallback"
        else:
            active_used = None
            active_quality = "missing"

        if missing_workout_coverage:
            active_quality = "missing_workout_coverage"
            notes.append("Obsidian有训练记录但HealthKit无对应workout，活动能量覆盖不完整")

        resting_raw = metric_value(metrics, "BasalEnergyBurned")
        resting_shape = shape.get((day_text, "BasalEnergyBurned"), {})
        prior = [
            value
            for prior_day, value in accepted_resting
            if 0 < (day - prior_day).days <= 7
        ]
        prior_median = median(prior) if prior else None
        overlaps = int(resting_shape.get("overlapping_slots", 0))
        slots = int(resting_shape.get("hour_slots", 0))

        if status == "partial":
            resting_quality = "partial"
            resting_used = None
        elif resting_raw is None:
            resting_quality = "missing"
            resting_used = prior_median
        elif slots < 22:
            resting_quality = "incomplete"
            resting_used = prior_median
        elif overlaps:
            resting_quality = "overlapping_samples"
            resting_used = prior_median
        elif prior_median and not 0.75 * prior_median <= resting_raw <= 1.25 * prior_median:
            resting_quality = "outlier"
            resting_used = prior_median
        else:
            resting_quality = "accepted"
            resting_used = resting_raw
            accepted_resting.append((day, resting_raw))

        if resting_quality != "accepted" and resting_raw is not None:
            notes.append(f"静息能量原始值{resting_raw:.1f}kcal标记为{resting_quality}")

        estimated_total = None
        method = ""
        if (
            status == "final"
            and active_used is not None
            and resting_used is not None
                and active_quality in {"ring_primary", "daily_fallback", "iphone_healthkit_complete"}
        ):
            estimated_total = active_used + resting_used
            method = (
                "iphone_active+basal_raw"
                if iphone_active and resting_quality == "accepted"
                else "iphone_active+prior_7d_median_basal"
                if iphone_active
                else "ring_active+basal_raw"
                if resting_quality == "accepted"
                else "ring_active+prior_7d_median_basal"
            )

        previous_night = (day - timedelta(days=1)).isoformat()
        sleep_night = sleep_nights.get(previous_night)
        sleep_hours = None if sleep_night is None else sleep_night["hours"]
        sleep_core = sleep_states.get((previous_night, "AsleepCore", "night"))
        sleep_deep = sleep_states.get((previous_night, "AsleepDeep", "night"))
        sleep_rem = sleep_states.get((previous_night, "AsleepREM", "night"))
        sleep_awake = sleep_states.get((previous_night, "Awake", "night"))
        nap = sum(
            value
            for (night, _state, kind), value in sleep_states.items()
            if night == day_text and kind == "nap"
        )
        if previous_night in deduplicated_nights:
            notes.append("夜间睡眠已按原始样本时间区间去重")
        if previous_night in iphone_sleep:
            notes.append("睡眠完整区间采用iPhone HealthKit")

        distance_m = metric_sum(metrics, "distance_walking_running")
        daylight_s = metric_sum(metrics, "TimeInDaylight")
        heart_row = metrics.get("HeartRate")

        output.append(
            {
                "date": day_text,
                "status": status,
                "weight_kg": fmt(
                    body["weight_kg"] if body else metric_value(metrics, "BodyMass"), 2
                ),
                "body_fat_pct": fmt(
                    body["body_fat_pct"]
                    if body
                    else metric_value(metrics, "BodyFatPercentage"),
                    1,
                ),
                "lean_body_mass_kg": fmt(
                    body["lean_body_mass_kg"]
                    if body
                    else metric_value(metrics, "LeanBodyMass"),
                    1,
                ),
                "bmi": fmt(
                    body["bmi"] if body else metric_value(metrics, "BodyMassIndex"), 1
                ),
                "sleep_hours": fmt(sleep_hours, 2),
                "sleep_core_min": fmt(sleep_core, 1),
                "sleep_deep_min": fmt(sleep_deep, 1),
                "sleep_rem_min": fmt(sleep_rem, 1),
                "sleep_awake_min": fmt(sleep_awake, 1),
                "nap_min": fmt(nap or None, 1),
                "steps": fmt(metric_value(metrics, "StepCount"), 0),
                "walking_running_km": fmt(None if distance_m is None else distance_m / 1000, 2),
                "active_kcal_raw": fmt(active_raw, 1),
                "ring_active_kcal": fmt(ring_active, 1),
                "active_kcal_used": fmt(active_used, 1),
                "active_quality": active_quality,
                "resting_kcal_raw": fmt(resting_raw, 1),
                "resting_kcal_used": fmt(resting_used, 1),
                "resting_quality": resting_quality,
                "estimated_total_kcal": fmt(estimated_total, 1),
                "tdee_method": method,
                "exercise_min": fmt(
                    None if ring is None else ring["exercise_min"], 0
                ),
                "stand_hours": fmt(None if ring is None else ring["stand_hours"], 0),
                "stand_minutes": fmt(metric_sum(metrics, "AppleStandTime"), 0),
                "resting_hr_bpm": fmt(metric_value(metrics, "RestingHeartRate"), 1),
                "hrv_sdnn_ms": fmt(metric_value(metrics, "HeartRateVariabilitySDNN"), 1),
                "avg_hr_bpm": fmt(None if heart_row is None else heart_row["avg"], 1),
                "max_hr_bpm": fmt(None if heart_row is None else heart_row["max"], 1),
                "respiratory_rate": fmt(metric_value(metrics, "RespiratoryRate"), 1),
                "oxygen_saturation_pct": fmt(metric_value(metrics, "OxygenSaturation"), 1),
                "physical_effort_met": fmt(metric_value(metrics, "PhysicalEffort"), 2),
                "daylight_min": fmt(None if daylight_s is None else daylight_s / 60, 0),
                "walking_hr_bpm": fmt(metric_value(metrics, "WalkingHeartRateAverage"), 1),
                "vo2max_ml_kg_min": fmt(metric_value(metrics, "VO2Max"), 1),
                "walking_speed_m_s": fmt(metric_value(metrics, "WalkingSpeed"), 2),
                "walking_step_length_m": fmt(metric_value(metrics, "WalkingStepLength"), 2),
                "walking_double_support_pct": fmt(
                    metric_value(metrics, "WalkingDoubleSupportPercentage"), 1
                ),
                "walking_asymmetry_pct": fmt(
                    metric_value(metrics, "WalkingAsymmetryPercentage"), 1
                ),
                "wrist_temperature_c": fmt(
                    metric_value(metrics, "apple_sleeping_wrist_temperature"), 2
                ),
                "flights_climbed": fmt(metric_sum(metrics, "FlightsClimbed"), 0),
                "stair_ascent_speed_m_s": fmt(
                    metric_value(metrics, "StairAscentSpeed"), 2
                ),
                "stair_descent_speed_m_s": fmt(
                    metric_value(metrics, "StairDescentSpeed"), 2
                ),
                "environmental_audio_db": fmt(
                    metric_value(metrics, "EnvironmentalAudioExposure"), 1
                ),
                "workout_effort_score_avg": fmt(
                    metric_value(metrics, "workout_effort_score"), 1
                ),
                "estimated_workout_effort_score_avg": fmt(
                    metric_value(metrics, "estimated_workout_effort_score"), 1
                ),
                "swimming_distance_m": fmt(
                    metric_sum(metrics, "distance_swimming"), 0
                ),
                "swimming_stroke_count": fmt(
                    metric_sum(metrics, "SwimmingStrokeCount"), 0
                ),
                "state_of_mind_count": str(
                    0 if state_event is None else state_event["event_count"]
                ),
                "state_of_mind_valence_avg": fmt(
                    None if state_event is None else state_event["valence_avg"], 2
                ),
                "ecg_count": str(ecg_event["count"]),
                "ecg_classifications": ";".join(
                    sorted(str(value) for value in ecg_event["classifications"])
                ),
                "training_count": str(training["count"]),
                "training_minutes": fmt(float(training["minutes"]) or None, 1),
                "training_names": ";".join(training["names"]),
                "healthkit_workout_count": str(len(day_workouts)),
                "healthkit_workout_minutes": fmt(workout_minutes or None, 1),
                "healthkit_workout_types": workout_types,
                "notes": "；".join(notes),
            }
        )
    return output


def write_csv(rows: list[dict[str, str]]) -> None:
    with CSV_OUT.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def write_dashboard(rows: list[dict[str, str]]) -> None:
    today = datetime.now(TZ).date().isoformat()
    recent = rows[-10:]
    latest_final = next((row for row in reversed(rows) if row["status"] == "final"), None)
    lines = [
        "---",
        "type: daily-health-dashboard",
        f"updated: {today}",
        "source: 每日健康汇总.csv, SyncHealth health.db",
        "---",
        "",
        "# 健康日结看板",
        "",
        "[[总览|← 返回总览]]　[[体测看板]]　[[训练看板]]　[[教练监控看板]]　[[训练决策看板]]",
        "",
        "> [!tldr] 口径",
        "> 完整日优先使用 Apple 圆环活动能量；静息能量通过小时覆盖、重叠样本和7日中位数做质量门槛。总消耗估算仅用于趋势和饮食校准，不直接按运动量吃回。表内睡眠按该日期对应的前一晚至当天早晨夜间睡眠统计，不代表该日期全天睡眠；当天未结束的数据标记为 `partial`。",
        "",
        "## 最近每日汇总",
        "",
        "| 日期 | 状态 | 体重 | 前一夜夜间睡眠 | 步数 | 活动能量采用值 | 静息能量采用值 | 估算总消耗 | 训练 | 质量说明 |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    quality_labels = {
        "accepted": "可采用",
        "overlapping_samples": "静息样本重叠，使用7日基线",
        "missing_workout_coverage": "训练未被HealthKit覆盖",
        "partial": "当天未结束",
        "incomplete": "静息小时覆盖不足",
        "outlier": "静息能量异常",
        "missing": "缺失",
    }
    for row in recent:
        quality_parts = [
            quality_labels.get(row["resting_quality"], row["resting_quality"])
        ]
        if row["active_quality"] not in {"ring_primary", "partial_ring"}:
            quality_parts.append(
                quality_labels.get(row["active_quality"], row["active_quality"])
            )
        quality = "；".join(dict.fromkeys(quality_parts))
        lines.append(
            "| {date} | {status} | {weight} | {sleep} | {steps} | {active} | {resting} | {total} | {workouts}次/{minutes}分 | {quality} |".format(
                date=row["date"],
                status=row["status"],
                weight=(row["weight_kg"] + "kg") if row["weight_kg"] else "—",
                sleep=(row["sleep_hours"] + "h") if row["sleep_hours"] else "—",
                steps=row["steps"] or "—",
                active=(row["active_kcal_used"] + "kcal") if row["active_kcal_used"] else "—",
                resting=(row["resting_kcal_used"] + "kcal") if row["resting_kcal_used"] else "—",
                total=(row["estimated_total_kcal"] + "kcal") if row["estimated_total_kcal"] else "—",
                workouts=row["training_count"],
                minutes=row["training_minutes"] or "0",
                quality=quality,
            )
        )

    lines.extend(["", "## 当前判断", ""])
    if latest_final:
        lines.append(
            f"- 最新完整日为 {latest_final['date']}：设备质量门槛后的总消耗估算约 {latest_final['estimated_total_kcal'] or '不可用'} kcal。"
        )
        if latest_final["notes"]:
            lines.append(f"- 数据质量说明：{latest_final['notes']}。")
    lines.extend(
        [
            "- 体重、腰围和训练表现仍是热量校准的结果指标；手表能量是输入证据之一，不是单日处方真值。",
            "- 心率、HRV、呼吸、血氧、步态、日照、心境与ECG覆盖均保留在 CSV；只有达到相应完整性和连续性时才参与对应判断。心境仅作低权重背景，ECG不用于自行诊断或正常训练加量。",
            "",
        ]
    )
    DASHBOARD_OUT.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    if not DB.is_file():
        raise SystemExit(f"缺少 SyncHealth 数据库: {DB}")
    if not (DATA.parent / ".obsidian").is_dir():
        raise SystemExit(f"不是有效的 Obsidian vault: {DATA.parent}")

    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        rows = build_rows(db)
    finally:
        db.close()
    write_csv(rows)
    write_dashboard(rows)
    latest = rows[-1] if rows else None
    print(f"已生成: {CSV_OUT}")
    print(f"已生成: {DASHBOARD_OUT}")
    if latest:
        print(
            "最新行: "
            f"{latest['date']} status={latest['status']} "
            f"weight={latest['weight_kg'] or '-'} "
            f"sleep={latest['sleep_hours'] or '-'} "
            f"estimated_total={latest['estimated_total_kcal'] or '-'}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
