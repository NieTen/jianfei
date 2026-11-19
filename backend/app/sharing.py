import json
from datetime import date, timezone
from typing import Literal

from pydantic import AwareDatetime, Field, model_validator

from .domain import food_totals
from .errors import AppError
from .models import InputModel
from .records import validate_actor
from .security import now_iso, utc_now


class ShareRequest(InputModel):
    recipient: str | None = Field(default=None, max_length=254)
    scopes: set[Literal["weight", "diet", "meals", "photos", "notes"]] = Field(min_length=1)
    from_day: date
    through_day: date
    expires_at: AwareDatetime
    expected_version: int = Field(ge=0)

    @model_validator(mode="after")
    def valid_window(self):
        if self.from_day > self.through_day or self.expires_at <= utc_now():
            raise ValueError("请选择有效的记录日期范围和未来的授权到期时间")
        return self


class ShareService:
    def __init__(self, database, records, media):
        self.db = database
        self.records = records
        self.media = media

    def describe(self, repo, grant, viewer):
        outgoing = grant["owner_id"] == viewer
        other_id = grant["recipient_id"] if outgoing else grant["owner_id"]
        other = repo.one("users", {"id": other_id})
        return {key: grant[key] for key in ("id", "from_day", "through_day", "expires_at", "version", "revoked_at")} | {
            "scopes": json.loads(grant["scopes"]), "direction": "sent" if outgoing else "received",
            "counterpart": other["display_name"], "active": not grant["revoked_at"] and grant["expires_at"] > now_iso(),
        }

    def listing(self, actor, direction, after):
        with self.db.read() as repo:
            validate_actor(repo, actor)
            key = "owner_id" if direction == "sent" else "recipient_id"
            rows = repo.find("share_grants", {key: actor["user_id"], "id__gt": after}, order=["id"], limit=51)
            return {"items": [self.describe(repo, row, actor["user_id"]) for row in rows[:50]],
                    "next": rows[49]["id"] if len(rows) > 50 else None}

    def save(self, actor, identifier, request):
        owner = actor["user_id"]
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            grant = repo.one("share_grants", {"id": identifier})
            values = {"scopes": json.dumps(sorted(request.scopes)), "from_day": request.from_day.isoformat(),
                      "through_day": request.through_day.isoformat(),
                      "expires_at": request.expires_at.astimezone(timezone.utc).isoformat(), "version": request.expected_version + 1}
            if grant:
                if owner != grant["owner_id"] or grant["revoked_at"]:
                    raise AppError("FORBIDDEN", "无法修改这份授权", 403)
                if request.expected_version == 0 and grant["version"] == 1:
                    # 同一设备提交后丢失回执时，重复提交相同内容可取回原结果。
                    target = repo.one("users", {"id": grant["recipient_id"], "status": "active"})
                    previous_account = (request.recipient or "").strip().lower()
                    if target and previous_account in (target["username"], target["email"]) and all(grant[k] == v for k, v in values.items()):
                        return self.describe(repo, grant, owner)
                if grant["version"] != request.expected_version:
                    raise AppError("VERSION_CONFLICT", "授权已变更，请刷新后重试", 409)
                if request.recipient is not None:
                    raise AppError("INVALID_RECIPIENT", "更换接收人请新建授权")
                repo.update("share_grants", values, {"id": identifier, "owner_id": owner})
            else:
                if request.expected_version != 0:
                    raise AppError("VERSION_CONFLICT", "授权已变更，请刷新后重试", 409)
                account = (request.recipient or "").strip()
                field = "email" if "@" in account else "username"
                user = repo.one("users", {field: account.lower(), "status": "active"})
                if not user or user["id"] == owner:
                    raise AppError("INVALID_RECIPIENT", "请填写其他已注册用户的准确账号")
                repo.insert("share_grants", {**values, "id": identifier, "owner_id": owner, "recipient_id": user["id"]})
            repo.audit(owner, "share_updated" if grant else "share_created", identifier)
            return self.describe(repo, repo.one("share_grants", {"id": identifier}), owner)

    def revoke(self, actor, identifier, version):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            grant = repo.one("share_grants", {"id": identifier, "owner_id": actor["user_id"]})
            if not grant:
                raise AppError("NOT_FOUND", "找不到这份授权", 404)
            if not grant["revoked_at"]:
                if version is not None and version != grant["version"]:
                    raise AppError("VERSION_CONFLICT", "授权已变更，请刷新后重试", 409)
                repo.update("share_grants", {"revoked_at": now_iso(), "version": grant["version"] + 1}, {"id": identifier})
                repo.audit(actor["user_id"], "share_revoked", identifier)
            return {"revoked": True}

    def authorized(self, repo, actor, identifier):
        validate_actor(repo, actor)
        grant = repo.one("share_grants", {"id": identifier, "recipient_id": actor["user_id"],
                                         "revoked_at": None, "expires_at__gt": now_iso()})
        if not grant or not repo.one("users", {"id": grant["owner_id"], "status": "active"}):
            raise AppError("CONSENT_REVOKED", "这份共享已失效或未向当前账号授权", 403)
        return grant

    @staticmethod
    def check_day(grant, day):
        if not grant["from_day"] <= day <= grant["through_day"]:
            raise AppError("FORBIDDEN", "该日期不在共享范围内", 403)

    def summary(self, actor, identifier, day):
        with self.db.read(snapshot=True) as repo:
            grant = self.authorized(repo, actor, identifier)
            self.check_day(grant, day)
            owner, scopes = grant["owner_id"], json.loads(grant["scopes"])
            result = {"date": day, "expires_at": grant["expires_at"], "version": grant["version"], "server_time": now_iso()}
            if "weight" in scopes or "diet" in scopes:
                summary = self.records.summary(owner, day, repo)
                if "weight" in scopes:
                    # 防止最近一次体重来自授权历史起点之前或缺测日。
                    result["weight_kg"] = summary["weight_kg"] if summary["has_weight_record"] else None
                if "diet" in scopes:
                    result["diet"] = {key: summary[key] for key in ("intake_kcal", "intake_complete", "unrecorded_meals")}
            if {"meals", "notes", "photos"}.intersection(scopes):
                result["meals"] = []
                for row in repo.find("entities", {"user_id": owner, "kind": "meal", "deleted_at": None, "business_date": day},
                                     order=["id"]):
                    meal = json.loads(row["payload"])
                    shared = {"meal_type": meal["meal_type"]}
                    if "meals" in scopes:
                        shared["status"] = meal["status"]
                        shared["items"] = [{"name": item["name"], "amount": item["amount"], "unit": item["unit"],
                                            "nutrition": food_totals(item)} for item in meal["items"]]
                    if "notes" in scopes:
                        shared["note"] = meal.get("note", "")
                    if "photos" in scopes:
                        ready = repo.find("media", {"user_id": owner, "meal_id": row["id"], "temporary": 0,
                                                    "status": "ready", "id__in": meal.get("photo_ids", [])}, limit=6)
                        found = {photo["id"] for photo in ready}
                        shared["photo_ids"] = [photo for photo in meal.get("photo_ids", []) if photo in found]
                    result["meals"].append(shared)
            if grant["expires_at"] <= now_iso():
                raise AppError("CONSENT_REVOKED", "这份共享已到期", 403)
            return result

    def photo(self, actor, identifier, media_id, thumbnail):
        with self.db.read(snapshot=True) as repo:
            grant = self.authorized(repo, actor, identifier)
            photo = repo.one("media", {"id": self.media.safe_id(media_id), "user_id": grant["owner_id"],
                                       "status": "ready", "temporary": 0})
            meal = repo.one("entities", {"id": photo["meal_id"], "user_id": grant["owner_id"], "kind": "meal",
                                         "deleted_at": None}) if photo else None
            if "photos" not in json.loads(grant["scopes"]) or not meal or media_id not in json.loads(meal["payload"]).get("photo_ids", []):
                raise AppError("FORBIDDEN", "没有这张照片的共享授权", 403)
            self.check_day(grant, meal["business_date"])
            path = self.media.path(media_id, thumbnail)
            if not path.exists():
                raise AppError("ATTACHMENT_PENDING", "照片暂不可用", 409, True)
            return path
