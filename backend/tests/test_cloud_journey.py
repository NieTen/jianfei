"""只使用回环 HTTP、临时数据卷和虚构邮件投递的云端业务闭环。"""
import hashlib
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
from PIL import Image


def serve_fixture(port):
    import uvicorn
    from app.main import create_app

    application = create_app()
    original = application.router.lifespan_context

    def deliver(email, code, purpose):
        # 仅替换外部邮件投递；排队、加密、消费和 HTTP 注册仍使用实际代码。
        target = Path(os.environ["JOURNEY_MAILBOX"]) / (hashlib.sha256(email.encode()).hexdigest() + ".json")
        pending = target.with_suffix(".pending")
        pending.write_text(json.dumps({"code": code, "purpose": purpose}), encoding="utf-8")
        pending.replace(target)

    @asynccontextmanager
    async def lifespan(app):
        async with original(app):
            app.state.runtime.auth.email.sender = deliver
            app.state.runtime.jobs.enqueue_backup = lambda: None
            yield

    application.router.lifespan_context = lifespan
    uvicorn.run(application, host="127.0.0.1", port=port, access_log=False)


class CloudJourneyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bingjian-cloud-journey-")
        self.root = Path(self.temporary.name)
        self.replica = self.root / "replica"
        self.mailbox = self.root / "mailbox"
        self.replica.mkdir()
        self.mailbox.mkdir()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        self.backend = Path(__file__).resolve().parents[1]
        self.environment = os.environ | {
            "DATA_DIR": str(self.root / "original-volume"), "DEPLOYMENT_MODE": "cloud",
            "PUBLIC_URL": f"http://127.0.0.1:{self.port}", "CLOUD_ALLOW_HTTP": "true",
            "JOURNEY_MAILBOX": str(self.mailbox), "AI_URL": "", "AI_KEY": "", "AI_MODEL": "",
            "SMTP_HOST": "", "SMTP_FROM": "", "SMTP_PASSWORD": "", "APNS_KEY_FILE": "", "FOOD_API_KEY": "",
            "BACKUP_PASSWORD": "synthetic-backup-password", "BACKUP_REPLICA_DIR": str(self.replica),
            "BACKUP_REPLICA_REQUIRED": "true",
        }
        self.password = "synthetic-account-password"
        self.client = httpx.Client(base_url=f"http://127.0.0.1:{self.port}", timeout=15, trust_env=False)
        self.process = None
        self.log = (self.root / "process.log").open("w+")
        self.day = datetime.now(timezone.utc).date().isoformat()
        self.addCleanup(self.temporary.cleanup)
        self.addCleanup(self.log.close)
        self.addCleanup(self.client.close)
        self.addCleanup(self.stop)
        self.start()

    def start(self):
        self.process = subprocess.Popen([sys.executable, "-m", "tests.test_cloud_journey", "--serve", str(self.port)],
            cwd=self.backend, env=self.environment, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.log.flush()
                self.fail("隔离 HTTP 服务退出：" + (self.root / "process.log").read_text())
            try:
                if self.client.get("/api/v1/health").status_code == 200:
                    return
            except httpx.TransportError:
                pass
            time.sleep(0.05)
        self.fail("隔离 HTTP 服务未就绪")

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process = None

    @staticmethod
    def headers(user):
        return {"Authorization": "Bearer " + user["access_token"]} if user else {}

    def request(self, method, path, user=None, status=200, **kwargs):
        response = self.client.request(method, path, headers=self.headers(user), **kwargs)
        self.assertEqual(response.status_code, status, f"{method} {path}: {response.text[:1000]}")
        return response

    def register(self, name):
        email, device = name + "@example.invalid", str(uuid.uuid4())
        queued = self.request("POST", "/api/v1/auth/email-code", json={"email": email, "purpose": "register"}).json()
        self.assertEqual(queued["delivery_status"], "queued")
        target = self.mailbox / (hashlib.sha256(email.encode()).hexdigest() + ".json")
        deadline = time.monotonic() + 10
        while not target.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        code = json.loads(target.read_text())["code"]
        user = self.request("POST", "/api/v1/auth/register", json={"email": email, "email_code": code,
            "password": self.password, "display_name": "虚构" + name, "device_id": device,
            "cloud_rules_version": "1"}).json()
        user.update(fixture_email=email, fixture_device=device)
        return user

    def login(self, old, status=200):
        return self.request("POST", "/api/v1/auth/login", status=status, json={"username": old["fixture_email"],
            "password": self.password, "device_id": old["fixture_device"]}).json()

    def push(self, user, changes):
        return self.request("POST", "/api/v1/sync/push", user, json={"epoch": user["epoch"],
            "generation": user["generation"], "changes": changes}).json()["results"]

    def change(self, kind, payload, entity_id=None):
        return {"change_id": str(uuid.uuid4()), "entity_id": entity_id or str(uuid.uuid4()), "kind": kind,
                "business_date": self.day, "base_version": 0, "payload": payload}

    def photo(self, user):
        photo, meal = str(uuid.uuid4()), str(uuid.uuid4())
        output = io.BytesIO()
        Image.new("RGB", (32, 32), "#336655").save(output, format="JPEG")
        contents = output.getvalue()
        self.request("POST", "/api/v1/media/upload-init", user, json={"id": photo, "meal_id": meal,
            "size": len(contents), "sha256": hashlib.sha256(contents).hexdigest(), "temporary": False})
        self.assertEqual(self.request("PUT", "/api/v1/media/" + photo, user, content=contents).json()["status"], "ready")
        return photo, meal, contents

    def cli(self, *arguments):
        result = subprocess.run([sys.executable, "-m", "app.cli", *arguments], cwd=self.backend,
            env=self.environment, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_three_cloud_accounts_share_and_restore_from_independent_volume(self):
        owner, reader, stranger = [self.register(name) for name in ("journey-owner", "journey-reader", "journey-stranger")]
        for user in (owner, reader, stranger):
            rights = self.request("GET", "/api/v1/me/entitlements", user).json()
            self.assertFalse(rights["ai_food_recognition"])
        live_photo, live_meal, photo_bytes = self.photo(owner)
        deleted_photo, deleted_meal, _ = self.photo(owner)
        weight = {"measured_at": self.day + "T08:00:00+00:00", "weight_kg": 72.35}
        changes = [self.change("weight", weight), self.change("weight", weight)]
        for photo, meal in ((live_photo, live_meal), (deleted_photo, deleted_meal)):
            changes.append(self.change("meal", {"eaten_at": self.day + "T10:00:00+00:00", "meal_type": "lunch",
                "status": "confirmed", "photo_ids": [photo], "note": "虚构私密备注",
                "items": [{"id": str(uuid.uuid4()), "name": "虚构苹果", "amount": 123, "basis_kcal": 52}]}, meal))
        self.assertTrue(all(row["status"] == "accepted" for row in self.push(owner, changes)))
        self.assertEqual(self.request("GET", "/api/v1/records", stranger).json(), [])
        self.assertEqual(self.push(stranger, [self.change("weight", weight)])[0]["status"], "accepted")
        print("云端 HTTP：三个邮箱验证账号完成基础记录和两张照片上传，非会员基础能力可用", flush=True)

        goal = {"target_weight_kg": 68, "step_goal": 8000, "start_date": self.day,
                "end_date": (datetime.now(timezone.utc).date() + timedelta(days=28)).isoformat()}
        challenge = self.request("POST", "/api/v1/challenges", owner, json={"title": "虚构三人挑战", "timezone": "UTC",
            "duration_days": 28, "max_members": 3, "goal": goal}).json()
        preview = "/api/v1/challenge-invites/" + challenge["invite_code"]
        self.request("GET", preview, status=401)
        for _ in range(2):
            self.assertEqual(self.request("GET", preview, reader).json()["title"], "虚构三人挑战")
        self.request("POST", "/api/v1/challenges/join", reader, json={"code": challenge["invite_code"], "goal": goal})
        self.request("GET", preview, stranger, status=409)
        spare_invite = self.request("POST", f"/api/v1/challenges/{challenge['id']}/invite", owner).json()["invite_code"]
        consent_path = f"/api/v1/challenges/{challenge['id']}/consent"
        self.request("PUT", consent_path, owner, json={"recipient_id": reader["user_id"], "scopes": ["weight", "photos"],
            "history_from": self.day, "expected_version": 0})

        share = "/api/v1/shares/" + str(uuid.uuid4())
        body = {"recipient": reader["fixture_email"], "scopes": ["weight", "meals"], "from_day": self.day,
                "through_day": self.day, "expires_at": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat(), "expected_version": 0}
        self.request("PUT", share, owner, json=body)
        projection = self.request("GET", share + "/summary", reader, params={"day": self.day}).json()
        self.assertEqual(projection["weight_kg"], 72.35)
        self.assertNotIn("note", projection["meals"][0])
        self.assertNotIn("photo_ids", projection["meals"][0])
        self.assertNotIn("diet", projection)
        self.request("GET", share + "/summary", stranger, status=403, params={"day": self.day})
        self.request("GET", share + "/summary", reader, status=403, params={"day": "2000-01-01"})
        self.request("GET", share + "/media/" + live_photo, reader, status=403)
        self.request("GET", "/api/v1/media/" + live_photo, reader, status=403)
        revised = {**body, "scopes": ["photos", "notes"], "expected_version": 1}
        revised.pop("recipient")
        self.request("PUT", share, owner, json=revised)
        projection = self.request("GET", share + "/summary", reader, params={"day": self.day}).json()
        self.assertNotIn("weight_kg", projection)
        self.assertEqual(projection["meals"][0]["note"], "虚构私密备注")
        photo_response = self.request("GET", share + "/media/" + live_photo, reader)
        self.assertEqual(photo_response.content, photo_bytes)
        self.assertEqual(photo_response.headers["Cache-Control"], "no-store")
        self.request("GET", share + "/media/" + live_photo, reader, params={"thumbnail": True})
        self.request("PUT", share, owner, status=409, json=revised)

        expiring = "/api/v1/shares/" + str(uuid.uuid4())
        self.request("PUT", expiring, owner, json={**body, "scopes": ["photos"],
            "expires_at": (datetime.now(timezone.utc) + timedelta(seconds=2)).isoformat()})
        self.request("GET", expiring + "/media/" + live_photo, reader)
        time.sleep(2.1)
        self.request("GET", expiring + "/summary", reader, status=403, params={"day": self.day})
        self.request("GET", expiring + "/media/" + live_photo, reader, status=403)
        still_active = "/api/v1/shares/" + str(uuid.uuid4())
        self.request("PUT", still_active, owner, json=body)
        print("云端 HTTP：邀请预览不消费、加入成功；字段/日期/接收人隔离、照片授权、真实到期拒绝通过", flush=True)

        self.stop()
        backup = json.loads(self.cli("backup"))
        self.assertTrue(backup["replica"]["verified"])
        self.assertGreater(backup["referenced_objects"], 0)
        archive = self.replica / "backups" / backup["filename"]
        self.start()
        for original in (changes[1], changes[3]):
            self.assertEqual(self.push(owner, [{**original, "change_id": str(uuid.uuid4()), "base_version": 1,
                "deleted_at": datetime.now(timezone.utc).isoformat()}])[0]["status"], "accepted")
        self.request("POST", share + "/revoke", owner)
        self.request("GET", share + "/media/" + live_photo, reader, status=403)
        deletion = self.request("DELETE", "/api/v1/account", stranger, json={"password": self.password,
            "request_key": str(uuid.uuid4()), "receipt_secret": "synthetic-deletion-receipt-secret-123"}).json()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            response = self.client.get("/api/v1/data/deletions/" + deletion["id"],
                headers={"X-Deletion-Receipt": "synthetic-deletion-receipt-secret-123"})
            self.assertEqual(response.status_code, 200, response.text)
            if response.json()["status"] == "completed":
                break
            time.sleep(0.1)
        else:
            self.fail("账号删除任务未完成")
        self.stop()
        shutil.rmtree(self.root / "original-volume")
        self.environment["DATA_DIR"] = str(self.root / "fresh-volume")
        self.assertFalse(Path(self.environment["DATA_DIR"]).exists())
        self.assertIn("恢复完成", self.cli("restore", str(archive)))
        self.assertTrue(json.loads(self.cli("status"))["backup_replica_configured"])
        self.start()
        self.request("GET", "/api/v1/records", owner, status=401)
        fresh_owner, fresh_reader = self.login(owner), self.login(reader)
        self.login(stranger, status=401)
        active = self.request("GET", "/api/v1/records", fresh_owner).json()
        self.assertEqual({row["id"] for row in active}, {changes[0]["entity_id"], live_meal})
        self.assertEqual(self.request("GET", "/api/v1/media/" + live_photo, fresh_owner).content, photo_bytes)
        self.assertIn(self.client.get("/api/v1/media/" + deleted_photo, headers=self.headers(fresh_owner)).status_code, (403, 404))
        for old_share in (share, still_active, expiring):
            self.request("GET", old_share + "/summary", fresh_reader, status=403, params={"day": self.day})
            self.request("GET", old_share + "/media/" + live_photo, fresh_reader, status=403)
        self.request("GET", "/api/v1/challenge-invites/" + spare_invite, fresh_owner, status=409)
        consents = self.request("GET", consent_path + "s", fresh_owner).json()
        self.assertTrue(all(row["revoked_at"] and not row["scopes"] for row in consents))
        repeated = self.push(fresh_owner, [{**changes[1], "change_id": str(uuid.uuid4())}])[0]
        self.assertNotEqual(repeated["status"], "accepted")
        self.assertEqual(len(self.request("GET", "/api/v1/records", fresh_owner).json()), 2)
        print("实际 CLI：原始卷完全删除后由独立增量副本恢复；照片字节相同、删除记录/账号不复活、旧会话/邀请/全部共享失效", flush=True)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--serve":
        serve_fixture(int(sys.argv[2]))
    else:
        unittest.main()
