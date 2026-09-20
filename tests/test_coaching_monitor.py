from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


TOOLS = Path(__file__).parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
MODULE_PATH = TOOLS / "build_coaching_monitor.py"
SPEC = importlib.util.spec_from_file_location("coaching_monitor", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class CoachingMonitorTests(unittest.TestCase):
    def test_list_style_negation_covers_all_red_flag_terms(self) -> None:
        text = "全程无胸痛、头晕、异常心悸、放射痛、麻木或无力。"
        for term in ("胸痛", "头晕", "异常心悸", "放射痛", "麻木", "无力"):
            with self.subTest(term=term):
                self.assertFalse(MODULE.has_non_negated_term(text, term))

    def test_explicit_no_discomfort_is_not_positive_symptom(self) -> None:
        rows = [
            {
                "date": "2026-08-03",
                "session_name": "健身房下肢A",
                "notes": "用户说明本次没有不适，按即时反馈记录腰骶及关节无不适。",
                "low_back_0_10": "0",
            }
        ]
        result = MODULE.symptom_rows(rows)[0]
        self.assertEqual(result["symptom_status"], "explicit_clear")
        self.assertEqual(result["signals"], "")

    def test_unreported_red_flag_list_is_not_treated_as_present(self) -> None:
        text = "用户尚未明确腰骶、膝髋及胸痛、头晕、异常心悸等反应，保持未填写。"
        for term in ("胸痛", "头晕", "异常心悸"):
            with self.subTest(term=term):
                self.assertFalse(MODULE.has_non_negated_term(text, term))

    def test_post_qualified_red_flag_is_not_treated_as_present(self) -> None:
        text = "胸痛、头晕、异常心悸及腰骶反应尚未确认。"
        for term in ("胸痛", "头晕", "异常心悸"):
            with self.subTest(term=term):
                self.assertFalse(MODULE.has_non_negated_term(text, term))

    def test_current_archive_has_no_false_red_flags(self) -> None:
        rows = MODULE.read_csv(MODULE.TRAINING)
        result = MODULE.symptom_rows(rows)
        self.assertEqual(sum(row["symptom_status"] == "red_flag_present" for row in result), 0)

    def test_running_tightness_remains_positive(self) -> None:
        rows = [
            {
                "date": "2026-07-21",
                "session_name": "健身房上肢A回归",
                "notes": "无胸痛、头晕等反应，但腰部出现紧张，用户感觉腰部在代偿。",
                "low_back_0_10": "",
            }
        ]
        result = MODULE.symptom_rows(rows)[0]
        self.assertEqual(result["symptom_status"], "symptom_present")
        self.assertIn("腰部紧张", result["signals"])

    def test_curated_table_has_no_false_red_flags(self) -> None:
        result = MODULE.curated_symptom_rows()
        self.assertGreaterEqual(len(result), 8)
        self.assertEqual(sum(row["symptom_status"] == "red_flag_present" for row in result), 0)
        first = next(row for row in result if row["date"] == "2026-07-09")
        self.assertEqual(first["symptom_status"], "symptom_present")


if __name__ == "__main__":
    unittest.main()
