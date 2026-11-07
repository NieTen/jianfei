import secrets
import sqlite3
import uuid
from datetime import timedelta

from .errors import AppError
from .security import new_token, now_iso, password_hash, token_hash, utc_now, verify_password


class AuthService:
    def __init__(self, database, settings):
        self.db = database
        self.settings = settings

    def create_enrollment(self):
        code = new_token()
        with self.db.transaction() as repo:
            repo.insert("enrollments", {"code_hash": token_hash(code), "expires_at": (utc_now() + timedelta(hours=24)).isoformat()})
        return code

    def issue_session(self, repo, user, device_id, device_name):
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
        repo.insert("sessions", {
            "id": str(uuid.uuid4()), "user_id": user["id"], "device_id": device_id,
            "access_hash": token_hash(access), "refresh_hash": token_hash(refresh),
            "access_expires_at": (utc_now() + timedelta(minutes=15)).isoformat(),
            "refresh_expires_at": (utc_now() + timedelta(days=30)).isoformat(),
            "generation": user["generation"],
        })
        return {
            "access_token": access, "refresh_token": refresh, "expires_in": 900,
            "user_id": user["id"], "display_name": user["display_name"], "device_id": device_id,
            "generation": user["generation"], "epoch": repo.setting("sync_epoch"),
            "instance_id": repo.setting("instance_id"),
        }

    def register(self, request):
        recovery = new_token()
        user = {
            "id": str(uuid.uuid4()), "username": request.username.lower(),
            "display_name": request.display_name, "password_hash": password_hash(request.password),
            "recovery_hash": token_hash(recovery), "generation": 1, "status": "active", "created_at": now_iso(),
        }
        try:
            with self.db.transaction() as repo:
                repo.insert("users", user)
                result = self.issue_session(repo, user, request.device_id, request.device_name)
                repo.audit(user["id"], "account_created", user["id"])
                result["recovery_code"] = recovery
                return result
        except sqlite3.IntegrityError:
            raise AppError("USERNAME_EXISTS", "用户名已存在", 409)

    def login(self, request):
        with self.db.transaction() as repo:
            user = repo.one("users", {"username": request.username.lower(), "status": "active"})
            if not user or not verify_password(request.password, user["password_hash"]):
                raise AppError("INVALID_CREDENTIALS", "用户名或密码错误", 401)
            repo.audit(user["id"], "login", request.device_id)
            return self.issue_session(repo, user, request.device_id, request.device_name)

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
        with self.db.transaction() as repo:
            session = repo.one("sessions", {"refresh_hash": token_hash(refresh_token), "revoked_at": None})
            if not session or session["refresh_expires_at"] <= now_iso():
                raise AppError("AUTH_EXPIRED", "刷新凭据已过期，请重新登录", 401)
            user = repo.one("users", {"id": session["user_id"], "status": "active"})
            device = repo.one("devices", {"id": session["device_id"], "revoked_at": None})
            if not user or not device or user["generation"] != session["generation"]:
                raise AppError("DEVICE_REVOKED", "设备或数据代际已变更，请重新登录", 403)
            repo.update("sessions", {"revoked_at": now_iso()}, {"id": session["id"]})
            return self.issue_session(repo, user, device["id"], device["name"])

    def recover(self, request):
        with self.db.transaction() as repo:
            user = repo.one("users", {"username": request.username.lower(), "status": "active"})
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

