#!/usr/bin/env bash
# ============================================================================
# scale-cluster.sh — Масштабирование, замена и вывод узлов (Day-2)
# ============================================================================
# Вызов: ./clusterctl scale <add|replace|remove|expand-disk> [опции]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
offline_peers=" "

usage() {
    cat <<'EOF'
Использование: ./clusterctl scale <подкоманда> [опции]

Подкоманды:
  add          --ip <IP> --dc <dc4> [--name <nodeN>] [--role edge|quorum] [--rebalance]
  replace      --old <node> --new-ip <IP>
  remove       --node <node>
  expand-disk  --node <node> --dir </mnt/nvme2> [--max-volumes <N>]
EOF
}

# The caller holds the operation lock. Persist the inventory only after live verification.
select_quorum_helper() {
    local excluded="$1" i host node
    for i in $(seq 1 "$(get_node_count)"); do
        host=$(get_node_ip "$i"); node=$(get_node_name "$i")
        [[ "$host" != "$excluded" ]] && is_quorum_node "$i" "$node" || continue
        if [[ "${DRY_RUN:-false}" == true ]] || remote_exec "$host" "cd '${REMOTE_BASE_DIR}' && docker compose exec -T etcd etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --dial-timeout=3s --command-timeout=6s --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health" >/dev/null 2>&1; then
            echo "$host"
            return 0
        fi
    done
    log_error "Для изменения состава нужен доступный голосующий участник с кворумом" >&2
    return 1
}

reconcile_member() {
    local helper="$1" operation="$2" name="$3" host="$4" old_host="${5:-}" previous=""
    [[ -z "$old_host" ]] || previous="https://${old_host}:${ETCD_PEER_PORT:-2380}"
    remote_exec_stdin "$helper" "$REMOTE_BASE_DIR" "${ETCD_CLIENT_PORT:-2379}" "$operation" "etcd-$name" \
        "https://${host}:${ETCD_PEER_PORT:-2380}" "$previous" < "${SCRIPT_DIR}/scripts/lib/etcd-member.sh"
}

maintain_volumes() {
    local joined="" retired=""
    [[ -z "${3:-}" ]] || joined="$3:${SWFS_VOLUME_PORT:-8082}"
    [[ -z "${5:-}" || "${5:-}" == "${3:-}" ]] || retired="$5:${SWFS_VOLUME_PORT:-8082}"
    remote_exec_stdin "$1" "$REMOTE_BASE_DIR" "$(build_swfs_master_peers)" "${SWFS_FILER_PORT:-8888}" "$2" "$joined" "${4:-}" "$retired" \
        < "${SCRIPT_DIR}/scripts/lib/seaweed-maintenance.sh"
    verify_volume_placement "$1"
}

# Match the actual Raft IDs in the pinned SeaweedFS version (host:httpPort[.grpcPort]).
reconcile_masters() {
    remote_exec_stdin "$1" "$REMOTE_BASE_DIR" "$(build_swfs_master_peers)" "${SWFS_FILER_PORT:-8888}" \
        "${2:-}" "${SWFS_MASTER_PORT:-9333}" < "${SCRIPT_DIR}/scripts/lib/seaweed-members.sh"
}

validate_node_identity() {
    python3 - "${SCRIPT_DIR}/scripts/lib" "$@" <<'PY'
import re, sys
lib, host, dc, name = sys.argv[1:]
sys.path.insert(0, lib)
from node_address import valid_node_address
label = r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
if not valid_node_address(host):
    sys.exit("Invalid node FQDN or IPv4 address")
if not re.fullmatch(r"[a-z][a-z0-9_]{0,62}", name) or not re.fullmatch(label, dc):
    sys.exit("Invalid node name or data centre")
PY
}

sync_topology_node() {
    [[ "$offline_peers" != *" $3 "* ]] || return 0
    render_node_configs "$1" "$2" "$3" "$4" existing
    push_node_configs "$1" "$2" "$3" "$4"
}

reload_peer() {
    local host="$1" target="$5"
    [[ "$host" != "$target" && "$offline_peers" != *" $3 "* ]] || return 0
    reload_node_haproxy "$host"
    remote_exec "$host" "cd '${REMOTE_BASE_DIR}' && docker compose kill -s HUP sftpgo"
}

