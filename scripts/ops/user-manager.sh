#!/usr/bin/env bash
# ============================================================================
# user-manager.sh — Управление клиентами, квотами и ключами SFTPGo (Day-2)
# ============================================================================
# Вызов: ./ligactl user <add|list|inspect|disable|enable|set-quota|rotate-key|disconnect>
#
# Особенность безопасности (Defense-in-Depth для WORM):
#   В профилях 'dual' и 'worm-only' папка '/worm' монтируется с правами SFTPGo
#   ["list","upload","download","create_dirs"] БЕЗ delete/overwrite/rename,
#   дополняя аппаратно-логическую блокировку S3 Object Lock COMPLIANCE!
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"

usage() {
    cat <<'EOF'
Использование: ./ligactl user <подкоманда> [опции]

Подкоманды:
  add          --username <name> [--profile dual|work-only|worm-only] [--quota-gb <N>]
               [--ssh-key <pubkey|@file>] [--password <pw>|--generate-password]
               [--allow-ip <cidr1,cidr2>] [--require-2fa]
  list         [--json]
  inspect      --username <name>
  disable      --username <name>
  enable       --username <name>
  set-quota    --username <name> --quota-gb <N>
  rotate-key   --username <name> --ssh-key <pubkey|@file>
  disconnect   --username <name>   (немедленный сброс активных сессий на всех нодах)
EOF
}

read_pubkey_arg() {
    local val="$1"
    if [[ "${val}" == @* ]]; then
        local path="${val#@}"
        [[ -f "${path}" ]] || { log_error "Файл публичного ключа не найден: ${path}"; exit 1; }
        cat "${path}"
    elif [[ -f "${val}" ]]; then
        cat "${val}"
    else
        echo "${val}"
    fi
}

cmd_add() {
    local uname="" profile="dual" quota_gb="0" ssh_key="" pw="" gen_pw=false allow_ips="" req_2fa="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --username)          uname="$2"; shift 2 ;;
            --profile)           profile="$2"; shift 2 ;;
            --quota-gb)          quota_gb="$2"; shift 2 ;;
            --ssh-key)           ssh_key="$(read_pubkey_arg "$2")"; shift 2 ;;
            --password)          pw="$2"; shift 2 ;;
            --generate-password) gen_pw=true; shift ;;
            --allow-ip)          allow_ips="$2"; shift 2 ;;
            --require-2fa)       req_2fa="true"; shift ;;
            *)                   log_error "Неизвестный флаг user add: $1"; usage; exit 1 ;;
        esac
    done

    [[ -n "${uname}" ]] || { log_error "Укажите --username"; exit 1; }
    if [[ ! "${uname}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Некорректное имя пользователя '${uname}' (разрешены a-zA-Z0-9._-)"
        exit 1
    fi
    if [[ "${profile}" != "dual" && "${profile}" != "work-only" && "${profile}" != "worm-only" ]]; then
        log_error "--profile должен быть dual, work-only или worm-only"
        exit 1
    fi

    if [[ "${gen_pw}" == "true" && -z "${pw}" ]]; then
        pw=$(python3 -c 'import secrets, string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')
    fi
    if [[ -z "${ssh_key}" && -z "${pw}" ]]; then
        log_error "Укажите хотя бы один метод входа: --ssh-key <pubkey|@file>, --password <pw> или --generate-password"
        exit 1
    fi

    local active_ip
    active_ip=$(resolve_current_active_ip)

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] SFTPGo API (${active_ip}): создание пользователя '${uname}' (profile=${profile}, quota=${quota_gb}GB, 2fa=${req_2fa})"
        return 0
    fi

    sftpgo_provision_s3_folders "${active_ip}"

    remote_exec_stdin "${active_ip}" \
        "${SFTPGO_ADMIN_USERNAME:-admin}" "${SFTPGO_ADMIN_PASSWORD}" \
        "${uname}" "${profile}" "${quota_gb}" "${ssh_key}" "${pw}" "${allow_ips}" "${req_2fa}" <<'REMOTE_USER_ADD'
set -euo pipefail
ADMIN_U="$1"; ADMIN_P="$2"; UNAME="$3"; PROFILE="$4"; QUOTA_GB="$5"
PUBKEY="$6"; USER_PW="$7"; ALLOW_IPS="$8"; REQ_2FA="$9"

python3 - "${ADMIN_U}" "${ADMIN_P}" "${UNAME}" "${PROFILE}" "${QUOTA_GB}" "${PUBKEY}" "${USER_PW}" "${ALLOW_IPS}" "${REQ_2FA}" <<'PYEOF'
import base64, json, sys, urllib.error, urllib.request

admin_u, admin_p, uname, profile, quota_gb, pubkey, user_pw, allow_ips, req_2fa = sys.argv[1:]
base = "http://127.0.0.1:8081/api/v2"

def api(method, path, body=None, headers=None):
    hdrs = {"Content-Type": "application/json", **(headers or {})}
    r = urllib.request.Request(
        f"{base}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        headers=hdrs,
        method=method,
    )
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

basic = base64.b64encode(f"{admin_u}:{admin_p}".encode()).decode()
st, tok = api("GET", "/token", headers={"Authorization": f"Basic {basic}"})
assert st == 200, f"SFTPGo auth failed: {st} {tok}"
auth = {"Authorization": f"Bearer {tok['access_token']}"}

vfolders = []
perms = {"/": ["list", "download"]}
if profile in ("dual", "work-only"):
    vfolders.append({"name": "sftp-work", "virtual_path": "/work"})
    perms["/work"] = ["*"]
if profile in ("dual", "worm-only"):
    vfolders.append({"name": "sftp-worm", "virtual_path": "/worm"})
    # Defense-in-depth: даже на уровне SFTPGo запрещены delete, rename и overwrite в /worm!
    perms["/worm"] = ["list", "upload", "download", "create_dirs"]

filters = {}
if allow_ips:
    filters["allowed_ip"] = [x.strip() for x in allow_ips.split(",") if x.strip()]
if req_2fa == "true":
    filters["totp_config"] = {"enabled": True, "config_name": "Default"}

payload = {
    "status": 1,
    "username": uname,
    "home_dir": f"/srv/sftpgo/data/{uname}",
    "quota_size": int(float(quota_gb) * (1024 ** 3)) if float(quota_gb) > 0 else 0,
    "permissions": perms,
    "virtual_folders": vfolders,
    "filters": filters,
}
if pubkey:
    payload["public_keys"] = [pubkey.strip()]
if user_pw:
    payload["password"] = user_pw

st_g, existing = api("GET", f"/users/{uname}", headers=auth)
if st_g == 200 and isinstance(existing, dict):
    st_w, res = api("PUT", f"/users/{uname}", body={**existing, **payload}, headers=auth)
    assert st_w in (200, 204), f"Failed updating user {uname}: {st_w} {res}"
    print(f"Updated SFTPGo user '{uname}' (profile={profile})")
else:
    st_c, res = api("POST", "/users", body=payload, headers=auth)
    assert st_c in (200, 201), f"Failed creating user {uname}: {st_c} {res}"
    print(f"Created SFTPGo user '{uname}' (profile={profile})")
PYEOF
REMOTE_USER_ADD

    log_info "✅ Пользователь '${uname}' готов (SFTP :${SFTP_PORT:-2022}, HTTPS https://${DOMAIN})"
    if [[ "${gen_pw}" == "true" ]]; then
        log_info "🔑 Сгенерированный пароль для '${uname}': ${pw}"
    fi
}

