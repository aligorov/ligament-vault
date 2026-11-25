#!/usr/bin/env bash
# ============================================================================
# test-lab.sh — Локальная песочница из 3 Ubuntu VM (Lima / Multipass) + MinIO
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
  up [--provider auto|lima|multipass] [--with-arbiter]
         Поднять 3 локальные Ubuntu 24.04 VM (+ опц. VM Арбитра с MinIO S3),
         установить Docker и сгенерировать готовое окружение environments/lab/
  verify Прогнать полный боевой цикл на lab-стенде (install -> verify --sprint 1 -> status --strict)
  status Показать состояние локальных VM стенда
  down   Удалить все локальные VM стенда и очистить environments/lab/
EOF
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
    local provider="auto" with_arbiter=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider)     provider="$2"; shift 2 ;;
            --with-arbiter) with_arbiter=true; shift ;;
            *)              log_error "Неизвестный флаг lab up: $1"; usage; exit 1 ;;
        esac
    done

    local resolved
    resolved=$(detect_provider "${provider}")

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] lab up (provider=${resolved}, vms=${VM_PREFIX}-node1..3, arbiter=${with_arbiter}) -> ${LAB_DIR}/cluster.env"
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

    local node_entries=() arbiter_ip="" idx=1
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

        if [[ "${vm}" == "${VM_PREFIX}-arbiter" ]]; then
            arbiter_ip="${ip}"
            ssh -o StrictHostKeyChecking=no -i "${LAB_KEY}" "root@${ip}" \
                "docker rm -f lab-minio >/dev/null 2>&1 || true; docker run -d --name lab-minio -p 9000:9000 -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadminsecret quay.io/minio/minio server /data/minio"
        else
            node_entries+=("${ip}:dc${idx}:node${idx}")
            idx=$((idx + 1))
        fi
    done

    local c_env
    c_env=$(cat "${SCRIPT_DIR}/cluster.env.example")
    c_env="${c_env/FIXME_IP1:dc1:node1 FIXME_IP2:dc2:node2 FIXME_IP3:dc3:node3/${node_entries[*]}}"
    c_env="${c_env/MIN_FREE_DISK_GB=80/MIN_FREE_DISK_GB=10}"
    c_env="${c_env/ARBITER_IP=\"\"/ARBITER_IP=\"${arbiter_ip}\"}"
    printf '%s\nSSH_IDENTITY_FILE="%s"\n' "${c_env}" "${LAB_KEY}" > "${LAB_DIR}/cluster.env"
    chmod 600 "${LAB_DIR}/cluster.env"

    CONFIG_ROOT="${LAB_DIR}" bash "${SCRIPT_DIR}/scripts/ops/secrets-manager.sh" init --force
    log_info "✅ Стенд готов! Запустите проверку: ./ligactl lab verify"
}

cmd_verify() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] ./ligactl --env lab install --yes && ./ligactl --env lab verify --sprint 1 && ./ligactl --env lab status --strict"
        return 0
    fi
    bash "${SCRIPT_DIR}/ligactl" --env lab install --yes
    bash "${SCRIPT_DIR}/ligactl" --env lab verify --sprint 1
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
