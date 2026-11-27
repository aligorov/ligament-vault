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

update_cluster_env_var() {
    local key="$1" val="$2"
    local env_file
    env_file="$(state_root)/cluster.env"
    cp "${env_file}" "${env_file}.bak.$(date +%Y%m%d%H%M%S)"
    python3 - "${env_file}" "${key}" "${val}" <<'PYEOF'
import re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, "r", encoding="utf-8").read()
newline = f'{key}="{val}"'
if re.search(rf'^{key}=.*$', text, flags=re.M):
    text = re.sub(rf'^{key}=.*$', newline, text, flags=re.M)
else:
    text += "\n" + newline + "\n"
open(path, "w", encoding="utf-8").write(text)
PYEOF
    export "${key}=${val}"
}

# Удаление ТОЛЬКО записи конкретного остановленного узла из DCS (НИКОГДА не вызывать patronictl remove <cluster>!)
purge_stopped_patroni_member_from_dcs() {
    local helper_ip="$1" dead_node_name="$2"
    remote_exec "${helper_ip}" "
        ETCD_CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1 || true)
        if [[ -n \"\${ETCD_CID}\" ]]; then
            docker exec \"\${ETCD_CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} \
                --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
                del '/${CLUSTER_SLUG}/${CLUSTER_SLUG}/members/${dead_node_name}' >/dev/null 2>&1 || true
        fi
    " || true
}

maybe_sync_arbiter_key_to_node() {
    local target_ip="$1"
    if [[ -n "${ARBITER_IP:-}" && "${DRY_RUN:-false}" != "true" ]]; then
        local arb_pub
        arb_pub=$(remote_exec "${ARBITER_IP}" "awk '{print \$1 \" \" \$2}' '${ARBITER_BASE_DIR}/.ssh/id_ed25519.pub'" 2>/dev/null || echo "")
        [[ -n "${arb_pub}" ]] && install_arbiter_helper_on_node "${target_ip}" "${arb_pub}"
    fi
}

# --- Подкоманда: add ---
cmd_add() {
    local new_ip="" new_dc="" new_name="" role="edge" rebalance=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip)        new_ip="$2"; shift 2 ;;
            --dc)        new_dc="$2"; shift 2 ;;
            --name)      new_name="$2"; shift 2 ;;
            --role)      role="$2"; shift 2 ;;
            --rebalance) rebalance=true; shift ;;
            *)           log_error "Неизвестный параметр add: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${new_ip}" || -z "${new_dc}" ]]; then
        log_error "Требуются --ip и --dc"
        exit 1
    fi
    if [[ "${role}" != "edge" && "${role}" != "quorum" ]]; then
        log_error "--role должен быть 'edge' или 'quorum'"
        exit 1
    fi

    local current_count next_idx
    current_count=$(get_node_count)
    next_idx=$((current_count + 1))
    new_name="${new_name:-node${next_idx}}"
    ensure_quorum_nodes_initialized

    log_step "Добавление узла ${new_name} (${new_ip}, DC=${new_dc}, role=${role})"

    # 1. Pre-flight SSH и RTT новой ноды
    log_info "1/8 — Проверка SSH и RTT до ${new_ip}..."
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        remote_exec "${new_ip}" "echo ok && docker compose version >/dev/null" || {
            log_error "На ${new_ip} нет SSH или Docker Compose"
            exit 1
        }
        local node1_ip rtt_avg
        node1_ip=$(get_node_ip 1)
        rtt_avg=$(remote_exec "${node1_ip}" "ping -c 30 -i 0.2 -q '${new_ip}'" | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}') || rtt_avg=9999
        log_info "  RTT node1 <-> ${new_name}: ${rtt_avg}ms"
        if (( rtt_avg > ${RTT_HARD_STOP:-250} )); then
            log_error "HARD STOP: RTT ${rtt_avg}ms > ${RTT_HARD_STOP:-250}ms"
            exit 1
        fi
    fi

    # 2. Обновление CLUSTER_NODES и ролей (до старта!)
    if [[ "${role}" == "quorum" ]]; then
        local qcount=0
        for i in $(seq 1 "${current_count}"); do
            is_quorum_node "$i" "$(get_node_name "$i")" && qcount=$((qcount + 1))
        done
        if (( qcount + 1 > ${MAX_ETCD_VOTERS:-5} )); then
            log_error "Превышен MAX_ETCD_VOTERS=${MAX_ETCD_VOTERS:-5}"
            exit 1
        fi
        if (( (qcount + 1) % 2 == 0 )); then
            log_warn "Добавление 1 quorum-ноды сделает число etcd voters четным (${qcount}-> $((qcount+1)))!"
            confirm_action "Продолжить добавление quorum-ноды при четном числе voters?" || exit 1
        fi
        [[ "${DRY_RUN:-false}" != "true" ]] && echo "${new_name}" >> "$(state_root)/.quorum_nodes"
    fi

    local new_cluster_nodes="${CLUSTER_NODES} ${new_ip}:${new_dc}:${new_name}"
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        update_cluster_env_var "CLUSTER_NODES" "${new_cluster_nodes}"
    else
        export CLUSTER_NODES="${new_cluster_nodes}"
    fi

    # 3. Бесшовное расширение UFW на существующих нодах ДО запуска нового узла
    log_info "2/8 — Расширение UFW на всем кластере и укрепление ${new_name}..."
    ufw_existing_cb() {
        local ip="$1" dc="$2" name="$3" idx="$4"
        [[ "${name}" == "${new_name}" ]] && return 0
        harden_node_ufw "${ip}" "${dc}" "${name}" "${idx}"
    }
    for_each_node ufw_existing_cb
    harden_node_full "${new_ip}" "${new_dc}" "${new_name}" "${next_idx}"
    maybe_sync_arbiter_key_to_node "${new_ip}"

    # 4. Remote-CSR сертификаты, SSH host-keys и SSL на новой ноде
    log_info "3/8 — Выпуск Remote-CSR сертификатов, SSH host-keys и SSL на ${new_name}..."
    ensure_ca_exists
    generate_node_certs "${new_ip}" "${new_dc}" "${new_name}" "${next_idx}"
    distribute_ssh_keys_to_node "${new_ip}" "${new_dc}" "${new_name}" "${next_idx}"
    distribute_ssl_to_node "${new_ip}" "${new_dc}" "${new_name}" "${next_idx}"

    # 5. Сборка образа Patroni на новой ноде и рендер конфигов
    log_info "4/8 — Сборка образа Patroni и раскладка конфигов..."
    build_patroni_image_on_node "${new_ip}" "${new_dc}" "${new_name}" "${next_idx}"
    sync_cb() {
        render_node_configs "$1" "$2" "$3" "$4" "existing"
        push_node_configs "$1" "$2" "$3" "$4"
    }
    for_each_node sync_cb

    # 6. Permanent slot в Patroni ДО старта новой реплики
    log_info "5/8 — Регистрация permanent slot '${new_name}' в Patroni..."
    local primary_ip
    primary_ip=$(find_patroni_primary_ip || get_node_ip 1)
    remote_exec "${primary_ip}" "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1); docker exec \"\${CID}\" patronictl edit-config '${CLUSTER_SLUG}' --force --set 'slots.${new_name}.type=physical'"

    # 7. Запуск сервисов
    if [[ "${role}" == "quorum" ]]; then
        log_info "6/8 — Ввод etcd-${new_name} через --learner → catch-up → promote..."
        local member_id=""
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            member_id=$(remote_exec "${primary_ip}" "
                ETCD_CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1)
                docker exec \"\${ETCD_CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} \
                    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
                    member add 'etcd-${new_name}' --peer-urls='https://${new_ip}:${ETCD_PEER_PORT:-2380}' --learner -w json | jq -r '.member.ID'
            " || echo "")
        fi
        remote_exec "${new_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d etcd"
        wait_for_remote_health "${new_ip}" "etcd learner ${new_name}" \
            "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1) && docker exec \"\${CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health" 25 3
        if [[ -n "${member_id}" && "${DRY_RUN:-false}" != "true" ]]; then
            for _ in $(seq 1 10); do
                if remote_exec "${primary_ip}" "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1); docker exec \"\${CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key member promote '${member_id}'"; then
                    break
                fi
                sleep 3
            done
        fi
    else
        log_info "6/8 — Режим edge: etcd и SWFS Master на ${new_name} не поднимаются"
    fi

    log_info "7/8 — Запуск стека на ${new_name} + обновление HAProxy/SFTPGo на кластере..."
    remote_exec "${new_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d"
    wait_for_remote_health "${new_ip}" "Patroni Replica ${new_name}" "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 45 3
    for i in $(seq 1 "${current_count}"); do
        local oip
        oip=$(get_node_ip "$i")
        remote_exec "${oip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --no-deps haproxy && SFTP_CID=\$(docker compose ps -q sftpgo | head -n1) && [[ -n \"\${SFTP_CID}\" ]] && docker kill -s HUP \"\${SFTP_CID}\""
    done

    # 8. SeaweedFS cluster.status и балансировка томов (со всеми мастерами!)
    log_info "8/8 — Проверка SeaweedFS и балансировка томов..."
    local mpeers
    mpeers=$(build_swfs_master_peers)
    if [[ "${rebalance}" == "true" || "${VOLUME_BALANCE_AFTER_ADD:-true}" == "true" ]]; then
        remote_exec_stdin "${primary_ip}" "${REMOTE_BASE_DIR}" "${mpeers}" <<'REMOTE_REBAL'
