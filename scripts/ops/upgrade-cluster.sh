#!/usr/bin/env bash
# ============================================================================
# upgrade-cluster.sh — Поэтапный Rolling Upgrade и Rollback (Day-2)
# ============================================================================
# Вызов:
#   ./clusterctl upgrade [--dry-run] [--yes] [--component all|etcd|patroni|swfs|sftpgo]
#   ./clusterctl rollback [--dry-run] [--yes]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"

ROLLBACK_FILE="$(state_root)/.rollback_state"
COMPONENT="all"
DO_ROLLBACK=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --component) COMPONENT="$2"; shift 2 ;;
            --rollback)  DO_ROLLBACK=true; shift ;;
            *)           log_error "Неизвестный флаг upgrade: $1"; exit 1 ;;
        esac
    done
}

guard_pg_major_version() {
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    local primary_ip running_major
    primary_ip=$(find_patroni_primary_ip || get_node_ip 1)
    running_major=$(remote_exec "${primary_ip}" \
        "docker exec \$(docker ps -qf name=patroni) psql -U postgres -tAc 'SHOW server_version_num;'" 2>/dev/null | cut -c1-2 || echo "16")
    local dockerfile_major
    dockerfile_major=$(awk '/^FROM postgres:/{split($2,a,":"); split(a[2],b,"-"); print b[1]}' "${SCRIPT_DIR}/Dockerfile.patroni")

    if [[ -n "${running_major}" && -n "${dockerfile_major}" && "${running_major}" != "${dockerfile_major}" ]]; then
        log_error "БЛОКИРОВКА: Попытка мажорного обновления PostgreSQL (${running_major} -> ${dockerfile_major})!"
        log_error "Выполняйте мажорный апгрейд строго по runbook в README.md (pg_upgrade / logical replication)."
        exit 1
    fi
}

pre_upgrade_gate() {
    log_step "0. Pre-Upgrade Gate & Snapshots"

    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        bash "${SCRIPT_DIR}/scripts/verify/cluster-health.sh" --strict || {
            log_error "Pre-Upgrade Gate не пройден! Исправьте предупреждения/ошибки до старта."
            exit 1
        }
    fi

    local primary_ip
    primary_ip=$(find_patroni_primary_ip || get_node_ip 1)

    log_info "Сохранение текущего состояния образов в ${ROLLBACK_FILE}..."
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        cp "${SCRIPT_DIR}/versions.env" "${ROLLBACK_FILE}.versions"
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "${ROLLBACK_FILE}"
        for i in $(seq 1 "$(get_node_count)"); do
            local ip name
            ip=$(get_node_ip "$i"); name=$(get_node_name "$i")
            remote_exec "${ip}" "docker ps --format '{{.Names}}={{.Image}}'" | sed "s/^/${name}:/" >> "${ROLLBACK_FILE}"
        done
    fi

    log_info "Снятие etcdctl snapshot save..."
    remote_exec "${primary_ip}" "
        docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
            snapshot save /etcd-data/pre-upgrade-\$(date +%Y%m%d-%H%M%S).db
    "

    if [[ "${BACKUP_S3_ACCESS_KEY:-FIXME}" != *FIXME* && "${BACKUP_S3_ACCESS_KEY:-}" != "" ]]; then
        log_info "Снятие инкрементального бэкапа pgBackRest..."
        remote_exec "${primary_ip}" "docker exec -u postgres \$(docker ps -qf name=patroni) pgbackrest --stanza='${CLUSTER_SLUG}' --type=incr backup"
    fi
}

rerender_and_push_node_by_ip() {
    local target_ip="$1" count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local ip dc name
        ip=$(get_node_ip "$i"); dc=$(get_node_dc "$i"); name=$(get_node_name "$i")
        if [[ "${ip}" == "${target_ip}" ]]; then
            render_node_configs "${ip}" "${dc}" "${name}" "$i" "existing"
            push_node_configs "${ip}" "${dc}" "${name}" "$i"
            return 0
        fi
    done
}

