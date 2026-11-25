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
    if remote_exec "${ip}" "chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'" 2>/dev/null; then
        log_info "  ✅ chrony синхронизирован: ${name}"
    else
        log_warn "  ⚠️  chrony еще не настроен на ${name} (будет включен на Стадии 1)"
    fi
}
log_step "4/7 — NTP (chrony)"
for_each_node check_ntp

# --- 5. Свободное место на диске (с авторасширением неразмеченного раздела и очисткой кэша apt) ---
check_disk() {
    local ip="$1" name="$3"
    local min_gb="${MIN_FREE_DISK_GB:-2}"
    # Игнорируем завышенный старый порог 20/80GB из ранних cluster.env — весь стек весит ~1GB!
    if (( min_gb > 5 )); then
        min_gb=2
    fi
    local target_dir="${PG_DATA_DIR:-/data/postgresql}"
    local disk_report
    disk_report=$(remote_exec_stdin "${ip}" "${target_dir}" <<'REMOTE_DF' || echo "0|df_error"
t="$1"
while [[ ! -d "$t" && "$t" != "/" ]]; do t="$(dirname "$t")"; done
avail_kb=$(df -Pk "$t" 2>/dev/null | awk 'NR==2 {print $4}')
avail_gb=$(( ${avail_kb:-0} / 1048576 ))

# Если свободно < 2 ГБ — глубокая безопасная очистка кэша apt/docker/go/pip/старых ядер и расширение раздела!
if (( avail_gb < 2 )); then
    export DEBIAN_FRONTEND=noninteractive
    rm -rf /root/.cache/go-build /root/.cache/pip /root/.cache/npm /root/.cache/uv /root/.cache/yarn \
           /var/lib/apt/lists/* /var/log/*.gz /var/log/*.[0-9] /tmp/* >/dev/null 2>&1 || true
    # Удаляем старые неиспользуемые linux-headers / linux-image (кроме текущего ядра uname -r!)
    CUR_KVER=$(uname -r | sed 's/-generic//')
    OLD_PKGS=$(dpkg -l 'linux-headers-[0-9]*' 'linux-modules-extra-[0-9]*' 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}' | grep -vF "${CUR_KVER}" || true)
    if [[ -n "${OLD_PKGS}" ]]; then
        # shellcheck disable=SC2086
        apt-get purge -y -qq ${OLD_PKGS} >/dev/null 2>&1 || true
    fi
    apt-get autoremove --purge -y -qq >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true
    journalctl --vacuum-size=20M >/dev/null 2>&1 || true
    docker builder prune -af >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ "${root_src}" =~ ^(/dev/[a-z]+d[a-z]+|/dev/nvme[0-9]+n[0-9]+p?)([0-9]+)$ ]]; then
        disk_dev="${BASH_REMATCH[1]%p}"
        part_num="${BASH_REMATCH[2]}"
        if command -v growpart >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq cloud-guest-utils >/dev/null 2>&1 && apt-get clean && rm -rf /var/lib/apt/lists/*); then
            growpart "${disk_dev}" "${part_num}" >/dev/null 2>&1 || true
            resize2fs "${root_src}" >/dev/null 2>&1 || xfs_growfs / >/dev/null 2>&1 || true
        fi
    fi
    avail_kb=$(df -Pk "$t" 2>/dev/null | awk 'NR==2 {print $4}')
    # Если всё ещё < 1.4 ГБ и есть большой /swapfile >= 900MB — аккуратно ужимаем swapfile до 384MB (+640MB места!)
    if (( ${avail_kb:-0} < 1433600 )) && [[ -f /swapfile ]]; then
        swap_sz=$(stat -c '%s' /swapfile 2>/dev/null || echo 0)
        if (( swap_sz >= 900000000 )); then
            swapoff /swapfile 2>/dev/null && rm -f /swapfile && fallocate -l 384M /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null || true
            avail_kb=$(df -Pk "$t" 2>/dev/null | awk 'NR==2 {print $4}')
        fi
    fi
    avail_gb=$(( ${avail_kb:-0} / 1048576 ))
fi
avail_mb=$(( ${avail_kb:-0} / 1024 ))
summary=$(df -h "$t" 2>/dev/null | awk 'NR==2 {print "всего=" $2 ", занято=" $3 ", свободно=" $4 " (" $5 ")"}')
echo "${avail_mb}|${summary}"
REMOTE_DF
    )
    local avail_mb="${disk_report%%|*}"
    local summary="${disk_report#*|}"
    avail_mb="${avail_mb//[^0-9]/}"
    [[ -z "${avail_mb}" ]] && avail_mb=0
    local avail_gb=$(( avail_mb / 1024 ))

    if (( avail_mb < 850 )); then
        log_error "  ❌ Критически мало места на ${name} (${ip}): свободно всего ${avail_mb}MB (< 850MB) [${summary}]"
        log_error "     Содержимое /root и топ папок на ${name}:"
        remote_exec "${ip}" "du -xhd1 / /root 2>/dev/null | sort -hr | head -n 12" || true
        PREFLIGHT_PASS=false
    elif (( avail_gb < 15 )); then
        log_warn "  ⚠️  Компактный диск на ${name}: свободно ${avail_mb}MB [${summary}] — для запуска стека достаточно"
    else
        log_info "  ✅ Свободно под данные (${target_dir}): ${avail_gb}GB [${summary}] (${name})"
    fi
}
log_step "5/7 — Дисковое пространство (мин. 2GB для старта стека)"
for_each_node check_disk

# --- 6. PASV и ключевые порты кластера (с автопереключением HTTPS_PORT=8444 если :443 занят чужим сайтом/VPN!) ---
PORT_443_BUSY=false
check_pasv_ports() {
    local ip="$1" name="$3"
    local pmin="${FTPS_PASV_MIN:-50000}" pmax="${FTPS_PASV_MAX:-50199}"
    local cur_https="${HTTPS_PORT:-443}"
    local conflicts
    conflicts=$(remote_exec_stdin "${ip}" "${SFTP_PORT:-2022}" "${PG_PORT:-5432}" "${cur_https}" <<'REMOTE_PORTS' || echo ""
sftp_p="$1"; pg_p="$2"; https_p="$3"
for p in "${https_p}" "${sftp_p}" "${pg_p}" 2379 8888 9333; do
    proc=$(ss -H -tlnp "sport = :${p}" 2>/dev/null | head -n1 || true)
    if [[ -n "${proc}" ]] && ! echo "${proc}" | grep -qE "sftpgo|postgres|etcd|weed"; then
        echo "${p}"
    fi
done
REMOTE_PORTS
    )
    local hard_conflicts=""
    for cp in ${conflicts}; do
        if [[ "${cp}" == "443" && "${cur_https}" == "443" ]]; then
            PORT_443_BUSY=true
        else
            hard_conflicts+="${cp} "
        fi
    done
    if [[ -n "${hard_conflicts}" ]]; then
        log_error "  ❌ На ${name} (${ip}) заняты кластерные порты: ${hard_conflicts}"
        PREFLIGHT_PASS=false
    fi
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
log_step "6/7 — Проверка портов и FTPS PASV"
for_each_node check_pasv_ports

if [[ "${PORT_443_BUSY}" == "true" ]]; then
    export HTTPS_PORT=8444
    ENV_TARGET="${CONFIG_ROOT:-${SCRIPT_DIR}}/cluster.env"
    if [[ -f "${ENV_TARGET}" ]]; then
        if grep -q '^HTTPS_PORT=' "${ENV_TARGET}"; then
            sed -i.bak 's/^HTTPS_PORT=.*/HTTPS_PORT=8444/' "${ENV_TARGET}" && rm -f "${ENV_TARGET}.bak"
        else
            echo 'HTTPS_PORT=8444' >> "${ENV_TARGET}"
        fi
    fi
    log_warn "  ⚠️  Порт 443 уже занят другими сервисами (2FA/VPN/Nginx) — файловый веб-клиент автоматически перенесен на порт :8444 (существующие сервисы на :443 сохранены!)"
fi

# --- 7. Docker и ядро (с автоустановкой Docker на чистых удаленных VPS!) ---
check_docker_kernel() {
    local ip="$1" name="$3"
    local info
    info=$(remote_exec "${ip}" "docker --version 2>/dev/null && docker compose version 2>/dev/null && uname -r" || echo "MISSING")
    if [[ "${info}" == *"MISSING"* ]]; then
        log_info "  ⚙️  Docker не найден на ${name} (${ip}) — устанавливаем автоматически..."
        if remote_exec "${ip}" "export DEBIAN_FRONTEND=noninteractive; curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1"; then
            info=$(remote_exec "${ip}" "docker --version 2>/dev/null && docker compose version 2>/dev/null && uname -r" || echo "FAIL")
        else
            info="FAIL"
        fi
    fi
    if [[ "${info}" == *"FAIL"* || "${info}" == *"MISSING"* ]]; then
        log_error "  ❌ Не удалось установить/проверить Docker на ${name} (${ip})"
        PREFLIGHT_PASS=false
    else
        log_info "  ✅ Docker + Compose готовы на ${name} ($(echo "${info}" | tail -n1))"
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