FILER_CID=$(cd "$1" && docker compose ps -q swfs-filer | head -n1)
docker exec -i "${FILER_CID}" weed shell -master="$2" <<'WEED'
cluster.status
volume.balance -apply
volume.fix.replication -apply
WEED
REMOTE_REBAL
    fi

    log_info "✅ Узел ${new_name} (${new_ip}) успешно добавлен в кластер"
}

# --- Подкоманда: replace ---
cmd_replace() {
    local old_node="" new_ip=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --old)    old_node="$2"; shift 2 ;;
            --new-ip) new_ip="$2"; shift 2 ;;
            *)        log_error "Неизвестный параметр replace: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${old_node}" || -z "${new_ip}" ]]; then
        log_error "Требуются --old и --new-ip"
        exit 1
    fi

    local node_info
    node_info=$(find_node_by_name "${old_node}") || {
        log_error "Узел '${old_node}' не найден в CLUSTER_NODES"
        exit 1
    }
    IFS=':' read -r old_ip old_dc old_name old_idx <<< "${node_info}"
    ensure_quorum_nodes_initialized

    log_step "Замена узла ${old_name} (${old_ip}) -> ${new_ip} (DC=${old_dc})"
    confirm_action "Отозвать сертификаты ${old_name}, перенести IP ${old_ip} -> ${new_ip} и перезалить ноду?" || exit 0

    local helper_idx=$(( old_idx == 1 ? 2 : 1 ))
    local helper_ip
    helper_ip=$(get_node_ip "${helper_idx}")

    # 1. Отзыв старых сертификатов в CRL
    log_info "1/6 — Отзыв старых сертификатов ${old_name} (CRL)..."
    revoke_node_certs "${old_name}"
    [[ "${DRY_RUN:-false}" != "true" ]] && rm -rf "$(state_root)/certs/${old_name}"

    # 2. Обновление IP в CLUSTER_NODES и атомарная синхронизация UFW на живых нодах
    log_info "2/6 — Обновление CLUSTER_NODES и UFW на живых узлах..."
    local updated_nodes="" count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local ip dc name
        ip=$(get_node_ip "$i"); dc=$(get_node_dc "$i"); name=$(get_node_name "$i")
        [[ "${name}" == "${old_name}" ]] && ip="${new_ip}"
        [[ -n "${updated_nodes}" ]] && updated_nodes+=" "
        updated_nodes+="${ip}:${dc}:${name}"
    done
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        update_cluster_env_var "CLUSTER_NODES" "${updated_nodes}"
    else
        export CLUSTER_NODES="${updated_nodes}"
    fi

    for i in $(seq 1 "${count}"); do
        local lip ldc lname
        lip=$(get_node_ip "$i"); ldc=$(get_node_dc "$i"); lname=$(get_node_name "$i")
        [[ "${lname}" == "${old_name}" ]] && continue
        harden_node_ufw "${lip}" "${ldc}" "${lname}" "$i"
    done

    # 3. Точечная очистка member-ключа сгоревшего узла в DCS и замена участника etcd
    log_info "3/6 — Очистка member-записи ${old_name} в DCS и подготовка etcd learner..."
    purge_stopped_patroni_member_from_dcs "${helper_ip}" "${old_name}"

    if is_quorum_node "${old_idx}" "${old_name}"; then
        remote_exec_stdin "${helper_ip}" "${old_name}" "${new_ip}" "${ETCD_CLIENT_PORT:-2379}" "${ETCD_PEER_PORT:-2380}" "${REMOTE_BASE_DIR}" <<'REMOTE_ETCD_REP'
