import json
import secrets
import sqlite3
import uuid
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .domain import business_day, day_window, representative
from .errors import AppError
from .records import validate_actor
from .security import now_iso, token_hash, utc_now


class ChallengeService:
    def __init__(self, database, records):
        self.db = database
        self.records = records

    def require_member(self, repo, user_id, challenge_id):
        member = repo.one("members", {"challenge_id": challenge_id, "user_id": user_id, "status": "active"})
        challenge = repo.one("challenges", {"id": challenge_id})
        if member is None or challenge is None:
            raise AppError("FORBIDDEN", "你没有访问这个挑战的权限", 403)
        return challenge, member

    def issue_invite(self, repo, challenge_id):
        code = secrets.token_urlsafe(18)
        repo.insert("invites", {"id": str(uuid.uuid4()), "challenge_id": challenge_id,
                               "code_hash": token_hash(code), "expires_at": (utc_now() + timedelta(hours=24)).isoformat()})
        return code

    def create(self, actor, request):
        try:
            ZoneInfo(request.timezone)
        except Exception:
            raise AppError("VALIDATION_FAILED", "统计时区无效")
        challenge_id, pair_id = str(uuid.uuid4()), str(uuid.uuid4())
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            if repo.one("active_members", {"user_id": actor["user_id"]}):
                raise AppError("ACTIVE_CHALLENGE_EXISTS", "请先结束当前挑战", 409)
            repo.insert("pairs", {"id": pair_id, "status": "active", "created_at": now_iso()})
            repo.insert("challenges", {
                "id": challenge_id, "owner_id": actor["user_id"], "pair_id": pair_id,
                "title": request.title, "status": "pending", "timezone": request.timezone,
                "day_start_minutes": request.day_start_minutes, "duration_days": request.duration_days,
                "max_members": request.max_members, "rules_version": "PK_RULE_V1", "created_at": now_iso(),
            })
            self.add_member(repo, challenge_id, actor["user_id"], request.goal.model_dump())
            code = self.issue_invite(repo, challenge_id)
            repo.audit(actor["user_id"], "challenge_created", challenge_id)
            return {"id": challenge_id, "invite_code": code, "version": 1}

    def add_member(self, repo, challenge_id, user_id, goal):
        repo.insert("active_members", {"user_id": user_id, "challenge_id": challenge_id})
        repo.insert("members", {"challenge_id": challenge_id, "user_id": user_id, "status": "active",
                               "goal": json.dumps(goal, ensure_ascii=False), "joined_at": now_iso()})

    def join(self, actor, request):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            invite = repo.one("invites", {"code_hash": token_hash(request.code), "revoked": 0, "used_by": None})
            if not invite or invite["expires_at"] <= now_iso():
                raise AppError("INVALID_INVITE", "邀请已过期或已使用", 409)
            challenge = repo.one("challenges", {"id": invite["challenge_id"]})
            members = repo.find("members", {"challenge_id": challenge["id"], "status": "active"})
            if challenge["status"] != "pending" or len(members) >= challenge["max_members"]:
                raise AppError("CHALLENGE_FULL", "挑战已经开始或成员已满", 409)
            if repo.one("active_members", {"user_id": actor["user_id"]}):
                raise AppError("ACTIVE_CHALLENGE_EXISTS", "请先结束当前挑战", 409)
            self.add_member(repo, challenge["id"], actor["user_id"], request.goal.model_dump())
            repo.update("invites", {"used_by": actor["user_id"]}, {"id": invite["id"]})
            repo.audit(actor["user_id"], "challenge_joined", challenge["id"])
            return {"id": challenge["id"], "version": challenge["version"]}

    def invitation(self, actor, challenge_id):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            challenge, _ = self.require_member(repo, actor["user_id"], challenge_id)
            if challenge["status"] != "pending":
                raise AppError("CHALLENGE_STARTED", "开始后不能新增成员", 409)
            return {"invite_code": self.issue_invite(repo, challenge_id)}

    def preview_invite(self, actor, code):
        with self.db.read() as repo:
            invite = repo.one("invites", {"code_hash": token_hash(code), "used_by": None, "revoked": 0})
            if not invite or invite["expires_at"] <= now_iso():
                raise AppError("INVALID_INVITE", "邀请已过期或已使用", 409)
            challenge = repo.one("challenges", {"id": invite["challenge_id"]})
            owner = repo.one("users", {"id": challenge["owner_id"]})
            return {"title": challenge["title"], "owner_name": owner["display_name"], "timezone": challenge["timezone"],
                    "duration_days": challenge["duration_days"], "max_members": challenge["max_members"],
                    "day_start_minutes": challenge["day_start_minutes"], "rules_version": challenge["rules_version"]}

    def confirm(self, actor, challenge_id, version):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            challenge, _ = self.require_member(repo, actor["user_id"], challenge_id)
            if challenge["version"] != version or challenge["status"] != "pending":
                raise AppError("VERSION_CONFLICT", "挑战状态或规则已变化，请刷新", 409)
            repo.update("members", {"confirmed": 1}, {"challenge_id": challenge_id, "user_id": actor["user_id"]})
            members = repo.find("members", {"challenge_id": challenge_id, "status": "active"})
            if len(members) == challenge["max_members"] and all(member["confirmed"] for member in members):
                today = business_day(utc_now(), challenge["timezone"], challenge["day_start_minutes"])
                _, start = day_window(today, challenge["timezone"], challenge["day_start_minutes"])
                end_date = date.fromisoformat(today) + timedelta(days=challenge["duration_days"] + 1)
                end, _ = day_window(end_date, challenge["timezone"], challenge["day_start_minutes"])
                repo.update("challenges", {"status": "scheduled", "start_at": start.isoformat(), "end_at": end.isoformat()},
                            {"id": challenge_id})
                repo.update("invites", {"revoked": 1}, {"challenge_id": challenge_id})
            return {"confirmed": True}

    def list(self, actor):
        with self.db.read() as repo:
            memberships = repo.find("members", {"user_id": actor["user_id"]}, order=["-joined_at"])
            results = []
            for membership in memberships:
                challenge = repo.one("challenges", {"id": membership["challenge_id"]})
                if challenge:
                    results.append(self.public_challenge(repo, challenge, actor["user_id"]))
            return results

    def public_challenge(self, repo, challenge, viewer):
        members = repo.find("members", {"challenge_id": challenge["id"]})
        result = dict(challenge)
        result["pause_periods"] = json.loads(result["pause_periods"])
        result["members"] = []
        for member in members:
            user = repo.one("users", {"id": member["user_id"]})
            value = {
                "user_id": member["user_id"], "display_name": user["display_name"] if user and user["status"] == "active" else "已退出用户",
                "status": member["status"], "confirmed": bool(member["confirmed"]),
                "resume_confirmed": bool(member["resume_confirmed"]),
            }
            if member["user_id"] == viewer:
                value["goal"] = json.loads(member["goal"])
                value["baseline"] = json.loads(member["baseline"]) if member["baseline"] else None
            result["members"].append(value)
        return result

    def get(self, actor, challenge_id):
        with self.db.read() as repo:
            challenge, _ = self.require_member(repo, actor["user_id"], challenge_id)
            return self.public_challenge(repo, challenge, actor["user_id"])

    def consent(self, actor, challenge_id, request):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            challenge, _ = self.require_member(repo, actor["user_id"], challenge_id)
            self.require_member(repo, request.recipient_id, challenge_id)
            if request.recipient_id == actor["user_id"]:
                raise AppError("VALIDATION_FAILED", "请选择其他成员")
            earliest = business_day(datetime.fromisoformat(challenge["start_at"]), challenge["timezone"],
                                    challenge["day_start_minutes"]) if challenge["start_at"] else business_day(utc_now(), challenge["timezone"])
            date.fromisoformat(request.history_from)
            if request.history_from < earliest:
                raise AppError("INVALID_HISTORY_RANGE", "历史共享范围不能早于本次挑战")
            key = {"challenge_id": challenge_id, "owner_id": actor["user_id"], "recipient_id": request.recipient_id}
            old = repo.one("consents", key)
            if (old["version"] if old else 0) != request.expected_version:
                raise AppError("VERSION_CONFLICT", "共享授权已在另一设备修改，请刷新", 409)
            values = {**key, "scopes": json.dumps(sorted(set(request.scopes))), "history_from": request.history_from,
                      "version": request.expected_version + 1, "revoked_at": None if request.scopes else now_iso(),
                      "updated_at": now_iso()}
            if old:
                repo.update("consents", values, key)
            else:
                repo.insert("consents", values)
            repo.audit(actor["user_id"], "consent_changed", challenge_id)
            if not request.scopes:
                repo.insert("deletion_ledger", {"id": str(uuid.uuid4()), "user_id": actor["user_id"],
                                               "action": "consent", "target_id": challenge_id, "created_at": now_iso()})
            return {**values, "scopes": request.scopes}

    def consents(self, actor, challenge_id):
        with self.db.read() as repo:
            self.require_member(repo, actor["user_id"], challenge_id)
            rows = repo.find("consents", {"challenge_id": challenge_id, "owner_id": actor["user_id"]})
            return [{**row, "scopes": json.loads(row["scopes"])} for row in rows]

    def revoke_all(self, repo, challenge_id):
        repo.update("consents", {"scopes": "[]", "revoked_at": now_iso(), "updated_at": now_iso()}, {"challenge_id": challenge_id})
        repo.update("invites", {"revoked": 1}, {"challenge_id": challenge_id})

    def leave(self, actor, challenge_id):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            challenge, _ = self.require_member(repo, actor["user_id"], challenge_id)
            repo.update("challenges", {"status": "ended_early", "finalized_at": now_iso()}, {"id": challenge_id})
            self.revoke_all(repo, challenge_id)
            repo.delete("active_members", {"challenge_id": challenge_id})
            repo.update("members", {"status": "left"}, {"challenge_id": challenge_id, "user_id": actor["user_id"]})
            repo.audit(actor["user_id"], "challenge_left", challenge_id)
        return {"ended": True}

    def unpair(self, actor, pair_id):
        with self.db.read() as repo:
            challenges = repo.find("challenges", {"pair_id": pair_id})
            accessible = [row for row in challenges if repo.one("members", {"challenge_id": row["id"], "user_id": actor["user_id"]})]
        if not accessible:
            raise AppError("FORBIDDEN", "无权解除该关系", 403)
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            repo.update("pairs", {"status": "unpaired"}, {"id": pair_id})
            for challenge in accessible:
                self.revoke_all(repo, challenge["id"])
                repo.delete("active_members", {"challenge_id": challenge["id"]})
                if challenge["status"] not in ("finished", "ended_early"):
                    repo.update("challenges", {"status": "ended_early", "finalized_at": now_iso()}, {"id": challenge["id"]})
        return {"unpaired": True}

    def pause(self, actor, challenge_id):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            challenge, _ = self.require_member(repo, actor["user_id"], challenge_id)
            if challenge["status"] != "active":
                raise AppError("INVALID_STATE", "当前挑战不能暂停", 409)
            today = business_day(utc_now(), challenge["timezone"], challenge["day_start_minutes"])
            _, next_start = day_window(today, challenge["timezone"], challenge["day_start_minutes"])
            periods = json.loads(challenge["pause_periods"])
            periods.append({"start": next_start.isoformat(), "end": None})
            repo.update("challenges", {"status": "paused", "paused_at": now_iso(), "pause_periods": json.dumps(periods)}, {"id": challenge_id})
            repo.update("members", {"resume_confirmed": 0}, {"challenge_id": challenge_id})
        return {"paused": True}

    def resume(self, actor, challenge_id):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            challenge, _ = self.require_member(repo, actor["user_id"], challenge_id)
            if challenge["status"] != "paused":
                raise AppError("INVALID_STATE", "当前挑战未暂停", 409)
            repo.update("members", {"resume_confirmed": 1}, {"challenge_id": challenge_id, "user_id": actor["user_id"]})
            members = repo.find("members", {"challenge_id": challenge_id, "status": "active"})
            if all(member["resume_confirmed"] for member in members):
                today = business_day(utc_now(), challenge["timezone"], challenge["day_start_minutes"])
                _, boundary = day_window(today, challenge["timezone"], challenge["day_start_minutes"])
                periods = json.loads(challenge["pause_periods"])
                periods[-1]["end"] = boundary.isoformat()
                repo.update("challenges", {"status": "active", "paused_at": None, "pause_periods": json.dumps(periods)}, {"id": challenge_id})
        return {"confirmed": True}

    def is_paused_day(self, challenge, start):
        for period in json.loads(challenge["pause_periods"]):
            if start >= datetime.fromisoformat(period["start"]) and (
                period["end"] is None or start < datetime.fromisoformat(period["end"])
            ):
                return True
        return False

    def recalculate_user(self, user_id, day):
        with self.db.transaction() as repo:
            active = repo.one("active_members", {"user_id": user_id})
            if active:
                self.recalculate(repo, active["challenge_id"], user_id, day)

    def recalculate(self, repo, challenge_id, user_id, day, closing=False):
        challenge = repo.one("challenges", {"id": challenge_id})
        if not challenge["start_at"] or challenge["status"] in ("finished", "ended_early", "pending", "scheduled"):
            return
        start, end = day_window(day, challenge["timezone"], challenge["day_start_minutes"])
        if start < datetime.fromisoformat(challenge["start_at"]) or start >= datetime.fromisoformat(challenge["end_at"]):
            return
        if start > utc_now() or self.is_paused_day(challenge, start):
            return
        old = repo.one("scores", {"challenge_id": challenge_id, "user_id": user_id, "business_date": day})
        if utc_now() > end + timedelta(hours=72) and not closing:
            return
        if closing and old:
            return
        member = repo.one("members", {"challenge_id": challenge_id, "user_id": user_id})
        goal = json.loads(member["goal"])
        summary = self.records.summary(user_id, day, repo)
        values = {
            "diet": bool(summary["intake_complete"]), "weight": bool(summary["has_weight_record"]),
            "steps": summary["steps"] is not None and summary["steps"] >= goal["step_goal"],
        }
        selected = goal.get("selected_items", ["diet", "weight", "steps"])
        value = {"items": {key: values[key] for key in selected}, "points": sum(int(values[key]) for key in selected),
                 "max_points": len(selected), "rule": "PK_RULE_V1"}
        raw = json.dumps(value, sort_keys=True)
        if old and old["payload"] == raw:
            return
        key = {"challenge_id": challenge_id, "user_id": user_id, "business_date": day}
        if old:
            repo.update("scores", {"payload": raw, "updated_at": now_iso()}, key)
        else:
            repo.insert("scores", {**key, "payload": raw, "updated_at": now_iso()})
        repo.insert("score_events", {"id": str(uuid.uuid4()), **key, "before_value": old["payload"] if old else "{}",
                                     "after_value": raw, "created_at": now_iso()})

    def tick(self):
        with self.db.transaction() as repo:
            challenges = repo.find("challenges", {"status__in": ["scheduled", "active", "paused", "settling"]})
            for challenge in challenges:
                if challenge["status"] == "scheduled" and challenge["start_at"] <= now_iso():
                    repo.update("challenges", {"status": "active"}, {"id": challenge["id"]})
                    for member in repo.find("members", {"challenge_id": challenge["id"]}):
                        start_date = business_day(datetime.fromisoformat(challenge["start_at"]), challenge["timezone"], challenge["day_start_minutes"])
                        earliest = (date.fromisoformat(start_date) - timedelta(days=7)).isoformat()
                        rows = repo.find("entities", {"user_id": member["user_id"], "kind": "weight", "deleted_at": None,
                                                      "business_date__gte": earliest, "business_date__lte": start_date}, order=["-business_date"])
                        valid_rows = [row for row in rows
                                      if datetime.fromisoformat(json.loads(row["payload"])["measured_at"].replace("Z", "+00:00"))
                                      <= datetime.fromisoformat(challenge["start_at"])
                                      and not json.loads(row["payload"]).get("hidden")
                                      and not json.loads(row["payload"]).get("source_deleted")]
                        latest_day = valid_rows[0]["business_date"] if valid_rows else None
                        samples = [json.loads(row["payload"]) for row in valid_rows if row["business_date"] == latest_day]
                        baseline = representative(samples)
                        repo.update("members", {"baseline": json.dumps({"weight_kg": baseline, "frozen_at": now_iso()})},
                                    {"challenge_id": challenge["id"], "user_id": member["user_id"]})
                if challenge["end_at"] and challenge["end_at"] <= now_iso():
                    if challenge["status"] != "settling":
                        repo.update("challenges", {"status": "settling"}, {"id": challenge["id"]})
                    if utc_now() >= datetime.fromisoformat(challenge["end_at"]) + timedelta(hours=72):
                        final_day = business_day(datetime.fromisoformat(challenge["end_at"]) - timedelta(seconds=1),
                                                 challenge["timezone"], challenge["day_start_minutes"])
                        for member in repo.find("members", {"challenge_id": challenge["id"], "status": "active"}):
                            summary = self.records.summary(member["user_id"], final_day, repo)
                            baseline = json.loads(member["baseline"] or "{}")
                            baseline.update(final_weight_kg=summary["weight_kg"], final_day=final_day)
                            repo.update("members", {"baseline": json.dumps(baseline)},
                                        {"challenge_id": challenge["id"], "user_id": member["user_id"]})
                        repo.update("challenges", {"status": "finished", "finalized_at": now_iso()}, {"id": challenge["id"]})
                        repo.delete("active_members", {"challenge_id": challenge["id"]})

    def summary(self, actor, challenge_id, day):
        with self.db.read() as repo:
            challenge, _ = self.require_member(repo, actor["user_id"], challenge_id)
            result = {"challenge": self.public_challenge(repo, challenge, actor["user_id"]),
                      "members": [], "cached_until": (utc_now() + timedelta(hours=24)).isoformat(), "server_time": now_iso()}
            for member in repo.find("members", {"challenge_id": challenge_id, "status": "active"}):
                user_id = member["user_id"]
                user = repo.one("users", {"id": user_id})
                projection = {"user_id": user_id, "display_name": user["display_name"], "scopes": [], "consent_version": 0}
                own = user_id == actor["user_id"]
                consent = repo.one("consents", {"challenge_id": challenge_id, "owner_id": user_id,
                                               "recipient_id": actor["user_id"], "revoked_at": None})
                scopes = ["checkin", "goal_progress", "weight_change", "steps", "weight", "meals", "photos", "notes", "score", "streak", "health", "profile"] if own else json.loads(consent["scopes"]) if consent else []
                window_start, _ = day_window(day, challenge["timezone"], challenge["day_start_minutes"])
                allowed_period = bool(challenge["start_at"] and challenge["end_at"])
                if allowed_period:
                    allowed_period = (
                        datetime.fromisoformat(challenge["start_at"]) <= window_start < datetime.fromisoformat(challenge["end_at"])
                        and utc_now() >= datetime.fromisoformat(challenge["start_at"])
                    )
                if not own and not allowed_period:
                    result["members"].append(projection)
                    continue
                if not own and (not consent or day < consent["history_from"]):
                    result["members"].append(projection)
                    continue
                projection["scopes"] = scopes
                projection["consent_version"] = consent["version"] if consent else 0
                summary = self.records.summary(user_id, day, repo)
                goal = json.loads(member["goal"])
                baseline = json.loads(member["baseline"]) if member["baseline"] else {}
                initial, current, target = baseline.get("weight_kg"), summary["weight_kg"], goal.get("target_weight_kg")
                progress_weight = current
                if challenge["status"] == "finished" and day >= baseline.get("final_day", day):
                    progress_weight = baseline.get("final_weight_kg")
                if "checkin" in scopes:
                    projection["checked_in"] = summary["checked_in"] or summary["intake_complete"]
                    projection["intake_complete"] = summary["intake_complete"]
                if "weight" in scopes:
                    projection["weight_kg"] = current
                    projection["has_weight_record"] = summary["has_weight_record"]
                if "steps" in scopes:
                    projection["steps"] = summary["steps"]
                if "weight_change" in scopes:
                    projection["weight_change_percent"] = (progress_weight - initial) / initial * 100 if initial and progress_weight else None
                if "goal_progress" in scopes:
                    projection["goal_progress"] = (initial - progress_weight) / (initial - target) * 100 if initial and progress_weight and target and target < initial else None
                projection["result_frozen"] = challenge["status"] == "finished"
                if "health" in scopes:
                    projection["health"] = summary["health"]
                if "profile" in scopes:
                    projection["profile"] = summary["profile"]
                if "meals" in scopes:
                    meals = repo.find("entities", {"user_id": user_id, "kind": "meal", "business_date": day, "deleted_at": None})
                    projection["meals"] = []
                    for row in meals:
                        meal = json.loads(row["payload"])
                        if not own:
                            meal["ai_result"] = None
                            meal["ai_task_id"] = None
                        if "notes" not in scopes:
                            meal["note"] = ""
                            for item in meal["items"]:
                                item["uncertainty_note"] = ""
                        if "photos" not in scopes:
                            meal["photo_ids"] = []
                            meal["ai_result"] = None
                            for item in meal["items"]:
                                item["evidence_photo_ids"] = []
                        projection["meals"].append({"id": row["id"], **meal})
                if "score" in scopes or "streak" in scopes:
                    score_rows = repo.find("scores", {"challenge_id": challenge_id, "user_id": user_id,
                                                      "business_date__lte": day}, order=["business_date"])
                    visible = [row for row in score_rows if own or row["business_date"] >= consent["history_from"]]
                    if "score" in scopes:
                        projection["score"] = sum(json.loads(row["payload"])["points"] for row in visible)
                        projection["selected_items"] = goal["selected_items"]
                    if "streak" in scopes:
                        projection["streak"] = self.streak(challenge, visible, day)
                result["members"].append(projection)
            return result

    def streak(self, challenge, rows, day):
        if not challenge["start_at"]:
            return 0
        values = {row["business_date"]: json.loads(row["payload"])["points"] for row in rows}
        count = 0
        current = date.fromisoformat(day)
        earliest = date.fromisoformat(business_day(datetime.fromisoformat(challenge["start_at"]), challenge["timezone"], challenge["day_start_minutes"]))
        while current >= earliest:
            start, _ = day_window(current, challenge["timezone"], challenge["day_start_minutes"])
            if not self.is_paused_day(challenge, start):
                if values.get(current.isoformat(), 0) == 0:
                    break
                count += 1
            current -= timedelta(days=1)
        return count

    def encourage(self, actor, challenge_id, request):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            challenge, _ = self.require_member(repo, actor["user_id"], challenge_id)
            if challenge["status"] in ("ended_early", "finished"):
                raise AppError("INVALID_STATE", "挑战已结束", 409)
            old = repo.one("encouragements", {"id": request.id})
            if old:
                if old["sender_id"] != actor["user_id"] or old["challenge_id"] != challenge_id or old["message"] != request.message:
                    raise AppError("IDEMPOTENCY_CONFLICT", "留言标识冲突", 409)
                return old
            value = {"id": request.id, "challenge_id": challenge_id, "sender_id": actor["user_id"],
                     "message": request.message, "created_at": now_iso()}
            repo.insert("encouragements", value)
            for member in repo.find("members", {"challenge_id": challenge_id, "status": "active"}):
                if member["user_id"] != actor["user_id"]:
                    repo.insert("notifications", {"id": str(uuid.uuid4()), "user_id": member["user_id"],
                                                   "payload": json.dumps({"challenge_id": challenge_id, "message": "伙伴发来了一条鼓励"}),
                                                   "status": "pending", "created_at": now_iso()})
            return value

    def messages(self, actor, challenge_id):
        with self.db.read() as repo:
            self.require_member(repo, actor["user_id"], challenge_id)
            return repo.find("encouragements", {"challenge_id": challenge_id, "deleted_at": None},
                             order=["-created_at"], limit=100)

    def delete_message(self, actor, challenge_id, message_id):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            self.require_member(repo, actor["user_id"], challenge_id)
            repo.update("encouragements", {"deleted_at": now_iso()},
                        {"id": message_id, "challenge_id": challenge_id, "sender_id": actor["user_id"]})
        return {"deleted": True}

