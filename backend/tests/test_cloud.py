import asyncio
import hashlib
import io
import json
import os
import sqlite3
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import timedelta
from pathlib import Path
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.database import Database
from app.errors import AppError
from app.main import create_app
from app.models import RecognitionRequest, Login
from app.main import RequestGuard
from app.cli import restore
from app.email_verification import EmailVerificationService
from app.security import now_iso, utc_now


class CloudTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        with patch.dict(os.environ, {"DATA_DIR": self.temporary.name, "PUBLIC_URL": "https://cloud.example.invalid",
                        "DEPLOYMENT_MODE": "cloud", "AI_URL": "", "AI_KEY": "", "BACKUP_PASSWORD": "",
                        "SMTP_HOST": "", "SMTP_FROM": "", "AI_DAILY_LIMIT": "2"}):
            self.settings = Settings.from_environment()
        self.client = TestClient(create_app(self.settings, run_jobs=False))
        self.client.__enter__()
        self.service = self.client.app.state.runtime
        self.delivered = []
        self.service.auth.email.sender = lambda email, code, purpose: self.delivered.append((email, code, purpose))
        self.user = self.register("user@example.invalid")

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temporary.cleanup()

    def headers(self, user=None):
        return {"Authorization": "Bearer " + (user or self.user)["access_token"]}

    def actor(self, user=None):
        return self.service.auth.authenticate(self.headers(user)["Authorization"])

    def code(self, email, purpose):
        response = self.client.post("/api/v1/auth/email-code", json={"email": email, "purpose": purpose})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(set(response.json()), {"sent", "expires_in", "delivery_status"})
        while self.service.auth.email.deliver_pending():
            pass
        return next(code for address, code, kind in reversed(self.delivered) if address == email and kind == purpose)

    def register(self, email):
        code = self.code(email, "register")
        response = self.client.post("/api/v1/auth/register", json={"email": email, "email_code": code,
                                    "password": "test-password-123", "display_name": "测试用户", "device_id": str(uuid.uuid4())})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def grant(self, user=None):
        return self.service.entitlements.grant((user or self.user)["user_id"], (utc_now() + timedelta(days=2)).isoformat())

    def configure(self):
        with patch.dict(os.environ, {"AI_ALLOWED_HOSTS": "provider.invalid"}):
            return self.service.providers.configure_cloud("https://provider.invalid/v1", ["vision-a", "vision-b"],
                                                          "测试平台", "fake-platform-key")

    def consent(self):
        config = self.client.get("/api/v1/me/ai-consent", headers=self.headers()).json()
        response = self.client.put("/api/v1/me/ai-consent", headers=self.headers(),
                                    json={"allowed": True, "provider_revision": config["provider_revision"]})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def setup_ai(self):
        grant = self.grant()
        self.configure()
        return grant, self.consent()

    def photo(self, consent=None, temporary=True):
        image = io.BytesIO()
        Image.new("RGB", (24, 24), "#236655").save(image, format="JPEG")
        data = image.getvalue()
        media_id, meal_id = str(uuid.uuid4()), str(uuid.uuid4())
        body = {"id": media_id, "meal_id": meal_id, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "temporary": temporary}
        if consent:
            body.update(consent_revision=consent["revision"], provider_revision=consent["provider_revision"])
        initialized = self.client.post("/api/v1/media/upload-init", headers=self.headers(), json=body)
        self.assertEqual(initialized.status_code, 200, initialized.text)
        uploaded = self.client.put("/api/v1/media/" + media_id, headers=self.headers(), content=data)
        self.assertEqual(uploaded.status_code, 200, uploaded.text)
        return media_id, meal_id, body

    def recognition(self, consent):
        media_id, meal_id, _ = self.photo(consent)
        body = {"request_key": str(uuid.uuid4()), "meal_id": meal_id, "meal_version": 0, "photo_ids": [media_id],
                "allow_external": True, "consent_revision": consent["revision"], "provider_revision": consent["provider_revision"]}
        response = self.client.post("/api/v1/ai/food-recognition", headers=self.headers(), json=body)
        self.assertEqual(response.status_code, 200, response.text)
        with self.service.db.read() as repo:
            task = repo.one("tasks", {"id": response.json()["id"]})
        return task, body

    def process(self, task, after_first=None, incomplete=False):
        calls = []
        def handler(request):
            calls.append(request)
            if after_first and len(calls) == 1:
                after_first()
            item = {"name": "米饭", "estimated_weight_g": 100, "calories_kcal": 120,
                    "protein_g": 3, "carbs_g": 25, "fat_g": 1}
            if incomplete and len(calls) == 1:
                item["protein_g"] = None
            return httpx.Response(200, json={"status": "completed", "output_text": json.dumps({"items": [item]})})
        factory = httpx.AsyncClient
        with patch.dict(os.environ, {"AI_ALLOWED_HOSTS": "provider.invalid"}), patch("app.ai.httpx.AsyncClient", side_effect=lambda **kwargs: factory(transport=httpx.MockTransport(handler))):
            result = asyncio.run(self.service.ai.process(task))
        return result, calls

    def test_cloud_registration_requires_single_use_email_verification(self):
        rejected = self.client.post("/api/v1/auth/register", json={"username": "legacy", "password": "test-password-123",
                                                                 "display_name": "测试", "device_id": str(uuid.uuid4())})
        self.assertEqual(rejected.json()["code"], "EMAIL_VERIFICATION_REQUIRED")
        code = self.code("next@example.invalid", "register")
        body = {"email": "next@example.invalid", "email_code": "wrong!", "password": "test-password-123",
                "display_name": "新用户", "device_id": str(uuid.uuid4())}
        self.assertEqual(self.client.post("/api/v1/auth/register", json=body).status_code, 403)
        with self.service.db.read() as repo:
            self.assertEqual(repo.one("email_challenges", {"email": body["email"]})["attempts"], 1)
        body["email_code"] = code
        self.assertEqual(self.client.post("/api/v1/auth/register", json=body).status_code, 200)
        self.assertEqual(self.client.post("/api/v1/auth/register", json=body).json()["code"], "INVALID_EMAIL_CODE")
        account = self.client.get("/api/v1/me", headers=self.headers()).json()
        self.assertEqual(account["email"], "user@example.invalid")
        self.assertTrue(account["email_verified"])
        self.assertEqual(self.client.get("/api/v1/app/config").json()["ai_execution"], "gateway_only")

    def test_codes_expire_and_cannot_cross_purpose(self):
        code = self.code("fresh@example.invalid", "register")
        response = self.client.post("/api/v1/auth/reset-password", json={"email": "fresh@example.invalid", "email_code": code, "new_password": "new-password-123"})
        self.assertEqual(response.json()["code"], "INVALID_EMAIL_CODE")
        with self.service.db.transaction() as repo:
            repo.update("email_challenges", {"expires_at": (utc_now() - timedelta(seconds=1)).isoformat()}, {"email": "fresh@example.invalid"})
        with self.assertRaises(AppError):
            self.service.auth.email.consume("fresh@example.invalid", "register", code)

    def test_password_reset_and_unknown_account_response(self):
        with self.service.db.transaction() as repo:
            repo.delete("email_challenges", {"email": "user@example.invalid"})
        code = self.code("user@example.invalid", "reset_password")
        unknown = self.client.post("/api/v1/auth/email-code", json={"email": "missing@example.invalid", "purpose": "reset_password"})
        self.assertEqual(unknown.json(), {"sent": True, "expires_in": 600, "delivery_status": "queued"})
        self.assertFalse(any(row[0] == "missing@example.invalid" for row in self.delivered))
        reset = self.client.post("/api/v1/auth/reset-password", json={"email": "user@example.invalid", "email_code": code, "new_password": "new-password-123"})
        self.assertEqual(reset.status_code, 200, reset.text)
        self.assertEqual(self.client.get("/api/v1/me", headers=self.headers()).status_code, 401)
        login = self.client.post("/api/v1/auth/login", json={"username": "user@example.invalid", "password": "new-password-123", "device_id": str(uuid.uuid4())})
        self.assertEqual(login.status_code, 200, login.text)

    def test_email_binding_password_change_and_logout_all(self):
        second = self.client.post("/api/v1/auth/login", json={"username": "user@example.invalid", "password": "test-password-123", "device_id": str(uuid.uuid4())}).json()
        request = {"email": "changed@example.invalid", "current_password": "test-password-123"}
        response = self.client.post("/api/v1/me/email-code", headers=self.headers(), json=request)
        self.assertEqual(response.status_code, 200, response.text)
        while self.service.auth.email.deliver_pending():
            pass
        request["email_code"] = self.delivered[-1][1]
        bound = self.client.put("/api/v1/me/email", headers=self.headers(), json=request)
        self.assertEqual(bound.json()["email"], "changed@example.invalid")
        self.assertEqual(self.client.get("/api/v1/me", headers=self.headers(second)).status_code, 401)
        change = self.client.post("/api/v1/me/password", headers=self.headers(), json={"current_password": "test-password-123", "new_password": "changed-password-123"})
        self.assertEqual(change.status_code, 200, change.text)
        self.assertEqual(self.client.get("/api/v1/me", headers=self.headers()).status_code, 401)
        self.user = self.client.post("/api/v1/auth/login", json={"username": "changed@example.invalid", "password": "changed-password-123", "device_id": str(uuid.uuid4())}).json()
        self.assertEqual(self.client.post("/api/v1/auth/logout-all", headers=self.headers()).status_code, 200)
        self.assertEqual(self.client.get("/api/v1/me", headers=self.headers()).status_code, 401)

    def test_reset_code_cannot_follow_email_to_another_account(self):
        other = self.register("other@example.invalid")
        with self.service.db.transaction() as repo:
            repo.delete("email_challenges", {"email": "user@example.invalid"})
        code = self.code("user@example.invalid", "reset_password")
        # 模拟消费验证码前邮箱已经转让，保留旧挑战以验证 user_id 绑定本身。
        with self.service.db.transaction() as repo:
            repo.update("users", {"email": "moved@example.invalid"}, {"id": self.user["user_id"]})
            repo.update("users", {"email": "user@example.invalid"}, {"id": other["user_id"]})
        response = self.client.post("/api/v1/auth/reset-password", json={"email": "user@example.invalid", "email_code": code, "new_password": "attacker-password-123"})
        self.assertEqual(response.json()["code"], "INVALID_EMAIL_CODE")
        valid = self.client.post("/api/v1/auth/login", json={"username": "user@example.invalid", "password": "test-password-123", "device_id": str(uuid.uuid4())})
        self.assertEqual(valid.status_code, 200, valid.text)
        self.assertEqual(valid.json()["user_id"], other["user_id"])

    def test_deleted_account_code_cannot_reset_reregistered_email(self):
        with self.service.db.transaction() as repo:
            repo.delete("email_challenges", {"email": "user@example.invalid"})
        code = self.code("user@example.invalid", "reset_password")
        deletion = self.client.request("DELETE", "/api/v1/account", headers=self.headers(), json={"request_key": str(uuid.uuid4()), "password": "test-password-123"}).json()
        with self.service.db.read() as repo:
            task = repo.one("tasks", {"id": deletion["id"]})
        self.service.data.process_delete(task)
        replacement = self.register("user@example.invalid")
        self.assertNotEqual(replacement["user_id"], self.user["user_id"])
        response = self.client.post("/api/v1/auth/reset-password", json={"email": "user@example.invalid", "email_code": code, "new_password": "attacker-password-123"})
        self.assertEqual(response.json()["code"], "INVALID_EMAIL_CODE")

    def test_mail_failure_does_not_change_public_response_or_expose_code(self):
        with self.service.db.transaction() as repo:
            repo.delete("email_challenges", {"email": "user@example.invalid"})
        def failed_sender(email, code, purpose):
            raise OSError("模拟邮件服务不可用")
        self.service.auth.email.sender = failed_sender
        known = self.client.post("/api/v1/auth/email-code", json={"email": "user@example.invalid", "purpose": "reset_password"})
        unknown = self.client.post("/api/v1/auth/email-code", json={"email": "missing@example.invalid", "purpose": "reset_password"})
        self.assertEqual(known.json(), unknown.json())
        self.assertEqual(known.status_code, 200)
        self.assertTrue(self.service.auth.email.deliver_pending())
        with self.service.db.read() as repo:
            delivery = repo.find("email_deliveries", {"status": "pending"}, order=["created_at"])[0]
            self.assertNotIn("user@example.invalid", delivery["encrypted_payload"])
            self.assertEqual(delivery["attempts"], 1)

    def test_account_throttle_survives_different_device_identifiers(self):
        for _ in range(20):
            with self.assertRaises(AppError) as caught:
                self.service.auth.login(Login(username="user@example.invalid", password="wrong", device_id=str(uuid.uuid4())))
            self.assertEqual(caught.exception.code, "INVALID_CREDENTIALS")
        with self.assertRaises(AppError) as caught:
            self.service.auth.login(Login(username="user@example.invalid", password="wrong", device_id=str(uuid.uuid4())))
        self.assertEqual(caught.exception.code, "ACCOUNT_RATE_LIMITED")

    def test_refresh_replay_revokes_family(self):
        renewed = self.client.post("/api/v1/auth/refresh", json={"refresh_token": self.user["refresh_token"]}).json()
        replay = self.client.post("/api/v1/auth/refresh", json={"refresh_token": self.user["refresh_token"]})
        self.assertEqual(replay.status_code, 401)
        self.assertEqual(self.client.get("/api/v1/me", headers=self.headers(renewed)).status_code, 401)

    def test_basic_account_has_no_ai_but_keeps_regular_media_and_data(self):
        self.configure()
        rights = self.client.get("/api/v1/me/entitlements", headers=self.headers()).json()
        self.assertFalse(rights["ai_food_recognition"])
        for path in ("ai/settings", "ai/models", "me/ai-preferences"):
            self.assertEqual(self.client.get("/api/v1/" + path, headers=self.headers()).status_code, 403)
        body = {"request_key": "test", "meal_id": str(uuid.uuid4()), "meal_version": 0, "photo_ids": [str(uuid.uuid4())]}
        self.assertEqual(self.client.post("/api/v1/ai/food-recognition", headers=self.headers(), json=body).json()["code"], "SVIP_REQUIRED")
        media_id, meal_id, media_body = self.photo(temporary=False)
        media_body["temporary"] = True
        self.assertEqual(self.client.post("/api/v1/media/upload-init", headers=self.headers(), json=media_body).json()["code"], "SVIP_REQUIRED")
        self.assertEqual(self.client.get("/api/v1/media/" + media_id, headers=self.headers()).status_code, 200)
        self.assertEqual(self.client.get("/api/v1/records", headers=self.headers()).status_code, 200)
        self.assertEqual(self.client.put("/api/v1/ai/settings", headers=self.headers(), json={"base_url": "https://fake.invalid", "model": "fake", "api_key": "key"}).status_code, 403)

    def test_multi_source_grants_and_expiration(self):
        first, second = self.grant(), self.grant()
        self.service.entitlements.revoke(first["id"], "撤销第一来源")
        current = self.client.get("/api/v1/me/entitlements", headers=self.headers()).json()
        self.assertTrue(current["ai_food_recognition"])
        self.assertIsNotNone(current["valid_until"])
        with self.service.db.transaction() as repo:
            repo.update("entitlement_grants", {"valid_until": (utc_now() - timedelta(seconds=1)).isoformat()}, {"id": second["id"]})
        self.assertFalse(self.client.get("/api/v1/me/entitlements", headers=self.headers()).json()["ai_food_recognition"])

    def test_platform_configuration_keeps_keys_private_and_models_restricted(self):
        _, consent = self.setup_ai()
        for path in ("capabilities", "ai/settings", "me/ai-preferences", "app/config"):
            text = self.client.get("/api/v1/" + path, headers=self.headers()).text
            self.assertNotIn("fake-platform-key", text)
            self.assertNotIn("provider.invalid", text)
        with self.service.db.read() as repo:
            self.assertNotIn("fake-platform-key", repo.one("cloud_ai_provider", {"id": "platform"})["encrypted_key"])
        selected = self.client.put("/api/v1/me/ai-preferences", headers=self.headers(), json={"model_id": "vision-b"})
        self.assertEqual(selected.json()["model_id"], "vision-b")
        self.assertEqual(self.client.put("/api/v1/me/ai-preferences", headers=self.headers(), json={"model_id": "expensive-unlisted"}).status_code, 403)
        self.assertEqual(self.client.post("/api/v1/ai/test", headers=self.headers()).status_code, 403)
        self.configure()
        stale = self.client.put("/api/v1/me/ai-consent", headers=self.headers(), json={"allowed": True, "provider_revision": consent["provider_revision"]})
        self.assertEqual(stale.json()["code"], "PROVIDER_CHANGED")

    def test_concurrent_idempotency_reserves_once_and_quota_blocks_new_task(self):
        _, consent = self.setup_ai()
        media_id, meal_id, _ = self.photo(consent)
        body = {"request_key": str(uuid.uuid4()), "meal_id": meal_id, "meal_version": 0, "photo_ids": [media_id],
                "allow_external": True, "consent_revision": consent["revision"], "provider_revision": consent["provider_revision"]}
        with ThreadPoolExecutor(max_workers=2) as pool:
            rows = list(pool.map(lambda _: self.service.ai.create(self.actor(), RecognitionRequest(**body)), range(2)))
        self.assertEqual(len({row["id"] for row in rows}), 1)
        self.assertEqual(self.client.get("/api/v1/me/entitlements", headers=self.headers()).json()["quota"]["used"], 1)
        mismatch = {**body, "note": "不同内容"}
        self.assertEqual(self.client.post("/api/v1/ai/food-recognition", headers=self.headers(), json=mismatch).json()["code"], "IDEMPOTENCY_CONFLICT")
        def create_another(_):
            try:
                self.service.ai.create(self.actor(), RecognitionRequest(**{**body, "request_key": str(uuid.uuid4())}))
                return "accepted"
            except AppError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            competing = list(pool.map(create_another, range(2)))
        self.assertEqual(sorted(competing), ["AI_QUOTA_EXCEEDED", "accepted"])
        body["request_key"] = str(uuid.uuid4())
        self.assertEqual(self.client.post("/api/v1/ai/food-recognition", headers=self.headers(), json=body).json()["code"], "AI_QUOTA_EXCEEDED")

    def test_cloud_identifies_local_only_meal_and_completes_once(self):
        _, consent = self.setup_ai()
        task, body = self.recognition(consent)
        with self.service.db.read() as repo:
            self.assertIsNone(repo.one("entities", {"id": body["meal_id"], "user_id": self.user["user_id"]}))
            self.assertNotIn("_provider_snapshot", json.loads(task["payload"]))
        result, calls = self.process(task)
        self.assertEqual(len(calls), 1)
        self.service.jobs.finish(task["id"], "completed", result, None)
        retrieved = self.client.get("/api/v1/ai/tasks/" + task["id"], headers=self.headers()).json()
        self.assertEqual(retrieved["result"]["items"][0]["name"], "米饭")
        with self.service.db.read() as repo:
            self.assertEqual(repo.one("ai_usage", {"task_id": task["id"]})["status"], "completed")

    def test_task_metadata_version_change_does_not_cancel_recognition(self):
        _, consent = self.setup_ai()
        media_id, meal_id, _ = self.photo(consent)
        payload = {"eaten_at": now_iso(), "status": "draft", "photo_ids": [media_id], "note": "", "items": []}
        with self.service.db.transaction() as repo:
            repo.insert("entities", {"id": meal_id, "user_id": self.user["user_id"], "kind": "meal", "payload": json.dumps(payload),
                        "business_date": utc_now().date().isoformat(), "version": 1, "updated_at": now_iso(), "device_id": self.user["device_id"]})
        request = RecognitionRequest(request_key=str(uuid.uuid4()), meal_id=meal_id, meal_version=0, photo_ids=[media_id],
                                     allow_external=True, consent_revision=consent["revision"], provider_revision=consent["provider_revision"])
        created = self.service.ai.create(self.actor(), request)
        with self.service.db.transaction() as repo:
            task = repo.one("tasks", {"id": created["id"]})
            payload["ai_task_id"] = task["id"]
            repo.update("entities", {"version": 2, "payload": json.dumps(payload)}, {"id": meal_id, "user_id": self.user["user_id"]})
        result, calls = self.process(task)
        self.assertEqual(len(calls), 1)
        self.assertTrue(result["items"])
        with self.service.db.transaction() as repo:
            payload["note"] = "真正修改识别内容"
            repo.update("entities", {"version": 3, "payload": json.dumps(payload)}, {"id": meal_id, "user_id": self.user["user_id"]})
        with self.assertRaises(AppError) as caught:
            self.process(task)
        self.assertEqual(caught.exception.code, "MEAL_VERSION_CHANGED")

    def test_revocation_before_processing_releases_reservation(self):
        grant, consent = self.setup_ai()
        task, _ = self.recognition(consent)
        self.service.entitlements.revoke(grant["id"], "测试撤销")
        with self.assertRaises(AppError):
            self.process(task)
        with self.service.db.read() as repo:
            self.assertEqual(repo.one("ai_usage", {"task_id": task["id"]})["status"], "released")
            self.assertEqual(repo.one("tasks", {"id": task["id"]})["status"], "cancelled")

    def test_expired_membership_or_originating_session_stops_queued_task(self):
        grant, consent = self.setup_ai()
        task, _ = self.recognition(consent)
        with self.service.db.transaction() as repo:
            repo.update("entitlement_grants", {"valid_until": (utc_now() - timedelta(seconds=1)).isoformat()}, {"id": grant["id"]})
        with self.assertRaises(AppError) as expired:
            self.process(task)
        self.assertEqual(expired.exception.code, "SVIP_REQUIRED")
        self.grant()
        with self.service.db.transaction() as repo:
            repo.update("sessions", {"refresh_expires_at": (utc_now() - timedelta(seconds=1)).isoformat()}, {"user_id": self.user["user_id"]})
        with self.assertRaises(AppError) as session_expired:
            self.process(task)
        self.assertEqual(session_expired.exception.code, "TASK_CANCELLED")

    def test_email_queue_survives_service_recreation_without_plaintext(self):
        response = self.client.post("/api/v1/auth/email-code", json={"email": "queued@example.invalid", "purpose": "register"})
        self.assertEqual(response.json()["delivery_status"], "queued")
        captured = []
        recreated = EmailVerificationService(self.service.db, self.settings, sender=lambda email, code, purpose: captured.append((email, code)))
        while recreated.deliver_pending():
            pass
        self.assertEqual(captured[0][0], "queued@example.invalid")
        challenge = recreated.consume(captured[0][0], "register", captured[0][1])
        self.assertEqual(challenge["email"], "queued@example.invalid")

    def test_cloud_restore_freezes_grants_consents_codes_and_recognition(self):
        grant, consent = self.setup_ai()
        task, _ = self.recognition(consent)
        self.client.post("/api/v1/auth/email-code", json={"email": "queued@example.invalid", "purpose": "register"})
        backup = self.service.maintenance.backup("backup-password-123", incremental=False)
        self.service.entitlements.revoke(grant["id"], "备份之后撤销")
        restore(self.service, self.settings.data_dir / "backups" / backup["filename"], "backup-password-123")
        with self.service.db.read() as repo:
            self.assertFalse(self.service.entitlements.active_grants(repo, self.user["user_id"]))
            self.assertIsNotNone(repo.one("entitlement_grants", {"id": grant["id"]})["revoked_at"])
            self.assertTrue(repo.find("entitlement_events", {"action": "restore_freeze", "user_id": self.user["user_id"]}))
            self.assertFalse(repo.one("cloud_ai_consents", {"user_id": self.user["user_id"]})["allowed"])
            self.assertEqual(repo.one("tasks", {"id": task["id"]})["status"], "cancelled")
            self.assertEqual(repo.find("email_challenges", {"used_at": None}), [])
            self.assertEqual(repo.find("email_deliveries", {"status": "pending"}), [])

    def test_revocation_during_first_request_prevents_nutrition_completion(self):
        grant, consent = self.setup_ai()
        task, _ = self.recognition(consent)
        with self.assertRaises(AppError):
            self.process(task, after_first=lambda: self.service.entitlements.revoke(grant["id"], "执行中撤销"), incomplete=True)
        with self.service.db.read() as repo:
            usage = repo.one("ai_usage", {"task_id": task["id"]})
            self.assertEqual(usage["provider_calls"], 1)
            self.assertEqual(usage["status"], "unknown")

    def test_consent_revocation_stops_upload_and_pending_task(self):
        _, consent = self.setup_ai()
        task, body = self.recognition(consent)
        response = self.client.put("/api/v1/me/ai-consent", headers=self.headers(), json={"allowed": False, "provider_revision": consent["provider_revision"]})
        self.assertEqual(response.status_code, 200)
        upload = self.client.put("/api/v1/media/" + body["photo_ids"][0], headers=self.headers(), content=b"")
        self.assertEqual(upload.json()["code"], "AI_CONSENT_REQUIRED")
        with self.assertRaises(AppError):
            self.process(task)

    def test_data_task_alias_cannot_bypass_ai_result_permission(self):
        grant, consent = self.setup_ai()
        task, _ = self.recognition(consent)
        result, _ = self.process(task)
        self.service.jobs.finish(task["id"], "completed", result, None)
        self.service.entitlements.revoke(grant["id"], "测试降级")
        for prefix in ("ai", "data"):
            value = self.client.get(f"/api/v1/{prefix}/tasks/" + task["id"], headers=self.headers()).json()
            self.assertIsNone(value["result"])
            self.assertTrue(value["result_withheld"])
        export = self.client.post("/api/v1/data/export", headers=self.headers(), json={"request_key": str(uuid.uuid4()), "password": "archive-password-123", "include_photos": False}).json()
        self.assertEqual(self.client.get("/api/v1/data/tasks/" + export["id"], headers=self.headers()).status_code, 200)
        self.assertEqual(self.client.post("/api/v1/ai/tasks/" + export["id"] + "/cancel", headers=self.headers()).status_code, 404)

    def test_account_deletion_removes_cloud_identity_and_rights(self):
        _, consent = self.setup_ai()
        self.recognition(consent)
        deletion = self.client.request("DELETE", "/api/v1/account", headers=self.headers(), json={"request_key": str(uuid.uuid4()), "password": "test-password-123"})
        self.assertEqual(deletion.status_code, 200, deletion.text)
        with self.service.db.read() as repo:
            task = repo.one("tasks", {"id": deletion.json()["id"]})
        self.service.data.process_delete(task)
        with self.service.db.read() as repo:
            user = repo.one("users", {"id": self.user["user_id"]})
            self.assertIsNone(user["email"])
            self.assertEqual(user["status"], "deleted")
            for table in ("entitlement_grants", "cloud_ai_consents", "cloud_ai_preferences", "ai_usage"):
                self.assertEqual(repo.find(table, {"user_id": self.user["user_id"]}), [])

    def test_data_reset_preserves_membership_and_consumed_quota(self):
        _, consent = self.setup_ai()
        task, _ = self.recognition(consent)
        result, _ = self.process(task)
        self.service.jobs.finish(task["id"], "completed", result, None)
        deletion = self.client.request("DELETE", "/api/v1/account/data", headers=self.headers(),
                    json={"request_key": str(uuid.uuid4()), "password": "test-password-123"}).json()
        with self.service.db.read() as repo:
            task = repo.one("tasks", {"id": deletion["id"]})
        self.service.data.process_delete(task)
        with self.service.db.read() as repo:
            self.assertTrue(self.service.entitlements.active_grants(repo, self.user["user_id"]))
            self.assertEqual(self.service.entitlements.quota(repo, self.user["user_id"])["used"], 1)
            self.assertEqual(repo.one("users", {"id": self.user["user_id"]})["status"], "active")


