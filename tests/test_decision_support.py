from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import unittest
from copy import deepcopy
from datetime import date
from pathlib import Path


TOOLS = Path(__file__).parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
MODULE_PATH = TOOLS / "build_decision_support.py"
SPEC = importlib.util.spec_from_file_location("decision_support", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DecisionSupportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = json.loads(MODULE.WORKFLOW.read_text(encoding="utf-8"))

    def test_planned_workflow_waits_for_user_completion(self) -> None:
        workflow = deepcopy(self.workflow)
        workflow["current_plan"]["status"] = "planned"
        result = MODULE.workflow_validation(workflow)
        self.assertTrue(result["valid"])
        self.assertEqual(result["blocking_step"], "await_user_completion")

    def test_smith_record_keeps_same_machine_scope(self) -> None:
        records = MODULE.build_records(
            [
                {
                    "date": "2026-08-01",
                    "session_name": "上肢 A",
                    "exercise": "史密斯卧推",
                    "equipment_variant": "垂直轨迹史密斯",
                    "set_index": "1",
                    "weight_kg": "50",
                    "weight_scope": "kg_displayed",
                    "reps": "10",
                },
                {
                    "date": "2026-08-02",
                    "session_name": "上肢 B",
                    "exercise": "史密斯卧推",
                    "equipment_variant": "斜轨史密斯",
                    "set_index": "1",
                    "weight_kg": "80",
                    "weight_scope": "kg_displayed",
                    "reps": "10",
                },
            ],
            [],
        )
        smith = next(
            row
            for row in records
            if row["exercise"] == "史密斯卧推"
            and row["equipment_variant"] == "垂直轨迹史密斯"
        )
        self.assertEqual(smith["heaviest_weight_kg"], "50")
        self.assertEqual(smith["reps_at_heaviest"], "10")
        self.assertEqual(smith["best_epley_display_kg"], "66.7")
        self.assertIn(smith["record_status"], {"new_or_tied_latest", "historical_record"})

    def test_core_exercise_does_not_get_e1rm_estimate(self) -> None:
        records = MODULE.build_records(
            MODULE.read_csv(MODULE.SETS), MODULE.read_csv(MODULE.PROGRESSION)
        )
        pallof = next(row for row in records if row["exercise"] == "Pallof Press")
        self.assertEqual(pallof["best_epley_display_kg"], "")

    def test_next_candidate_is_locked_lower_strength_after_upper_completion(self) -> None:
        workflow = deepcopy(self.workflow)
        workflow["current_plan"]["status"] = "planned"
        _rows, candidate = MODULE.build_schedule(
            MODULE.read_csv(MODULE.TRAINING),
            MODULE.read_csv(MODULE.LOAD),
            MODULE.read_csv(MODULE.RECOVERY),
            workflow,
            date(2026, 8, 10),
        )
        self.assertEqual(candidate["candidate_type"], "lower_strength")
        self.assertGreaterEqual(candidate["earliest_date"], "2026-08-11")
        self.assertEqual(candidate["status"], "locked_until_current_plan_completed")

    def test_cancelled_plan_skips_explicit_rest_days(self) -> None:
        workflow = deepcopy(self.workflow)
        workflow["current_plan"]["status"] = "cancelled_by_user"
        _rows, candidate = MODULE.build_schedule(
            MODULE.read_csv(MODULE.TRAINING),
            MODULE.read_csv(MODULE.LOAD),
            MODULE.read_csv(MODULE.RECOVERY),
            workflow,
            date(2026, 8, 13),
        )
        self.assertGreaterEqual(candidate["earliest_date"], "2026-08-14")
        self.assertNotIn(
            candidate["earliest_date"],
            {item["date"] for item in workflow["planned_microcycle"] if item["status"] == "planned_rest"},
        )
        self.assertEqual(candidate["status"], "candidate_requires_daily_review")

    def test_vo2max_uses_available_measurements_and_requires_three_for_trend(self) -> None:
        db = sqlite3.connect(f"file:{MODULE.DB}?mode=ro", uri=True)
        try:
            cardio = MODULE.build_cardio_status(
                db,
                MODULE.read_csv(MODULE.LOAD),
                MODULE.read_csv(MODULE.RECOVERY),
                MODULE.read_csv(MODULE.SYMPTOMS),
                self.workflow,
            )[0]
        finally:
            db.close()
        self.assertGreaterEqual(cardio["vo2max_count"], 3)
        self.assertEqual(cardio["baseline_status"], "trend_available")
        self.assertTrue(cardio["latest_vo2max"])
        if cardio["associated_workout"]:
            self.assertGreater(float(cardio["associated_workout_minutes"]), 0)


if __name__ == "__main__":
    unittest.main()
