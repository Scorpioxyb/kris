import unittest

from app.server import dashboard_payload


class AppServerTests(unittest.TestCase):
    def test_dashboard_payload_has_actionable_sections(self):
        payload = dashboard_payload()
        self.assertIn("today", payload)
        self.assertIn("trends", payload)
        self.assertIn("nutrition", payload)
        self.assertIn("training_intelligence", payload)
        self.assertIn("quality", payload)
        self.assertIn("readiness", payload["today"])
        self.assertIn("plan", payload["today"])
        self.assertIsInstance(payload["trends"]["health"], list)
        self.assertIsInstance(payload["trends"]["body"], list)
        self.assertIsInstance(payload["trends"]["training"], list)

    def test_training_intelligence_exposes_load_and_progression(self):
        payload = dashboard_payload()
        training = payload["training_intelligence"]
        self.assertIn("current_load", training)
        self.assertIn("progression", training)
        self.assertIn("cardio", training)
        self.assertIn("short_ema", training["current_load"])
        self.assertIn("long_ema", training["current_load"])
        self.assertIsInstance(training["progression"]["recent_decisions"], list)
        self.assertLessEqual(len(payload["trends"]["training"]), 42)

    def test_snapshot_is_local_and_versioned(self):
        payload = dashboard_payload()
        self.assertEqual(payload["meta"]["app_version"], "v1.3.0")
        self.assertTrue(payload["meta"]["snapshot_mtime"])


if __name__ == "__main__":
    unittest.main()
