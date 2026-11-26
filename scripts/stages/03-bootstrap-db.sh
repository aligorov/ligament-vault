#!/usr/bin/env bash
# ============================================================================
# 03-bootstrap-db.sh — etcd + Patroni/PG16 + HAProxy + pgBackRest stanza
# ============================================================================
# Вызов: ./ligactl install --stage 3
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
log_step "Стадия 3: Bootstrap DB (etcd + Patroni + HAProxy + pgBackRest)"

PG_PORT_MIGRATED=false
if [[ ! -f "$(state_root)/.cluster_installed" && "${PG_PORT:-15432}" == "5432" ]]; then
    log_warn "🔒 Автоперевод PostgreSQL со стандартного порта 5432 на закрытый mTLS-порт 15432..."
    persist_cluster_env_var "PG_PORT" "15432"
    export PG_PORT=15432
    PG_PORT_MIGRATED=true
fi
export PG_PORT="${PG_PORT:-15432}"

ensure_quorum_nodes_initialized
discover_extra_peer_ips

# Убираем старые/сломанные юниты моста (если остались после прошлых сбоев)
cleanup_broken_bridges_cb() {
    local ip="$1"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    remote_exec "${ip}" 'for uf in /etc/systemd/system/*-bridge-*.service; do [[ -f "${uf}" ]] || continue; if grep -q "id_ed25519-" "${uf}"; then bn=$(basename "${uf}"); systemctl stop "${bn}" 2>/dev/null || true; systemctl disable "${bn}" 2>/dev/null || true; rm -f "${uf}"; systemctl daemon-reload; fi; done' >/dev/null 2>&1 || true
}
for_each_node cleanup_broken_bridges_cb

for_each_node tune_node_wan_and_swap
for_each_node harden_node_ufw

# Если Stage 2 была пропущена (--resume) после смены IP узла, гарантируем актуальный PKI SAN до старта etcd
ensure_node_pki_fresh_cb() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    if ! remote_exec "${ip}" "test -f '${REMOTE_BASE_DIR}/certs/${name}/etcd-server.crt' && test -f '${REMOTE_BASE_DIR}/certs/${name}/pg-server.crt' && test -f '${REMOTE_BASE_DIR}/certs/${name}/swfs-client.crt' && openssl x509 -in '${REMOTE_BASE_DIR}/certs/${name}/etcd-server.crt' -noout -ext subjectAltName 2>/dev/null | grep -Fq 'IP Address:${ip}'" >/dev/null 2>&1; then
        log_warn "  🔐 Сертификаты на ${name} (${ip}) отсутствуют или содержат старый IP — обновляем PKI (Remote-CSR)..."
        ensure_ca_exists
        generate_node_certs "${ip}" "${dc}" "${name}" "${idx}"
        distribute_ssh_keys_to_node "${ip}" "${dc}" "${name}" "${idx}"
    fi
}
for_each_node ensure_node_pki_fresh_cb

for_each_node build_patroni_image_on_node

render_and_push_cb() {
    render_node_configs "$1" "$2" "$3" "$4" "new"
    push_node_configs "$1" "$2" "$3" "$4"
}
for_each_node render_and_push_cb

log_step "Запуск etcd (кворум)"
start_etcd_cb() {
    local ip="$1" name="$3" idx="$4"
    if ! is_quorum_node "${idx}" "${name}"; then
        log_info "  Пропуск etcd на ${name} (edge-нода)"
        return 0
    fi
    log_info "  Старт etcd на ${name} (${ip})..."
    remote_compose_up "${ip}" "" etcd
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        # etcd слушает peer-порт именно на NODE_IP, а client-порт еще на 127.0.0.1
        remote_exec "${ip}" "for _i in 1 2 3 4 5 6 7 8; do nc -z '${ip}' ${ETCD_PEER_PORT:-2380} 2>/dev/null && exit 0; sleep 1; done; exit 0" >/dev/null 2>&1 || true
    fi
}
for_each_node start_etcd_cb

