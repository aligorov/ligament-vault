#!/usr/bin/env bash
# ============================================================================
# secrets-manager.sh — Управление секретами Ligament Vault (age / Zero-Plaintext)
# ============================================================================
# Вызов: ./ligactl secrets <init|encrypt|decrypt|edit|status> [опции]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

ROOT_DIR="${CONFIG_ROOT:-${SCRIPT_DIR}}"
SECRETS_PLAIN="${ROOT_DIR}/secrets.env"
SECRETS_AGE="${ROOT_DIR}/secrets.env.age"
CA_KEY_PLAIN="${ROOT_DIR}/.pki/ca/ca.key"
CA_KEY_AGE="${ROOT_DIR}/.pki/ca/ca.key.age"

usage() {
    cat <<'EOF'
Использование: ./ligactl secrets <подкоманда> [опции]

Подкоманды:
  init [--no-encrypt] [--force]  Сгенерировать криптостойкие пароли/ключи из secrets.env.example
                                 (по умолчанию сразу шифрует в secrets.env.age при наличии age)
  encrypt                        Зашифровать secrets.env -> secrets.env.age (и ca.key -> ca.key.age)
                                 с безопасным удалением открытых файлов
  decrypt                        Расшифровать secrets.env.age -> secrets.env (chmod 600)
  edit                           Безопасно отредактировать secrets.env.age в RAM ($EDITOR)
  status                         Проверить статус шифрования секретов, ключа age и FIXME-полей
EOF
}

ensure_age_key() {
    local age_key
    age_key=$(resolve_age_key_file)
    if [[ -f "${age_key}" ]]; then
        echo "${age_key}"
        return 0
    fi
    if ! command -v age-keygen &>/dev/null; then
        log_error "Утилита 'age-keygen' не найдена. Установите пакет 'age' (brew install age / apt install age)."
        return 1
    fi
    mkdir -p "$(dirname "${age_key}")"
    chmod 700 "$(dirname "${age_key}")"
    age-keygen -o "${age_key}" >/dev/null 2>&1
    chmod 600 "${age_key}"
    log_info "Сгенерирован новый мастер-ключ age: ${age_key} (сохраните резервную копию в менеджере паролей!)"
    echo "${age_key}"
}

get_age_recipient() {
    local age_key="$1"
    age-keygen -y "${age_key}"
}

generate_populated_secrets() {
    local tpl_file="${SCRIPT_DIR}/secrets.env.example"
    python3 - "${tpl_file}" <<'PYEOF'
import secrets, string, sys

alphabet = string.ascii_letters + string.digits
text = open(sys.argv[1], "r", encoding="utf-8").read()

def rand_alnum(n=36):
    return "".join(secrets.choice(alphabet) for _ in range(n))

while "FIXME_GENERATE_32_BYTE_HEX" in text:
    text = text.replace("FIXME_GENERATE_32_BYTE_HEX", secrets.token_hex(32), 1)
while "FIXME_UNIQUE_CODE" in text:
    text = text.replace("FIXME_UNIQUE_CODE", secrets.token_hex(16), 1)
while "FIXME_GENERATE_PASSPHRASE" in text:
    text = text.replace("FIXME_GENERATE_PASSPHRASE", rand_alnum(44), 1)
while "FIXME_CA_PASSPHRASE" in text:
    text = text.replace("FIXME_CA_PASSPHRASE", rand_alnum(36), 1)
while "FIXME_GENERATE" in text:
    text = text.replace("FIXME_GENERATE", rand_alnum(32), 1)

sys.stdout.write(text)
PYEOF
}

