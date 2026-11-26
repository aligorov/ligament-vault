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
    ENV_FILE="${CONFIG_ROOT:-${SCRIPT_DIR}}/cluster.env"
    if [[ "${DRY_RUN:-false}" != "true" && -f "${ENV_FILE}" ]]; then
        python3 - "${ENV_FILE}" <<'PYENV'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
txt = p.read_text(encoding="utf-8")
if re.search(r"^PG_PORT=", txt, flags=re.M):
    txt = re.sub(r"^PG_PORT=.*$", "PG_PORT=15432", txt, flags=re.M)
else:
    txt = txt.rstrip("\n") + "\nPG_PORT=15432\n"
p.write_text(txt, encoding="utf-8")
PYENV
    fi
    export PG_PORT=15432
    PG_PORT_MIGRATED=true
fi
export PG_PORT="${PG_PORT:-15432}"

ensure_quorum_nodes_initialized
for_each_node tune_node_wan_and_swap
for_each_node harden_node_ufw
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
ACTIVE_PRIMARY_IP="${NODE1_IP}"

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    remote_exec "${NODE1_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --force-recreate patroni"
    for_each_node_dry_rep() {
        local ip="$1" idx="$4"
        (( idx == 1 )) && return 0
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --force-recreate patroni"
    }
    for_each_node for_each_node_dry_rep
else
    # Проверяем, есть ли уже здоровый лидер Patroni на целевом порту PG_PORT
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
            if ! remote_exec "${ip}" "nc -z -w 8 '${CANDIDATE_PRIMARY}' '${PG_PORT:-15432}'" >/dev/null 2>&1; then
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
        log_info "Обнаружен действующий лидер Patroni на ${ACTIVE_PRIMARY_IP} — обновляем его конфиг и поднимаем реплики..."
        remote_exec "${ACTIVE_PRIMARY_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --force-recreate patroni"
        wait_for_remote_health "${ACTIVE_PRIMARY_IP}" "Patroni Primary (${ACTIVE_PRIMARY_IP})" \
            "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/primary" 60 3 \
            "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 60 patroni || true"
    else
        if [[ ! -f "$(state_root)/.cluster_installed" ]]; then
            log_info "Очистка незавершенного состояния Patroni после прерванной первичной установки..."
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
        fi

        ACTIVE_PRIMARY_IP="${NODE1_IP}"
        log_info "Старт Patroni Primary на $(get_node_name 1) (${NODE1_IP})..."
        remote_exec "${NODE1_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --force-recreate patroni"
        wait_for_remote_health "${NODE1_IP}" "Patroni Primary /primary" \
            "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/primary" 60 3 \
            "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 60 patroni || true; curl -sk https://127.0.0.1:${PATRONI_API_PORT:-8008}/patroni || true"
    fi

    start_replica_cb() {
        local ip="$1" name="$3"
        [[ "${ip}" == "${ACTIVE_PRIMARY_IP}" ]] && return 0
        if ! remote_exec "${ip}" "nc -z -w 10 '${ACTIVE_PRIMARY_IP}' '${PG_PORT:-15432}' || (sleep 2 && nc -z -w 10 '${ACTIVE_PRIMARY_IP}' '${PG_PORT:-15432}')" >/dev/null 2>&1; then
            log_error "❌ Сетевой порт PostgreSQL ${ACTIVE_PRIMARY_IP}:${PG_PORT:-15432} недоступен с узла ${name} (${ip})!"
            log_error "   Проверьте внешний облачный файрвол хостинга (Security Group / Cloud Firewall) между ${ip} и ${ACTIVE_PRIMARY_IP} для TCP ${PG_PORT:-15432}."
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
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --force-recreate patroni"
        wait_for_remote_health "${ip}" "Patroni Replica ${name} /replica" \
            "curl -sf --cacert '${REMOTE_BASE_DIR}/certs/ca.crt' https://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 80 3 \
            "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 60 patroni || true; curl -sk https://127.0.0.1:${PATRONI_API_PORT:-8008}/patroni || true"
    }
    for_each_node start_replica_cb

    # Обновляем ACTIVE_PRIMARY_IP на случай перевыборов во время старта
    ACTIVE_PRIMARY_IP=$(find_patroni_primary_ip || echo "${ACTIVE_PRIMARY_IP}")
fi

log_step "Запуск HAProxy (127.0.0.1:${HAPROXY_PG_PORT:-5433} -> PG Primary)"
start_haproxy_cb() {
    local ip="$1" name="$3"
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d --force-recreate haproxy"
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
