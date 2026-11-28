#!/usr/bin/env bash
# ============================================================================
# 05-edge-ssl-backup.sh — SSL (lego DNS-01), SFTPGo (+S3 Folders), Арбитр & Backups
# ============================================================================
# Вызов: ./ligactl install --stage 5
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
log_step "Стадия 5: Edge (SSL + SFTPGo + Арбитр/Мониторинг + Бэкапы)"

SSL_DIR="$(state_root)/.ssl"
NODE1_IP=$(get_node_ip 1)

# --- 1. Выпуск SSL-сертификата через lego DNS-01 ---
log_step "1/7 — Выпуск SSL (${DOMAIN}) через lego DNS-01"
mkdir -p "${SSL_DIR}"
if [[ -f "${SSL_DIR}/certificates/${DOMAIN}.crt" && ! -f "${SSL_DIR}/.selfsigned" ]]; then
    log_info "Сертификат ${DOMAIN} уже выпущен в ${SSL_DIR} — пропускаем первичный выпуск"
else
    prepare_lego_credentials
    trap 'rm -rf "${LEGO_CREDENTIALS}"' EXIT
    if (( ${#LEGO_ARGS[@]} == 0 )); then
        log_warn "Токены DNS-провайдера (${DNS_PROVIDER:-cloudflare}) не заданы — пропуск lego DNS-01"
    else
        issue_lego_certificate "$SSL_DIR" 30 || log_warn "lego не выпустил сертификат. Для запуска будет использован локальный сертификат."

    fi
    rm -rf "${LEGO_CREDENTIALS}"
fi

ensure_fallback_or_distribute_ssl() {
    if [[ ! -f "${SSL_DIR}/certificates/${DOMAIN}.crt" && "${DRY_RUN:-false}" != "true" ]]; then
        log_warn "⚠️  Публичный SSL-сертификат не получен — создаем временный self-signed для запуска WebClient/FTPS!"
        mkdir -p "${SSL_DIR}/certificates"
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 7 \
            -keyout "${SSL_DIR}/certificates/${DOMAIN}.key" \
            -out "${SSL_DIR}/certificates/${DOMAIN}.crt" \
            -subj "/CN=${DOMAIN}" -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}" 2>/dev/null
        touch "${SSL_DIR}/.selfsigned"
    fi
    for_each_node distribute_ssl_to_node
}
ensure_fallback_or_distribute_ssl

# --- 2. Однократный sftpgo initprovider ДО старта SFTPGo ---
if [[ "${DRY_RUN:-false}" != "true" && "${HTTPS_PORT:-443}" == "443" ]]; then
    HTTPS_443_BUSY=false
    _chk_443_cb() {
        local ip="$1"
        local proc
        proc=$(remote_exec "${ip}" "ss -H -tlnp 'sport = :443' 2>/dev/null | head -n1 || true" 2>/dev/null || true)
        if [[ -n "${proc}" ]] && ! echo "${proc}" | grep -q "sftpgo"; then
            HTTPS_443_BUSY=true
        fi
    }
    for_each_node _chk_443_cb
    if [[ "${HTTPS_443_BUSY}" == "true" ]]; then
        log_warn "  ⚠️  Порт 443 занят соседним сервисом — автоматически переключаем SFTPGo HTTPS WebClient на :8444..."
        export HTTPS_PORT=8444
        persist_cluster_env_var "HTTPS_PORT" "8444"
        for_each_node harden_node_ufw
        _rerender_edge_cb() {
            render_node_configs "$1" "$2" "$3" "$4" "existing"
            push_node_configs "$1" "$2" "$3" "$4"
        }
        for_each_node _rerender_edge_cb
    fi
fi

PRIMARY_PG_IP=$(find_writable_pg_primary_ip || find_patroni_primary_ip || echo "${NODE1_IP}")
log_step "2/7 — SFTPGo initprovider (update_mode=1, однократно на Primary ${PRIMARY_PG_IP})"
ensure_remote_image "${PRIMARY_PG_IP}" "$(resolve_service_image_ref sftpgo)"
for _init_try in 1 2 3; do
    PRIMARY_PG_IP=$(find_writable_pg_primary_ip || find_patroni_primary_ip || echo "${NODE1_IP}")
    ensure_remote_image "${PRIMARY_PG_IP}" "$(resolve_service_image_ref sftpgo)"
    if remote_exec "${PRIMARY_PG_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose run --rm --no-deps sftpgo sftpgo initprovider --config-file /etc/sftpgo/sftpgo.json"; then
        break
    fi
    (( _init_try == 3 )) && exit 1
    log_warn "  ⏳ Повтор sftpgo initprovider через 4с (попытка ${_init_try}/3)..."
    sleep 4
done
log_info "  ✅ Схема SFTPGo в PostgreSQL инициализирована"

_ensure_sftpgo_unprivileged_ports_cb() {
    local ip="$1" name="$3"
    local cur_start
    cur_start=$(remote_exec "${ip}" "sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 0")
    if [[ "${cur_start}" =~ ^[0-9]+$ ]] && (( cur_start > 21 )); then
        log_info "  Разрешаем SFTPGo (UID 1000) бинд портов >= 21 на ${name} (${ip})..."
        remote_exec "${ip}" "sysctl -w net.ipv4.ip_unprivileged_port_start=21 >/dev/null && (grep -q 'ip_unprivileged_port_start' /etc/sysctl.d/99-ligament-vault.conf 2>/dev/null || echo 'net.ipv4.ip_unprivileged_port_start = 21' >> /etc/sysctl.d/99-ligament-vault.conf)"
    fi
}
for_each_node _ensure_sftpgo_unprivileged_ports_cb

# --- 3. Запуск SFTPGo и node-exporter ---
log_step "3/7 — Запуск SFTPGo и node-exporter на всех нодах"
start_edge_cb() {
    local ip="$1" name="$3"
    log_info "  Старт SFTPGo и node-exporter на ${name} (${ip})..."
    remote_compose_up "${ip}" "--force-recreate" sftpgo
    remote_compose_up "${ip}" "--force-recreate" node-exporter || log_warn "  ⚠️  node-exporter на ${name} пропущен (ограничение mount-propagation хоста)"
    wait_for_remote_health "${ip}" "SFTPGo ${name}" \
        "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q sftpgo | head -n1) && [[ -n \"\${CID}\" ]] && docker exec \"\${CID}\" sftpgo ping --config-file /etc/sftpgo/sftpgo.json" 35 2 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 50 sftpgo || true"
}
for_each_node start_edge_cb

# --- 4. Автопровижининг Virtual Folders S3 (sftp-work, sftp-worm) в SFTPGo ---
log_step "4/7 — Провижининг Virtual Folders S3 (sftp-work, sftp-worm) в SFTPGo"
sftpgo_provision_s3_folders "${NODE1_IP}"

# --- 5. Обновление DNS / Floating IP ---
log_step "5/7 — Переключение входной точки (${DOMAIN} -> ${NODE1_IP})"
if ! update_dns_provider "${NODE1_IP}"; then
    expected=$(resolve_node_ipv4 "${NODE1_IP}") || exit 1
    actual=$(resolve_node_ipv4 "${DOMAIN}" 2>/dev/null) || actual=""
    if [[ "${actual}" != "${expected}" ]]; then
        log_error "Публикация входного DNS-имени ${DOMAIN} не подтверждена"
        exit 1
    fi
    log_warn "Входное DNS-имя уже указывает на ${expected}, автоматическое обновление не подтверждено"
fi

# --- 6. Деплой внешнего Арбитра (ограниченный SSH-ключ + Prometheus + systemd) ---
log_step "6/7 — Развертывание внешнего Арбитра & Prometheus Stack"
if [[ -n "${ARBITER_IP:-}" ]]; then
    source "${SCRIPT_DIR}/scripts/lib/arbiter-deploy.sh"
    deploy_arbiter
    log_info "  ✅ Арбитр (restricted SSH + Prometheus/Blackbox + systemd) развернут на ${ARBITER_IP}"
else
    log_warn "ARBITER_IP не задан — внешний мониторинг и автоматический failover не развернуты"
fi

# --- 7. Проверка бэкапов ---
log_step "7/7 — Проверка бэкапов"
if [[ "${BACKUP_S3_ACCESS_KEY:-FIXME}" != *FIXME* && "${BACKUP_S3_ACCESS_KEY:-}" != "" ]]; then
    PRIMARY_PG_IP=$(find_patroni_primary_ip || echo "${NODE1_IP}")
    remote_exec "${PRIMARY_PG_IP}" "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q patroni | head -n1); [[ -n \"\${CID}\" ]] && docker exec -u postgres \"\${CID}\" pgbackrest --stanza='${CLUSTER_SLUG}' check" \
        || log_warn "pgBackRest check вернул предупреждение — проверьте configs/pgbackrest.conf"
else
    log_warn "Бэкапы pgBackRest/filer.backup ожидают заполнения BACKUP_S3_* в секретах"
fi

echo ""
log_info "═══════════════════════════════════════════════════════════"
log_info "🎉 Установка ${PROJECT_NAME} завершена! Дальнейшие шаги:"
log_info "  1. Приемка S3/WORM: ./ligactl verify --sprint 1"
log_info "  2. Создать клиента: ./ligactl user add --username client1 --generate-password"
log_info "  3. Общий статус:    ./ligactl status"
log_info "  4. WebAdmin туннель: ssh -N -L 8081:127.0.0.1:8081 root@${NODE1_IP}"
log_info "═══════════════════════════════════════════════════════════"
