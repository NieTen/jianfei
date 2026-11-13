import os

from .ai import AIService
from .auth import AuthService
from .challenges import ChallengeService
from .config import Settings
from .data_service import DataService
from .database import Database
from .entitlements import EntitlementService
from .foods import FoodService
from .jobs import JobRunner
from .maintenance import MaintenanceService
from .media import MediaService
from .push import PushService
from .providers import ProviderService
from .records import RecordService


class Runtime:
    def __init__(self, settings=None, exclusive=False):
        self.settings = settings or Settings.from_environment()
        self.settings.prepare()
        self.lock_file = None
        if exclusive:
            self.acquire_instance()
        self.db = Database(self.settings.data_dir / "db" / "app.sqlite3")
        self.db.initialize()
        self.auth = AuthService(self.db, self.settings)
        self.entitlements = EntitlementService(self.db, self.settings)
        self.records = RecordService(self.db, self.settings)
        self.media = MediaService(self.db, self.settings)
        self.media.entitlements = self.entitlements
        self.challenges = ChallengeService(self.db, self.records)
        self.records.challenge_service = self.challenges
        self.providers = ProviderService(self.db, self.settings, self.entitlements)
        self.ai = AIService(self.db, self.settings, self.media, self.providers, self.entitlements)
        self.data = DataService(self.db, self.settings, self.records, self.media)
        self.maintenance = MaintenanceService(self.db, self.settings, self.media)
        self.push = PushService(self.db, self.settings)
        self.foods = FoodService(self.settings, self.records)
        self.jobs = JobRunner(self.db, self.settings, self.ai, self.data, self.challenges,
                              self.maintenance, self.push, self.media, self.auth.email)

    def acquire_instance(self):
        self.lock_file = (self.settings.data_dir / "db" / "instance.lock").open("a+b")
        try:
            if os.name == "nt":
                import msvcrt
                self.lock_file.seek(0)
                if self.lock_file.read(1) == b"":
                    self.lock_file.write(b"0")
                    self.lock_file.flush()
                self.lock_file.seek(0)
                msvcrt.locking(self.lock_file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lock_file.close()
            raise RuntimeError("已有后台实例使用此数据目录")

    def release_instance(self):
        if self.lock_file:
            self.lock_file.close()
            self.lock_file = None