set -euo pipefail
NAME="$1"; NEW_IP="$2"; EC="$3"; EP="$4"; BDIR="$5"
ETCD_CID=$(cd "${BDIR}" && docker compose ps -q etcd | head -n1)
OLD_ID=$(docker exec "${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC}" \
    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
    member list -w json | jq -r ".members[] | select(.name==\"etcd-${NAME}\") | .ID")
if [[ -n "${OLD_ID}" ]]; then
    docker exec "${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC}" \
        --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
        member remove "${OLD_ID}"
fi
docker exec "${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC}" \
    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
    member add "etcd-${NAME}" --peer-urls="https://${NEW_IP}:${EP}" --learner
REMOTE_ETCD_REP
    fi

    # 4. Подготовка новой VPS
    log_info "4/6 — Подготовка новой VPS ${new_ip} (Hardening, PKI, Docker Patroni)..."
    harden_node_full "${new_ip}" "${old_dc}" "${old_name}" "${old_idx}"
    maybe_sync_arbiter_key_to_node "${new_ip}"
    ensure_ca_exists
    generate_node_certs "${new_ip}" "${old_dc}" "${old_name}" "${old_idx}"
    distribute_ssh_keys_to_node "${new_ip}" "${old_dc}" "${old_name}" "${old_idx}"
    distribute_ssl_to_node "${new_ip}" "${old_dc}" "${old_name}" "${old_idx}"
    build_patroni_image_on_node "${new_ip}" "${old_dc}" "${old_name}" "${old_idx}"

    # 5. Рендер конфигов (etcd_state=existing) и старт
    log_info "5/6 — Запуск сервисов на замененной ноде и promote etcd learner..."
    for i in $(seq 1 "${count}"); do
        local cip cdc cname
        cip=$(get_node_ip "$i"); cdc=$(get_node_dc "$i"); cname=$(get_node_name "$i")
        render_node_configs "${cip}" "${cdc}" "${cname}" "$i" "existing"
        push_node_configs "${cip}" "${cdc}" "${cname}" "$i"
    done

    if is_quorum_node "${old_idx}" "${old_name}"; then
        remote_exec "${new_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d etcd"
        wait_for_remote_health "${new_ip}" "etcd learner ${old_name}" \
            "ETCD_CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1); [ -n \"\${ETCD_CID}\" ] && docker exec \"\${ETCD_CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health" 25 3
        remote_exec_stdin "${helper_ip}" "${old_name}" "${ETCD_CLIENT_PORT:-2379}" "${REMOTE_BASE_DIR}" <<'REMOTE_PROMOTE'
