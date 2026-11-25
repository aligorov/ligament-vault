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
wait_for_remote_health "${NODE1_IP}" "etcd quorum" \
    "docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health" \
    30 3

log_step "Запуск Patroni Primary -> Replicas"
log_info "Старт Patroni Primary на $(get_node_name 1) (${NODE1_IP})..."
remote_exec "${NODE1_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d patroni"
wait_for_remote_health "${NODE1_IP}" "Patroni Primary /primary" \
    "curl -sf http://127.0.0.1:${PATRONI_API_PORT:-8008}/primary" 40 3

start_replica_cb() {
    local ip="$1" name="$3" idx="$4"
    if (( idx == 1 )); then return 0; fi
    log_info "Старт Patroni Replica на ${name} (${ip})..."
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d patroni"
    wait_for_remote_health "${ip}" "Patroni Replica ${name} /replica" \
        "curl -sf http://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 40 3
}
for_each_node start_replica_cb

log_step "Запуск HAProxy (127.0.0.1:${HAPROXY_PG_PORT:-5433} -> PG Primary)"
start_haproxy_cb() {
    local ip="$1" name="$3"
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d haproxy"
    wait_for_remote_health "${ip}" "HAProxy ${name}" "nc -z 127.0.0.1 ${HAPROXY_PG_PORT:-5433}" 15 2
}
for_each_node start_haproxy_cb

log_step "Создание пользователей и БД (sftpgo, seaweedfs_filer)"
remote_exec_stdin "${NODE1_IP}" "${SFTPGO_DB_PASSWORD}" "${SWFS_FILER_DB_PASSWORD}" <<'REMOTE_DB_INIT'
set -euo pipefail
SFTPGO_PW="$1"
SWFS_PW="$2"

PATRONI_CID=$(docker ps -qf name=patroni)
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
        PATRONI_CID=\$(docker ps -qf name=patroni) && \
        docker exec -u postgres \"\${PATRONI_CID}\" pgbackrest --stanza='${CLUSTER_SLUG}' stanza-create && \
        docker exec -u postgres \"\${PATRONI_CID}\" pgbackrest --stanza='${CLUSTER_SLUG}' check
    "
else
    log_warn "BACKUP_S3_ACCESS_KEY не задан — пропуск pgbackrest stanza-create"
fi

log_info "✅ Стадия 3 завершена: etcd + Patroni + HAProxy работают"
