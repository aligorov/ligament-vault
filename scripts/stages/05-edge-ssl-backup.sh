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
    LEGO_ENV="${SSL_DIR}/.lego.env"
    write_clean_lego_env "${LEGO_ENV}"
    trap 'rm -f "${LEGO_ENV}"' EXIT
    if [[ ! -s "${LEGO_ENV}" ]]; then
        log_warn "Токены DNS-провайдера (${DNS_PROVIDER:-cloudflare}) не заданы — пропуск lego DNS-01"
    else
        rm -f "${SSL_DIR}/certificates/${DOMAIN}.crt" "${SSL_DIR}/certificates/${DOMAIN}.key" "${SSL_DIR}/.selfsigned"
        ACME_MAIL="${ACME_EMAIL:-}"
        [[ -z "${ACME_MAIL}" || "${ACME_MAIL}" == "admin@company.com" ]] && ACME_MAIL="admin@${DOMAIN}"
        ensure_local_image "$(resolve_image_ref "${LEGO_IMAGE}" "${LEGO_DIGEST:-}")"
        run_or_dry docker run --rm \
            -v "${SSL_DIR}:/lego" \
            --env-file "${LEGO_ENV}" \
            "$(resolve_image_ref "${LEGO_IMAGE}" "${LEGO_DIGEST:-}")" \
            --accept-tos \
            --email "${ACME_MAIL}" \
            --dns "${DNS_PROVIDER:-cloudflare}" \
            --domains "${DOMAIN}" \
            --path /lego \
            run
    fi
    rm -f "${LEGO_ENV}"
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
PRIMARY_PG_IP=$(find_patroni_primary_ip || echo "${NODE1_IP}")
log_step "2/7 — SFTPGo initprovider (update_mode=1, однократно на Primary ${PRIMARY_PG_IP})"
ensure_remote_image "${PRIMARY_PG_IP}" "$(resolve_service_image_ref sftpgo)"
remote_exec "${PRIMARY_PG_IP}" "cd '${REMOTE_BASE_DIR}' && docker compose run --rm --no-deps sftpgo sftpgo initprovider --config-file /etc/sftpgo/sftpgo.json"
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
    remote_compose_up "${ip}" "--force-recreate" sftpgo node-exporter
    wait_for_remote_health "${ip}" "SFTPGo ${name}" \
        "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q sftpgo | head -n1) && [[ -n \"\${CID}\" ]] && docker exec \"\${CID}\" sftpgo ping --config-file /etc/sftpgo/sftpgo.json" 25 2 \
        "cd '${REMOTE_BASE_DIR}' && docker compose logs --tail 50 sftpgo || true"
}
for_each_node start_edge_cb

# --- 4. Автопровижининг Virtual Folders S3 (sftp-work, sftp-worm) в SFTPGo ---
log_step "4/7 — Провижининг Virtual Folders S3 (sftp-work, sftp-worm) в SFTPGo"
sftpgo_provision_s3_folders "${NODE1_IP}"

# --- 5. Обновление DNS / Floating IP ---
log_step "5/7 — Переключение входной точки (${DOMAIN} -> ${NODE1_IP})"
update_dns_provider "${NODE1_IP}" || log_warn "Проверьте DNS A-запись ${DOMAIN} -> ${NODE1_IP} (TTL ${DNS_TTL:-60}s)"