NAME="$1"; EC="$2"; BDIR="$3"
ETCD_CID=$(cd "${BDIR}" && docker compose ps -q etcd | head -n1)
LID=$(docker exec "${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC}" \
    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
    member list -w json | jq -r ".members[] | select(.name==\"etcd-${NAME}\") | .ID")
if [[ -n "${LID}" ]]; then
    for _ in $(seq 1 10); do
        docker exec "${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC}" \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key member promote "${LID}" && break
        sleep 3
    done
fi
REMOTE_PROMOTE
    fi

    remote_exec "${new_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d"
    wait_for_remote_health "${new_ip}" "Patroni Replica ${old_name}" "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 45 3

    # 6. Ремонт томов SeaweedFS и reload HAProxy/SFTPGo на живых нодах
    log_info "6/6 — Восстановление потерянных копий томов (volume.fix.replication -apply) и reload..."
    local mpeers
    mpeers=$(build_swfs_master_peers)
    remote_exec "${helper_ip}" "FILER_CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q swfs-filer | head -n1); docker exec -i \"\${FILER_CID}\" weed shell -master='${mpeers}' <<< 'volume.fix.replication -apply'"
    for i in $(seq 1 "${count}"); do
        local cip cname
        cip=$(get_node_ip "$i"); cname=$(get_node_name "$i")
        [[ "${cname}" == "${old_name}" ]] && continue
        remote_exec "${cip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --no-deps haproxy && SCID=\$(docker compose ps -q sftpgo | head -n1) && [[ -n \"\${SCID}\" ]] && docker kill -s HUP \"\${SCID}\""
    done

    log_info "✅ Замена ${old_name} -> ${new_ip} полностью выполнена"
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
    IFS=':' read -r rm_ip _ rm_name rm_idx <<< "${node_info}"

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
    helper_ip=$(get_node_ip $(( rm_idx == 1 ? 2 : 1 )))

    # 1. Дренаж трафика (DNS + switchover если Primary PG)
    log_info "1/5 — Дренаж трафика и проверка ролей..."
    if [[ "$(resolve_current_active_ip)" == "${rm_ip}" ]]; then
        log_info "  ${rm_name} — текущий Active Edge в DNS; переключаем на ${helper_ip}..."
        remote_exec "${helper_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose restart sftpgo"
        update_dns_provider "${helper_ip}" || true
    fi
    if patroni_is_primary "${rm_ip}"; then
        log_info "  ${rm_name} — PG Primary; выполняем switchover..."
        remote_exec "${rm_ip}" "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1); docker exec \"\${CID}\" patronictl switchover '${CLUSTER_SLUG}' --force"
        run_or_dry sleep 8
    fi

    # 2. Вывод Volume и восстановление реплик томов на оставшихся ДЦ
    log_info "2/5 — Остановка swfs-volume на ${rm_name} и volume.fix.replication..."
    remote_exec "${rm_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose stop sftpgo swfs-s3 swfs-filer swfs-volume swfs-worker || true"
    local mpeers
    mpeers=$(build_swfs_master_peers)
    remote_exec "${helper_ip}" "FILER_CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q swfs-filer | head -n1); docker exec -i \"\${FILER_CID}\" weed shell -master='${mpeers}' <<< 'volume.fix.replication -apply'"

    # 3. Остановка Patroni, точечная очистка member-записи в DCS и удаление permanent slot
    log_info "3/5 — Вывод ${rm_name} из Patroni DCS и очистка permanent slot..."
    remote_exec "${rm_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose stop patroni haproxy || true"
    purge_stopped_patroni_member_from_dcs "${helper_ip}" "${rm_name}"
    local cur_primary_ip
    cur_primary_ip=$(find_patroni_primary_ip || echo "${helper_ip}")
    remote_exec_env_stdin "${cur_primary_ip}" "PATRONI_API_PASSWORD" "${PATRONI_API_PORT:-8008}" "${rm_name}" "${REMOTE_BASE_DIR}" <<'REMOTE_DEL_SLOT' || true