class CloudMigrationTests(unittest.TestCase):
    def test_ip_guard_bounds_buckets_and_reclaims_expired_entries(self):
        messages = []
        async def app(scope, receive, send):
            await send({"type": "http.response.start", "status": 204, "headers": []})
            await send({"type": "http.response.body", "body": b""})
        async def receive():
            return {"type": "http.request", "body": b""}
        async def send(message):
            messages.append(message)
        guard = RequestGuard(app)
        guard.maximum_buckets = 2
        with patch("app.main.time.monotonic", return_value=100):
            for address in ("192.0.2.1", "192.0.2.2", "192.0.2.3"):
                asyncio.run(guard({"type": "http", "path": "/api/v1/health", "client": (address, 1000)}, receive, send))
        self.assertEqual([value["status"] for value in messages if value["type"] == "http.response.start"], [204, 204, 429])
        self.assertEqual(len(guard.attempts), 2)
        with patch("app.main.time.monotonic", return_value=161):
            asyncio.run(guard({"type": "http", "path": "/api/v1/health", "client": ("192.0.2.3", 1000)}, receive, send))
        self.assertEqual(len(guard.attempts), 1)

    def test_upgrade_preserves_legacy_account_and_session(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.sqlite3"
            connection = sqlite3.connect(path)
            migrations = Path(__file__).parents[1] / "app" / "migrations"
            connection.executescript((migrations / "001_initial.sql").read_text())
            connection.executescript((migrations / "002_ai_settings.sql").read_text())
            connection.execute("CREATE TABLE schema_version(version INTEGER PRIMARY KEY)")
            connection.executemany("INSERT INTO schema_version(version) VALUES (?)", [(1,), (2,)])
            connection.execute("INSERT INTO users(id,username,display_name,password_hash,recovery_hash,generation,status,created_at) VALUES (?,?,?,?,?,?,?,?)",
                               ("legacy", "legacy_user", "原用户", "hash", "recovery", 7, "active", now_iso()))
            connection.execute("INSERT INTO devices(id,user_id,name,last_seen_at) VALUES (?,?,?,?)", ("old-device", "legacy", "原手机", now_iso()))
            connection.execute("INSERT INTO sessions(id,user_id,device_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,generation) VALUES (?,?,?,?,?,?,?,?)",
                               ("old-session", "legacy", "old-device", "old-access-hash", "old-refresh-hash", now_iso(), now_iso(), 7))
            connection.execute("INSERT INTO entities(id,user_id,kind,payload,business_date,version,updated_at,device_id) VALUES (?,?,?,?,?,?,?,?)",
                               ("old-weight", "legacy", "weight", '{"weight_kg":70}', "2026-01-01", 4, now_iso(), "old-device"))
            connection.commit()
            connection.close()
            database = Database(path)
            database.initialize()
            database.initialize()
            with database.read() as repo:
                user = repo.one("users", {"id": "legacy"})
                self.assertEqual(user["generation"], 7)
                self.assertEqual(user["password_hash"], "hash")
                self.assertIsNone(user["email"])
                self.assertEqual(repo.find("entitlement_grants", {"user_id": "legacy"}), [])
                session = repo.one("sessions", {"id": "old-session"})
                self.assertEqual(session["family_id"], "old-session")
                self.assertEqual(session["refresh_hash"], "old-refresh-hash")
                record = repo.one("entities", {"id": "old-weight", "user_id": "legacy"})
                self.assertEqual(json.loads(record["payload"])["weight_kg"], 70)
                self.assertEqual(record["version"], 4)
