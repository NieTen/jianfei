import unittest
from datetime import datetime, timezone

from app.domain import basal_energy, day_window, energy_summary, food_totals, representative


class EnergyTests(unittest.TestCase):
    def test_bmr(self):
        self.assertEqual(basal_energy({"sex_for_formula": "male", "height_cm": 175, "age": 30}, 70, "2026-11-03"), 1648.75)

    def test_partial_resting_does_not_double_count(self):
        profile = {"sex_for_formula": "male", "height_cm": 168, "age": 31, "timezone": "UTC", "routine_meals": ["lunch"]}
        # 此参数组合对应全天基础代谢 1600kcal。
        meals = [{"eaten_at": "2026-11-03T10:00:00Z", "meal_type": "lunch", "status": "confirmed",
                  "items": [{"amount": 100, "basis_amount": 100, "basis_kcal": 600}]}]
        health = {"resting_kcal": 300, "resting_coverage": 0.2, "active_kcal": 200}
        result = energy_summary("2026-11-03", profile, 70, meals, health, {},
                                datetime(2026, 11, 3, 12, tzinfo=timezone.utc))
        self.assertEqual(result["expenditure_kcal"], 1000)
        self.assertEqual(result["deficit_kcal"], 400)

    def test_portion_and_unknown_macros(self):
        result = food_totals({"amount": 150, "basis_amount": 100, "basis_kcal": 116, "consumed_fraction": 0.8})
        self.assertEqual(result["kcal"], 139.2)
        self.assertIsNone(result["protein_g"])

    def test_locked_value(self):
        result = food_totals({"amount": 300, "basis_amount": 100, "basis_kcal": 116, "locked_values": {"kcal": 200}})
        self.assertEqual(result["kcal"], 200)

    def test_summer_time(self):
        start, end = day_window("2026-03-08", "America/New_York")
        self.assertEqual((end - start).total_seconds(), 23 * 3600)

    def test_custom_day_start(self):
        start, end = day_window("2026-11-03", "Asia/Shanghai", 240)
        self.assertEqual(start.hour, 20)
        self.assertEqual((end - start).total_seconds(), 86400)

    def test_no_meal_means_zero_recorded_intake_but_incomplete_day(self):
        result = energy_summary("2026-11-03", {}, None, [], {}, {})
        self.assertEqual(result["intake_kcal"], 0)
        self.assertFalse(result["intake_complete"])
        self.assertIsNone(result["deficit_kcal"])
        self.assertIsNone(result["macros"]["protein_g"])

    def test_confirmed_food_with_unknown_nutrition_keeps_null(self):
        meal = {"eaten_at": "2026-11-03T08:00:00Z", "meal_type": "breakfast", "status": "confirmed",
                "items": [{"amount": 100, "basis_amount": 100}]}
        result = energy_summary("2026-11-03", {}, None, [meal], {}, {},
                                datetime(2026, 11, 4, tzinfo=timezone.utc))
        self.assertIsNone(result["intake_kcal"])
        self.assertIsNone(result["macros"]["protein_g"])
        self.assertFalse(result["intake_complete"])

    def test_skipped_meal_requires_explicit_confirmation(self):
        meals = [{"eaten_at": "2026-11-03T08:00:00Z", "meal_type": "breakfast", "status": "skipped", "items": []}]
        result = energy_summary("2026-11-03", {"routine_meals": ["breakfast"]}, None, meals, {},
                                {"routine_meals": ["breakfast"], "intake_complete": True},
                                datetime(2026, 11, 4, tzinfo=timezone.utc))
        self.assertEqual(result["intake_kcal"], 0)
        self.assertTrue(result["intake_complete"])


    def test_balance_without_meals_uses_elapsed_activity_estimate(self):
        profile = {"sex_for_formula": "male", "height_cm": 168, "age": 31, "timezone": "UTC"}
        result = energy_summary("2026-11-03", profile, 70, [], {}, {},
                                datetime(2026, 11, 3, 12, tzinfo=timezone.utc))
        self.assertEqual(result["intake_kcal"], 0)
        self.assertEqual(result["expenditure_kcal"], 960)
        self.assertEqual(result["deficit_kcal"], 960)
        self.assertFalse(result["intake_complete"])
        self.assertEqual(len(result["unrecorded_meals"]), 3)

    def test_latest_weight_ignores_old_representative_flag(self):
        values = [{"measured_at": "2026-11-03T08:00:00Z", "weight_kg": 70, "representative": True},
                  {"measured_at": "2026-11-03T18:00:00Z", "weight_kg": 71}]
        self.assertEqual(representative(values), 71)
