#!/bin/sh
# ============================================================================
# ligament-2fa-hook.sh — SFTPGo pre_login_hook для интеграции с Ligament 2FA
# ============================================================================
# Вызывается внутри контейнера sftpgo перед входом пользователя.
# Переменные SFTPGo:
#   SFTPGO_LOGIND_USER     — JSON объекта пользователя
#   SFTPGO_LOGIND_IP       — IP клиента
#   SFTPGO_LOGIND_PROTOCOL — SSH | SFTP | FTP | HTTP | DAV | OIDC
#   SFTPGO_LOGIND_METHOD   — publickey | password | keyboard-interactive | ...
#
# Контракт SFTPGo pre_login_hook:
#   - Пустой stdout + exit 0 => вход разрешен без модификации профиля
#   - Ненулевой код возврата => вход немедленно отклонен
# ============================================================================

set -eu

ENV_FILE="/etc/sftpgo/hooks/ligament-2fa.env"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
fi

if [ "${LIGAMENT_2FA_ENABLED:-false}" != "true" ]; then
    exit 0
fi

# Извлекаем username из SFTPGO_LOGIND_USER без внешних зависимостей (jq/python)
USERNAME=$(printf '%s' "${SFTPGO_LOGIND_USER:-}" | sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
CLIENT_IP="${SFTPGO_LOGIND_IP:-unknown}"
PROTO="${SFTPGO_LOGIND_PROTOCOL:-unknown}"
METHOD="${SFTPGO_LOGIND_METHOD:-unknown}"
TIMEOUT="${LIGAMENT_2FA_TIMEOUT_SEC:-5}"
SERVICE="${CLUSTER_SLUG:-ligament-vault}"

if [ -z "${USERNAME}" ]; then
    echo "[ligament-2fa] empty username in SFTPGO_LOGIND_USER" >&2
    exit 1
fi

if [ -z "${LIGAMENT_2FA_API_URL:-}" ]; then
    echo "[ligament-2fa] LIGAMENT_2FA_API_URL is empty" >&2
    [ "${LIGAMENT_2FA_FAIL_OPEN:-false}" = "true" ] && exit 0 || exit 1
fi

json_escape() {
    printf '%s' "$1" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

E_USER=$(json_escape "${USERNAME}")
E_IP=$(json_escape "${CLIENT_IP}")
E_PROTO=$(json_escape "${PROTO}")
E_METHOD=$(json_escape "${METHOD}")
E_SVC=$(json_escape "${SERVICE}")

PAYLOAD=$(printf '{"username":"%s","ip":"%s","protocol":"%s","method":"%s","service":"%s"}' \
    "${E_USER}" "${E_IP}" "${E_PROTO}" "${E_METHOD}" "${E_SVC}")
TARGET_URL="${LIGAMENT_2FA_API_URL%/}/api/v1/verify-access"

HTTP_CODE="000"
RESP_BODY=""

if command -v curl >/dev/null 2>&1; then
    TMP_RESP=$(mktemp)
    trap 'rm -f "${TMP_RESP}"' EXIT
    HTTP_CODE=$(curl -sS --max-time "${TIMEOUT}" -o "${TMP_RESP}" -w '%{http_code}' \
        -X POST "${TARGET_URL}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${LIGAMENT_2FA_API_TOKEN:-}" \
        -d "${PAYLOAD}" 2>/dev/null || echo "000")
    [ -f "${TMP_RESP}" ] && RESP_BODY=$(cat "${TMP_RESP}")
elif command -v wget >/dev/null 2>&1; then
    if RESP_BODY=$(wget -q -T "${TIMEOUT}" -O - \
        --header="Content-Type: application/json" \
        --header="Authorization: Bearer ${LIGAMENT_2FA_API_TOKEN:-}" \
        --post-data="${PAYLOAD}" "${TARGET_URL}" 2>/dev/null); then
        HTTP_CODE="200"
    else
        HTTP_CODE="403"
    fi
else
    echo "[ligament-2fa] neither curl nor wget found in container" >&2
    [ "${LIGAMENT_2FA_FAIL_OPEN:-false}" = "true" ] && exit 0 || exit 1
fi

case "${HTTP_CODE}" in
    200|204)
        if printf '%s' "${RESP_BODY}" | grep -Eq '"locked"[[:space:]]*:[[:space:]]*true|"allowed"[[:space:]]*:[[:space:]]*false'; then
            echo "[ligament-2fa] DENY user=${USERNAME} ip=${CLIENT_IP} proto=${PROTO} (policy/lockout)" >&2
            exit 1
        fi
        if printf '%s' "${RESP_BODY}" | grep -Eq '"allowed"[[:space:]]*:[[:space:]]*true'; then
            exit 0
        fi
        echo "[ligament-2fa] DENY unexpected response (missing allowed=true) user=${USERNAME}" >&2
        exit 1
        ;;
    401|403|423|429)
        echo "[ligament-2fa] DENY user=${USERNAME} ip=${CLIENT_IP} proto=${PROTO} http=${HTTP_CODE}" >&2
        exit 1
        ;;
    *)
        echo "[ligament-2fa] UNREACHABLE http=${HTTP_CODE} user=${USERNAME} fail_open=${LIGAMENT_2FA_FAIL_OPEN:-false}" >&2
        if [ "${LIGAMENT_2FA_FAIL_OPEN:-false}" = "true" ]; then
            exit 0
        fi
        exit 1
        ;;
esac
