import os
import tempfile
import unittest
from unittest.mock import patch

from app.config import Settings


class CloudProtocolSettingsTests(unittest.TestCase):
    def test_cloud_requires_https_by_default(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {
                "DATA_DIR": directory, "DEPLOYMENT_MODE": "cloud",
                "PUBLIC_URL": "http://127.0.0.1:8000",
            }, clear=True):
                settings = Settings.from_environment()
            self.assertFalse(settings.cloud_allow_http)
            with self.assertRaisesRegex(ValueError, "HTTPS"):
                settings.prepare()

    def test_cloud_http_requires_explicit_opt_in(self):
        for option in ("false", "1", "yes", ""):
            with self.subTest(option=option), tempfile.TemporaryDirectory() as directory:
                with patch.dict(os.environ, {
                    "DATA_DIR": directory, "DEPLOYMENT_MODE": "cloud",
                    "PUBLIC_URL": "http://192.168.50.229:8000", "CLOUD_ALLOW_HTTP": option,
                }, clear=True):
                    settings = Settings.from_environment()
                with self.assertRaises(ValueError):
                    settings.prepare()

    def test_local_http_keeps_cloud_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {
                "DATA_DIR": directory, "DEPLOYMENT_MODE": "cloud",
                "PUBLIC_URL": "http://192.168.50.229:8000", "CLOUD_ALLOW_HTTP": "true",
            }, clear=True):
                settings = Settings.from_environment()
            settings.prepare()
            self.assertEqual(settings.deployment_mode, "cloud")
            self.assertTrue((settings.data_dir / "db").is_dir())

    def test_https_and_other_protocols_with_http_option(self):
        for option in ("false", "true"):
            for address, allowed in (("https://cloud.example.invalid", True), ("ftp://localhost", False)):
                with self.subTest(option=option, address=address), tempfile.TemporaryDirectory() as directory:
                    with patch.dict(os.environ, {
                        "DATA_DIR": directory, "DEPLOYMENT_MODE": "cloud",
                        "PUBLIC_URL": address, "CLOUD_ALLOW_HTTP": option,
                    }, clear=True):
                        settings = Settings.from_environment()
                    if allowed:
                        settings.prepare()
                    else:
                        with self.assertRaises(ValueError):
                            settings.prepare()
