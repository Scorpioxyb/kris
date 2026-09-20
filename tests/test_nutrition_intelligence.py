from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "tools/build_nutrition_intelligence.py"
SPEC = importlib.util.spec_from_file_location("nutrition_intelligence", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class NutritionIntelligenceTests(unittest.TestCase):
    def inventory(self) -> list[dict[str, str]]:
        return [
            {"snapshot_date": "2026-08-12", "item": "蔬菜", "food_group": "vegetable", "status": "available"},
            {"snapshot_date": "2026-08-12", "item": "鸡胸肉", "food_group": "poultry", "status": "available"},
            {"snapshot_date": "2026-08-12", "item": "香蕉", "food_group": "fruit", "status": "available"},
            {"snapshot_date": "2026-08-12", "item": "燕麦", "food_group": "whole_grain", "status": "available"},
            {"snapshot_date": "2026-08-12", "item": "牛奶", "food_group": "dairy", "status": "available"},
            {"snapshot_date": "2026-08-12", "item": "橄榄油", "food_group": "quality_fat", "status": "available"},
        ]

    def test_latest_inventory_ignores_older_snapshot(self) -> None:
        rows = self.inventory() + [
            {"snapshot_date": "2026-08-11", "item": "旧食材", "food_group": "fish", "status": "available"}
        ]
        current = MODULE.latest_active_inventory(rows)
        self.assertNotIn("旧食材", {row["item"] for row in current})

    def test_inventory_does_not_claim_actual_intake(self) -> None:
        rows = MODULE.build_coverage(self.inventory(), "2026-08-12")
        protein = next(row for row in rows if row["dimension"] == "protein_total")
        self.assertEqual(protein["coverage_status"], "available_quantity_unknown")
        self.assertIn("库存只代表可用", protein["interpretation_rule"])

    def test_missing_fish_is_inventory_gap_not_diagnosed_deficiency(self) -> None:
        rows = MODULE.build_coverage(self.inventory(), "2026-08-12")
        omega3 = next(row for row in rows if row["dimension"] == "omega3")
        self.assertEqual(omega3["coverage_status"], "gap_in_current_inventory")
        self.assertNotIn("缺乏", omega3["coverage_status"])

    def test_dairy_is_available_but_quantity_unknown(self) -> None:
        rows = MODULE.build_coverage(self.inventory(), "2026-08-12")
        calcium = next(row for row in rows if row["dimension"] == "calcium_dairy")
        self.assertEqual(calcium["coverage_status"], "available_quantity_unknown")

    def test_existing_poultry_and_dairy_are_partial_protein_variety(self) -> None:
        rows = MODULE.build_coverage(self.inventory(), "2026-08-12")
        variety = next(row for row in rows if row["dimension"] == "protein_variety")
        self.assertEqual(variety["coverage_status"], "partially_available")
        self.assertIn("鸡胸肉", variety["inventory_evidence"])

    def test_olive_oil_prevents_false_fat_inventory_gap(self) -> None:
        rows = MODULE.build_coverage(self.inventory(), "2026-08-12")
        fat = next(row for row in rows if row["dimension"] == "fat_total_quality")
        self.assertEqual(fat["coverage_status"], "available_quantity_unknown")


if __name__ == "__main__":
    unittest.main()
