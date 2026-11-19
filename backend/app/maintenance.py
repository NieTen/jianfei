import hashlib
import json
import os
import re
import shutil
import sqlite3
import time
import uuid
from datetime import timedelta
from pathlib import Path

from .archive import CHUNK_SIZE, decrypt_file, derive_key, encrypt_file, file_hash, read_frames, write_frame
from .errors import AppError
from .security import load_secret, now_iso, utc_now

BACKUP_SECRETS = ("providers.key", "tasks.key", "cursor.key", "bootstrap.code", "backup.key")


class MaintenanceService:
    def __init__(self, database, settings, media):
        self.db = database
        self.settings = settings
        self.media = media
        self.ledger_path = settings.data_dir / "db" / "deletion-ledger.json"
        self.last_backup_cleanup = 0

    def persist_ledger(self):
        with self.db.write_lock:
            with self.db.read() as repo:
                rows = repo.find("deletion_ledger", order=["created_at"], limit=1_000_000)
            events = {row["id"]: row for row in self.deletion_events(include_replica=False) + rows}
            temporary = self.ledger_path.with_suffix(".tmp")
            with temporary.open("w", encoding="utf-8") as handle:
                json.dump(list(events.values()), handle, ensure_ascii=False)
                handle.flush()
                os.fsync(handle.fileno())
            temporary.replace(self.ledger_path)

    def deletion_events(self, include_replica=True):
        saved = json.loads(self.ledger_path.read_text(encoding="utf-8")) if self.ledger_path.exists() else []
        rows = saved + self.db.deletion_journal.read()
        # 日常本地备份独立于远端挂载。灾难恢复必须合并异地账本，读取失败便停止恢复。
        if include_replica:
            rows.extend(self.db.deletion_journal.read_replica())
        events = {row["id"]: row for row in rows}
        return sorted(events.values(), key=lambda row: (row["created_at"], row["id"]))

    def backup(self, password=None, incremental=True, task_id=None):
        password = password or self.settings.backup_password
        if not password or len(password) < 10:
            raise AppError("BACKUP_PASSWORD_REQUIRED", "请配置至少 10 位的独立备份密码")
        if task_id:
            with self.db.read() as repo:
                task = repo.one("tasks", {"id": task_id, "kind": "backup"})
            previous = json.loads(task["payload"]).get("verified_local_backup") if task else None
            if previous:
                source = self.settings.data_dir / "backups" / Path(previous["filename"]).name
                if not source.is_file() or file_hash(source) != previous["sha256"]:
                    raise AppError("BACKUP_LOCAL_MISSING", "待重传的已验证备份不可用，请检查磁盘后手动重新备份")
                references = json.loads(source.with_suffix(".refs.json").read_text(encoding="utf-8"))
                self.replicate_backup(source, references, password)
                previous["replica"] = {"configured": True, "verified": True, "completed_at": now_iso()}
                with self.db.transaction() as repo:
                    repo.update("settings", {"value": json.dumps(previous)}, {"key": "last_backup"})
                return previous
        identifier = str(uuid.uuid4())
        work = self.settings.data_dir / "tmp" / ("backup-" + identifier)
        work.mkdir()
        output = self.settings.data_dir / "backups" / (utc_now().strftime("%Y%m%dT%H%M%S") + "-" + identifier + ".bjar")
        pending = output.with_suffix(".pending")
        try:
            with self.media.lock, self.db.write_lock:
                self.db.maintenance = True
                self.persist_ledger()
                self.db.backup(work / "app.sqlite3")
                salt = load_secret(self.settings.data_dir / "secrets" / "backup.key").encode()[:16]
                namespace = derive_key(password, salt).hex()[:32]
                paths = [(work / "app.sqlite3", "db/app.sqlite3")]
                paths += [(path, "media/" + path.name) for path in self.media.root.glob("*") if path.is_file()]
                paths += [(path, "secrets/" + path.name) for path in (self.settings.data_dir / "secrets").glob("*")
                          if path.is_file() and path.name in BACKUP_SECRETS]
                files = [{"name": name, "size": path.stat().st_size, "sha256": file_hash(path)} for path, name in paths]
                hashes = {item["name"]: item["sha256"] for item in files}
                references = []
                plain = work / "backup.plain"
                with plain.open("wb") as writer:
                    manifest = json.dumps({"schema_version": 1, "created_at": now_iso(), "files": files,
                                           "deletion_ledger_id": self.db.deletion_journal.replica_id,
                                           "media_mode": "incremental" if incremental else "full"}, ensure_ascii=False).encode()
                    write_frame(writer, {"type": "backup_manifest", "length": len(manifest)}, manifest)
                    for path, name in paths:
                        if incremental and name.startswith("media/"):
                            reference = namespace + "/" + hashes[name] + ".bjar"
                            target = output.parent / "objects" / reference
                            if not target.exists():
                                target.parent.mkdir(parents=True, exist_ok=True)
                                temporary = target.with_suffix(".pending")
                                encrypt_file(path, temporary, password)
                                temporary.replace(target)
                            write_frame(writer, {"type": "backup_object", "name": name,
                                                 "object": reference, "length": 0}, b"")
                            references.append(reference)
                            continue
                        offset = 0
                        with path.open("rb") as reader:
                            while chunk := reader.read(CHUNK_SIZE):
                                write_frame(writer, {"type": "backup_file", "name": name, "offset": offset, "length": len(chunk)}, chunk)
                                offset += len(chunk)
                    write_frame(writer, {"type": "end", "length": 0}, b"")
                encrypt_file(plain, pending, password)
                # 在隔离目录中解密并执行完整性检查，确认备份可恢复。
                validation = work / "validation"
                self.unpack_backup(pending, password, validation)
                index = output.with_suffix(".refs.json")
                index.write_text(json.dumps(references), encoding="utf-8")
                pending.replace(output)
                # 副本复制只读取已完成的加密文件，远端 I/O 不占用业务库维护窗口。
                self.db.maintenance = False
            result = {"filename": output.name, "completed_at": now_iso(), "sha256": file_hash(output), "restore_verified": True,
                      "media_mode": "incremental" if incremental else "full", "referenced_objects": len(set(references))}
            if task_id and self.settings.backup_replica_dir:
                with self.db.transaction(allow_maintenance=True) as repo:
                    task = repo.one("tasks", {"id": task_id, "kind": "backup"})
                    payload = json.loads(task["payload"])
                    payload["verified_local_backup"] = result
                    repo.update("tasks", {"payload": json.dumps(payload)}, {"id": task_id, "kind": "backup"})
            replica = {"configured": bool(self.settings.backup_replica_dir), "verified": False}
            if self.settings.backup_replica_dir:
                try:
                    self.replicate_backup(output, references, password)
                    replica.update(verified=True, completed_at=now_iso())
                except Exception:
                    replica["error"] = "异地副本未校验成功，请检查挂载、空间和备份密码"
            with self.db.transaction(allow_maintenance=True) as repo:
                value = json.dumps({**result, "replica": replica})
                if repo.setting("last_backup"):
                    repo.update("settings", {"value": value}, {"key": "last_backup"})
                else:
                    repo.insert("settings", {"key": "last_backup", "value": value})
            if self.settings.backup_replica_required and not replica["verified"]:
                raise AppError("BACKUP_REPLICA_FAILED", "本机备份已保存，但必需异地副本失败，任务将重试", 503, True)
            return json.loads(value)
        finally:
            self.db.maintenance = False
            pending.unlink(missing_ok=True)
            shutil.rmtree(work, ignore_errors=True)

    @staticmethod
    def copy_verified(source, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".pending")
        try:
            with source.open("rb") as reader, temporary.open("wb") as writer:
                shutil.copyfileobj(reader, writer, CHUNK_SIZE)
                writer.flush()
                os.fsync(writer.fileno())
            if file_hash(source) != file_hash(temporary):
                raise ValueError("副本校验失败")
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)

    def replicate_backup(self, source, references, password):
        root = Path(self.settings.backup_replica_dir)
        if not root.is_dir() or not self.db.deletion_journal.replica_path.is_file():
            raise ValueError("异地目录或独立账本不可用")
        self.db.deletion_journal.verify_replica_header()
        destination = root / "backups"
        destination.mkdir(exist_ok=True)
        for reference in set(references):
            original = source.parent / "objects" / reference
            copied = destination / "objects" / reference
            if not copied.is_file() or file_hash(copied) != file_hash(original):
                self.copy_verified(original, copied)
        self.copy_verified(source.with_suffix(".refs.json"), destination / source.with_suffix(".refs.json").name)
        self.copy_verified(source, destination / source.name)
        validation = self.settings.data_dir / "tmp" / ("replica-check-" + str(uuid.uuid4()))
        try:
            self.unpack_backup(destination / source.name, password, validation)
            status = {"filename": source.name, "sha256": file_hash(source), "verified_at": now_iso()}
            temporary = root / "latest.json.pending"
            with temporary.open("w", encoding="utf-8") as handle:
                json.dump(status, handle)
                handle.flush()
                os.fsync(handle.fileno())
            temporary.replace(root / "latest.json")
            self.cleanup_backup_directory(destination)
        finally:
            shutil.rmtree(validation, ignore_errors=True)

    def unpack_backup(self, encrypted, password, destination, object_directory=None):
        destination.mkdir(parents=True, exist_ok=True)
        plain = destination / "archive.plain"
        decrypt_file(encrypted, plain, password)
        manifest = None
        try:
            for metadata, data in read_frames(plain):
                if metadata["type"] == "backup_manifest":
                    manifest = json.loads(data)
                elif metadata["type"] in ("backup_file", "backup_object"):
                    name = metadata["name"]
                    permitted_secret = name in ("secrets/" + value for value in BACKUP_SECRETS)
                    if name != "db/app.sqlite3" and not permitted_secret and not (name.startswith("media/") and Path(name).name == name[6:]):
                        raise ValueError("备份包含不允许的路径")
                    target = (destination / name).resolve()
                    if destination.resolve() not in target.parents:
                        raise ValueError("备份路径越界")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if metadata["type"] == "backup_object":
                        reference = metadata["object"]
                        if not name.startswith("media/") or not re.fullmatch(r"[a-f0-9]{32}/[a-f0-9]{64}\.bjar", reference):
                            raise ValueError("备份附件引用无效")
                        root = Path(object_directory) if object_directory else Path(encrypted).parent / "objects"
                        source = root / reference
                        if not source.is_file():
                            raise ValueError("缺少增量附件，请同时复制 objects 目录或指定 --objects 路径")
                        decrypt_file(source, target, password)
                        continue
                    actual = target.stat().st_size if target.exists() else 0
                    if actual != metadata["offset"]:
                        raise ValueError("备份文件分片顺序错误")
                    with target.open("ab") as handle:
                        handle.write(data)
            if not manifest or manifest.get("schema_version") != 1:
                raise ValueError("备份清单无效")
            for item in manifest["files"]:
                target = (destination / item["name"]).resolve()
                if destination.resolve() not in target.parents or not target.is_file():
                    raise ValueError("备份文件缺失")
                if target.stat().st_size != item["size"] or file_hash(target) != item["sha256"]:
                    raise ValueError("备份文件校验失败")
            connection = sqlite3.connect(destination / "db" / "app.sqlite3")
            try:
                if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise ValueError("备份数据库完整性检查失败")
            finally:
                connection.close()
            return manifest
        finally:
            plain.unlink(missing_ok=True)

    def cleanup(self):
        now = now_iso()
        if time.monotonic() - self.last_backup_cleanup > 3600:
            self.cleanup_backups()
            self.last_backup_cleanup = time.monotonic()
        with self.db.transaction() as repo:
            repo.delete("snapshots", {"expires_at__lt": now})
            repo.delete("auth_rate_limits", {"expires_at__lt": now})
            repo.delete("email_challenges", {"expires_at__lt": (utc_now() - timedelta(days=1)).isoformat()})
            exports = repo.find("tasks", {"kind": "export", "status": "completed"})
            for task in exports:
                result = json.loads(task["result"] or "{}")
                if result.get("expires_at", now) < now:
                    filename = Path(result.get("filename", "")).name
                    if filename:
                        (self.settings.data_dir / "exports" / filename).unlink(missing_ok=True)
                    repo.update("tasks", {"status": "expired", "payload": "{}", "updated_at": now}, {"id": task["id"]})
            users = repo.find("users", {"status": "active"})
            cutoff = (utc_now() - timedelta(days=90)).isoformat()
            for user in users:
                old = repo.find("changes", {"user_id": user["id"], "created_at__lt": cutoff}, order=["-sequence"], limit=1)
                if old:
                    key = "minimum_cursor:" + user["id"]
                    value = str(old[0]["sequence"])
                    if repo.setting(key):
                        repo.update("settings", {"value": value}, {"key": key})
                    else:
                        repo.insert("settings", {"key": key, "value": value})
                    repo.delete("changes", {"user_id": user["id"], "sequence__lte": old[0]["sequence"]})

    def cleanup_backups(self):
        with self.db.write_lock:
            self.cleanup_backup_directory(self.settings.data_dir / "backups")

    @staticmethod
    def cleanup_backup_directory(directory):
        if directory.is_dir():
            threshold = (utc_now() - timedelta(days=30)).timestamp()
            retained = set()
            complete_index = True
            for path in directory.glob("*.bjar"):
                index = path.with_suffix(".refs.json")
                if path.stat().st_mtime < threshold:
                    path.unlink(missing_ok=True)
                    index.unlink(missing_ok=True)
                elif index.is_file():
                    retained.update(json.loads(index.read_text(encoding="utf-8")))
                else:
                    # 缺失引用索引时保留对象，避免误删其他有效备份的依赖。
                    complete_index = False
            if complete_index:
                orphan_cutoff = (utc_now() - timedelta(days=1)).timestamp()
                objects = directory / "objects"
                for path in objects.glob("*/*.bjar"):
                    if path.relative_to(objects).as_posix() not in retained and path.stat().st_mtime < orphan_cutoff:
                        path.unlink(missing_ok=True)

