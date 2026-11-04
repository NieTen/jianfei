import json
import os
from pathlib import Path


class DeletionJournal:
    """独立保存已验证的删除意图，旧备份恢复时优先执行。"""

    def __init__(self, directory: Path):
        self.path = directory / "deletion-intents.jsonl"

    def append(self, event):
        encoded = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
        with self.path.open("a+b") as handle:
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
