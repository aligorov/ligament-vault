#!/usr/bin/env bash
# ============================================================================
# acme-lego-dns01.sh — Cron-обновление SSL-сертификата DNS-01 + SIGHUP
# ============================================================================
# Использование: ./scripts/ops/acme-lego-dns01.sh [--force]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"

SSL_DIR="$(state_root)/.ssl"
renew_days=30
[[ "${1:-}" == "--force" ]] && renew_days=999

log_step "Проверка и продление SSL (${DOMAIN}) через lego DNS-01"

prepare_lego_credentials
trap 'rm -rf "${LEGO_CREDENTIALS}"' EXIT

if (( ${#LEGO_ARGS[@]} == 0 )); then
    log_error "Токены DNS-провайдера (${DNS_PROVIDER:-cloudflare}) не заданы в базе управления"
    exit 1
fi

cert_file="${SSL_DIR}/certificates/${DOMAIN}.crt"
before=$(openssl x509 -in "$cert_file" -fingerprint -sha256 -noout 2>/dev/null || true)
issue_lego_certificate "$SSL_DIR" "$renew_days"
after=$(openssl x509 -in "$cert_file" -fingerprint -sha256 -noout 2>/dev/null || true)

if [[ "$before" != "$after" || "$renew_days" == 999 ]]; then
    log_info "Сертификат обновлен — раскладка и SIGHUP SFTPGo без разрыва сессий..."
    distribute_and_hup() {
        distribute_ssl_to_node "$1" "$2" "$3" "$4"
        remote_exec "$1" "CID=\$(cd '${REMOTE_BASE_DIR}' && docker compose ps -q sftpgo | head -n1); [[ -n \"\${CID}\" ]] && docker kill -s HUP \"\${CID}\""
    }
    for_each_node distribute_and_hup
    sync_arbiter_edge_trust
    log_info "✅ Новый SSL распространен, SFTPGo перезагрузил TLS через SIGHUP"
else
    log_info "Продление не требуется (срок действия сертификата > 30 дней)"
fi