# --- 6. Деплой внешнего Арбитра (ограниченный SSH-ключ + Prometheus + systemd) ---
log_step "6/7 — Развертывание внешнего Арбитра & Prometheus Stack"
if [[ -n "${ARBITER_IP:-}" ]]; then
    deploy_arbiter() {
        local count
        count=$(get_node_count)
        local t_ne="" t_etcd="" t_pat="" t_swm="" t_swv="" t_swf="" t_sftp=""
        for i in $(seq 1 "${count}"); do
            local nip nname
            nip=$(get_node_ip "$i")
            nname=$(get_node_name "$i")
            [[ -n "${t_ne}" ]] && t_ne+=", " && t_pat+=", " && t_swv+=", " && t_swf+=", " && t_sftp+=", "
            t_ne+="\"${nip}:9100\""
            t_pat+="\"${nip}:${PATRONI_API_PORT:-8008}\""
            t_swv+="\"${nip}:${SWFS_VOLUME_METRICS_PORT:-9325}\""
            t_swf+="\"${nip}:${SWFS_FILER_METRICS_PORT:-9326}\""
            t_sftp+="\"${nip}:${SFTPGO_TELEMETRY_PORT:-10000}\""
            if is_quorum_node "$i" "${nname}"; then
                [[ -n "${t_swm}" ]] && t_swm+=", " && t_etcd+=", "
                t_swm+="\"${nip}:${SWFS_MASTER_METRICS_PORT:-9324}\""
                t_etcd+="\"${nip}:${ETCD_METRICS_PORT:-2381}\""
            fi
        done
        export PROM_TARGETS_NODE_EXPORTER="${t_ne}"
        export PROM_TARGETS_ETCD="${t_etcd}"
        export PROM_TARGETS_PATRONI="${t_pat}"
        export PROM_TARGETS_SWFS_MASTER="${t_swm}"
        export PROM_TARGETS_SWFS_VOLUME="${t_swv}"
        export PROM_TARGETS_SWFS_FILER="${t_swf}"
        export PROM_TARGETS_SFTPGO="${t_sftp}"
        export HTTPS_PORT="${HTTPS_PORT:-443}"
        export PROMETHEUS_IMAGE_REF ALERTMANAGER_IMAGE_REF BLACKBOX_IMAGE_REF
        PROMETHEUS_IMAGE_REF=$(resolve_image_ref "${PROMETHEUS_IMAGE}" "${PROMETHEUS_DIGEST:-}")
        ALERTMANAGER_IMAGE_REF=$(resolve_image_ref "${ALERTMANAGER_IMAGE}" "${ALERTMANAGER_DIGEST:-}")
        BLACKBOX_IMAGE_REF=$(resolve_image_ref "${BLACKBOX_EXPORTER_IMAGE}" "${BLACKBOX_EXPORTER_DIGEST:-}")
        export ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-http://127.0.0.1:9099/alerts}"

        local arb_out
        arb_out="$(state_root)/.rendered/arbiter"
        mkdir -p "${arb_out}"
        render_template "${SCRIPT_DIR}/configs/prometheus/prometheus.yml.tpl" "${arb_out}/prometheus.yml"
        render_template "${SCRIPT_DIR}/configs/prometheus/alertmanager.yml.tpl" "${arb_out}/alertmanager.yml"
        render_template "${SCRIPT_DIR}/configs/prometheus/arbiter-compose.yml.tpl" "${arb_out}/docker-compose.yml"

        local arb_pubkey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDryRunPlaceholderKey"
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            arb_pubkey=$(remote_exec_stdin "${ARBITER_IP}" "${ARBITER_BASE_DIR}" <<'REMOTE_ARB_KEY'
set -euo pipefail
ARB_DIR="$1"
mkdir -p "${ARB_DIR}/.ssh" && chmod 700 "${ARB_DIR}/.ssh"
if [[ ! -f "${ARB_DIR}/.ssh/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -f "${ARB_DIR}/.ssh/id_ed25519" -N "" -C "arbiter" >/dev/null
fi
chmod 600 "${ARB_DIR}/.ssh/id_ed25519"
awk '{print $1 " " $2}' "${ARB_DIR}/.ssh/id_ed25519.pub"
REMOTE_ARB_KEY
            )
        fi
        install_helper_cb() { install_arbiter_helper_on_node "$1" "${arb_pubkey}"; }
        for_each_node install_helper_cb

        write_clean_lego_env "${arb_out}/arbiter-secrets.env"
        remote_exec "${ARBITER_IP}" "mkdir -p '${ARBITER_BASE_DIR}/scripts/lib' '${ARBITER_BASE_DIR}/scripts/ops' '${ARBITER_BASE_DIR}/prometheus'"
        remote_copy "${arb_out}/docker-compose.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/docker-compose.yml"
        remote_copy "${arb_out}/prometheus.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/prometheus.yml"
        remote_copy "${arb_out}/alertmanager.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/alertmanager.yml"
        remote_copy "${SCRIPT_DIR}/configs/prometheus/blackbox.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/blackbox.yml"
        remote_copy "${SCRIPT_DIR}/configs/prometheus/alerts.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/alerts.yml"
        remote_copy "$(state_root)/.pki/ca/ca.crt" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/ca.crt"
        remote_copy "$(state_root)/cluster.env" "${ARBITER_IP}:${ARBITER_BASE_DIR}/cluster.env"
        remote_copy "${arb_out}/arbiter-secrets.env" "${ARBITER_IP}:${ARBITER_BASE_DIR}/secrets.env"
        rm -f "${arb_out}/arbiter-secrets.env"
        remote_copy "${SCRIPT_DIR}/versions.env" "${ARBITER_IP}:${ARBITER_BASE_DIR}/versions.env"
        remote_copy "${SCRIPT_DIR}/scripts/lib/common.sh" "${ARBITER_IP}:${ARBITER_BASE_DIR}/scripts/lib/common.sh"
        remote_copy "${SCRIPT_DIR}/scripts/lib/deploy.sh" "${ARBITER_IP}:${ARBITER_BASE_DIR}/scripts/lib/deploy.sh"
        remote_copy "${SCRIPT_DIR}/scripts/ops/dns-failover-arbiter.sh" "${ARBITER_IP}:${ARBITER_BASE_DIR}/scripts/ops/dns-failover-arbiter.sh"

        ensure_remote_image "${ARBITER_IP}" "${PROMETHEUS_IMAGE_REF}"
        ensure_remote_image "${ARBITER_IP}" "${ALERTMANAGER_IMAGE_REF}"
        ensure_remote_image "${ARBITER_IP}" "${BLACKBOX_IMAGE_REF}"

        remote_exec_stdin "${ARBITER_IP}" "${ARBITER_BASE_DIR}" "${CLUSTER_SLUG}" <<'REMOTE_ARB'
set -euo pipefail
ARB_DIR="$1"; SLUG="$2"
chmod 600 "${ARB_DIR}/secrets.env" "${ARB_DIR}/cluster.env"
chmod +x "${ARB_DIR}/scripts/ops/dns-failover-arbiter.sh"

cd "${ARB_DIR}" && docker compose up -d

cat > "/etc/systemd/system/${SLUG}-arbiter.service" <<UNIT
[Unit]
Description=Ligament Vault (${SLUG}) External Failover & 5-Gate Arbiter
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${ARB_DIR}
ExecStart=${ARB_DIR}/scripts/ops/dns-failover-arbiter.sh --daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "${SLUG}-arbiter.service"
REMOTE_ARB
    }
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
