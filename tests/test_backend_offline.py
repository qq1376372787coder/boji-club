"""Offline regression tests using synthetic data only."""
import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from ai_core import AIError, Provider, Router, messages_for, validate_request, validate_result
from server import JobStore, make_server


def weekly_request():
    return {
        "kind": "weekly_review",
        "date": "2026-09-27",
        "payload": {
            "profile": {"age": 28, "height": 175, "weight": 68, "goal": "增肌", "experience": "有基础", "venue": "健身房", "focus": "全身"},
            "survey": {"days": 2, "pain": "无疼痛", "fatigue": "适中", "difficulty": "合适", "diet": "记录不完整"},
            "days": [
                {"date": f"2026-09-{day}", "payload": {"exercises": [{"name": "深蹲", "sets": [{"weight": 20, "reps": 10, "completed": True}] * 2}], "meals": []}}
                for day in range(21, 28)
            ],
            "upcoming": [],
            "photos": [],
            "history": [],
        },
    }


def weekly_result():
    exercise = {"library_query":"barbell squat", "name": "深蹲", "muscle": "腿部", "sets": [{"weight": 200, "reps": 10}] * 2}
    return {
        "kind": "weekly_review",
        "summary": "记录较完整",
        "training": "按完成记录分析",
        "nutrition": "缺少饮食记录",
        "recovery": "关注感受",
        "appearance": "没有提供照片",
        "decision": "adjust",
        "reason": "小幅调整",
        "notes": [],
        "photoFeedback": [],
        "sessions": [{"date": f"2026-09-{day}", "label": "适当安排", "exercises": [exercise, exercise]} for day in (28, 30)],
    }


class BackendOfflineTests(unittest.TestCase):
    def test_weekly_rules_do_not_invent_data_or_prescribe_weight(self):
        clean = validate_request(weekly_request())
        self.assertEqual(clean["payload"]["days"][0]["meals"], [])
        output = validate_result(clean, weekly_result())
        self.assertIsNone(output["sessions"][0]["exercises"][0]["sets"][0]["weight"])

        raw = weekly_request()
        raw["payload"]["survey"]["pain"] = "有疼痛"
        output = validate_result(validate_request(raw), weekly_result())
        self.assertEqual(output["sessions"], [])

    def test_training_context_reaches_plan_prompt(self):
        body = {
            "kind": "generate_plan",
            "date": "2026-09-30",
            "payload": {"profile": {
                "age": 28, "height": 175, "weight": 68, "daysPerWeek": 3,
                "goal": "增肌", "experience": "新手", "venue": "两者都有", "focus": "全身",
                "gender": "女", "equipment": "哑铃、弹力带", "equipmentOther": "瑜伽垫",
                "sessionMinutes": 45, "limitations": "膝盖不适",
                "trainingDays": [1, 3, 5], "homeTrainingDays": [5],
            }},
        }
        clean = validate_request(body)
        profile = clean["payload"]["profile"]
        self.assertEqual(profile["gender"], "女")
        self.assertEqual(profile["equipment"], "哑铃、弹力带")
        self.assertEqual(profile["trainingDays"], [1, 3, 5])
        self.assertEqual(profile["homeTrainingDays"], [5])
        prompt = json.dumps(messages_for(clean), ensure_ascii=False)
        self.assertIn("homeTrainingDays", prompt)
        self.assertIn("居家器械", prompt)

    def test_deleted_task_tombstone_survives_recreate_and_complete(self):
        with tempfile.TemporaryDirectory() as folder:
            store = JobStore(Path(folder) / "jobs.sqlite3")
            job_id = str(uuid.uuid4())
            store.delete_private(job_id)
            with self.assertRaises(AIError) as caught:
                store.create(job_id, validate_request(weekly_request()))
            self.assertEqual(caught.exception.code, "id_conflict")
            store.complete(job_id, weekly_result(), "test", "test")
            job = store.get(job_id)
            self.assertEqual(job["status"], "deleted")
            self.assertIsNone(job["result"])

    def test_internal_job_api_rejects_non_owner_tokens(self):
        with tempfile.TemporaryDirectory() as folder:
            store = JobStore(Path(folder) / "jobs.sqlite3")
            server = make_server(store, Router([]), "offline-test-owner-token-only-12345", port=0)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            owner = "offline-test-owner-token-only-12345"
            other = "not-the-owner-token-1234567890"
            job_id = str(uuid.uuid4())
            body = weekly_request()
            body["id"] = job_id

            def call(method, path, token, payload=None):
                data = None if payload is None else json.dumps(payload).encode()
                request = urllib.request.Request(
                    base + path,
                    data=data,
                    method=method,
                    headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
                )
                try:
                    with urllib.request.urlopen(request) as response:
                        return response.status, json.load(response)
                except urllib.error.HTTPError as error:
                    return error.code, json.load(error)

            try:
                self.assertEqual(call("POST", "/v1/jobs", other, body)[0], 404)
                self.assertEqual(call("POST", "/v1/jobs", owner, body)[0], 202)
                self.assertEqual(call("GET", "/v1/jobs/" + job_id, other)[0], 404)
                self.assertEqual(call("DELETE", "/v1/jobs/" + job_id, other)[0], 404)
                self.assertEqual(call("DELETE", "/v1/jobs/" + job_id, owner)[0], 200)
                with store.connect() as db:
                    row = db.execute("SELECT payload,result FROM jobs WHERE id=?", (job_id,)).fetchone()
                self.assertEqual(row["payload"], "{}")
                self.assertIsNone(row["result"])
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_food_images_only_route_to_image_capable_providers(self):
        request = {"kind": "food", "date": "2026-09-28", "payload": {"context": "", "mime": "image/jpeg", "image_base64": "fixture"}}
        item = {"name": "牛奶", "amount": 250, "unit": "ml", "calories": 150, "protein": 8, "carbs": 12, "fat": 8, "basis": "visible", "details": ["容量为估算"]}
        raw = {"kind": "meal", "is_food": True, "name": "早餐", "notes": ["请确认份量"], "components": [item, dict(item, name="第二杯")], "calories": 9999}
        seen = []

        def transport(provider, messages, limit):
            seen.append(provider.name)
            return raw, {}

        providers = [
            Provider("deepseek", "https://example.invalid", "text", "unused", supports_images=False),
            Provider("mimo", "https://example.invalid", "vision", "unused", supports_images=True),
        ]
        result, provider, _ = Router(providers, transport=transport).run(request)
        self.assertEqual(provider, "mimo")
        self.assertEqual(seen, ["mimo"])
        self.assertEqual(result["calories"], 300)


if __name__ == "__main__":
    unittest.main(verbosity=2)