start_verified_node() {
    local host="$1" name="$2" idx="$3" helper="$4" previous="${5:-}"
    if is_quorum_node "$idx" "$name"; then
        local action=prepare
        # Replacement at the same DNS address with an empty etcd disk has a new identity.
        if [[ "$previous" == "$host" && "${DRY_RUN:-false}" != true ]] &&
            remote_exec "$host" "test ! -s '${ETCD_DATA_DIR:-/data/etcd}/member/snap/db'"; then action=prepare-empty; fi
        reconcile_member "$helper" "$action" "$name" "$host" "$previous"
        remote_exec "$host" "cd '${REMOTE_BASE_DIR}' && docker compose up -d etcd"
        reconcile_member "$helper" promote "$name" "$host"
    fi
    remote_exec "$host" "cd '${REMOTE_BASE_DIR}' && docker compose up -d"
    # A successfully rejoined node can already have become the new primary.
    wait_for_remote_health "$host" "PostgreSQL $name" \
        "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/read-write || curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 45 3
    if is_quorum_node "$idx" "$name"; then
        if [[ "$previous" == "$host" ]]; then previous=""; fi
        reconcile_masters "$helper" "$previous"
    fi
    for_each_node reload_peer "$host"
    wait_for_remote_health "$host" "SFTPGo и SeaweedFS $name" \
        "cd '$REMOTE_BASE_DIR' && docker compose exec -T sftpgo sftpgo ping --config-file /etc/sftpgo/sftpgo.json && curl -fsS --max-time 4 'http://127.0.0.1:${SWFS_FILER_PORT:-8888}/healthz'" 30 3
}

maybe_sync_arbiter_key_to_node() {
    local target_ip="$1"
    if [[ -n "${ARBITER_IP:-}" && "${DRY_RUN:-false}" != "true" ]]; then
        local arb_pub
        arb_pub=$(remote_exec "${ARBITER_IP}" "awk '{print \$1 \" \" \$2}' '${ARBITER_BASE_DIR}/.ssh/id_ed25519.pub'" 2>/dev/null || echo "")
        [[ -n "${arb_pub}" ]] && install_arbiter_helper_on_node "${target_ip}" "${arb_pub}"
    fi
}

cmd_add() {
    local host="" dc="" name="" role=edge balance="${VOLUME_BALANCE_AFTER_ADD:-true}"
    while (($#)); do
        case "$1" in
            --ip) host="$2"; shift 2 ;;
            --dc) dc="$2"; shift 2 ;;
            --name) name="$2"; shift 2 ;;
            --role) role="$2"; shift 2 ;;
            --rebalance) balance=true; shift ;;
            *) usage; return 1 ;;
        esac
    done
    [[ -n "$host" && -n "$dc" && ( "$role" == edge || "$role" == quorum ) ]] || { usage; return 1; }
    local idx="" i cur_host cur_name helper primary suffix
    ensure_quorum_nodes_initialized
    for i in $(seq 1 "$(get_node_count)"); do
        cur_host=$(get_node_ip "$i"); cur_name=$(get_node_name "$i")
        if [[ "$cur_host" == "$host" || ( -n "$name" && "$name" == "$cur_name" ) ]]; then
            if [[ "$cur_host" != "$host" || "${name:-$cur_name}" != "$cur_name" || "$(get_node_dc "$i")" != "$dc" ]]; then
                log_error "Имя или адрес уже заняты"; return 1
            fi
            if is_quorum_node "$i" "$cur_name" && [[ "$role" != quorum ]]; then
                log_error "Узел уже входит в кворум"; return 1
            fi
            idx="$i"; name="$cur_name"; break
        fi
    done
    if [[ -z "$idx" ]]; then
        idx=$(($(get_node_count)+1))
        if [[ -z "$name" ]]; then
            suffix=$idx
            while find_node_by_name "node$suffix" >/dev/null; do suffix=$((suffix+1)); done
            name="node$suffix"
        fi
    fi
    validate_node_identity "$host" "$dc" "$name"
    helper=$(select_quorum_helper "$host") || return 1
    primary=$(find_patroni_primary_ip) || { log_error "Нет доступного primary"; return 1; }
    if [[ "${DRY_RUN:-false}" != true ]]; then
        remote_exec "$host" true
        local rtt
        rtt=$(remote_exec_stdin "$helper" "$host" "${ADMIN_SSH_PORT:-22}" <<'TCP_RTT'
set -eu
python3 - "$@" <<'PY'
import socket, statistics, sys, time
samples = []
for _ in range(3):
    start = time.monotonic()
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5):
        samples.append((time.monotonic() - start) * 1000)
