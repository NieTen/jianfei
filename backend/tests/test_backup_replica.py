import os
import shutil
import tempfile
import unittest
import uuid
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.cli import restore
from app.config import Settings
from app.errors import AppError
from app.main import create_app
from app.runtime import Runtime
from app.security import now_iso


class BackupReplicaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.replica = self.root / "replica"
        self.replica.mkdir()
        with patch.dict(os.environ, {"DATA_DIR": str(self.root / "data"), "DEPLOYMENT_MODE": "private",
                        "PUBLIC_URL": "https://example.invalid", "BACKUP_PASSWORD": "fixture-backup-password",
                        "BACKUP_REPLICA_DIR": str(self.replica), "BACKUP_REPLICA_REQUIRED": "true"}):
            self.settings = Settings.from_environment()
        self.client = TestClient(create_app(self.settings, run_jobs=False))
        self.client.__enter__()
        self.service = self.client.app.state.runtime
        self.user = self.client.post("/api/v1/auth/register", json={
            "username": "backup_fixture", "password": "fixture-user-password", "display_name": "备份测试",
            "device_id": str(uuid.uuid4()), "device_name": "测试设备"}).json()
        self.entity_id = str(uuid.uuid4())

    def tearDown(self):
        if self.client:
            self.client.__exit__(None, None, None)
        self.temporary.cleanup()

    def push(self, deleted=False):
        now = datetime.now(timezone.utc).isoformat()
        mutation = {"change_id": str(uuid.uuid4()), "entity_id": self.entity_id, "kind": "weight",
                    "business_date": now[:10], "base_version": 1 if deleted else 0,
                    "payload": {"measured_at": now, "weight_kg": 70, "source": "manual"}}
        if deleted:
            mutation["deleted_at"] = now
        return self.client.post("/api/v1/sync/push", headers={"Authorization": "Bearer " + self.user["access_token"]},
            json={"epoch": self.user["epoch"], "generation": self.user["generation"], "changes": [mutation]})

    def test_replica_survives_empty_volume_and_replays_newer_deletion(self):
        self.assertEqual(self.push().json()["results"][0]["status"], "accepted")
        backup = self.service.maintenance.backup(incremental=False)
        self.assertTrue(backup["replica"]["verified"])
        self.assertEqual(self.push(deleted=True).json()["results"][0]["status"], "accepted")
        journal = (self.replica / "deletion-intents.encrypted.jsonl").read_text()
        self.assertNotIn(self.entity_id, journal)
        self.assertNotIn(self.user["user_id"], journal)
        source = self.replica / "backups" / backup["filename"]
        self.client.__exit__(None, None, None)
        self.client = None
        shutil.rmtree(self.settings.data_dir)
        recovered = Runtime(self.settings)
        with patch("builtins.print"):
            restore(recovered, source, self.settings.backup_password)
        with recovered.db.read() as repo:
            self.assertIsNone(repo.one("entities", {"id": self.entity_id}))
            self.assertEqual(repo.one("entity_ledger", {"entity_id": self.entity_id})["deleted"], 1)
            self.assertIsNotNone(repo.one("users", {"id": self.user["user_id"]}))
            self.assertFalse(repo.find("sessions", {"revoked_at": None}))

    def test_required_replica_failure_is_visible_and_does_not_remove_local_backup(self):
        with patch.object(self.service.maintenance, "replicate_backup", side_effect=OSError("fixture unavailable")):
            with self.assertRaises(AppError) as error:
                self.service.maintenance.backup()
        self.assertEqual(error.exception.code, "BACKUP_REPLICA_FAILED")
        self.assertTrue(list((self.settings.data_dir / "backups").glob("*.bjar")))
        with self.service.db.read() as repo:
            self.assertIn('"verified": false', repo.setting("last_backup"))

    def test_detached_replica_keeps_local_backup_and_requires_ledger_for_restore(self):
        self.assertEqual(self.push().json()["results"][0]["status"], "accepted")
        detached = self.root / "detached"
        self.replica.rename(detached)
        try:
            with self.assertRaises(AppError) as error:
                self.service.maintenance.backup()
            self.assertEqual(error.exception.code, "BACKUP_REPLICA_FAILED")
            self.assertEqual(len(list((self.settings.data_dir / "backups").glob("*.bjar"))), 1)
            with self.assertRaises(FileNotFoundError):
                self.service.maintenance.deletion_events()
        finally:
            detached.rename(self.replica)

    def test_retry_retransmits_same_verified_package_without_filling_local_disk(self):
        task_id = str(uuid.uuid4())
        with self.service.db.transaction() as repo:
            repo.insert("tasks", {"id": task_id, "user_id": "system", "kind": "backup", "status": "running",
                                  "request_key": task_id, "payload": "{}", "created_at": now_iso(), "updated_at": now_iso()})
        with patch.object(self.service.maintenance, "replicate_backup", side_effect=OSError("fixture offline")):
            for _ in range(3):
                with self.assertRaises((AppError, OSError)):
                    self.service.maintenance.backup(task_id=task_id)
        before = list((self.settings.data_dir / "backups").glob("*.bjar"))
        self.assertEqual(len(before), 1)
        result = self.service.maintenance.backup(task_id=task_id)
        self.assertEqual(result["filename"], before[0].name)
        self.assertTrue(result["replica"]["verified"])
        self.assertEqual(len(list((self.settings.data_dir / "backups").glob("*.bjar"))), 1)

    def test_unavailable_deletion_replica_prevents_acknowledged_delete(self):
        self.assertEqual(self.push().json()["results"][0]["status"], "accepted")
        journal = self.replica / "deletion-intents.encrypted.jsonl"
        contents = journal.read_bytes()
        journal.unlink()
        try:
            with self.assertRaises(OSError):
                self.push(deleted=True)
            with self.service.db.read() as repo:
                self.assertIsNone(repo.one("entities", {"id": self.entity_id})["deleted_at"])
        finally:
            journal.write_bytes(contents)

    def test_replica_must_be_independent_and_pre_mounted(self):
        for target in (self.settings.data_dir, self.settings.data_dir / "backups", self.root / "missing"):
            with self.assertRaises(ValueError):
                replace(self.settings, backup_replica_dir=str(target)).prepare()

    def test_existing_replica_without_deletion_journal_cannot_be_reinitialized(self):
        self.service.maintenance.backup()
        journal = self.replica / "deletion-intents.encrypted.jsonl"
        original = journal.read_bytes()
        journal.unlink()
        try:
            with self.assertRaisesRegex(ValueError, "账本缺失"):
                Runtime(replace(self.settings, data_dir=self.root / "fresh"))
            self.assertFalse(journal.exists())
        finally:
            journal.write_bytes(original)

    def test_restore_rejects_new_empty_ledger_even_when_archive_was_copied_elsewhere(self):
        backup = self.service.maintenance.backup(incremental=False)
        source = self.replica / "backups" / backup["filename"]
        other_replica = self.root / "new-replica"
        other_replica.mkdir()
        fresh = Runtime(replace(self.settings, data_dir=self.root / "fresh", backup_replica_dir=str(other_replica)))
        with self.assertRaisesRegex(ValueError, "原始独立删除账本"):
            restore(fresh, source, self.settings.backup_password)

    def test_runtime_detects_mount_replaced_with_another_ledger(self):
        other_replica = self.root / "other-replica"
        other_replica.mkdir()
        Runtime(replace(self.settings, data_dir=self.root / "other-data", backup_replica_dir=str(other_replica)))
        journal = self.replica / "deletion-intents.encrypted.jsonl"
        original = journal.read_bytes()
        try:
            journal.write_bytes((other_replica / journal.name).read_bytes())
            with self.assertRaisesRegex(ValueError, "身份已变化"):
                self.service.db.deletion_journal.read_replica()
            with self.assertRaises(AppError) as error:
                self.service.maintenance.backup()
            self.assertEqual(error.exception.code, "BACKUP_REPLICA_FAILED")
        finally:
            journal.write_bytes(original)

    def test_incremental_replica_keeps_required_objects(self):
        # 系统媒体备份只处理文件，使用合成字节核对独立对象的复制和完整性。
        photo = self.service.media.root / str(uuid.uuid4())
        photo.write_bytes(b"fixture attachment" * 100)
        backup = self.service.maintenance.backup()
        self.assertEqual(backup["referenced_objects"], 1)
        source = self.replica / "backups" / backup["filename"]
        restored = self.root / "isolated"
        self.service.maintenance.unpack_backup(source, self.settings.backup_password, restored)
        self.assertEqual((restored / "media" / photo.name).read_bytes(), photo.read_bytes())
