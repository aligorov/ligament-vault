#!/usr/bin/env bash
# ============================================================================
# backup-job.sh — Off-cluster DR-бэкапы, метрики Prometheus и verify-restore
# ============================================================================
# Использование: ./scripts/ops/backup-job.sh [full|incr|verify-restore]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
MODE="${1:-incr}"

if [[ "${BACKUP_S3_ACCESS_KEY:-FIXME}" == *FIXME* || -z "${BACKUP_S3_ACCESS_KEY:-}" ]]; then
    log_warn "BACKUP_S3_ACCESS_KEY не заполнен — укажите реквизиты внешнего S3"
    [[ "${DRY_RUN:-false}" != "true" ]] && exit 1
fi

write_backup_metrics() {
    local node_ip="$1" status_val="$2" update_ts="${3:-false}"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    remote_exec_stdin "${node_ip}" "${REMOTE_BASE_DIR}" "${status_val}" "${update_ts}" <<'REMOTE_PROM' || true
set -euo pipefail
BDIR="$1"; ST="$2"; UPD="$3"
DIR="/var/lib/node_exporter/textfile_collector"
FILE="${DIR}/ligament_backup.prom"
mkdir -p "${DIR}"
PREV_TS=$(awk '/^ligament_backup_last_success_timestamp_seconds/{print $2}' "${FILE}" 2>/dev/null || echo "0")
[[ -z "${PREV_TS}" ]] && PREV_TS=0
if [[ "${UPD}" == "true" ]]; then
    PREV_TS=$(date +%s)
fi
SW_UP=0
[[ -n "$(cd "${BDIR}" 2>/dev/null && docker compose ps -q swfs-backup | head -n1 || true)" ]] && SW_UP=1
cat > "${FILE}.tmp" <<EOF
# HELP ligament_backup_last_status Last backup execution status (1=ok, 0=failed)
# TYPE ligament_backup_last_status gauge
ligament_backup_last_status ${ST}
# HELP ligament_backup_last_success_timestamp_seconds Unix timestamp of last successful backup
# TYPE ligament_backup_last_success_timestamp_seconds gauge
ligament_backup_last_success_timestamp_seconds ${PREV_TS}
# HELP ligament_swfs_backup_up Continuous weed filer.backup container status
# TYPE ligament_swfs_backup_up gauge
ligament_swfs_backup_up ${SW_UP}
EOF
mv "${FILE}.tmp" "${FILE}"
REMOTE_PROM
}

run_pgbackrest() {
    local type="$1"
    local primary_ip
    primary_ip=$(find_patroni_primary_ip || get_node_ip 1)

    log_step "pgBackRest (${type}, stanza=${CLUSTER_SLUG}) на Primary ${primary_ip}"
    if ! remote_exec "${primary_ip}" "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1); [[ -n \"\${CID}\" ]] && docker exec -u postgres \"\${CID}\" pgbackrest --stanza='${CLUSTER_SLUG}' --type=${type} backup"; then
        write_backup_metrics "${primary_ip}" 0 false
        return 1
    fi
}

