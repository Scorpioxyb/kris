from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS = Path(__file__).parents[1] / "tools"
MODULE_PATH = TOOLS / "auto_refresh_kris.py"
SPEC = importlib.util.spec_from_file_location("auto_refresh_kris", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def brief(state: str = "train_maintain", alerts: list[dict] | None = None) -> dict:
    return {
        "readiness": {"state": state, "label": state},
        "alerts": alerts or [],
    }


class AutoRefreshKrisTests(unittest.TestCase):
    def test_same_fingerprint_does_not_refresh(self) -> None:
        self.assertFalse(MODULE.should_refresh({"last_successful_fingerprint": "abc"}, "abc"))

    def test_new_input_changes_fingerprint_and_refreshes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "health.db"
            raw = root / "raw"
            raw.mkdir()
            database.write_bytes(b"db")
            first = MODULE.snapshot_fingerprint(MODULE.input_snapshot(database, raw))
            (raw / "upload.json").write_text("{}", encoding="utf-8")
            second = MODULE.snapshot_fingerprint(MODULE.input_snapshot(database, raw))
        self.assertNotEqual(first, second)
        self.assertTrue(MODULE.should_refresh({"last_successful_fingerprint": first}, second))

    def test_nonblocking_lock_prevents_reentry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "refresh.lock"
            first = MODULE.try_acquire_lock(lock)
            self.assertIsNotNone(first)
            second = MODULE.try_acquire_lock(lock)
            self.assertIsNone(second)
            os.close(first)

    def test_existing_high_alert_is_not_repeated(self) -> None:
        alert = {"id": "stale_plan", "severity": "high", "title": "旧计划待确认"}
        previous = {
            "last_successful_fingerprint": "old",
            "readiness_state": "train_maintain",
            "high_alert_ids": ["stale_plan"],
        }
        self.assertIsNone(MODULE.notification_for_brief(previous, brief(alerts=[alert])))

    def test_readiness_transition_and_new_high_alert_notify(self) -> None:
        previous = {
            "last_successful_fingerprint": "old",
            "readiness_state": "train_maintain",
            "high_alert_ids": [],
        }
        alert = {"id": "new_issue", "severity": "high", "title": "出现新问题"}
        notification = MODULE.notification_for_brief(
            previous, brief("recover_or_light", [alert])
        )
        self.assertIsNotNone(notification)
        self.assertIn("准备度状态变为", notification[1])
        self.assertIn("出现新问题", notification[1])


if __name__ == "__main__":
    unittest.main()