cmd_list() {
    local json_out=false
    [[ "${1:-}" == "--json" ]] && json_out=true
    local active_ip
    active_ip=$(resolve_current_active_ip)

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] SFTPGo API (${active_ip}): GET /api/v2/users"
        return 0
    fi

    remote_exec_stdin "${active_ip}" "${SFTPGO_ADMIN_USERNAME:-admin}" "${SFTPGO_ADMIN_PASSWORD}" "${json_out}" <<'REMOTE_LIST'
set -euo pipefail
ADMIN_U="$1"; ADMIN_P="$2"; JSON_OUT="$3"
python3 - "${ADMIN_U}" "${ADMIN_P}" "${JSON_OUT}" <<'PYEOF'
import base64, json, sys, urllib.request
u, p, jout = sys.argv[1:]
base = "http://127.0.0.1:8081/api/v2"
b64 = base64.b64encode(f"{u}:{p}".encode()).decode()
tok = json.loads(urllib.request.urlopen(urllib.request.Request(f"{base}/token", headers={"Authorization": f"Basic {b64}"}), timeout=10).read().decode())["access_token"]
users = json.loads(urllib.request.urlopen(urllib.request.Request(f"{base}/users?limit=500", headers={"Authorization": f"Bearer {tok}"}), timeout=10).read().decode())
if jout == "true":
    print(json.dumps(users, indent=2))
else:
    print(f"{'USERNAME':<22} {'STATUS':<10} {'QUOTA_GB':<12} {'USED_MB':<12} {'FOLDERS'}")
    print("-" * 78)
    for usr in users:
        st = "ENABLED" if usr.get("status") == 1 else "DISABLED"
        q_gb = round(usr.get("quota_size", 0) / (1024**3), 2) if usr.get("quota_size", 0) else "unlimited"
        u_mb = round(usr.get("used_quota_size", 0) / (1024**2), 2)
        vfs = ",".join(v.get("virtual_path", "") for v in usr.get("virtual_folders", []) or []) or "/"
        print(f"{usr.get('username',''):<22} {st:<10} {str(q_gb):<12} {str(u_mb):<12} {vfs}")
PYEOF
REMOTE_LIST
}

