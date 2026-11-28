#!/usr/bin/env bash
# ============================================================================
# test-lab.sh — Локальная песочница из 3 Ubuntu VM (Lima / Multipass)
# ============================================================================
# Вызов: ./ligactl lab <up|down|status|verify> [--provider auto|lima|multipass] [--with-arbiter]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

LAB_DIR="${SCRIPT_DIR}/environments/lab"
LAB_KEY="${LAB_DIR}/id_ed25519_lab"
VM_PREFIX="lv"

usage() {
    cat <<'EOF'
Использование: ./ligactl lab <подкоманда> [опции]

Подкоманды:
  up [--provider auto|lima|multipass] [--with-arbiter] [--dns-zone lab.test]
         Создать VM и записать IPv4 или проверенные FQDN в environments/lab/control.sqlite3.
         Для своей DNS-зоны создать выведенные A-записи на локальном резолвере и повторить up.
  verify [--with-backup]  Установка, S3/WORM, статус; с флагом также полный внешний backup и проверка восстановления.
  status Показать состояние локальных VM стенда
  down   Удалить все локальные VM стенда и очистить environments/lab/
EOF
}

lab_guest() {
    local provider="$1" vm="$2"; shift 2
    if [[ "$provider" == multipass ]]; then multipass exec "$vm" -- "$@"; else limactl shell "$vm" "$@"; fi
}

detect_provider() {
    local req="${1:-auto}"
    if [[ "${req}" != "auto" ]]; then
        echo "${req}"
        return 0
    fi
    if command -v multipass &>/dev/null; then
        echo "multipass"
    elif command -v limactl &>/dev/null; then
        echo "lima"
    else
        echo "none"
    fi
}

cmd_up() {
    local provider="auto" with_arbiter=false zone=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider)     provider="$2"; shift 2 ;;
            --dns-zone)     zone="${2:?Укажите DNS-зону}"; shift 2 ;;
            --with-arbiter) with_arbiter=true; shift ;;
            *)              log_error "Неизвестный флаг lab up: $1"; usage; exit 1 ;;
        esac
    done

    case "$provider" in auto|multipass|lima) ;; *) log_error "Неизвестный VM-провайдер: $provider"; return 1 ;; esac
    if [[ -n "$zone" ]]; then
        python3 - "$SCRIPT_DIR/scripts/lib" "$zone" <<'VALID_ZONE'
import sys
sys.path.insert(0, sys.argv[1])
from node_address import valid_node_address
if not valid_node_address("arbiter." + sys.argv[2]) or sys.argv[2].replace(".", "").isdigit():
    sys.exit("Некорректная DNS-зона стенда")
VALID_ZONE
    fi

    local resolved
    resolved=$(detect_provider "${provider}")

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] lab up (provider=${resolved}, vms=${VM_PREFIX}-node1..3, arbiter=${with_arbiter}, DNS=${zone:-IPv4}) -> ${LAB_DIR}/control.sqlite3"
        return 0
    fi

    if [[ "${resolved}" == "none" ]]; then
        log_error "Не найден ни 'multipass', ни 'limactl'. Установите: brew install multipass (или brew install lima)"
        exit 1
    fi

    mkdir -p "${LAB_DIR}"
    if [[ ! -f "${LAB_KEY}" ]]; then
        ssh-keygen -t ed25519 -f "${LAB_KEY}" -N "" -C "ligament-lab" >/dev/null
        chmod 600 "${LAB_KEY}"
    fi
    local pubkey
    pubkey=$(cat "${LAB_KEY}.pub")

    local vms=("${VM_PREFIX}-node1" "${VM_PREFIX}-node2" "${VM_PREFIX}-node3")
    [[ "${with_arbiter}" == "true" ]] && vms+=("${VM_PREFIX}-arbiter")

    local cloud_init="${LAB_DIR}/cloud-init.yaml"
    cat > "${cloud_init}" <<EOF
#cloud-config
users:
  - name: root
    ssh_authorized_keys:
      - ${pubkey}
package_update: true
packages:
  - docker.io
  - docker-compose-v2
  - curl
  - jq
