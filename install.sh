#!/usr/bin/env bash
# ============================================================================
# Ligament Vault — Единый однострочный установщик и запуск Веб-панели (:9443)
# ============================================================================
# Установка на Ubuntu 22.04 / 24.04 LTS (от root):
#
#   curl -fsSL https://raw.githubusercontent.com/aligorov/ligament-vault/main/install.sh | sudo bash
# ============================================================================

set -euo pipefail

REPO_URL=https://github.com/aligorov/ligament-vault.git
INSTALL_DIR=/opt/ligament-vault-ctl
requested_port=""
requested_domain=""
requested_nodes=""
while (($#)); do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --domain) requested_domain="$2"; shift 2 ;;
        --nodes) requested_nodes="$2"; shift 2 ;;
        --panel-port) requested_port="$2"; shift 2 ;;
        --dry-run) echo "План: установка зависимостей и панели, инициализация control.sqlite3"; exit 0 ;;
        *) echo "Неизвестная опция $1" >&2; exit 2 ;;
    esac
done
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[Ligament Vault]${NC} $*"; }
warn() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $*" >&2; }
err()  { echo -e "${RED}[ОШИБКА]${NC} $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || err "Запустите установщик от имени root: curl -fsSL https://raw.githubusercontent.com/aligorov/ligament-vault/main/install.sh | sudo bash"

# 1. Установка базовых пакетов и Docker (если отсутствует)
info "1/5 — Проверка системных пакетов и Docker..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl jq age apache2-utils openssl python3 python3-yaml openssh-client sshpass iproute2 ca-certificates

if ! command -v docker >/dev/null 2>&1; then
    info "Установка Docker Engine + Compose..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

# 2. Клонирование / обновление репозитория и глобальная команда ligactl
info "2/5 — Загрузка Ligament Vault в ${INSTALL_DIR}..."
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    git -C "${INSTALL_DIR}" fetch --quiet origin main
    # Import locally pinned versions before the update removes the old tracked file.
    if [[ ! -s "${INSTALL_DIR}/control.sqlite3" && -f "${INSTALL_DIR}/versions.env" ]]; then
        migration_dir=$(mktemp -d)
        trap 'rm -rf "$migration_dir"' EXIT
        mkdir -p "$migration_dir/scripts/lib" "$migration_dir/configs"
        for file in scripts/lib/config_db.py scripts/lib/node_address.py configs/control-defaults.json; do
            git -C "$INSTALL_DIR" show "FETCH_HEAD:$file" > "$migration_dir/$file"
        done
        python3 "$migration_dir/scripts/lib/config_db.py" --root "$INSTALL_DIR" init
        if ! git -C "$INSTALL_DIR" diff --quiet HEAD -- versions.env; then
            git -C "$INSTALL_DIR" stash push -m "Image pins imported into control.sqlite3" -- versions.env
        fi
        rm -rf "$migration_dir"
        trap - EXIT
    fi
    git -C "${INSTALL_DIR}" merge --ff-only FETCH_HEAD
else
    [[ ! -e "${INSTALL_DIR}" || -z "$(ls -A "${INSTALL_DIR}")" ]] || err "Каталог установки занят: ${INSTALL_DIR}"
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

info "4/5 — Инициализация базы управления..."
db=(python3 "${INSTALL_DIR}/scripts/lib/config_db.py" --root "${INSTALL_DIR}")
"${db[@]}" init
PANEL_PORT="${requested_port:-$("${db[@]}" get PANEL_PORT)}"
[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] && ((PANEL_PORT >= 1 && PANEL_PORT <= 65535)) || err "Некорректный порт панели"
PANEL_HOST=$(hostname -f)
if [[ "$("${db[@]}" get CLUSTER_NODES)" == *FIXME* && ( -n "$requested_nodes" || "$PANEL_HOST" == *.* ) ]]; then
    entries=()
    for host in ${requested_nodes:-${PANEL_HOST}}; do
        i=$(("${#entries[@]}" + 1))
        entries+=("${host}:dc${i}:node${i}")
    done
    printf %s "${entries[*]}" | "${db[@]}" set CLUSTER_NODES
fi
if [[ -n "$requested_domain" ]]; then printf %s "$requested_domain" | "${db[@]}" set DOMAIN; fi
systemctl stop ligament-vault-ui.service 2>/dev/null || true
for candidate in "$PANEL_PORT" 9443 9444 10443 18443; do
    if ! ss -H -tln "sport = :${candidate}" | grep -q .; then
        PANEL_PORT="$candidate"
        break
    fi
done
printf %s "$PANEL_PORT" | "${db[@]}" set PANEL_PORT

# 5. Запуск HTTPS Веб-панели управления через systemd + проверка /api/v1/health
info "5/5 — Запуск HTTPS Веб-панели управления (порт ${PANEL_PORT}/tcp)..."
cat > /etc/systemd/system/ligament-vault-ui.service <<EOF
[Unit]
Description=Ligament Vault HTTPS Web Control Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
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
elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -Eq '^-P INPUT DROP|-j DROP|-j REJECT'; then
    iptables -C INPUT -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null || true
fi

# Проверяем, что именно наша панель поднялась на выбранном порту
PANEL_OK=false
for _ in 1 2 3 4 5 6; do
    if curl -ksf --max-time 2 "https://127.0.0.1:${PANEL_PORT}/api/v1/health" 2>/dev/null | grep -Eq '"ok":[[:space:]]*true'; then
        PANEL_OK=true
        break
    fi
    sleep 1
done

if [[ "${PANEL_OK}" != "true" ]]; then
    journalctl -u ligament-vault-ui.service -n 25 --no-pager >&2 || true
    err "Веб-панель не ответила на https://127.0.0.1:${PANEL_PORT}/api/v1/health"
fi

info "Панель управления https://${PANEL_HOST}:${PANEL_PORT}"
info "Логин: $("${db[@]}" get SFTPGO_ADMIN_USERNAME). Для получения пароля: sudo ligactl config get PANEL_ADMIN_PASSWORD"
if [[ -n "${requested_nodes}" ]]; then "${INSTALL_DIR}/ligactl" install --yes; fi
