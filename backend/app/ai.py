import base64
import json
import uuid
from datetime import timedelta
from pathlib import Path
from urllib.parse import urlsplit

import httpx
from pydantic import ValidationError

from .errors import AppError
from .models import AIRecognitionOutput, FoodPayload
from .records import validate_actor
from .security import now_iso, utc_now


class AIService:
    def __init__(self, database, settings, media, providers):
        self.db = database
        self.settings = settings
        self.media = media
        self.providers = providers
        self.schema = json.loads((Path(__file__).parent / "resources" / "food_schema.json").read_text(encoding="utf-8"))

    def create(self, actor, request):
        configuration = self.providers.configuration(actor["user_id"])
        if not configuration["base_url"]:
            raise AppError("PROVIDER_UNAVAILABLE", "服务器尚未配置 AI 服务，可使用本机识别或手动记录", 503, True)
        if configuration["external"] and not request.allow_external:
            raise AppError("EXTERNAL_CONSENT_REQUIRED", "请先同意将照片发送给配置的外部 AI 服务", 403)
        if configuration["protocol"] != "generic" and not configuration["model"]:
            raise AppError("AI_MODEL_REQUIRED", "请先在 AI 设置中选择或填写模型")
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            old = repo.one("tasks", {"user_id": actor["user_id"], "kind": "recognition", "request_key": request.request_key})
            if old:
                prior_request = {key: value for key, value in json.loads(old["payload"]).items() if not key.startswith("_")}
                if prior_request != request.model_dump():
                    raise AppError("IDEMPOTENCY_CONFLICT", "识别请求标识已用于其他内容", 409)
                return self.public_task(old)
            for photo_id in request.photo_ids:
                if not repo.one("media", {"id": self.media.safe_id(photo_id), "user_id": actor["user_id"], "status": "ready"}):
                    raise AppError("ATTACHMENT_PENDING", "照片还没有上传完成", 409, True)
            task_payload = request.model_dump()
            task_payload["_provider_snapshot"] = self.providers.seal(configuration)
            task = {
                "id": str(uuid.uuid4()), "user_id": actor["user_id"], "kind": "recognition",
                "status": "pending", "request_key": request.request_key,
                "payload": json.dumps(task_payload, ensure_ascii=False),
                "created_at": now_iso(), "updated_at": now_iso(),
            }
            repo.insert("tasks", task)
            return self.public_task(task)

    def public_task(self, task):
        return {
            "id": task["id"], "kind": task["kind"], "status": task["status"],
            "result": json.loads(task["result"]) if task.get("result") else None,
            "error": task.get("error"), "created_at": task["created_at"], "updated_at": task["updated_at"],
        }

    def task(self, actor, task_id):
        with self.db.read() as repo:
            task = repo.one("tasks", {"id": task_id, "user_id": actor["user_id"]})
            if not task:
                raise AppError("NOT_FOUND", "任务不存在", 404)
            return self.public_task(task)

    def cancel(self, actor, task_id):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            task = repo.one("tasks", {"id": task_id, "user_id": actor["user_id"]})
            if not task:
                raise AppError("NOT_FOUND", "任务不存在", 404)
            payload = json.loads(task["payload"])
            payload.pop("_provider_snapshot", None)
            repo.update("tasks", {"status": "cancelled", "payload": json.dumps(payload), "updated_at": now_iso()}, {"id": task_id})
        return {"cancelled": True}

    async def process(self, task):
        request = json.loads(task["payload"])
        if "_provider_snapshot" not in request:
            raise AppError("PROVIDER_CHANGED", "识别配置已更新，请重新提交任务", 409)
        configuration = self.providers.unseal(request["_provider_snapshot"])
        current = self.providers.configuration(task["user_id"])
        if current["version"] != configuration["version"] or current["base_url"] != configuration["base_url"]:
            raise AppError("PROVIDER_CHANGED", "AI 配置已变化，请重新提交任务", 409)
        self.providers.validate_destination(configuration["base_url"])
        with self.db.read() as repo:
            active_user = repo.one("users", {"id": task["user_id"], "status": "active"})
            latest_task = repo.one("tasks", {"id": task["id"]})
        if not active_user or not latest_task or latest_task["status"] == "cancelled":
            raise AppError("TASK_CANCELLED", "账号或任务状态已变化，识别已停止", 409)
        images = [self.media.ai_image(task["user_id"], image_id) for image_id in request["photo_ids"]]
        headers = {"Idempotency-Key": task["request_key"]}
        if configuration["api_key"]:
            headers["Authorization"] = "Bearer " + configuration["api_key"]
        prompt = self.schema["description"] + "\n照片标识依次为 " + json.dumps(request["photo_ids"], ensure_ascii=False)
        prompt += "。用户说明 " + json.dumps(request.get("note", ""), ensure_ascii=False)
        async with httpx.AsyncClient(timeout=180, follow_redirects=False, trust_env=False) as client:
            for attempt in range(2):
                # 补全前重新核对任务与配置，取消或更换服务后不继续发送照片。
                with self.db.read() as repo:
                    latest = repo.one("tasks", {"id": task["id"]})
                    user = repo.one("users", {"id": task["user_id"], "status": "active"})
                current = self.providers.configuration(task["user_id"])
                if not user or not latest or latest["status"] == "cancelled":
                    raise AppError("TASK_CANCELLED", "账号或任务状态已变化，识别已停止", 409)
                if current["version"] != configuration["version"] or current["base_url"] != configuration["base_url"]:
                    raise AppError("PROVIDER_CHANGED", "AI 配置已变化，请重新提交任务", 409)
                body, url = self.recognition_request(configuration, task, request, images, prompt)
                # 补全是不同请求，不能复用首次响应的幂等缓存。
                headers["Idempotency-Key"] = task["request_key"] + (":nutrition" if attempt else "")
                if configuration["protocol"] == "generic":
                    body["request_id"] = headers["Idempotency-Key"]
                response = await client.post(url, headers=headers, json=body)
                self.providers.check_response(response)
                raw = response.json()
                if configuration["protocol"] == "generic":
                    output = raw
                elif configuration["protocol"] == "chat_completions":
                    output = json.loads(raw["choices"][0]["message"]["content"])
                else:
                    output = self.parse_responses_output(raw)
                try:
                    validated = AIRecognitionOutput.model_validate(output).model_dump()
                except ValidationError as error:
                    if attempt:
                        raise AppError("INVALID_AI_OUTPUT", "模型自动补全后返回的份量或营养数据仍无效，请重试或更换模型") from error
                    problem = "份量或营养字段格式无效，必须使用约定字段名和有效 JSON 数值"
                else:
                    output = validated
                    fields = ("estimated_weight_g", "calories_kcal", "protein_g", "carbs_g", "fat_g")
                    missing = [f"{index + 1}.{field}" for index, item in enumerate(output["items"])
                               for field in fields if item[field] is None]
                    if not missing:
                        break
                    if attempt:
                        raise AppError("AI_NUTRITION_INCOMPLETE", "AI 自动补全后仍未提供完整份量与营养，请重试或更换支持图像营养估算的模型")
                    problem = "缺少 " + "、".join(missing)
                prompt += ("\n上次结果" + problem + "。请结合原照片补全并返回整餐完整 JSON，"
                           "不要只返回缺失字段，不要删除已识别的食物。对缺少份量的食物估算常见份量，并核对全部营养与份量一致。"
                           "上次结果：" + json.dumps(output, ensure_ascii=False)[:16000])
        items = []
        with self.db.read() as repo:
            preferences = repo.find("entities", {"user_id": task["user_id"], "kind": "food_preference", "deleted_at": None})
        preference_map = {json.loads(row["payload"])["food_name"].casefold(): json.loads(row["payload"]) for row in preferences}
        for item in output["items"]:
            amount = item["estimated_weight_g"]
            preference = preference_map.get(item["name"].casefold(), {})
            weight_multiplier = preference.get("weight_multiplier", 1)
            calorie_multiplier = preference.get("calorie_multiplier", 1)
            note = "份量、热量及营养为 AI 估算，可直接保存，也可按实际食用量调整。"
            if output.get("uncertainty_note"):
                note += " " + output["uncertainty_note"]
            food = FoodPayload(
                id=str(uuid.uuid4()), name=item["name"], amount=amount * weight_multiplier,
                basis_amount=amount, nutrition_basis="total", unit="g",
                basis_kcal=item["calories_kcal"] * calorie_multiplier,
                basis_protein_g=item["protein_g"], basis_carbs_g=item["carbs_g"], basis_fat_g=item["fat_g"],
                source="ai_estimate", confidence=item.get("confidence"), uncertainty_note=note,
                food_state=item.get("food_state", "unknown"),
                evidence_photo_ids=[value for value in item.get("evidence_photo_ids", []) if value in request["photo_ids"]],
                requires_portion=False,
            )
            items.append(food.model_dump())
        return {
            "items": items, "raw_result": output, "meal_id": request["meal_id"], "meal_version": request["meal_version"],
            "photo_ids": request["photo_ids"], "model_name": configuration["model"] or "generic",
            "model_version": raw.get("model", configuration["model"] or "unspecified"),
            "needs_user_confirmation": True, "uncertainty_note": output.get("uncertainty_note", "请核对实际食用份量"),
        }

    def recognition_request(self, configuration, task, request, images, prompt):
        protocol = configuration["protocol"]
        if protocol == "generic":
            body = {"request_id": task["request_key"], "images": [base64.b64encode(value).decode() for value in images],
                    "photo_ids": request["photo_ids"], "prompt": prompt}
            url = configuration["base_url"]
        elif protocol == "chat_completions":
            content = [{"type": "text", "text": prompt}]
            content += [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(value).decode()}} for value in images]
            body = {"model": configuration["model"], "messages": [{"role": "user", "content": content}],
                    "temperature": 0.2, "response_format": {"type": "json_object"}}
            url = configuration["base_url"] + "/chat/completions"
        else:
            content = [{"type": "input_text", "text": prompt}]
            content += [{"type": "input_image", "image_url": "data:image/jpeg;base64," + base64.b64encode(value).decode(),
                         "detail": "auto"} for value in images]
            output_format = {"type": "json_schema", "name": "food_recognition", "strict": True, "schema": self.schema}
            if not configuration["structured_output"]:
                output_format = {"type": "json_object"}
            body = {"model": configuration["model"], "input": [{"role": "user", "content": content}],
                    "text": {"format": output_format}, "store": False,
                    "max_output_tokens": configuration.get("max_output_tokens", 4096)}
            from .providers import normalized_ai_url
            url = normalized_ai_url(configuration["base_url"]) + "/responses"
        return body, url

    def parse_responses_output(self, response):
        if response.get("status") not in (None, "completed"):
            raise AppError("AI_RESPONSE_INCOMPLETE", "模型响应未完成，请调整输出设置后重试")
        texts = []
        for message in response.get("output", []):
            if message.get("type") != "message":
                continue
            for content in message.get("content", []):
                if content.get("type") == "refusal":
                    raise AppError("AI_REFUSAL", "模型未能处理这张照片，请手动记录或更换清晰照片")
                if content.get("type") == "output_text":
                    texts.append(content.get("text", ""))
        if not texts and isinstance(response.get("output_text"), str):
            texts.append(response["output_text"])
        if not texts:
            raise AppError("INVALID_AI_OUTPUT", "模型未返回可用的结构化食物结果")
        try:
            output = json.loads("".join(texts))
        except (ValueError, TypeError) as error:
            raise AppError("INVALID_AI_OUTPUT", "模型未返回有效 JSON，请检查结构化输出设置") from error
        if not isinstance(output, dict) or not isinstance(output.get("items"), list):
            raise AppError("INVALID_AI_OUTPUT", "模型结果不符合食物识别结构")
        return output

    def provider_info(self, user_id):
        return self.providers.public_configuration(user_id)

