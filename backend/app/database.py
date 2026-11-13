import json
import sqlite3
import threading
import uuid
from contextlib import closing, contextmanager
from pathlib import Path

from .errors import AppError
from .deletion_journal import DeletionJournal
from .security import now_iso


class Repository:
    """统一构造参数化 SQL，业务层不拼接数据库语句。"""

    def __init__(self, connection, columns, deletion_journal=None):
        self.connection = connection
        self.columns = columns
        self.deletion_journal = deletion_journal

    def checked_table(self, table):
        if table not in self.columns:
            raise ValueError("未知数据表")
        return table

    def checked_column(self, table, column):
        if column not in self.columns[self.checked_table(table)]:
            raise ValueError("未知数据字段")
        return column

    def conditions(self, table, filters):
        parts, values = [], []
        operators = {"eq": "=", "gt": ">", "gte": ">=", "lt": "<", "lte": "<=", "ne": "!="}
        for expression, value in filters.items():
            segments = expression.rsplit("__", 1)
            column = self.checked_column(table, segments[0])
            operator = segments[1] if len(segments) == 2 else "eq"
            if value is None:
                parts.append(f'"{column}" IS {"NOT " if operator == "ne" else ""}NULL')
            elif operator == "in":
                if not value:
                    parts.append("0 = 1")
                else:
                    parts.append(f'"{column}" IN ({",".join("?" for _ in value)})')
                    values.extend(value)
            else:
                parts.append(f'"{column}" {operators[operator]} ?')
                values.append(value)
        return " AND ".join(parts) or "1 = 1", values

    def find(self, table, filters=None, order=None, limit=10000, offset=0):
        table = self.checked_table(table)
        where, values = self.conditions(table, filters or {})
        fields = ", ".join(f'"{column}"' for column in self.columns[table])
        sql = f'SELECT {fields} FROM "{table}" WHERE {where}'
        if order:
            clauses = []
            for field in order:
                descending = field.startswith("-")
                column = self.checked_column(table, field.lstrip("-"))
                clauses.append(f'"{column}" {"DESC" if descending else "ASC"}')
            sql += " ORDER BY " + ", ".join(clauses)
        sql += " LIMIT ? OFFSET ?"
        return [dict(row) for row in self.connection.execute(sql, values + [limit, offset])]

    def one(self, table, filters):
        rows = self.find(table, filters, limit=1)
        return rows[0] if rows else None

    def insert(self, table, values):
        table = self.checked_table(table)
        fields = [self.checked_column(table, field) for field in values]
        names = ", ".join(f'"{field}"' for field in fields)
        placeholders = ", ".join("?" for _ in fields)
        cursor = self.connection.execute(
            f'INSERT INTO "{table}" ({names}) VALUES ({placeholders})', list(values.values())
        )
        if table == "deletion_ledger" and self.deletion_journal:
            self.deletion_journal.append(values)
        return cursor.lastrowid

    def update(self, table, values, filters):
        if not filters or not values:
            raise ValueError("更新必须包含字段及条件")
        table = self.checked_table(table)
        fields = [self.checked_column(table, field) for field in values]
        where, parameters = self.conditions(table, filters)
        assignments = ", ".join(f'"{field}" = ?' for field in fields)
        return self.connection.execute(
            f'UPDATE "{table}" SET {assignments} WHERE {where}', list(values.values()) + parameters
        ).rowcount

    def delete(self, table, filters):
        if not filters:
            raise ValueError("删除必须包含条件")
        table = self.checked_table(table)
        where, values = self.conditions(table, filters)
        return self.connection.execute(f'DELETE FROM "{table}" WHERE {where}', values).rowcount

    def setting(self, key):
        row = self.one("settings", {"key": key})
        return row["value"] if row else None

    def audit(self, user_id, action, target_id=None):
        self.insert("audit", {"id": str(uuid.uuid4()), "user_id": user_id, "action": action,
                              "target_id": target_id, "created_at": now_iso()})

    def max_sequence(self, user_id):
        row = self.connection.execute(
            "SELECT COALESCE(MAX(sequence), 0) AS sequence FROM changes WHERE user_id = ?", (user_id,)
        ).fetchone()
        return row["sequence"]

    def ai_usage_count(self, user_id, usage_day):
        row = self.connection.execute(
            "SELECT COUNT(task_id) AS total FROM ai_usage WHERE user_id = ? AND usage_day = ? AND status != ?",
            (user_id, usage_day, "released"),
        ).fetchone()
        return row["total"]

    def copy_snapshot(self, snapshot_id, user_id):
        rows = self.connection.execute(
            "SELECT id, kind, payload, business_date, source_id, version, deleted_at, updated_at, device_id "
            "FROM entities WHERE user_id = ? ORDER BY id", (user_id,)
        )
        batch = []
        for row in rows:
            value = dict(row)
            value["payload"] = json.loads(value["payload"])
            batch.append((snapshot_id, value["id"], json.dumps(value, ensure_ascii=False)))
            if len(batch) == 200:
                self.connection.executemany(
                    "INSERT INTO snapshot_rows(snapshot_id, entity_id, payload) VALUES (?, ?, ?)", batch
                )
                batch.clear()
        if batch:
            self.connection.executemany(
                "INSERT INTO snapshot_rows(snapshot_id, entity_id, payload) VALUES (?, ?, ?)", batch
            )


