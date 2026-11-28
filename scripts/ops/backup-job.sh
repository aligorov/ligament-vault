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
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

source "${SCRIPT_DIR}/scripts/ops/file-snapshot.sh"
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
    primary_ip=$(find_patroni_primary_ip) || return 1

    log_step "pgBackRest (${type}, stanza=${CLUSTER_SLUG}) на Primary ${primary_ip}"
    if ! remote_exec "${primary_ip}" "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1); [[ -n \"\${CID}\" ]] && docker exec -u postgres \"\${CID}\" pgbackrest --stanza='${CLUSTER_SLUG}' --type=${type} backup"; then
        write_backup_metrics "${primary_ip}" 0 false
        return 1
    fi
}

run_swfs_backup() {
    local count primary cut info label at idx
    count=$(get_node_count)
    primary=$(find_patroni_primary_ip) || return 1
    SNAPSHOT_ID=$(python3 -c 'import uuid;print(uuid.uuid4().hex)')
    for ((idx=1; idx<=count; idx++)); do snapshot_on_node "${idx}" capture || return $?; done
    snapshot_on_node 1 objects || return 1
    info=$(remote_exec_stdin "${primary}" "${REMOTE_BASE_DIR}" "${CLUSTER_SLUG}" "${SNAPSHOT_ID}" "${PG_PORT}" <<'REMOTE_CUT'
set -euo pipefail
cd "$1"
cid=$(docker compose ps -q patroni)
label=$(docker exec -u postgres "${cid}" pgbackrest --stanza="$2" info --output=json | jq -er '.[0].backup[-1].label')
sql=(docker exec -u postgres "${cid}" psql -p "$4" -XAt -v ON_ERROR_STOP=1 -d postgres)
[[ "$("${sql[@]}" -c "select pg_is_in_recovery()")" == f ]]
at=$("${sql[@]}" -c "select to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD HH24:MI:SS.US') || '+00:00' from pg_create_restore_point('lv_$3')")
"${sql[@]}" -c 'select pg_switch_wal()' >/dev/null
docker exec -u postgres "${cid}" pgbackrest --stanza="$2" check >&2
printf '%s|%s\n' "${label}" "${at}"
REMOTE_CUT
) || return 1
    cut=$(printf '%s\n' "${info}" | tail -n1)
    IFS='|' read -r label at <<< "${cut}"
    for ((idx=1; idx<=count; idx++)); do snapshot_on_node "${idx}" stable || return $?; done
    snapshot_on_node 1 check-objects || return 1
    snapshot_controller verify --id "${SNAPSHOT_ID}" --nodes "${count}" || return 1
    snapshot_controller commit --id "${SNAPSHOT_ID}" --at "${at}" --label "${label}" --nodes "${count}"
}

snapshot_with_retry() {
    local attempt status
    for attempt in 1 2 3; do
        if run_swfs_backup; then return 0; else status=$?; fi
        [[ "${status}" == 75 && "${attempt}" != 3 ]] || return "${status}"
        log_warn "Тома менялись во время снятия копии. Повтор ${attempt}/3"
        sleep "$((2 * attempt))"
    done
}

run_verify_restore() {
    local primary point label at
    primary=$(find_patroni_primary_ip) || return 1
    point=$(snapshot_controller select --nodes "$(get_node_count)") || return 1
    read -r SNAPSHOT_ID label at <<< "${point}"
    snapshot_controller verify --id "${SNAPSHOT_ID}" --nodes "$(get_node_count)" || return 1
    remote_exec_stdin "${primary}" "${REMOTE_BASE_DIR}" "${CLUSTER_SLUG}" "${label}" "lv_${SNAPSHOT_ID}" <<'VERIFY_PG'
set -euo pipefail
cd "$1"
cid=$(docker compose ps -q patroni)
docker exec -i -u postgres "${cid}" bash -s -- "$2" "$3" "$4" <<'PG'
set -euo pipefail
d=$(mktemp -d /tmp/pgbr-verify.XXXXXXXX)
cleanup() { pg_ctl -D "$d/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf -- "$d"; }
trap cleanup EXIT
pgbackrest --stanza="$1" --set="$2" --type=name --target="$3" --target-action=promote --pg1-path="$d/data" restore
mkdir "$d/socket"
pg_ctl -D "$d/data" -l "$d/log" -w -t 120 -o "-p 55432 -k $d/socket -c data_directory=$d/data -c listen_addresses='' -c archive_mode=off -c ssl=off" start
for ((i=0;i<120;i++)); do
    ready=$(psql -XAt -v ON_ERROR_STOP=1 -h "$d/socket" -p 55432 -d postgres -c 'SELECT NOT pg_is_in_recovery()')
    [[ "${ready}" == t ]] && break
    sleep 1
done
[[ "${ready}" == t ]]
PG
VERIFY_PG
}

case "${MODE}" in
    full|incr)
        if [[ "${DRY_RUN:-false}" == true ]]; then log_info "[DRY-RUN] PostgreSQL + SeaweedFS volume snapshot"; exit 0; fi
        admin=$(get_node_ip "${SWFS_ADMIN_NODE_INDEX:-2}")
        if run_pgbackrest "${MODE}" && snapshot_with_retry; then
            write_backup_metrics "${admin}" 1 true
        else
            write_backup_metrics "${admin}" 0 false
            exit 1
        fi ;;
    verify-restore)
        if [[ "${DRY_RUN:-false}" == true ]]; then log_info "[DRY-RUN] Verify physical snapshot and PG restore"; exit 0; fi
        run_verify_restore ;;
    *) log_error "Использование: $0 [full|incr|verify-restore]"; exit 1 ;;
esac
log_info "Задача бэкапа (${MODE}) завершена"
