"""显式启用的真实 TCP/SMTP 云账号验收；全部服务与数据仅位于本机临时目录。"""
import email
import hashlib
import io
import json
import os
import re
import shutil
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from email import policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
from PIL import Image


class CaptureSMTPHandler(socketserver.StreamRequestHandler):
    """只接收邮件并放入内存，不具备外发或转投能力。"""
    def handle(self):
        self.wfile.write(b"220 localhost synthetic SMTP ready\r\n")
        while line := self.rfile.readline():
            command = line.decode("ascii", errors="replace").strip().upper()
            if command.startswith(("EHLO", "HELO")):
                self.wfile.write(b"250 localhost\r\n")
            elif command.startswith(("MAIL FROM:", "RCPT TO:", "RSET", "NOOP")):
                self.wfile.write(b"250 OK\r\n")
            elif command == "DATA":
                self.wfile.write(b"354 End with dot\r\n")
                parts = []
                while data := self.rfile.readline():
                    if data == b".\r\n":
                        break
                    parts.append(data[1:] if data.startswith(b"..") else data)
                message = email.message_from_bytes(b"".join(parts), policy=policy.default)
                with self.server.lock:
                    self.server.messages.append(message)
                self.wfile.write(b"250 Captured locally\r\n")
            elif command == "QUIT":
                self.wfile.write(b"221 Bye\r\n")
                return
            else:
                self.wfile.write(b"502 Unsupported\r\n")


class CaptureSMTPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def get_request(self):
        connection, address = super().get_request()
        return self.tls.wrap_socket(connection, server_side=True), address


class LocalResponsesHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.server.lock:
            self.server.calls.append({"path": self.path, "key": self.headers.get("Idempotency-Key"),
                                      "authorized": self.headers.get("Authorization") == "Bearer synthetic-provider-key",
                                      "model": body.get("model"), "has_input": bool(body.get("input"))})
            incomplete = self.server.always_incomplete or not self.headers.get("Idempotency-Key", "").endswith(":nutrition")
        item = {"name": "虚构米饭", "estimated_weight_g": 100, "calories_kcal": 120,
                "protein_g": None if incomplete else 3, "carbs_g": 25, "fat_g": 1}
        result = {"status": "completed", "model": "synthetic-vision", "output": [{"type": "message", "content": [
            {"type": "output_text", "text": json.dumps({"items": [item]}, ensure_ascii=False)}]}]}
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