runcmd:
  - mkdir -p /data /root/.ssh
  - echo "${pubkey}" >> /root/.ssh/authorized_keys
  - chmod 600 /root/.ssh/authorized_keys
  - systemctl enable --now docker
EOF

    local node_entries=() records=() node_ips=() arbiter_ip="" idx=1 vm endpoint
    for vm in "${vms[@]}"; do
        log_info "Запуск VM ${vm} (${resolved})..."
        local ip=""
        if [[ "${resolved}" == "multipass" ]]; then
            multipass info "${vm}" >/dev/null 2>&1 || multipass launch 24.04 --name "${vm}" --cpus 2 --memory 3G --disk 25G --cloud-init "${cloud_init}"
            ip=$(multipass info "${vm}" --format json | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['${vm}']['ipv4'][0])")
        else
            limactl list -q | grep -qx "${vm}" || limactl start --name="${vm}" --cpus=2 --memory=3 --disk=25 --tty=false template://ubuntu-24.04
            limactl shell "${vm}" sudo bash -c "mkdir -p /data /root/.ssh && echo '${pubkey}' >> /root/.ssh/authorized_keys && apt-get update -qq && apt-get install -y -qq docker.io docker-compose-v2"
            ip=$(limactl shell "${vm}" hostname -I | awk '{print $1}')
        fi

        python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$ip"
        endpoint="$ip"
        if [[ -n "$zone" ]]; then
            endpoint="${vm#"$VM_PREFIX-"}.$zone"
            records+=("$endpoint=$ip")
        fi
        if [[ "${vm}" == "${VM_PREFIX}-arbiter" ]]; then
            arbiter_ip="$endpoint"
            lab_guest "$resolved" "$vm" sudo bash -ec '
                if [ "$(docker inspect --format "{{.Config.Image}} {{join .Args \" \"}}" lab-minio 2>/dev/null)" = "quay.io/minio/minio server /data/minio" ]; then
                    docker stop lab-minio >/dev/null
                    echo "Остановлен устаревший HTTP lab-minio. Его данные сохранены."
                fi'
        else
            node_ips+=("$ip")
            node_entries+=("${endpoint}:dc${idx}:node${idx}")
            idx=$((idx + 1))
        fi
    done

    local extra=()
    if [[ -n "$zone" ]]; then
        log_info "A-записи частной зоны:"
        printf '  %s\n' "${records[@]}"
        printf '  files.%s=%s (первоначальный edge)\n' "$zone" "${node_ips[0]}"
        local allowed
        allowed=$(IFS=,; echo "${node_ips[*]}")
        records+=("files.$zone=$allowed")
        local checker
        checker='import socket,sys
for record in sys.argv[1:]:
    name, expected = record.split("=")
    try:
        ips = {row[4][0] for row in socket.getaddrinfo(name, None, socket.AF_INET)}
    except OSError as err:
        sys.exit(f"{name}: {err}")
    if len(ips) != 1 or not ips.issubset(expected.split(",")):
        sys.exit(f"{name}: получено {ips}, ожидается {expected}")'
        python3 -c "$checker" "${records[@]}"
        for vm in "${vms[@]}"; do
            lab_guest "$resolved" "$vm" python3 -c "$checker" "${records[@]}"
        done
        extra+=(DOMAIN "files.$zone")
        local ssl_dir="$LAB_DIR/.ssl/certificates" domain="files.$zone"
        if [[ ! -e "$ssl_dir/$domain.crt" && ! -e "$ssl_dir/$domain.key" ]]; then
            mkdir -p "$ssl_dir"
            (umask 077
             openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 90 \
                 -keyout "$ssl_dir/$domain.key" -out "$ssl_dir/$domain.crt" -subj "/CN=$domain" \
                 -addext "subjectAltName=DNS:$domain" -addext "basicConstraints=critical,CA:FALSE")
            touch "$LAB_DIR/.ssl/.selfsigned"
        fi
        [[ -s "$ssl_dir/$domain.crt" && -s "$ssl_dir/$domain.key" ]] || { log_error "Неполная TLS-пара для $domain"; return 1; }
    fi
    export CONFIG_ROOT="${LAB_DIR}"
    config_db init
    config_db_set_many CLUSTER_NODES "${node_entries[*]}" MIN_FREE_DISK_GB 10 ARBITER_IP "${arbiter_ip}" SSH_IDENTITY_FILE "${LAB_KEY}" "${extra[@]+"${extra[@]}"}"
    log_info "Инвентарь VM сохранён. Для проверки сервисов запустите ./ligactl lab verify"
}

cmd_verify() {
    local with_backup=false
    if [[ "${1:-}" == --with-backup ]]; then with_backup=true; shift; fi
    (( $# == 0 )) || { usage; return 1; }
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] lab install, verify --sprint 1, внешний backup и проверка восстановления=$with_backup, status --strict"
        return 0
    fi
    if [[ "$with_backup" == true ]]; then
        load_cluster_env "$LAB_DIR"
        python3 - "$BACKUP_S3_ENDPOINT" <<'S3_DNS'
import ipaddress, sys
from urllib.parse import urlsplit
u = urlsplit(sys.argv[1])
if u.scheme != "https" or not u.hostname or u.username is not None or u.password is not None:
    sys.exit("Для резервной копии укажите HTTPS endpoint с DNS-именем в БД lab")
try:
    ipaddress.ip_address(u.hostname)
except ValueError:
    pass
else:
    sys.exit("Для endpoint S3 требуется DNS-имя")
S3_DNS
        if [[ -z "$BACKUP_S3_BUCKET" || -z "$BACKUP_S3_ACCESS_KEY" || "$BACKUP_S3_ACCESS_KEY" == *FIXME* || -z "$BACKUP_S3_SECRET_KEY" || "$BACKUP_S3_SECRET_KEY" == *FIXME* ]]; then
            log_error "Заполните BACKUP_S3_BUCKET и ключи отдельного тестового бакета в БД lab"; return 1
        fi
    fi
    bash "${SCRIPT_DIR}/ligactl" --env lab install --yes
    bash "${SCRIPT_DIR}/ligactl" --env lab verify --sprint 1
    if [[ "$with_backup" == true ]]; then
        bash "${SCRIPT_DIR}/ligactl" --env lab backup full
        bash "${SCRIPT_DIR}/ligactl" --env lab backup --verify
    fi
    bash "${SCRIPT_DIR}/ligactl" --env lab status --strict
}

cmd_status() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Проверка локальных VM (${VM_PREFIX}-node1..3)"
        return 0
    fi
    if command -v multipass &>/dev/null; then
        multipass list | grep -E "Name|${VM_PREFIX}-" || true
    elif command -v limactl &>/dev/null; then
        limactl list | grep -E "NAME|${VM_PREFIX}-" || true
    else
        log_warn "Гипервизор Lima/Multipass не установлен"
    fi
}

cmd_down() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Удаление VM ${VM_PREFIX}-node1..3, ${VM_PREFIX}-arbiter и ${LAB_DIR}"
        return 0
    fi
    confirm_action "Удалить все локальные VM стенда (${VM_PREFIX}-*) и каталог ${LAB_DIR}?" || exit 0
    for vm in "${VM_PREFIX}-node1" "${VM_PREFIX}-node2" "${VM_PREFIX}-node3" "${VM_PREFIX}-arbiter"; do
        if command -v multipass &>/dev/null; then
            multipass delete --purge "${vm}" >/dev/null 2>&1 || true
        fi
        if command -v limactl &>/dev/null; then
            limactl delete -f "${vm}" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "${LAB_DIR}"
    log_info "✅ Локальный стенд полностью очищен"
}

main() {
    local sub="${1:-status}"
    shift || true
    case "${sub}" in
        up)     cmd_up "$@" ;;
        verify) cmd_verify "$@" ;;
        status) cmd_status "$@" ;;
        down)   cmd_down "$@" ;;
        --help|-h|help) usage ;;
        *) log_error "Неизвестная подкоманда lab: ${sub}"; usage; exit 1 ;;
    esac
}

main "$@"