cmd_init() {
    local no_encrypt=false force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-encrypt) no_encrypt=true; shift ;;
            --force)      force=true; shift ;;
            *)            log_error "Неизвестный флаг secrets init: $1"; usage; exit 1 ;;
        esac
    done

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Генерация криптостойких секретов в ${ROOT_DIR} (no_encrypt=${no_encrypt})"
        return 0
    fi

    if [[ "${force}" != "true" ]] && [[ -f "${SECRETS_PLAIN}" || -f "${SECRETS_AGE}" ]]; then
        log_error "Секреты уже существуют (${SECRETS_PLAIN} или ${SECRETS_AGE}). Добавьте --force для перегенерации."
        exit 1
    fi

    mkdir -p "${ROOT_DIR}"
    if [[ "${no_encrypt}" == "false" ]] && command -v age &>/dev/null && command -v age-keygen &>/dev/null; then
        local age_key recipient
        age_key=$(ensure_age_key)
        recipient=$(get_age_recipient "${age_key}")
        generate_populated_secrets | age -r "${recipient}" -o "${SECRETS_AGE}"
        chmod 600 "${SECRETS_AGE}"
        secure_wipe_file "${SECRETS_PLAIN}"
        log_info "✅ Секреты сгенерированы и сразу зашифрованы в ${SECRETS_AGE} (открытый файл не создавался на диске)"
        log_info "   Для заполнения внешних токенов (CF_DNS_API_TOKEN, BACKUP_S3_*) выполните: ./ligactl secrets edit"
    else
        if [[ "${no_encrypt}" == "false" ]]; then
            log_warn "Утилита 'age' не установлена — создаем локальный ${SECRETS_PLAIN} с правами 0600"
        fi
        umask 077
        generate_populated_secrets > "${SECRETS_PLAIN}"
        chmod 600 "${SECRETS_PLAIN}"
        log_info "✅ Секреты сгенерированы в ${SECRETS_PLAIN} (chmod 600)"
    fi
}

cmd_encrypt() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] age encrypt ${SECRETS_PLAIN} -> ${SECRETS_AGE} (и ${CA_KEY_PLAIN} -> ${CA_KEY_AGE})"
        return 0
    fi
    check_command age
    local age_key recipient encrypted_any=false
    age_key=$(ensure_age_key)
    recipient=$(get_age_recipient "${age_key}")

    if [[ -f "${SECRETS_PLAIN}" ]]; then
        age -r "${recipient}" -o "${SECRETS_AGE}" "${SECRETS_PLAIN}"
        chmod 600 "${SECRETS_AGE}"
        secure_wipe_file "${SECRETS_PLAIN}"
        log_info "✅ Зашифрован ${SECRETS_AGE} (открытый secrets.env удален)"
        encrypted_any=true
    fi

    if [[ -f "${CA_KEY_PLAIN}" ]]; then
        age -r "${recipient}" -o "${CA_KEY_AGE}" "${CA_KEY_PLAIN}"
        chmod 600 "${CA_KEY_AGE}"
        secure_wipe_file "${CA_KEY_PLAIN}"
        log_info "✅ Зашифрован приватный ключ Root CA: ${CA_KEY_AGE} (открытый ca.key удален)"
        encrypted_any=true
    fi

    if [[ "${encrypted_any}" == "false" ]]; then
        log_info "Открытые файлы секретов не найдены — шифровать нечего"
    fi
}

cmd_decrypt() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] age decrypt ${SECRETS_AGE} -> ${SECRETS_PLAIN}"
        return 0
    fi
    check_command age
    local age_key
    age_key=$(resolve_age_key_file)
    [[ -f "${age_key}" ]] || { log_error "Не найден ключ age: ${age_key}"; exit 1; }

    if [[ -f "${SECRETS_AGE}" ]]; then
        umask 077
        age -d -i "${age_key}" -o "${SECRETS_PLAIN}" "${SECRETS_AGE}"
        chmod 600 "${SECRETS_PLAIN}"
        log_warn "⚠️  Расшифрован ${SECRETS_PLAIN} на диск! После работы зашифруйте обратно: ./ligactl secrets encrypt"
    else
        log_error "Файл ${SECRETS_AGE} не найден"
        exit 1
    fi
}

