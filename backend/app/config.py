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
    deployment_mode: str = "private"
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_username: str = ""
    smtp_password: str = ""
    smtp_from: str = ""
    smtp_starttls: bool = True
    smtp_ssl: bool = False
    ai_daily_limit: int = 30
    email_code_ttl_seconds: int = 600

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
            deployment_mode=os.getenv("DEPLOYMENT_MODE", "private").lower(),
            smtp_host=os.getenv("SMTP_HOST", ""),
            smtp_port=int(os.getenv("SMTP_PORT", "587")),
            smtp_username=os.getenv("SMTP_USERNAME", ""),
            smtp_password=os.getenv("SMTP_PASSWORD", ""),
            smtp_from=os.getenv("SMTP_FROM", ""),
            smtp_starttls=os.getenv("SMTP_STARTTLS", "true").lower() == "true",
            smtp_ssl=os.getenv("SMTP_SSL", "false").lower() == "true",
            ai_daily_limit=int(os.getenv("AI_DAILY_LIMIT", "30")),
            email_code_ttl_seconds=int(os.getenv("EMAIL_CODE_TTL_SECONDS", "600")),
        )

    def prepare(self):
        if self.deployment_mode not in ("private", "cloud"):
            raise ValueError("DEPLOYMENT_MODE 必须为 private 或 cloud")
        if self.ai_daily_limit < 1 or not 60 <= self.email_code_ttl_seconds <= 1800:
            raise ValueError("AI 日额度必须为正数，邮箱验证码有效期须在 60 至 1800 秒之间")
        if self.deployment_mode == "cloud" and not self.public_url.startswith("https://"):
            raise ValueError("云端服务 PUBLIC_URL 必须使用 HTTPS")
        for name in ("db", "media", "tmp", "exports", "backups", "secrets"):
            (self.data_dir / name).mkdir(parents=True, exist_ok=True)