ensure_etcd_mesh_cb() {
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    local src_ip="$1" src_name="$3" idx="$4"
    is_quorum_node "${idx}" "${src_name}" || return 0
    local count j dst_ip dst_name
    count=$(get_node_count)
    for j in $(seq 1 "${count}"); do
        dst_ip=$(get_node_ip "${j}")
        dst_name=$(get_node_name "${j}")
        [[ "${dst_ip}" == "${src_ip}" ]] && continue
        is_quorum_node "${j}" "${dst_name}" || continue
        local need_bridge=false
        if ! remote_tcp_probe "${src_ip}" "${dst_ip}" "${ETCD_PEER_PORT:-2380}" 5; then
            if remote_exec "${dst_ip}" "nc -z '${dst_ip}' ${ETCD_PEER_PORT:-2380}" >/dev/null 2>&1; then
                need_bridge=true
            fi
        fi
        if [[ "${need_bridge}" != "true" ]] && ! remote_tcp_probe "${src_ip}" "${dst_ip}" "${ETCD_CLIENT_PORT:-2379}" 5; then
            if remote_exec "${dst_ip}" "nc -z '${dst_ip}' ${ETCD_CLIENT_PORT:-2379}" >/dev/null 2>&1; then
                need_bridge=true
            fi
        fi
        if [[ "${need_bridge}" == "true" ]]; then
            log_warn "  ⚠️  Порты etcd (${ETCD_CLIENT_PORT:-2379}/${ETCD_PEER_PORT:-2380}) на ${dst_name} недоступны с ${src_name} — поднимаем прозрачный SSH-мост..."
            ensure_ssh_peer_bridge "${src_ip}" "${src_name}" "${dst_ip}" "${dst_name}"
        fi
    done
}
for_each_node ensure_etcd_mesh_cb

NODE1_IP=$(get_node_ip 1)
NODE1_NAME=$(get_node_name 1)
ETCD_ALL_ENDPOINTS=$(build_etcd_hosts | tr ',' '\n' | awk -v p="${ETCD_CLIENT_PORT:-2379}" '{sub(/:[0-9]+$/,""); print "https://" $1 ":" p}' | paste -sd, -)