# --- 1. etcd rolling upgrade ---
upgrade_etcd() {
    log_step "Этап 1: Rolling Upgrade etcd"
    local count quorum_ips=() followers=() leader_ip=""
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local name ip
        name=$(get_node_name "$i"); ip=$(get_node_ip "$i")
        if is_quorum_node "$i" "${name}"; then
            quorum_ips+=("${ip}")
        fi
    done

    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        local q1="${quorum_ips[0]}"
        local leader_id
        leader_id=$(remote_exec "${q1}" "docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint status -w json | jq -r '.[0].Status.leader'")
        for qip in "${quorum_ips[@]}"; do
            local mid
            mid=$(remote_exec "${qip}" "docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint status -w json | jq -r '.[0].Status.header.member_id'")
            if [[ "${mid}" == "${leader_id}" ]]; then
                leader_ip="${qip}"
            else
                followers+=("${qip}")
            fi
        done
    else
        followers=("${quorum_ips[@]:1}")
        leader_ip="${quorum_ips[0]}"
    fi

    for fip in "${followers[@]}"; do
        log_info "Обновление etcd follower (${fip})..."
        rerender_and_push_node_by_ip "${fip}"
        remote_exec "${fip}" "cd '${REMOTE_BASE_DIR}' && docker compose pull etcd && docker compose up -d --no-deps etcd"
        wait_for_remote_health "${fip}" "etcd ${fip}" \
            "docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health" 25 3
    done

    if [[ -n "${leader_ip}" && ${#followers[@]} -gt 0 ]]; then
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            local target_mid
            target_mid=$(remote_exec "${followers[0]}" "docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint status -w json | jq -r '.[0].Status.header.member_id'")
            remote_exec "${leader_ip}" "docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key move-leader '${target_mid}'"
        fi
        log_info "Обновление бывшего etcd лидера (${leader_ip})..."
        rerender_and_push_node_by_ip "${leader_ip}"
        remote_exec "${leader_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose pull etcd && docker compose up -d --no-deps etcd"
        wait_for_remote_health "${leader_ip}" "etcd ${leader_ip}" \
            "docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health" 25 3
    fi
}

# --- 2. Patroni + PG rolling upgrade (с сохранением :rollback образа) ---
upgrade_patroni() {
    log_step "Этап 2: Rolling Upgrade Patroni + PostgreSQL (минорные версии)"
    guard_pg_major_version

    local count primary_ip="" replicas=()
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local ip name
        ip=$(get_node_ip "$i"); name=$(get_node_name "$i")
        build_patroni_image_on_node "${ip}" "$(get_node_dc "$i")" "${name}" "$i"
        if patroni_is_primary "${ip}"; then
            primary_ip="${ip}"
        else
            replicas+=("${ip}")
        fi
    done

    for rip in "${replicas[@]}"; do
        log_info "Обновление Patroni Replica (${rip})..."
        rerender_and_push_node_by_ip "${rip}"
        remote_exec "${rip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --no-deps patroni"
        wait_for_remote_health "${rip}" "Patroni Replica ${rip}" "curl -sf http://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 40 3
    done

    if [[ -n "${primary_ip}" && ${#replicas[@]} -gt 0 ]]; then
        log_info "Управляемый patronictl switchover с ${primary_ip}..."
        remote_exec "${primary_ip}" "docker exec \$(docker ps -qf name=patroni) patronictl switchover '${CLUSTER_SLUG}' --force"
        run_or_dry sleep 8
        log_info "Обновление бывшего Primary (${primary_ip})..."
        rerender_and_push_node_by_ip "${primary_ip}"
        remote_exec "${primary_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --no-deps patroni"
        wait_for_remote_health "${primary_ip}" "Patroni former Primary ${primary_ip}" "curl -sf http://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 40 3
    fi
}

# --- 3. SeaweedFS rolling upgrade ---
upgrade_swfs() {
    log_step "Этап 3: Rolling Upgrade SeaweedFS"
    local count
    count=$(get_node_count)

    log_info "3.1 — Обновление swfs-worker и swfs-admin..."
    local admin_idx="${SWFS_ADMIN_NODE_INDEX:-2}"
    for i in $(seq 1 "${count}"); do
        local ip
        ip=$(get_node_ip "$i")
        rerender_and_push_node_by_ip "${ip}"
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose pull swfs-worker && docker compose up -d --no-deps swfs-worker"
    done
    local admin_ip
    admin_ip=$(get_node_ip "${admin_idx}")
    remote_exec "${admin_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose pull swfs-admin && docker compose up -d --no-deps swfs-admin"

    log_info "3.2 — Обновление swfs-filer и swfs-s3 по одной ноде..."
    for i in $(seq 1 "${count}"); do
        local ip
        ip=$(get_node_ip "$i")
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose pull swfs-filer swfs-s3 && docker compose up -d --no-deps swfs-filer swfs-s3"
        wait_for_remote_health "${ip}" "SWFS Filer ${ip}" \
            "curl -sf http://127.0.0.1:${SWFS_FILER_PORT:-8888}/healthz || curl -sf http://127.0.0.1:${SWFS_FILER_METRICS_PORT:-9326}/metrics >/dev/null" 20 2
    done

    log_info "3.3 — Обновление swfs-volume по одному ДЦ за раз..."
    for i in $(seq 1 "${count}"); do
        local ip
        ip=$(get_node_ip "$i")
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose pull swfs-volume && docker compose up -d --no-deps swfs-volume"
        wait_for_remote_health "${ip}" "SWFS Volume ${ip}" \
            "curl -sf http://127.0.0.1:${SWFS_VOLUME_PORT:-8082}/healthz || curl -sf http://127.0.0.1:${SWFS_VOLUME_PORT:-8082}/status" 20 2
    done

    log_info "3.4 — Обновление swfs-master (фолловеры -> лидер последним)..."
    local leader_host="" qips=()
    for i in $(seq 1 "${count}"); do
        local ip name
        ip=$(get_node_ip "$i"); name=$(get_node_name "$i")
        if is_quorum_node "$i" "${name}"; then
            qips+=("${ip}")
        fi
    done
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        leader_host=$(remote_exec "${qips[0]}" "curl -sf http://127.0.0.1:${SWFS_MASTER_PORT:-9333}/cluster/status | jq -r '.Leader'" | cut -d: -f1)
    fi
    for ip in "${qips[@]}"; do
        [[ "${ip}" == "${leader_host}" ]] && continue
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose pull swfs-master && docker compose up -d --no-deps swfs-master"
        wait_for_remote_health "${ip}" "SWFS Master ${ip}" "curl -sf http://127.0.0.1:${SWFS_MASTER_PORT:-9333}/cluster/status" 20 2
    done
    if [[ -n "${leader_host}" ]]; then
        remote_exec "${leader_host}" "cd '${REMOTE_BASE_DIR}' && docker compose pull swfs-master && docker compose up -d --no-deps swfs-master"
        wait_for_remote_health "${leader_host}" "SWFS Master Leader" "curl -sf http://127.0.0.1:${SWFS_MASTER_PORT:-9333}/cluster/status | jq -e '.Leader != \"\"'" 25 2
    fi
}

# --- 4. SFTPGo Standby-first rolling upgrade (динамический резолв текущего Active Edge по DNS!) ---
upgrade_sftpgo() {
    log_step "Этап 4: Rolling Upgrade SFTPGo (Standby-first Edge Cutover)"
    local count active_ip standby_ip=""
    count=$(get_node_count)
    active_ip=$(resolve_current_active_ip)
    log_info "Текущий Active Edge по DNS (${DOMAIN}): ${active_ip}"

    for i in $(seq "${count}" -1 1); do
        local ip
        ip=$(get_node_ip "$i")
        [[ "${ip}" == "${active_ip}" ]] && continue
        [[ -z "${standby_ip}" ]] && standby_ip="${ip}"
        log_info "Обновление Standby SFTPGo (${ip})..."
        rerender_and_push_node_by_ip "${ip}"
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose pull sftpgo && docker compose up -d --no-deps sftpgo"
        wait_for_remote_health "${ip}" "SFTPGo ${ip}" "docker exec \$(docker ps -qf name=sftpgo) sftpgo ping --config-file /etc/sftpgo/sftpgo.json" 20 2
    done

    log_info "Запуск sftpgo initprovider (update_mode=1) на обновленном Standby (${standby_ip})..."
    remote_exec "${standby_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose run --rm --no-deps sftpgo initprovider --config-file /etc/sftpgo/sftpgo.json"
    log_info "Рестарт Standby SFTPGo для сброса 10-минутного кэша до DNS cutover..."
    remote_exec "${standby_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose restart sftpgo"

    if ! update_dns_provider "${standby_ip}"; then
        log_warn "Переведите DNS ${DOMAIN} -> ${standby_ip} вручную до обновления бывшего Active (${active_ip})"
        confirm_action "DNS переведен на ${standby_ip}? Продолжить обновление ${active_ip}?" || exit 0
    fi

    rerender_and_push_node_by_ip "${active_ip}"
    remote_exec "${active_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose pull sftpgo && docker compose up -d --no-deps sftpgo"
    wait_for_remote_health "${active_ip}" "SFTPGo former Active ${active_ip}" "docker exec \$(docker ps -qf name=sftpgo) sftpgo ping --config-file /etc/sftpgo/sftpgo.json" 20 2
}

run_rollback() {
    log_step "Откат контейнеров на состояние из ${ROLLBACK_FILE}.versions"
    if [[ ! -f "${ROLLBACK_FILE}.versions" ]]; then
        log_error "Отсутствует ${ROLLBACK_FILE}.versions"
        exit 1
    fi
    confirm_action "Восстановить версии из ${ROLLBACK_FILE}.versions и откатить сервисы?" || exit 0

    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        cp "${ROLLBACK_FILE}.versions" "${SCRIPT_DIR}/versions.env"
        load_cluster_env "${SCRIPT_DIR}"
    fi

    local count primary_ip="" replicas=()
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local ip name
        ip=$(get_node_ip "$i"); name=$(get_node_name "$i")
        # Восстанавливаем сохраненный тег local/patroni-pg16:rollback перед рестартом
        remote_exec "${ip}" "
            if docker image inspect 'local/patroni-pg16:rollback' >/dev/null 2>&1; then
                docker tag 'local/patroni-pg16:rollback' '${PATRONI_PG_IMAGE}' || true
            fi
        "
        rerender_and_push_node_by_ip "${ip}"
        if patroni_is_primary "${ip}"; then
            primary_ip="${ip}"
        else
            replicas+=("${ip}")
        fi
    done

    # Сначала реплики/фолловеры, затем switchover и бывший Primary
    for rip in "${replicas[@]}"; do
        log_info "Откат стека на реплике (${rip})..."
        remote_exec "${rip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d"
    done
    if [[ -n "${primary_ip}" ]]; then
        if (( ${#replicas[@]} > 0 )); then
            remote_exec "${primary_ip}" "docker exec \$(docker ps -qf name=patroni) patronictl switchover '${CLUSTER_SLUG}' --force" || true
            run_or_dry sleep 5
        fi
        log_info "Откат стека на бывшем Primary (${primary_ip})..."
        remote_exec "${primary_ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d"
    fi

    log_warn "Если схема PostgreSQL изменилась миграцией initprovider, при необходимости выполните restore через pgBackRest!"
    log_info "✅ Откат контейнеров завершен"
}

main() {
    parse_args "$@"
    if [[ "${DO_ROLLBACK}" == "true" ]]; then
        run_rollback
        exit 0
    fi

    confirm_action "Начать rolling-обновление (component=${COMPONENT})?" || exit 0
    pre_upgrade_gate

    init_op_checkpoints "upgrade"
    case "${COMPONENT}" in
        all)
            run_checkpoint "upgrade" "1-etcd"    upgrade_etcd
            run_checkpoint "upgrade" "2-patroni" upgrade_patroni
            run_checkpoint "upgrade" "3-swfs"    upgrade_swfs
            run_checkpoint "upgrade" "4-sftpgo"  upgrade_sftpgo
            ;;
        etcd)    run_checkpoint "upgrade" "1-etcd"    upgrade_etcd ;;
        patroni) run_checkpoint "upgrade" "2-patroni" upgrade_patroni ;;
        swfs)    run_checkpoint "upgrade" "3-swfs"    upgrade_swfs ;;
        sftpgo)  run_checkpoint "upgrade" "4-sftpgo"  upgrade_sftpgo ;;
        *)       log_error "Неизвестный компонент: ${COMPONENT}"; exit 1 ;;
    esac
    clear_op_checkpoints "upgrade"

    log_info "✅ Rolling upgrade (${COMPONENT}) успешно завершен"
}

main "$@"
