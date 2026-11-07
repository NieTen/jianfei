#!/usr/bin/env bash
# 只在一次性 CI 运行器上使用，检查实际群晖配置及两种架构。
set -euo pipefail
image=${1:?请指定待验收镜像}
workspace=$(pwd)
mkdir -p build deploy/synology/secrets deploy/synology/certificates
printf 'NAS_IP=127.0.0.1\nHTTP_PORT=18080\nHTTPS_PORT=18443\n' > deploy/synology/.env
export BINGJIAN_IMAGE="$image"
compose=(docker compose --project-directory "$workspace/deploy/synology" -f "$workspace/deploy/synology/docker-compose.yml" -f "$workspace/build/nas-platform.yml")
cleanup() {
    "${compose[@]}" logs --no-color > "$workspace/build/nas-${architecture}-services.log" 2>&1 || true
    "${compose[@]}" down --volumes --remove-orphans || true
}
for architecture in amd64 arm64; do
    export COMPOSE_PROJECT_NAME="bingjian-nas-${GITHUB_RUN_ID:-local}-${architecture}"
    printf 'services:\n  api:\n    platform: linux/%s\n' "$architecture" > build/nas-platform.yml
    trap cleanup EXIT
    docker pull --platform "linux/$architecture" "$image"
    test_startup_timeout=15
    if [ "$architecture" = arm64 ]; then test_startup_timeout=90; fi
    docker run --rm --platform "linux/$architecture" \
        -e "BINGJIAN_TEST_STARTUP_TIMEOUT=$test_startup_timeout" "$image" \
        python -m unittest discover -s tests -v 2>&1 | tee "build/nas-${architecture}-tests.log"
    "${compose[@]}" config --quiet
    "${compose[@]}" up -d --wait --wait-timeout 240
    for attempt in $(seq 1 30); do
        if "${compose[@]}" exec -T caddy cp /data/caddy/pki/authorities/local/root.crt /certificates/bingjian-root.crt; then
            break
        fi
        if [ "$attempt" -eq 30 ]; then exit 1; fi
        sleep 1
    done
    # 仅放开导出的公开根证书读取权限，CA 私钥仍留在数据卷中。
    "${compose[@]}" exec -T caddy chmod 644 /certificates/bingjian-root.crt
    certificate="$workspace/deploy/synology/certificates/bingjian-root.crt"
    for phase in before after; do
        if [ "$phase" = after ]; then
            "${compose[@]}" up -d --force-recreate --wait --wait-timeout 240
        fi
        curl --fail --silent --show-error --retry 10 --retry-all-errors --retry-delay 2 \
            http://127.0.0.1:18080/api/v1/health > "build/nas-${architecture}-http-health-${phase}.json"
        curl --fail --silent --show-error --retry 10 --retry-all-errors --retry-delay 2 \
            --cacert "$certificate" https://127.0.0.1:18443/api/v1/health > "build/nas-${architecture}-health-${phase}.json"
        curl --fail --silent --show-error --cacert "$certificate" \
            https://127.0.0.1:18443/api/v1/server-info > "build/nas-${architecture}-server-${phase}.json"
        if [ "$phase" = before ]; then
            "${compose[@]}" exec -T api python -c 'from pathlib import Path; Path("/data/.ci-persistence-check").write_text("保留数据", encoding="utf-8")'
        fi
    done
    "${compose[@]}" exec -T api python -c 'from pathlib import Path; assert Path("/data/.ci-persistence-check").read_text(encoding="utf-8") == "保留数据"'
    "${compose[@]}" exec -T api python -m app.cli status > "build/nas-${architecture}-status.json"
    # 通过实际容器接口注册和登录，不传入系统密钥，不把会话凭据写入日志。
    "${compose[@]}" exec -T api python - <<'PY'
import uuid
import httpx
with httpx.Client(base_url="http://127.0.0.1:8000/api/v1", trust_env=False) as client:
    body = {"username": "nas_" + uuid.uuid4().hex[:10], "password": "nas-test-password-123",
            "display_name": "无密钥注册测试", "device_id": str(uuid.uuid4())}
    created = client.post("/auth/register", json=body)
    assert created.status_code == 200, created.status_code
    signed_in = client.post("/auth/login", json={key: body[key] for key in ("username", "password", "device_id")})
    assert signed_in.status_code == 200, signed_in.status_code
    assert signed_in.json()["user_id"] == created.json()["user_id"]
    assert client.get("/records").status_code == 401
print("无系统密钥注册、登录与匿名访问隔离通过")
PY
    python3 - "$architecture" <<'PY'
import json
import sys
from pathlib import Path
prefix = Path("build") / ("nas-" + sys.argv[1])
def read(name):
    return json.loads(Path(str(prefix) + name).read_text())
assert read("-server-before.json")["instance_id"] == read("-server-after.json")["instance_id"]
assert read("-health-before.json")["status"] == read("-health-after.json")["status"] == "ok"
assert read("-http-health-before.json")["status"] == read("-http-health-after.json")["status"] == "ok"
print(sys.argv[1] + "：HTTP、HTTPS、数据保留与实例身份检查通过")
PY
    cleanup
    trap - EXIT
done
