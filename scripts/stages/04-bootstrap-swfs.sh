#!/usr/bin/env bash
# ============================================================================
# 04-bootstrap-swfs.sh — SeaweedFS Masters/Volumes/Filers/S3/Admin/Workers + Бакеты
# ============================================================================
# Вызов: ./clusterctl install --stage 4
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
log_step "Стадия 4: Bootstrap SeaweedFS"

NODE1_IP=$(get_node_ip 1)
MASTER_PEERS=$(build_swfs_master_peers)

# 0. Убеждаемся, что свежие отрендеренные конфиги лежат на всех нодах
ensure_swfs_configs_cb() {
    render_node_configs "$1" "$2" "$3" "$4" "existing"
    push_node_configs "$1" "$2" "$3" "$4"
}
for_each_node ensure_swfs_configs_cb

# 1. Masters (профиль quorum)
log_step "Запуск SeaweedFS Masters"
start_master_cb() {
    local ip="$1" name="$3" idx="$4"
    if ! is_quorum_node "${idx}" "${name}"; then
        log_info "  Пропуск Master на ${name} (edge-нода)"
        return 0
    fi
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d swfs-master"
}
for_each_node start_master_cb
wait_for_remote_health "${NODE1_IP}" "SeaweedFS Master Leader" \
    "curl -sf http://127.0.0.1:${SWFS_MASTER_PORT:-9333}/cluster/status | jq -e '.Leader != \"\"'" 30 3 \
    "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 50 swfs-master || true"

# 2. Volume Servers
log_step "Запуск SeaweedFS Volume Servers"
start_volume_cb() {
    local ip="$1" dc="$2" name="$3"
    log_info "  Старт swfs-volume на ${name} (-dataCenter=${dc})..."
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d swfs-volume"
    wait_for_remote_health "${ip}" "SWFS Volume ${name}" "curl -sf http://127.0.0.1:${SWFS_VOLUME_PORT:-8082}/healthz || curl -sf http://127.0.0.1:${SWFS_VOLUME_PORT:-8082}/status" 20 2 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 40 swfs-volume || true"
}
for_each_node start_volume_cb

# 3. Filer ([postgres2] verify-full) + S3 Gateway (127.0.0.1:8333)
log_step "Запуск SeaweedFS Filers и S3 Gateways"
start_filer_s3_cb() {
    local ip="$1" name="$3"
    log_info "  Старт swfs-filer и swfs-s3 на ${name}..."
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d swfs-filer swfs-s3"
    # Проверяем /healthz или порт метрик (GET / закрыт JWT -> 401!)
    wait_for_remote_health "${ip}" "SWFS Filer ${name}" \
        "curl -sf http://127.0.0.1:${SWFS_FILER_PORT:-8888}/healthz || curl -sf http://127.0.0.1:${SWFS_FILER_METRICS_PORT:-9326}/metrics >/dev/null" 25 2 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 40 swfs-filer || true"
    wait_for_remote_health "${ip}" "SWFS S3 ${name}" "nc -z 127.0.0.1 ${SWFS_S3_PORT:-8333}" 20 2 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 40 swfs-s3 || true"
}
for_each_node start_filer_s3_cb

# 4. fs.configure (с полным списком мастеров)
log_step "Применение fs.configure (volumeGrowthCount=${SWFS_VOLUME_GROWTH_COUNT:-2}, replication=${SWFS_DEFAULT_REPLICATION:-100})"
remote_exec_stdin "${NODE1_IP}" "${REMOTE_BASE_DIR}" "${SWFS_VOLUME_GROWTH_COUNT:-2}" "${SWFS_DEFAULT_REPLICATION:-100}" "${MASTER_PEERS}" <<'REMOTE_FS_CONF'
set -euo pipefail
BASE_DIR="$1"; VGC="$2"; REPL="$3"; MASTERS="$4"
FILER_CID=$(cd "${BASE_DIR}" && docker compose ps -q swfs-filer | head -n1)
[[ -n "${FILER_CID}" ]] || { echo "swfs-filer container not found" >&2; exit 1; }
docker exec -i "${FILER_CID}" weed shell -master="${MASTERS}" <<WEED
fs.configure -locationPrefix=/ -volumeGrowthCount=${VGC} -replication=${REPL} -apply
WEED
REMOTE_FS_CONF

# 5. Создание бакетов sftp-work (Versioning) и sftp-worm (Object Lock + DefaultRetention)
log_step "Создание S3 бакетов: sftp-work и sftp-worm (${WORM_RETENTION_MODE:-COMPLIANCE}, ${WORM_RETENTION_DAYS:-365}d)"
remote_exec_stdin "${NODE1_IP}" \
    "${SWFS_S3_PORT:-8333}" \
    "sftpgo-s3-access" \
    "${SWFS_S3_SECRET_KEY_SFTPGO}" \
    "${WORM_RETENTION_MODE:-COMPLIANCE}" \
    "${WORM_RETENTION_DAYS:-365}" <<'REMOTE_BUCKETS'
