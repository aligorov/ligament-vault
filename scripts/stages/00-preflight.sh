#!/usr/bin/env bash
# ============================================================================
# 00-preflight.sh — Проверка готовности VPS и окружения (Спринт 0)
# ============================================================================
# Вызов: ./clusterctl preflight [--dry-run]
#
# Проверки:
#   1. Локальные зависимости (ssh, scp, openssl, python3) и env-файлы
#   2. SSH-доступ ко всем нодам (key-only, BatchMode)
#   3. Полная RTT-матрица (ping -c 100, HARD STOP при max_RTT > 250ms)
#   4. NTP / chrony синхронизация
#   5. Свободное место на дисках (>= MIN_FREE_DISK_GB)
#   6. Свободность FTPS PASV-портов (FTPS_PASV_MIN..FTPS_PASV_MAX)
#   7. Docker + docker compose и ядро
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
log_step "${PROJECT_NAME}: Preflight Check (Спринт 0)"

PREFLIGHT_PASS=true
NODE_COUNT=$(get_node_count)

# --- 1. Локальные зависимости и конфиг ---
log_step "1/7 — Локальные зависимости и конфигурация"
for cmd in ssh scp openssl python3; do
    check_command "${cmd}" || PREFLIGHT_PASS=false
done

if (( NODE_COUNT < 3 )); then
    log_error "В CLUSTER_NODES указано ${NODE_COUNT} нод(ы), минимум 3 для кворума!"
    PREFLIGHT_PASS=false
else
    log_info "  ✅ Узлов в CLUSTER_NODES: ${NODE_COUNT}"
fi

if [[ "${CLUSTER_NODES}" == *FIXME* ]]; then
    log_warn "  ⚠️  CLUSTER_NODES содержит FIXME-заглушки — заполните реальные IP в cluster.env"
    [[ "${DRY_RUN:-false}" != "true" ]] && PREFLIGHT_PASS=false
fi

if [[ "${ADMIN_SSH_NET:-0.0.0.0/0}" == "0.0.0.0/0" ]]; then
    log_warn "  ⚠️  ADMIN_SSH_NET=0.0.0.0/0 — рекомендуется ограничить до статического IP/CIDR администратора!"
fi

if [[ -f "${CONFIG_ROOT}/secrets.env" ]] && grep -q "FIXME" "${CONFIG_ROOT}/secrets.env"; then
    log_warn "  ⚠️  secrets.env содержит незаполненные FIXME-значения (обязательно заменить до Стадии 2)"
fi

if grep -q "FIXME" "${SCRIPT_DIR}/versions.env"; then
    log_warn "  ⚠️  versions.env содержит незаполненные FIXME-дайджесты (запустите ./ligactl pin-versions)"
fi

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] Проверка SSH, RTT (ping -c 100), chrony, дисков (${MIN_FREE_DISK_GB:-20}GB), PASV (${FTPS_PASV_MIN:-50000}-${FTPS_PASV_MAX:-50199}) и Docker на ${NODE_COUNT} нодах"
    log_info "✅ Preflight [DRY-RUN] завершен"
    exit 0
fi

# --- 2. SSH-доступ ---
check_ssh_access() {
    local ip="$1" name="$3"
    if remote_exec "${ip}" "echo ok" &>/dev/null; then
        log_info "  ✅ SSH OK: ${name} (${ip})"
    else
        log_error "  ❌ SSH FAIL: ${name} (${ip})"
        PREFLIGHT_PASS=false
    fi
}
log_step "2/7 — SSH-доступ (BatchMode, key-only)"
for_each_node check_ssh_access

if [[ "${PREFLIGHT_PASS}" != "true" ]]; then
    log_error "❌ Preflight прерван: нет SSH-доступа к одному или нескольким узлам."
    exit 1
fi

# --- 3. RTT-матрица (ping -c 100) ---
check_rtt() {
    log_step "3/7 — RTT-матрица между ДЦ (ping -c 100)"
    local max_rtt=0

    for i in $(seq 1 "${NODE_COUNT}"); do
        for j in $(seq $((i+1)) "${NODE_COUNT}"); do
            local src_ip dst_ip src_name dst_name rtt_avg
            src_ip=$(get_node_ip "$i")
            dst_ip=$(get_node_ip "$j")
            src_name=$(get_node_name "$i")
            dst_name=$(get_node_name "$j")

            log_info "  Замер ${src_name} (${src_ip}) <-> ${dst_name} (${dst_ip})..."
            rtt_avg=$(remote_exec "${src_ip}" "ping -c 100 -i 0.2 -q '${dst_ip}'" 2>/dev/null | \
                      awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}') || rtt_avg=9999
            [[ -z "${rtt_avg}" ]] && rtt_avg=9999

            if (( rtt_avg > ${RTT_HARD_STOP:-250} )); then
                log_error "  ❌ HARD STOP: RTT ${src_name}<->${dst_name} = ${rtt_avg}ms > ${RTT_HARD_STOP:-250}ms!"
                PREFLIGHT_PASS=false
            elif (( rtt_avg > ${RTT_WARN:-150} )); then
                log_warn "  ⚠️  RTT ${src_name}<->${dst_name} = ${rtt_avg}ms > ${RTT_WARN:-150}ms"
            else
                log_info "  ✅ RTT ${src_name}<->${dst_name}: ${rtt_avg}ms"
            fi

            (( rtt_avg > max_rtt )) && max_rtt=${rtt_avg}
        done
    done

    if (( max_rtt <= ${RTT_HARD_STOP:-250} )); then
        local rec_hb=$(( max_rtt > 100 ? max_rtt : 250 ))
        local rec_el=$(( rec_hb * 10 ))
        log_info "Макс. RTT=${max_rtt}ms -> рекомендовано: ETCD_HEARTBEAT_INTERVAL=${rec_hb}ms, ETCD_ELECTION_TIMEOUT=${rec_el}ms"
    fi
}
check_rtt