set -euo pipefail
python3 - "$1" "$2" "$3" <<'PYEOF'
import base64, json, os, ssl, sys, urllib.request
port, rname, bdir = sys.argv[1:]
pw = os.environ["PATRONI_API_PASSWORD"]
ctx = ssl.create_default_context(cafile=f"{bdir}/certs/ca.crt")
ctx.load_cert_chain(certfile=f"{bdir}/certs/{rname}/pg-client.crt", keyfile=f"{bdir}/certs/{rname}/pg-client.key") if os.path.exists(f"{bdir}/certs/{rname}/pg-client.crt") else None
b64 = base64.b64encode(f"patroni:{pw}".encode()).decode()
req = urllib.request.Request(
    f"https://127.0.0.1:{port}/config",
    data=json.dumps({"slots": {rname: None}}).encode(),
    headers={"Authorization": f"Basic {b64}", "Content-Type": "application/json"},
    method="PATCH",
)
urllib.request.urlopen(req, context=ctx, timeout=10).read()
PYEOF
REMOTE_DEL_SLOT
    remote_exec "${cur_primary_ip}" "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1); docker exec -u postgres \"\${CID}\" psql -U postgres -c \"SELECT pg_drop_replication_slot('${rm_name}') FROM pg_replication_slots WHERE slot_name = '${rm_name}';\" >/dev/null" || true

    # 4. Вывод из etcd (если quorum) и отзыв сертификатов
    log_info "4/5 — Проверка etcd и отзыв сертификатов..."
    if is_quorum_node "${rm_idx}" "${rm_name}"; then
        remote_exec_stdin "${helper_ip}" "${REMOTE_BASE_DIR}" "${rm_name}" "${ETCD_CLIENT_PORT:-2379}" <<'REMOTE_ETCD_RM'
BDIR="$1"; NAME="$2"; EC="$3"
ETCD_CID=$(cd "${BDIR}" && docker compose ps -q etcd | head -n1)
ID=$(docker exec "${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC}" \
    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
    member list -w json | jq -r ".members[] | select(.name==\"etcd-${NAME}\") | .ID")
[[ -n "${ID}" ]] && docker exec "${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC}" \
    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key member remove "${ID}"
REMOTE_ETCD_RM
        remote_exec "${rm_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose stop etcd swfs-master || true"
        if [[ -f "$(state_root)/.quorum_nodes" && "${DRY_RUN:-false}" != "true" ]]; then
            sed -i.bak "/^${rm_name}$/d" "$(state_root)/.quorum_nodes" && rm -f "$(state_root)/.quorum_nodes.bak" || true
        fi
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
        update_cluster_env_var "CLUSTER_NODES" "${new_nodes}"
        update_cluster_env_var "SWFS_ADMIN_NODE_INDEX" "${new_admin_idx}"
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
        update_cluster_env_var "SWFS_VOLUME_DIR" "${updated_dirs}"
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
}

main "$@"
