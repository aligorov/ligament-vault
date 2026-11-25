#!/usr/bin/env bash
# ============================================================================
# dr-restore.sh — Автоматизированный подъем кластера из внешнего S3 (PITR DR)
# ============================================================================
# Вызов:
#   ./ligactl dr restore [--target-time "YYYY-MM-DD HH:MM:SS+00"|--latest] [--dry-run] [--yes]
#   ./ligactl dr verify-backup [--dry-run]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"

usage() {
    cat <<'EOF'
Использование: ./ligactl dr <подкоманда> [опции]

Подкоманды:
  restore [--latest | --target-time "YYYY-MM-DD HH:MM:SS+00"] [--resume] [--dry-run] [--yes]
          Полное восстановление кластера с нуля на чистых VPS из внешнего S3 (pgBackRest PITR + SeaweedFS)
  verify-backup [--dry-run]
          Пробная расшифровка и проверка целостности бэкапов БД и SeaweedFS без остановки кластера
EOF
}

dr_step_infra() {
    bash "${SCRIPT_DIR}/scripts/stages/00-preflight.sh"
    bash "${SCRIPT_DIR}/scripts/stages/01-host-hardening.sh"
    bash "${SCRIPT_DIR}/scripts/stages/02-pki-secrets.sh"
    for_each_node build_patroni_image_on_node
    render_push_cb() {
        render_node_configs "$1" "$2" "$3" "$4" "new"
        push_node_configs "$1" "$2" "$3" "$4"
    }
    for_each_node render_push_cb
}

dr_step_etcd_and_pg_restore() {
    local target_time="${1:-}"
    local node1_ip
    node1_ip=$(get_node_ip 1)

    log_step "DR 2/4 — Запуск чистого кворума etcd и восстановление PostgreSQL из pgBackRest"
    start_etcd_cb() {
        local ip="$1" name="$3" idx="$4"
        is_quorum_node "${idx}" "${name}" || return 0
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d etcd"
    }
    for_each_node start_etcd_cb

    wait_for_remote_health "${node1_ip}" "etcd quorum" \
        "docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health" 30 3

    # Очищаем ключи старой эпохи Patroni в DCS перед стартом восстановленного PGDATA
    remote_exec "${node1_ip}" "
        docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
            del --prefix '/${CLUSTER_SLUG}/' >/dev/null 2>&1 || true
    "

    local pgbr_opts="--type=default"
    if [[ -n "${target_time}" ]]; then
        pgbr_opts="--type=time --target='${target_time}' --target-action=promote"
    fi

    log_info "Восстановление PGDATA на $(get_node_name 1) (${node1_ip}) через pgBackRest (${pgbr_opts})..."
    remote_exec "${node1_ip}" "
        cd '${REMOTE_BASE_DIR}' && \
        docker compose stop patroni 2>/dev/null || true && \
        rm -rf '${PG_DATA_DIR}/data' && mkdir -p '${PG_DATA_DIR}/data' && \
        docker compose run --rm --no-deps --entrypoint '' -u root patroni bash -c \"
            chown -R postgres:postgres '${PG_DATA_DIR}' /var/log/pgbackrest /var/lib/pgbackrest && \
            chmod 700 '${PG_DATA_DIR}/data' && \
            gosu postgres pgbackrest --stanza='${CLUSTER_SLUG}' --delta ${pgbr_opts} restore
        \"
    "

    log_info "Запуск Patroni Primary на $(get_node_name 1) -> клонирование реплик..."
    remote_exec "${node1_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d patroni"
    wait_for_remote_health "${node1_ip}" "Restored Patroni Primary" \
        "curl -sf http://127.0.0.1:${PATRONI_API_PORT:-8008}/primary" 45 3

    start_rep_cb() {
        local ip="$1" name="$3" idx="$4"
        if (( idx != 1 )); then
            remote_exec "${ip}" "rm -rf '${PG_DATA_DIR}/data' && mkdir -p '${PG_DATA_DIR}/data' && cd '${REMOTE_BASE_DIR}' && docker compose up -d patroni"
            wait_for_remote_health "${ip}" "Patroni Replica ${name}" "curl -sf http://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 60 3
        fi
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d haproxy"
    }
    for_each_node start_rep_cb
}

