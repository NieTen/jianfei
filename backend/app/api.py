import asyncio
import json
import uuid
from datetime import date

from fastapi import APIRouter, Depends, File, Form, Header, Query, Request, UploadFile
from fastapi.responses import FileResponse

from .errors import AppError
from .models import (
    ChallengeConfirmation, ChallengeCreate, ChallengeJoin, ConsentRequest, DeleteRequest,
    DeviceAction, EncouragementRequest, ExportRequest, IdentityBinding, Login, MediaInit,
    Mutation, PushRegistration, PushRequest, RecognitionRequest, RecoveryRequest, AISettingsRequest,
    RefreshRequest, Registration,
    EmailCodeRequest, EmailResetRequest, PasswordChangeRequest, EmailBindingCodeRequest, EmailBindingRequest,
    AIConsentRequest, AIPreferenceRequest,
)

router = APIRouter(prefix="/api/v1")


def runtime(request: Request):
    return request.app.state.runtime


def actor(request: Request, authorization: str | None = Header(default=None)):
    return runtime(request).auth.authenticate(authorization)


@router.get("/health")
def health():
    return {"status": "ok", "version": "0.1.9", "registration_requires_code": False}


@router.get("/version")
def version():
    return {"version": "0.1.9", "api_version": 1, "minimum_client": 1, "maximum_client": 1}


@router.get("/app/config")
def app_configuration(request: Request):
    settings = runtime(request).settings
    cloud = settings.deployment_mode == "cloud"
    return {"deployment_mode": settings.deployment_mode, "email_auth_enabled": cloud or bool(settings.smtp_host),
            "registration_requires_email_verification": cloud, "ai_execution": "gateway_only" if cloud else "private",
            "api_version": 1}


@router.get("/server-info")
def server_info(request: Request):
    return runtime(request).records.public_identity()


@router.get("/capabilities")
def capabilities(request: Request, identity=Depends(actor)):
    service = runtime(request)
    return {**service.records.handshake(identity), "ai": service.ai.provider_info(identity["user_id"]),
            "deployment_mode": service.settings.deployment_mode, "entitlements": service.entitlements.public(identity),
            "push_available": service.push.configured(), "food_database_available": bool(service.settings.food_api_key),
            "max_members": 8, "max_photos": 6, "ai_timeout_seconds": 360}


@router.post("/auth/register")
def register(payload: Registration, request: Request):
    return runtime(request).auth.register(payload)


@router.post("/auth/login")
@router.post("/auth/register-device")
def login(payload: Login, request: Request):
    return runtime(request).auth.login(payload)


@router.post("/auth/refresh")
def refresh(payload: RefreshRequest, request: Request):
    return runtime(request).auth.refresh(payload.refresh_token)


@router.post("/auth/email-code")
def email_code(payload: EmailCodeRequest, request: Request):
    return runtime(request).auth.email.issue(payload.email, payload.purpose)


@router.post("/auth/reset-password")
def reset_password(payload: EmailResetRequest, request: Request):
    return runtime(request).auth.reset_password(payload)


@router.get("/me")
def current_account(request: Request, identity=Depends(actor)):
    return runtime(request).auth.me(identity)


@router.post("/me/password")
def change_password(payload: PasswordChangeRequest, request: Request, identity=Depends(actor)):
    return runtime(request).auth.change_password(identity, payload)


@router.post("/me/email-code")
def bind_email_code(payload: EmailBindingCodeRequest, request: Request, identity=Depends(actor)):
    return runtime(request).auth.email_binding_code(identity, payload)


@router.put("/me/email")
def bind_email(payload: EmailBindingRequest, request: Request, identity=Depends(actor)):
    return runtime(request).auth.bind_email(identity, payload)


@router.post("/auth/logout-all")
def logout_all(request: Request, identity=Depends(actor)):
    return runtime(request).auth.logout_all(identity)


@router.get("/me/entitlements")
def entitlements(request: Request, identity=Depends(actor)):
    return runtime(request).entitlements.public(identity)


@router.get("/me/ai-consent")
def ai_consent(request: Request, identity=Depends(actor)):
    return runtime(request).providers.consent(identity)


@router.put("/me/ai-consent")
def update_ai_consent(payload: AIConsentRequest, request: Request, identity=Depends(actor)):
    return runtime(request).providers.consent(identity, payload)


@router.get("/me/ai-preferences")
def ai_preferences(request: Request, identity=Depends(actor)):
    return runtime(request).providers.preferences(identity)


