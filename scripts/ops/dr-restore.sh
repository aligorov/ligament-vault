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

source "${SCRIPT_DIR}/scripts/ops/file-snapshot.sh"
load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"

usage() {
    cat <<'EOF'
Использование: ./ligactl dr <подкоманда> [опции]

Подкоманды:
  restore [--latest | --target-time "YYYY-MM-DD HH:MM:SS+00"] [--resume] [--dry-run] [--yes]
          Полное восстановление на чистых VPS из S3. --target-time принимает точное время опубликованного совместного снимка БД и томов (UTC).
  list    Доступные совместные точки восстановления (UTC, набор PostgreSQL, число нод, ID).
  verify-backup [--dry-run]
          Пробная расшифровка и проверка целостности бэкапов БД и SeaweedFS без остановки кластера
EOF
}

dr_step_infra() {
    bash "${SCRIPT_DIR}/scripts/stages/00-preflight.sh" || return 1
    bash "${SCRIPT_DIR}/scripts/stages/01-host-hardening.sh" || return 1
    bash "${SCRIPT_DIR}/scripts/stages/02-pki-secrets.sh" || return 1
    for_each_node build_patroni_image_on_node || return 1
    render_push_cb() {
        render_node_configs "$1" "$2" "$3" "$4" "new" || return 1
        push_node_configs "$1" "$2" "$3" "$4"
    }
    for_each_node render_push_cb
}

dr_check_destination() {
    local idx ip
    for ((idx=1;idx<=$(get_node_count);idx++)); do
        ip=$(get_node_ip "${idx}") || return 1
        remote_exec_stdin "${ip}" "${REMOTE_BASE_DIR}" "${PG_DATA_DIR}" "${SNAPSHOT_ID}" <<'CHECK' || return 1
set -euo pipefail
cd "$1"
marker=".dr-source-point"
if [[ -f "${marker}" ]]; then
    [[ "$(cat "${marker}")" == "$3" ]] || { echo "Destination belongs to another restore" >&2; exit 1; }
else
    [[ ! -s "$2/data/PG_VERSION" && -z "$(docker compose ps -q patroni)" && -z "$(docker compose ps -q swfs-volume)" ]] ||
        { echo "DR destination contains an existing PostgreSQL or SeaweedFS installation" >&2; exit 1; }
    umask 077
    printf '%s\n' "$3" > "${marker}"
fi
CHECK
        snapshot_on_node "${idx}" destination || return 1
    done
    ip=$(get_node_ip 1) || return 1
    remote_exec_stdin "${ip}" "${REMOTE_BASE_DIR}" "${CLUSTER_SLUG}" "${BACKUP_LABEL}" <<'CHECK_PG_SET'
set -euo pipefail
cd "$1"
docker compose run -T --rm --no-deps --entrypoint pgbackrest patroni --stanza="$2" info --output=json |
    jq -e --arg label "$3" 'any(.[0].backup[]; .label == $label and .error != true)' >/dev/null
CHECK_PG_SET
}