class Database:
    def __init__(self, path: Path):
        self.path = path
        self.write_lock = threading.RLock()
        self.maintenance = False
        self.columns = {}
        self.deletion_journal = DeletionJournal(path.parent)

    def connect(self):
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA synchronous = FULL")
        return connection

    def initialize(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self.connect()) as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY)")
            for migration in sorted((Path(__file__).parent / "migrations").glob("*.sql")):
                version = int(migration.stem.split("_")[0])
                applied = connection.execute(
                    "SELECT version FROM schema_version WHERE version = ?", (version,)
                ).fetchone()
                if not applied:
                    # 迁移在单一事务中提交，失败时交给 SQLite 回滚。
                    script = "BEGIN IMMEDIATE;\n" + migration.read_text(encoding="utf-8")
                    script += f"\nINSERT INTO schema_version(version) VALUES ({version});\nCOMMIT;"
                    connection.executescript(script)
            tables = connection.execute(
                "SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE ?", ("table", "sqlite_%")
            ).fetchall()
            for table in tables:
                name = table["name"]
                self.columns[name] = [row["name"] for row in connection.execute(f'PRAGMA table_info("{name}")')]
        with self.transaction() as repo:
            for key in ("instance_id", "sync_epoch"):
                if repo.setting(key) is None:
                    repo.insert("settings", {"key": key, "value": str(uuid.uuid4())})

    @contextmanager
    def read(self):
        connection = self.connect()
        try:
            yield Repository(connection, self.columns)
        finally:
            connection.close()

    @contextmanager
    def transaction(self, allow_maintenance=False):
        if self.maintenance and not allow_maintenance:
            raise AppError("SERVICE_MAINTENANCE", "服务器正在备份，请稍后重试", 503, True)
        with self.write_lock:
            connection = self.connect()
            try:
                connection.execute("BEGIN IMMEDIATE")
                yield Repository(connection, self.columns, self.deletion_journal)
                connection.commit()
            except sqlite3.OperationalError as error:
                connection.rollback()
                if "locked" in str(error).lower() or "busy" in str(error).lower():
                    raise AppError("DATABASE_BUSY", "数据正在保存，请稍后重试", 503, True) from error
                raise
            except BaseException:
                connection.rollback()
                raise
            finally:
                connection.close()

    def backup(self, destination):
        with self.write_lock, closing(self.connect()) as source, closing(sqlite3.connect(destination)) as target:
            source.backup(target)

