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
    def __init__(self, database, settings):
        self.db = database
        self.settings = settings
        secret = load_secret(settings.data_dir / "secrets" / "providers.key")
        self.cipher = Fernet(base64.urlsafe_b64encode(hashlib.sha256(secret.encode()).digest()))
        self.model_cache = {}

    def seal(self, configuration):
        return self.cipher.encrypt(json.dumps(configuration, ensure_ascii=False).encode()).decode()

    def unseal(self, value):
        return json.loads(self.cipher.decrypt(value.encode()))

    def configuration(self, user_id):
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
        with self.db.transaction() as repo:
            validate_actor(repo, actor)
            repo.delete("ai_settings", {"user_id": actor["user_id"]})
            repo.audit(actor["user_id"], "ai_settings_removed")
        self.model_cache.pop(actor["user_id"], None)
        return self.public_configuration(actor["user_id"])

    async def models(self, actor, refresh=False):
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
        value = await self.models(actor, refresh=True)
        selected = value["selected_model"]
        return {"connected": True, "model_listed": any(row["id"] == selected for row in value["models"]),
                "model": selected, "protocol": "responses", "message": "接口连接成功，所选模型的图像能力在首次识别时校验"}

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
