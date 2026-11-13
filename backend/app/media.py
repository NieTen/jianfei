import hashlib
import io
import json
import os
import threading
import uuid
import warnings
from datetime import datetime, timedelta
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from .errors import AppError
from .domain import day_window
from .records import validate_actor
from .security import now_iso, utc_now

Image.MAX_IMAGE_PIXELS = 20_000_000
warnings.simplefilter("error", Image.DecompressionBombWarning)


class MediaService:
    def __init__(self, database, settings):
        self.db = database
        self.settings = settings
        self.entitlements = None
        self.root = settings.data_dir / "media"
        self.temp = settings.data_dir / "tmp"
        self.lock = threading.RLock()

    def safe_id(self, media_id):
        try:
            return str(uuid.UUID(media_id))
        except (ValueError, TypeError):
            raise AppError("VALIDATION_FAILED", "照片标识格式无效")

    def path(self, media_id, thumbnail=False):
        return self.root / (self.safe_id(media_id) + (".thumb.jpg" if thumbnail else ".image"))

    def initialize(self, actor, request):
        media_id = self.safe_id(request.id)
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            if self.settings.deployment_mode == "cloud" and request.temporary:
                self.entitlements.check_consent(repo, actor["user_id"], request.provider_revision, request.consent_revision)
            meal = repo.one("entities", {"id": request.meal_id, "user_id": actor["user_id"]})
            if meal and meal["deleted_at"]:
                raise AppError("ENTITY_DELETED", "餐次已经删除", 409)
            existing = repo.one("media", {"id": media_id})
            if existing:
                if existing["user_id"] != actor["user_id"] or existing["expected_hash"] != request.sha256 or existing["meal_id"] != request.meal_id:
                    raise AppError("FORBIDDEN", "照片标识冲突", 409)
                if existing["status"] in ("deleted", "purged"):
                    raise AppError("ENTITY_DELETED", "照片已经删除", 409)
                if existing["status"] == "expired":
                    repo.update("media", {"status": "uploading", "received_size": 0, "temporary": int(request.temporary),
                                          "created_at": now_iso()}, {"id": media_id})
                    existing.update(status="uploading", received_size=0, temporary=int(request.temporary))
                elif existing["temporary"] and not request.temporary:
                    repo.update("media", {"temporary": 0}, {"id": media_id})
                    existing["temporary"] = 0
                if self.settings.deployment_mode == "cloud" and request.temporary:
                    revisions = {"consent_revision": request.consent_revision, "provider_revision": request.provider_revision}
                    repo.update("media", revisions, {"id": media_id})
                    existing.update(revisions)
                return existing
            value = {
                "id": media_id, "user_id": actor["user_id"], "meal_id": request.meal_id,
                "expected_size": request.size, "expected_hash": request.sha256, "received_size": 0,
                "mime_type": request.mime_type, "status": "uploading", "created_at": now_iso(),
                "temporary": int(request.temporary),
                "consent_revision": request.consent_revision, "provider_revision": request.provider_revision,
            }
            repo.insert("media", value)
            return value

    def upload(self, actor, media_id, offset, data):
        media_id = self.safe_id(media_id)
        if len(data) > 2 * 1024 * 1024:
            raise AppError("UPLOAD_TOO_LARGE", "每个上传分片最多 2MB", 413)
        with self.lock, self.db.transaction() as repo:
            validate_actor(repo, actor)
            media = repo.one("media", {"id": media_id, "user_id": actor["user_id"]})
            if not media:
                raise AppError("NOT_FOUND", "照片上传任务不存在", 404)
            if self.settings.deployment_mode == "cloud" and media["temporary"]:
                self.entitlements.check_consent(repo, actor["user_id"], media["provider_revision"], media["consent_revision"])
            if media["status"] == "ready":
                return media
            if media["status"] in ("deleted", "purged"):
                raise AppError("ENTITY_DELETED", "照片已删除", 409)
            partial = self.temp / (media_id + ".upload")
            actual = partial.stat().st_size if partial.exists() else 0
            # 文件与数据库无法共用事务，重试时以磁盘长度校正上传偏移。
            if offset != actual:
                return {**media, "received_size": actual, "retry_offset": actual}
            if actual + len(data) > media["expected_size"]:
                raise AppError("UPLOAD_TOO_LARGE", "上传内容超出声明大小", 413)
            with partial.open("ab") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            received = actual + len(data)
            if received == media["expected_size"]:
                digest = hashlib.sha256(partial.read_bytes()).hexdigest()
                if digest != media["expected_hash"]:
                    partial.unlink(missing_ok=True)
                    repo.update("media", {"received_size": 0}, {"id": media_id})
                    return {**media, "received_size": 0, "status": "hash_mismatch"}
                try:
                    self.validate_image(partial)
                    self.create_thumbnail(partial, media_id)
                except (UnidentifiedImageError, OSError, Image.DecompressionBombError, Image.DecompressionBombWarning):
                    partial.unlink(missing_ok=True)
                    raise AppError("INVALID_IMAGE", "图片格式无效或解码尺寸过大")
                partial.replace(self.path(media_id))
                repo.update("media", {"received_size": received, "status": "ready"}, {"id": media_id})
                return {**media, "received_size": received, "status": "ready"}
            repo.update("media", {"received_size": received}, {"id": media_id})
            return {**media, "received_size": received}

    def resolve(self, actor, media_id, challenge_id=None, thumbnail=False):
        with self.db.read() as repo:
            validate_actor(repo, actor)
            media = repo.one("media", {"id": self.safe_id(media_id), "status": "ready"})
            if not media:
                raise AppError("NOT_FOUND", "照片尚未上传或已删除", 404)
            if media["user_id"] != actor["user_id"]:
                consent = repo.one("consents", {"challenge_id": challenge_id, "owner_id": media["user_id"],
                                               "recipient_id": actor["user_id"], "revoked_at": None})
                viewer = repo.one("members", {"challenge_id": challenge_id, "user_id": actor["user_id"], "status": "active"})
                owner = repo.one("members", {"challenge_id": challenge_id, "user_id": media["user_id"], "status": "active"})
                if not consent or not viewer or not owner or "photos" not in json.loads(consent["scopes"]):
                    raise AppError("CONSENT_REVOKED", "没有读取这张照片的授权", 403)
                challenge = repo.one("challenges", {"id": challenge_id})
                if not challenge or not challenge["start_at"] or not challenge["end_at"] or utc_now() < datetime.fromisoformat(challenge["start_at"]):
                    raise AppError("FORBIDDEN", "挑战开始后才能查看授权照片", 403)
                meals = repo.find("entities", {"user_id": media["user_id"], "kind": "meal", "deleted_at": None,
                                               "business_date__gte": consent["history_from"]})
                visible_meals = [
                    meal for meal in meals
                    if datetime.fromisoformat(challenge["start_at"]) <=
                    day_window(meal["business_date"], challenge["timezone"], challenge["day_start_minutes"])[0] <
                    datetime.fromisoformat(challenge["end_at"])
                ]
                if not any(media_id in json.loads(meal["payload"]).get("photo_ids", []) for meal in visible_meals):
                    raise AppError("FORBIDDEN", "照片不在授权历史范围内", 403)
            result = self.path(media_id, thumbnail)
            if not result.exists():
                raise AppError("ATTACHMENT_PENDING", "照片文件暂不可用", 409, True)
            return result

    def validate_image(self, path):
        with Image.open(path) as source:
            source.verify()

    def create_thumbnail(self, source_path, media_id):
        with Image.open(source_path) as source:
            thumbnail = source.convert("RGB")
            thumbnail.thumbnail((480, 480))
            thumbnail.save(self.path(media_id, True), "JPEG", quality=80)

    def ai_image(self, user_id, media_id):
        with self.db.read() as repo:
            media = repo.one("media", {"id": self.safe_id(media_id), "user_id": user_id, "status": "ready"})
            if not media:
                raise AppError("ATTACHMENT_PENDING", "请先完成照片上传", 409, True)
        with Image.open(self.path(media_id)) as source:
            image = source.convert("RGB")
            image.thumbnail((2048, 2048))
            output = io.BytesIO()
            image.save(output, "JPEG", quality=85)
            return output.getvalue()

    def cleanup(self):
        with self.lock, self.db.transaction() as repo:
            temporary = repo.find("media", {"temporary": 1, "status__in": ["ready", "uploading"],
                                            "created_at__lt": (utc_now() - timedelta(hours=24)).isoformat()}, limit=200)
            for media in temporary:
                self.path(media["id"]).unlink(missing_ok=True)
                self.path(media["id"], True).unlink(missing_ok=True)
                (self.temp / (media["id"] + ".upload")).unlink(missing_ok=True)
                repo.update("media", {"status": "expired", "received_size": 0}, {"id": media["id"]})
            deleted = repo.find("media", {"status": "deleted"}, limit=200)
            for media in deleted:
                self.path(media["id"]).unlink(missing_ok=True)
                self.path(media["id"], True).unlink(missing_ok=True)
                (self.temp / (media["id"] + ".upload")).unlink(missing_ok=True)
                repo.update("media", {"status": "purged"}, {"id": media["id"]})