print(round(statistics.median(samples)))
PY
TCP_RTT
)
        if [[ ! "$rtt" =~ ^[0-9]+$ ]] || (( rtt > ${RTT_HARD_STOP:-1000} )); then
            log_error "Не удалось подтвердить приемлемый RTT до $host"; return 1
        fi
    fi
    if [[ "$role" == quorum && " $QUORUM_NODES " != *" $name "* ]]; then
        local voters
        read -ra voters <<< "$QUORUM_NODES"
        if (( ${#voters[@]} >= ${MAX_ETCD_VOTERS:-5} )); then log_error "Достигнут лимит голосующих узлов"; return 1; fi
        QUORUM_NODES+=" $name"
    fi
    if (( idx > $(get_node_count) )); then CLUSTER_NODES+=" $host:$dc:$name"; fi
    log_step "Добавление $name ($host, $dc, $role)"
    prepare_node "$host" "$dc" "$name" "$idx"
    remote_exec "$primary" "cd '${REMOTE_BASE_DIR}' && docker compose exec -T patroni patronictl -c /run/pg-certs/patroni.yml edit-config '${CLUSTER_SLUG}' --force --set 'slots.${name}.type=physical'"
    start_verified_node "$host" "$name" "$idx" "$helper"
    maintain_volumes "$helper" "$balance" "$host" "$dc"
    if [[ "${DRY_RUN:-false}" != true ]]; then config_db_set_many CLUSTER_NODES "$CLUSTER_NODES" QUORUM_NODES "$QUORUM_NODES"; fi
    log_info "Узел $name введён; состав и размещение томов проверены"
}

prepare_node() {
    local host="$1" dc="$2" name="$3" idx="$4" i peer peer_name
    for i in $(seq 1 "$(get_node_count)"); do
        [[ "$i" == "$idx" ]] && continue
        peer=$(get_node_ip "$i"); peer_name=$(get_node_name "$i")
        if ! remote_exec "$peer" true >/dev/null 2>&1; then
            offline_peers+="$peer_name "
            log_warn "$peer_name ($peer) недоступен по SSH. При его возвращении синхронизируйте конфигурацию через ligactl sync-config."
            continue
        fi
        harden_node_ufw "$peer" "$(get_node_dc "$i")" "$peer_name" "$i"
    done
    harden_node_full "$host" "$dc" "$name" "$idx"
    maybe_sync_arbiter_key_to_node "$host"
    ensure_ca_exists
    if [[ "${DRY_RUN:-false}" == true ]] || ! remote_exec_stdin "$host" "$REMOTE_BASE_DIR/certs/$name" "$host" "${PKI_ROLES[@]}" <<'CHECK_CERTS'
set -euo pipefail
dir="$1"; address="$2"; shift 2
for role in "$@"; do
    [[ -s "$dir/$role.key" && -s "$dir/$role.crt" ]]
    openssl verify -CAfile "$dir/ca.crt" -CRLfile "$dir/crl.pem" -crl_check "$dir/$role.crt" >/dev/null
    [[ "$(openssl x509 -noout -pubkey -in "$dir/$role.crt")" == "$(openssl pkey -pubout -in "$dir/$role.key")" ]]
    openssl x509 -in "$dir/$role.crt" -noout -ext subjectAltName | tr ', ' '\n' | grep -Fx -e "DNS:$address" -e "Address:$address" >/dev/null
done
CHECK_CERTS
    then
        generate_node_certs "$host" "$dc" "$name" "$idx"
    fi
    distribute_ssh_keys_to_node "$host" "$dc" "$name" "$idx"
    distribute_ssl_to_node "$host" "$dc" "$name" "$idx"
    build_patroni_image_on_node "$host" "$dc" "$name" "$idx"
    for_each_node sync_topology_node
    # The current primary must accept the new replication source before basebackup begins.
    for i in $(seq 1 "$(get_node_count)"); do
        if [[ "$i" != "$idx" && "$offline_peers" != *" $(get_node_name "$i") "* ]]; then
            reload_node_patroni "$(get_node_ip "$i")"
        fi
    done
}

cmd_replace() {
    local name="" host=""
    while (($#)); do
        case "$1" in
            --old) name="$2"; shift 2 ;;
            --new-ip) host="$2"; shift 2 ;;
            *) usage; return 1 ;;
        esac
    done
    [[ -n "$name" && -n "$host" ]] || { usage; return 1; }
    local info old dc idx i helper updated="" ip node
    info=$(find_node_by_name "$name") || { log_error "Неизвестный узел $name"; return 1; }
    IFS=':' read -r old dc name idx <<< "$info"
    validate_node_identity "$host" "$dc" "$name"
    ensure_quorum_nodes_initialized
    helper=$(select_quorum_helper "$old") || return 1
    for i in $(seq 1 "$(get_node_count)"); do
        ip=$(get_node_ip "$i"); node=$(get_node_name "$i")
        if [[ "$node" == "$name" ]]; then ip="$host"
        elif [[ "$ip" == "$host" ]]; then log_error "Адрес уже занят другим узлом"; return 1; fi
        updated+="${updated:+ }$ip:$(get_node_dc "$i"):$node"
    done
    confirm_action "Заменить узел $name ($old → $host)?" || return 0
    remote_exec "$host" true >/dev/null
    if is_quorum_node "$idx" "$name"; then
        reconcile_member "$helper" check-survivors "$name" "$old"
    fi
    if [[ "$old" != "$host" && "${DRY_RUN:-false}" != true ]]; then
        if remote_exec "$old" true >/dev/null 2>&1; then
            remote_exec "$old" "cd '${REMOTE_BASE_DIR}' && docker compose stop"
        fi
    fi
    if [[ "${DRY_RUN:-false}" != true ]]; then
        local cert old_fingerprint new_fingerprint
        cert="$(state_root)/certs/$name/etcd-server.crt"
        if [[ -s "$cert" ]]; then
            old_fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2)
            new_fingerprint=$(remote_exec "$host" "file='$REMOTE_BASE_DIR/certs/$name/etcd-server.crt'; if test -s \"\$file\"; then openssl x509 -in \"\$file\" -noout -fingerprint -sha256 | cut -d= -f2; fi")
        fi
        if [[ -s "$cert" ]] && { [[ "$old_fingerprint" != "$new_fingerprint" ]] ||
            ! openssl x509 -in "$cert" -noout -ext subjectAltName | tr ', ' '\n' | grep -Fxq -e "DNS:$host" -e "Address:$host"; }; then
            revoke_node_certs "$name"
        fi
    fi
    CLUSTER_NODES="$updated"
    prepare_node "$host" "$dc" "$name" "$idx"
    start_verified_node "$host" "$name" "$idx" "$helper" "$old"
    maintain_volumes "$helper" false "$host" "$dc" "$old"
    if [[ "${DRY_RUN:-false}" != true ]]; then config_db_set CLUSTER_NODES "$CLUSTER_NODES"; fi
    log_info "Узел $name заменён; состав и размещение томов проверены"
}


