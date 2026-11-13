import hashlib
import json
import uuid
from datetime import datetime, timezone

from .errors import AppError
from .records import validate_actor
from .security import now_iso, utc_now


class EntitlementService:
    def __init__(self, database, settings):
        self.db, self.settings = database, settings

    @property
    def cloud(self):
        return self.settings.deployment_mode == "cloud"

    def active_grants(self, repo, user_id):
        return repo.find("entitlement_grants", {"user_id": user_id, "entitlement_key": "ai_food_recognition",
                         "revoked_at": None, "valid_from__lte": now_iso(), "valid_until__gt": now_iso()})

    def require(self, repo, user_id):
        if not self.cloud:
            return
        user = repo.one("users", {"id": user_id, "status": "active"})
        if not user or not self.active_grants(repo, user_id):
            raise AppError("SVIP_REQUIRED", "AI 识图仅对有效 SVIP 开放，基础记录仍可使用", 403)

    def quota(self, repo, user_id):
        used = repo.ai_usage_count(user_id, utc_now().date().isoformat())
        maximum = self.settings.ai_daily_limit
        return {"daily_limit": maximum, "used": used, "remaining": max(0, maximum - used)}

    def public(self, actor):
        with self.db.read() as repo:
            validate_actor(repo, actor)
            grants = self.active_grants(repo, actor["user_id"])
            enabled = bool(grants) or not self.cloud
            revision = hashlib.sha256(json.dumps([(g["id"], g["valid_until"]) for g in grants], sort_keys=True).encode()).hexdigest()
            return {"tier": "private" if not self.cloud else "svip" if enabled else "basic",
                    "ai_food_recognition": enabled, "valid_until": max((g["valid_until"] for g in grants), default=None),
                    "revision": revision, "server_time": now_iso(), "quota": self.quota(repo, actor["user_id"]),
                    "reason": "" if enabled else "SVIP_REQUIRED"}

    def grant(self, user_id, valid_until, source="manual", source_ref=None, reason="人工开通", operator="cli"):
        try:
            expiration = datetime.fromisoformat(valid_until.replace("Z", "+00:00"))
            if expiration.tzinfo is None or expiration <= utc_now():
                raise ValueError()
        except ValueError:
            raise AppError("INVALID_EXPIRATION", "权益到期时间必须为含时区的未来时间")
        source_ref = source_ref or str(uuid.uuid4())
        with self.db.transaction() as repo:
            if not repo.one("users", {"id": user_id, "status": "active"}):
                raise AppError("NOT_FOUND", "账号不存在或不可用", 404)
            existing = repo.one("entitlement_grants", {"source": source, "source_ref": source_ref})
            if existing:
                if existing["user_id"] != user_id or existing["valid_until"] != expiration.astimezone(timezone.utc).isoformat():
                    raise AppError("IDEMPOTENCY_CONFLICT", "授权来源凭据已经用于其他授权", 409)
                return existing
            grant = {"id": str(uuid.uuid4()), "user_id": user_id, "entitlement_key": "ai_food_recognition",
                     "valid_from": now_iso(), "valid_until": expiration.astimezone(timezone.utc).isoformat(),
                     "source": source, "source_ref": source_ref, "reason": reason, "created_at": now_iso()}
            repo.insert("entitlement_grants", grant)
            repo.insert("entitlement_events", {"id": str(uuid.uuid4()), "user_id": user_id, "grant_id": grant["id"],
                        "action": "grant", "operator": operator, "reason": reason, "created_at": now_iso()})
            return grant

    def revoke(self, grant_id, reason, operator="cli"):
        with self.db.transaction() as repo:
            grant = repo.one("entitlement_grants", {"id": grant_id})
            if not grant:
                raise AppError("NOT_FOUND", "权益授权不存在", 404)
            if not grant["revoked_at"]:
                repo.update("entitlement_grants", {"revoked_at": now_iso(), "reason": reason}, {"id": grant_id})
                repo.insert("entitlement_events", {"id": str(uuid.uuid4()), "user_id": grant["user_id"], "grant_id": grant_id,
                            "action": "revoke", "operator": operator, "reason": reason, "created_at": now_iso()})
            if not self.active_grants(repo, grant["user_id"]):
                self.cancel_pending(repo, grant["user_id"], "SVIP 权益已撤销")
        return {"revoked": True, "grant_id": grant_id}

    def check_consent(self, repo, user_id, provider_revision, consent_revision):
        if not self.cloud:
            return
        self.require(repo, user_id)
        provider = repo.one("cloud_ai_provider", {"id": "platform", "enabled": 1})
        if not provider:
            raise AppError("AI_UNAVAILABLE", "平台 AI 服务暂不可用", 503, True)
        if provider_revision != provider["revision"]:
            raise AppError("PROVIDER_CHANGED", "AI 提供方配置已更新，请重新确认", 409)
        consent = repo.one("cloud_ai_consents", {"user_id": user_id})
        if not consent or not consent["allowed"]:
            raise AppError("AI_CONSENT_REQUIRED", "请先明确同意当前 AI 服务处理所选照片", 403)
        if consent["revision"] != consent_revision or consent["provider_revision"] != provider_revision:
            raise AppError("AI_CONSENT_CHANGED", "照片处理授权已变化，请重新确认", 403)

    def reserve(self, repo, user_id, task_id, request_key):
        if not self.cloud:
            return
        self.require(repo, user_id)
        if self.quota(repo, user_id)["remaining"] < 1:
            raise AppError("AI_QUOTA_EXCEEDED", "今日 AI 识图额度已用完，请于 UTC 次日重试", 429)
        repo.insert("ai_usage", {"task_id": task_id, "user_id": user_id, "request_key": request_key,
                    "usage_day": utc_now().date().isoformat(), "status": "reserved", "created_at": now_iso(), "updated_at": now_iso()})

    def provider_started(self, repo, task_id):
        usage = repo.one("ai_usage", {"task_id": task_id})
        if usage:
            repo.update("ai_usage", {"status": "submitted", "provider_calls": usage["provider_calls"] + 1,
                        "updated_at": now_iso()}, {"task_id": task_id})

    def settle(self, repo, task_id, completed=False):
        usage = repo.one("ai_usage", {"task_id": task_id})
        if usage:
            # 请求已经发出时不能声称没有发生费用；失败/超时仍占一次额度。
            status = "completed" if completed else "unknown" if usage["provider_calls"] else "released"
            repo.update("ai_usage", {"status": status, "updated_at": now_iso()}, {"task_id": task_id})

    def cancel_pending(self, repo, user_id, message):
        for task in repo.find("tasks", {"user_id": user_id, "kind": "recognition", "status__in": ["pending", "running", "unknown"]}):
            payload = json.loads(task["payload"])
            payload.pop("_provider_snapshot", None)
            repo.update("tasks", {"status": "cancelled", "payload": json.dumps(payload), "error": message,
                        "updated_at": now_iso()}, {"id": task["id"]})
            self.settle(repo, task["id"])

    def freeze_after_restore(self):
        """旧整库备份不能复活已撤销权益、验证码或曾同意的外部处理。"""
        if not self.cloud:
            return
        with self.db.transaction() as repo:
            while True:
                grants = repo.find("entitlement_grants", {"revoked_at": None}, limit=200)
                if not grants:
                    break
                for grant in grants:
                    reason = "云端整库恢复后待管理员核验"
                    repo.update("entitlement_grants", {"revoked_at": now_iso(), "reason": reason}, {"id": grant["id"]})
                    repo.insert("entitlement_events", {"id": str(uuid.uuid4()), "user_id": grant["user_id"],
                                "grant_id": grant["id"], "action": "restore_freeze", "operator": "cli:restore",
                                "reason": reason, "created_at": now_iso()})
            repo.update("cloud_ai_consents", {"allowed": 0, "updated_at": now_iso()}, {"allowed": 1})
            repo.update("email_challenges", {"used_at": now_iso()}, {"used_at": None})
            repo.update("email_deliveries", {"status": "cancelled", "encrypted_payload": ""}, {"status__in": ["pending", "sending"]})
            while True:
                tasks = repo.find("tasks", {"kind": "recognition", "status__in": ["pending", "running", "unknown"]}, limit=200)
                if not tasks:
                    break
                for task in tasks:
                    payload = json.loads(task["payload"])
                    payload.pop("_provider_snapshot", None)
                    repo.update("tasks", {"status": "cancelled", "payload": json.dumps(payload),
                                "error": "云端恢复后需重新核验授权并提交识别", "updated_at": now_iso()}, {"id": task["id"]})
                    self.settle(repo, task["id"])
