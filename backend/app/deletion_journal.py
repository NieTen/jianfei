import json
import os
import hashlib
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .archive import derive_key


class DeletionJournal:
    """独立保存已验证的删除意图，旧备份恢复时优先执行。"""

    def __init__(self, directory: Path):
        self.path = directory / "deletion-intents.jsonl"
        self.replica_path = None
        self.replica_cipher = None
        self.replica_id = None

    def configure_replica(self, directory, password):
        self.replica_path = Path(directory) / "deletion-intents.encrypted.jsonl"
        if not self.replica_path.exists():
            root = Path(directory)
            if (root / "latest.json").exists() or any((root / "backups").glob("*.bjar")):
                raise ValueError("异地目录已有备份但独立删除账本缺失，禁止创建空账本；请恢复最新账本后重试")
            salt = os.urandom(16)
            cipher = AESGCM(derive_key(password, salt))
            nonce = os.urandom(12)
            header = {"version": 1, "salt": salt.hex(),
                      "verification": (nonce + cipher.encrypt(nonce, b"BingJian ledger key", b"ledger header v1")).hex()}
            descriptor = os.open(self.replica_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(json.dumps(header).encode() + b"\n")
                handle.flush()
                os.fsync(handle.fileno())
        else:
            with self.replica_path.open("rb") as handle:
                header = json.loads(handle.readline())
            if header.get("version") != 1:
                raise ValueError("异地删除账本版本无效")
            salt = bytes.fromhex(header["salt"])
        if len(salt) != 16:
            raise ValueError("异地删除账本头部无效")
        self.replica_cipher = AESGCM(derive_key(password, salt))
        self.replica_id = hashlib.sha256(salt).hexdigest()
        verification = bytes.fromhex(header.get("verification", ""))
        if len(verification) < 28 or self.replica_cipher.decrypt(verification[:12], verification[12:], b"ledger header v1") != b"BingJian ledger key":
            raise ValueError("异地删除账本密码或头部无效")
        # 错误密码或损坏的账本必须在服务启动前显式失败。
        known = {row["id"] for row in self.read_replica()}
        for event in self.read():
            if event["id"] not in known:
                self.mirror_event(event)

    def append(self, event):
        encoded = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
        self.mirror_event(event)
        self.append_line(self.path, encoded)

    def mirror_event(self, event):
        if self.replica_path:
            if not self.replica_path.is_file():
                raise OSError("异地删除账本不可用，删除未确认")
            self.verify_replica_header()
            nonce = os.urandom(12)
            encoded = json.dumps(event, ensure_ascii=False).encode("utf-8")
            sealed = self.replica_cipher.encrypt(nonce, encoded, b"BingJian deletion intent v1")
            self.append_line(self.replica_path, (nonce + sealed).hex().encode() + b"\n")

    def verify_replica_header(self):
        if not self.replica_path:
            return
        with self.replica_path.open("rb") as handle:
            header = json.loads(handle.readline())
        if header.get("version") != 1 or hashlib.sha256(bytes.fromhex(header["salt"])).hexdigest() != self.replica_id:
            raise ValueError("异地删除账本身份已变化，请检查挂载")
        verification = bytes.fromhex(header.get("verification", ""))
        if len(verification) < 28 or self.replica_cipher.decrypt(verification[:12], verification[12:], b"ledger header v1") != b"BingJian ledger key":
            raise ValueError("异地删除账本校验失败")

    @staticmethod
    def append_line(path, encoded):
        with path.open("a+b") as handle:
            handle.seek(0, os.SEEK_END)
            position = handle.tell()
            while position:
                handle.seek(position - 1)
                if handle.read(1) == b"\n":
                    break
                position -= 1
            handle.truncate(position)
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())

    def read_replica(self):
        if not self.replica_path:
            return []
        self.verify_replica_header()
        rows = []
        with self.replica_path.open("rb") as handle:
            handle.readline()
            for line in handle:
                if not line.endswith(b"\n"):
                    break
                raw = bytes.fromhex(line.decode().strip())
                decoded = self.replica_cipher.decrypt(raw[:12], raw[12:], b"BingJian deletion intent v1")
                rows.append(json.loads(decoded))
        return rows

    def read(self):
        if not self.path.exists():
            return []
        rows = []
        with self.path.open("rb") as handle:
            for line in handle:
                if not line.endswith(b"\n"):
                    # 崩溃时未完整落盘的最后一条不曾向调用方确认。
                    break
                rows.append(json.loads(line))
        return rows
