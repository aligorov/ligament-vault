#!/usr/bin/env bash
# ============================================================================
# Ligament Vault — Единый однострочный установщик и запуск Веб-панели (:8443)
# ============================================================================
# Установка на чистый Ubuntu 22.04 / 24.04 LTS (от root):
#
#   curl -fsSL https://raw.githubusercontent.com/aligorov/ligament-vault/main/install.sh | sudo bash
#
# Неинтерактивный режим с авторазвертыванием кластера:
#   NODES="1.1.1.1 2.2.2.2 3.3.3.3" DOMAIN="files.example.com" \
#     curl -fsSL https://raw.githubusercontent.com/aligorov/ligament-vault/main/install.sh | sudo -E bash
# ============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/aligorov/ligament-vault.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ligament-vault-ctl}"
PANEL_PORT="${PANEL_PORT:-8443}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}[Ligament Vault]${NC} $*"; }
warn() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $*" >&2; }
err()  { echo -e "${RED}[ОШИБКА]${NC} $*" >&2; exit 1; }

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    info "[DRY-RUN] Установка зависимостей -> клонирование ${REPO_URL} в ${INSTALL_DIR} -> генерация секретов -> запуск systemd сервиса ligament-vault-ui (:8443)"
    exit 0
fi

[[ "${EUID}" -eq 0 ]] || err "Запустите установщик от имени root: curl -fsSL https://raw.githubusercontent.com/aligorov/ligament-vault/main/install.sh | sudo bash"

# 1. Установка базовых пакетов и Docker (если отсутствует)
info "1/5 — Проверка системных пакетов и Docker..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl jq age openssl python3 python3-yaml openssh-client sshpass ca-certificates

if ! command -v docker >/dev/null 2>&1; then
    info "Установка Docker Engine + Compose..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

# 2. Клонирование / обновление репозитория и глобальная команда ligactl
info "2/5 — Загрузка Ligament Vault в ${INSTALL_DIR}..."
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    git -C "${INSTALL_DIR}" pull --ff-only
else
    rm -rf "${INSTALL_DIR}"
    git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
fi
chmod +x "${INSTALL_DIR}/ligactl" "${INSTALL_DIR}/clusterctl" "${INSTALL_DIR}/web/panel.py" \
         "${INSTALL_DIR}"/scripts/lib/*.sh "${INSTALL_DIR}"/scripts/stages/*.sh \
         "${INSTALL_DIR}"/scripts/ops/*.sh "${INSTALL_DIR}"/scripts/verify/*.sh "${INSTALL_DIR}"/scripts/hooks/*.sh
ln -sf "${INSTALL_DIR}/ligactl" /usr/local/bin/ligactl

# 3. Подготовка SSH-ключа оркестратора (и автодобавление на текущий узел)
info "3/5 — Настройка SSH-ключа оркестратора..."
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [[ ! -f /root/.ssh/id_ed25519 ]]; then
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "ligament-vault-orchestrator" >/dev/null
fi
PUBKEY=$(cat /root/.ssh/id_ed25519.pub)
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
grep -Fqx "${PUBKEY}" /root/.ssh/authorized_keys || echo "${PUBKEY}" >> /root/.ssh/authorized_keys

# 4. Автоконфигурация cluster.env и криптостойких секретов (без ручного редактирования!)
info "4/5 — Генерация конфигурации и шифрованных секретов..."
PUBLIC_IP=$(curl -4 -fsSL --max-time 4 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

if [[ ! -f "${INSTALL_DIR}/cluster.env" ]]; then
    cp "${INSTALL_DIR}/cluster.env.example" "${INSTALL_DIR}/cluster.env"
    chmod 600 "${INSTALL_DIR}/cluster.env"

    if [[ -n "${NODES:-}" ]]; then
        NODE_LIST=""
        IDX=1
        for nip in ${NODES}; do
            [[ -n "${NODE_LIST}" ]] && NODE_LIST+=" "
            NODE_LIST+="${nip}:dc${IDX}:node${IDX}"
            IDX=$((IDX + 1))
        done
    else
        NODE_LIST="${PUBLIC_IP}:dc1:node1"
    fi
    sed -i "s|FIXME_IP1:dc1:node1 FIXME_IP2:dc2:node2 FIXME_IP3:dc3:node3|${NODE_LIST}|g" "${INSTALL_DIR}/cluster.env"
    if [[ -n "${DOMAIN:-}" ]]; then
        sed -i "s|DOMAIN=\"files.company.com\"|DOMAIN=\"${DOMAIN}\"|g" "${INSTALL_DIR}/cluster.env"
    fi
    sed -i "s|PANEL_PORT=8443|PANEL_PORT=${PANEL_PORT}|g" "${INSTALL_DIR}/cluster.env"
fi

if [[ ! -f "${INSTALL_DIR}/secrets.env" && ! -f "${INSTALL_DIR}/secrets.env.age" ]]; then
    "${INSTALL_DIR}/ligactl" secrets init
fi

# 5. Запуск HTTPS Веб-панели управления (:8443) через systemd
info "5/5 — Запуск HTTPS Веб-панели управления (порт ${PANEL_PORT}/tcp)..."
cat > /etc/systemd/system/ligament-vault-ui.service <<EOF
[Unit]
Description=Ligament Vault HTTPS Web Control Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
Environment="HOME=/root"
Environment="CONFIG_ROOT=${INSTALL_DIR}"
Environment="AGE_KEY_FILE=/root/.config/ligament/age.key"
Environment="PANEL_PORT=${PANEL_PORT}"
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/web/panel.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ligament-vault-ui.service >/dev/null 2>&1 || true
systemctl restart ligament-vault-ui.service

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "${PANEL_PORT}/tcp" comment "ligament-vault:web-panel" >/dev/null 2>&1 || true
fi

# Извлекаем пароль администратора для вывода в консоль
ADMIN_PASS=$(
    export SCRIPT_DIR="${INSTALL_DIR}"
    cd "${INSTALL_DIR}"
    # shellcheck disable=SC1091
    source "${INSTALL_DIR}/scripts/lib/common.sh"
    load_cluster_env "${INSTALL_DIR}"
    echo "${SFTPGO_ADMIN_PASSWORD:-}"
)

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  🎉 Ligament Vault установлен — Веб-панель управления запущена!          ║${NC}"
echo -e "${CYAN}${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}${BOLD}║${NC}  🌐 Веб-интерфейс:  ${GREEN}${BOLD}https://${PUBLIC_IP}:${PANEL_PORT}${NC}"
echo -e "${CYAN}${BOLD}║${NC}  👤 Логин:          ${BOLD}admin${NC}"
echo -e "${CYAN}${BOLD}║${NC}  🔑 Пароль:         ${YELLOW}${BOLD}${ADMIN_PASS}${NC}"
echo -e "${CYAN}${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}${BOLD}║${NC}  Откройте ссылку в браузере -> укажите IP серверов 2 и 3 ->             ${CYAN}${BOLD}║${NC}"
echo -e "${CYAN}${BOLD}║${NC}  нажмите «Развернуть кластер» (все остальное произойдет автоматически). ${CYAN}${BOLD}║${NC}"
echo -e "${CYAN}${BOLD}║${NC}  CLI также доступен глобально: ${BOLD}ligactl status | ligactl user ...${NC}       ${CYAN}${BOLD}║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Если переданы реальные NODES без FIXME — сразу запускаем установку кластера!
if [[ -n "${NODES:-}" ]]; then
    info "Обнаружена переменная NODES — запускаем автоматическое развертывание кластера..."
    "${INSTALL_DIR}/ligactl" install --yes
fi
