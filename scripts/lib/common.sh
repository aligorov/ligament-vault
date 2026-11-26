#!/usr/bin/env bash
# ============================================================================
# common.sh — Общая библиотека оркестратора Ligament Vault
# ============================================================================
# Предоставляет:
#   - Логирование с уровнями (log_info/warn/error/debug/step)
#   - Загрузку env + прозрачную расшифровку secrets.env.age в RAM (через age)
#   - Защищенную работу с ключом УЦ (ca.key / ca.key.age в RAM)
#   - Распределенную блокировку кластера (etcd CAS lease + локальный lock)
#   - Транзакционный журнал операций (.state/journal.jsonl) и --resume чекпоинты
#   - Безопасную SSH/SCP обертку и строгий Python-шаблонизатор
# ============================================================================

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# --- Цвета (безопасно при non-TTY) ---
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# --- Логирование ---
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_debug() { [[ "${VERBOSE:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $(date '+%H:%M:%S') $*" >&2 || true; }
log_step()  { echo -e "${CYAN}${BOLD}──── $* ────${NC}"; }

# --- Dry-run и подтверждения ---
run_or_dry() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

confirm_action() {
    local msg="${1:-Продолжить?}"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Auto-confirm: ${msg}"
        return 0
    fi
    if [[ "${AUTO_YES:-false}" == "true" ]]; then
        return 0
    fi
    echo -en "${YELLOW}${msg} [y/N]: ${NC}"
    read -r answer
    [[ "${answer}" =~ ^[Yy]$ ]]
}

# --- Поиск ключа age ---
resolve_age_key_file() {
    echo "${AGE_KEY_FILE:-${SOPS_AGE_KEY_FILE:-${HOME}/.config/ligament/age.key}}"
}

# --- Безопасная временная директория (в RAM /dev/shm на Linux, иначе mktemp) ---
make_ram_tempdir() {
    if [[ -d /dev/shm && -w /dev/shm ]]; then
        mktemp -d -p /dev/shm ligament.XXXXXXXXXX
    else
        mktemp -d "${TMPDIR:-/tmp}/ligament.XXXXXXXXXX"
    fi
}

secure_wipe_file() {
    local f="$1"
    [[ -f "${f}" ]] || return 0
    if command -v shred &>/dev/null; then
        shred -u "${f}" 2>/dev/null || rm -f "${f}"
    else
        rm -P "${f}" 2>/dev/null || rm -f "${f}"
    fi
}

# --- Автономная загрузка env (мульти-контур CONFIG_ROOT + age RAM decrypt) ---
load_cluster_env() {
    local root_dir="${CONFIG_ROOT:-${1:-${SCRIPT_DIR}}}"
    export CONFIG_ROOT="${root_dir}"

    local versions_file="${SCRIPT_DIR}/versions.env"
    [[ -f "${root_dir}/versions.env" ]] && versions_file="${root_dir}/versions.env"
    local env_file="${root_dir}/cluster.env"
    local secrets_file="${root_dir}/secrets.env"
    local secrets_age="${root_dir}/secrets.env.age"

    set -a
    # shellcheck disable=SC1090
    [[ -f "${versions_file}" ]] && source "${versions_file}"
    if [[ -z "${CLUSTER_NODES:-}" && -f "${env_file}" ]]; then
        # shellcheck disable=SC1090
        source "${env_file}"
    fi

    if [[ -f "${secrets_file}" ]]; then
        local perms
        perms=$(stat -c '%a' "${secrets_file}" 2>/dev/null || stat -f '%Lp' "${secrets_file}" 2>/dev/null || echo "600")
        if [[ "${perms}" != "600" ]]; then
            log_warn "secrets.env имеет права ${perms}, ожидается 600 (chmod 600 '${secrets_file}')"
        fi
        # shellcheck disable=SC1090
        source "${secrets_file}"
    elif [[ -f "${secrets_age}" ]]; then
        local age_key
        age_key=$(resolve_age_key_file)
        if ! command -v age &>/dev/null; then
            log_error "Найден ${secrets_age}, но утилита 'age' не установлена!"
            exit 1
        fi
        if [[ ! -f "${age_key}" ]]; then
            log_error "Ключ расшифровки age не найден: ${age_key} (задайте AGE_KEY_FILE)"
            exit 1
        fi
        local decrypted_env
        decrypted_env=$(age -d -i "${age_key}" "${secrets_age}")
        while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
            if [[ "${_k}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
                printf -v "${_k}" '%s' "${_v}"
                export "${_k}"
            fi
        done < <(printf '%s\n' "${decrypted_env}" | python3 -c '
import re, shlex, sys

def unescape_dq(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] in ("\\", "\"", "$", "`"):
            out.append(s[i + 1])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)

for raw in sys.stdin:
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
    if not m:
        continue
    k, rest = m.group(1), m.group(2).strip()
    if rest.startswith("\""):
        # Parse double-quoted value honoring bash escapes without executing commands
        buf, i, closed = [], 1, False
        while i < len(rest):
            c = rest[i]
            if c == "\\" and i + 1 < len(rest):
                buf.append(rest[i:i+2])
                i += 2
            elif c == "\"":
                closed = True
                break
            else:
                buf.append(c)
                i += 1
        val = unescape_dq("".join(buf)) if closed else rest.strip("\"")
    elif rest.startswith("\x27"):
        end = rest.find("\x27", 1)
        val = rest[1:end] if end != -1 else rest.strip("\x27")
    else:
        val = shlex.split(rest, comments=True)[0] if rest else ""
    sys.stdout.buffer.write(k.encode("utf-8") + b"\x00" + val.encode("utf-8") + b"\x00")
')
        unset decrypted_env _k _v
    fi

    export PROJECT_NAME="${PROJECT_NAME:-Ligament Vault}"
    export CLUSTER_SLUG="${CLUSTER_SLUG:-ligament-vault}"
    export REMOTE_BASE_DIR="${REMOTE_BASE_DIR:-/opt/${CLUSTER_SLUG}}"
    export ARBITER_BASE_DIR="${ARBITER_BASE_DIR:-/opt/${CLUSTER_SLUG}-arbiter}"
    set +a
}

has_secrets_configured() {
    local root_dir="${CONFIG_ROOT:-${SCRIPT_DIR}}"
    [[ -f "${root_dir}/secrets.env" || -f "${root_dir}/secrets.env.age" ]]
}

# --- Выполнение коллбэка с расшифрованным в RAM ca.key (поддержка ca.key.age) ---
# Использование: with_ca_key <ca_dir> <callback_fn> [args...]
# Внутри callback переменная ACTIVE_CA_KEY указывает на актуальный приватный ключ.
with_ca_key() {
    local ca_dir="$1"; shift
    local cb="$1"; shift

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        ACTIVE_CA_KEY="${ca_dir}/ca.key" "${cb}" "$@"
        return $?
    fi

    if [[ -f "${ca_dir}/ca.key" ]]; then
        ACTIVE_CA_KEY="${ca_dir}/ca.key" "${cb}" "$@"
        return $?
    fi

    if [[ -f "${ca_dir}/ca.key.age" ]]; then
        local age_key ram_dir tmp_key rc=0
        age_key=$(resolve_age_key_file)
        ram_dir=$(make_ram_tempdir)
        tmp_key="${ram_dir}/ca.key"
        age -d -i "${age_key}" -o "${tmp_key}" "${ca_dir}/ca.key.age"
        chmod 600 "${tmp_key}"
        ACTIVE_CA_KEY="${tmp_key}" "${cb}" "$@" || rc=$?
        secure_wipe_file "${tmp_key}"
        rm -rf "${ram_dir}"
        return "${rc}"
    fi

    log_error "Приватный ключ Root CA не найден ни в ${ca_dir}/ca.key, ни в ${ca_dir}/ca.key.age"
    return 1
}

# --- Парсинг CLUSTER_NODES ---
get_node_entries() {
    echo "${CLUSTER_NODES}" | xargs -n1
}

get_node_ips() {
    get_node_entries | cut -d: -f1
}

get_node_count() {
    get_node_entries | wc -l | tr -d ' '
}

get_node_ip() {
    get_node_entries | sed -n "${1}p" | cut -d: -f1
}

get_node_dc() {
    get_node_entries | sed -n "${1}p" | cut -d: -f2
}

get_node_name() {
    get_node_entries | sed -n "${1}p" | cut -d: -f3
}

find_node_by_name() {
    local target="$1"
    local count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        if [[ "$(get_node_name "$i")" == "${target}" ]]; then
            echo "$(get_node_ip "$i"):$(get_node_dc "$i"):$(get_node_name "$i"):$i"
            return 0
        fi
    done
    return 1
}

for_each_node() {
    local callback="$1"; shift
    local count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local ip dc name
        ip=$(get_node_ip "$i")
        dc=$(get_node_dc "$i")
        name=$(get_node_name "$i")
        "${callback}" "${ip}" "${dc}" "${name}" "$i" "$@"
    done
}

# --- SSH / SCP обертки (адаптированы под высокий WAN RTT до 250ms и кратковременные замирания VPS) ---
_ssh_base_opts() {
    local opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=25 -o ServerAliveInterval=15 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes -o BatchMode=yes"
    if [[ -n "${SSH_IDENTITY_FILE:-}" && -f "${SSH_IDENTITY_FILE}" ]]; then
        opts+=" -i ${SSH_IDENTITY_FILE}"
    fi
    echo "${opts}"
}

remote_exec() {
    local ip="$1"; shift
    local ssh_opts
    ssh_opts=$(_ssh_base_opts)
    if [[ -n "${ADMIN_SSH_PORT:-}" && "${ADMIN_SSH_PORT}" != "22" ]]; then
        ssh_opts+=" -p ${ADMIN_SSH_PORT}"
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        # shellcheck disable=SC2086
        run_or_dry ssh ${ssh_opts} "root@${ip}" "$@"
        return 0
    fi
    local attempt rc=0
    for attempt in 1 2 3; do
        rc=0
        # shellcheck disable=SC2086
        ssh ${ssh_opts} "root@${ip}" "$@" || rc=$?
        if (( rc != 255 )) || (( attempt == 3 )); then
            return "${rc}"
        fi
        log_warn "SSH-соединение с ${ip} прервалось (код 255, попытка ${attempt}/3) — повтор через 5с..."
        sleep 5
    done
    return "${rc}"
}

remote_exec_stdin() {
    local ip="$1"; shift
    local ssh_opts
    ssh_opts=$(_ssh_base_opts)
    if [[ -n "${ADMIN_SSH_PORT:-}" && "${ADMIN_SSH_PORT}" != "22" ]]; then
        ssh_opts+=" -p ${ADMIN_SSH_PORT}"
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        cat >/dev/null
        log_info "[DRY-RUN] ssh root@${ip} bash -s -- $*"
        return 0
    fi
    local tmp_in attempt rc=0
    tmp_in=$(mktemp)
    cat > "${tmp_in}"
    for attempt in 1 2 3; do
        rc=0
        # shellcheck disable=SC2086
        ssh ${ssh_opts} "root@${ip}" bash -s -- "$@" < "${tmp_in}" || rc=$?
        if (( rc != 255 )) || (( attempt == 3 )); then
            rm -f "${tmp_in}"
            return "${rc}"
        fi
        log_warn "SSH-соединение с ${ip} прервалось (код 255, попытка ${attempt}/3) — повтор через 5с..."
        sleep 5
    done
    rm -f "${tmp_in}"
    return "${rc}"
}

# Передача секретов удаленному скрипту через stdin (0600 в RAM), минуя argv / ps aux
remote_exec_env_stdin() {
    local ip="$1" env_csv="$2"; shift 2
    local ram_dir tmp_script
    ram_dir=$(make_ram_tempdir)
    chmod 700 "${ram_dir}"
    tmp_script="${ram_dir}/script.sh"
    : > "${tmp_script}"
    chmod 600 "${tmp_script}"

    local IFS=','
    local _vars=()
    read -ra _vars <<< "${env_csv}"
    for _vn in "${_vars[@]}"; do
        [[ "${_vn}" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        printf 'export %s=%q\n' "${_vn}" "${!_vn:-}" >> "${tmp_script}"
    done
    cat >> "${tmp_script}"

    local rc=0
    remote_exec_stdin "${ip}" "$@" < "${tmp_script}" || rc=$?
    secure_wipe_file "${tmp_script}"
    rm -rf "${ram_dir}"
    return "${rc}"
}

remote_copy() {
    local src="$1"
    local target="$2"
    local ip="${target%%:*}"
    local dst="${target#*:}"
    local scp_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=25 -o ServerAliveInterval=15 -o ServerAliveCountMax=6 -o BatchMode=yes"
    if [[ -n "${SSH_IDENTITY_FILE:-}" && -f "${SSH_IDENTITY_FILE}" ]]; then
        scp_opts+=" -i ${SSH_IDENTITY_FILE}"
    fi
    if [[ -n "${ADMIN_SSH_PORT:-}" && "${ADMIN_SSH_PORT}" != "22" ]]; then
        scp_opts+=" -P ${ADMIN_SSH_PORT}"
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        # shellcheck disable=SC2086
        run_or_dry scp ${scp_opts} "${src}" "root@${ip}:${dst}"
        return 0
    fi
    local attempt rc=0
    for attempt in 1 2 3; do
        rc=0
        # shellcheck disable=SC2086
        scp ${scp_opts} "${src}" "root@${ip}:${dst}" || rc=$?
        if (( rc == 0 )) || (( attempt == 3 )); then
            return "${rc}"
        fi
        log_warn "SCP на ${ip} не удался (код ${rc}, попытка ${attempt}/3) — повтор через 5с..."
        sleep 5
    done
    return "${rc}"
}

# --- Распределенная блокировка операций (локальный PID + etcd CAS lease) ---
OPS_LOCK_ACQUIRED=false
OPS_LOCK_ETCD_IP=""

acquire_ops_lock() {
    local op_name="${1:-operation}"
    if [[ "${OPS_LOCK_HELD_BY_PARENT:-false}" == "true" ]]; then
        return 0
    fi

    local state_dir="${CONFIG_ROOT:-${SCRIPT_DIR}}/.state"
    local lock_file="${state_dir}/ops.lock"
    mkdir -p "${state_dir}"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_debug "[DRY-RUN] acquire_ops_lock(${op_name})"
        export OPS_LOCK_HELD_BY_PARENT=true
        return 0
    fi

    if [[ -f "${lock_file}" ]]; then
        local old_pid old_info
        old_pid=$(awk -F'|' '{print $1}' "${lock_file}" 2>/dev/null || echo "")
        old_info=$(cat "${lock_file}" 2>/dev/null || echo "")
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            log_error "Операция заблокирована другим локальным процессом: ${old_info}"
            log_error "Дождитесь завершения или снимите блокировку: ./ligactl unlock --force"
            exit 1
        fi
        rm -f "${lock_file}"
    fi

    local operator_id
    operator_id="$(whoami)@$(hostname -s 2>/dev/null || hostname)"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "$$|${operator_id}|${op_name}|${ts}" > "${lock_file}"
    OPS_LOCK_ACQUIRED=true

    # Если кластер уже установлен — берем распределенную блокировку в etcd (CAS CreateRevision == 0)
    if [[ -f "${CONFIG_ROOT:-${SCRIPT_DIR}}/.cluster_installed" && "${CLUSTER_NODES:-FIXME}" != *FIXME* ]]; then
        local q_ip
        q_ip=$(get_node_ip 1)
        local payload="{\"operator\":\"${operator_id}\",\"op\":\"${op_name}\",\"ts\":\"${ts}\"}"
        local etcd_res
        etcd_res=$(remote_exec_stdin "${q_ip}" "${REMOTE_BASE_DIR}" "${ETCD_CLIENT_PORT:-2379}" "/${CLUSTER_SLUG}/ops-lock" "${payload}" <<'REMOTE_LOCK' 2>/dev/null || echo "ETCD_UNREACHABLE"
set -euo pipefail
BDIR="$1"; EC="$2"; LKEY="$3"; LVAL="$4"
CID=$(cd "${BDIR}" 2>/dev/null && docker compose ps -q etcd | head -n1 || true)
[[ -n "${CID}" ]] || CID=$(docker ps -qf "label=com.docker.compose.service=etcd" | head -n1)
[[ -n "${CID}" ]] || { echo "ETCD_UNREACHABLE"; exit 0; }
LID=$(docker exec "${CID}" etcdctl --endpoints="https://127.0.0.1:${EC}" \
    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
    lease grant 600 | awk '/lease/{print $2}')
OUT=$(docker exec -i "${CID}" etcdctl --endpoints="https://127.0.0.1:${EC}" \
    --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key txn <<TXN
create("${LKEY}") = "0"

put "${LKEY}" '${LVAL}' --lease=${LID}

get "${LKEY}"
TXN
)
if echo "${OUT}" | head -n1 | grep -qx "SUCCESS"; then
    echo "LOCKED"
else
    HOLDER=$(echo "${OUT}" | tail -n1)
    echo "BUSY:${HOLDER}"
fi
REMOTE_LOCK
        )
        if [[ "${etcd_res}" == BUSY:* ]]; then
            rm -f "${lock_file}"
            OPS_LOCK_ACQUIRED=false
            log_error "Кластер уже заблокирован другим оператором в etcd: ${etcd_res#BUSY:}"
            log_error "Для принудительного снятия используйте: ./ligactl unlock --force"
            exit 1
        elif [[ "${etcd_res}" == "LOCKED" ]]; then
            OPS_LOCK_ETCD_IP="${q_ip}"
        fi
    fi

    export OPS_LOCK_HELD_BY_PARENT=true
}

release_ops_lock() {
    if [[ "${OPS_LOCK_ACQUIRED:-false}" != "true" ]]; then
        return 0
    fi
    local state_dir="${CONFIG_ROOT:-${SCRIPT_DIR}}/.state"
    rm -f "${state_dir}/ops.lock"
    if [[ -n "${OPS_LOCK_ETCD_IP:-}" && "${DRY_RUN:-false}" != "true" ]]; then
        remote_exec "${OPS_LOCK_ETCD_IP}" "
            CID=\$(cd '${REMOTE_BASE_DIR}' 2>/dev/null && docker compose ps -q etcd | head -n1 || true)
            [[ -n \"\${CID}\" ]] && docker exec \"\${CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} \
                --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
                del '/${CLUSTER_SLUG}/ops-lock' >/dev/null 2>&1 || true
        " >/dev/null 2>&1 || true
    fi
    OPS_LOCK_ACQUIRED=false
}

force_unlock_ops() {
    local state_dir="${CONFIG_ROOT:-${SCRIPT_DIR}}/.state"
    rm -f "${state_dir}/ops.lock"
    if [[ "${DRY_RUN:-false}" != "true" && "${CLUSTER_NODES:-FIXME}" != *FIXME* ]]; then
        local q_ip
        q_ip=$(get_node_ip 1)
        remote_exec "${q_ip}" "
            CID=\$(cd '${REMOTE_BASE_DIR}' 2>/dev/null && docker compose ps -q etcd | head -n1 || true)
            [[ -n \"\${CID}\" ]] && docker exec \"\${CID}\" etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} \
                --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
                del '/${CLUSTER_SLUG}/ops-lock' >/dev/null 2>&1 || true
        " >/dev/null 2>&1 || true
    fi
    log_info "✅ Локальная и распределенная (etcd) блокировки сняты"
}

# --- Журнал транзакций (.state/journal.jsonl) и чекпоинты (--resume) ---
journal_append() {
    local op="$1" step="$2" status="$3"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    local state_dir="${CONFIG_ROOT:-${SCRIPT_DIR}}/.state"
    mkdir -p "${state_dir}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"ts":"%s","op":"%s","step":"%s","status":"%s"}\n' "${ts}" "${op}" "${step}" "${status}" >> "${state_dir}/journal.jsonl"
}

init_op_checkpoints() {
    local op="$1"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    local state_dir="${CONFIG_ROOT:-${SCRIPT_DIR}}/.state"
    mkdir -p "${state_dir}"
    local ck_file="${state_dir}/checkpoints.${op}"
    if [[ "${RESUME_OP:-false}" != "true" ]]; then
        : > "${ck_file}"
    fi
}

run_checkpoint() {
    local op="$1" step="$2"; shift 2
    local state_dir="${CONFIG_ROOT:-${SCRIPT_DIR}}/.state"
    local ck_file="${state_dir}/checkpoints.${op}"

    if [[ "${RESUME_OP:-false}" == "true" && -f "${ck_file}" ]] && grep -qx "${step}" "${ck_file}"; then
        log_info "⏭️  [RESUME] Шаг '${step}' (${op}) уже выполнен ранее — пропуск"
        return 0
    fi

    journal_append "${op}" "${step}" "started"
    if "$@"; then
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            mkdir -p "${state_dir}"
            echo "${step}" >> "${ck_file}"
        fi
        journal_append "${op}" "${step}" "completed"
        return 0
    else
        local rc=$?
        journal_append "${op}" "${step}" "failed:${rc}"
        log_error "Шаг '${step}' (${op}) завершился с ошибкой (код ${rc}). Для продолжения после починки добавьте --resume"
        return "${rc}"
    fi
}

clear_op_checkpoints() {
    local op="$1"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    rm -f "${CONFIG_ROOT:-${SCRIPT_DIR}}/.state/checkpoints.${op}"
}

# --- Резолвер образов ---
resolve_image_ref() {
    local image="$1"
    local digest="${2:-}"
    if [[ -n "${digest}" && "${digest}" == sha256:* && "${digest}" != *FIXME* ]]; then
        echo "${image}@${digest}"
    else
        echo "${image}"
    fi
}

# --- Строгий шаблонизатор ---
render_template() {
    local template="$1"
    local output="$2"
    mkdir -p "$(dirname "${output}")"

    python3 - "${template}" "${output}" <<'PYEOF'
import os, re, sys

tpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tpl_path, "r", encoding="utf-8") as f:
    content = f.read()

pattern = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
missing = []

def repl(match):
    name = match.group(1)
    if name in os.environ:
        return os.environ[name]
    missing.append(name)
    return match.group(0)

rendered = pattern.sub(repl, content)
if missing:
    uniq = ", ".join(sorted(set(missing)))
    sys.stderr.write(f"[ERROR] В шаблоне {tpl_path} не заданы переменные: {uniq}\n")
    sys.exit(1)

with open(out_path, "w", encoding="utf-8") as f:
    f.write(rendered)
PYEOF
    log_debug "Шаблон ${template} -> ${output}"
}

validate_json_file() {
    local file="$1"
    python3 -m json.tool "${file}" >/dev/null || {
        log_error "Невалидный JSON: ${file}"
        return 1
    }
}

validate_yaml_file() {
    local file="$1"
    python3 - "${file}" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
with open(sys.argv[1], "r", encoding="utf-8") as f:
    yaml.safe_load(f)
PYEOF
}

# --- API-хелперы ---
patroni_is_primary() {
    local ip="$1"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        [[ "${ip}" == "$(get_node_ip 1)" ]]
        return $?
    fi
    local code
    code=$(remote_exec "${ip}" "CA='${REMOTE_BASE_DIR}/certs/ca.crt'; if [[ -f \"\${CA}\" ]]; then curl -s --cacert \"\${CA}\" -o /dev/null -w '%{http_code}' 'https://127.0.0.1:${PATRONI_API_PORT:-8008}/primary' 2>/dev/null || curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:${PATRONI_API_PORT:-8008}/primary' 2>/dev/null; else curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:${PATRONI_API_PORT:-8008}/primary' 2>/dev/null; fi" 2>/dev/null || echo "000")
    [[ "${code}" == "200" ]]
}

find_patroni_primary_ip() {
    local count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local ip
        ip=$(get_node_ip "$i")
        if patroni_is_primary "${ip}"; then
            echo "${ip}"
            return 0
        fi
    done
    return 1
}

wait_for_remote_health() {
    local ip="$1" desc="$2" check_cmd="$3" attempts="${4:-30}" sleep_s="${5:-2}" diag_cmd="${6:-}"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] wait_for_remote_health(${ip}): ${desc}"
        return 0
    fi
    for i in $(seq 1 "${attempts}"); do
        if remote_exec "${ip}" "${check_cmd}" >/dev/null 2>&1; then
            log_debug "${ip}: ${desc} готов (попытка ${i}/${attempts})"
            return 0
        fi
        sleep "${sleep_s}"
    done
    log_error "${ip}: таймаут ожидания (${desc})"
    if [[ -n "${diag_cmd}" ]]; then
        log_warn "Последние логи сервиса на ${ip}:"
        remote_exec "${ip}" "${diag_cmd}" >&2 || true
    fi
    return 1
}

check_command() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        log_error "Команда '${cmd}' не найдена локально. Установите перед продолжением."
        return 1
    fi
}
