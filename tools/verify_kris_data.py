#!/usr/bin/env python3
"""Read-only sanity check for the Kris fitness data archive."""

from __future__ import annotations

import csv
import os
import sys
from datetime import date
from pathlib import Path


DATA = Path(
    os.environ.get(
        "KRIS_VAULT_DATA",
        Path.home() / "Documents" / "Obsidian Vault" / "Kris 健身数据",
    )
)
VAULT = DATA.parent
REQUIRED = {
    "体测记录.csv": ({"date"}, "date"),
    "训练记录.csv": ({"date", "session_name"}, "date"),
    "饮食执行记录.csv": ({"date"}, "date"),
    "食材库存.csv": ({"snapshot_date", "item", "food_group", "status"}, "snapshot_date"),
    "营养目标与覆盖.csv": ({"as_of", "dimension", "coverage_status", "interpretation_rule"}, "as_of"),
    "每日健康汇总.csv": ({"date", "status", "estimated_total_kcal"}, "date"),
    "动作组记录.csv": ({"date", "session_name", "exercise", "set_index", "reps"}, "date"),
    "肌群周训练量.csv": ({"week_start", "muscle_group", "confirmed_direct_sets"}, "week_start"),
    "动作进阶建议.csv": ({"latest_date", "exercise", "equipment_variant", "progression_state", "decision_evidence", "rollback_condition", "next_action"}, "latest_date"),
    "训练负荷汇总.csv": ({"date", "rolling_7d_load", "load_status", "short_term_7d_ema", "long_term_42d_ema", "load_balance", "performance_model_status"}, "date"),
    "恢复状态.csv": ({"date", "baseline_complete_days", "recovery_status"}, "date"),
    "减脂趋势.csv": ({"as_of", "plateau_status", "next_action"}, "as_of"),
    "数据质量状态.csv": ({"check_id", "status", "severity", "evidence"}, "latest_date"),
    "症状事件.csv": ({"date", "session_name", "symptom_status", "trigger_tags"}, "date"),
    "症状触发汇总.csv": ({"trigger", "symptom_recorded_sessions", "symptom_positive_sessions"}, "last_positive_date"),
    "周教练汇总.csv": ({"week_start", "training_sessions", "duration_load_points"}, "week_start"),
    "动作纪录.csv": ({"exercise", "equipment_variant", "weight_scope", "record_status"}, "latest_date"),
    "排课状态.csv": ({"category", "last_completed_date", "sessions_7d", "status"}, "last_completed_date"),
    "心肺能力状态.csv": ({"as_of", "vo2max_count", "baseline_status"}, "as_of"),
}


def read_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError("缺少表头")
        rows = list(reader)
        return reader.fieldnames, rows


def parse_date(value: str, path: Path, row_number: int) -> date:
    try:
        return date.fromisoformat(value.strip())
    except ValueError as exc:
        raise ValueError(f"{path.name} 第 {row_number} 行日期无效: {value!r}") from exc


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []
    print("Kris 数据适配检查（只读）")
    print(f"数据目录: {DATA}")

    if not VAULT.is_dir() or not (VAULT / ".obsidian").is_dir():
        errors.append("未找到包含 .obsidian/ 的 Obsidian vault")
    if not DATA.is_dir():
        errors.append("未找到 Kris 健身数据目录")
        print("结果: FAIL")
        for error in errors:
            print(f"ERROR: {error}")
        return 1

    latest: dict[str, date] = {}
    counts: dict[str, int] = {}
    for filename, (required_fields, date_field) in REQUIRED.items():
        path = DATA / filename
        if not path.is_file():
            errors.append(f"缺少 {filename}")
            continue
        try:
            fields, rows = read_csv(path)
            missing = required_fields - set(fields)
            if missing:
                errors.append(f"{filename} 缺少字段: {', '.join(sorted(missing))}")
                continue
            parsed = [
                parse_date(row.get(date_field, ""), path, index)
                for index, row in enumerate(rows, start=2)
                if row.get(date_field, "").strip()
            ]
            if not parsed:
                errors.append(f"{filename} 没有可解析日期")
                continue
            latest[filename] = max(parsed)
            counts[filename] = len(rows)
            print(f"OK: {filename}: {len(rows)} 行, 最新 {latest[filename].isoformat()}")
        except (OSError, UnicodeError, ValueError) as exc:
            errors.append(f"{filename}: {exc}")

    overview = DATA / "总览.md"
    if overview.is_file():
        text = overview.read_text(encoding="utf-8")
        updated = next(
            (line.split(":", 1)[1].strip() for line in text.splitlines() if line.startswith("updated:")),
            None,
        )
        if updated:
            try:
                overview_date = date.fromisoformat(updated)
                newest_csv = max(latest.values(), default=overview_date)
                if newest_csv > overview_date:
                    warnings.append(
                        f"总览.md updated={overview_date.isoformat()}，但 CSV 最新到 {newest_csv.isoformat()}；读取时以 CSV 日期为准"
                    )
            except ValueError:
                warnings.append(f"总览.md 的 updated 字段不可解析: {updated!r}")

    readme = DATA / "README.md"
    if readme.is_file() and "2026-07-14" in readme.read_text(encoding="utf-8"):
        warnings.append("README.md 顶部仍显示 2026-07-14，可能早于结构化 CSV；不要用该文案判断最新状态")

    snapshot = DATA / "coach_snapshot.json"
    if not snapshot.is_file():
        errors.append("缺少 coach_snapshot.json")
    else:
        try:
            import json

            payload = json.loads(snapshot.read_text(encoding="utf-8"))
            for key in ("schema_version", "generated_at", "latest_body", "training_load", "progression_engine", "recovery", "fat_loss", "nutrition", "monitor", "decision_support"):
                if key not in payload:
                    errors.append(f"coach_snapshot.json 缺少字段: {key}")
        except (OSError, UnicodeError, ValueError) as exc:
            errors.append(f"coach_snapshot.json: {exc}")

    workflow = DATA / "训练流程状态.json"
    if not workflow.is_file():
        errors.append("缺少 训练流程状态.json")
    else:
        try:
            import json

            payload = json.loads(workflow.read_text(encoding="utf-8"))
            for key in ("schema_version", "current_plan", "completion_pipeline", "guard"):
                if key not in payload:
                    errors.append(f"训练流程状态.json 缺少字段: {key}")
        except (OSError, UnicodeError, ValueError) as exc:
            errors.append(f"训练流程状态.json: {exc}")

    if warnings:
        for warning in warnings:
            print(f"WARN: {warning}")
    if errors:
        print("结果: FAIL")
        for error in errors:
            print(f"ERROR: {error}")
        return 1

    print("结果: PASS（数据路径、字段和日期检查通过）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