dr_step_swfs_restore() {
    log_step "DR 3/4 — Подъем SeaweedFS и восстановление метаданных Filer из внешнего S3"
    bash "${SCRIPT_DIR}/scripts/stages/04-bootstrap-swfs.sh"

    local node1_ip
    node1_ip=$(get_node_ip 1)
    if [[ "${BACKUP_S3_ACCESS_KEY:-FIXME}" != *FIXME* && -n "${BACKUP_S3_ACCESS_KEY:-}" ]]; then
        remote_exec_stdin "${node1_ip}" \
            "${SWFS_FILER_PORT:-8888}" \
            "${BACKUP_S3_ENDPOINT}" \
            "${BACKUP_S3_REGION:-us-east-1}" \
            "${BACKUP_S3_BUCKET}" \
            "${BACKUP_S3_ACCESS_KEY}" \
            "${BACKUP_S3_SECRET_KEY}" \
            "${BACKUP_ENCRYPTION_KEY}" <<'REMOTE_SWFS_RESTORE' || log_warn "Дамп filer-meta/LATEST не найден — используются метаданные из восстановленной БД PostgreSQL"
set -euo pipefail
FPORT="$1"; ENDPOINT="$2"; REGION="$3"; BUCKET="$4"; AK="$5"; SK="$6"; ENC_KEY="$7"
TMP_ENC="/tmp/dr-filer.meta.gz.enc"
TMP_RAW="/tmp/dr-filer.meta"
CID=$(docker ps -qf name=swfs-filer)
trap 'rm -f "${TMP_ENC}" "${TMP_RAW}"; docker exec "${CID}" rm -f "${TMP_RAW}" 2>/dev/null || true' EXIT

python3 - "${ENDPOINT}" "${REGION}" "${BUCKET}" "${AK}" "${SK}" "${TMP_ENC}" <<'PYEOF'
import datetime, hashlib, hmac, sys, urllib.parse, urllib.request
endpoint, region, bucket, ak, sk, dst = sys.argv[1:]
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
    return urllib.request.urlopen(urllib.request.Request(f"{endpoint}{path}", headers=hdrs), timeout=45).read()

latest = s3_get("filer-meta/LATEST").decode().strip()
open(dst, "wb").write(s3_get(latest))
PYEOF

ENCK="${ENC_KEY}" openssl enc -d -aes-256-cbc -pbkdf2 -pass env:ENCK -in "${TMP_ENC}" | gunzip > "${TMP_RAW}"
docker cp "${TMP_RAW}" "${CID}:${TMP_RAW}"
docker exec "${CID}" weed filer.meta.restore -filer="127.0.0.1:${FPORT}" -input="${TMP_RAW}" || true
REMOTE_SWFS_RESTORE
    fi
}

dr_step_edge_and_verify() {
    log_step "DR 4/4 — Запуск SFTPGo Edge, Арбитра и финальная валидация"
    bash "${SCRIPT_DIR}/scripts/stages/05-edge-ssl-backup.sh"
    bash "${SCRIPT_DIR}/scripts/verify/cluster-health.sh" --strict
}

cmd_restore() {
    local target_time=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target-time) target_time="$2"; shift 2 ;;
            --latest)      target_time=""; shift ;;
            *)             log_error "Неизвестный флаг dr restore: $1"; usage; exit 1 ;;
        esac
    done

    if [[ "${DRY_RUN:-false}" != "true" ]] && [[ "${BACKUP_S3_ACCESS_KEY:-FIXME}" == *FIXME* || -z "${BACKUP_S3_ACCESS_KEY:-}" ]]; then
        log_error "Для DR-восстановления заполните BACKUP_S3_* и BACKUP_ENCRYPTION_KEY в секретах!"
        exit 1
    fi

    confirm_action "⚠️  ВНИМАНИЕ: DR Restore перезапишет данные кластера из внешнего S3 (${target_time:-LATEST}). Продолжить?" || exit 0

    init_op_checkpoints "dr-restore"
    run_checkpoint "dr-restore" "1-infra-pki"      dr_step_infra
    run_checkpoint "dr-restore" "2-etcd-pg-pitr"   dr_step_etcd_and_pg_restore "${target_time}"
    run_checkpoint "dr-restore" "3-swfs-restore"   dr_step_swfs_restore
    run_checkpoint "dr-restore" "4-edge-verify"    dr_step_edge_and_verify
    clear_op_checkpoints "dr-restore"

    [[ "${DRY_RUN:-false}" != "true" ]] && touch "$(state_root)/.cluster_installed"
    log_info "🎉 Аварийное восстановление ${PROJECT_NAME} из внешнего S3 успешно завершено!"
}

main() {
    local sub="${1:-}"
    shift || true
    case "${sub}" in
        restore)        cmd_restore "$@" ;;
        verify-backup)  bash "${SCRIPT_DIR}/scripts/ops/backup-job.sh" verify-restore ;;
        ""|--help|-h|help) usage ;;
        *) log_error "Неизвестная подкоманда dr: ${sub}"; usage; exit 1 ;;
    esac
}

main "$@"
