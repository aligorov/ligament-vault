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
FORCE_FLAG=""
[[ "${1:-}" == "--force" ]] && FORCE_FLAG="--days 999"

log_step "Проверка и продление SSL (${DOMAIN}) через lego DNS-01"

LEGO_ENV="${SSL_DIR}/.lego.env"
write_clean_lego_env "${LEGO_ENV}"
trap 'rm -f "${LEGO_ENV}"' EXIT

if [[ ! -s "${LEGO_ENV}" ]]; then
    log_error "Токены DNS-провайдера (${DNS_PROVIDER:-cloudflare}) не заданы в secrets.env"
    exit 1
fi

cert_file="${SSL_DIR}/certificates/${DOMAIN}.crt"
before_mtime=""
[[ -f "${cert_file}" ]] && before_mtime=$(stat -c '%Y' "${cert_file}" 2>/dev/null || stat -f '%m' "${cert_file}" 2>/dev/null || echo "")

CMD="renew"
[[ ! -f "${cert_file}" ]] && CMD="run"

# shellcheck disable=SC2086
run_or_dry docker run --rm \
    -v "${SSL_DIR}:/lego" \
    --env-file "${LEGO_ENV}" \
    "$(resolve_image_ref "${LEGO_IMAGE}" "${LEGO_DIGEST:-}")" \
    --accept-tos \
    --email "${ACME_EMAIL:-admin@${DOMAIN}}" \
    --dns "${DNS_PROVIDER:-cloudflare}" \
    --domains "${DOMAIN}" \
    --domains "*.${DOMAIN}" \
    --path /lego \
    "${CMD}" ${FORCE_FLAG} --days 30

rm -f "${LEGO_ENV}"

after_mtime=""
[[ -f "${cert_file}" ]] && after_mtime=$(stat -c '%Y' "${cert_file}" 2>/dev/null || stat -f '%m' "${cert_file}" 2>/dev/null || echo "")

if [[ "${before_mtime}" != "${after_mtime}" || -n "${FORCE_FLAG}" ]]; then
    log_info "Сертификат обновлен — раскладка и SIGHUP SFTPGo без разрыва сессий..."
    distribute_and_hup() {
        distribute_ssl_to_node "$1" "$2" "$3" "$4"
        remote_exec "$1" "docker kill -s HUP \$(docker ps -qf name=sftpgo)"
    }
    for_each_node distribute_and_hup
    log_info "✅ Новый SSL распространен, SFTPGo перезагрузил TLS через SIGHUP"
else
    log_info "Продление не требуется (срок действия сертификата > 30 дней)"
fi
