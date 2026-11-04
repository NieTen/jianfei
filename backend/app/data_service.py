import csv
import hashlib
import io
import json
import shutil
import uuid
from cryptography.exceptions import InvalidTag
from datetime import timedelta
from pathlib import Path

from .archive import decrypt_file, encrypt_file, file_hash, read_frames, write_frame
from .errors import AppError
from .models import KIND_MODELS
from .records import decoded_entity, validate_actor
from .security import now_iso, utc_now, verify_password


class DataService:
    def __init__(self, database, settings, records, media):
        self.db = database
        self.settings = settings
        self.records = records
        self.media = media

    def create_export(self, actor, request):
        # 密码只用于加密导出任务参数，避免数据库内保存明文导出密码。
        from cryptography.fernet import Fernet
        from .security import load_secret
        import base64
        key = hashlib.sha256(load_secret(self.settings.data_dir / "secrets" / "tasks.key").encode()).digest()
        cipher = Fernet(base64.urlsafe_b64encode(key))
        payload = request.model_dump()
        payload["password"] = cipher.encrypt(payload["password"].encode()).decode()
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            old = repo.one("tasks", {"user_id": actor["user_id"], "kind": "export", "request_key": request.request_key})
            if old:
                return {"id": old["id"], "status": old["status"]}
            task_id = str(uuid.uuid4())
            repo.insert("tasks", {"id": task_id, "user_id": actor["user_id"], "kind": "export",
                                  "request_key": request.request_key, "status": "pending",
                                  "payload": json.dumps(payload), "created_at": now_iso(), "updated_at": now_iso()})
            repo.audit(actor["user_id"], "export_requested", task_id)
            return {"id": task_id, "status": "pending"}

    def export(self, task):
        from cryptography.fernet import Fernet
        from .security import load_secret
        import base64
        request = json.loads(task["payload"])
        key = hashlib.sha256(load_secret(self.settings.data_dir / "secrets" / "tasks.key").encode()).digest()
        password = Fernet(base64.urlsafe_b64encode(key)).decrypt(request["password"].encode()).decode()
        plain_path = self.settings.data_dir / "tmp" / (task["id"] + ".plain")
        final_path = self.settings.data_dir / "exports" / (task["id"] + ".bjar")
        snapshot_id = str(uuid.uuid4())
        with self.db.transaction() as repo:
            user = repo.one("users", {"id": task["user_id"], "status": "active"})
            if not user:
                raise AppError("ACCOUNT_DELETED", "账号已注销", 409)
            repo.insert("snapshots", {"id": snapshot_id, "user_id": user["id"], "generation": user["generation"],
                                      "epoch": repo.setting("sync_epoch"), "sequence": repo.max_sequence(user["id"]),
                                      "expires_at": (utc_now() + timedelta(hours=2)).isoformat()})
            repo.copy_snapshot(snapshot_id, user["id"])
        try:
            with plain_path.open("wb") as output:
                metadata = json.dumps({"schema_version": 1, "user_id": task["user_id"], "exported_at": now_iso(),
                                       "includes_photos": request["include_photos"]}, ensure_ascii=False).encode()
                write_frame(output, {"type": "manifest", "length": len(metadata)}, metadata)
                after, photo_ids = "", set()
                while True:
                    with self.db.read() as repo:
                        rows = repo.find("snapshot_rows", {"snapshot_id": snapshot_id, "entity_id__gt": after},
                                         order=["entity_id"], limit=200)
                    if not rows:
                        break
                    for row in rows:
                        entity = json.loads(row["payload"])
                        if entity["deleted_at"]:
                            continue
                        raw = row["payload"].encode("utf-8")
                        write_frame(output, {"type": "entity", "length": len(raw)}, raw)
                        if entity["kind"] == "meal":
                            photo_ids.update(entity["payload"].get("photo_ids", []))
                    after = rows[-1]["entity_id"]
                if request["include_photos"]:
                    for photo_id in sorted(photo_ids):
                        with self.db.read() as repo:
                            media = repo.one("media", {"id": photo_id, "user_id": task["user_id"], "status": "ready"})
                        if not media or not self.media.path(photo_id).exists():
                            raise AppError("ATTACHMENT_PENDING", "部分照片尚未上传，完成上传后再导出", 409, True)
                        path = self.media.path(photo_id)
                        write_frame(output, {"type": "photo", "id": photo_id, "meal_id": media["meal_id"],
                                             "length": path.stat().st_size, "sha256": file_hash(path)}, path)
                write_frame(output, {"type": "end", "length": 0}, b"")
            if request["format"] == "csv":
                final_path = self.settings.data_dir / "exports" / (task["id"] + ".csv")
                with final_path.open("w", encoding="utf-8-sig", newline="") as output:
                    writer = csv.writer(output)
                    writer.writerow(["记录标识", "类型", "统计日期", "更新时间", "记录内容"])
                    for metadata, data in read_frames(plain_path):
                        if metadata["type"] == "entity":
                            entity = json.loads(data)
                            writer.writerow([entity["id"], entity["kind"], entity["business_date"], entity["updated_at"],
                                             json.dumps(entity["payload"], ensure_ascii=False)])
            else:
                encrypt_file(plain_path, final_path, password)
            return {"filename": final_path.name, "expires_at": (utc_now() + timedelta(hours=24)).isoformat(),
                    "sha256": file_hash(final_path), "format": request["format"]}
        finally:
            plain_path.unlink(missing_ok=True)
            with self.db.transaction() as repo:
                repo.delete("snapshots", {"id": snapshot_id})

    def download(self, actor, task_id):
        with self.db.read() as repo:
            validate_actor(repo, actor)
            task = repo.one("tasks", {"id": task_id, "user_id": actor["user_id"], "kind": "export", "status": "completed"})
            if not task or not task["result"]:
                raise AppError("NOT_FOUND", "导出文件尚未生成", 404)
            result = json.loads(task["result"])
            if result["expires_at"] <= now_iso():
                raise AppError("EXPORT_EXPIRED", "导出文件已过期，请重新生成", 410)
            path = self.settings.data_dir / "exports" / Path(result["filename"]).name
            if not path.exists():
                raise AppError("NOT_FOUND", "导出文件已清理", 404)
            return path

    def import_archive(self, actor, encrypted_path, password, mode="preview"):
        plain_path = self.settings.data_dir / "tmp" / (str(uuid.uuid4()) + ".import")
        photo_staging = self.settings.data_dir / "tmp" / str(uuid.uuid4())
        photo_staging.mkdir()
        try:
            decrypt_file(encrypted_path, plain_path, password)
            entities, photos, manifest = [], [], None
            for metadata, raw in read_frames(plain_path):
                if metadata["type"] == "manifest":
                    manifest = json.loads(raw)
                    if manifest.get("schema_version") != 1:
                        raise AppError("UNSUPPORTED_ARCHIVE", "归档版本不受支持")
                elif metadata["type"] == "entity":
                    entity = json.loads(raw)
                    if entity["kind"] not in KIND_MODELS:
                        raise AppError("VALIDATION_FAILED", "归档包含未知记录类型")
                    entity["payload"] = KIND_MODELS[entity["kind"]].model_validate(entity["payload"]).model_dump()
                    entities.append(entity)
                elif metadata["type"] == "photo":
                    photo_id = self.media.safe_id(metadata["id"])
                    if hashlib.sha256(raw).hexdigest() != metadata["sha256"]:
                        raise AppError("INVALID_ARCHIVE", "归档图片校验失败")
                    (photo_staging / photo_id).write_bytes(raw)
                    self.media.validate_image(photo_staging / photo_id)
                    photos.append(metadata)
            if manifest is None:
                raise AppError("INVALID_ARCHIVE", "归档缺少清单")
            preview = {"new": 0, "identical": 0, "conflicts": [], "deleted": [], "photos": len(photos)}
            with self.db.read() as repo:
                validate_actor(repo, actor)
                for entity in entities:
                    old = repo.one("entities", {"user_id": actor["user_id"], "id": entity["id"]})
                    ledger = repo.one("entity_ledger", {"user_id": actor["user_id"], "entity_id": entity["id"],
                                                       "generation": actor["generation"]})
                    if ledger and ledger["deleted"]:
                        preview["deleted"].append(entity["id"])
                    elif old and json.loads(old["payload"]) != entity["payload"]:
                        preview["conflicts"].append(entity["id"])
                    elif old:
                        preview["identical"] += 1
                    else:
                        preview["new"] += 1
            if mode == "preview":
                return preview
            if mode not in ("keep_local", "use_archive"):
                raise AppError("VALIDATION_FAILED", "请选择冲突处理方式")
            if preview["deleted"]:
                raise AppError("DELETED_RECORDS_PRESENT", "归档包含已删除记录，请在客户端选择以新记录恢复", 409, details=preview)
            from .models import Mutation
            with self.media.lock, self.db.transaction() as repo:
                validate_actor(repo, actor)
                for photo in photos:
                    old_media = repo.one("media", {"id": photo["id"]})
                    if old_media and old_media["user_id"] != actor["user_id"]:
                        raise AppError("FORBIDDEN", "图片标识属于另一账号", 409)
                    if old_media and old_media["expected_hash"] != photo["sha256"]:
                        raise AppError("PHOTO_CONFLICT", "相同照片标识的内容不一致", 409)
                    target = self.media.path(photo["id"])
                    if target.exists() and file_hash(target) != photo["sha256"]:
                        raise AppError("PHOTO_CONFLICT", "本地照片内容与恢复包不一致", 409)
                for entity in entities:
                    old = repo.one("entities", {"user_id": actor["user_id"], "id": entity["id"]})
                    if old and mode == "keep_local":
                        continue
                    mutation = Mutation(change_id=str(uuid.uuid4()), entity_id=entity["id"], kind=entity["kind"],
                                        business_date=entity["business_date"], source_id=entity.get("source_id"),
                                        base_version=old["version"] if old else 0, payload=entity["payload"])
                    result = self.records.apply_change(repo, actor, mutation)
                    if result["status"] == "conflict":
                        raise AppError("VERSION_CONFLICT", "导入来源存在冲突，请先处理", 409)
                for photo in photos:
                    target = self.media.path(photo["id"])
                    if not target.exists():
                        shutil.copyfile(photo_staging / photo["id"], target)
                    self.media.create_thumbnail(target, photo["id"])
                    if not repo.one("media", {"id": photo["id"]}):
                        repo.insert("media", {"id": photo["id"], "user_id": actor["user_id"], "meal_id": photo["meal_id"],
                                              "expected_size": photo["length"], "expected_hash": photo["sha256"],
                                              "received_size": photo["length"], "mime_type": "image/jpeg",
                                              "status": "ready", "created_at": now_iso()})
                repo.audit(actor["user_id"], "data_imported")
            return {**preview, "imported": True}
        except (InvalidTag, ValueError, KeyError, TypeError) as error:
            raise AppError("INVALID_ARCHIVE", "归档密码或内容校验失败", 400) from error
        finally:
            plain_path.unlink(missing_ok=True)
            shutil.rmtree(photo_staging, ignore_errors=True)

    def delete_data(self, actor, request, delete_account=False):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            user = repo.one("users", {"id": actor["user_id"]})
            if not verify_password(request.password, user["password_hash"]):
                raise AppError("INVALID_CREDENTIALS", "请确认当前账号密码", 403)
            old = repo.one("tasks", {"user_id": actor["user_id"], "kind": "delete", "request_key": request.request_key})
            if old:
                return {"id": old["id"], "status": old["status"]}
            task_id = str(uuid.uuid4())
            from .security import new_token, token_hash
            receipt = request.receipt_secret or new_token()
            if request.receipt_secret:
                try:
                    task_id = str(uuid.UUID(request.request_key))
                except ValueError:
                    raise AppError("VALIDATION_FAILED", "提供删除回执时，请求标识必须为 UUID")
            repo.insert("tasks", {"id": task_id, "user_id": actor["user_id"], "kind": "delete",
                                  "status": "pending", "request_key": request.request_key,
                                  "payload": json.dumps({"delete_account": delete_account, "receipt_hash": token_hash(receipt)}),
                                  "created_at": now_iso(), "updated_at": now_iso()})
            repo.update("users", {"generation": user["generation"] + 1,
                                  "status": "deleting" if delete_account else "resetting"}, {"id": user["id"]})
            repo.update("sessions", {"revoked_at": now_iso()}, {"user_id": user["id"]})
            for task in repo.find("tasks", {"user_id": user["id"], "kind": "recognition",
                                            "status__in": ["pending", "running", "unknown"]}):
                payload = json.loads(task["payload"])
                payload.pop("_provider_snapshot", None)
                repo.update("tasks", {"status": "cancelled", "payload": json.dumps(payload),
                                      "updated_at": now_iso()}, {"id": task["id"]})
            repo.update("consents", {"scopes": "[]", "revoked_at": now_iso(), "updated_at": now_iso()}, {"owner_id": user["id"]})
            repo.update("consents", {"scopes": "[]", "revoked_at": now_iso(), "updated_at": now_iso()}, {"recipient_id": user["id"]})
            repo.insert("deletion_ledger", {"id": str(uuid.uuid4()), "user_id": user["id"],
                                           "action": "account" if delete_account else "all_data",
                                           "target_id": str(user["generation"] + 1), "created_at": now_iso()})
            repo.audit(user["id"], "deletion_requested", task_id)
            return {"id": task_id, "status": "pending", "receipt": receipt}

    def deletion_status(self, task_id, receipt):
        from .security import token_hash
        import secrets
        with self.db.read() as repo:
            task = repo.one("tasks", {"id": task_id, "kind": "delete"})
            if not task or not secrets.compare_digest(token_hash(receipt), json.loads(task["payload"])["receipt_hash"]):
                raise AppError("FORBIDDEN", "删除回执无效", 403)
            return {"id": task["id"], "status": task["status"], "error": task["error"], "updated_at": task["updated_at"]}

    def process_delete(self, task):
        user_id = task["user_id"]
        with self.media.lock, self.db.transaction() as repo:
            media_rows = repo.find("media", {"user_id": user_id}, limit=1_000_000)
            for media in media_rows:
                self.media.path(media["id"]).unlink(missing_ok=True)
                self.media.path(media["id"], True).unlink(missing_ok=True)
                (self.settings.data_dir / "tmp" / (media["id"] + ".upload")).unlink(missing_ok=True)
            export_tasks = repo.find("tasks", {"user_id": user_id, "kind": "export"})
            for export in export_tasks:
                (self.settings.data_dir / "exports" / (export["id"] + ".bjar")).unlink(missing_ok=True)
                (self.settings.data_dir / "exports" / (export["id"] + ".csv")).unlink(missing_ok=True)
            memberships = repo.find("members", {"user_id": user_id})
            for member in memberships:
                repo.update("challenges", {"status": "ended_early", "finalized_at": now_iso()}, {"id": member["challenge_id"]})
                repo.update("consents", {"scopes": "[]", "revoked_at": now_iso(), "updated_at": now_iso()},
                            {"challenge_id": member["challenge_id"]})
                repo.delete("active_members", {"challenge_id": member["challenge_id"]})
            for table in ("entities", "changes", "receipts", "entity_ledger", "media", "snapshots", "scores", "score_events", "notifications", "ai_settings"):
                repo.delete(table, {"user_id": user_id})
            repo.delete("encouragements", {"sender_id": user_id})
            repo.update("members", {"goal": "{}", "baseline": None, "status": "left"}, {"user_id": user_id})
            repo.delete("tasks", {"user_id": user_id, "id__ne": task["id"]})
            if json.loads(task["payload"])["delete_account"]:
                repo.update("users", {"status": "deleted", "display_name": "已注销用户",
                                      "password_hash": "", "recovery_hash": ""}, {"id": user_id})
                repo.update("devices", {"revoked_at": now_iso(), "push_token": None}, {"user_id": user_id})
            else:
                repo.update("users", {"status": "active"}, {"id": user_id})
        return {"deleted": True, "backup_retention_days": 30}

