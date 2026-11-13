import secrets
import sqlite3
import uuid
from datetime import timedelta

from .errors import AppError
from .email_verification import EmailVerificationService, normalize_email
from .records import validate_actor
from .security import new_token, now_iso, password_hash, token_hash, utc_now, verify_password


class AuthService:
    def __init__(self, database, settings):
        self.db = database
        self.settings = settings
        self.email = EmailVerificationService(database, settings)
        self.dummy_password_hash = password_hash(new_token())

    def create_enrollment(self):
        code = new_token()
        with self.db.transaction() as repo:
            repo.insert("enrollments", {"code_hash": token_hash(code), "expires_at": (utc_now() + timedelta(hours=24)).isoformat()})
        return code

    def issue_session(self, repo, user, device_id, device_name, family_id=None, parent_id=None):
        device = repo.one("devices", {"id": device_id})
        if device and device["user_id"] != user["id"]:
            raise AppError("DEVICE_OWNER_CONFLICT", "设备标识已属于其他账号，请为当前账号注册新设备", 409)
        if device and device["revoked_at"]:
            raise AppError("DEVICE_REVOKED", "该设备已被撤销，请使用新的设备注册标识", 403)
        if device is None:
            repo.insert("devices", {
                "id": device_id, "user_id": user["id"], "name": device_name,
                "platform": "ios", "last_seen_at": now_iso(),
            })
        else:
            repo.update("devices", {"name": device_name, "last_seen_at": now_iso()}, {"id": device_id})
        access, refresh = new_token(), new_token()
        session_id = str(uuid.uuid4())
        repo.insert("sessions", {
            "id": session_id, "user_id": user["id"], "device_id": device_id,
            "access_hash": token_hash(access), "refresh_hash": token_hash(refresh),
            "access_expires_at": (utc_now() + timedelta(minutes=15)).isoformat(),
            "refresh_expires_at": (utc_now() + timedelta(days=30)).isoformat(),
            "generation": user["generation"],
            "family_id": family_id or session_id, "parent_id": parent_id,
        })
        return {
            "access_token": access, "refresh_token": refresh, "expires_in": 900,
            "user_id": user["id"], "display_name": user["display_name"], "device_id": device_id,
            "generation": user["generation"], "epoch": repo.setting("sync_epoch"),
            "instance_id": repo.setting("instance_id"),
        }

    def register(self, request):
        email = normalize_email(request.email) if request.email else None
        if self.settings.deployment_mode == "cloud" or email:
            if not email or not request.email_code:
                raise AppError("EMAIL_VERIFICATION_REQUIRED", "请先验证邮箱后注册", 403)
            self.email.consume(email, "register", request.email_code)
        if not request.username and self.settings.deployment_mode != "cloud":
            raise AppError("VALIDATION_FAILED", "请输入用户名", 422)
        recovery = new_token()
        user = {
            "id": str(uuid.uuid4()), "username": (request.username or "u_" + uuid.uuid4().hex).lower(),
            "display_name": request.display_name, "password_hash": password_hash(request.password),
            "recovery_hash": token_hash(recovery), "generation": 1, "status": "active", "created_at": now_iso(),
            "email": email, "email_verified_at": now_iso() if email else None,
        }
        try:
            with self.db.transaction() as repo:
                repo.insert("users", user)
                result = self.issue_session(repo, user, request.device_id, request.device_name)
                repo.audit(user["id"], "account_created", user["id"])
                result["recovery_code"] = recovery
                return result
        except sqlite3.IntegrityError:
            if email:
                raise AppError("ACCOUNT_UNAVAILABLE", "账号无法注册，请检查资料或使用找回密码", 409)
            raise AppError("USERNAME_EXISTS", "用户名已存在", 409)

    def login(self, request):
        login = request.username.strip().lower()
        self.limit_attempt(login, "login", 20)
        self.limit_attempt(request.device_id, "device_login", 60)
        with self.db.transaction() as repo:
            user = repo.one("users", {"email" if "@" in login else "username": login, "status": "active"})
            valid_password = verify_password(request.password, user["password_hash"] if user else self.dummy_password_hash)
            if not user or not valid_password:
                raise AppError("INVALID_CREDENTIALS", "用户名或密码错误", 401)
            repo.audit(user["id"], "login", request.device_id)
            return self.issue_session(repo, user, request.device_id, request.device_name)

    def limit_attempt(self, identity, action, maximum):
        key = token_hash(action + ":" + identity)
        exceeded = False
        with self.db.transaction() as repo:
            row = repo.one("auth_rate_limits", {"id": key})
            if row and row["expires_at"] > now_iso():
                exceeded = row["attempts"] >= maximum
                if not exceeded:
                    repo.update("auth_rate_limits", {"attempts": row["attempts"] + 1}, {"id": key})
            else:
                values = {"id": key, "attempts": 1, "expires_at": (utc_now() + timedelta(minutes=5)).isoformat()}
                if row:
                    repo.update("auth_rate_limits", values, {"id": key})
                else:
                    repo.insert("auth_rate_limits", values)
        if exceeded:
            raise AppError("ACCOUNT_RATE_LIMITED", "账号操作过于频繁，请稍后重试", 429)

    def authenticate(self, authorization):
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError("AUTH_REQUIRED", "请先登录", 401)
        with self.db.read() as repo:
            session = repo.one("sessions", {"access_hash": token_hash(authorization[7:]), "revoked_at": None})
            if not session or session["access_expires_at"] <= now_iso():
                raise AppError("AUTH_EXPIRED", "登录状态已过期，请刷新或重新登录", 401)
            user = repo.one("users", {"id": session["user_id"]})
            device = repo.one("devices", {"id": session["device_id"]})
            if not user or user["status"] != "active" or not device or device["revoked_at"]:
                raise AppError("DEVICE_REVOKED", "账号或设备已失效", 403)
            if session["generation"] != user["generation"]:
                raise AppError("GENERATION_CHANGED", "个人数据已重置，请重新登录并建立同步基线", 409)
            return {"user_id": user["id"], "device_id": device["id"], "generation": user["generation"], "session_id": session["id"]}

    def refresh(self, refresh_token):
        reused = False
        result = None
        with self.db.transaction() as repo:
            session = repo.one("sessions", {"refresh_hash": token_hash(refresh_token)})
            if not session or session["refresh_expires_at"] <= now_iso():
                raise AppError("AUTH_EXPIRED", "刷新凭据已过期，请重新登录", 401)
            if session["revoked_at"]:
                if session["revoked_reason"] == "rotated":
                    repo.update("sessions", {"revoked_at": now_iso(), "revoked_reason": "replay"}, {"family_id": session["family_id"]})
                    repo.audit(session["user_id"], "refresh_replay_detected", session["device_id"])
                    reused = True
                else:
                    raise AppError("AUTH_EXPIRED", "刷新凭据已失效，请重新登录", 401)
            else:
                user = repo.one("users", {"id": session["user_id"], "status": "active"})
                device = repo.one("devices", {"id": session["device_id"], "revoked_at": None})
                if not user or not device or user["generation"] != session["generation"]:
                    raise AppError("DEVICE_REVOKED", "设备或数据代际已变更，请重新登录", 403)
                repo.update("sessions", {"revoked_at": now_iso(), "revoked_reason": "rotated"}, {"id": session["id"]})
                result = self.issue_session(repo, user, device["id"], device["name"], session["family_id"], session["id"])
        if reused:
            raise AppError("AUTH_EXPIRED", "检测到刷新凭据重复使用，请重新登录", 401)
        return result

    def me(self, actor):
        with self.db.read() as repo:
            validate_actor(repo, actor)
            user = repo.one("users", {"id": actor["user_id"]})
            return {"user_id": user["id"], "username": user["username"], "display_name": user["display_name"],
                    "email": user["email"], "email_verified": bool(user["email_verified_at"]),
                    "deployment_mode": self.settings.deployment_mode}

    def require_password(self, repo, actor, password):
        validate_actor(repo, actor)
        user = repo.one("users", {"id": actor["user_id"], "status": "active"})
        if not user or not verify_password(password, user["password_hash"]):
            raise AppError("INVALID_CREDENTIALS", "请确认当前账号密码", 403)
        return user

    def reset_password(self, request):
        challenge = self.email.consume(request.email, "reset_password", request.email_code)
        with self.db.transaction() as repo:
            user = repo.one("users", {"id": challenge["user_id"], "email": challenge["email"], "status": "active"})
            if not user:
                raise AppError("INVALID_EMAIL_CODE", "验证码无效或已过期，请重新获取", 403)
            repo.update("users", {"password_hash": password_hash(request.new_password), "recovery_hash": token_hash(new_token())}, {"id": user["id"]})
            repo.update("sessions", {"revoked_at": now_iso(), "revoked_reason": "password_reset"}, {"user_id": user["id"]})
            repo.audit(user["id"], "password_reset")
        return {"updated": True}

    def change_password(self, actor, request):
        self.limit_attempt(actor["user_id"], "sensitive", 20)
        with self.db.transaction() as repo:
            user = self.require_password(repo, actor, request.current_password)
            repo.update("users", {"password_hash": password_hash(request.new_password), "recovery_hash": token_hash(new_token())}, {"id": user["id"]})
            repo.update("email_challenges", {"used_at": now_iso()}, {"user_id": user["id"], "used_at": None})
            repo.update("sessions", {"revoked_at": now_iso(), "revoked_reason": "password_changed"}, {"user_id": user["id"]})
            repo.audit(user["id"], "password_changed")
        return {"updated": True}

    def email_binding_code(self, actor, request):
        self.limit_attempt(actor["user_id"], "sensitive", 20)
        with self.db.read() as repo:
            self.require_password(repo, actor, request.current_password)
        return self.email.issue(request.email, "bind_email", actor["user_id"])

    def bind_email(self, actor, request):
        self.limit_attempt(actor["user_id"], "sensitive", 20)
        with self.db.read() as repo:
            self.require_password(repo, actor, request.current_password)
        challenge = self.email.consume(request.email, "bind_email", request.email_code, actor["user_id"])
        email = challenge["email"]
        try:
            with self.db.transaction() as repo:
                user = self.require_password(repo, actor, request.current_password)
                repo.update("users", {"email": email, "email_verified_at": now_iso()}, {"id": actor["user_id"]})
                repo.update("email_challenges", {"used_at": now_iso()}, {"user_id": actor["user_id"], "used_at": None})
                if user["email"]:
                    repo.update("email_challenges", {"used_at": now_iso()}, {"email": user["email"], "used_at": None})
                repo.update("sessions", {"revoked_at": now_iso(), "revoked_reason": "email_changed"},
                            {"user_id": actor["user_id"], "id__ne": actor["session_id"]})
                repo.audit(actor["user_id"], "email_changed")
        except sqlite3.IntegrityError:
            raise AppError("EMAIL_UNAVAILABLE", "无法绑定此邮箱，请核对或使用找回密码", 409)
        return self.me(actor)

    def logout_all(self, actor):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            repo.update("sessions", {"revoked_at": now_iso(), "revoked_reason": "logout_all"}, {"user_id": actor["user_id"]})
            repo.audit(actor["user_id"], "logout_all")
        return {"logged_out": True}

    def recover(self, request):
        self.limit_attempt(request.username.lower(), "recover", 20)
        with self.db.transaction() as repo:
            login = request.username.strip().lower()
            user = repo.one("users", {"email" if "@" in login else "username": login, "status": "active"})
            if not user or not secrets.compare_digest(token_hash(request.recovery_code), user["recovery_hash"]):
                raise AppError("INVALID_RECOVERY", "账号或恢复凭据错误", 403)
            recovery = new_token()
            repo.update("users", {"password_hash": password_hash(request.new_password), "recovery_hash": token_hash(recovery)}, {"id": user["id"]})
            repo.update("sessions", {"revoked_at": now_iso()}, {"user_id": user["id"]})
            repo.audit(user["id"], "credentials_recovered")
            return {"recovery_code": recovery}

    def list_devices(self, actor):
        with self.db.read() as repo:
            rows = repo.find("devices", {"user_id": actor["user_id"]}, order=["-last_seen_at"])
            return [{key: row[key] for key in ("id", "name", "platform", "revoked_at", "last_seen_at")} for row in rows]

    def logout(self, actor):
        with self.db.transaction() as repo:
            repo.update("sessions", {"revoked_at": now_iso()}, {"id": actor["session_id"], "user_id": actor["user_id"]})
            repo.audit(actor["user_id"], "logout", actor["device_id"])
        return {"logged_out": True}

    def revoke_device(self, actor, device_id):
        with self.db.transaction() as repo:
            device = repo.one("devices", {"id": device_id, "user_id": actor["user_id"]})
            if not device:
                raise AppError("NOT_FOUND", "设备不存在", 404)
            repo.update("devices", {"revoked_at": now_iso(), "push_token": None}, {"id": device_id})
            repo.update("sessions", {"revoked_at": now_iso()}, {"user_id": actor["user_id"], "device_id": device_id})
            repo.audit(actor["user_id"], "device_revoked", device_id)
        return {"revoked": True}

    def bind(self, actor, local_user_id):
        with self.db.transaction() as repo:
            binding = repo.one("bindings", {"user_id": actor["user_id"], "local_user_id": local_user_id})
            if binding is None:
                binding = {"id": str(uuid.uuid4()), "user_id": actor["user_id"], "local_user_id": local_user_id,
                           "device_id": actor["device_id"], "created_at": now_iso()}
                repo.insert("bindings", binding)
            return binding

    def push_registration(self, actor, request):
        with self.db.transaction() as repo:
            repo.update("devices", {"push_token": request.token if request.enabled else None,
                                     "push_enabled": int(request.enabled)}, {"id": actor["device_id"], "user_id": actor["user_id"]})
        return {"enabled": request.enabled}