set -euo pipefail
S3_PORT="$1"; ACCESS_KEY="$2"; SECRET_KEY="$3"; RET_MODE="$4"; RET_DAYS="$5"

python3 - "${S3_PORT}" "${ACCESS_KEY}" "${SECRET_KEY}" "${RET_MODE}" "${RET_DAYS}" <<'PYEOF'
import datetime, hashlib, hmac, sys, urllib.error, urllib.request

port, ak, sk, ret_mode, ret_days = sys.argv[1:]
endpoint = f"http://127.0.0.1:{port}"
region = "us-east-1"

def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

def s3_req(method, path, query="", body=b"", extra_headers=None):
    extra_headers = extra_headers or {}
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()

    headers = {
        "host": f"127.0.0.1:{port}",
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
        **{k.lower(): v for k, v in extra_headers.items()},
    }
    sorted_keys = sorted(headers.keys())
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted_keys)
    signed_headers = ";".join(sorted_keys)
    canonical_request = f"{method}\n{path}\n{query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"

    scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    k_signing = sign(sign(sign(sign(("AWS4" + sk).encode("utf-8"), date_stamp), region), "s3"), "aws4_request")
    sig = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    headers["authorization"] = f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, SignedHeaders={signed_headers}, Signature={sig}"
    url = f"{endpoint}{path}" + (f"?{query}" if query else "")
    req = urllib.request.Request(url, data=body if method in ("PUT", "POST") else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

def ensure_bucket(name, object_lock=False):
    hdrs = {"x-amz-bucket-object-lock-enabled": "true"} if object_lock else {}
    st, txt = s3_req("PUT", f"/{name}", extra_headers=hdrs)
    if st not in (200, 204, 409) and "BucketAlready" not in txt:
        raise RuntimeError(f"Failed creating bucket {name}: HTTP {st} {txt}")

    ver_xml = (
        '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        '<Status>Enabled</Status></VersioningConfiguration>'
    ).encode("utf-8")
    st, txt = s3_req("PUT", f"/{name}", query="versioning=", body=ver_xml, extra_headers={"content-type": "application/xml"})
    if st not in (200, 204):
        raise RuntimeError(f"Failed enabling versioning on {name}: HTTP {st} {txt}")

ensure_bucket("sftp-work", object_lock=False)
ensure_bucket("sftp-worm", object_lock=True)

# Устанавливаем DefaultRetention на sftp-worm, чтобы файлы из SFTPGo защищались автоматически!
lock_cfg_xml = (
    '<ObjectLockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
    '<ObjectLockEnabled>Enabled</ObjectLockEnabled>'
    '<Rule><DefaultRetention>'
    f'<Mode>{ret_mode}</Mode><Days>{int(ret_days)}</Days>'
    '</DefaultRetention></Rule>'
    '</ObjectLockConfiguration>'
).encode("utf-8")
st_put, txt_put = s3_req("PUT", "/sftp-worm", query="object-lock=", body=lock_cfg_xml, extra_headers={"content-type": "application/xml"})
if st_put not in (200, 204):
    raise RuntimeError(f"Failed setting DefaultRetention on sftp-worm: HTTP {st_put} {txt_put}")

st, lock_xml = s3_req("GET", "/sftp-worm", query="object-lock=")
print(f"Object Lock DefaultRetention verified (HTTP {st}): {lock_xml.strip()}")
if st != 200 or ret_mode not in lock_xml:
    raise RuntimeError("DefaultRetention не подтвержден на бакете sftp-worm!")
PYEOF
REMOTE_BUCKETS

# 6. Запуск weed admin (+ swfs-backup если активен профиль backup) и weed worker
log_step "Запуск swfs-admin, swfs-worker (и swfs-backup при настроенном S3)"
admin_idx="${SWFS_ADMIN_NODE_INDEX:-2}"
admin_ip=$(get_node_ip "${admin_idx}")
log_info "Старт admin-сервисов на $(get_node_name "${admin_idx}") (${admin_ip})..."
remote_exec "${admin_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d swfs-admin"
if [[ -n "${BACKUP_S3_ACCESS_KEY:-}" && "${BACKUP_S3_ACCESS_KEY}" != *FIXME* ]]; then
    remote_exec "${admin_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d swfs-backup"
fi
wait_for_remote_health "${admin_ip}" "SWFS Admin" "nc -z 127.0.0.1 ${SWFS_ADMIN_PORT:-12535}" 20 2

start_worker_cb() {
    local ip="$1" name="$3"
    log_info "  Старт swfs-worker на ${name}..."
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d swfs-worker"
}
for_each_node start_worker_cb

log_info "✅ Стадия 4 завершена: SeaweedFS (S3, DefaultRetention WORM, admin/workers) работает"
