import json
import time
from pathlib import Path

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from .security import b64encode


class PushService:
    def __init__(self, database, settings):
        self.db = database
        self.settings = settings
        self.cached_token = None
        self.token_time = 0

    def configured(self):
        return bool(self.settings.apns_key_file and self.settings.apns_key_id and
                    self.settings.apns_team_id and self.settings.apns_topic)

    def provider_token(self):
        now = int(time.time())
        if self.cached_token and now - self.token_time < 3000:
            return self.cached_token
        header = b64encode(json.dumps({"alg": "ES256", "kid": self.settings.apns_key_id}, separators=(",", ":")).encode())
        claims = b64encode(json.dumps({"iss": self.settings.apns_team_id, "iat": now}, separators=(",", ":")).encode())
        value = header + "." + claims
        private_key = serialization.load_pem_private_key(Path(self.settings.apns_key_file).read_bytes(), password=None)
        signature = private_key.sign(value.encode(), ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(signature)
        self.cached_token = value + "." + b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        self.token_time = now
        return self.cached_token

    async def deliver(self):
        if not self.configured():
            return
        with self.db.read() as repo:
            notifications = repo.find("notifications", {"status": "pending"}, order=["created_at"], limit=10)
        host = "https://api.sandbox.push.apple.com" if self.settings.apns_sandbox else "https://api.push.apple.com"
        async with httpx.AsyncClient(http2=True, timeout=15) as client:
            for notification in notifications:
                payload = json.loads(notification["payload"])
                with self.db.read() as repo:
                    member = repo.one("members", {"challenge_id": payload["challenge_id"],
                                                  "user_id": notification["user_id"], "status": "active"})
                    devices = repo.find("devices", {"user_id": notification["user_id"], "revoked_at": None, "push_enabled": 1})
                if not member:
                    with self.db.transaction() as repo:
                        repo.update("notifications", {"status": "cancelled"}, {"id": notification["id"]})
                    continue
                delivered = True
                for device in devices:
                    if not device["push_token"]:
                        continue
                    response = await client.post(
                        host + "/3/device/" + device["push_token"],
                        headers={"authorization": "bearer " + self.provider_token(), "apns-topic": self.settings.apns_topic,
                                 "apns-push-type": "alert", "apns-priority": "10",
                                 "apns-collapse-id": notification["id"], "apns-id": notification["id"]},
                        json={"aps": {"alert": {"title": "并肩", "body": "伙伴发来了一条鼓励"}, "sound": "default"},
                              "challenge_id": payload["challenge_id"]},
                    )
                    if response.status_code == 410:
                        with self.db.transaction() as repo:
                            repo.update("devices", {"push_enabled": 0, "push_token": None}, {"id": device["id"]})
                    elif response.status_code >= 400:
                        delivered = False
                if delivered:
                    with self.db.transaction() as repo:
                        repo.update("notifications", {"status": "sent"}, {"id": notification["id"]})