# --- 4. NTP / chrony ---
check_ntp() {
    local ip="$1" name="$3"
    local chrony_ok
    chrony_ok=$(remote_exec "${ip}" "chronyc tracking 2>/dev/null | grep -c 'Leap status.*Normal'" || echo "0")
    if (( chrony_ok >= 1 )); then
        log_info "  ✅ chrony синхронизирован: ${name}"
    else
        log_warn "  ⚠️  chrony еще не настроен на ${name} (будет включен на Стадии 1)"
    fi
}
log_step "4/7 — NTP (chrony)"
for_each_node check_ntp

# --- 5. Свободное место на диске раздела данных (${PG_DATA_DIR}) ---
check_disk() {
    local ip="$1" name="$3"
    local min_gb="${MIN_FREE_DISK_GB:-80}"
    local target_dir="${PG_DATA_DIR:-/data/postgresql}"
    local avail_gb
    avail_gb=$(remote_exec_stdin "${ip}" "${target_dir}" <<'REMOTE_DF' || echo "0"
t="$1"
while [[ ! -d "$t" && "$t" != "/" ]]; do t="$(dirname "$t")"; done
df -BG --output=avail "$t" | tail -n1 | tr -dc '0-9'
REMOTE_DF
    )
    if (( avail_gb < min_gb )); then
        log_error "  ❌ Недостаточно места на разделе данных ${name}: ${avail_gb}GB < MIN_FREE_DISK_GB=${min_gb}GB (нужен запас под 64GB pg_wal!)"
        PREFLIGHT_PASS=false
    else
        log_info "  ✅ Свободно под данные (${target_dir}): ${avail_gb}GB (${name})"
    fi
}
log_step "5/7 — Дисковое пространство (>= ${MIN_FREE_DISK_GB:-80}GB под БД/WAL и тома)"
for_each_node check_disk

# --- 6. PASV-порты ---
check_pasv_ports() {
    local ip="$1" name="$3"
    local pmin="${FTPS_PASV_MIN:-50000}" pmax="${FTPS_PASV_MAX:-50199}"
    local busy
    busy=$(remote_exec_stdin "${ip}" "${pmin}" "${pmax}" <<'REMOTE_PASV' || echo "0"
pmin="$1"; pmax="$2"
ss -H -tln 2>/dev/null | awk '{print $4}' | awk -F':' '{print $NF}' | \
    awk -v lo="$pmin" -v hi="$pmax" '$1>=lo && $1<=hi {c++} END{print c+0}'
REMOTE_PASV
    )
    if (( busy > 0 )); then
        log_warn "  ⚠️  На ${name} занято ${busy} портов из PASV-диапазона ${pmin}-${pmax}"
    else
        log_info "  ✅ PASV-порты ${pmin}-${pmax} свободны: ${name}"
    fi
}
log_step "6/7 — Проверка FTPS PASV-портов"
for_each_node check_pasv_ports

# --- 7. Docker и ядро ---
check_docker_kernel() {
    local ip="$1" name="$3"
    local info
    info=$(remote_exec "${ip}" "docker --version 2>/dev/null && docker compose version 2>/dev/null && uname -r" || echo "FAIL")
    if [[ "${info}" == *"FAIL"* ]]; then
        log_error "  ❌ Docker или docker compose plugin отсутствует на ${name}"
        PREFLIGHT_PASS=false
    else
        log_info "  ✅ Docker + Compose OK на ${name} ($(echo "${info}" | tail -n1))"
    fi
}
log_step "7/7 — Docker, Compose и ядро"
for_each_node check_docker_kernel

echo ""
if [[ "${PREFLIGHT_PASS}" == "true" ]]; then
    log_info "✅ Preflight PASSED. Можно запускать: ./clusterctl install"
else
    log_error "❌ Preflight FAILED. Устраните ошибки выше перед установкой."
    exit 1
fi