@router.put("/me/ai-preferences")
def update_ai_preferences(payload: AIPreferenceRequest, request: Request, identity=Depends(actor)):
    return runtime(request).providers.preferences(identity, payload.model_id)


@router.post("/auth/recover")
def recover(payload: RecoveryRequest, request: Request):
    return runtime(request).auth.recover(payload)


@router.post("/auth/logout")
def logout(request: Request, identity=Depends(actor)):
    return runtime(request).auth.logout(identity)


@router.get("/devices")
def devices(request: Request, identity=Depends(actor)):
    return runtime(request).auth.list_devices(identity)


@router.post("/auth/revoke-device")
def revoke_device(payload: DeviceAction, request: Request, identity=Depends(actor)):
    return runtime(request).auth.revoke_device(identity, payload.device_id)


@router.post("/devices/push")
def register_push(payload: PushRegistration, request: Request, identity=Depends(actor)):
    return runtime(request).auth.push_registration(identity, payload)


@router.post("/identity/bind")
def bind(payload: IdentityBinding, request: Request, identity=Depends(actor)):
    return runtime(request).auth.bind(identity, payload.local_user_id)


@router.get("/profile")
def profile(request: Request, identity=Depends(actor)):
    rows = runtime(request).records.list_entities(identity, "profile")
    return rows[0] if rows else None


@router.get("/records")
def records(request: Request, kind: str | None = None, start: str | None = None,
            end: str | None = None, identity=Depends(actor)):
    return runtime(request).records.list_entities(identity, kind, start, end)


@router.get("/summaries/{day}")
def summary(day: date, request: Request, identity=Depends(actor)):
    return runtime(request).records.summary(identity["user_id"], day.isoformat())


@router.post("/sync/push")
def sync_push(payload: PushRequest, request: Request, identity=Depends(actor)):
    return runtime(request).records.push(identity, payload)


@router.get("/sync/pull")
def sync_pull(request: Request, cursor: str | None = None, limit: int = Query(default=200, ge=1, le=200),
              identity=Depends(actor)):
    return runtime(request).records.pull(identity, cursor, limit)


@router.post("/sync/snapshots")
def create_snapshot(request: Request, identity=Depends(actor)):
    return runtime(request).records.create_snapshot(identity)


@router.get("/sync/snapshots/{snapshot_id}")
def snapshot_page(snapshot_id: str, request: Request, after: str = "", limit: int = Query(default=200, ge=1, le=200),
                  identity=Depends(actor)):
    return runtime(request).records.snapshot_page(identity, snapshot_id, after, limit)


@router.get("/sync/logs")
def sync_logs(request: Request, identity=Depends(actor)):
    return runtime(request).records.audit_logs(identity)


@router.post("/media/upload-init")
def media_init(payload: MediaInit, request: Request, identity=Depends(actor)):
    return runtime(request).media.initialize(identity, payload)


@router.put("/media/{media_id}")
async def media_upload(media_id: str, request: Request, offset: int = Query(default=0, ge=0), identity=Depends(actor)):
    data = await request.body()
    return await asyncio.to_thread(runtime(request).media.upload, identity, media_id, offset, data)


@router.get("/media/{media_id}")
def media_download(media_id: str, request: Request, challenge_id: str | None = None, thumbnail: bool = False,
                   identity=Depends(actor)):
    path = runtime(request).media.resolve(identity, media_id, challenge_id, thumbnail)
    return FileResponse(path, headers={"Cache-Control": "no-store"})


@router.post("/ai/food-recognition")
def recognize(payload: RecognitionRequest, request: Request, identity=Depends(actor)):
    return runtime(request).ai.create(identity, payload)


@router.get("/ai/settings")
def ai_settings(request: Request, identity=Depends(actor)):
    service = runtime(request)
    if service.settings.deployment_mode == "cloud":
        with service.db.read() as repo:
            service.entitlements.require(repo, identity["user_id"])
    return runtime(request).providers.public_configuration(identity["user_id"])


@router.put("/ai/settings")
def save_ai_settings(payload: AISettingsRequest, request: Request, identity=Depends(actor)):
    return runtime(request).providers.save(identity, payload)


@router.delete("/ai/settings")
def remove_ai_settings(request: Request, identity=Depends(actor)):
    return runtime(request).providers.remove(identity)


@router.get("/ai/models")
async def ai_models(request: Request, refresh: bool = False, identity=Depends(actor)):
    return await runtime(request).providers.models(identity, refresh)


@router.post("/ai/test")
async def test_ai_connection(request: Request, identity=Depends(actor)):
    return await runtime(request).providers.test(identity)


