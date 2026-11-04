import logging
import time
import uuid
from collections import defaultdict, deque
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .api import router
from .errors import AppError
from .runtime import Runtime

logger = logging.getLogger("jianfei")


class RequestGuard:
    def __init__(self, app):
        self.app = app
        self.attempts = defaultdict(deque)

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path = scope.get("path", "")
        client = (scope.get("client") or ("unknown", 0))[0]
        now = time.monotonic()
        key = (client, "auth" if "/auth/" in path else "api")
        history = self.attempts[key]
        while history and history[0] < now - 60:
            history.popleft()
        maximum = 20 if key[1] == "auth" else 600
        if len(history) >= maximum:
            response = JSONResponse({"code": "RATE_LIMITED", "message": "请求过于频繁，请稍后再试", "retryable": True}, 429)
            return await response(scope, receive, send)
        history.append(now)
        limit = 4 * 1024 * 1024 * 1024 + 1024 * 1024 if path == "/api/v1/data/import" else 2 * 1024 * 1024
        received = 0

        async def limited_receive():
            nonlocal received
            message = await receive()
            received += len(message.get("body", b""))
            if received > limit:
                raise AppError("REQUEST_TOO_LARGE", "请求内容超过大小限制", 413)
            return message

        await self.app(scope, limited_receive, send)


def create_app(settings=None, run_jobs=True):
    @asynccontextmanager
    async def lifespan(application):
        service = Runtime(settings, exclusive=True)
        application.state.runtime = service
        if run_jobs:
            await service.jobs.start()
        try:
            yield
        finally:
            if run_jobs:
                await service.jobs.stop()
            try:
                service.maintenance.persist_ledger()
            finally:
                service.release_instance()

    application = FastAPI(title="并肩健康记录 API", version="0.1.0", lifespan=lifespan,
                          docs_url="/api/docs", redoc_url=None)
    application.add_middleware(RequestGuard)
    application.include_router(router)

    @application.exception_handler(AppError)
    async def application_error(request: Request, error: AppError):
        return JSONResponse({"code": error.code, "message": error.message, "retryable": error.retryable,
                             "details": error.details, "request_id": str(uuid.uuid4())}, status_code=error.status)

    @application.exception_handler(RequestValidationError)
    async def validation_error(request: Request, error: RequestValidationError):
        fields = [{"field": ".".join(map(str, item["loc"])), "message": item["msg"]} for item in error.errors()]
        return JSONResponse({"code": "VALIDATION_FAILED", "message": "请检查输入字段", "details": fields,
                             "retryable": False, "request_id": str(uuid.uuid4())}, status_code=422)

    @application.exception_handler(httpx.HTTPError)
    async def external_error(request: Request, error: httpx.HTTPError):
        return JSONResponse({"code": "PROVIDER_UNAVAILABLE", "message": "外部服务暂不可用，请稍后重试",
                             "retryable": True, "request_id": str(uuid.uuid4())}, status_code=502)

    @application.exception_handler(Exception)
    async def unexpected_error(request: Request, error: Exception):
        identifier = str(uuid.uuid4())
        logger.error("请求失败，标识=%s，错误类型=%s", identifier, type(error).__name__)
        return JSONResponse({"code": "INTERNAL_ERROR", "message": "操作暂未完成，请稍后重试",
                             "retryable": True, "request_id": identifier}, status_code=500)

    return application


app = create_app()