# --- Подкоманда: remove ---
cmd_remove() {
    local target_node=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node) target_node="$2"; shift 2 ;;
            *)      log_error "Неизвестный параметр remove: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${target_node}" ]]; then
        log_error "Требуется --node"
        exit 1
    fi

    local node_info
    node_info=$(find_node_by_name "${target_node}") || {
        log_error "Узел '${target_node}' не найден в CLUSTER_NODES"
        exit 1
    }
    IFS=':' read -r rm_ip rm_dc rm_name rm_idx <<< "${node_info}"

    validate_node_identity "$rm_ip" "$rm_dc" "$rm_name"
    ensure_quorum_nodes_initialized
    local count
    count=$(get_node_count)
    if (( count <= 3 )); then
        log_error "Нельзя удалить узел: останется < 3 узлов (нарушение кворума etcd и defaultReplication=100)"
        exit 1
    fi
    if is_quorum_node "${rm_idx}" "${rm_name}"; then
        local qcount=0
        for i in $(seq 1 "${count}"); do
            is_quorum_node "$i" "$(get_node_name "$i")" && qcount=$((qcount + 1))
        done
        if (( qcount <= 3 )); then
            log_error "Нельзя удалить quorum-узел '${rm_name}': в кластере всего ${qcount} quorum-узла(ов), минимум для кворума etcd/SeaweedFS — 3. Используйте 'scale replace' или добавьте сначала новую quorum-ноду."
            exit 1
        fi
    fi

    log_step "Безопасное удаление узла ${rm_name} (${rm_ip})"
    confirm_action "Вывести ${rm_name} (${rm_ip}) из кластера?" || exit 0

    local helper_ip
    helper_ip=$(select_quorum_helper "$rm_ip") || return 1
    if is_quorum_node "$rm_idx" "$rm_name"; then
        reconcile_member "$helper_ip" check-survivors "$rm_name" "$rm_ip"
    fi

    # 1. Дренаж трафика (DNS + switchover если Primary PG)
    log_info "1/5 — Дренаж трафика и проверка ролей..."
    if [[ "$(resolve_current_active_ip)" == "${rm_ip}" ]]; then
        log_info "  ${rm_name} — текущий Active Edge в DNS; переключаем на ${helper_ip}..."
        remote_exec "${helper_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose restart sftpgo"
        update_dns_provider "${helper_ip}"
    fi
    if patroni_is_primary "${rm_ip}"; then
        log_info "  ${rm_name} — PG Primary; выполняем switchover..."
        remote_exec "${rm_ip}" "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1); docker exec \"\${CID}\" patronictl -c /run/pg-certs/patroni.yml switchover '${CLUSTER_SLUG}' --force"
        run_or_dry sleep 8
    fi

    # 2. Вывод Volume и восстановление реплик томов на оставшихся ДЦ
    log_info "2/5 — Остановка swfs-volume на ${rm_name} и volume.fix.replication..."
    remote_exec "${rm_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose stop sftpgo swfs-s3 swfs-filer swfs-volume swfs-worker || true"
    maintain_volumes "$helper_ip" false "" "" "$rm_ip"

    # 3. Остановка Patroni, точечная очистка member-записи в DCS и удаление permanent slot
    log_info "3/5 — Вывод ${rm_name} из Patroni DCS и очистка permanent slot..."
    remote_exec "${rm_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose stop patroni haproxy || true"
    local cur_primary_ip
    cur_primary_ip=$(find_patroni_primary_ip) || { log_error "Нет доступного primary"; return 1; }
    remote_exec "$cur_primary_ip" "cd '${REMOTE_BASE_DIR}' && docker compose exec -T patroni patronictl -c /run/pg-certs/patroni.yml edit-config '${CLUSTER_SLUG}' --force --set 'slots.${rm_name}=null'"

    # 4. Вывод из etcd (если quorum) и отзыв сертификатов
    log_info "4/5 — Проверка etcd и отзыв сертификатов..."
    if is_quorum_node "${rm_idx}" "${rm_name}"; then
        reconcile_member "$helper_ip" remove "$rm_name" "$rm_ip"
        remote_exec "$rm_ip" "cd '${REMOTE_BASE_DIR}' && docker compose stop etcd swfs-master"
        local remaining_voters="" voter
        for voter in $QUORUM_NODES; do
            [[ "$voter" == "$rm_name"  ]] || remaining_voters+="${remaining_voters:+ }$voter"
        done
        QUORUM_NODES="$remaining_voters"
        reconcile_masters "$helper_ip" "$rm_ip"
    fi
    revoke_node_certs "${rm_name}"

    # 5. Обновляем CLUSTER_NODES (и SWFS_ADMIN_NODE_INDEX при сдвиге) и синхронизируем оставшиеся ноды
    log_info "5/5 — Очистка UFW и синхронизация конфигов на оставшихся узлах..."
    local admin_idx="${SWFS_ADMIN_NODE_INDEX:-2}"
    local admin_name=""
    admin_name=$(get_node_name "${admin_idx}" 2>/dev/null || echo "")
    local new_nodes="" new_admin_idx="1" new_idx=0
    for i in $(seq 1 "${count}"); do
        local nip ndc nname
        nip=$(get_node_ip "$i"); ndc=$(get_node_dc "$i"); nname=$(get_node_name "$i")
        [[ "${nname}" == "${rm_name}" ]] && continue
        new_idx=$((new_idx + 1))
        [[ "${nname}" == "${admin_name}" ]] && new_admin_idx="${new_idx}"
        [[ -n "${new_nodes}" ]] && new_nodes+=" "
        new_nodes+="${nip}:${ndc}:${nname}"
    done
    if [[ "${rm_name}" == "${admin_name}" ]]; then
        new_admin_idx=$(( new_idx >= 2 ? 2 : 1 ))
    fi
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        config_db_set_many CLUSTER_NODES "$new_nodes" SWFS_ADMIN_NODE_INDEX "$new_admin_idx" QUORUM_NODES "$QUORUM_NODES"
    else
        export CLUSTER_NODES="${new_nodes}"
        export SWFS_ADMIN_NODE_INDEX="${new_admin_idx}"
    fi
    local sync_flags=()
    [[ -n "${ENV_NAME:-}" ]] && sync_flags+=("--env" "${ENV_NAME}")
    [[ "${DRY_RUN:-false}" == "true" ]] && sync_flags+=("--dry-run")
    [[ "${AUTO_YES:-false}" == "true" ]] && sync_flags+=("--yes")
    bash "${SCRIPT_DIR}/clusterctl" "${sync_flags[@]}" sync-config
    if [[ "${rm_name}" == "${admin_name}" ]]; then
        local new_admin_ip
        new_admin_ip=$(get_node_ip "${new_admin_idx}")
        remote_exec "${new_admin_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d swfs-admin" || true
    fi

    log_info "✅ Узел ${rm_name} безопасно выведен из кластера"
}

