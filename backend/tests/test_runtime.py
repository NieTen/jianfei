import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from datetime import datetime, timezone
from pathlib import Path

import httpx


class RuntimeTests(unittest.TestCase):
    def test_real_http_restart_and_background_deletion(self):
        with tempfile.TemporaryDirectory() as directory:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            environment = dict(os.environ)
            environment.update(DATA_DIR=directory, BOOTSTRAP_CODE="runtime-test-enrollment",
                               AI_URL="", AI_KEY="", AI_MODEL="", AI_ALLOWED_HOSTS="provider.invalid",
                               APNS_KEY_FILE="", FOOD_API_KEY="", BACKUP_PASSWORD="")
            command = [sys.executable, "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1",
                       "--port", str(port), "--no-access-log", "--log-level", "error"]
            process = None
            with httpx.Client(base_url=f"http://127.0.0.1:{port}/api/v1", trust_env=False, timeout=5) as client:
                try:
                    process = subprocess.Popen(command, cwd=Path(__file__).parents[1], env=environment,
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    self.wait_ready(client, process)
                    device_id = str(uuid.uuid4())
                    account = client.post("/auth/register", json={
                        "username": "runtime_user", "password": "runtime-password-123", "display_name": "运行测试",
                        "device_id": device_id,
                    })
                    self.assertEqual(account.status_code, 200, account.text)
                    session = account.json()
                    client.headers["Authorization"] = "Bearer " + session["access_token"]
                    day = datetime.now(timezone.utc).date().isoformat()
                    value = client.post("/sync/push", json={
                        "epoch": session["epoch"], "generation": session["generation"], "changes": [{
                            "change_id": str(uuid.uuid4()), "entity_id": str(uuid.uuid4()), "kind": "weight",
                            "business_date": day, "base_version": 0,
                            "payload": {"measured_at": datetime.now(timezone.utc).isoformat(), "weight_kg": 71},
                        }],
                    })
                    self.assertEqual(value.json()["results"][0]["status"], "accepted")
                    configured = client.put("/ai/settings", json={
                        "base_url": "https://provider.invalid/v1/responses", "model": "test-vision",
                        "api_key": "runtime-test-key", "external": True,
                    })
                    self.assertEqual(configured.status_code, 200, configured.text)
                    process.terminate()
                    process.wait(timeout=15)
                    process = subprocess.Popen(command, cwd=Path(__file__).parents[1], env=environment,
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    self.wait_ready(client, process)
                    login = client.post("/auth/login", json={
                        "username": "runtime_user", "password": "runtime-password-123", "device_id": device_id,
                    })
                    self.assertEqual(login.status_code, 200, login.text)
                    self.assertEqual(login.json()["instance_id"], session["instance_id"])
                    client.headers["Authorization"] = "Bearer " + login.json()["access_token"]
                    self.assertEqual(len(client.get("/records").json()), 1)
                    saved = client.get("/ai/settings").json()
                    self.assertEqual(saved["model"], "test-vision")
                    self.assertTrue(saved["has_api_key"])
                    task_id, receipt = str(uuid.uuid4()), "r" * 64
                    deletion = client.request("DELETE", "/account/data", json={
                        "password": "runtime-password-123", "request_key": task_id, "receipt_secret": receipt,
                    })
                    self.assertEqual(deletion.status_code, 200, deletion.text)
                    deadline = time.monotonic() + 15
                    state = None
                    while time.monotonic() < deadline:
                        state = client.get("/data/deletions/" + task_id, headers={"X-Deletion-Receipt": receipt}).json()
                        if state["status"] in ("completed", "failed"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(state["status"], "completed", state)
                    self.assertEqual(client.get("/records").status_code, 401)
                finally:
                    if process and process.poll() is None:
                        process.terminate()
                        process.wait(timeout=15)

    def wait_ready(self, client, process):
        # QEMU 跨架构运行时导入依赖更慢，CI 可单独调整启动等待时间。
        deadline = time.monotonic() + float(os.getenv("BINGJIAN_TEST_STARTUP_TIMEOUT", "15"))
        while time.monotonic() < deadline:
            if process.poll() is not None:
                self.fail("后台进程在启动期间退出")
            try:
                response = client.get("/health")
                if response.status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            time.sleep(0.1)
        self.fail("后台启动超时")
