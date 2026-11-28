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

PROBE_INTERVAL=15
FAIL_THRESHOLD=3
COOLDOWN_SEC=3600
FAILBACK_SAMPLES=5
SAMPLE_INTERVAL=30
ARB_KEY="${SCRIPT_DIR}/.ssh/id_ed25519"

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
    local node="$1" ip
    ip=$(resolve_node_ipv4 "${node}") || return 1
    config_db_get EDGE_PROBE_PASSWORD | python3 "${SCRIPT_DIR}/scripts/ops/edge_probe.py" probe \
        "${ip}" "${DOMAIN}" "${HTTPS_PORT:-443}" "${SFTP_PORT:-2022}" "${FTPS_PORT:-21}" \
        "${ARB_KEY}" "${SCRIPT_DIR}/.ssh/edge_known_hosts"
}

publish_etcd_lease() {
    local node
    while IFS= read -r node; do
        if arbiter_ssh "${node}" "etcd-lease $1" >/dev/null 2>&1; then return 0; fi
    done < <(get_node_ips)
    log_warn "Ни одна нода не подтвердила запись active_edge в etcd"
    return 1
}

save_state() {
    python3 "${SCRIPT_DIR}/scripts/ops/arbiter_state.py" "$(state_root)/control.sqlite3" "${1:-write}" \
        "${active}" "${published}" "${failures}" "${switched}" "${samples}" "${last_probe}"
}

publish_edge() {
    local target="$1" address previous="${active}"
    address=$(resolve_node_ipv4 "${target}") || return 1
    # A provider can accept a write even if this process dies before recording the response.
    python3 "${SCRIPT_DIR}/scripts/ops/arbiter_state.py" "$(state_root)/control.sqlite3" pending || return 1
    if ! update_dns_provider "${address}"; then
        log_error "Провайдер не подтвердил переключение на ${target} (${address}). Повтор при следующем опросе."
        return 1
    fi
    active="${target}"; published="${address}"; failures=0; samples=0; last_probe=0
    switched=$(date +%s)
    save_state commit || return 1
    publish_etcd_lease "${address}" || true
    if [[ "${previous}" != "${target}" ]]; then
        arbiter_ssh "${previous}" fence-edge >/dev/null 2>&1 || log_warn "Старый edge ${previous} не подтвердил отключение"
    fi
    log_info "Провайдер подтвердил переключение на ${target} (${address})"
}

replica_ready() {
    local node="$1" peer primary_position="" base
    local -a request=(curl -fsS --max-time 5 --cacert "${SCRIPT_DIR}/prometheus/ca.crt")
    # Capture a write position from the elected primary before observing replay.
    while IFS= read -r peer; do
        base="https://${peer}:${PATRONI_API_PORT:-8008}"
        "${request[@]}" "${base}/primary" >/dev/null 2>&1 || continue
        primary_position=$("${request[@]}" "${base}/patroni" | python3 -c '
import json, sys
r = json.load(sys.stdin)
if r.get("state") != "running" or r.get("role") not in ("master", "primary"): sys.exit(1)
print(int(r["timeline"]), int(r["xlog"]["location"]))') || continue
        break
    done < <(get_node_ips)
    [[ -n "${primary_position}" ]] || return 1
    "${request[@]}" "https://${node}:${PATRONI_API_PORT:-8008}/patroni" | python3 -c '
import json, sys
timeline, minimum = map(int, sys.argv[1].split())
r = json.load(sys.stdin)
if r.get("state") != "running" or r.get("timeline") != timeline: sys.exit(1)
role = r.get("role")
xlog = r.get("xlog") or {}
if role in ("master", "primary"):
    position = xlog.get("location")
elif role == "replica":
    position = xlog.get("replayed_location")
    if position != xlog.get("received_location"): sys.exit(1)
else:
    sys.exit(1)
sys.exit(0 if type(position) is int and position >= minimum else 1)' "${primary_position}"
}

check_failback() {
    local preferred="$1" now="$2"
    if (( now - switched < COOLDOWN_SEC || now - last_probe < SAMPLE_INTERVAL )); then return 0; fi
    last_probe="${now}"
    if replica_ready "${preferred}" && arbiter_ssh "${preferred}" check-gates | grep -Fxq GATES_OK \
        && arbiter_ssh "${preferred}" ensure-sftpgo >/dev/null && probe_edge_node "${preferred}"; then
        samples=$((samples + 1))
    else
        samples=0
    fi
    if (( samples >= FAILBACK_SAMPLES )); then
        publish_edge "${preferred}" || return 1
    else
        save_state
    fi
}

run_once() {
    local primary active published failures switched samples last_probe state endpoint candidate pending=0
    primary=$(get_node_ip 1) || return 1
    state=$(python3 "${SCRIPT_DIR}/scripts/ops/arbiter_state.py" "$(state_root)/control.sqlite3" read) || return 1
    if [[ -n "${state}" ]]; then
        IFS='|' read -r active published failures switched samples last_probe pending <<< "${state}"
    else
        active=$(resolve_current_active_ip) || return 1
        # On a cold start reconcile with the provider even when the active node is healthy.
        published=""; failures=0; switched=0; samples=0; last_probe=0
    fi
    if probe_edge_node "${active}"; then
        endpoint=$(resolve_node_ipv4 "${active}") || return 1
        if (( pending )) || [[ "${endpoint}" != "${published}" ]]; then
            publish_edge "${active}" || return 1
        else
            publish_etcd_lease "${published}" || true
        fi
        if (( failures )); then failures=0; save_state || return 1; fi
        if [[ "${primary}" != "${active}" ]]; then check_failback "${primary}" "$(date +%s)"; fi
        return $?
    fi

    if (( failures < FAIL_THRESHOLD )); then failures=$((failures + 1)); fi
    samples=0; last_probe=0
    save_state || return 1
    log_warn "Клиентская проба ${active} не прошла (${failures}/${FAIL_THRESHOLD})"
    if (( failures < FAIL_THRESHOLD )); then return 0; fi
    while IFS= read -r candidate; do
        [[ "${candidate}" != "${active}" ]] || continue
        if ! probe_edge_node "${candidate}"; then
            arbiter_ssh "${candidate}" ensure-sftpgo >/dev/null 2>&1 && probe_edge_node "${candidate}" || continue
        fi
        publish_edge "${candidate}"
        return $?
    done < <(get_node_ips)
    log_error "Ни один запасной edge не подтвердил работоспособность клиентских протоколов"
    return 1
}

main() {
    load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
    [[ "${DRY_RUN:-false}" != "true" ]] || { log_info "[DRY-RUN] Опрос клиентских протоколов и DNS"; return 0; }
    # One daemon/one-shot writer per local arbiter DB. The DB is never replaced during an update.
    exec 9<"$(state_root)/control.sqlite3"
    flock -n 9 || { log_error "Другой процесс арбитра уже работает"; return 1; }
    if [[ "${1:-}" == "--daemon" ]]; then
        while true; do
            run_once || log_warn "Опрос арбитра завершился с ошибкой"
            sleep "${PROBE_INTERVAL}"
        done
    else
        run_once
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
