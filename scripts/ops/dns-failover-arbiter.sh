#!/usr/bin/env bash
# ============================================================================
# dns-failover-arbiter.sh — Внешний Арбитр Failover (DNS / Floating IP) & 5-Gate Failback
# ============================================================================
# Работает на внешней VPS-арбитре с минимальными привилегиями:
#   - Не хранит ключей БД/KMS/JWT (только DNS / Floating-IP API токены)
#   - Опрашивает Patroni напрямую по HTTP (:8008/patroni)
#   - При отказе вызывает TCP RST fencing (fence-edge) на старом узле, чтобы
#     клиенты мгновенно переподключились на новый Active Edge без зависания TCP!
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"

STATE_DIR="/var/lib/${CLUSTER_SLUG}-arbiter"
[[ -w /var/lib ]] || STATE_DIR="$(state_root)/.arbiter_state"
FAIL_COUNT_FILE="${STATE_DIR}/fail_count"
LAST_SWITCH_FILE="${STATE_DIR}/last_switch_epoch"
ACTIVE_NODE_FILE="${STATE_DIR}/active_ip"
ARB_KEY="${SCRIPT_DIR}/.ssh/id_ed25519"

PROBE_INTERVAL=15
FAIL_THRESHOLD=3
COOLDOWN_SEC=3600

mkdir -p "${STATE_DIR}"

arbiter_ssh() {
    local ip="$1" subcmd="$2"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] arbiter_ssh ${ip} '${subcmd}'"
        return 0
    fi
    local opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 -o BatchMode=yes"
    [[ -f "${ARB_KEY}" ]] && opts+=" -i ${ARB_KEY}"
    [[ -n "${ADMIN_SSH_PORT:-}" && "${ADMIN_SSH_PORT}" != "22" ]] && opts+=" -p ${ADMIN_SSH_PORT}"
    # shellcheck disable=SC2086
    ssh ${opts} "root@${ip}" "${subcmd}"
}

probe_edge_node() {
    local ip="$1"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    curl -sf --max-time 5 --insecure "https://${ip}:${HTTPS_PORT:-443}/web/client/login" >/dev/null 2>&1 || return 1
    nc -z -w 4 "${ip}" "${SFTP_PORT:-2022}" >/dev/null 2>&1 || return 1
    return 0
}

publish_etcd_lease() {
    local active_ip="$1"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    for i in 1 2 3; do
        local q_ip
        q_ip=$(get_node_ip "$i")
        if arbiter_ssh "${q_ip}" "etcd-lease ${active_ip}" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 0
}

update_endpoint_record() {
    local target_ip="$1"
    update_dns_provider "${target_ip}"
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        echo "${target_ip}" > "${ACTIVE_NODE_FILE}"
        date +%s > "${LAST_SWITCH_FILE}"
    fi
    publish_etcd_lease "${target_ip}"
}

check_failback_gates() {
    local preferred_ip="$1"
    log_info "Проверка 5 ворот авто-failback на ${preferred_ip}..."

    local now last_switch=0
    now=$(date +%s)
    [[ -f "${LAST_SWITCH_FILE}" ]] && last_switch=$(cat "${LAST_SWITCH_FILE}")
    if (( now - last_switch < COOLDOWN_SEC )); then
        log_info "Gate 5 BLOCK: не прошел cooldown (${COOLDOWN_SEC}s)"
        return 1
    fi

    local pg_ok="FAIL"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        pg_ok="OK"
    else
        pg_ok=$(curl -sf --max-time 5 "http://${preferred_ip}:${PATRONI_API_PORT:-8008}/patroni" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("state") != "running":
    sys.exit(1)
xlog = d.get("xlog") or {}
if d.get("role") == "replica" and xlog.get("received_location") != xlog.get("replayed_location"):
    sys.exit(1)
print("OK")
' 2>/dev/null || echo "FAIL")
    fi
    if [[ "${pg_ok}" != "OK" ]]; then
        log_info "Gate 1 BLOCK: Patroni/PG не синхронизирован на ${preferred_ip}"
        return 1
    fi

    if ! arbiter_ssh "${preferred_ip}" "check-gates" | grep -q "GATES_OK"; then
        log_info "Gates 2/3 BLOCK: etcd или репликация SeaweedFS не в норме на ${preferred_ip}"
        return 1
    fi

    # Поднимаем sftpgo на кандидате перед сквозными пробами Gate 4 (если был в fence-edge)
    arbiter_ssh "${preferred_ip}" "restart-sftpgo" >/dev/null 2>&1 || true

    for attempt in 1 2 3 4 5; do
        if ! probe_edge_node "${preferred_ip}"; then
            log_info "Gate 4 BLOCK: проба ${attempt}/5 на ${preferred_ip} провалена"
            return 1
        fi
        [[ ${attempt} -lt 5 ]] && run_or_dry sleep 30
    done

    log_info "✅ Все 5 ворот failback пройдены!"
    return 0
}

run_once() {
    local primary_edge_ip active_ip fails=0
    primary_edge_ip=$(get_node_ip 1)
    active_ip=$(cat "${ACTIVE_NODE_FILE}" 2>/dev/null || resolve_current_active_ip)
    [[ -f "${FAIL_COUNT_FILE}" ]] && fails=$(cat "${FAIL_COUNT_FILE}")

    if probe_edge_node "${active_ip}"; then
        echo "0" > "${FAIL_COUNT_FILE}"
        publish_etcd_lease "${active_ip}"
        log_debug "Active Edge ${active_ip}: OK"

        if [[ "${active_ip}" != "${primary_edge_ip}" ]]; then
            if check_failback_gates "${primary_edge_ip}"; then
                log_info "FAILBACK на ${primary_edge_ip}: рестарт sftpgo + переключение (${FAILOVER_MODE:-dns})..."
                arbiter_ssh "${primary_edge_ip}" "restart-sftpgo"
                update_endpoint_record "${primary_edge_ip}"
            fi
        fi
    else
        fails=$((fails + 1))
        echo "${fails}" > "${FAIL_COUNT_FILE}"
        log_warn "Active Edge ${active_ip} не отвечает (${fails}/${FAIL_THRESHOLD})"

        if (( fails >= FAIL_THRESHOLD )); then
            local count candidate_ip=""
            count=$(get_node_count)
            for i in $(seq 1 "${count}"); do
                local ip
                ip=$(get_node_ip "$i")
                if [[ "${ip}" != "${active_ip}" ]] && probe_edge_node "${ip}"; then
                    candidate_ip="${ip}"
                    break
                fi
            done

            if [[ -n "${candidate_ip}" ]]; then
                log_warn "FAILOVER: изоляция ${active_ip} (TCP RST fence-edge) -> переключение на ${candidate_ip}!"
                arbiter_ssh "${active_ip}" "fence-edge" >/dev/null 2>&1 || true
                arbiter_ssh "${candidate_ip}" "restart-sftpgo"
                update_endpoint_record "${candidate_ip}"
                echo "0" > "${FAIL_COUNT_FILE}"
            else
                log_error "КРИТИЧНО: ни один резервный Edge-узел не прошел пробу!"
                exit 1
            fi
        fi
    fi
}

if [[ "${1:-}" == "--daemon" ]]; then
    log_info "Арбитр ${PROJECT_NAME} запущен в режиме демона (шаг ${PROBE_INTERVAL}s, режим ${FAILOVER_MODE:-dns})..."
    while true; do
        run_once || true
        sleep "${PROBE_INTERVAL}"
    done
else
    run_once
fi