cmd_edit() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Безопасное редактирование ${SECRETS_AGE} в RAM через \${EDITOR:-vi}"
        return 0
    fi
    check_command age
    local age_key recipient ram_dir tmp_file
    age_key=$(ensure_age_key)
    recipient=$(get_age_recipient "${age_key}")
    ram_dir=$(make_ram_tempdir)
    tmp_file="${ram_dir}/secrets.env"
    trap 'secure_wipe_file "${tmp_file:-}"; rm -rf "${ram_dir:-}"' EXIT

    if [[ -f "${SECRETS_AGE}" ]]; then
        age -d -i "${age_key}" -o "${tmp_file}" "${SECRETS_AGE}"
    elif [[ -f "${SECRETS_PLAIN}" ]]; then
        cp "${SECRETS_PLAIN}" "${tmp_file}"
    else
        generate_populated_secrets > "${tmp_file}"
    fi
    chmod 600 "${tmp_file}"

    "${EDITOR:-vi}" "${tmp_file}"
    bash -n "${tmp_file}" || {
        log_error "Синтаксическая ошибка в отредактированном secrets.env — изменения НЕ сохранены!"
        exit 1
    }

    age -r "${recipient}" -o "${SECRETS_AGE}" "${tmp_file}"
    chmod 600 "${SECRETS_AGE}"
    secure_wipe_file "${SECRETS_PLAIN}"
    log_info "✅ Изменения проверены и перешифрованы в ${SECRETS_AGE}"
}

cmd_status() {
    local age_key
    age_key=$(resolve_age_key_file)
    log_step "Статус секретов (${ROOT_DIR})"
    log_info "  Ключ age (${age_key}): $([[ -f "${age_key}" ]] && echo 'НАЙДЕН' || echo 'ОТСУТСТВУЕТ')"
    log_info "  secrets.env.age (RAM-encrypted): $([[ -f "${SECRETS_AGE}" ]] && echo 'АКТИВЕН ✅' || echo 'нет')"
    log_info "  secrets.env (plaintext на диске): $([[ -f "${SECRETS_PLAIN}" ]] && echo 'ЕСТЬ ⚠️ (рекомендуется ./ligactl secrets encrypt)' || echo 'нет (безопасно ✅)')"
    log_info "  Root CA ca.key.age:              $([[ -f "${CA_KEY_AGE}" ]] && echo 'ЗАШИФРОВАН ✅' || echo 'нет')"
    log_info "  Root CA ca.key (plaintext):      $([[ -f "${CA_KEY_PLAIN}" ]] && echo 'НА ДИСКЕ ⚠️' || echo 'нет')"

    if [[ "${DRY_RUN:-false}" != "true" ]] && has_secrets_configured; then
        load_cluster_env "${ROOT_DIR}"
        local fixmes=()
        for v in SFTPGO_ADMIN_PASSWORD SFTPGO_KMS_MASTER_KEY PG_SUPERUSER_PASSWORD PATRONI_API_PASSWORD SWFS_JWT_SIGNING_KEY CF_DNS_API_TOKEN BACKUP_S3_ACCESS_KEY; do
            if [[ "${!v:-FIXME}" == *FIXME* ]]; then
                fixmes+=("${v}")
            fi
        done
        if (( ${#fixmes[@]} > 0 )); then
            log_warn "  Незаполненные поля (FIXME): ${fixmes[*]}"
        else
            log_info "  ✅ Все ключевые секреты заполнены"
        fi
    fi
}

main() {
    local sub="${1:-status}"
    shift || true
    case "${sub}" in
        init)          cmd_init "$@" ;;
        encrypt)       cmd_encrypt "$@" ;;
        decrypt)       cmd_decrypt "$@" ;;
        edit)          cmd_edit "$@" ;;
        status)        cmd_status "$@" ;;
        --help|-h|help) usage ;;
        *)             log_error "Неизвестная подкоманда secrets: ${sub}"; usage; exit 1 ;;
    esac
}

main "$@"
