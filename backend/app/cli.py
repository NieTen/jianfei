import argparse
import getpass
import json
import os
import shutil
import signal
import socket
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from .config import Settings
from .runtime import Runtime
from .security import now_iso


def replay_deletions(service, events):
    with service.db.transaction() as repo:
        for event in events:
            user = repo.one("users", {"id": event["user_id"]})
            if not user:
                continue
            if event["action"] == "entity":
                entity_id = event["target_id"]
                repo.delete("entities", {"user_id": user["id"], "id": entity_id})
                remaining = repo.find("entities", {"user_id": user["id"], "kind": "meal", "deleted_at": None})
                referenced = {photo for meal in remaining for photo in json.loads(meal["payload"]).get("photo_ids", [])}
                for photo in repo.find("media", {"user_id": user["id"], "meal_id": entity_id}):
                    if photo["id"] not in referenced:
                        repo.update("media", {"status": "deleted"}, {"id": photo["id"]})
                key = {"user_id": user["id"], "entity_id": entity_id, "generation": user["generation"]}
                if repo.one("entity_ledger", key):
                    repo.update("entity_ledger", {"deleted": 1}, key)
                else:
                    repo.insert("entity_ledger", {**key, "deleted": 1, "created_change_id": event["id"]})
            elif event["action"] in ("all_data", "account"):
                for table in ("entities", "changes", "receipts", "scores", "score_events", "snapshots", "ai_settings", "tasks", "notifications", "cloud_ai_preferences", "cloud_ai_consents"):
                    repo.delete(table, {"user_id": user["id"]})
                repo.update("media", {"status": "deleted"}, {"user_id": user["id"]})
                repo.update("users", {"generation": max(user["generation"], int(event["target_id"] or 1)),
                                      "status": "deleted" if event["action"] == "account" else "active"}, {"id": user["id"]})
                for member in repo.find("members", {"user_id": user["id"]}):
                    repo.update("challenges", {"status": "ended_early", "finalized_at": now_iso()}, {"id": member["challenge_id"]})
                    repo.delete("active_members", {"challenge_id": member["challenge_id"]})
                repo.update("members", {"goal": "{}", "baseline": None, "status": "left"}, {"user_id": user["id"]})
                repo.delete("encouragements", {"sender_id": user["id"]})
                if event["action"] == "account":
                    if user["email"]:
                        repo.delete("email_challenges", {"email": user["email"]})
                    for table in ("entitlement_grants", "entitlement_events", "ai_usage", "email_challenges"):
                        repo.delete(table, {"user_id": user["id"]})
                    repo.update("users", {"password_hash": "", "recovery_hash": "", "display_name": "已注销用户",
                                          "email": None, "email_verified_at": None}, {"id": user["id"]})
                else:
                    repo.update("ai_usage", {"status": "released", "updated_at": now_iso()}, {"user_id": user["id"], "status": "reserved"})
            if not repo.one("deletion_ledger", {"id": event["id"]}):
                repo.insert("deletion_ledger", event)
        repo.update("settings", {"value": str(uuid.uuid4())}, {"key": "sync_epoch"})
        repo.update("sessions", {"revoked_at": now_iso(), "revoked_reason": "restore"}, {"revoked_at": None})
        repo.update("consents", {"scopes": "[]", "revoked_at": now_iso(), "updated_at": now_iso()}, {"revoked_at": None})


def restore(service, source, password, object_directory=None):
    work = service.settings.data_dir / "tmp" / ("restore-" + str(uuid.uuid4()))
    try:
        service.maintenance.unpack_backup(source, password, work, object_directory)
        events = service.maintenance.deletion_events()
        with service.db.read() as repo:
            has_users = bool(repo.find("users", limit=1))
        if has_users:
            service.maintenance.backup(password=password)
        for suffix in ("-wal", "-shm"):
            Path(str(service.db.path) + suffix).unlink(missing_ok=True)
        shutil.copyfile(work / "db" / "app.sqlite3", service.db.path)
        media_source = work / "media"
        if media_source.exists():
            shutil.copytree(media_source, service.media.root, dirs_exist_ok=True)
        secrets_source = work / "secrets"
        if secrets_source.exists():
            shutil.copytree(secrets_source, service.settings.data_dir / "secrets", dirs_exist_ok=True)
        service.db.initialize()
        replay_deletions(service, events)
        service.entitlements.freeze_after_restore()
        service.media.cleanup()
        service.maintenance.persist_ledger()
        print("恢复完成。旧会话及游标已失效，用户重新登录并确认共享授权后继续使用。")
        if service.settings.deployment_mode == "cloud":
            print("云端备份中的会员权益已冻结并保留审计；管理员核验后重新授予，用户需重新同意 AI 照片处理。")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def advertise(args):
    from zeroconf import IPVersion, ServiceInfo, Zeroconf
    ip = socket.inet_aton(args.address)
    hostname = args.hostname.rstrip(".") + "."
    info = ServiceInfo(
        "_fatloss._tcp.local.", args.name + "._fatloss._tcp.local.",
        addresses=[ip], port=args.port, properties={"scheme": "https", "api": "1"}, server=hostname,
    )
    zeroconf = Zeroconf(interfaces=[args.address], ip_version=IPVersion.V4Only)
    zeroconf.register_service(info)
    print("内网服务发现已发布，按 Ctrl+C 停止。")
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        pass
    finally:
        zeroconf.unregister_service(info)
        zeroconf.close()