cmd_mutate_simple() {
    local action="$1"; shift
    local uname="" quota_gb="" ssh_key=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --username) uname="$2"; shift 2 ;;
            --quota-gb) quota_gb="$2"; shift 2 ;;
            --ssh-key)  ssh_key="$(read_pubkey_arg "$2")"; shift 2 ;;
            *)          log_error "Неизвестный аргумент ${action}: $1"; exit 1 ;;
        esac
    done
    [[ -n "${uname}" ]] || { log_error "Требуется --username"; exit 1; }

    local active_ip
    active_ip=$(resolve_current_active_ip)

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] SFTPGo API (${active_ip}): ${action} для '${uname}'"
        return 0
    fi

    if [[ "${action}" == "disconnect" ]]; then
        disconnect_cb() {
            local ip="$1"
            remote_exec_stdin "${ip}" "${SFTPGO_ADMIN_USERNAME:-admin}" "${SFTPGO_ADMIN_PASSWORD}" "${uname}" <<'REMOTE_DISC' || true
set -euo pipefail
ADMIN_U="$1"; ADMIN_P="$2"; UNAME="$3"
python3 - "${ADMIN_U}" "${ADMIN_P}" "${UNAME}" <<'PYEOF'
import base64, json, sys, urllib.parse, urllib.request
u, p, target = sys.argv[1:]
base = "http://127.0.0.1:8081/api/v2"
b64 = base64.b64encode(f"{u}:{p}".encode()).decode()
tok = json.loads(urllib.request.urlopen(urllib.request.Request(f"{base}/token", headers={"Authorization": f"Basic {b64}"}), timeout=10).read().decode())["access_token"]
hdr = {"Authorization": f"Bearer {tok}"}
conns = json.loads(urllib.request.urlopen(urllib.request.Request(f"{base}/connections", headers=hdr), timeout=10).read().decode())
killed = 0
for c in conns:
    if c.get("username") == target and c.get("connection_id"):
        cid = urllib.parse.quote(c["connection_id"], safe="")
        urllib.request.urlopen(urllib.request.Request(f"{base}/connections/{cid}", headers=hdr, method="DELETE"), timeout=10).read()
        killed += 1
print(f"Closed {killed} active session(s) for {target}")
PYEOF
REMOTE_DISC
        }
        for_each_node disconnect_cb
        log_info "✅ Активные сессии '${uname}' сброшены на всех узлах"
        return 0
    fi

    remote_exec_stdin "${active_ip}" "${SFTPGO_ADMIN_USERNAME:-admin}" "${SFTPGO_ADMIN_PASSWORD}" "${action}" "${uname}" "${quota_gb}" "${ssh_key}" <<'REMOTE_MUT'
set -euo pipefail
ADMIN_U="$1"; ADMIN_P="$2"; ACT="$3"; UNAME="$4"; QUOTA_GB="$5"; PUBKEY="$6"
python3 - "${ADMIN_U}" "${ADMIN_P}" "${ACT}" "${UNAME}" "${QUOTA_GB}" "${PUBKEY}" <<'PYEOF'
import base64, json, sys, urllib.request
u, p, act, uname, q_gb, pubkey = sys.argv[1:]
base = "http://127.0.0.1:8081/api/v2"
b64 = base64.b64encode(f"{u}:{p}".encode()).decode()
tok = json.loads(urllib.request.urlopen(urllib.request.Request(f"{base}/token", headers={"Authorization": f"Basic {b64}"}), timeout=10).read().decode())["access_token"]
hdr = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
usr = json.loads(urllib.request.urlopen(urllib.request.Request(f"{base}/users/{uname}", headers=hdr), timeout=10).read().decode())

if act == "inspect":
    usr.pop("password", None)
    print(json.dumps(usr, indent=2))
    sys.exit(0)
elif act == "disable":
    usr["status"] = 0
elif act == "enable":
    usr["status"] = 1
elif act == "set-quota":
    usr["quota_size"] = int(float(q_gb) * (1024 ** 3)) if float(q_gb) > 0 else 0
elif act == "rotate-key":
    usr["public_keys"] = [pubkey.strip()]

usr.pop("password", None)
urllib.request.urlopen(urllib.request.Request(f"{base}/users/{uname}", data=json.dumps(usr).encode(), headers=hdr, method="PUT"), timeout=10).read()
print(f"OK: {act} applied to user '{uname}'")
PYEOF
REMOTE_MUT

    # Сброс 10-минутного кэша на Standby-узлах через SIGHUP при блокировке
    if [[ "${action}" == "disable" ]]; then
        cmd_mutate_simple disconnect --username "${uname}"
    fi
}

main() {
    local sub="${1:-}"
    shift || true
    case "${sub}" in
        add)        cmd_add "$@" ;;
        list)       cmd_list "$@" ;;
        inspect|disable|enable|set-quota|rotate-key|disconnect)
            cmd_mutate_simple "${sub}" "$@"
            ;;
        ""|--help|-h|help) usage ;;
        *) log_error "Неизвестная подкоманда user: ${sub}"; usage; exit 1 ;;
    esac
}

main "$@"
