import hashlib
import hmac
import base64
import json
import re
import secrets
import smtplib
import ssl
import uuid
from datetime import timedelta
from email.message import EmailMessage

from cryptography.fernet import Fernet

from .errors import AppError
from .security import load_secret, now_iso, utc_now


def normalize_email(value):
    value = (value or "").strip().lower()
    if len(value) > 254 or not re.fullmatch(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+", value):
        raise AppError("INVALID_EMAIL", "请输入有效邮箱地址", 422)
    return value


class EmailVerificationService:
    """验证码只通过邮件交付；测试可注入 sender，不把验证码写入响应或日志。"""

    def __init__(self, database, settings, sender=None):
        self.db, self.settings = database, settings
        self.secret = load_secret(settings.data_dir / "secrets" / "email.key")
        self.sender = sender or self.send_smtp
        self.cipher = Fernet(base64.urlsafe_b64encode(hashlib.sha256(self.secret.encode()).digest()))

    def digest(self, challenge_id, code):
        return hmac.new(self.secret.encode(), (challenge_id + ":" + code).encode(), hashlib.sha256).hexdigest()

    def send_smtp(self, email, code, purpose):
        if not self.settings.smtp_host or not self.settings.smtp_from:
            raise AppError("EMAIL_UNAVAILABLE", "邮箱服务尚未配置，请稍后重试", 503, True)
        message = EmailMessage()
        message["From"] = self.settings.smtp_from
        message["To"] = email
        message["Subject"] = "并肩账号验证码"
        message.set_content(f"你的并肩账号验证码为：{code}\n有效期 {self.settings.email_code_ttl_seconds // 60} 分钟。请勿将验证码提供给他人。若非本人操作，请忽略。")
        try:
            if self.settings.smtp_ssl:
                client = smtplib.SMTP_SSL(self.settings.smtp_host, self.settings.smtp_port, timeout=15,
                                          context=ssl.create_default_context())
            else:
                client = smtplib.SMTP(self.settings.smtp_host, self.settings.smtp_port, timeout=15)
            with client:
                if not self.settings.smtp_ssl:
                    if not self.settings.smtp_starttls:
                        raise AppError("EMAIL_UNAVAILABLE", "邮件服务必须启用 TLS", 503)
                    client.starttls(context=ssl.create_default_context())
                if self.settings.smtp_username:
                    client.login(self.settings.smtp_username, self.settings.smtp_password)
                client.send_message(message)
        except (OSError, smtplib.SMTPException) as error:
            raise AppError("EMAIL_UNAVAILABLE", "验证码暂未发送，请稍后重试", 503, True) from error

    def issue(self, email, purpose, user_id=None):
        email = normalize_email(email)
        if self.sender == self.send_smtp and (not self.settings.smtp_host or not self.settings.smtp_from):
            raise AppError("EMAIL_UNAVAILABLE", "邮箱服务尚未配置，请稍后重试", 503, True)
        now = utc_now()
        identifier, code = str(uuid.uuid4()), f"{secrets.randbelow(1000000):06d}"
        with self.db.transaction() as repo:
            recent = repo.find("email_challenges", {"email": email, "created_at__gte": (now - timedelta(hours=1)).isoformat()},
                               order=["-created_at"], limit=6)
            if len(recent) >= 5 or (recent and recent[0]["created_at"] > (now - timedelta(seconds=60)).isoformat()):
                raise AppError("EMAIL_RATE_LIMITED", "验证码发送过于频繁，请稍后重试", 429)
            user = repo.one("users", {"email": email, "status": "active"})
            deliver = (purpose == "register" and user is None) or (purpose == "reset_password" and user is not None) or (purpose == "bind_email" and (user is None or user["id"] == user_id))
            # 无对应账号的找回请求也记录相同限流状态，并返回相同响应。
            repo.update("email_challenges", {"used_at": now.isoformat()}, {"email": email, "purpose": purpose, "used_at": None})
            repo.insert("email_challenges", {"id": identifier, "user_id": user_id or (user["id"] if user else None),
                        "email": email, "purpose": purpose, "code_hash": self.digest(identifier, code),
                        "created_at": now.isoformat(), "expires_at": (now + timedelta(seconds=self.settings.email_code_ttl_seconds)).isoformat(),
                        "used_at": None if deliver else now.isoformat()})
            # 不存在的账号也经历相同的加密入队；SMTP 发送不影响 HTTP 状态与耗时。
            encrypted = self.cipher.encrypt(json.dumps({"email": email, "code": code, "purpose": purpose,
                                                       "deliver": deliver}).encode()).decode()
            repo.insert("email_deliveries", {"id": identifier, "challenge_id": identifier,
                        "encrypted_payload": encrypted, "status": "pending", "retry_at": now.isoformat(), "created_at": now.isoformat()})
        return {"sent": True, "expires_in": self.settings.email_code_ttl_seconds, "delivery_status": "queued"}

    def deliver_pending(self):
        with self.db.transaction() as repo:
            rows = repo.find("email_deliveries", {"status": "pending", "retry_at__lte": now_iso()}, order=["created_at"], limit=1)
            if not rows:
                return False
            delivery = rows[0]
            challenge = repo.one("email_challenges", {"id": delivery["challenge_id"]})
            if not challenge or challenge["used_at"] or challenge["expires_at"] <= now_iso():
                repo.update("email_deliveries", {"status": "expired", "encrypted_payload": ""}, {"id": delivery["id"]})
                return True
            repo.update("email_deliveries", {"status": "sending", "attempts": delivery["attempts"] + 1}, {"id": delivery["id"]})
        try:
            payload = json.loads(self.cipher.decrypt(delivery["encrypted_payload"].encode()))
            if payload["deliver"]:
                self.sender(payload["email"], payload["code"], payload["purpose"])
        except Exception:
            # 邮件失败不向发起者泄露账号存在性；有限重试且不记录邮箱或验证码。
            with self.db.transaction() as repo:
                retry = delivery["attempts"] < 2
                repo.update("email_deliveries", {"status": "pending" if retry else "failed",
                            "retry_at": (utc_now() + timedelta(seconds=30 * (delivery["attempts"] + 1))).isoformat(),
                            "encrypted_payload": delivery["encrypted_payload"] if retry else ""}, {"id": delivery["id"]})
        else:
            with self.db.transaction() as repo:
                repo.update("email_deliveries", {"status": "sent", "encrypted_payload": ""}, {"id": delivery["id"]})
        return True

    def consume(self, email, purpose, code, user_id=None):
        email = normalize_email(email)
        valid = False
        with self.db.transaction() as repo:
            rows = repo.find("email_challenges", {"email": email, "purpose": purpose}, order=["-created_at"], limit=1)
            challenge = rows[0] if rows else None
            if challenge and not challenge["used_at"] and challenge["expires_at"] > now_iso() and challenge["attempts"] < 5:
                matches_user = purpose != "bind_email" or challenge["user_id"] == user_id
                valid = matches_user and hmac.compare_digest(challenge["code_hash"], self.digest(challenge["id"], code or ""))
                # 无效尝试必须先提交，不能因随后抛错而被事务回滚。
                repo.update("email_challenges", {"attempts": challenge["attempts"] + 1,
                            "used_at": now_iso() if valid or challenge["attempts"] >= 4 else None}, {"id": challenge["id"]})
        if not valid:
            raise AppError("INVALID_EMAIL_CODE", "验证码无效或已过期，请重新获取", 403)
        return {"email": email, "user_id": challenge["user_id"], "challenge_id": challenge["id"]}