# --- Подкоманда: expand-disk ---
cmd_expand_disk() {
    local target_node="" new_dir="" max_volumes="0"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node)        target_node="$2"; shift 2 ;;
            --dir)         new_dir="$2"; shift 2 ;;
            --max-volumes) max_volumes="$2"; shift 2 ;;
            *)             log_error "Неизвестный параметр expand-disk: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${target_node}" || -z "${new_dir}" ]]; then
        log_error "Требуются --node и --dir"
        exit 1
    fi

    local node_info
    node_info=$(find_node_by_name "${target_node}") || {
        log_error "Узел '${target_node}' не найден в CLUSTER_NODES"
        exit 1
    }
    IFS=':' read -r ip dc name idx <<< "${node_info}"

    log_step "Подключение дополнительного диска ${new_dir} к swfs-volume на ${name} (${ip})"
    remote_exec "${ip}" "mkdir -p '${new_dir}' && df -h '${new_dir}'"

    local updated_dirs="${SWFS_VOLUME_DIR},${new_dir}"
    export SWFS_VOLUME_DIR="${updated_dirs}"
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        config_db_set "SWFS_VOLUME_DIR" "${updated_dirs}"
    fi

    local cur_max_parts=()
    IFS=',' read -ra _dirs_arr <<< "${updated_dirs}"
    for _ in $(seq 1 $(( ${#_dirs_arr[@]} - 1 ))); do
        cur_max_parts+=("${SWFS_VOLUME_MAX_PER_DIR:-64}")
    done
    cur_max_parts+=("${max_volumes}")
    export SWFS_VOLUME_MAX_OVERRIDE
    SWFS_VOLUME_MAX_OVERRIDE=$(IFS=,; echo "${cur_max_parts[*]}")

    render_node_configs "${ip}" "${dc}" "${name}" "${idx}" "existing"
    unset SWFS_VOLUME_MAX_OVERRIDE
    push_node_configs "${ip}" "${dc}" "${name}" "${idx}"
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --no-deps swfs-volume"
    wait_for_remote_health "${ip}" "SWFS Volume ${name}" "curl -sf http://127.0.0.1:${SWFS_VOLUME_PORT:-8082}/healthz || curl -sf http://127.0.0.1:${SWFS_VOLUME_PORT:-8082}/status" 20 2

    log_info "✅ Диск ${new_dir} (-max=0,${max_volumes}) подключен к swfs-volume на ${name}"
}

main() {
    local subcmd="${1:-}"
    shift || true
    case "${subcmd}" in
        add)         cmd_add "$@" ;;
        replace)     cmd_replace "$@" ;;
        remove)      cmd_remove "$@" ;;
        expand-disk) cmd_expand_disk "$@" ;;
        ""|--help|-h) usage; exit 0 ;;
        *)           log_error "Неизвестная подкоманда scale: ${subcmd}"; usage; exit 1 ;;
    esac
    if [[ "$subcmd" != expand-disk && -n "${ARBITER_IP:-}" ]]; then
        source "${SCRIPT_DIR}/scripts/lib/arbiter-deploy.sh"
        deploy_arbiter
    fi
}

main "$@"