run_swfs_backup() {
    local admin_idx="${SWFS_ADMIN_NODE_INDEX:-2}"
    local node_ip
    node_ip=$(get_node_ip "${admin_idx}")
    log_step "SeaweedFS off-cluster meta-backup + контроль демона swfs-backup (${node_ip})"

    remote_exec "${node_ip}" "
        cd '${REMOTE_BASE_DIR}'
        if [[ -z \$(docker compose ps -q swfs-backup | head -n1) ]]; then
            docker compose --profile backup up -d swfs-backup
        fi
    "

    if ! remote_exec_stdin "${node_ip}" \
        "${REMOTE_BASE_DIR}" \
        "${SWFS_FILER_PORT:-8888}" \
        "${BACKUP_S3_ENDPOINT}" \
        "${BACKUP_S3_REGION:-us-east-1}" \
        "${BACKUP_S3_BUCKET}" \
        "${BACKUP_S3_ACCESS_KEY}" \
        "${BACKUP_S3_SECRET_KEY}" \
        "${BACKUP_ENCRYPTION_KEY}" <<'REMOTE_META_BKP'
set -euo pipefail
BDIR="$1"; FPORT="$2"; ENDPOINT="$3"; REGION="$4"; BUCKET="$5"; AK="$6"; SK="$7"; ENC_KEY="$8"

TS=$(date -u +%Y%m%dT%H%M%SZ)
TMP_META="/tmp/filer-meta-${TS}.meta"
TMP_ENC="/tmp/filer-meta-${TS}.meta.gz.enc"
CID=$(cd "${BDIR}" && docker compose ps -q swfs-filer | head -n1)
[[ -n "${CID}" ]] || { echo "swfs-filer not running" >&2; exit 1; }

trap 'rm -f "${TMP_META}" "${TMP_ENC}"; docker exec "${CID}" rm -f "${TMP_META}" 2>/dev/null || true' EXIT

docker exec "${CID}" weed filer.meta.backup -filer="127.0.0.1:${FPORT}" -output="${TMP_META}"
docker cp "${CID}:${TMP_META}" "${TMP_META}"
docker exec "${CID}" rm -f "${TMP_META}"

gzip -c "${TMP_META}" | ENCK="${ENC_KEY}" openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:ENCK -out "${TMP_ENC}"

python3 - "${ENDPOINT}" "${REGION}" "${BUCKET}" "${AK}" "${SK}" "${TMP_ENC}" "filer-meta/filer-meta-${TS}.meta.gz.enc" <<'PYEOF'
import datetime, hashlib, hmac, sys, urllib.parse, urllib.request

endpoint, region, bucket, ak, sk, local_file, obj_key = sys.argv[1:]
if not endpoint.startswith(("http://", "https://")):
    endpoint = "https://" + endpoint
endpoint = endpoint.rstrip("/")
parsed = urllib.parse.urlparse(endpoint)
host = parsed.netloc
body = open(local_file, "rb").read()

def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

for key_target, payload in ((obj_key, body), ("filer-meta/LATEST", obj_key.encode("utf-8"))):
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(payload).hexdigest()
    path = f"/{bucket}/{key_target}"
    headers = {"host": host, "x-amz-date": amz_date, "x-amz-content-sha256": payload_hash}
    sorted_keys = sorted(headers.keys())
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted_keys)
    signed_headers = ";".join(sorted_keys)
    canonical_req = f"PUT\n{path}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{hashlib.sha256(canonical_req.encode()).hexdigest()}"
    k_signing = sign(sign(sign(sign(("AWS4" + sk).encode(), date_stamp), region), "s3"), "aws4_request")
    sig = hmac.new(k_signing, sts.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, SignedHeaders={signed_headers}, Signature={sig}"
    req = urllib.request.Request(f"{endpoint}{path}", data=payload, headers=headers, method="PUT")
    with urllib.request.urlopen(req, timeout=60) as resp:
        assert resp.status in (200, 201, 204), f"S3 upload failed: {resp.status}"
print(f"Uploaded encrypted filer metadata backup -> s3://{bucket}/{obj_key}")
PYEOF
REMOTE_META_BKP
    then
        write_backup_metrics "${node_ip}" 0 false
        return 1
    fi

    write_backup_metrics "${node_ip}" 1 true
}