def pairing(service, certificate_path):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    contents = Path(certificate_path).read_bytes()
    certificate = x509.load_pem_x509_certificate(contents) if b"-----BEGIN CERTIFICATE-----" in contents else x509.load_der_x509_certificate(contents)
    return {
        "kind": "bingjian_server", "version": 1, "url": service.settings.public_url,
        "instance_id": service.records.public_identity()["instance_id"],
        "ca_sha256": certificate.fingerprint(hashes.SHA256()).hex(),
    }


def main():
    parser = argparse.ArgumentParser(description="并肩后台运维")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("enrollment", help="兼容旧客户端的凭据命令，新版注册无需使用")
    backup = commands.add_parser("backup", help="生成并验证加密备份")
    backup.add_argument("--full", action="store_true", help="将全部附件嵌入单个完整包")
    restoration = commands.add_parser("restore", help="停止 API 后恢复备份")
    restoration.add_argument("archive")
    restoration.add_argument("--objects", help="增量附件 objects 目录，默认取恢复包同级目录")
    commands.add_parser("status", help="查看部署状态")
    grant = commands.add_parser("svip-grant", help="向指定账号授予有期限的 SVIP 权益")
    grant.add_argument("--user", required=True, help="账号 UUID")
    grant.add_argument("--until", required=True, help="含时区的 ISO 8601 到期时间")
    grant.add_argument("--reference", help="授权来源唯一凭据，重试使用同一值")
    grant.add_argument("--source", default="manual")
    grant.add_argument("--reason", default="人工开通")
    revoke = commands.add_parser("svip-revoke", help="撤销指定授权，不影响其他有效授权")
    revoke.add_argument("grant_id")
    revoke.add_argument("--reason", required=True)
    configure_ai = commands.add_parser("ai-configure", help="维护云端平台 AI；密钥通过终端隐蔽输入")
    configure_ai.add_argument("--url", required=True)
    configure_ai.add_argument("--models", required=True, help="允许模型标识，逗号分隔")
    configure_ai.add_argument("--name", default="平台 AI")
    configure_ai.add_argument("--internal", action="store_true", help="声明为平台自身处理，仍须照片处理同意")
    configure_ai.add_argument("--disabled", action="store_true")
    configure_ai.add_argument("--max-output-tokens", type=int, default=4096)
    pair = commands.add_parser("pairing", help="生成包含服务身份及 CA 指纹的配对信息")
    pair.add_argument("--certificate", required=True, help="Caddy 根证书的 PEM 或 DER 文件路径")
    discovery = commands.add_parser("advertise", help="在宿主网络发布内网发现")
    discovery.add_argument("--address", required=True, help="宿主机内网 IPv4 地址")
    discovery.add_argument("--hostname", required=True, help="可解析的内网主机名")
    discovery.add_argument("--port", type=int, default=8443)
    discovery.add_argument("--name", default="并肩私有服务")
    args = parser.parse_args()
    if args.command == "advertise":
        advertise(args)
        return
    service = Runtime(Settings.from_environment(), exclusive=args.command in ("backup", "restore"))
    if args.command == "svip-grant":
        print(json.dumps(service.entitlements.grant(args.user, args.until, args.source, args.reference,
                                                   args.reason, operator="cli:" + getpass.getuser()), ensure_ascii=False, indent=2))
        return
    if args.command == "svip-revoke":
        print(json.dumps(service.entitlements.revoke(args.grant_id, args.reason, operator="cli:" + getpass.getuser()), ensure_ascii=False, indent=2))
        return
    if args.command == "ai-configure":
        key = getpass.getpass("平台 API 密钥（留空仅保留同一接口已有密钥）： ")
        print(json.dumps(service.providers.configure_cloud(args.url, args.models.split(","), args.name,
                         key or None, external=not args.internal, enabled=not args.disabled,
                         max_output_tokens=args.max_output_tokens), ensure_ascii=False, indent=2))
        return
    if args.command == "pairing":
        print(json.dumps(pairing(service, args.certificate), ensure_ascii=False, indent=2))
        return
    if args.command == "enrollment":
        print(service.auth.create_enrollment())
        return
    if args.command == "status":
        with service.db.read() as repo:
            print(json.dumps({"instance_id": repo.setting("instance_id"),
                              "last_backup": json.loads(repo.setting("last_backup") or "null"),
                              "ai_configured": bool(service.settings.ai_url),
                              "apns_configured": service.push.configured()}, ensure_ascii=False, indent=2))
        return
    try:
        password = service.settings.backup_password or getpass.getpass("备份密码（至少 10 位） ")
        if args.command == "backup":
            print(json.dumps(service.maintenance.backup(password, incremental=not args.full), ensure_ascii=False, indent=2))
        elif args.command == "restore":
            restore(service, Path(args.archive).resolve(), password, args.objects)
    finally:
        service.release_instance()


if __name__ == "__main__":
    main()
