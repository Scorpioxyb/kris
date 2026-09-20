#!/usr/bin/env python3
"""Backfill sleep timestamps from retained SyncHealth payloads and re-fold."""

from __future__ import annotations

import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
import sqlite3
import sys
from pathlib import Path


SYNC_HOME = Path(os.environ.get("SYNCHEALTH_HOME", Path.home() / ".synchealth"))
LOCAL_BIN = Path(os.environ.get("LOCAL_BIN", Path.home() / ".local" / "bin"))
DB = Path(os.environ.get("SYNCHEALTH_DB", SYNC_HOME / "health.db"))
RAW = Path(os.environ.get("SYNCHEALTH_RAW", SYNC_HOME / "raw"))
SERVER = Path(os.environ.get("SYNCHEALTH_SERVER", LOCAL_BIN / "synchealth-server"))
SLEEP = Path(os.environ.get("SYNCHEALTH_SLEEP_MODULE", LOCAL_BIN / "synchealth_sleep.py"))


def load(path: Path, name: str):
    spec = importlib.util.spec_from_loader(name, SourceFileLoader(name, str(path)))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"无法载入 {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    sys.path.insert(0, str(SERVER.parent))
    server = load(SERVER, "synchealth_server_repair")
    sleep = load(SLEEP, "synchealth_sleep_repair")
    latest: dict[str, tuple[str, str, str, float]] = {}
    files = 0
    for path in RAW.glob("*.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            continue
        files += 1
        samples = payload.get("data", {}).get("category_samples", [])
        if not isinstance(samples, list):
            continue
        for item in samples:
            if not isinstance(item, dict):
                continue
            ctype = (item.get("type") or "").split("Identifier")[-1]
            identifier = item.get("id")
            start_text = item.get("start_date") or item.get("startDate")
            end_text = item.get("end_date") or item.get("endDate")
            if ctype != "SleepAnalysis" or not identifier or not start_text or not end_text:
                continue
            _, start = server.parse_time(start_text)
            _, end = server.parse_time(end_text)
            if not start or not end or end <= start:
                continue
            label = (item.get("value_label") or "").strip()
            state = server.SLEEP_LABELS.get(label, label.replace(" ", "") or "Unknown")
            latest[str(identifier)] = (
                state,
                start_text,
                end_text,
                (end - start).total_seconds() / 60.0,
            )

    with sqlite3.connect(DB) as db:
        server.ensure_runtime_schema(db)
        sleep.ensure_sleep_segment_timestamps(db)
        db.executemany(
            "INSERT INTO sleep_segments(id,night,state,kind,minutes,start_at,end_at) "
            "VALUES (?,'',?,'night',?,?,?) ON CONFLICT(id) DO UPDATE SET "
            "state=excluded.state,minutes=excluded.minutes,start_at=excluded.start_at,end_at=excluded.end_at",
            [
                (identifier, state, minutes, start_text, end_text)
                for identifier, (state, start_text, end_text, minutes) in latest.items()
            ],
        )
        assigned = sleep.rebuild_sleep_sessions(db, server.parse_time)
        db.commit()
        latest_night = db.execute(
            "SELECT night,basis,hours FROM sleep_nights ORDER BY night DESC LIMIT 1"
        ).fetchone()
    print(
        f"扫描 {files} 个原始批次，回填 {len(latest)} 个唯一睡眠分段，"
        f"重分类 {assigned} 行；最新主睡眠={latest_night}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
