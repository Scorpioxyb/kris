import json
import csv
import ssl
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from uuid import uuid4

from companion.archive import TRAINING_FIELDS
from companion.config import CompanionConfig
from companion.contracts import ContractError, validate_health_batch, validate_training_plan, validate_training_session
from companion.readiness import ReadinessEngine
from companion.security import ensure_certificate
from companion.server import CompanionHTTPServer
from companion.snapshot import _decision_trace, _readiness_history
from companion.source_resolution import resolve_daily_metrics
from companion.store import CompanionStore


ROOT = Path(__file__).resolve().parents[1]


def plan_payload() -> dict:
    return {
        "schema_version": "TrainingPlan.v1",
        "plan_id": str(uuid4()),
        "revision": 1,
        "date": "2026-08-31",
        "title": "上肢回归",
        "estimated_minutes": 55,
        "safety_gates": ["出现放射痛、麻木或无力时停止训练"],
        "exercises": [{
            "exercise_id": str(uuid4()), "order": 1, "name": "高位下拉",
            "equipment_variant": "常规龙门架", "target_weight_kg": 40,
            "sets": 3, "target_reps": 10, "rest_seconds": 90,
            "notes": ["胸廓保持稳定"], "alternative": "中立握下拉",
        }],
    }


def session_payload(plan: dict) -> dict:
    exercise = plan["exercises"][0]
    return {
        "schema_version": "TrainingSession.v1",
        "session_id": str(uuid4()), "plan_id": plan["plan_id"], "plan_revision": 1,
        "started_at": "2026-08-31T18:00:00+08:00", "ended_at": "2026-08-31T19:00:00+08:00",
        "status": "completed",
        "exercise_results": [{
            "exercise_id": exercise["exercise_id"], "name": exercise["name"],
            "equipment_variant": exercise["equipment_variant"],
            "sets": [{
                "set_id": str(uuid4()), "set_number": 1, "weight_kg": 40,
                "reps": 10, "completed_at": "2026-08-31T18:10:00+08:00",
                "last_set_feeling": "appropriate",
            }],
        }],
        "feedback": {"energy": "normal", "target_muscle_response": "good", "symptoms": "无不适", "notes": ""},
        "watch_workout_uuid": None,
        "workout": {"duration_seconds": 3600, "active_kcal": 420, "average_heart_rate": 128, "maximum_heart_rate": 166},
    }


def adjusted_session_payload(plan: dict) -> dict:
    payload = session_payload(plan)
    actual = payload["exercise_results"][0]
    planned = plan["exercises"][0]
    actual["planned"] = {
        "exercise_id": planned["exercise_id"],
        "name": planned["name"],
        "equipment_variant": planned["equipment_variant"],
        "target_weight_kg": planned["target_weight_kg"],
        "sets": planned["sets"],
        "target_reps": planned["target_reps"],
        "rest_seconds": planned["rest_seconds"],
    }
    actual["name"] = "中立握下拉"
    actual["equipment_variant"] = "现场龙门架 B"
    return payload


class ReadinessGoldenTests(unittest.TestCase):
    def test_all_golden_cases(self):
        fixture = json.loads((ROOT / "shared/fixtures/readiness_golden.v1.json").read_text(encoding="utf-8"))
        engine = ReadinessEngine.load()
        for case in fixture["cases"]:
            with self.subTest(case=case["name"]):
                actual = engine.evaluate(case["input"]).as_dict()
                for key, expected in case["expected"].items():
                    self.assertEqual(actual[key], expected)