@unittest.skipUnless(os.getenv("BINGJIAN_RUN_LIVE_ACCEPTANCE") == "1", "真实 SMTP/TCP 验收需显式启用")
class CloudRuntimeAcceptanceTests(unittest.TestCase):
    def setUp(self):
        if not shutil.which("openssl"):
            self.skipTest("需要 openssl 创建仅供本机验收使用的 TLS 证书")
        self.backend = Path(__file__).resolve().parents[1]
        self.output = Path(os.getenv("BINGJIAN_ACCEPTANCE_OUTPUT", str(self.backend.parent / "build/全流程验收/账号识图")))
        self.output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="isolated-", dir=self.output)
        self.addCleanup(self.temporary.cleanup)
        directory = Path(self.temporary.name)
        certificate, key = directory / "localhost.pem", directory / "localhost.key"
        config = directory / "certificate.cnf"
        config.write_text("[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n", encoding="utf-8")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", str(config),
                        "-keyout", str(key), "-out", str(certificate)], check=True, capture_output=True)
        self.smtp = CaptureSMTPServer(("127.0.0.1", 0), CaptureSMTPHandler)
        self.smtp.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.smtp.tls.load_cert_chain(certificate, key)
        self.smtp.messages, self.smtp.lock = [], threading.Lock()
        self.provider = ThreadingHTTPServer(("127.0.0.1", 0), LocalResponsesHandler)
        provider_tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        provider_tls.load_cert_chain(certificate, key)
        self.provider.socket = provider_tls.wrap_socket(self.provider.socket, server_side=True)
        self.provider.calls, self.provider.lock, self.provider.always_incomplete = [], threading.Lock(), False
        for server in (self.smtp, self.provider):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.environment = dict(os.environ)
        self.environment.update(DATA_DIR=str(directory / "data"), DEPLOYMENT_MODE="cloud", CLOUD_ALLOW_HTTP="true",
            PUBLIC_URL=f"http://127.0.0.1:{port}", AI_URL="", AI_KEY="", AI_MODEL="", AI_ALLOWED_HOSTS="127.0.0.1",
            AI_DAILY_LIMIT="2", BACKUP_PASSWORD="", BACKUP_REPLICA_DIR="", BACKUP_REPLICA_REQUIRED="false",
            APNS_KEY_FILE="", FOOD_API_KEY="", SMTP_HOST="localhost", SMTP_PORT=str(self.smtp.server_address[1]),
            SMTP_SSL="true", SMTP_STARTTLS="false", SMTP_USERNAME="", SMTP_PASSWORD="", SMTP_FROM="local-test@example.invalid",
            SSL_CERT_FILE=str(certificate), NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
        self.server_log = (self.output / "server.log").open("w", encoding="utf-8")
        self.addCleanup(self.server_log.close)
        # 产品禁用代理环境变量；因此只为这个子进程替换 certifi 根证书路径。
        # HTTPS 仍执行主机名与证书链验证，不改变系统信任、不关闭 verify、不替换网络传输。
        bootstrap = "import certifi,sys; certifi.where=lambda:sys.argv[1]; import uvicorn; uvicorn.run('app.main:app',host='127.0.0.1',port=int(sys.argv[2]),access_log=False,log_level='warning')"
        self.process = subprocess.Popen([sys.executable, "-c", bootstrap, str(certificate), str(port)], cwd=self.backend, env=self.environment,
                                        stdout=self.server_log, stderr=self.server_log)
        self.addCleanup(self.stop_backend)
        self.client = httpx.Client(base_url=f"http://127.0.0.1:{port}/api/v1", trust_env=False, timeout=10)
        self.addCleanup(self.client.close)
        self.wait_for(lambda: self.ready(), 20, "后端启动")
        self.code_sent_at = {}
        self.progress("隔离云服务、真实 TLS SMTP 捕获与本机 Responses 提供方均已启动")

    def stop_backend(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=15)

    def ready(self):
        self.assertIsNone(self.process.poll(), "后端提前退出，请检查 server.log")
        try:
            return self.client.get("/health").status_code == 200
        except httpx.HTTPError:
            return False

    def progress(self, message):
        print(datetime.now(timezone.utc).isoformat(timespec="seconds") + " " + message, flush=True)

    def wait_for(self, predicate, seconds, description):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.1)
        self.fail(description + "超时")

    def request(self, method, path, session=None, status=200, code=None, **kwargs):
        headers = kwargs.pop("headers", {})
        if session:
            headers["Authorization"] = "Bearer " + session["access_token"]
        response = self.client.request(method, path, headers=headers, **kwargs)
        body = response.json()
        self.assertEqual(response.status_code, status, f"{method} {path}: {response.status_code}, code={body.get('code') if isinstance(body, dict) else 'list'}")
        if code:
            self.assertEqual(body.get("code"), code)
        return body

    def mail_code(self, address, path="/auth/email-code", payload=None, session=None, wait_cooldown=False):
        if wait_cooldown:
            remaining = self.code_sent_at.get(address, 0) + 61 - time.monotonic()
            if remaining > 0:
                self.progress("等待真实邮箱发送冷却期后继续账号验收")
                time.sleep(remaining)
        with self.smtp.lock:
            start = len(self.smtp.messages)
        result = self.request("POST", path, session, json=payload or {"email": address, "purpose": "register"})
        self.assertEqual(set(result), {"sent", "expires_in", "delivery_status"})
        self.assertEqual(result["delivery_status"], "queued")
        self.code_sent_at[address] = time.monotonic()
        def received():
            with self.smtp.lock:
                for message in self.smtp.messages[start:]:
                    if message["To"] == address:
                        match = re.search(r"验证码为：(\d{6})", message.get_content())
                        return match.group(1) if match else None
            return None
        return self.wait_for(received, 15, "SMTP 邮件投递")

    def register(self, address):
        code = self.mail_code(address)
        session = self.request("POST", "/auth/register", json={"email": address, "email_code": code, "password": "synthetic-password-123",
            "display_name": "虚构验收账号", "device_id": str(uuid.uuid4()), "cloud_rules_version": "1"})
        return session, code

    def cli(self, *args, input=None):
        result = subprocess.run([sys.executable, "-m", "app.cli", *args], cwd=self.backend, env=self.environment,
                                input=input, text=True, capture_output=True, timeout=20)
        if result.returncode:
            # 只保存本机虚构服务诊断；口令从未进入命令行或正常日志。
            diagnostic = result.stderr.replace("synthetic-provider-key", "[fixture-key]")
            (self.output / "cli-error.log").write_text(diagnostic, encoding="utf-8")
        self.assertEqual(result.returncode, 0, "CLI 执行失败：" + args[0])
        return json.loads(result.stdout)

    def task(self, session, identifier):
        def finished():
            value = self.request("GET", "/ai/tasks/" + identifier, session)
            return value if value["status"] in ("completed", "failed", "cancelled", "unknown") else None
        return self.wait_for(finished, 20, "AI 后台任务")

    def test_live_cloud_account_ai_and_account_security_flow(self):
        self.assertEqual(self.request("GET", "/app/config")["deployment_mode"], "cloud")
        self.request("POST", "/auth/register", status=403, code="EMAIL_VERIFICATION_REQUIRED", json={
            "email": "owner@example.invalid", "password": "synthetic-password-123", "display_name": "未验证", "device_id": str(uuid.uuid4())})
        owner, used_code = self.register("owner@example.invalid")
        self.request("POST", "/auth/register", status=403, code="INVALID_EMAIL_CODE", json={"email": "owner@example.invalid", "email_code": used_code,
            "password": "synthetic-password-123", "display_name": "重复注册", "device_id": str(uuid.uuid4())})
        self.request("POST", "/auth/login", status=401, code="INVALID_CREDENTIALS", json={"username": "owner@example.invalid", "password": "wrong",
            "device_id": owner["device_id"]})
        second = self.request("POST", "/auth/login", json={"username": "owner@example.invalid", "password": "synthetic-password-123", "device_id": str(uuid.uuid4())})
        self.assertTrue(self.request("GET", "/me", owner)["email_verified"])
        self.assertFalse(self.request("GET", "/me/entitlements", owner)["ai_food_recognition"])
        self.progress("邮箱 SMTP 验证注册、一次性码、正常登录与错误密码拒绝通过")

        photo_id, meal_id = str(uuid.uuid4()), str(uuid.uuid4())
        image = io.BytesIO()
        Image.new("RGB", (32, 32), "#317456").save(image, format="JPEG")
        photo = image.getvalue()
        media = {"id": photo_id, "meal_id": meal_id, "size": len(photo), "sha256": hashlib.sha256(photo).hexdigest(), "temporary": False}
        self.request("POST", "/media/upload-init", owner, json=media)
        self.request("PUT", "/media/" + photo_id, owner, content=photo)
        day, measured = datetime.now(timezone.utc).date().isoformat(), datetime.now(timezone.utc).isoformat()
        changes = [{"change_id": str(uuid.uuid4()), "entity_id": str(uuid.uuid4()), "kind": "weight", "business_date": day, "base_version": 0,
                    "payload": {"measured_at": measured, "weight_kg": 70.25}},
                   {"change_id": str(uuid.uuid4()), "entity_id": meal_id, "kind": "meal", "business_date": day, "base_version": 0,
                    "payload": {"eaten_at": measured, "photo_ids": [photo_id], "note": "虚构午餐"}}]
        saved = self.request("POST", "/sync/push", owner, json={"epoch": owner["epoch"], "generation": owner["generation"], "changes": changes})
        self.assertTrue(all(row["status"] == "accepted" for row in saved["results"]))
        self.assertEqual(len(self.request("GET", "/records", owner)), 2)
        request = {"request_key": str(uuid.uuid4()), "meal_id": meal_id, "meal_version": 1, "photo_ids": [photo_id], "note": "虚构午餐", "allow_external": True}
        for path in ("/ai/models", "/ai/settings", "/me/ai-preferences"):
            self.request("GET", path, owner, status=403, code="SVIP_REQUIRED")
        self.request("POST", "/ai/food-recognition", owner, status=403, code="SVIP_REQUIRED", json=request)
        self.request("POST", "/media/upload-init", owner, status=403, code="SVIP_REQUIRED", json=media | {"id": str(uuid.uuid4()), "temporary": True})
        self.assertEqual(len(self.provider.calls), 0)
        self.progress("基础体重/餐次/照片正常保存；基础账号 AI 入口与临时上传拒绝且无提供方请求")

        self.cli("ai-configure", "--url", f"https://127.0.0.1:{self.provider.server_address[1]}/v1", "--models", "synthetic-vision,synthetic-alt", "--name", "本机验收提供方", input="synthetic-provider-key\n")
        status = self.cli("status")
        self.assertTrue(status["ai_configured"])
        self.assertEqual(status["ai_configuration_source"], "platform")
        until = (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat()
        grant = self.cli("svip-grant", "--user", owner["user_id"], "--until", until, "--reference", "acceptance-original")
        repeated = self.cli("svip-grant", "--user", owner["user_id"], "--until", until, "--reference", "acceptance-original")
        self.assertEqual(grant["id"], repeated["id"])
        self.assertTrue(self.request("GET", "/me/entitlements", owner)["ai_food_recognition"])
        preferences = self.request("GET", "/me/ai-preferences", owner)
        self.assertNotIn("synthetic-provider-key", json.dumps(preferences))
        self.request("PUT", "/me/ai-preferences", owner, json={"model_id": "synthetic-vision"})
        consent = self.request("GET", "/me/ai-consent", owner)
        request.update(consent_revision=consent["revision"], provider_revision=consent["provider_revision"])
        self.request("POST", "/ai/food-recognition", owner, status=403, code="AI_CONSENT_REQUIRED", json=request)
        consent = self.request("PUT", "/me/ai-consent", owner, json={"allowed": True, "provider_revision": consent["provider_revision"], "expected_revision": consent["revision"]})
        request.update(consent_revision=consent["revision"])
        task = self.request("POST", "/ai/food-recognition", owner, json=request)
        finished = self.task(owner, task["id"])
        self.assertEqual(finished["status"], "completed", finished.get("error"))
        self.assertEqual(finished["result"]["items"][0]["basis_protein_g"], 3)
        self.assertTrue(finished["result"]["needs_user_confirmation"])
        self.assertEqual(len(self.provider.calls), 2)
        self.assertTrue(all(call["authorized"] and call["path"] == "/v1/responses" and call["has_input"] for call in self.provider.calls))
        self.assertEqual(self.provider.calls[1]["key"], self.provider.calls[0]["key"] + ":nutrition")
        self.assertEqual(self.request("POST", "/ai/food-recognition", owner, json=request)["id"], task["id"])
        self.assertEqual(self.request("GET", "/me/entitlements", owner)["quota"]["used"], 1)
        self.assertEqual(len(self.provider.calls), 2)
        self.progress("CLI 平台配置与 SVIP 幂等开通通过；真实 Responses HTTP 两次完成营养补全，重复提交只计一次额度")

        reader, _ = self.register("reader@example.invalid")
        self.request("GET", "/ai/tasks/" + task["id"], reader, status=404, code="NOT_FOUND")
        self.request("PUT", "/me/ai-consent", owner, json={"allowed": False, "provider_revision": 0})
        self.request("POST", "/ai/food-recognition", owner, status=403, code="AI_CONSENT_REQUIRED", json=request | {"request_key": str(uuid.uuid4())})
        latest = self.request("GET", "/me/ai-consent", owner)
        self.request("PUT", "/me/ai-consent", owner, status=409, code="AI_CONSENT_CHANGED", json={"allowed": True,
            "provider_revision": latest["provider_revision"], "expected_revision": consent["revision"]})
        consent = self.request("PUT", "/me/ai-consent", owner, json={"allowed": True, "provider_revision": latest["provider_revision"], "expected_revision": latest["revision"]})
        self.provider.always_incomplete = True
        failing = self.request("POST", "/ai/food-recognition", owner, json=request | {"request_key": str(uuid.uuid4()), "consent_revision": consent["revision"]})
        failed = self.task(owner, failing["id"])
        self.assertEqual(failed["status"], "failed")
        self.assertIn("营养", failed["error"])
        self.assertEqual(len(self.provider.calls), 4)
        self.request("POST", "/ai/food-recognition", owner, status=429, code="AI_QUOTA_EXCEEDED", json=request | {"request_key": str(uuid.uuid4()), "consent_revision": consent["revision"]})
        expires = (datetime.now(timezone.utc) + timedelta(seconds=4)).isoformat()
        self.cli("svip-grant", "--user", owner["user_id"], "--until", expires, "--source", "acceptance-secondary")
        self.cli("svip-revoke", grant["id"], "--reason", "虚构验收撤销第一来源")
        self.assertTrue(self.request("GET", "/me/entitlements", owner)["ai_food_recognition"])
        self.wait_for(lambda: not self.request("GET", "/me/entitlements", owner)["ai_food_recognition"], 8, "权益自然到期")
        self.request("POST", "/ai/food-recognition", owner, status=403, code="SVIP_REQUIRED", json=request | {"request_key": str(uuid.uuid4())})
        self.assertTrue(self.request("GET", "/ai/tasks/" + task["id"], owner)["result_withheld"])
        self.assertEqual(len(self.provider.calls), 4)
        self.assertEqual(len(self.request("GET", "/records", owner)), 2)
        self.progress("跨账号读取拒绝、同意撤回、迟到同意拒绝、补全失败说明、额度上限、多来源撤权与自然到期通过")

        changed = "changed@example.invalid"
        code = self.mail_code(changed, "/me/email-code", {"email": changed, "current_password": "synthetic-password-123"}, owner)
        self.request("PUT", "/me/email", owner, json={"email": changed, "email_code": code, "current_password": "synthetic-password-123"})
        self.request("GET", "/me", second, status=401, code="AUTH_EXPIRED")
        self.request("POST", "/auth/login", status=401, code="INVALID_CREDENTIALS", json={"username": "owner@example.invalid", "password": "synthetic-password-123", "device_id": owner["device_id"]})
        second = self.request("POST", "/auth/login", json={"username": changed, "password": "synthetic-password-123", "device_id": second["device_id"]})
        self.request("POST", "/auth/logout-all", owner)
        for session in (owner, second):
            self.request("GET", "/me", session, status=401, code="AUTH_EXPIRED")
        owner = self.request("POST", "/auth/login", json={"username": changed, "password": "synthetic-password-123", "device_id": owner["device_id"]})
        self.request("POST", "/me/password", owner, json={"current_password": "synthetic-password-123", "new_password": "changed-password-123"})
        self.request("GET", "/me", owner, status=401, code="AUTH_EXPIRED")
        owner = self.request("POST", "/auth/login", json={"username": changed, "password": "changed-password-123", "device_id": owner["device_id"]})
        self.progress("更换验证邮箱、旧邮箱停用、其他会话撤销、全端退出与修改密码通过")

        code = self.mail_code(changed, payload={"email": changed, "purpose": "reset_password"}, wait_cooldown=True)
        wrong = ("0" if code[0] != "0" else "1") + code[1:]
        self.request("POST", "/auth/reset-password", status=403, code="INVALID_EMAIL_CODE", json={"email": changed, "email_code": wrong, "new_password": "reset-password-123"})
        reset = {"email": changed, "email_code": code, "new_password": "reset-password-123"}
        self.request("POST", "/auth/reset-password", json=reset)
        self.request("POST", "/auth/reset-password", status=403, code="INVALID_EMAIL_CODE", json=reset)
        self.request("GET", "/me", owner, status=401, code="AUTH_EXPIRED")
        owner = self.request("POST", "/auth/login", json={"username": changed, "password": "reset-password-123", "device_id": owner["device_id"]})
        self.request("POST", "/auth/revoke-device", owner, json={"device_id": owner["device_id"]})
        self.request("POST", "/auth/login", status=403, code="DEVICE_REVOKED", json={"username": changed, "password": "reset-password-123", "device_id": owner["device_id"]})
        self.progress("真实 SMTP 找回密码、错误码/复用拒绝及设备撤销后的普通登录拒绝通过")
        recovery = {"username": changed, "password": "reset-password-123", "previous_device_id": owner["device_id"]}
        code = self.mail_code(changed, "/auth/device-recovery-code", recovery, wait_cooldown=True)
        recovered = self.request("POST", "/auth/recover-device", json=recovery | {"email_code": code, "device_id": str(uuid.uuid4())})
        self.assertEqual(recovered["user_id"], owner["user_id"])
        self.assertEqual(len(self.request("GET", "/records", recovered)), 2)
        self.assertFalse(self.request("GET", "/me/entitlements", recovered)["ai_food_recognition"])
        self.request("POST", "/auth/login", status=403, code="DEVICE_REVOKED", json={"username": changed, "password": "reset-password-123", "device_id": owner["device_id"]})
        deletion_id, receipt = str(uuid.uuid4()), "synthetic-deletion-receipt-" + uuid.uuid4().hex
        self.request("DELETE", "/account", recovered, json={"request_key": deletion_id, "receipt_secret": receipt, "password": "reset-password-123"})
        def deleted():
            result = self.request("GET", "/data/deletions/" + deletion_id, headers={"X-Deletion-Receipt": receipt})
            return result if result["status"] in ("completed", "failed") else None
        self.assertEqual(self.wait_for(deleted, 15, "账号后台删除")["status"], "completed")
        self.request("GET", "/me", recovered, status=401, code="AUTH_EXPIRED")
        self.assertEqual(self.request("GET", "/me", reader)["user_id"], reader["user_id"])
        self.assertEqual(len(self.provider.calls), 4)
        self.progress("邮箱二次验证设备恢复、原设备继续失效、记录保留、后台注销与其他账号隔离通过")
        summary = {"result": "passed", "smtp_messages": len(self.smtp.messages), "provider_requests": len(self.provider.calls),
                   "external_mail": 0, "real_ai_requests": 0, "transport": "真实 HTTP API + HTTPS Responses + TLS SMTP，仅绑定 127.0.0.1"}
        (self.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
