#!/usr/bin/env bash
# ============================================================================
# 02-pki-secrets.sh — PKI (Zero-Knowledge Remote-CSR) и SSH host-keys
# ============================================================================
# Вызов: ./ligactl install --stage 2
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
log_step "Стадия 2: PKI (Remote-CSR ECDSA P-256) & SSH Host Keys"

if [[ "${DRY_RUN:-false}" != "true" ]]; then
    if ! has_secrets_configured; then
        log_error "Секреты не найдены! Запустите './ligactl secrets init' перед установкой."
        exit 1
    fi
    for req_secret in SFTPGO_ADMIN_PASSWORD SFTPGO_KMS_MASTER_KEY PG_SUPERUSER_PASSWORD PATRONI_API_PASSWORD SWFS_JWT_SIGNING_KEY SWFS_S3_SECRET_KEY_SFTPGO; do
        if [[ "${!req_secret:-FIXME}" == *FIXME* ]]; then
            log_error "Секрет ${req_secret} содержит незаполненное значение FIXME!"
            exit 1
        fi
    done
fi

ensure_ca_exists
for_each_node generate_node_certs

setup_ssh_host_keys() {
    local keys_dir
    keys_dir="$(state_root)/ssh-host-keys"
    mkdir -p "${keys_dir}"
    if [[ -f "${keys_dir}/id_ed25519" && -f "${keys_dir}/id_ecdsa" && -f "${keys_dir}/id_rsa" ]]; then
        log_info "Общие SSH host-keys уже существуют, используем текущие"
        return 0
    fi
    log_info "Генерация общих SSH host-keys для SFTPGo (${CLUSTER_SLUG})..."
    run_or_dry ssh-keygen -t ed25519 -f "${keys_dir}/id_ed25519" -N "" -C "sftpgo-${CLUSTER_SLUG}" >/dev/null
    run_or_dry ssh-keygen -t ecdsa -b 256 -f "${keys_dir}/id_ecdsa" -N "" -C "sftpgo-${CLUSTER_SLUG}" >/dev/null
    run_or_dry ssh-keygen -t rsa -b 4096 -f "${keys_dir}/id_rsa" -N "" -C "sftpgo-${CLUSTER_SLUG}" >/dev/null
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        chmod 600 "${keys_dir}"/id_*
        chmod 644 "${keys_dir}"/*.pub
    fi
}

setup_ssh_host_keys
for_each_node distribute_ssh_keys_to_node

log_info "✅ Стадия 2 завершена: PKI, CRL-база и общие SSH host-keys развернуты"