class SnapshotIntelligenceTests(unittest.TestCase):
    def test_readiness_history_and_decision_trace_stay_structured(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            health_path = root / "每日健康汇总.csv"
            load_path = root / "训练负荷汇总.csv"
            with health_path.open("w", encoding="utf-8-sig", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=[
                    "date", "status", "sleep_hours", "hrv_sdnn_ms", "resting_hr_bpm",
                ])
                writer.writeheader()
                for index in range(8):
                    writer.writerow({
                        "date": f"2026-08-{25 + index:02d}" if index < 7 else "2026-09-01",
                        "status": "partial" if index == 7 else "final",
                        "sleep_hours": 7 + index / 10,
                        "hrv_sdnn_ms": 40 + index,
                        "resting_hr_bpm": 68 - index / 2,
                    })
            with load_path.open("w", encoding="utf-8-sig", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=[
                    "date", "load_ratio_7d_to_28d_weekly",
                ])
                writer.writeheader()
                writer.writerow({"date": "2026-09-01", "load_ratio_7d_to_28d_weekly": "0.8"})

            history = _readiness_history(health_path, load_path)

        self.assertEqual(len(history), 8)
        self.assertEqual(history[-1]["date"], "2026-09-01")
        self.assertEqual(history[-1]["source"], "mac_derived")
        self.assertIsInstance(history[-1]["score"], float)

        trace = _decision_trace({
            "as_of": "2026-09-01",
            "readiness": {"score": 57.5, "label": "可训练，但降阶"},
            "actions": ["减少一组"],
            "current_plan": {
                "prescription_basis": "静息心率高于基线",
                "adjustment_note": "不做力竭",
            },
        })
        self.assertEqual(trace["summary"], "准备度 57.5 分 · 可训练，但降阶")
        self.assertEqual(trace["actions"], ["减少一组"])
        self.assertEqual(trace["plan_basis"], "静息心率高于基线")


class ContractTests(unittest.TestCase):
    def test_plan_and_session_contracts(self):
        plan = validate_training_plan(plan_payload())
        session = validate_training_session(adjusted_session_payload(plan))
        self.assertEqual(session["plan_id"], plan["plan_id"])

    def test_reject_duplicate_health_sample_uuid(self):
        sample = {
            "sample_uuid": str(uuid4()), "metric": "hrv_sdnn",
            "start_at": "2026-08-31T07:00:00+08:00", "end_at": "2026-08-31T07:00:01+08:00",
            "value": 50, "unit": "ms", "source": "Apple Watch",
        }
        payload = {
            "schema_version": "HealthBatch.v1", "batch_id": str(uuid4()), "device_id": "phone",
            "created_at": "2026-08-31T08:00:00+08:00", "samples": [sample, dict(sample)], "coverage": [],
        }
        with self.assertRaises(ContractError):
            validate_health_batch(payload)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = CompanionStore(Path(self.temp.name) / "state.sqlite3", b"x" * 32)

    def tearDown(self):
        self.temp.cleanup()

    def test_pairing_token_is_one_time_and_authentication_works(self):
        token = self.store.create_pairing_token()
        device_token = self.store.pair_device(token, "phone-1", "iPhone")
        self.assertTrue(device_token)
        self.assertIsNone(self.store.pair_device(token, "phone-2", "iPhone"))
        self.assertEqual(self.store.authenticate(str(device_token)), "phone-1")

    def test_plan_and_session_are_idempotent(self):
        plan = validate_training_plan(plan_payload())
        first, version = self.store.publish_plan(plan)
        second, duplicate_version = self.store.publish_plan(plan)
        self.assertTrue(first)
        self.assertFalse(second)
        self.assertEqual(version, duplicate_version)
        session = validate_training_session(adjusted_session_payload(plan))
        self.assertEqual(self.store.store_session(session, "phone-1"), (True, "received"))
        self.assertEqual(self.store.store_session(session, "phone-1"), (False, "received"))

    def test_plan_revision_conflict_is_rejected(self):
        plan = validate_training_plan(plan_payload())
        self.store.publish_plan(plan)
        changed = dict(plan)
        changed["title"] = "冲突内容"
        with self.assertRaises(ValueError):
            self.store.publish_plan(changed)


class CompanionEndpointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.vault = root / "vault"
        self.vault.mkdir()
        with (self.vault / "训练记录.csv").open("w", encoding="utf-8-sig", newline="") as handle:
            csv.DictWriter(handle, fieldnames=TRAINING_FIELDS).writeheader()
        with (self.vault / "训练负荷汇总.csv").open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(
                handle, fieldnames=["date", "short_term_7d_ema", "long_term_42d_ema"]
            )
            writer.writeheader()
            writer.writerow({
                "date": "2026-08-31", "short_term_7d_ema": "22.0",
                "long_term_42d_ema": "29.0",
            })
        self.refresh = root / "refresh.py"
        self.refresh.write_text("raise SystemExit(0)\n", encoding="utf-8")
        self.config = CompanionConfig(
            host="127.0.0.1", port=0, state_dir=root / "state",
            vault_dir=self.vault, refresh_script=self.refresh, service_name="Kris Test",
        )
        certificate, private_key = ensure_certificate(self.config)
        self.store = CompanionStore(self.config.database_path, b"t" * 32)
        self.server = CompanionHTTPServer(("127.0.0.1", 0), self.config, self.store)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, private_key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"https://127.0.0.1:{self.server.server_address[1]}"
        self.client_context = ssl._create_unverified_context()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def request(self, path: str, *, payload: dict | None = None, token: str | None = None) -> tuple[int, dict]:
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(self.base + path, data=body, method="POST" if body is not None else "GET")
        request.add_header("Accept", "application/json")
        if body is not None:
            request.add_header("Content-Type", "application/json")
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, context=self.client_context, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            try:
                return error.code, json.loads(error.read())
            finally:
                error.close()

    def pair(self) -> str:
        one_time = self.store.create_pairing_token()
        status, response = self.request(
            "/v1/pair", payload={"token": one_time, "device_id": "phone-1", "device_name": "iPhone"}
        )
        self.assertEqual(status, 200)
        second_status, _ = self.request(
            "/v1/pair", payload={"token": one_time, "device_id": "phone-2", "device_name": "iPhone"}
        )
        self.assertEqual(second_status, 401)
        return response["device_token"]

    def test_tls_pair_health_snapshot_and_session_retry_are_end_to_end_idempotent(self):
        token = self.pair()
        plan = validate_training_plan(plan_payload())
        self.store.publish_plan(plan)
        sample_id = str(uuid4())
        batch = {
            "schema_version": "HealthBatch.v1", "batch_id": str(uuid4()), "device_id": "phone-1",
            "created_at": "2026-09-01T08:00:00+08:00",
            "samples": [{
                "sample_uuid": sample_id, "metric": "hrv_sdnn",
                "start_at": "2026-09-01T07:00:00+08:00", "end_at": "2026-09-01T07:00:01+08:00",
                "value": 55, "unit": "ms", "source": "Apple Watch",
            }],
            "coverage": [{"date": "2026-09-01", "metric": "hrv_sdnn", "status": "partial"}],
        }
        first_status, first = self.request("/v1/health/batches", payload=batch, token=token)
        second_status, second = self.request("/v1/health/batches", payload=batch, token=token)
        self.assertEqual((first_status, first["duplicate"]), (200, False))
        self.assertEqual((second_status, second["duplicate"]), (200, True))
        refresh_status, refresh = self.request("/v1/refresh", payload={}, token=token)
        self.assertEqual((refresh_status, refresh["acknowledged"]), (200, True))
        snapshot_status, snapshot = self.request("/v1/snapshot", token=token)
        self.assertEqual(snapshot_status, 200)
        self.assertEqual(snapshot["current_plan"]["plan_id"], plan["plan_id"])
        self.assertEqual(snapshot["trends"]["training_load_7d"][-1]["value"], 22.0)
        self.assertEqual(snapshot["trends"]["training_load_42d"][-1]["value"], 29.0)
        self.assertEqual(snapshot["recent_training"], [])

        session = validate_training_session(adjusted_session_payload(plan))
        self.refresh.write_text("raise SystemExit(1)\n", encoding="utf-8")
        failed_status, failed = self.request("/v1/training/sessions", payload=session, token=token)
        self.assertEqual(failed_status, 503)
        self.assertEqual(failed["error"]["code"], "pipeline_failed")
        self.refresh.write_text("raise SystemExit(0)\n", encoding="utf-8")
        success_status, success = self.request("/v1/training/sessions", payload=session, token=token)
        duplicate_status, duplicate = self.request("/v1/training/sessions", payload=session, token=token)
        self.assertEqual((success_status, success["archive_state"]), (200, "archived"))
        self.assertEqual((duplicate_status, duplicate["duplicate"]), (200, True))
        marker = f"[app_session_id={session['session_id']}]"
        archived_csv = (self.vault / "训练记录.csv").read_text(encoding="utf-8-sig")
        self.assertEqual(archived_csv.count(marker), 1)
        self.assertIn("中立握下拉·现场龙门架 B", archived_csv)
        self.assertIn("计划 高位下拉·常规龙门架 → 实际 中立握下拉·现场龙门架 B", archived_csv)
        self.assertIn("现场龙门架 B", archived_csv)
        self.assertEqual((self.vault / "App训练会话.jsonl").read_text(encoding="utf-8").count(session["session_id"]), 1)
        snapshot_status, snapshot = self.request("/v1/snapshot", token=token)
        self.assertEqual(snapshot_status, 200)
        self.assertEqual(snapshot["recent_training"][0]["id"], session["session_id"])
        self.assertEqual(snapshot["recent_training"][0]["duration_minutes"], 60.0)


class SourceResolutionTests(unittest.TestCase):
    def test_complete_iphone_metric_wins_without_summing(self):
        iphone = [{"date": "2026-08-31", "metric": "active_energy", "sample_uuid": "i1", "value": 500}]
        sync = [{"date": "2026-08-31", "metric": "active_energy", "sample_uuid": "s1", "value": 480}]
        resolved = resolve_daily_metrics(iphone, sync, [{"date": "2026-08-31", "metric": "active_energy", "status": "complete"}])
        self.assertEqual(resolved[0]["source"], "iphone_healthkit")
        self.assertEqual(len(resolved[0]["samples"]), 1)

    def test_partial_iphone_metric_falls_back(self):
        iphone = [{"date": "2026-08-31", "metric": "step_count", "sample_uuid": "i1", "value": 100}]
        sync = [{"date": "2026-08-31", "metric": "step_count", "sample_uuid": "s1", "value": 7000}]
        resolved = resolve_daily_metrics(iphone, sync, [{"date": "2026-08-31", "metric": "step_count", "status": "partial"}])
        self.assertEqual(resolved[0]["source"], "synchealth")


if __name__ == "__main__":
    unittest.main()
