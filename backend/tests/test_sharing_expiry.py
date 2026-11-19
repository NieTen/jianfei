import os
import tempfile
import unittest
import uuid
from datetime import timedelta
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.security import utc_now


class SharingExpiryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        with patch.dict(os.environ, {"DATA_DIR": self.temporary.name, "DEPLOYMENT_MODE": "private",
                                    "AI_URL": "", "AI_KEY": "", "BACKUP_PASSWORD": ""}):
            self.client = TestClient(create_app(Settings.from_environment(), run_jobs=False))
        self.client.__enter__()
        self.service = self.client.app.state.runtime
        self.owner = self.register("share_owner")
        self.reader = self.register("share_reader")
        self.day = utc_now().date().isoformat()
        self.share_id = str(uuid.uuid4())
        self.expiry = utc_now() + timedelta(minutes=2)
        created = self.client.put("/api/v1/shares/" + self.share_id, headers=self.headers(self.owner), json={
            "recipient": "share_reader", "scopes": ["weight"], "from_day": self.day, "through_day": self.day,
            "expires_at": self.expiry.isoformat(), "expected_version": 0})
        self.assertEqual(created.status_code, 200, created.text)

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temporary.cleanup()

    def register(self, username):
        response = self.client.post("/api/v1/auth/register", json={"username": username, "display_name": username,
            "password": "test-password-123", "device_id": str(uuid.uuid4())})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    @staticmethod
    def headers(user):
        return {"Authorization": "Bearer " + user["access_token"]}

    def read_summary(self):
        return self.client.get("/api/v1/shares/" + self.share_id + "/summary", headers=self.headers(self.reader), params={"day": self.day})

    def test_summary_includes_server_time_and_refuses_expired_grant(self):
        response = self.read_summary()
        self.assertEqual(response.status_code, 200, response.text)
        self.assertIn("server_time", response.json())
        self.assertLess(response.json()["server_time"], response.json()["expires_at"])
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        with patch("app.sharing.now_iso", return_value=(self.expiry + timedelta(seconds=1)).isoformat()):
            self.assertEqual(self.read_summary().json()["code"], "CONSENT_REVOKED")

    def test_grant_expiring_while_projecting_does_not_return_private_content(self):
        before = (self.expiry - timedelta(seconds=1)).isoformat()
        after = (self.expiry + timedelta(seconds=1)).isoformat()
        with patch("app.sharing.now_iso", side_effect=[before, before, after]):
            response = self.read_summary()
        self.assertEqual(response.status_code, 403, response.text)
        self.assertEqual(response.json()["code"], "CONSENT_REVOKED")
        self.assertNotIn("weight_kg", response.json())