ETCD_QUORUM_CHECK_CMD="CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1) && [[ -n \"\${CID}\" ]] && docker exec \"\${CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health && curl -sf --cacert '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/ca.crt' --cert '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/etcd-client.crt' --key '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/etcd-client.key' https://127.0.0.1:${ETCD_CLIENT_PORT:-2379}/version | grep -qE '\"etcdcluster\":\"3\\.[456]'"

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    wait_for_remote_health "${NODE1_IP}" "etcd quorum" "${ETCD_QUORUM_CHECK_CMD}" 30 3 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 50 etcd || true"
else
    ETCD_LOCAL_OK=true
    wait_for_remote_health "${NODE1_IP}" "etcd quorum" "${ETCD_QUORUM_CHECK_CMD}" 25 3 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 50 etcd || true" || ETCD_LOCAL_OK=false

    QUORUM_IPS_CSV=$(build_etcd_hosts | tr ',' '\n' | awk -F: '{print $1}' | paste -sd, -)
    ETCD_CLUSTER_CONSISTENT=true
    if [[ "${ETCD_LOCAL_OK}" == "true" ]]; then
        ETCD_CHK_OUT=$(remote_exec_stdin "${NODE1_IP}" "${REMOTE_BASE_DIR}" "${ETCD_ALL_ENDPOINTS}" "${QUORUM_IPS_CSV}" <<'REMOTE_ETCD_CHK' || true
set -euo pipefail
BASE_DIR="$1"; ENDPOINTS="$2"; EXPECTED_CSV="$3"
CID=$(cd "${BASE_DIR}" && docker compose ps -q etcd | head -n1 || true)
[[ -n "${CID}" ]] || { echo "MISMATCH:NO_CID"; exit 0; }
MEMBERS_JSON=$(docker exec "${CID}" etcdctl --endpoints="${ENDPOINTS}" --dial-timeout=5s --command-timeout=8s \
    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key member list -w json 2>/dev/null || echo "{}")
HEALTH_JSON=$(docker exec "${CID}" etcdctl --endpoints="${ENDPOINTS}" --dial-timeout=5s --command-timeout=8s \
    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health -w json 2>/dev/null || echo "[]")
python3 - "${MEMBERS_JSON}" "${HEALTH_JSON}" "${EXPECTED_CSV}" <<'PYETCD'
import json, re, sys
try:
    members = json.loads(sys.argv[1] or "{}").get("members", [])
except Exception:
    members = []
try:
    healths = json.loads(sys.argv[2] or "[]")
except Exception:
    healths = []
expected = sorted(x for x in sys.argv[3].split(",") if x)
peer_ips = sorted({
    re.sub(r"^https?://", "", u).split(":")[0]
    for m in members for u in m.get("peerURLs", [])
})
healthy_ips = sorted({
    re.sub(r"^https?://", "", h.get("endpoint", "")).split(":")[0]
    for h in healths if h.get("health") is True
})
if peer_ips != expected:
    print(f"MISMATCH:PEERS={peer_ips}!=EXPECTED={expected}")
elif healthy_ips != expected:
    print(f"MISMATCH:HEALTHY={healthy_ips}!=EXPECTED={expected}")
else:
    print("ETCD_TOPOLOGY_OK")
PYETCD
REMOTE_ETCD_CHK
        )
        [[ "${ETCD_CHK_OUT}" == *"ETCD_TOPOLOGY_OK"* ]] || ETCD_CLUSTER_CONSISTENT=false
    else
        ETCD_CLUSTER_CONSISTENT=false
    fi

    if [[ "${ETCD_CLUSTER_CONSISTENT}" != "true" && ! -f "$(state_root)/.cluster_installed" ]]; then
        log_warn "🔄 Обнаружено незавершенное состояние etcd (${ETCD_CHK_OUT:-quorum unreachable}) — пересоздаем чистый кворум etcd..."
        for_each_node ensure_etcd_mesh_cb
        reset_uninstalled_etcd_cb() {
            local ip="$1"
            remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose stop patroni etcd 2>/dev/null || true; find '${ETCD_DATA_DIR:-/data/etcd}' '${PG_DATA_DIR:-/data/postgresql}/data' -mindepth 1 -delete 2>/dev/null || true; mkdir -p '${ETCD_DATA_DIR:-/data/etcd}' '${PG_DATA_DIR:-/data/postgresql}/data'"
        }
        for_each_node reset_uninstalled_etcd_cb
        for_each_node start_etcd_cb
        for_each_node ensure_etcd_mesh_cb
        wait_for_remote_health "${NODE1_IP}" "etcd quorum (fresh)" "${ETCD_QUORUM_CHECK_CMD}" 30 3 \
            "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 50 etcd || true"
    fi

    log_info "Проверка всех участников etcd (${ETCD_ALL_ENDPOINTS}):"
    remote_exec "${NODE1_IP}" "
        CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1)
        curl -skf --cacert '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/ca.crt' --cert '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/etcd-client.crt' --key '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/etcd-client.key' https://127.0.0.1:${ETCD_CLIENT_PORT:-2379}/version || true
        echo ''
        docker exec \"\${CID}\" etcdctl --endpoints='${ETCD_ALL_ENDPOINTS}' --dial-timeout=5s --command-timeout=8s \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health -w table
        docker exec \"\${CID}\" etcdctl --endpoints='${ETCD_ALL_ENDPOINTS}' --dial-timeout=5s --command-timeout=8s \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint status -w table || true
    "
fi