dr_step_etcd_and_pg_restore() {
    local node1_ip
    node1_ip=$(get_node_ip 1)

    log_step "DR 2/4 — Запуск чистого кворума etcd и восстановление PostgreSQL из pgBackRest"
    start_etcd_cb() {
        local ip="$1" name="$3" idx="$4"
        is_quorum_node "${idx}" "${name}" || return 0
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d etcd"
    }
    for_each_node start_etcd_cb || return 1

    wait_for_remote_health "${node1_ip}" "etcd quorum" \
        "ETCD_CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1); [ -n \"\${ETCD_CID}\" ] && docker exec \"\${ETCD_CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health" 30 3 || return 1

    # A clean DCS has no Patroni leader. Never delete a live cluster's keys.
    log_info "Восстановление PostgreSQL до именованной точки lv_${SNAPSHOT_ID} из ${BACKUP_LABEL}"
    remote_exec_stdin "${node1_ip}" "${REMOTE_BASE_DIR}" "${PG_DATA_DIR}" "${CLUSTER_SLUG}" "${BACKUP_LABEL}" "${SNAPSHOT_ID}" <<'REMOTE_PG' || return 1
set -euo pipefail
cd "$1"
[[ -n "$2" && "$2" != "/" && "$2" == /* ]]
[[ -z "$(docker compose ps -q patroni)" ]] || { echo 'Destination Patroni must be offline' >&2; exit 1; }
mkdir -p "$2/data"
docker compose run -T --rm --no-deps --entrypoint bash -u root patroni -s -- "$2" "$3" "$4" "$5" <<'PG'
set -euo pipefail
chown -R postgres:postgres "$1" /var/log/pgbackrest /var/lib/pgbackrest
chmod 700 "$1/data"
gosu postgres pgbackrest --stanza="$2" --set="$3" --type=name --target="lv_$4" --target-action=promote --delta restore
# Complete WAL replay before Patroni takes ownership of recovery configuration.
d=$(mktemp -d)
chown postgres:postgres "$d"
stop_pg() {
    gosu postgres pg_ctl -D "$1/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf -- "$d"
}
trap 'stop_pg "$1"' EXIT
gosu postgres pg_ctl -D "$1/data" -l "$d/recovery.log" -w -t 120 -o "-p 55432 -k $d -c data_directory=$1/data -c listen_addresses='' -c archive_mode=off -c ssl=off" start
for ((i=0;i<120;i++)); do
    ready=$(gosu postgres psql -XAt -v ON_ERROR_STOP=1 -h "$d" -p 55432 -d postgres -c 'SELECT NOT pg_is_in_recovery()')
    [[ "${ready}" == t ]] && break
    sleep 1
done
[[ "${ready}" == t ]]
gosu postgres pg_ctl -D "$1/data" -m fast -w stop
PG
REMOTE_PG

    log_info "Запуск Patroni Primary на $(get_node_name 1) -> клонирование реплик..."
    remote_exec "${node1_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d patroni" || return 1
    wait_for_remote_health "${node1_ip}" "Restored Patroni Primary" \
        "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/primary" 45 3 || return 1

    start_rep_cb() {
        local ip="$1" name="$3" idx="$4"
        if (( idx != 1 )); then
            remote_exec "${ip}" "mkdir -p '${PG_DATA_DIR}/data' && cd '${REMOTE_BASE_DIR}' && docker compose up -d patroni" || return 1
            wait_for_remote_health "${ip}" "Patroni Replica ${name}" "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 60 3 || return 1
        fi
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d haproxy"
    }
    for_each_node start_rep_cb
}

dr_step_swfs_restore() {
    local count idx
    count=$(get_node_count) || return 1
    log_step "DR 3/4 — восстановление физических томов SeaweedFS и проверка версий и WORM"
    for ((idx=1;idx<=count;idx++)); do
        snapshot_on_node "${idx}" restore || return 1
    done
    bash "${SCRIPT_DIR}/scripts/stages/04-bootstrap-swfs.sh" || return 1
    snapshot_on_node 1 check-objects
}

dr_step_edge_and_verify() {
    log_step "DR 4/4 — Запуск SFTPGo Edge, Арбитра и финальная валидация"
    bash "${SCRIPT_DIR}/scripts/stages/05-edge-ssl-backup.sh" || return 1
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

    if [[ "${DRY_RUN:-false}" == true ]]; then
        log_info "[DRY-RUN] Проверка архива, PG PITR, восстановление томов, проверка файлов и WORM"
        return 0
    fi
    local point operation at count
    local args=()
    count=$(get_node_count)
    [[ -z "${target_time}" ]] || args+=(--at "${target_time}")
    point=$(snapshot_controller select --nodes "${count}" "${args[@]}") || return 1
    read -r SNAPSHOT_ID BACKUP_LABEL at <<< "${point}"
    log_step "Полная точка восстановления ${at}, PG ${BACKUP_LABEL}, файловые тома ${SNAPSHOT_ID}"
    snapshot_controller verify --id "${SNAPSHOT_ID}" --nodes "${count}" || return 1
    confirm_action "Восстановить кластер на чистых узлах из этой точки?" || return 1
    operation="dr-restore-${SNAPSHOT_ID}"
    init_op_checkpoints "${operation}"
    run_checkpoint "${operation}" "1-infra-pki" dr_step_infra
    run_checkpoint "${operation}" "1a-clean-destination" dr_check_destination
    run_checkpoint "${operation}" "2-etcd-pg-pitr" dr_step_etcd_and_pg_restore
    run_checkpoint "${operation}" "3-swfs-restore" dr_step_swfs_restore
    run_checkpoint "${operation}" "4-edge-verify" dr_step_edge_and_verify
    clear_op_checkpoints "${operation}"

    [[ "${DRY_RUN:-false}" != "true" ]] && touch "$(state_root)/.cluster_installed"
    log_info "🎉 Аварийное восстановление ${PROJECT_NAME} из внешнего S3 успешно завершено!"
}

main() {
    local sub="${1:-}"
    shift || true
    case "${sub}" in
        restore)        cmd_restore "$@" ;;
        list)           snapshot_controller list ;;
        verify-backup)  bash "${SCRIPT_DIR}/scripts/ops/backup-job.sh" verify-restore ;;
        ""|--help|-h|help) usage ;;
        *) log_error "Неизвестная подкоманда dr: ${sub}"; usage; exit 1 ;;
    esac
}

main "$@"
