import asyncio
import hashlib
import io
import json
import os
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient
from PIL import Image

from app.archive import decrypt_file, file_hash, read_frames
from app.config import Settings
from app.main import create_app
from app.models import RecognitionRequest
from app.errors import AppError
from app.providers import ProviderService, normalized_ai_url
from app.cli import pairing, restore
from app.runtime import Runtime


class APITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        with patch.dict(os.environ, {
            "DATA_DIR": self.temporary.name, "BOOTSTRAP_CODE": "test-bootstrap-code-only",
            "AI_URL": "", "AI_KEY": "", "BACKUP_PASSWORD": "", "APNS_KEY_FILE": "", "FOOD_API_KEY": "",
        }):
            self.settings = Settings.from_environment()
        self.app = create_app(self.settings, run_jobs=False)
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.service = self.app.state.runtime
        self.today = datetime.now(timezone.utc).date().isoformat()
        self.user = self.register("user_a")

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temporary.cleanup()

    def register(self, username):
        response = self.client.post("/api/v1/auth/register", json={
            "username": username, "password": "test-password-123", "display_name": username,
            "device_id": str(uuid.uuid4()), "device_name": "测试设备",
        })
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def headers(self, user=None):
        return {"Authorization": "Bearer " + (user or self.user)["access_token"]}

    def actor(self, user=None):
        return self.service.auth.authenticate(self.headers(user)["Authorization"])

    def mutation(self, kind="weight", entity_id=None, version=0, payload=None):
        return {
            "change_id": str(uuid.uuid4()), "entity_id": entity_id or str(uuid.uuid4()), "kind": kind,
            "business_date": self.today, "base_version": version,
            "payload": payload or {"measured_at": datetime.now(timezone.utc).isoformat(), "weight_kg": 70, "source": "manual"},
        }

    def push(self, changes, user=None):
        user = user or self.user
        response = self.client.post("/api/v1/sync/push", headers=self.headers(user),
            json={"epoch": user["epoch"], "generation": user["generation"], "changes": changes})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()["results"]

    def goal(self):
        return {"target_weight_kg": 65, "step_goal": 8000, "start_date": self.today,
                "end_date": (datetime.now(timezone.utc).date() + timedelta(days=28)).isoformat(),
                "selected_items": ["diet", "weight", "steps"]}

    def challenge(self, members=2):
        response = self.client.post("/api/v1/challenges", headers=self.headers(), json={
            "title": "测试挑战", "timezone": "UTC", "duration_days": 28, "max_members": members, "goal": self.goal(),
        })
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def upload_photo(self, user=None, meal_id=None, temporary=False):
        user = user or self.user
        image = io.BytesIO()
        Image.new("RGB", (32, 32), "#336655").save(image, format="JPEG")
        data = image.getvalue()
        image_id, meal_id = str(uuid.uuid4()), meal_id or str(uuid.uuid4())
        initialized = self.client.post("/api/v1/media/upload-init", headers=self.headers(user), json={
            "id": image_id, "meal_id": meal_id, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "mime_type": "image/jpeg", "temporary": temporary,
        })
        self.assertEqual(initialized.status_code, 200)
        response = self.client.put("/api/v1/media/" + image_id, params={"offset": 0},
            headers={**self.headers(user), "Content-Type": "application/octet-stream"}, content=data)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["status"], "ready")
        return image_id, meal_id, data

    def test_registration_without_enrollment_keeps_authentication_required(self):
        body = {"username": "new_user", "password": "test-password-123", "display_name": "新用户",
                "device_id": str(uuid.uuid4())}
        self.assertEqual(self.client.post("/api/v1/auth/register", json=body).status_code, 200)
        body.update(username="another_user", device_id=str(uuid.uuid4()))
        self.assertEqual(self.client.post("/api/v1/auth/register", json=body).status_code, 200)
        self.assertEqual(self.client.get("/api/v1/records").status_code, 401)

    def test_legacy_registration_code_is_optional_and_ignored(self):
        for code in ("", "expired-or-wrong-code", None):
            response = self.client.post("/api/v1/auth/register", json={
                "username": "legacy_" + uuid.uuid4().hex[:10], "password": "test-password-123",
                "display_name": "旧客户端", "bootstrap_code": code, "device_id": str(uuid.uuid4()),
            })
            self.assertEqual(response.status_code, 200, response.text)

    def test_open_registration_still_validates_fields_and_username_uniqueness(self):
        body = {"username": "user_a", "password": "abc", "display_name": "测试用户", "device_id": str(uuid.uuid4())}
        rejected = self.client.post("/api/v1/auth/register", json=body)
        self.assertEqual(rejected.status_code, 422)
        self.assertEqual(rejected.json()["details"][0]["field"], "body.password")
        body["password"] = "test-password-123"
        self.assertEqual(self.client.post("/api/v1/auth/register", json=body).status_code, 409)
        self.assertFalse(self.client.get("/api/v1/health").json()["registration_requires_code"])

    def test_refresh_rotates_and_logout_revokes(self):
        response = self.client.post("/api/v1/auth/refresh", json={"refresh_token": self.user["refresh_token"]})
        self.assertEqual(response.status_code, 200)
        current = response.json()
        self.assertEqual(self.client.get("/api/v1/devices", headers=self.headers()).status_code, 401)
        self.assertEqual(self.client.post("/api/v1/auth/logout", headers=self.headers(current)).status_code, 200)
        self.assertEqual(self.client.get("/api/v1/devices", headers=self.headers(current)).status_code, 401)

    def test_idempotent_push_and_conflict(self):
        mutation = self.mutation()
        first = self.push([mutation])[0]
        self.assertEqual(first["entity"]["version"], 1)
        self.assertEqual(self.push([mutation])[0]["status"], "duplicate")
        conflict = self.mutation(entity_id=mutation["entity_id"], version=0)
        self.assertEqual(self.push([conflict])[0]["status"], "conflict")
        self.assertEqual(len(self.client.get("/api/v1/records", headers=self.headers()).json()), 1)

    def test_batch_partial_success(self):
        valid, invalid = self.mutation(), self.mutation(payload={"measured_at": "invalid", "weight_kg": -1})
        results = self.push([valid, invalid])
        self.assertEqual([item["status"] for item in results], ["accepted", "rejected"])
        self.assertEqual(len(self.client.get("/api/v1/records", headers=self.headers()).json()), 1)

    def test_personal_data_isolation(self):
        second = self.register("user_b")
        self.push([self.mutation()])
        self.assertEqual(self.client.get("/api/v1/records", headers=self.headers(second)).json(), [])

    def test_multi_device_conflict(self):
        login = self.client.post("/api/v1/auth/login", json={"username": "user_a", "password": "test-password-123",
            "device_id": str(uuid.uuid4()), "device_name": "第二台设备"}).json()
        mutation = self.mutation()
        self.push([mutation])
        self.assertEqual(self.push([self.mutation(entity_id=mutation["entity_id"])], login)[0]["status"], "conflict")
        self.assertEqual(len(self.client.get("/api/v1/devices", headers=self.headers()).json()), 2)

    def test_deleted_entity_cannot_return(self):
        mutation = self.mutation()
        self.push([mutation])
        deleted = self.mutation(entity_id=mutation["entity_id"], version=1)
        deleted["deleted_at"] = datetime.now(timezone.utc).isoformat()
        self.assertEqual(self.push([deleted])[0]["status"], "accepted")
        self.assertEqual(self.push([self.mutation(entity_id=mutation["entity_id"], version=2)])[0]["code"], "ENTITY_DELETED")

    def test_pull_page_cursor_preserves_changes(self):
        self.push([self.mutation(), self.mutation(), self.mutation()])
        first = self.client.get("/api/v1/sync/pull", params={"limit": 2}, headers=self.headers()).json()
        self.assertTrue(first["has_more"])
        second = self.client.get("/api/v1/sync/pull", params={"limit": 2, "cursor": first["cursor"]}, headers=self.headers()).json()
        self.assertFalse(second["has_more"])
        self.assertEqual(len(first["entities"]) + len(second["entities"]), 3)

    def test_snapshot_is_immutable(self):
        mutation = self.mutation()
        self.push([mutation])
        snapshot = self.client.post("/api/v1/sync/snapshots", headers=self.headers()).json()
        self.push([self.mutation(entity_id=mutation["entity_id"], version=1,
                                 payload={"measured_at": datetime.now(timezone.utc).isoformat(), "weight_kg": 69})])
        rows = self.client.get("/api/v1/sync/snapshots/" + snapshot["snapshot_id"], headers=self.headers()).json()["entities"]
        self.assertEqual(rows[0]["payload"]["weight_kg"], 70)

    def test_concurrent_invitation_consumption(self):
        second, third = self.register("user_b"), self.register("user_c")
        challenge = self.challenge()
        def join(user):
            return self.client.post("/api/v1/challenges/join", headers=self.headers(user),
                json={"code": challenge["invite_code"], "goal": self.goal()}).status_code
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(join, [second, third]))
        self.assertEqual(sorted(results), [200, 409])

    def test_group_and_scoped_consent(self):
        second, third = self.register("user_b"), self.register("user_c")
        challenge = self.challenge(3)
        challenge_id = challenge["id"]
        self.client.post("/api/v1/challenges/join", headers=self.headers(second),
            json={"code": challenge["invite_code"], "goal": self.goal()})
        invite = self.client.post(f"/api/v1/challenges/{challenge_id}/invite", headers=self.headers()).json()["invite_code"]
        self.client.post("/api/v1/challenges/join", headers=self.headers(third), json={"code": invite, "goal": self.goal()})
        with self.service.db.transaction() as repo:
            start = datetime.combine(datetime.now(timezone.utc).date(), datetime.min.time(), timezone.utc)
            repo.update("challenges", {"status": "active", "start_at": start.isoformat(),
                                      "end_at": (start + timedelta(days=28)).isoformat()}, {"id": challenge_id})
        self.push([self.mutation()])
        grant = {"recipient_id": second["user_id"], "scopes": ["weight"], "history_from": self.today, "expected_version": 0}
        response = self.client.put(f"/api/v1/challenges/{challenge_id}/consent", headers=self.headers(), json=grant)
        self.assertEqual(response.status_code, 200, response.text)
        visible = self.client.get(f"/api/v1/challenges/{challenge_id}/summary", headers=self.headers(second), params={"day": self.today}).json()
        owner = next(item for item in visible["members"] if item["user_id"] == self.user["user_id"])
        self.assertEqual(owner["weight_kg"], 70)
        self.assertNotIn("profile", owner)
        hidden = self.client.get(f"/api/v1/challenges/{challenge_id}/summary", headers=self.headers(third), params={"day": self.today}).json()
        owner = next(item for item in hidden["members"] if item["user_id"] == self.user["user_id"])
        self.assertNotIn("weight_kg", owner)
        grant.update(scopes=[], expected_version=1)
        self.assertEqual(self.client.put(f"/api/v1/challenges/{challenge_id}/consent", headers=self.headers(), json=grant).status_code, 200)
        revoked = self.client.get(f"/api/v1/challenges/{challenge_id}/summary", headers=self.headers(second), params={"day": self.today}).json()
        owner = next(item for item in revoked["members"] if item["user_id"] == self.user["user_id"])
        self.assertEqual(owner["scopes"], [])

    def test_photo_upload_resume_and_ownership(self):
        image_id, _, data = self.upload_photo()
        second = self.register("user_b")
        self.assertEqual(self.client.get("/api/v1/media/" + image_id, headers=self.headers()).content, data)
        self.assertEqual(self.client.get("/api/v1/media/" + image_id, headers=self.headers(second)).status_code, 403)
        repeat = self.client.put("/api/v1/media/" + image_id, headers=self.headers(), content=b"", params={"offset": len(data)})
        self.assertEqual(repeat.json()["status"], "ready")

    def test_ai_requires_explicit_external_consent(self):
        image_id, meal_id, _ = self.upload_photo(temporary=True)
        self.service.ai.settings = replace(self.settings, ai_url="https://example.invalid/v1", ai_external=True, ai_model="test-vision")
        self.service.providers.settings = self.service.ai.settings
        body = {"request_key": str(uuid.uuid4()), "meal_id": meal_id, "meal_version": 0, "photo_ids": [image_id]}
        self.assertEqual(self.client.post("/api/v1/ai/food-recognition", headers=self.headers(), json=body).status_code, 403)
        body["allow_external"] = True
        response = self.client.post("/api/v1/ai/food-recognition", headers=self.headers(), json=body)
        self.assertEqual(response.status_code, 200, response.text)
        task_id = response.json()["id"]
        self.assertEqual(self.client.post("/api/v1/ai/food-recognition", headers=self.headers(), json=body).json()["id"], task_id)
        self.assertEqual(self.client.post(f"/api/v1/ai/tasks/{task_id}/cancel", headers=self.headers()).status_code, 200)

    def test_archive_export_roundtrip(self):
        self.push([self.mutation()])
        response = self.client.post("/api/v1/data/export", headers=self.headers(),
            json={"request_key": str(uuid.uuid4()), "password": "archive-password-123", "include_photos": False})
        self.assertEqual(response.status_code, 200, response.text)
        with self.service.db.read() as repo:
            task = repo.one("tasks", {"id": response.json()["id"]})
        result = self.service.data.export(task)
        self.service.jobs.finish(task["id"], "completed", result, None)
        archive = self.service.settings.data_dir / "exports" / result["filename"]
        preview = self.service.data.import_archive(self.actor(), archive, "archive-password-123")
        self.assertEqual(preview["identical"], 1)
        imported = self.service.data.import_archive(self.actor(), archive, "archive-password-123", "keep_local")
        self.assertTrue(imported["imported"])
        self.assertEqual(len(self.client.get("/api/v1/records", headers=self.headers()).json()), 1)

    def test_data_deletion_receipt_and_generation(self):
        self.push([self.mutation()])
        task_id, receipt = str(uuid.uuid4()), "r" * 64
        response = self.client.request("DELETE", "/api/v1/account/data", headers=self.headers(), json={
            "password": "test-password-123", "request_key": task_id, "receipt_secret": receipt,
        })
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["id"], task_id)
        self.assertEqual(self.client.get("/api/v1/records", headers=self.headers()).status_code, 401)
        status = self.client.get("/api/v1/data/deletions/" + task_id, headers={"X-Deletion-Receipt": receipt})
        self.assertEqual(status.status_code, 200)
        with self.service.db.read() as repo:
            task = repo.one("tasks", {"id": task_id})
        result = self.service.data.process_delete(task)
        self.service.jobs.finish(task_id, "completed", result, None)
        login = self.client.post("/api/v1/auth/login", json={"username": "user_a", "password": "test-password-123",
            "device_id": self.user["device_id"]})
        self.assertEqual(login.status_code, 200)
        self.assertEqual(login.json()["generation"], 2)
        self.assertEqual(self.client.get("/api/v1/records", headers=self.headers(login.json())).json(), [])

    def test_backup_is_restorable(self):
        self.push([self.mutation()])
        result = self.service.maintenance.backup("backup-password-123")
        self.assertTrue(result["restore_verified"])
        self.assertTrue((self.service.settings.data_dir / "backups" / result["filename"]).is_file())

    def test_incremental_backups_reuse_encrypted_media(self):
        image_id, _, data = self.upload_photo()
        first = self.service.maintenance.backup("backup-password-123")
        objects = self.settings.data_dir / "backups" / "objects"
        original = {path: (path.stat().st_mtime_ns, file_hash(path)) for path in objects.glob("*/*.bjar")}
        self.assertTrue(original)
        second = self.service.maintenance.backup("backup-password-123")
        current = {path: (path.stat().st_mtime_ns, file_hash(path)) for path in objects.glob("*/*.bjar")}
        self.assertEqual(current, original)
        self.assertEqual(second["media_mode"], "incremental")
        directory = self.settings.data_dir / "tmp" / "restore-incremental"
        self.service.maintenance.unpack_backup(self.settings.data_dir / "backups" / second["filename"],
                                               "backup-password-123", directory)
        self.assertEqual((directory / "media" / self.service.media.path(image_id).name).read_bytes(), data)
        old_archive = self.settings.data_dir / "backups" / first["filename"]
        old_time = (datetime.now(timezone.utc) - timedelta(days=31)).timestamp()
        os.utime(old_archive, (old_time, old_time))
        self.service.maintenance.cleanup_backups()
        self.assertFalse(old_archive.exists())
        self.assertTrue(all(path.exists() for path in original))

    def test_full_backup_restores_without_object_directory(self):
        image_id, _, data = self.upload_photo()
        result = self.service.maintenance.backup("backup-password-123", incremental=False)
        isolated = self.settings.data_dir / "tmp" / "portable.bjar"
        isolated.write_bytes((self.settings.data_dir / "backups" / result["filename"]).read_bytes())
        destination = self.settings.data_dir / "tmp" / "restore-full"
        self.service.maintenance.unpack_backup(isolated, "backup-password-123", destination)
        self.assertEqual((destination / "media" / self.service.media.path(image_id).name).read_bytes(), data)

    def test_repository_requires_write_conditions(self):
        with self.service.db.transaction() as repo:
            with self.assertRaises(ValueError):
                repo.delete("users", {})
            with self.assertRaises(ValueError):
                repo.update("users", {"status": "deleted"}, {})

    def configure_ai(self, **overrides):
        self.service.providers.settings = replace(self.settings, ai_url="https://provider.invalid/v1")
        value = {"base_url": "https://provider.invalid/v1/responses", "model": "test-vision",
                 "api_key": "test-key-only", "external": True, "structured_output": True}
        value.update(overrides)
        response = self.client.put("/api/v1/ai/settings", headers=self.headers(), json=value)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def recognition_task(self):
        image_id, meal_id, _ = self.upload_photo(temporary=True)
        response = self.client.post("/api/v1/ai/food-recognition", headers=self.headers(), json={
            "request_key": str(uuid.uuid4()), "meal_id": meal_id, "meal_version": 3,
            "photo_ids": [image_id], "allow_external": True,
        })
        self.assertEqual(response.status_code, 200, response.text)
        with self.service.db.read() as repo:
            return repo.one("tasks", {"id": response.json()["id"]})

    def test_ai_settings_encrypted_persistent_and_isolated(self):
        settings = self.configure_ai()
        self.assertEqual(settings["base_url"], "https://provider.invalid/v1")
        self.assertTrue(settings["has_api_key"])
        self.assertNotIn("api_key", settings)
        with self.service.db.read() as repo:
            row = repo.one("ai_settings", {"user_id": self.user["user_id"]})
        self.assertNotIn("test-key-only", row["encrypted_key"])
        restarted = ProviderService(self.service.db, self.settings)
        self.assertEqual(restarted.configuration(self.user["user_id"])["api_key"], "test-key-only")
        other = self.register("other_user")
        self.assertFalse(self.client.get("/api/v1/ai/settings", headers=self.headers(other)).json()["has_api_key"])
        unchanged = self.configure_ai(api_key=None)
        self.assertEqual(unchanged["version"], settings["version"])
        self.assertEqual(restarted.configuration(self.user["user_id"])["api_key"], "test-key-only")

    def test_ai_model_list_uses_cache_and_sanitizes_errors(self):
        self.configure_ai()
        requests = []
        def handler(request):
            requests.append(request)
            return httpx.Response(200, json={"data": [{"id": "test-vision"}, {"id": "test-text"}]})
        factory = httpx.AsyncClient
        with patch("app.providers.httpx.AsyncClient", side_effect=lambda **kwargs: factory(transport=httpx.MockTransport(handler))):
            first = self.client.get("/api/v1/ai/models", headers=self.headers())
            second = self.client.get("/api/v1/ai/models", headers=self.headers())
        self.assertEqual(first.status_code, 200, first.text)
        self.assertEqual(first.json(), second.json())
        self.assertEqual(len(requests), 1)
        self.assertEqual(str(requests[0].url), "https://provider.invalid/v1/models")
        self.assertEqual(requests[0].headers["Authorization"], "Bearer test-key-only")
        with self.assertRaises(AppError) as caught:
            self.service.providers.check_response(httpx.Response(401, text="secret-server-debug"))
        self.assertNotIn("secret-server-debug", caught.exception.message)

    def test_responses_request_and_missing_portion_are_preserved(self):
        self.configure_ai()
        task = self.recognition_task()
        requests = []
        result = {"items": [{"name": "待确认食物", "estimated_weight_g": None, "calories_kcal": 999,
                             "confidence": 0.4}], "uncertainty_note": "份量未知"}
        def handler(request):
            requests.append(request)
            return httpx.Response(200, json={"status": "completed", "model": "test-vision-version",
                "output": [{"type": "reasoning", "summary": []},
                           {"type": "message", "content": [{"type": "output_text", "text": json.dumps(result)}]}]})
        factory = httpx.AsyncClient
        with patch("app.ai.httpx.AsyncClient", side_effect=lambda **kwargs: factory(transport=httpx.MockTransport(handler))):
            value = asyncio.run(self.service.ai.process(task))
        body = json.loads(requests[0].content)
        self.assertEqual(str(requests[0].url), "https://provider.invalid/v1/responses")
        self.assertEqual(body["input"][0]["content"][0]["type"], "input_text")
        self.assertEqual(body["input"][0]["content"][1]["type"], "input_image")
        self.assertTrue(body["input"][0]["content"][1]["image_url"].startswith("data:image/jpeg;base64,"))
        self.assertEqual(body["text"]["format"]["type"], "json_schema")
        self.assertTrue(body["text"]["format"]["strict"])
        self.assertFalse(body["store"])
        self.assertEqual(value["meal_version"], 3)
        self.assertTrue(value["needs_user_confirmation"])
        self.assertTrue(value["items"][0]["requires_portion"])
        self.assertIsNone(value["items"][0]["basis_kcal"])

    def test_responses_negative_nutrition_is_rejected(self):
        self.configure_ai(structured_output=False)
        task = self.recognition_task()
        def handler(request):
            self.assertEqual(json.loads(request.content)["text"]["format"]["type"], "json_object")
            return httpx.Response(200, json={"output_text": json.dumps({
                "items": [{"name": "异常食物", "estimated_weight_g": 100, "calories_kcal": -20}]
            })})
        factory = httpx.AsyncClient
        with patch("app.ai.httpx.AsyncClient", side_effect=lambda **kwargs: factory(transport=httpx.MockTransport(handler))):
            with self.assertRaises(AppError) as caught:
                asyncio.run(self.service.ai.process(task))
        self.assertEqual(caught.exception.code, "INVALID_AI_OUTPUT")

    def test_responses_refusal_and_incomplete(self):
        for raw, code in [
            ({"status": "incomplete"}, "AI_RESPONSE_INCOMPLETE"),
            ({"output": [{"type": "message", "content": [{"type": "refusal"}]}]}, "AI_REFUSAL"),
            ({"output_text": "invalid-json"}, "INVALID_AI_OUTPUT"),
            ({"output_text": '{"items": 5}'}, "INVALID_AI_OUTPUT"),
        ]:
            with self.subTest(code=code), self.assertRaises(AppError) as caught:
                self.service.ai.parse_responses_output(raw)
            self.assertEqual(caught.exception.code, code)

    def test_provider_change_cancels_queued_recognition(self):
        original = self.configure_ai()
        task = self.recognition_task()
        same = self.configure_ai(api_key=None)
        self.assertEqual(same["version"], original["version"])
        self.assertEqual(self.service.ai.task(self.actor(), task["id"])["status"], "pending")
        self.configure_ai(model="another-test-model", api_key=None)
        self.assertEqual(self.service.ai.task(self.actor(), task["id"])["status"], "cancelled")
        with self.service.db.read() as repo:
            self.assertNotIn("_provider_snapshot", json.loads(repo.one("tasks", {"id": task["id"]})["payload"]))
        with self.assertRaises(AppError) as caught:
            asyncio.run(self.service.ai.process(task))
        self.assertEqual(caught.exception.code, "PROVIDER_CHANGED")

    def test_private_provider_requires_explicit_host_configuration(self):
        with self.assertRaises(AppError):
            self.service.providers.validate_destination("https://127.0.0.1/v1")
        self.assertEqual(normalized_ai_url("https://example.invalid/responses/"), "https://example.invalid/v1")
        with self.assertRaises(AppError):
            normalized_ai_url("https://username:password@example.invalid/v1")

    def test_unconfirmed_portion_blocks_meal_confirmation(self):
        result = self.push([self.mutation(kind="meal", payload={
            "eaten_at": datetime.now(timezone.utc).isoformat(), "status": "confirmed",
            "items": [{"id": str(uuid.uuid4()), "name": "食物", "amount": 100, "requires_portion": True}],
        })])[0]
        self.assertEqual(result["status"], "rejected")

    def test_interrupted_jobs_recover_without_waiting_for_lease(self):
        self.configure_ai()
        recognition = self.recognition_task()
        export = self.client.post("/api/v1/data/export", headers=self.headers(), json={
            "request_key": str(uuid.uuid4()), "password": "archive-password-123", "include_photos": False,
        }).json()
        with self.service.db.transaction() as repo:
            for task_id in (recognition["id"], export["id"]):
                repo.update("tasks", {"status": "running", "lease_until": (datetime.now(timezone.utc) + timedelta(minutes=30)).isoformat()}, {"id": task_id})
        self.service.jobs.recover_interrupted()
        with self.service.db.read() as repo:
            self.assertEqual(repo.one("tasks", {"id": recognition["id"]})["status"], "unknown")
            self.assertEqual(repo.one("tasks", {"id": export["id"]})["status"], "pending")

    def test_second_runtime_cannot_take_active_data_directory(self):
        with self.assertRaisesRegex(RuntimeError, "已有后台实例"):
            Runtime(self.settings, exclusive=True)

    def test_server_pairing_contains_identity_and_certificate_fingerprint(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID
        key = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "测试根证书")])
        now = datetime.now(timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(days=1))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(key, hashes.SHA256()))
        path = self.settings.data_dir / "tmp" / "root.crt"
        path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
        value = pairing(self.service, path)
        self.assertEqual(value["instance_id"], self.user["instance_id"])
        self.assertEqual(value["ca_sha256"], certificate.fingerprint(hashes.SHA256()).hex())
        identity = self.client.get("/api/v1/server-info").json()
        self.assertEqual(identity["instance_id"], self.user["instance_id"])
        self.assertNotIn("users", identity)

    def test_deletion_journal_survives_old_backup_restore(self):
        mutation = self.mutation()
        self.push([mutation])
        backup = self.service.maintenance.backup("backup-password-123")
        deleted = self.mutation(entity_id=mutation["entity_id"], version=1)
        deleted["deleted_at"] = datetime.now(timezone.utc).isoformat()
        self.assertEqual(self.push([deleted])[0]["status"], "accepted")
        events = self.service.db.deletion_journal.read()
        self.assertTrue(any(row["target_id"] == mutation["entity_id"] for row in events))
        archive = self.settings.data_dir / "backups" / backup["filename"]
        with patch("builtins.print"):
            restore(self.service, archive, "backup-password-123")
        with self.service.db.read() as repo:
            self.assertIsNone(repo.one("entities", {"id": mutation["entity_id"]}))
            self.assertEqual(repo.one("entity_ledger", {"entity_id": mutation["entity_id"]})["deleted"], 1)

    def test_shared_photos_require_started_challenge_and_notes_scope(self):
        other = self.register("viewer")
        challenge = self.challenge()
        challenge_id = challenge["id"]
        self.client.post("/api/v1/challenges/join", headers=self.headers(other),
                         json={"code": challenge["invite_code"], "goal": self.goal()})
        image_id, meal_id, _ = self.upload_photo()
        meal = self.mutation(kind="meal", entity_id=meal_id, payload={
            "eaten_at": datetime.now(timezone.utc).isoformat(), "status": "confirmed",
            "photo_ids": [image_id], "note": "私人备注",
            "items": [{"id": str(uuid.uuid4()), "name": "饭", "amount": 100, "basis_kcal": 100,
                       "uncertainty_note": "个人说明", "evidence_photo_ids": [image_id]}],
        })
        self.assertEqual(self.push([meal])[0]["status"], "accepted")
        self.client.put(f"/api/v1/challenges/{challenge_id}/consent", headers=self.headers(), json={
            "recipient_id": other["user_id"], "scopes": ["meals", "photos"], "expected_version": 0,
            "history_from": self.today,
        })
        photo_path = "/api/v1/media/" + image_id
        self.assertEqual(self.client.get(photo_path, headers=self.headers(other), params={"challenge_id": challenge_id}).status_code, 403)
        with self.service.db.transaction() as repo:
            start = datetime.combine(datetime.now(timezone.utc).date(), datetime.min.time(), timezone.utc)
            repo.update("challenges", {"status": "active", "start_at": start.isoformat(),
                                      "end_at": (start + timedelta(days=28)).isoformat()}, {"id": challenge_id})
        visible = self.client.get(f"/api/v1/challenges/{challenge_id}/summary", headers=self.headers(other),
                                  params={"day": self.today}).json()
        owner = next(row for row in visible["members"] if row["user_id"] == self.user["user_id"])
        self.assertEqual(owner["meals"][0]["note"], "")
        self.assertEqual(owner["meals"][0]["items"][0]["uncertainty_note"], "")
        self.assertEqual(self.client.get(photo_path, headers=self.headers(other), params={"challenge_id": challenge_id}).status_code, 200)


if __name__ == "__main__":
    unittest.main()
