from __future__ import annotations

import importlib.util
import os
import unittest
from datetime import datetime
from pathlib import Path


MODULE_PATH = Path(
    os.environ.get(
        "SYNCHEALTH_SLEEP_MODULE",
        Path.home() / ".local" / "bin" / "synchealth_sleep.py",
    )
)
SPEC = importlib.util.spec_from_file_location("synchealth_sleep", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SyncHealthSleepSessionTests(unittest.TestCase):
    @staticmethod
    def row(identifier: str, start: str, end: str) -> dict[str, object]:
        return {
            "id": identifier,
            "start": datetime.fromisoformat(start),
            "end": datetime.fromisoformat(end),
        }

    def test_late_waking_main_sleep_is_not_split_at_ten(self) -> None:
        rows = [
            self.row("before-ten", "2026-09-01T06:06:50+08:00", "2026-09-01T09:59:00+08:00"),
            self.row("after-ten", "2026-09-01T10:00:00+08:00", "2026-09-01T13:52:05+08:00"),
        ]
        result = MODULE.classify_sleep_sessions(rows)
        self.assertEqual(
            result,
            [
                ("before-ten", "2026-08-31", "night"),
                ("after-ten", "2026-08-31", "night"),
            ],
        )

    def test_short_afternoon_session_remains_a_nap(self) -> None:
        rows = [self.row("nap", "2026-09-01T15:07:00+08:00", "2026-09-01T16:40:00+08:00")]
        self.assertEqual(
            MODULE.classify_sleep_sessions(rows),
            [("nap", "2026-09-01", "nap")],
        )

    def test_long_daytime_sleep_is_main_sleep(self) -> None:
        rows = [self.row("shift", "2026-09-01T11:00:00+08:00", "2026-09-01T17:30:00+08:00")]
        self.assertEqual(
            MODULE.classify_sleep_sessions(rows),
            [("shift", "2026-08-31", "night")],
        )

    def test_interval_union_removes_cross_source_overlap(self) -> None:
        intervals = [
            (datetime.fromisoformat("2026-09-01T06:00:00+08:00"), datetime.fromisoformat("2026-09-01T08:00:00+08:00")),
            (datetime.fromisoformat("2026-09-01T06:30:00+08:00"), datetime.fromisoformat("2026-09-01T09:00:00+08:00")),
        ]
        self.assertEqual(MODULE.interval_union_minutes(intervals), 180)


if __name__ == "__main__":
    unittest.main()