log_step "Запуск Patroni Primary -> Replicas"
ACTIVE_PRIMARY_IP="${NODE1_IP}"
ACTIVE_PRIMARY_NAME="${NODE1_NAME}"

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    remote_compose_up "${NODE1_IP}" "--force-recreate" patroni
    for_each_node_dry_rep() {
        local ip="$1" idx="$4"
        (( idx == 1 )) && return 0
        remote_compose_up "${ip}" "--force-recreate" patroni
    }
    for_each_node for_each_node_dry_rep
else
    # 1. Проверяем, есть ли уже действующий лидер Patroni, напрямую видимый со всех узлов на текущем PG_PORT
    REUSE_EXISTING_PRIMARY=""
    CANDIDATE_PRIMARY=""
    if [[ "${PG_PORT_MIGRATED}" != "true" ]]; then
        CANDIDATE_PRIMARY=$(find_patroni_primary_ip || true)
    fi
    if [[ -n "${CANDIDATE_PRIMARY}" ]]; then
        PEER_REACH_OK=true
        check_pg_reach_cb() {
            local ip="$1" name="$3"
            [[ "${ip}" == "${CANDIDATE_PRIMARY}" ]] && return 0
            if ! remote_tcp_probe "${ip}" "${CANDIDATE_PRIMARY}" "${PG_PORT:-15432}" 6; then
                log_warn "  ⚠️  Узел ${name} (${ip}) не видит порт PostgreSQL ${CANDIDATE_PRIMARY}:${PG_PORT:-15432}"
                PEER_REACH_OK=false
            fi
        }
        for_each_node check_pg_reach_cb
        if [[ "${PEER_REACH_OK}" == "true" ]]; then
            REUSE_EXISTING_PRIMARY="${CANDIDATE_PRIMARY}"
        fi
    fi

    if [[ -n "${REUSE_EXISTING_PRIMARY}" ]]; then
        ACTIVE_PRIMARY_IP="${REUSE_EXISTING_PRIMARY}"
        ACTIVE_PRIMARY_NAME=$(get_node_name_by_ip "${ACTIVE_PRIMARY_IP}")
        log_info "Обнаружен действующий лидер Patroni на ${ACTIVE_PRIMARY_NAME} (${ACTIVE_PRIMARY_IP}:${PG_PORT}) — обновляем его конфиг и поднимаем реплики..."
        remote_compose_up "${ACTIVE_PRIMARY_IP}" "--force-recreate" patroni
        wait_for_remote_health "${ACTIVE_PRIMARY_IP}" "Patroni Primary (${ACTIVE_PRIMARY_IP})" \
            "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/primary" 60 3 \
            "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 60 patroni || true"
    else
        if [[ ! -f "$(state_root)/.cluster_installed" ]]; then
            log_info "Очистка незавершенного состояния Patroni и автоподбор доступного маршрута/порта PostgreSQL..."
            stop_and_clean_pg_cb() {
                local ip="$1"
                remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose stop patroni 2>/dev/null || true; rm -rf '${PG_DATA_DIR}/data' && mkdir -p '${PG_DATA_DIR}/data'"
            }
            for_each_node stop_and_clean_pg_cb
            remote_exec "${NODE1_IP}" "
                ECID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1 || true)
                if [[ -n \"\${ECID}\" ]]; then
                    docker exec \"\${ECID}\" etcdctl --endpoints='https://127.0.0.1:${ETCD_CLIENT_PORT:-2379}' \
                        --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
                        del --prefix '/${CLUSTER_SLUG}/' >/dev/null 2>&1 || true
                fi
            "

            # Формируем список портов-кандидатов (текущий PG_PORT, 2382 рядом с рабочим etcd, HTTPS-alt 8445/6443/4433/8080)
            RESERVED_PORTS=" ${ADMIN_SSH_PORT:-22} ${HTTPS_PORT:-443} ${SFTP_PORT:-2022} ${FTPS_PORT:-21} ${PANEL_PORT:-9443} ${PATRONI_API_PORT:-8008} ${HAPROXY_PG_PORT:-5433} ${ETCD_CLIENT_PORT:-2379} ${ETCD_PEER_PORT:-2380} ${ETCD_METRICS_PORT:-2381} "
            CAND_PORTS=""
            for _cp in "${PG_PORT}" 2382 8445 6443 4433 8080; do
                if [[ "${RESERVED_PORTS}" != *" ${_cp} "* && " ${CAND_PORTS} " != *" ${_cp} "* ]]; then
                    CAND_PORTS+="${CAND_PORTS:+ }${_cp}"
                fi
            done

            ASYMMETRIC_BLOCKED_PAIRS=()
            SELECTED_PORT=""
            SELECTED_PRIMARY_IP=""
            SELECTED_PRIMARY_NAME=""
            NODE_CNT=$(get_node_count)
            for _qi in $(seq 1 "${NODE_CNT}"); do
                _qip=$(get_node_ip "${_qi}")
                _qname=$(get_node_name "${_qi}")
                if ! is_quorum_node "${_qi}" "${_qname}"; then
                    continue
                fi
                probe_node_candidate_ports "${_qip}" "${_qname}" "${CAND_PORTS}"
                if [[ -n "${PROBED_SELECTED_PORT}" ]]; then
                    SELECTED_PORT="${PROBED_SELECTED_PORT}"
                    SELECTED_PRIMARY_IP="${_qip}"
                    SELECTED_PRIMARY_NAME="${_qname}"
                    break
                fi
            done

            if [[ -z "${SELECTED_PRIMARY_IP}" ]]; then
                SELECTED_PRIMARY_IP="${NODE1_IP}"
                SELECTED_PRIMARY_NAME="${NODE1_NAME}"
                SELECTED_PORT="${PG_PORT}"
                log_warn "🔄 Прямой межсетевой порт PostgreSQL закрыт на всех кворум-узлах — включаем автоматический защищенный SSH-мост..."
            else
                if [[ "${SELECTED_PORT}" != "${PG_PORT}" ]]; then
                    log_warn "🔄 Автопереключение PostgreSQL с фильтруемого порта ${PG_PORT} на открытый mTLS-порт ${SELECTED_PORT} (Primary: ${SELECTED_PRIMARY_NAME})..."
                    persist_cluster_env_var "PG_PORT" "${SELECTED_PORT}"
                    export PG_PORT="${SELECTED_PORT}"
                    for_each_node harden_node_ufw
                    for_each_node render_and_push_cb
                fi
                if [[ "${SELECTED_PRIMARY_IP}" != "${NODE1_IP}" ]]; then
                    log_warn "🔄 Автовыбор узла ${SELECTED_PRIMARY_NAME} (${SELECTED_PRIMARY_IP}:${PG_PORT}) в качестве начального Patroni Primary (прямая связность со всеми репликами)"
                fi
            fi

            # Если между какими-то узлами обнаружена полная блокировка прямого TCP провайдером — поднимаем прозрачный SSH-мост
            if (( ${#ASYMMETRIC_BLOCKED_PAIRS[@]} > 0 )); then
                SEEN_BRIDGES=" "
                for _pair in "${ASYMMETRIC_BLOCKED_PAIRS[@]}"; do
                    [[ "${SEEN_BRIDGES}" == *" ${_pair} "* ]] && continue
                    SEEN_BRIDGES+="${_pair} "
                    IFS='|' read -r _sip _sname _dip _dname <<< "${_pair}"
                    ensure_ssh_peer_bridge "${_sip}" "${_sname}" "${_dip}" "${_dname}" || \
                        log_warn "Дополнительный SSH-мост ${_sname} -> ${_dname} пропущен (основной маршрут идет через ${SELECTED_PRIMARY_NAME})"
                done
            fi

            ACTIVE_PRIMARY_IP="${SELECTED_PRIMARY_IP}"
            ACTIVE_PRIMARY_NAME="${SELECTED_PRIMARY_NAME}"
        fi

        log_info "Старт Patroni Primary на ${ACTIVE_PRIMARY_NAME} (${ACTIVE_PRIMARY_IP}:${PG_PORT})..."
        remote_compose_up "${ACTIVE_PRIMARY_IP}" "--force-recreate" patroni
        wait_for_remote_health "${ACTIVE_PRIMARY_IP}" "Patroni Primary /primary (${ACTIVE_PRIMARY_NAME})" \
            "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/primary" 60 3 \
            "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 60 patroni || true; curl -sk https://127.0.0.1:${PATRONI_API_PORT:-8008}/patroni || true"
    fi

    start_replica_cb() {
        local ip="$1" name="$3"
        [[ "${ip}" == "${ACTIVE_PRIMARY_IP}" ]] && return 0
        if ! remote_tcp_probe "${ip}" "${ACTIVE_PRIMARY_IP}" "${PG_PORT:-15432}" 8; then
            sleep 2
            if ! remote_tcp_probe "${ip}" "${ACTIVE_PRIMARY_IP}" "${PG_PORT:-15432}" 8; then
                log_warn "  ⚠️  Прямой TCP ${name} (${ip}) -> ${ACTIVE_PRIMARY_NAME} (${ACTIVE_PRIMARY_IP}:${PG_PORT}) недоступен — включаем резервный SSH-мост..."
                ensure_ssh_peer_bridge "${ip}" "${name}" "${ACTIVE_PRIMARY_IP}" "${ACTIVE_PRIMARY_NAME}"
            fi
        fi
        if ! remote_tcp_probe "${ip}" "${ACTIVE_PRIMARY_IP}" "${PG_PORT:-15432}" 10; then
            log_error "❌ Сетевой порт PostgreSQL ${ACTIVE_PRIMARY_IP}:${PG_PORT:-15432} недоступен с узла ${name} (${ip}) даже после включения моста!"
            exit 1
        fi
        remote_exec_stdin "${ip}" "${PG_DATA_DIR}" <<'REMOTE_PREP_REPLICA'
set -euo pipefail
PG_DIR="$1"
if [[ ! -f "${PG_DIR}/data/PG_VERSION" && -d "${PG_DIR}/data" ]]; then
    find "${PG_DIR}/data" -mindepth 1 -delete 2>/dev/null || true
fi
REMOTE_PREP_REPLICA
        log_info "Старт Patroni Replica на ${name} (${ip})..."
        remote_compose_up "${ip}" "--force-recreate" patroni
        wait_for_remote_health "${ip}" "Patroni Replica ${name} /replica" \
            "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 80 3 \
            "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 60 patroni || true; curl -sk https://127.0.0.1:${PATRONI_API_PORT:-8008}/patroni || true"
    }
    for_each_node start_replica_cb

    # Обновляем ACTIVE_PRIMARY_IP на случай перевыборов во время старта
    ACTIVE_PRIMARY_IP=$(find_patroni_primary_ip || echo "${ACTIVE_PRIMARY_IP}")
    ACTIVE_PRIMARY_NAME=$(get_node_name_by_ip "${ACTIVE_PRIMARY_IP}")
fi

log_step "Запуск HAProxy (127.0.0.1:${HAPROXY_PG_PORT:-5433} -> PG Primary)"
start_haproxy_cb() {
    local ip="$1" name="$3"
    if [[ "${DRY_RUN:-false}" != "true" && "${ip}" != "${ACTIVE_PRIMARY_IP}" ]]; then
        if ! remote_tcp_probe "${ip}" "${ACTIVE_PRIMARY_IP}" "${PATRONI_API_PORT:-8008}" 5 \
            || ! remote_tcp_probe "${ip}" "${ACTIVE_PRIMARY_IP}" "${PG_PORT:-15432}" 5; then
            if remote_exec "${ACTIVE_PRIMARY_IP}" "nc -z 127.0.0.1 ${PATRONI_API_PORT:-8008} && nc -z 127.0.0.1 ${PG_PORT:-15432}" >/dev/null 2>&1; then
                log_warn "  ⚠️  Порт Patroni API (${PATRONI_API_PORT:-8008}) или PG (${PG_PORT:-15432}) на ${ACTIVE_PRIMARY_NAME} недоступен с ${name} для HAProxy — включаем SSH-мост..."
                ensure_ssh_peer_bridge "${ip}" "${name}" "${ACTIVE_PRIMARY_IP}" "${ACTIVE_PRIMARY_NAME}"
            fi
        fi
    fi
    remote_compose_up "${ip}" "--force-recreate" haproxy
    wait_for_remote_health "${ip}" "HAProxy ${name}" "nc -z 127.0.0.1 ${HAPROXY_PG_PORT:-5433}" 15 2 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 40 haproxy || true"
}
for_each_node start_haproxy_cb

log_step "Создание пользователей и БД (sftpgo, seaweedfs_filer) на Primary (${ACTIVE_PRIMARY_IP})"
remote_exec_env_stdin "${ACTIVE_PRIMARY_IP}" "SFTPGO_DB_PASSWORD,SWFS_FILER_DB_PASSWORD" "${REMOTE_BASE_DIR}" <<'REMOTE_DB_INIT'
set -euo pipefail
BASE_DIR="$1"

PATRONI_CID=$(cd "${BASE_DIR}" && docker compose ps -q patroni | head -n1)
[[ -n "${PATRONI_CID}" ]] || { echo "Patroni container not found" >&2; exit 1; }
TMP_DB_ENV=$(mktemp)
chmod 600 "${TMP_DB_ENV}"
trap 'rm -f "${TMP_DB_ENV}"' EXIT
printf 'SFTPGO_PW=%s\nSWFS_PW=%s\n' "${SFTPGO_DB_PASSWORD}" "${SWFS_FILER_DB_PASSWORD}" > "${TMP_DB_ENV}"
docker exec -i --env-file "${TMP_DB_ENV}" "${PATRONI_CID}" python3 - <<'PYEOF'
import os, psycopg2
from psycopg2 import sql

conn = psycopg2.connect(dbname="postgres", user="postgres", host="/var/run/postgresql")
conn.autocommit = True
cur = conn.cursor()

def ensure_role_and_db(role, pw, db):
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,))
    if not cur.fetchone():
        cur.execute(sql.SQL("CREATE USER {} WITH PASSWORD %s").format(sql.Identifier(role)), (pw,))
    else:
        cur.execute(sql.SQL("ALTER USER {} WITH PASSWORD %s").format(sql.Identifier(role)), (pw,))
    cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (db,))
    if not cur.fetchone():
        cur.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(sql.Identifier(db), sql.Identifier(role)))

ensure_role_and_db("sftpgo", os.environ["SFTPGO_PW"], "sftpgo")
ensure_role_and_db("seaweedfs", os.environ["SWFS_PW"], "seaweedfs_filer")
cur.close()
conn.close()
print("PostgreSQL roles and databases ensured cleanly.")
PYEOF
REMOTE_DB_INIT

log_step "Инициализация pgBackRest stanza '${CLUSTER_SLUG}'"
if [[ "${BACKUP_S3_ACCESS_KEY:-FIXME}" != *FIXME* && "${BACKUP_S3_ACCESS_KEY:-}" != "" ]]; then
    remote_exec "${ACTIVE_PRIMARY_IP}" "
        PATRONI_CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1) && \
        docker exec -u postgres \"\${PATRONI_CID}\" pgbackrest --stanza='${CLUSTER_SLUG}' stanza-create && \
        docker exec -u postgres \"\${PATRONI_CID}\" pgbackrest --stanza='${CLUSTER_SLUG}' check
    "
else
    log_warn "BACKUP_S3_ACCESS_KEY не задан — пропуск pgbackrest stanza-create"
fi

log_info "✅ Стадия 3 завершена: etcd + Patroni + HAProxy работают"
