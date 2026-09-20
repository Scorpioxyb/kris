from __future__ import annotations

import importlib.util
import sys
import unittest
from datetime import date
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "tools/build_training_intelligence.py"
SPEC = importlib.util.spec_from_file_location("training_intelligence", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class TrainingIntelligenceParserTests(unittest.TestCase):
    def test_varying_weights_are_paired_with_reps(self) -> None:
        self.assertEqual(
            MODULE.extract_sets("坐姿划船35/35/40kg×10/10/10，末组合适"),
            [(35.0, 10), (35.0, 10), (40.0, 10)],
        )

    def test_app_export_repeated_weights_are_paired_with_reps(self) -> None:
        self.assertEqual(
            MODULE.extract_sets("上斜史密斯卧推 50kg×10/50kg×10/55kg×10"),
            [(50.0, 10), (50.0, 10), (55.0, 10)],
        )

    def test_weight_range_is_not_forced_to_upper_bound(self) -> None:
        self.assertEqual(MODULE.extract_sets("腿举60–70kg×12/12/12"), [])

    def test_set_count_without_reps_is_not_misread_as_reps(self) -> None:
        self.assertEqual(MODULE.extract_sets("锤式弯举8kg/手×2组，次数未提供"), [])

    def test_latest_exercise_alias_before_load_controls_variant(self) -> None:
        clause = (
            "因插销式坐姿腿推占用，主项改片装式倒蹬，"
            "按外加负重记录80kg×12、100kg×12、80kg×12"
        )
        exercise = MODULE.identify_exercise(clause)
        self.assertIsNotNone(exercise)
        assert exercise is not None
        self.assertEqual(exercise.name, "腿举")
        self.assertEqual(exercise.variant, "片装式倒蹬")

    def test_nested_alias_keeps_specific_equipment_variant(self) -> None:
        cases = {
            "常规龙门架高位下拉40kg×12×3": ("高位下拉", "常规龙门架"),
            "插销式水平推胸55kg×10×3": ("水平推胸", "插销式"),
            "哑铃侧平举6kg/手×12/14": ("侧平举", "哑铃"),
        }
        for clause, expected in cases.items():
            with self.subTest(clause=clause):
                exercise = MODULE.identify_exercise(clause)
                self.assertIsNotNone(exercise)
                assert exercise is not None
                self.assertEqual((exercise.name, exercise.variant), expected)

    def test_latest_archived_upper_session_has_expected_explicit_sets(self) -> None:
        rows = MODULE.read_csv(MODULE.TRAINING)
        parsed = MODULE.build_set_rows(rows)
        latest = [row for row in parsed if row["date"] == "2026-08-08"]
        self.assertEqual(len(latest), 22)
        self.assertEqual(
            sum(row["exercise"] == "高位下拉" for row in latest),
            3,
        )
        self.assertEqual(
            sum(row["exercise"] == "史密斯卧推" for row in latest),
            3,
        )

    @staticmethod
    def progression_set(reps: int, feel: str = "合适", weight: float = 40) -> dict[str, object]:
        return {
            "weight_kg": f"{weight:g}",
            "reps": reps,
            "last_set_feel": feel,
            "raw_clause": "测试记录",
        }

    def test_progression_requires_two_matching_top_range_sessions(self) -> None:
        top = [self.progression_set(12) for _ in range(3)]
        result = MODULE.progression_decision(top, top, 8, 12)
        self.assertEqual(result["progression_state"], "increase_smallest_step")
        self.assertIn("连续2次", result["decision_evidence"])

    def test_progression_missing_feedback_does_not_unlock_load_increase(self) -> None:
        top_without_feedback = [self.progression_set(12, "") for _ in range(3)]
        result = MODULE.progression_decision(top_without_feedback, top_without_feedback, 8, 12)
        self.assertEqual(result["progression_state"], "confirm_top_range")
        self.assertIn("反馈", result["decision_evidence"])

    def test_progression_technique_issue_overrides_repetition_success(self) -> None:
        top = [self.progression_set(12) for _ in range(3)]
        latest = [self.progression_set(12), self.progression_set(12), self.progression_set(12, "动作变形/代偿")]
        result = MODULE.progression_decision(latest, top, 8, 12)
        self.assertEqual(result["progression_state"], "technique_hold")

    def test_performance_model_is_immature_before_42_days(self) -> None:
        rows = [
            {
                "date": "2026-08-01",
                "session_name": "上肢A",
                "duration": "01:00:00",
            }
        ]
        result = MODULE.build_load(rows, date(2026, 8, 12))[-1]
        self.assertEqual(result["performance_model_status"], "baseline_building")
        self.assertEqual(result["performance_model_days"], 12)

    def test_performance_balance_uses_prior_day_state(self) -> None:
        rows = [
            {
                "date": "2026-08-01",
                "session_name": "上肢A",
                "duration": "01:00:00",
            }
        ]
        result = MODULE.build_load(rows, date(2026, 8, 1))[0]
        self.assertEqual(result["load_balance"], "0.0")


if __name__ == "__main__":
    unittest.main()
