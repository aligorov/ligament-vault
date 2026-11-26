#!/usr/bin/env bash
# ============================================================================
# chaos-dr-test.sh — Chaos & Disaster Recovery тестирование (Day-1, Спринты 3–6)
# ============================================================================
# Вызов: ./clusterctl verify [--disruptive] [--dry-run] [--yes]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"

DISRUPTIVE=false
for arg in "$@"; do
    [[ "${arg}" == "--disruptive" ]] && DISRUPTIVE=true
done

log_step "Chaos & DR Acceptance Tests (disruptive=${DISRUPTIVE})"
confirm_action "⚠️  Chaos-тест проверит switchover/failover PG, остановку swfs-admin и периметр. Запускать ДО продакшн-трафика. Продолжить?" || exit 0

NODE1_IP=$(get_node_ip 1)
NODE2_IP=$(get_node_ip 2)
ADMIN_IP=$(get_node_ip "${SWFS_ADMIN_NODE_INDEX:-2}")

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] 1. Периметр: отказ Filer :8888 без JWT"
    log_info "[DRY-RUN] 2. Patroni switchover (или pause при --disruptive) + RTO HAProxy :5433"
    log_info "[DRY-RUN] 3. Проверка записи Filer через HAProxy после смены Primary PG"
    log_info "[DRY-RUN] 4. Остановка swfs-admin -> проверка fallback [master.maintenance] на Master -> возврат swfs-admin"
    log_info "[DRY-RUN] 5. Финальный cluster-health.sh --strict"
    log_info "✅ Chaos/DR [DRY-RUN] OK"
    exit 0
fi

# --- Тест 1: Периметр SeaweedFS без JWT ---
log_step "Тест 1/5 — Периметр SeaweedFS без JWT"
http_code=$(remote_exec "${NODE1_IP}" "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:${SWFS_FILER_PORT:-8888}/chaos-unauth-check" || echo "000")
if [[ "${http_code}" == "401" || "${http_code}" == "403" ]]; then
    log_info "  ✅ PASS: Filer отклонил неавторизованную запись без JWT (HTTP ${http_code})"
else
    log_error "  ❌ FAIL: Filer вернул HTTP ${http_code} без JWT! Проверьте security.toml"
    exit 1
fi

# --- Тест 2: Patroni failover / switchover ---
log_step "Тест 2/5 — Patroni $([[ "${DISRUPTIVE}" == "true" ]] && echo 'HARD PAUSE failover' || echo 'switchover') и HAProxy :5433"
old_primary=$(find_patroni_primary_ip)
start_ts=$(date +%s)

if [[ "${DISRUPTIVE}" == "true" ]]; then
    log_warn "  Пауза контейнера patroni на ${old_primary} для симуляции отказа лидера..."
    remote_exec "${old_primary}" "cd '${REMOTE_BASE_DIR}' && docker compose pause patroni"
else
    remote_exec "${old_primary}" "PCID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1); docker exec \"\${PCID}\" patronictl switchover '${CLUSTER_SLUG}' --force"
fi

new_primary=""
for _ in $(seq 1 45); do
    cur_p=$(find_patroni_primary_ip || true)
    if [[ -n "${cur_p}" && "${cur_p}" != "${old_primary}" ]]; then
        new_primary="${cur_p}"
        break
    fi
    sleep 2
done
elapsed=$(( $(date +%s) - start_ts ))

if [[ -n "${new_primary}" ]]; then
    log_info "  ✅ PASS: Новый PG Primary ${new_primary} выбран за ${elapsed}s"
else
    [[ "${DISRUPTIVE}" == "true" ]] && remote_exec "${old_primary}" "cd '${REMOTE_BASE_DIR}' && docker compose unpause patroni" || true
    log_error "  ❌ FAIL: Новый Primary не выбран за 90s"
    exit 1
fi

wait_for_remote_health "${NODE2_IP}" "HAProxy :5433 -> новый Primary" \
    "PCID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1); docker exec -u postgres -e PGSSLMODE=verify-full -e PGSSLROOTCERT=/run/pg-certs/ca.crt -e PGSSLCERT=/run/pg-certs/pg-client.crt -e PGSSLKEY=/run/pg-certs/pg-client.key \"\${PCID}\" pg_isready -h 127.0.0.1 -p ${HAPROXY_PG_PORT:-5433} -U postgres" 15 2
log_info "  ✅ PASS: HAProxy :5433 принимает подключения к новому Primary"

if [[ "${DISRUPTIVE}" == "true" ]]; then
    log_info "  Возврат ${old_primary} (unpause patroni -> pg_rewind -> replica catch-up)..."
    remote_exec "${old_primary}" "cd '${REMOTE_BASE_DIR}' && docker compose unpause patroni"
    wait_for_remote_health "${old_primary}" "Returned node /replica" "curl -sf http://127.0.0.1:${PATRONI_API_PORT:-8008}/replica" 30 3
    log_info "  ✅ PASS: Бывший лидер вернулся репликой без ручного вмешательства"
fi

# --- Тест 3: Непрерывность Filer ---
log_step "Тест 3/5 — Работа SeaweedFS Filer через HAProxy после смены PG Primary"
MASTER_PEERS=$(build_swfs_master_peers)
remote_exec "${NODE2_IP}" "FCID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q swfs-filer | head -n1); docker exec -i \"\${FCID}\" weed shell -master='${MASTER_PEERS}' <<< 'fs.ls /'" >/dev/null
log_info "  ✅ PASS: Filer отвечает через новый PG Primary"

# --- Тест 4: Падение weed admin -> проверка fallback master.toml ---
log_step "Тест 4/5 — Остановка swfs-admin и проверка готовности fallback [master.maintenance]"
remote_exec "${ADMIN_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose stop swfs-admin"
sleep 3
leader_master_ip=$(remote_exec "${NODE1_IP}" "curl -sf http://127.0.0.1:${SWFS_MASTER_PORT:-9333}/cluster/status | jq -r '.Leader'" | cut -d: -f1)
if remote_exec "${leader_master_ip:-${NODE1_IP}}" "test -s '${REMOTE_BASE_DIR}/configs/seaweedfs/master.toml' && grep -q 'volume.fix.replication' '${REMOTE_BASE_DIR}/configs/seaweedfs/master.toml'"; then
    log_info "  ✅ PASS: [master.maintenance] настроен на Master Leader (${leader_master_ip}) для автономного fallback при падении swfs-admin"
else
    remote_exec "${ADMIN_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d swfs-admin" || true
    log_error "  ❌ FAIL: [master.maintenance] отсутствует в master.toml"
    exit 1
fi
remote_exec "${ADMIN_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d swfs-admin"
wait_for_remote_health "${ADMIN_IP}" "SWFS Admin restore" "nc -z 127.0.0.1 ${SWFS_ADMIN_PORT:-12535}" 15 2

# --- Тест 5: Финальная проверка здоровья ---
log_step "Тест 5/5 — Проверка сходимости кластера"
sleep 5
bash "${SCRIPT_DIR}/scripts/verify/cluster-health.sh" --strict

log_info "✅ Все Chaos & DR тесты пройдены"