@router.get("/ai/tasks/{task_id}")
@router.get("/data/tasks/{task_id}")
def task(task_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).ai.task(identity, task_id)


@router.post("/ai/tasks/{task_id}/cancel")
def cancel_task(task_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).ai.cancel(identity, task_id)


@router.get("/foods/search")
async def food_search(request: Request, q: str = Query(default="", max_length=100), external: bool = False,
                      identity=Depends(actor)):
    return await runtime(request).foods.search(identity, q, external)


@router.post("/challenges")
def create_challenge(payload: ChallengeCreate, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.create(identity, payload)


@router.get("/challenges")
def list_challenges(request: Request, identity=Depends(actor)):
    return runtime(request).challenges.list(identity)


@router.post("/challenges/join")
def join_challenge(payload: ChallengeJoin, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.join(identity, payload)


@router.get("/challenge-invites/{code}")
def preview_invite(code: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.preview_invite(identity, code)


@router.get("/challenges/{challenge_id}")
def get_challenge(challenge_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.get(identity, challenge_id)


@router.post("/challenges/{challenge_id}/invite")
def invite(challenge_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.invitation(identity, challenge_id)


@router.post("/challenges/{challenge_id}/confirm")
def confirm(challenge_id: str, payload: ChallengeConfirmation, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.confirm(identity, challenge_id, payload.version)


@router.get("/challenges/{challenge_id}/consents")
def consents(challenge_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.consents(identity, challenge_id)


@router.put("/challenges/{challenge_id}/consent")
def consent(challenge_id: str, payload: ConsentRequest, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.consent(identity, challenge_id, payload)


@router.post("/challenges/{challenge_id}/pause")
def pause(challenge_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.pause(identity, challenge_id)


@router.post("/challenges/{challenge_id}/resume")
def resume(challenge_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.resume(identity, challenge_id)


@router.post("/challenges/{challenge_id}/leave")
def leave(challenge_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.leave(identity, challenge_id)


@router.delete("/pairs/{pair_id}")
def unpair(pair_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.unpair(identity, pair_id)


@router.get("/challenges/{challenge_id}/summary")
def challenge_summary(challenge_id: str, request: Request, day: date, identity=Depends(actor)):
    return runtime(request).challenges.summary(identity, challenge_id, day.isoformat())


@router.post("/challenges/{challenge_id}/encouragements")
def encourage(challenge_id: str, payload: EncouragementRequest, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.encourage(identity, challenge_id, payload)


@router.get("/challenges/{challenge_id}/encouragements")
def messages(challenge_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.messages(identity, challenge_id)


@router.delete("/challenges/{challenge_id}/encouragements/{message_id}")
def delete_message(challenge_id: str, message_id: str, request: Request, identity=Depends(actor)):
    return runtime(request).challenges.delete_message(identity, challenge_id, message_id)


@router.post("/data/export")
def export(payload: ExportRequest, request: Request, identity=Depends(actor)):
    return runtime(request).data.create_export(identity, payload)


@router.get("/data/exports/{task_id}/download")
def export_download(task_id: str, request: Request, identity=Depends(actor)):
    path = runtime(request).data.download(identity, task_id)
    return FileResponse(path, filename=path.name, headers={"Cache-Control": "no-store"})


@router.post("/data/import")
async def import_data(request: Request, archive: UploadFile = File(), password: str = Form(),
                      mode: str = Form(default="preview"), identity=Depends(actor)):
    service = runtime(request)
    temporary = service.settings.data_dir / "tmp" / (str(uuid.uuid4()) + ".incoming")
    try:
        with temporary.open("wb") as output:
            total = 0
            while chunk := await archive.read(1024 * 1024):
                total += len(chunk)
                if total > 4 * 1024 * 1024 * 1024:
                    raise AppError("UPLOAD_TOO_LARGE", "导入包超过 4GB", 413)
                output.write(chunk)
        return await asyncio.to_thread(service.data.import_archive, identity, temporary, password, mode)
    finally:
        temporary.unlink(missing_ok=True)
        await archive.close()


@router.delete("/account/data")
def delete_data(payload: DeleteRequest, request: Request, identity=Depends(actor)):
    return runtime(request).data.delete_data(identity, payload)


@router.delete("/account")
def delete_account(payload: DeleteRequest, request: Request, identity=Depends(actor)):
    return runtime(request).data.delete_data(identity, payload, True)


@router.get("/data/deletions/{task_id}")
def deletion_status(task_id: str, request: Request, x_deletion_receipt: str = Header()):
    return runtime(request).data.deletion_status(task_id, x_deletion_receipt)

