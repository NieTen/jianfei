#!/usr/bin/env bash
# 只在一次性 CI 运行器上使用，检查实际群晖配置及两种架构。
set -euo pipefail
image=${1:?请指定待验收镜像}
workspace=$(pwd)
mkdir -p build deploy/synology/secrets deploy/synology/certificates
printf 'NAS_IP=127.0.0.1\nHTTPS_PORT=18443\n' > deploy/synology/.env
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
    docker run --rm --platform "linux/$architecture" "$image" \
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
            --cacert "$certificate" https://127.0.0.1:18443/api/v1/health > "build/nas-${architecture}-health-${phase}.json"
        curl --fail --silent --show-error --cacert "$certificate" \
            https://127.0.0.1:18443/api/v1/server-info > "build/nas-${architecture}-server-${phase}.json"
        if [ "$phase" = before ]; then
            "${compose[@]}" exec -T api python -c 'from pathlib import Path; Path("/data/.ci-persistence-check").write_text("保留数据", encoding="utf-8")'
        fi
    done
    "${compose[@]}" exec -T api python -c 'from pathlib import Path; assert Path("/data/.ci-persistence-check").read_text(encoding="utf-8") == "保留数据"'
    "${compose[@]}" exec -T api python -m app.cli status > "build/nas-${architecture}-status.json"
    # 只验证开户命令确实返回凭据，不将测试凭据写入日志。
    "${compose[@]}" exec -T api python -m app.cli enrollment | python3 -c 'import sys; assert len(sys.stdin.read().strip()) >= 20; print("开户凭据生成通过")'
    python3 - "$architecture" <<'PY'
import json
import sys
from pathlib import Path
prefix = Path("build") / ("nas-" + sys.argv[1])
def read(name):
    return json.loads(Path(str(prefix) + name).read_text())
assert read("-server-before.json")["instance_id"] == read("-server-after.json")["instance_id"]
assert read("-health-before.json")["status"] == read("-health-after.json")["status"] == "ok"
print(sys.argv[1] + "：HTTPS、数据保留与实例身份检查通过")
PY
    cleanup
    trap - EXIT
done
