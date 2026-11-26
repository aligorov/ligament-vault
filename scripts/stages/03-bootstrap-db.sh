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

ensure_quorum_nodes_initialized
for_each_node tune_node_wan_and_swap
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
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d etcd"
}
for_each_node start_etcd_cb

NODE1_IP=$(get_node_ip 1)
NODE1_NAME=$(get_node_name 1)
ETCD_ALL_ENDPOINTS=$(build_etcd_hosts | tr ',' '\n' | awk -v p="${ETCD_CLIENT_PORT:-2379}" '{sub(/:[0-9]+$/,""); print "https://" $1 ":" p}' | paste -sd, -)

wait_for_remote_health "${NODE1_IP}" "etcd quorum" \
    "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1) && [[ -n \"\${CID}\" ]] && docker exec \"\${CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health && curl -sf --cacert '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/ca.crt' --cert '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/etcd-client.crt' --key '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/etcd-client.key' https://127.0.0.1:${ETCD_CLIENT_PORT:-2379}/version | grep -qE '\"etcdcluster\":\"3\\.[456]'" \
    30 3 \
    "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 50 etcd || true"

if [[ "${DRY_RUN:-false}" != "true" ]]; then
    log_info "Проверка всех участников etcd (${ETCD_ALL_ENDPOINTS}):"
    remote_exec "${NODE1_IP}" "
        CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q etcd | head -n1)
        curl -skf --cacert '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/ca.crt' --cert '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/etcd-client.crt' --key '${REMOTE_BASE_DIR}/certs/${NODE1_NAME}/etcd-client.key' https://127.0.0.1:${ETCD_CLIENT_PORT:-2379}/version || true
        echo ''
        docker exec \"\${CID}\" etcdctl --endpoints='${ETCD_ALL_ENDPOINTS}' --dial-timeout=5s --command-timeout=8s \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health -w table || true
        docker exec \"\${CID}\" etcdctl --endpoints='${ETCD_ALL_ENDPOINTS}' --dial-timeout=5s --command-timeout=8s \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint status -w table || true
    " || true
fi

log_step "Запуск Patroni Primary -> Replicas"
if [[ "${DRY_RUN:-false}" != "true" && ! -f "$(state_root)/.cluster_installed" ]]; then
    remote_exec_stdin "${NODE1_IP}" "${REMOTE_BASE_DIR}" "${PG_DATA_DIR}" "${ETCD_CLIENT_PORT:-2379}" "/${CLUSTER_SLUG}/${CLUSTER_SLUG}" <<'REMOTE_PREP_PRIMARY'
set -euo pipefail
BASE_DIR="$1"; PG_DIR="$2"; EC_PORT="$3"; PATRONI_PREFIX="$4"
if [[ ! -f "${PG_DIR}/data/PG_VERSION" ]]; then
    if [[ -d "${PG_DIR}/data" ]]; then
        find "${PG_DIR}/data" -mindepth 1 -delete 2>/dev/null || true
    fi
    ETCD_CID=$(cd "${BASE_DIR}" && docker compose ps -q etcd | head -n1 || true)
    if [[ -n "${ETCD_CID}" ]]; then
        docker exec "${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC_PORT}" \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
            del --prefix "${PATRONI_PREFIX}" >/dev/null 2>&1 || true
    fi
fi
REMOTE_PREP_PRIMARY
fi

log_info "Старт Patroni Primary на $(get_node_name 1) (${NODE1_IP})..."
remote_exec "${NODE1_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --force-recreate patroni"
wait_for_remote_health "${NODE1_IP}" "Patroni Primary /primary" \
    "curl -sf http://127.0.0.1:${PATRONI_API_PORT:-8008}/primary" 60 3 \
    "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 60 patroni || true; curl -s http://127.0.0.1:${PATRONI_API_PORT:-8008}/patroni || true"

start_replica_cb() {
    local ip="$1" name="$3" idx="$4"
    if (( idx == 1 )); then return 0; fi
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        remote_exec_stdin "${ip}" "${PG_DATA_DIR}" <<'REMOTE_PREP_REPLICA'
set -euo pipefail
PG_DIR="$1"
if [[ ! -f "${PG_DIR}/data/PG_VERSION" && -d "${PG_DIR}/data" ]]; then
    find "${PG_DIR}/data" -mindepth 1 -delete 2>/dev/null || true
fi
REMOTE_PREP_REPLICA
    fi
    log_info "Старт Patroni Replica на ${name} (${ip})..."
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --force-recreate patroni"
    wait_for_remote_health "${ip}" "Patroni Replica ${name} /replica" \
        "curl -sf http://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 80 3 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 60 patroni || true; curl -s http://127.0.0.1:${PATRONI_API_PORT:-8008}/patroni || true"
}
for_each_node start_replica_cb

log_step "Запуск HAProxy (127.0.0.1:${HAPROXY_PG_PORT:-5433} -> PG Primary)"
start_haproxy_cb() {
    local ip="$1" name="$3"
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --force-recreate haproxy"
    wait_for_remote_health "${ip}" "HAProxy ${name}" "nc -z 127.0.0.1 ${HAPROXY_PG_PORT:-5433}" 15 2 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 40 haproxy || true"
}
for_each_node start_haproxy_cb

log_step "Создание пользователей и БД (sftpgo, seaweedfs_filer)"
remote_exec_stdin "${NODE1_IP}" "${REMOTE_BASE_DIR}" "${SFTPGO_DB_PASSWORD}" "${SWFS_FILER_DB_PASSWORD}" <<'REMOTE_DB_INIT'
set -euo pipefail
BASE_DIR="$1"
SFTPGO_PW="$2"
SWFS_PW="$3"

PATRONI_CID=$(cd "${BASE_DIR}" && docker compose ps -q patroni | head -n1)
[[ -n "${PATRONI_CID}" ]] || { echo "Patroni container not found" >&2; exit 1; }
docker exec -i -e "SFTPGO_PW=${SFTPGO_PW}" -e "SWFS_PW=${SWFS_PW}" "${PATRONI_CID}" python3 - <<'PYEOF'
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
    remote_exec "${NODE1_IP}" "
        PATRONI_CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1) && \
        docker exec -u postgres \"\${PATRONI_CID}\" pgbackrest --stanza='${CLUSTER_SLUG}' stanza-create && \
        docker exec -u postgres \"\${PATRONI_CID}\" pgbackrest --stanza='${CLUSTER_SLUG}' check
    "
else
    log_warn "BACKUP_S3_ACCESS_KEY не задан — пропуск pgbackrest stanza-create"
fi

log_info "✅ Стадия 3 завершена: etcd + Patroni + HAProxy работают"
