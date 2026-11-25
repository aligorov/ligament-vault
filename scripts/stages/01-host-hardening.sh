#!/usr/bin/env bash
# ============================================================================
# 01-host-hardening.sh — Укрепление хостов (chrony, fail2ban, UFW, sysctl)
# ============================================================================
# Вызов: ./clusterctl install --stage 1
# Вся логика переиспользуется из scripts/lib/deploy.sh (harden_node_full).
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
log_step "Стадия 1: Host Hardening & UFW (120s External Dead-Man's Switch)"

if [[ "${ADMIN_SSH_NET:-0.0.0.0/0}" == "0.0.0.0/0" ]]; then
    log_warn "⚠️  ADMIN_SSH_NET=0.0.0.0/0 — SSH будет открыт всему интернету!"
    confirm_action "Продолжить с ADMIN_SSH_NET=0.0.0.0/0?" || exit 1
fi

for_each_node harden_node_full

log_info "✅ Стадия 1 завершена: все узлы укреплены, внешний SSH после UFW подтвержден"
