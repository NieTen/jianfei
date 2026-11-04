import base64
import hashlib
import hmac
import json
import secrets
from datetime import datetime, timezone
from pathlib import Path

from .errors import AppError


def utc_now():
    return datetime.now(timezone.utc)


def now_iso():
    return utc_now().isoformat()


def token_hash(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def new_token():
    return secrets.token_urlsafe(32)


def password_hash(password, salt=None):
    salt = salt or secrets.token_hex(16)
    digest = hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt), n=16384, r=8, p=1)
    return salt + ":" + digest.hex()


def verify_password(password, encoded):
    try:
        return hmac.compare_digest(password_hash(password, encoded.split(":")[0]), encoded)
    except (ValueError, TypeError):
        return False


def load_secret(path: Path):
    if not path.exists():
        try:
            with path.open("x", encoding="utf-8") as handle:
                handle.write(new_token())
            path.chmod(0o600)
        except FileExistsError:
            pass
    return path.read_text(encoding="utf-8").strip()


def b64encode(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def b64decode(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def sign_payload(payload, secret):
    raw = b64encode(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    signature = b64encode(hmac.new(secret.encode(), raw.encode(), hashlib.sha256).digest())
    return raw + "." + signature


def verify_payload(value, secret):
    try:
        raw, signature = value.split(".")
        expected = b64encode(hmac.new(secret.encode(), raw.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(signature, expected):
            raise ValueError()
        return json.loads(b64decode(raw))
    except (ValueError, TypeError, UnicodeDecodeError):
        raise AppError("INVALID_TOKEN", "凭据无效，请重新获取", 401)

