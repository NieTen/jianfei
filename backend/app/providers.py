import base64
import hashlib
import ipaddress
import json
import os
import socket
import time
from urllib.parse import urlsplit, urlunsplit

import httpx
from cryptography.fernet import Fernet

from .errors import AppError
from .records import validate_actor
from .security import load_secret, now_iso


def normalized_ai_url(value):
    parsed = urlsplit(value.strip().rstrip("/"))
    if parsed.scheme not in ("https", "http") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise AppError("INVALID_AI_URL", "请输入不含账号、查询参数的 AI API 地址")
    path = parsed.path.rstrip("/")
    if path.endswith("/responses"):
        path = path[:-len("/responses")]
    if not path:
        path = "/v1"
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


class ProviderService:
    def __init__(self, database, settings, entitlements=None):
        self.db = database
        self.settings = settings
        secret = load_secret(settings.data_dir / "secrets" / "providers.key")
        self.cipher = Fernet(base64.urlsafe_b64encode(hashlib.sha256(secret.encode()).digest()))
        self.model_cache = {}
        self.entitlements = entitlements

    @property
    def cloud(self):
        return self.settings.deployment_mode == "cloud"

    def seal(self, configuration):
        return self.cipher.encrypt(json.dumps(configuration, ensure_ascii=False).encode()).decode()

    def unseal(self, value):
        return json.loads(self.cipher.decrypt(value.encode()))

    def configuration(self, user_id):
        if self.cloud:
            with self.db.read() as repo:
                row = repo.one("cloud_ai_provider", {"id": "platform", "enabled": 1})
                preference = repo.one("cloud_ai_preferences", {"user_id": user_id})
            if not row:
                raise AppError("AI_UNAVAILABLE", "平台 AI 服务尚未配置", 503, True)
            models = json.loads(row["models"])
            model = preference["model_id"] if preference and preference["model_id"] in models else models[0]
            return {"base_url": row["base_url"], "model": model,
                    "api_key": self.cipher.decrypt(row["encrypted_key"].encode()).decode() if row["encrypted_key"] else "",
                    "external": bool(row["external"]), "structured_output": True,
                    "max_output_tokens": row["max_output_tokens"], "protocol": "responses",
                    "version": row["revision"], "source": "platform", "provider_name": row["name"]}
        with self.db.read() as repo:
            row = repo.one("ai_settings", {"user_id": user_id})
        if row:
            return {
                "base_url": row["base_url"], "model": row["model"],
                "api_key": self.cipher.decrypt(row["encrypted_key"].encode()).decode() if row["encrypted_key"] else "",
                "external": bool(row["external"]), "structured_output": bool(row["structured_output"]),
                "max_output_tokens": row["max_output_tokens"],
                "protocol": "responses", "version": row["version"], "source": "personal",
            }
        return {
            "base_url": self.settings.ai_url, "model": self.settings.ai_model, "api_key": self.settings.ai_key,
            "external": self.settings.ai_external, "structured_output": True,
            "max_output_tokens": 4096,
            "protocol": self.settings.ai_protocol, "version": 0, "source": "server_default",
        }

    def public_configuration(self, user_id):
        if self.cloud:
            with self.db.read() as repo:
                row = repo.one("cloud_ai_provider", {"id": "platform"})
                preference = repo.one("cloud_ai_preferences", {"user_id": user_id})
                allowed = bool(self.entitlements and self.entitlements.active_grants(repo, user_id))
            models = json.loads(row["models"]) if row else []
            model = preference["model_id"] if preference and preference["model_id"] in models else next(iter(models), "")
            return {"source": "platform", "configured": bool(row and row["enabled"]),
                    "provider_name": row["name"] if row else "平台 AI", "version": row["revision"] if row else 0,
                    "external": bool(row["external"]) if row else True, "model": model if allowed else "",
                    "protocol": "responses", "execution": "gateway", "has_api_key": False}
        value = self.configuration(user_id)
        return {key: item for key, item in value.items() if key != "api_key"} | {
            "has_api_key": bool(value["api_key"]), "configured": bool(value["base_url"] and value["model"]),
            "host": urlsplit(value["base_url"]).hostname or "",
        }

    def validate_destination(self, url):
        parsed = urlsplit(url)
        host = parsed.hostname or ""
        configured_host = urlsplit(self.settings.ai_url).hostname
        allowed = {entry.strip().lower() for entry in os.getenv("AI_ALLOWED_HOSTS", "").split(",") if entry.strip()}
        if configured_host:
            allowed.add(configured_host.lower())
        if host.lower() in allowed:
            return
        if parsed.scheme != "https":
            raise AppError("INVALID_AI_URL", "自定义 AI 地址需使用 HTTPS，内网 HTTP 服务由部署者加入允许列表")
        try:
            addresses = {entry[4][0] for entry in socket.getaddrinfo(host, parsed.port or 443, type=socket.SOCK_STREAM)}
        except OSError as error:
            raise AppError("AI_HOST_UNREACHABLE", "AI 主机暂时无法解析，请检查地址", 503, True) from error
        if not addresses or any(not ipaddress.ip_address(address).is_global for address in addresses):
            raise AppError("AI_HOST_NOT_ALLOWED", "该内网 AI 主机需加入后台 AI_ALLOWED_HOSTS，也可在 App 中选择手机直连", 403)

    def save(self, actor, request):
        if self.cloud:
            raise AppError("PLATFORM_CONFIG_MANAGED", "平台 AI 配置仅可由管理员维护", 403)
        url = normalized_ai_url(request.base_url)
        self.validate_destination(url)
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            existing = repo.one("ai_settings", {"user_id": actor["user_id"]})
            if request.api_key is None and existing and existing["base_url"] != url:
                raise AppError("AI_KEY_REQUIRED", "AI 地址变化后请重新填写对应密钥")
            same_key = request.api_key is None or (existing is not None and request.api_key == (
                self.cipher.decrypt(existing["encrypted_key"].encode()).decode() if existing["encrypted_key"] else ""
            ))
            if existing and same_key and all((
                existing["base_url"] == url, existing["model"] == request.model.strip(),
                bool(existing["external"]) == request.external,
                bool(existing["structured_output"]) == request.structured_output,
                existing["max_output_tokens"] == request.max_output_tokens,
            )):
                return self.public_configuration(actor["user_id"])
            encrypted = existing["encrypted_key"] if existing else ""
            if not existing and request.api_key is None and self.settings.ai_key and self.settings.ai_url:
                if normalized_ai_url(self.settings.ai_url) == url:
                    encrypted = self.cipher.encrypt(self.settings.ai_key.encode()).decode()
            if request.api_key is not None:
                encrypted = self.cipher.encrypt(request.api_key.encode()).decode() if request.api_key else ""
            values = {"user_id": actor["user_id"], "base_url": url, "model": request.model.strip(),
                      "encrypted_key": encrypted, "external": int(request.external),
                      "structured_output": int(request.structured_output),
                      "max_output_tokens": request.max_output_tokens,
                      "version": (existing["version"] if existing else 0) + 1, "updated_at": now_iso()}
            if existing:
                repo.update("ai_settings", values, {"user_id": actor["user_id"]})
            else:
                repo.insert("ai_settings", values)
            pending = repo.find("tasks", {"user_id": actor["user_id"], "kind": "recognition", "status__in": ["pending", "unknown"]})
            for task in pending:
                payload = json.loads(task["payload"])
                payload.pop("_provider_snapshot", None)
                repo.update("tasks", {"status": "cancelled", "payload": json.dumps(payload), "error": "AI 配置已变化，请重新提交",
                                      "updated_at": now_iso()}, {"id": task["id"]})
            repo.audit(actor["user_id"], "ai_settings_updated")
        self.model_cache.pop(actor["user_id"], None)
        return self.public_configuration(actor["user_id"])

    def remove(self, actor):
        if self.cloud:
            raise AppError("PLATFORM_CONFIG_MANAGED", "平台 AI 配置仅可由管理员维护", 403)
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            repo.delete("ai_settings", {"user_id": actor["user_id"]})
            repo.audit(actor["user_id"], "ai_settings_removed")
        self.model_cache.pop(actor["user_id"], None)
        return self.public_configuration(actor["user_id"])

    async def models(self, actor, refresh=False):
        if self.cloud:
            value = self.preferences(actor)
            return {"models": value["models"], "selected_model": value["model_id"], "message": "平台允许的识图模型"}
        configuration = self.configuration(actor["user_id"])
        if not configuration["base_url"]:
            raise AppError("AI_NOT_CONFIGURED", "请先保存 AI 接口配置")
        cache_key = (configuration["base_url"], configuration["version"], hashlib.sha256(configuration["api_key"].encode()).hexdigest())
        cached = self.model_cache.get(actor["user_id"])
        if cached and not refresh and cached["key"] == cache_key and cached["expires"] > time.monotonic():
            return cached["value"]
        self.validate_destination(configuration["base_url"])
        headers = {"Authorization": "Bearer " + configuration["api_key"]} if configuration["api_key"] else {}
        async with httpx.AsyncClient(timeout=20, follow_redirects=False, trust_env=False) as client:
            response = await client.get(normalized_ai_url(configuration["base_url"]) + "/models", headers=headers)
        self.check_response(response)
        raw = response.json()
        rows = raw.get("data", raw.get("models", []))
        models = []
        for row in rows:
            model_id = row.get("id") or row.get("slug")
            if model_id and row.get("visibility", "list") == "list":
                models.append({"id": model_id, "name": row.get("display_name") or model_id,
                               "owned_by": row.get("owned_by", "")})
        result = {"models": sorted(models, key=lambda row: row["id"]), "selected_model": configuration["model"],
                  "message": "列表来自当前接口，图像输入能力在实际识别时校验"}
        self.model_cache[actor["user_id"]] = {"key": cache_key, "expires": time.monotonic() + 300, "value": result}
        return result

    async def test(self, actor):
        if self.cloud:
            raise AppError("PLATFORM_CONFIG_MANAGED", "平台连接检查仅由管理员执行", 403)
        value = await self.models(actor, refresh=True)
        selected = value["selected_model"]
        return {"connected": True, "model_listed": any(row["id"] == selected for row in value["models"]),
                "model": selected, "protocol": "responses", "message": "接口连接成功，所选模型的图像能力在首次识别时校验"}

    def configure_cloud(self, base_url, models, name="平台 AI", api_key=None, external=True, enabled=True, max_output_tokens=4096):
        """仅由受限 CLI 调用；没有接受普通账号写入平台配置的 HTTP 路由。"""
        url = normalized_ai_url(base_url)
        if not url.startswith("https://"):
            raise AppError("INVALID_AI_URL", "云端 AI 提供方必须使用 HTTPS")
        self.validate_destination(url)
        models = list(dict.fromkeys(value.strip() for value in models if value.strip()))
        if not models or any(len(value) > 200 for value in models) or not 256 <= max_output_tokens <= 32768:
            raise AppError("INVALID_AI_CONFIGURATION", "请提供允许模型及有效输出上限")
        with self.db.transaction() as repo:
            existing = repo.one("cloud_ai_provider", {"id": "platform"})
            if existing and existing["base_url"] != url and api_key is None:
                raise AppError("AI_KEY_REQUIRED", "接口地址变化后请重新提供密钥")
            encrypted = existing["encrypted_key"] if existing else ""
            if api_key is not None:
                encrypted = self.cipher.encrypt(api_key.encode()).decode() if api_key else ""
            values = {"id": "platform", "name": name, "base_url": url, "models": json.dumps(models),
                      "encrypted_key": encrypted, "external": int(external), "enabled": int(enabled),
                      "max_output_tokens": max_output_tokens, "revision": existing["revision"] + 1 if existing else 1,
                      "updated_at": now_iso()}
            if existing:
                repo.update("cloud_ai_provider", values, {"id": "platform"})
            else:
                repo.insert("cloud_ai_provider", values)
            repo.audit("system", "cloud_ai_provider_updated", "platform")
            # 版本号仍在每次上游请求前检查；主动终止已领取任务以阻止迟到结果落库。
            users = {task["user_id"] for task in repo.find("tasks", {"kind": "recognition", "status__in": ["pending", "running", "unknown"]})}
            for user_id in users:
                self.entitlements.cancel_pending(repo, user_id, "平台 AI 配置已更新")
        return {"provider_name": name, "provider_revision": values["revision"], "models": models, "enabled": bool(enabled)}

    def preferences(self, actor, model_id=None):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            self.entitlements.require(repo, actor["user_id"])
            row = repo.one("cloud_ai_provider", {"id": "platform", "enabled": 1})
            if not row:
                raise AppError("AI_UNAVAILABLE", "平台 AI 服务尚未配置", 503, True)
            models = json.loads(row["models"])
            preference = repo.one("cloud_ai_preferences", {"user_id": actor["user_id"]})
            if model_id is not None:
                if model_id not in models:
                    raise AppError("AI_MODEL_NOT_ALLOWED", "该模型不在平台允许列表中", 403)
                values = {"user_id": actor["user_id"], "model_id": model_id, "updated_at": now_iso()}
                if preference:
                    repo.update("cloud_ai_preferences", values, {"user_id": actor["user_id"]})
                else:
                    repo.insert("cloud_ai_preferences", values)
                preference = values
            selected = preference["model_id"] if preference and preference["model_id"] in models else models[0]
            return {"model_id": selected, "models": [{"id": model, "name": model} for model in models],
                    "provider_name": row["name"], "provider_revision": row["revision"], "external": bool(row["external"])}

    def consent(self, actor, request=None):
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            provider = repo.one("cloud_ai_provider", {"id": "platform"})
            revision = provider["revision"] if provider else 0
            row = repo.one("cloud_ai_consents", {"user_id": actor["user_id"]})
            if request is not None:
                if request.allowed:
                    self.entitlements.require(repo, actor["user_id"])
                    if not provider or not provider["enabled"]:
                        raise AppError("AI_UNAVAILABLE", "平台 AI 服务尚未配置", 503, True)
                    if request.provider_revision != revision:
                        raise AppError("PROVIDER_CHANGED", "提供方已变化，请重新阅读照片处理说明", 409)
                values = {"user_id": actor["user_id"], "allowed": int(request.allowed),
                          "revision": (row["revision"] if row else 0) + 1,
                          "provider_revision": revision, "updated_at": now_iso()}
                if row:
                    repo.update("cloud_ai_consents", values, {"user_id": actor["user_id"]})
                else:
                    repo.insert("cloud_ai_consents", values)
                row = values
                self.entitlements.cancel_pending(repo, actor["user_id"], "照片处理授权已变化")
                repo.audit(actor["user_id"], "ai_consent_changed")
            return {"allowed": bool(row and row["allowed"] and row["provider_revision"] == revision and provider and provider["enabled"]),
                    "revision": row["revision"] if row else 0, "provider_revision": revision,
                    "provider_name": provider["name"] if provider else "平台 AI", "external": bool(provider["external"]) if provider else True}

    @staticmethod
    def check_response(response):
        if response.is_success:
            return
        messages = {
            400: "模型或 Responses 参数不兼容，请核对模型及结构化输出设置",
            401: "AI 密钥无效或已过期", 403: "当前密钥没有访问所选模型的权限",
            404: "AI 接口路径或所选模型不存在", 429: "AI 服务限流或额度不足，请稍后重试",
        }
        raise AppError("PROVIDER_HTTP_" + str(response.status_code), messages.get(response.status_code, "AI 服务暂不可用"),
                       502, response.status_code >= 500 or response.status_code == 429)
