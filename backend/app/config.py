import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    public_url: str
    bootstrap_code: str
    ai_url: str
    ai_key: str
    ai_model: str
    ai_protocol: str
    ai_external: bool
    backup_hour: int
    backup_password: str
    apns_key_file: str
    apns_key_id: str
    apns_team_id: str
    apns_topic: str
    apns_sandbox: bool
    food_api_key: str

    @classmethod
    def from_environment(cls):
        return cls(
            data_dir=Path(os.getenv("DATA_DIR", "./data")).resolve(),
            public_url=os.getenv("PUBLIC_URL", "https://localhost"),
            bootstrap_code=os.getenv("BOOTSTRAP_CODE", ""),
            ai_url=os.getenv("AI_URL", "").rstrip("/"),
            ai_key=os.getenv("AI_KEY", ""),
            ai_model=os.getenv("AI_MODEL", ""),
            ai_protocol=os.getenv("AI_PROTOCOL", "responses"),
            ai_external=os.getenv("AI_EXTERNAL", "true").lower() == "true",
            backup_hour=int(os.getenv("BACKUP_HOUR", "3")),
            backup_password=os.getenv("BACKUP_PASSWORD", ""),
            apns_key_file=os.getenv("APNS_KEY_FILE", ""),
            apns_key_id=os.getenv("APNS_KEY_ID", ""),
            apns_team_id=os.getenv("APNS_TEAM_ID", ""),
            apns_topic=os.getenv("APNS_TOPIC", ""),
            apns_sandbox=os.getenv("APNS_SANDBOX", "true").lower() == "true",
            food_api_key=os.getenv("FOOD_API_KEY", ""),
        )

    def prepare(self):
        for name in ("db", "media", "tmp", "exports", "backups", "secrets"):
            (self.data_dir / name).mkdir(parents=True, exist_ok=True)