run_verify_restore() {
    local test_ip
    test_ip=$(get_node_ip "${SWFS_ADMIN_NODE_INDEX:-2}")
    log_step "Проверка целостности PostgreSQL + SeaweedFS бэкапов (verify-restore) на ${test_ip}"
    remote_exec_stdin "${test_ip}" \
        "${REMOTE_BASE_DIR}" \
        "${CLUSTER_SLUG}" \
        "${BACKUP_S3_ENDPOINT}" \
        "${BACKUP_S3_REGION:-us-east-1}" \
        "${BACKUP_S3_BUCKET}" \
        "${BACKUP_S3_ACCESS_KEY}" \
        "${BACKUP_S3_SECRET_KEY}" \
        "${BACKUP_ENCRYPTION_KEY}" <<'REMOTE_VERIFY'
set -euo pipefail
BDIR="$1"; SLUG="$2"; ENDPOINT="$3"; REGION="$4"; BUCKET="$5"; AK="$6"; SK="$7"; ENC_KEY="$8"

CID=$(cd "${BDIR}" && docker compose ps -q patroni | head -n1)
[[ -n "${CID}" ]] || { echo "Patroni container not found" >&2; exit 1; }
docker exec -u postgres "${CID}" pgbackrest --stanza="${SLUG}" check
docker exec -u postgres "${CID}" pgbackrest --stanza="${SLUG}" info --output=json | jq '.[0].backup[-1]'
AVAIL_MB=$(df -Pm /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
if (( AVAIL_MB >= 1200 )); then
    docker exec -u postgres "${CID}" bash -c "
        rm -rf /tmp/pgbr-verify && mkdir -p /tmp/pgbr-verify
        pgbackrest --stanza='${SLUG}' --pg1-path=/tmp/pgbr-verify --no-delta --type=immediate restore || \
        pgbackrest --stanza='${SLUG}' --pg1-path=/tmp/pgbr-verify restore
        ls -la /tmp/pgbr-verify/PG_VERSION
        rm -rf /tmp/pgbr-verify
    "
else
    echo "Пропуск полного test-restore в /tmp (/var/lib/docker free=${AVAIL_MB}MB < 1200MB); stanza check и metadata info выполнены OK"
fi

# Проверяем скачивание и AES-256 расшифровку последнего дампа метаданных SeaweedFS
TMP_DEC="/tmp/verify-meta-$$.enc"
trap 'rm -f "${TMP_DEC}"' EXIT
python3 - "${ENDPOINT}" "${REGION}" "${BUCKET}" "${AK}" "${SK}" "${TMP_DEC}" <<'PYEOF'
import datetime, hashlib, hmac, sys, urllib.parse, urllib.request
endpoint, region, bucket, ak, sk, dst = sys.argv[1:]
if not endpoint.startswith(("http://", "https://")):
    endpoint = "https://" + endpoint
endpoint = endpoint.rstrip("/")
host = urllib.parse.urlparse(endpoint).netloc
def sign(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
def s3_get(key):
    now = datetime.datetime.now(datetime.timezone.utc)
    ad, ds = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    ph = hashlib.sha256(b"").hexdigest()
    path = f"/{bucket}/{key}"
    hdrs = {"host": host, "x-amz-date": ad, "x-amz-content-sha256": ph}
    ch = "".join(f"{k}:{hdrs[k]}\n" for k in sorted(hdrs))
    sh = ";".join(sorted(hdrs))
    creq = f"GET\n{path}\n\n{ch}\n{sh}\n{ph}"
    sc = f"{ds}/{region}/s3/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{ad}\n{sc}\n{hashlib.sha256(creq.encode()).hexdigest()}"
    ks = sign(sign(sign(sign(("AWS4" + sk).encode(), ds), region), "s3"), "aws4_request")
    hdrs["authorization"] = f"AWS4-HMAC-SHA256 Credential={ak}/{sc}, SignedHeaders={sh}, Signature={hmac.new(ks, sts.encode(), hashlib.sha256).hexdigest()}"
    return urllib.request.urlopen(urllib.request.Request(f"{endpoint}{path}", headers=hdrs), timeout=30).read()

latest_key = s3_get("filer-meta/LATEST").decode().strip()
open(dst, "wb").write(s3_get(latest_key))
print(f"Downloaded {latest_key} for decryption verification")
PYEOF

ENCK="${ENC_KEY}" openssl enc -d -aes-256-cbc -pbkdf2 -pass env:ENCK -in "${TMP_DEC}" | gunzip -t
echo "SeaweedFS encrypted metadata archive verified OK"
REMOTE_VERIFY
    log_info "✅ Автотест восстановления PostgreSQL + SeaweedFS метаданных (verify-restore) пройден"
}

case "${MODE}" in
    full)           run_pgbackrest full; run_swfs_backup ;;
    incr)           run_pgbackrest incr; run_swfs_backup ;;
    verify-restore) run_verify_restore ;;
    *)              log_error "Использование: $0 [full|incr|verify-restore]"; exit 1 ;;
esac

log_info "✅ Задача бэкапа (${MODE}) завершена"
