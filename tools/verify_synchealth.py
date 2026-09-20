#!/usr/bin/env python3
"""Read-only verification of the local phone-health sync pipeline."""

from __future__ import annotations

import json
import os
import sqlite3
import ssl
import sys
import urllib.request
from pathlib import Path


HOME = Path(os.environ.get("SYNCHEALTH_HOME", Path.home() / ".synchealth"))
DB = HOME / "health.db"
CONFIG = HOME / "server.json"
REQUIRED_TABLES = {"daily", "sleep", "workouts", "rings"}
ACTIVITY_METRICS = (
    "StepCount",
    "RestingHeartRate",
    "ActiveEnergyBurned",
)
BODY_COMPOSITION_METRICS = (
    "BodyMass",
    "BodyFatPercentage",
    "LeanBodyMass",
    "BodyMassIndex",
)


def endpoint_check() -> tuple[bool, str]:
    if not CONFIG.is_file():
        return False, "缺少 ~/.synchealth/server.json"
    try:
        config = json.loads(CONFIG.read_text(encoding="utf-8"))
        token = config["token"]
        base = f"https://{config['bind']}:{int(config['port'])}"
        request = urllib.request.Request(
            f"{base}/health",
            headers={"X-Health-Token": token},
        )
        context = ssl._create_unverified_context()
        with urllib.request.urlopen(request, context=context, timeout=8) as response:
            body = json.loads(response.read())
        if body.get("ok") is not True:
            return False, f"服务返回异常: {body}"
        return True, (
            f"服务可读: indexed_items={body.get('indexed_items')}, "
            f"metric_count={body.get('metric_count')}, raw_payloads={body.get('raw_payloads')}"
        )
    except Exception as exc:  # report a bounded diagnostic, never the token
        return False, f"服务不可读: {type(exc).__name__}: {exc}"


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []
    print("手机健康数据适配检查（只读）")
    print(f"数据目录: {HOME}")
    if not DB.is_file():
        print("结果: FAIL")
        print("ERROR: 缺少 health.db")
        return 1

    try:
        db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        tables = {
            row[0]
            for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        missing = REQUIRED_TABLES - tables
        if missing:
            errors.append(f"health.db 缺少表: {', '.join(sorted(missing))}")
        counts = {}
        for table in sorted(REQUIRED_TABLES):
            if table in tables:
                counts[table] = db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
        print("OK: 表和行数:", ", ".join(f"{k}={v}" for k, v in counts.items()))

        latest_workout = db.execute(
            "SELECT start, end, activity, round(minutes, 2), source "
            "FROM workouts ORDER BY start DESC LIMIT 1"
        ).fetchone()
        if latest_workout:
            print("OK: 最新运动:", " | ".join(map(str, latest_workout)))
        else:
            errors.append("workouts 没有记录")

        complete_body_composition = None
        if "samples" in tables:
            complete_body_composition = db.execute(
                "SELECT weight.day, weight.at, weight.value, fat.value, "
                "lean.value, bmi.value "
                "FROM samples AS weight "
                "JOIN samples AS fat ON fat.day=weight.day AND fat.at=weight.at "
                "JOIN samples AS lean ON lean.day=weight.day AND lean.at=weight.at "
                "JOIN samples AS bmi ON bmi.day=weight.day AND bmi.at=weight.at "
                "WHERE weight.metric=? AND fat.metric=? AND lean.metric=? "
                "AND bmi.metric=? ORDER BY weight.at DESC LIMIT 1",
                BODY_COMPOSITION_METRICS,
            ).fetchone()
        if complete_body_composition:
            day, at, weight, fat, lean, bmi = complete_body_composition
            print(
                "OK: 最新完整体测（同时间成套样本）: "
                f"{at} | {weight} kg | 体脂 {fat}% | "
                f"去脂体重 {lean} kg | BMI {bmi}"
            )
        else:
            warnings.append(
                "没有找到体重、体脂、去脂体重和 BMI 同时间成套样本；"
                "孤立体重不用于覆盖完整晨起体测"
            )

        for metric in ACTIVITY_METRICS:
            row = db.execute(
                "SELECT day, value, unit FROM daily WHERE metric=? "
                "AND value IS NOT NULL ORDER BY day DESC LIMIT 1",
                (metric,),
            ).fetchone()
            if row:
                print(f"OK: {metric}: {row[0]} = {row[1]} {row[2] or ''}".rstrip())
            else:
                print(f"WARN: {metric}: 当前库没有可用值")
        db.close()
    except (OSError, sqlite3.Error, ValueError) as exc:
        errors.append(f"health.db 读取失败: {exc}")

    healthy, message = endpoint_check()
    print(("OK: " if healthy else "WARN: ") + message)
    if not healthy:
        warnings.append(message)

    if errors:
        print("结果: FAIL")
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    if warnings:
        print("结果: PASS_WITH_WARNINGS（health.db 只读检查通过；服务端点受当前运行环境限制）")
    else:
        print("结果: PASS（手机健康数据只读检查通过）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
