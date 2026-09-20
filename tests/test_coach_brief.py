from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


TOOLS = Path(__file__).parents[1] / "tools"
MODULE_PATH = TOOLS / "build_coach_brief.py"
SPEC = importlib.util.spec_from_file_location("coach_brief", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class CoachBriefTests(unittest.TestCase):
    def test_short_sleep_and_lower_hrv_is_not_progression(self) -> None:
        components = {
            "sleep": MODULE.component_score(5.0, 6.5, 22.0),
            "hrv": MODULE.component_score(35.0, 40.0, 1.6),
            "rhr": MODULE.component_score(55.0, 65.0, -1.5),
            "load": 68.0,
        }
        score = MODULE.weighted_readiness(components)
        decision = MODULE.readiness_decision(score, "partial", "usable_with_known_gaps")
        self.assertLess(score, 45)
        self.assertEqual(decision["state"], "recover_or_light")

    def test_high_readiness_requires_final_data_to_remove_temporary_label(self) -> None:
        decision = MODULE.readiness_decision(85.0, "partial", "usable_with_known_gaps")
        self.assertEqual(decision["state"], "train_progress")
        self.assertIn("临时", decision["label"])

    def test_missing_signal_does_not_make_score_zero(self) -> None:
        score = MODULE.weighted_readiness({"sleep": 70.0, "hrv": None, "rhr": None, "load": None})
        self.assertEqual(score, 70.0)

    def test_latest_complete_body_uses_health_summary_not_stale_metadata(self) -> None:
        rows = [
            {"date": "2026-08-19", "weight_kg": "83.1", "body_fat_pct": "25.3", "lean_body_mass_kg": "62.1", "bmi": "26.5"},
            {"date": "2026-08-30", "weight_kg": "", "body_fat_pct": "", "lean_body_mass_kg": "", "bmi": ""},
        ]
        body = MODULE.latest_complete_body(rows)
        self.assertIsNotNone(body)
        self.assertEqual(body["date"], "2026-08-19")

    def test_stale_planned_session_is_high_priority_alert(self) -> None:
        alerts = MODULE.build_alerts(
            "2026-08-30",
            {"status": "partial"},
            None,
            [{"date": "2026-08-24"}],
            {"date": "2026-08-26", "status": "planned"},
            6.5,
            6.5,
        )
        alert = next(item for item in alerts if item["id"] == "stale_current_plan")
        self.assertEqual(alert["severity"], "high")
        self.assertIn("过期", alert["title"])


if __name__ == "__main__":
    unittest.main()
