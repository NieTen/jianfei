import asyncio
import json
import logging
import os
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from .errors import AppError
from .security import now_iso, utc_now

logger = logging.getLogger("jianfei.jobs")


class JobRunner:
    def __init__(self, database, settings, ai, data, challenges, maintenance, push, media):
        self.db, self.settings = database, settings
        self.ai, self.data, self.challenges = ai, data, challenges
        self.maintenance, self.push, self.media = maintenance, push, media
        self.stopping = asyncio.Event()
        self.tasks = []

    async def start(self):
        await asyncio.to_thread(self.recover_interrupted)
        self.tasks = [
            asyncio.create_task(self.worker(["recognition"])),
            asyncio.create_task(self.worker(["export", "delete", "backup"])),
            asyncio.create_task(self.periodic()),
        ]

    def recover_interrupted(self):
        # 单实例锁已取得，旧 running 状态不会再由其他进程执行。
        with self.db.transaction() as repo:
            for task in repo.find("tasks", {"status": "running"}):
                status = "unknown" if task["kind"] == "recognition" else "pending"
                repo.update("tasks", {"status": status, "lease_until": None,
                                      "error": "服务重新启动，请确认原任务结果后重试" if status == "unknown" else None,
                                      "updated_at": now_iso()}, {"id": task["id"]})

    async def stop(self):
        self.stopping.set()
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)

    def claim(self, kinds):
        if self.db.maintenance:
            return None
        with self.db.transaction() as repo:
            if "delete" in kinds:
                failed = repo.find("tasks", {"kind": "delete", "status": "failed",
                                             "attempts__lt": 5, "lease_until__lt": now_iso()}, limit=10)
                for task in failed:
                    repo.update("tasks", {"status": "pending", "updated_at": now_iso()}, {"id": task["id"]})
            abandoned = repo.find("tasks", {"kind__in": kinds, "status": "running", "lease_until__lt": now_iso()}, limit=20)
            for task in abandoned:
                # 外部模型请求中断后无法确认是否已计费，交由用户明确重试。
                status = "unknown" if task["kind"] == "recognition" else "pending"
                repo.update("tasks", {"status": status, "error": "执行中断，请查看结果后重试",
                                      "updated_at": now_iso()}, {"id": task["id"]})
            pending = repo.find("tasks", {"kind__in": kinds, "status": "pending"}, order=["created_at"], limit=1)
            if not pending:
                return None
            task = pending[0]
            repo.update("tasks", {"status": "running", "attempts": task["attempts"] + 1,
                                  "lease_until": (utc_now() + timedelta(minutes=30)).isoformat(),
                                  "updated_at": now_iso()}, {"id": task["id"]})
            return task

    async def worker(self, kinds):
        while not self.stopping.is_set():
            task = None
            try:
                task = await asyncio.to_thread(self.claim, kinds)
                if not task:
                    await asyncio.sleep(1)
                    continue
                if task["kind"] == "recognition":
                    result = await self.ai.process(task)
                elif task["kind"] == "export":
                    result = await asyncio.to_thread(self.data.export, task)
                elif task["kind"] == "delete":
                    result = await asyncio.to_thread(self.data.process_delete, task)
                else:
                    result = await asyncio.to_thread(self.maintenance.backup)
                await asyncio.to_thread(self.finish, task["id"], "completed", result, None)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                logger.warning("后台任务失败，类型=%s", task["kind"] if task else "领取")
                if task:
                    message = error.message if isinstance(error, AppError) else "任务未完成，请检查服务配置后重试"
                    await asyncio.to_thread(self.finish, task["id"], "failed", None, message)
                await asyncio.sleep(2)

    def finish(self, task_id, status, result, error):
        with self.db.transaction(allow_maintenance=True) as repo:
            task = repo.one("tasks", {"id": task_id})
            if task and task["status"] != "cancelled":
                retry_at = (utc_now() + timedelta(minutes=5)).isoformat() if status == "failed" and task["kind"] == "delete" else None
                payload = json.loads(task["payload"])
                if task["kind"] == "recognition":
                    payload.pop("_provider_snapshot", None)
                repo.update("tasks", {"status": status, "result": json.dumps(result, ensure_ascii=False) if result is not None else None,
                                      "payload": json.dumps(payload), "error": error, "lease_until": retry_at, "updated_at": now_iso()}, {"id": task_id})

    def enqueue_backup(self):
        local = datetime.now(ZoneInfo(os.environ.get("TZ", "Asia/Shanghai")))
        if not self.settings.backup_password or local.hour < self.settings.backup_hour:
            return
        key = "daily-" + local.date().isoformat()
        with self.db.transaction() as repo:
            if repo.one("tasks", {"user_id": "system", "kind": "backup", "request_key": key}):
                return
            repo.insert("tasks", {"id": str(uuid.uuid4()), "user_id": "system", "kind": "backup",
                                  "status": "pending", "request_key": key, "payload": "{}",
                                  "created_at": now_iso(), "updated_at": now_iso()})

    async def periodic(self):
        while not self.stopping.is_set():
            try:
                if not self.db.maintenance:
                    await asyncio.to_thread(self.challenges.tick)
                    await asyncio.to_thread(self.media.cleanup)
                    await asyncio.to_thread(self.maintenance.persist_ledger)
                    await asyncio.to_thread(self.enqueue_backup)
                    await asyncio.to_thread(self.maintenance.cleanup)
                    await self.push.deliver()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.warning("周期维护暂未完成，将在下一周期重试")
            await asyncio.sleep(30)

