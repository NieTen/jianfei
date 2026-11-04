import hashlib
import json
import uuid
from datetime import datetime, timedelta

from pydantic import ValidationError

from .domain import energy_summary, representative
from .errors import AppError
from .models import KIND_MODELS
from .security import load_secret, now_iso, sign_payload, utc_now, verify_payload


def decoded_entity(row):
    if row is None:
        return None
    result = {key: row[key] for key in (
        "id", "kind", "business_date", "source_id", "version", "deleted_at", "updated_at", "device_id"
    )}
    result["payload"] = json.loads(row["payload"])
    return result


def validate_actor(repo, actor):
    user = repo.one("users", {"id": actor["user_id"], "status": "active"})
    device = repo.one("devices", {"id": actor["device_id"], "user_id": actor["user_id"], "revoked_at": None})
    session = repo.one("sessions", {"id": actor["session_id"], "revoked_at": None})
    if not user or not device or not session:
        raise AppError("DEVICE_REVOKED", "账号或设备已失效", 403)
    if user["generation"] != actor["generation"]:
        raise AppError("GENERATION_CHANGED", "数据代际已变化，请重新登录", 409)


class RecordService:
    def __init__(self, database, settings):
        self.db = database
        self.secret = load_secret(settings.data_dir / "secrets" / "cursor.key")
        self.challenge_service = None

    def public_identity(self):
        with self.db.read() as repo:
            return {"instance_id": repo.setting("instance_id"), "api_version": 1, "name": "并肩私有服务"}

    def handshake(self, actor):
        with self.db.read() as repo:
            return {
                "instance_id": repo.setting("instance_id"), "epoch": repo.setting("sync_epoch"),
                "generation": actor["generation"], "protocol_version": 1,
                "max_batch": 200, "max_media_bytes": 15 * 1024 * 1024,
                "features": ["groups", "multi_device", "resumable_media", "snapshots", "score_v1"],
            }

    def validate_epoch(self, repo, actor, epoch, generation):
        validate_actor(repo, actor)
        if epoch != repo.setting("sync_epoch"):
            raise AppError("EPOCH_CHANGED", "服务端已恢复或迁移，请重新拉取数据", 409)
        if generation != actor["generation"]:
            raise AppError("GENERATION_CHANGED", "数据代际已变化，请重新建立同步基线", 409)

    def push(self, actor, request):
        results, affected_days = [], set()
        with self.db.read() as repo:
            self.validate_epoch(repo, actor, request.epoch, request.generation)
        for change in request.changes:
            try:
                with self.db.transaction() as repo:
                    self.validate_epoch(repo, actor, request.epoch, request.generation)
                    result = self.apply_change(repo, actor, change)
                    results.append(result)
                    if result["status"] in ("accepted", "duplicate"):
                        affected_days.add(change.business_date)
            except (ValidationError, ValueError) as error:
                results.append({"change_id": change.change_id, "status": "rejected",
                                "code": "VALIDATION_FAILED", "message": str(error), "retryable": False})
            except AppError as error:
                results.append({"change_id": change.change_id, "status": "rejected",
                                "code": error.code, "message": error.message, "retryable": error.retryable,
                                "details": error.details})
        if self.challenge_service:
            for day in affected_days:
                self.challenge_service.recalculate_user(actor["user_id"], day)
        return {"results": results}

    def apply_change(self, repo, actor, change):
        serialized = json.dumps(change.model_dump(), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        payload_hash = hashlib.sha256(serialized.encode()).hexdigest()
        receipt_key = {"id": change.change_id, "user_id": actor["user_id"], "generation": actor["generation"]}
        receipt = repo.one("receipts", receipt_key)
        if receipt:
            if receipt["payload_hash"] != payload_hash:
                raise AppError("IDEMPOTENCY_CONFLICT", "相同变更标识包含不同内容", 409)
            result = json.loads(receipt["result"])
            result["status"] = "duplicate"
            return result
        existing = repo.one("entities", {"user_id": actor["user_id"], "id": change.entity_id})
        ledger_key = {"user_id": actor["user_id"], "entity_id": change.entity_id, "generation": actor["generation"]}
        ledger = repo.one("entity_ledger", ledger_key)
        if ledger and ledger["deleted"]:
            raise AppError("ENTITY_DELETED", "该记录已删除，恢复时请创建新记录", 409)
        if existing and existing["kind"] != change.kind:
            raise AppError("VERSION_CONFLICT", "记录类型与原记录不一致", 409)
        if change.base_version != (existing["version"] if existing else 0):
            return {"change_id": change.change_id, "status": "conflict", "entity": decoded_entity(existing),
                    "message": "记录已在其他设备更新"}
        source_id = change.source_id
        if source_id:
            same_source = repo.one("entities", {"user_id": actor["user_id"], "kind": change.kind, "source_id": source_id})
            if same_source and same_source["id"] != change.entity_id:
                return {"change_id": change.change_id, "status": "conflict", "entity": decoded_entity(same_source),
                        "message": "相同健康样本已存在"}
        validated = KIND_MODELS[change.kind].model_validate(change.payload).model_dump()
        self.validate_business_rules(repo, actor, change.kind, validated)
        timestamp = now_iso()
        value = {
            "id": change.entity_id, "user_id": actor["user_id"], "kind": change.kind,
            "payload": json.dumps(validated, ensure_ascii=False), "business_date": change.business_date,
            "source_id": source_id, "version": (existing["version"] if existing else 0) + 1,
            "deleted_at": timestamp if change.deleted_at else None, "updated_at": timestamp,
            "device_id": actor["device_id"],
        }
        if existing:
            repo.update("entities", value, {"user_id": actor["user_id"], "id": change.entity_id})
        else:
            repo.insert("entities", value)
        if not ledger:
            repo.insert("entity_ledger", {**ledger_key, "deleted": int(bool(change.deleted_at)), "created_change_id": change.change_id})
        elif change.deleted_at:
            repo.update("entity_ledger", {"deleted": 1}, ledger_key)
        entity = decoded_entity(value)
        repo.insert("changes", {
            "user_id": actor["user_id"], "entity_id": change.entity_id, "kind": change.kind,
            "payload": json.dumps(entity, ensure_ascii=False), "version": value["version"],
            "deleted_at": value["deleted_at"], "created_at": timestamp,
        })
        result = {"change_id": change.change_id, "status": "accepted", "entity": entity}
        repo.insert("receipts", {**receipt_key, "payload_hash": payload_hash,
                                 "result": json.dumps(result, ensure_ascii=False), "created_at": timestamp})
        if change.deleted_at:
            repo.insert("deletion_ledger", {"id": str(uuid.uuid4()), "user_id": actor["user_id"],
                                           "action": "entity", "target_id": change.entity_id, "created_at": timestamp})
            if change.kind == "meal":
                remaining = repo.find("entities", {"user_id": actor["user_id"], "kind": "meal", "deleted_at": None})
                referenced = set()
                for remaining_meal in remaining:
                    referenced.update(json.loads(remaining_meal["payload"]).get("photo_ids", []))
                for media in repo.find("media", {"user_id": actor["user_id"], "meal_id": change.entity_id}):
                    if media["id"] not in referenced:
                        repo.update("media", {"status": "deleted"}, {"id": media["id"]})
                tasks = repo.find("tasks", {"user_id": actor["user_id"], "kind": "recognition"})
                for task in tasks:
                    if json.loads(task["payload"]).get("meal_id") == change.entity_id:
                        repo.update("tasks", {"status": "cancelled", "updated_at": timestamp}, {"id": task["id"]})
        return result

    def validate_business_rules(self, repo, actor, kind, payload):
        if kind == "profile":
            membership = repo.one("active_members", {"user_id": actor["user_id"]})
            if membership:
                challenge = repo.one("challenges", {"id": membership["challenge_id"]})
                if payload["timezone"] != challenge["timezone"] or payload["day_start_minutes"] != challenge["day_start_minutes"]:
                    raise AppError("CHALLENGE_TIMEZONE_LOCKED", "挑战期间统计时区和日界线已冻结", 409)
        if kind == "meal":
            for photo_id in payload["photo_ids"]:
                media = repo.one("media", {"id": photo_id})
                if media and media["user_id"] != actor["user_id"]:
                    raise AppError("FORBIDDEN", "照片不属于当前账号", 403)
        for key in ("measured_at", "eaten_at", "start_at", "end_at", "window_start", "window_end"):
            if payload.get(key):
                parsed = datetime.fromisoformat(payload[key].replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError("时间字段必须包含时区")

    def cursor(self, repo, actor, last, upper=None, snapshot_id=None):
        return sign_payload({
            "user_id": actor["user_id"], "epoch": repo.setting("sync_epoch"), "generation": actor["generation"],
            "last": last, "upper": upper, "snapshot_id": snapshot_id,
        }, self.secret)

    def pull(self, actor, cursor, limit=200):
        with self.db.read() as repo:
            validate_actor(repo, actor)
            state = verify_payload(cursor, self.secret) if cursor else {
                "user_id": actor["user_id"], "epoch": repo.setting("sync_epoch"), "generation": actor["generation"],
                "last": 0, "upper": None,
            }
            if state["user_id"] != actor["user_id"]:
                raise AppError("FORBIDDEN", "游标不属于当前账号", 403)
            self.validate_epoch(repo, actor, state["epoch"], state["generation"])
            minimum = int(repo.setting("minimum_cursor:" + actor["user_id"]) or 0)
            if state["last"] < minimum:
                raise AppError("CURSOR_EXPIRED", "同步游标已过期，请重新拉取完整快照", 409)
            upper = state.get("upper")
            if upper is None:
                upper = repo.max_sequence(actor["user_id"])
            rows = repo.find("changes", {"user_id": actor["user_id"], "sequence__gt": state["last"],
                                         "sequence__lte": upper}, order=["sequence"], limit=limit + 1)
            more = len(rows) > limit
            rows = rows[:limit]
            last = rows[-1]["sequence"] if rows else upper
            token = self.cursor(repo, actor, last, upper if more else None)
            return {"entities": [json.loads(row["payload"]) for row in rows], "cursor": token, "has_more": more}

    def create_snapshot(self, actor):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            snapshot_id = str(uuid.uuid4())
            sequence = repo.max_sequence(actor["user_id"])
            repo.insert("snapshots", {"id": snapshot_id, "user_id": actor["user_id"],
                                      "generation": actor["generation"], "epoch": repo.setting("sync_epoch"),
                                      "sequence": sequence, "expires_at": (utc_now() + timedelta(hours=2)).isoformat()})
            repo.copy_snapshot(snapshot_id, actor["user_id"])
            return {"snapshot_id": snapshot_id, "cursor": self.cursor(repo, actor, sequence)}

    def snapshot_page(self, actor, snapshot_id, after="", limit=200):
        with self.db.read() as repo:
            snapshot = repo.one("snapshots", {"id": snapshot_id, "user_id": actor["user_id"]})
            if not snapshot or snapshot["expires_at"] <= now_iso():
                raise AppError("CURSOR_EXPIRED", "完整快照已过期，请重新生成", 409)
            self.validate_epoch(repo, actor, snapshot["epoch"], snapshot["generation"])
            rows = repo.find("snapshot_rows", {"snapshot_id": snapshot_id, "entity_id__gt": after},
                             order=["entity_id"], limit=limit + 1)
            more = len(rows) > limit
            rows = rows[:limit]
            return {"entities": [json.loads(row["payload"]) for row in rows],
                    "after": rows[-1]["entity_id"] if rows else after, "has_more": more}

    def list_entities(self, actor, kind=None, start=None, end=None):
        filters = {"user_id": actor["user_id"], "deleted_at": None}
        if kind:
            filters["kind"] = kind
        if start:
            filters["business_date__gte"] = start
        if end:
            filters["business_date__lte"] = end
        with self.db.read() as repo:
            return [decoded_entity(row) for row in repo.find("entities", filters, order=["-business_date", "-updated_at"])]

    def summary(self, user_id, day, repo=None):
        if repo is None:
            with self.db.read() as repository:
                return self.summary(user_id, day, repository)
        profiles = repo.find("entities", {"user_id": user_id, "kind": "profile", "deleted_at": None,
                                          "business_date__lte": day}, order=["-business_date", "-updated_at"], limit=1)
        profile = json.loads(profiles[0]["payload"]) if profiles else {}
        weights = repo.find("entities", {"user_id": user_id, "kind": "weight", "deleted_at": None,
                                         "business_date__lte": day}, order=["-business_date", "-updated_at"], limit=100)
        valid_weights = [row for row in weights if not json.loads(row["payload"]).get("hidden")
                         and not json.loads(row["payload"]).get("source_deleted")]
        latest_day = valid_weights[0]["business_date"] if valid_weights else None
        weight_values = [json.loads(row["payload"]) | {"_record_id": row["id"]} for row in valid_weights if row["business_date"] == latest_day]
        weight = representative(weight_values)
        today_weights = [json.loads(row["payload"]) | {"_record_id": row["id"]} for row in weights if row["business_date"] == day]
        meals = repo.find("entities", {"user_id": user_id, "kind": "meal", "business_date": day, "deleted_at": None})
        health = repo.find("entities", {"user_id": user_id, "kind": "health_day", "business_date": day,
                                        "deleted_at": None}, order=["-updated_at"], limit=1)
        completion = repo.find("entities", {"user_id": user_id, "kind": "daily_status", "business_date": day,
                                            "deleted_at": None}, order=["-updated_at"], limit=1)
        health_value = json.loads(health[0]["payload"]) if health else {}
        completion_value = json.loads(completion[0]["payload"]) if completion else {}
        result = energy_summary(day, profile, weight, [json.loads(row["payload"]) for row in meals], health_value, completion_value)
        result.update({"weight_kg": weight, "has_weight_record": representative(today_weights) is not None,
                       "steps": health_value.get("steps"), "health": health_value,
                       "checked_in": completion_value.get("checked_in", False), "profile": profile})
        return result

    def audit_logs(self, actor):
        with self.db.read() as repo:
            return repo.find("audit", {"user_id": actor["user_id"]}, order=["-created_at"], limit=100)

    def food_search(self, actor, query):
        rows = self.list_entities(actor, "favorite")
        needle = query.casefold().strip()
        return [row for row in rows if needle in row["payload"]["name"].casefold()][:100]

