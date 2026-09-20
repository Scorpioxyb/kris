from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from uuid import uuid4

from companion.store import CompanionStore


MODULE_PATH = Path(__file__).parents[1] / "tools/build_daily_health_summary.py"
SPEC = importlib.util.spec_from_file_location("daily_health_summary", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DailyHealthSummaryTests(unittest.TestCase):
    def dt(self, value: str) -> datetime:
        return datetime.fromisoformat(value)

    def test_interval_union_removes_exact_duplicates(self) -> None:
        interval = (self.dt("2026-08-12T01:00:00+08:00"), self.dt("2026-08-12T02:00:00+08:00"))
        self.assertEqual(MODULE.interval_union_minutes([interval, interval]), 60.0)

    def test_interval_union_merges_partial_overlap(self) -> None:
        intervals = [
            (self.dt("2026-08-12T01:00:00+08:00"), self.dt("2026-08-12T02:00:00+08:00")),
            (self.dt("2026-08-12T01:30:00+08:00"), self.dt("2026-08-12T02:30:00+08:00")),
        ]
        self.assertEqual(MODULE.interval_union_minutes(intervals), 90.0)

    def test_interval_union_keeps_separate_intervals(self) -> None:
        intervals = [
            (self.dt("2026-08-12T01:00:00+08:00"), self.dt("2026-08-12T02:00:00+08:00")),
            (self.dt("2026-08-12T03:00:00+08:00"), self.dt("2026-08-12T03:30:00+08:00")),
        ]
        self.assertEqual(MODULE.interval_union_minutes(intervals), 90.0)

    def test_complete_iphone_metrics_are_loaded_without_duplicate_sleep(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "companion.sqlite3"
            store = CompanionStore(path, b"h" * 32)
            samples = [
                self.sample("active", "active_energy", "2026-08-31T08:00:00+08:00", "2026-08-31T09:00:00+08:00", 120, "kcal"),
                self.sample("sleep-1", "sleep", "2026-08-31T00:00:00+08:00", "2026-08-31T05:00:00+08:00", 18_000, "s"),
                self.sample("sleep-2", "sleep", "2026-08-31T04:00:00+08:00", "2026-08-31T08:00:00+08:00", 14_400, "s"),
            ]
            coverage = [
                {"date": "2026-08-31", "metric": "active_energy", "status": "complete"},
                {"date": "2026-08-31", "metric": "sleep", "status": "complete"},
            ]
            store.ingest_health_batch(
                {
                    "schema_version": "HealthBatch.v1", "batch_id": str(uuid4()), "device_id": "phone",
                    "created_at": "2026-09-01T08:00:00+08:00", "samples": samples, "coverage": coverage,
                },
                "phone",
            )
            result = MODULE.iphone_health_overrides(path)
            self.assertEqual(result["daily"]["2026-08-31"]["ActiveEnergyBurned"]["sum"], 120)
            self.assertEqual(result["sleep"]["2026-08-31"]["hours"], 8)

    @staticmethod
    def sample(identifier: str, metric: str, start: str, end: str, value: float, unit: str) -> dict[str, object]:
        return {
            "sample_uuid": identifier, "metric": metric, "start_at": start, "end_at": end,
            "value": value, "unit": unit, "source": "Apple Watch",
        }


if __name__ == "__main__":
    unittest.main()
