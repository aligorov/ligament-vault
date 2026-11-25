#!/usr/bin/env bash
# ============================================================================
# pki-rotate.sh — Мониторинг и бесшовная ротация внутренних mTLS-сертификатов
# ============================================================================
# Вызов:
#   ./ligactl pki status [--json]
#   ./ligactl pki rotate [--node <name>|--all] [--role <role>] [--dry-run] [--yes]
#
# Гарантии:
#   - Zero-Knowledge Remote-CSR: приватные ключи (.key.new) не покидают ноду
#   - Проверка совпадения публичного ключа и цепочки CA до атомарного mv
#   - PostgreSQL перечитывает сертификаты без обрыва соединений (pg_reload_conf)
#   - etcd и SeaweedFS перезапускают фолловеров по очереди до лидера (без потери кворума)
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
Использование: ./ligactl pki <status|rotate> [опции]

Подкоманды:
  status [--json]                             Проверить срок действия Root CA, SSL и всех mTLS сертификатов на нодах
  rotate [--node <name>|--all] [--role <r>]   Бесшовно перевыпустить mTLS-сертификаты без потери кворума
EOF
}

cert_days_local() {
    local path="$1"
    [[ -f "${path}" ]] || { echo "-1"; return 0; }
    python3 - "${path}" <<'PYEOF' 2>/dev/null || echo "-1"
import datetime, subprocess, sys
out = subprocess.check_output(["openssl", "x509", "-in", sys.argv[1], "-noout", "-enddate"], text=True).strip()
dt_str = out.split("=", 1)[1].replace(" GMT", "").strip()
exp = datetime.datetime.strptime(dt_str, "%b %d %H:%M:%S %Y").replace(tzinfo=datetime.timezone.utc)
print((exp - datetime.datetime.now(datetime.timezone.utc)).days)
PYEOF
}

cmd_status() {
    local json_out=false
    [[ "${1:-}" == "--json" ]] && json_out=true

    local sroot ca_days ssl_days
    sroot=$(state_root)
    ca_days=$(cert_days_local "${sroot}/.pki/ca/ca.crt")
    ssl_days=$(cert_days_local "${sroot}/.ssl/certificates/${DOMAIN}.crt")

    local node_items=()
    local count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local ip name min_days="825"
        ip=$(get_node_ip "$i"); name=$(get_node_name "$i")
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            min_days=$(remote_exec_stdin "${ip}" "${REMOTE_BASE_DIR}/certs/${name}" <<'REMOTE_PKI_CHECK' || echo "-1"
set -euo pipefail
CDIR="$1"
MIN_D=$(python3 - "${CDIR}" <<'PYEOF'
import datetime, glob, os, subprocess, sys
cdir = sys.argv[1]
days_list = []
for f in glob.glob(os.path.join(cdir, "*.crt")):
    if os.path.basename(f) == "ca.crt":
        continue
    out = subprocess.check_output(["openssl", "x509", "-in", f, "-noout", "-enddate"], text=True).strip()
    dt_str = out.split("=", 1)[1].replace(" GMT", "").strip()
    exp = datetime.datetime.strptime(dt_str, "%b %d %H:%M:%S %Y").replace(tzinfo=datetime.timezone.utc)
    days_list.append((exp - datetime.datetime.now(datetime.timezone.utc)).days)
print(min(days_list) if days_list else -1)
PYEOF
)
mkdir -p /var/lib/node_exporter/textfile_collector
printf 'ligament_pki_min_days_remaining %s\n' "${MIN_D}" > /var/lib/node_exporter/textfile_collector/ligament_pki.prom.tmp
mv /var/lib/node_exporter/textfile_collector/ligament_pki.prom.tmp /var/lib/node_exporter/textfile_collector/ligament_pki.prom
echo "${MIN_D}"
REMOTE_PKI_CHECK
            )
        fi
        node_items+=("{\"node\":\"${name}\",\"ip\":\"${ip}\",\"mtls_min_days\":${min_days}}")
        if [[ "${json_out}" != "true" ]]; then
            log_info "  Узел ${name} (${ip}): минимум до истечения mTLS = ${min_days} дн."
        fi
    done

    if [[ "${json_out}" == "true" ]]; then
        local joined
        joined=$(IFS=,; echo "${node_items[*]}")
        printf '{"root_ca_days":%s,"public_ssl_days":%s,"nodes":[%s]}\n' "${ca_days}" "${ssl_days}" "${joined}"
    else
        log_info "  Root CA: ${ca_days} дн. | Публичный SSL (${DOMAIN}): ${ssl_days} дн."
    fi
}

rotate_single_node_files() {
    local ip="$1" dc="$2" name="$3" idx="$4" filter_role="${5:-}"
    local sroot ca_dir node_cert_dir
    sroot=$(state_root)
    ca_dir="${sroot}/.pki/ca"
    node_cert_dir="${sroot}/certs/${name}"
    mkdir -p "${node_cert_dir}"
    ensure_ca_exists

    local san="IP:${ip},IP:127.0.0.1,DNS:${name},DNS:${name}.${CLUSTER_SLUG}.internal,DNS:localhost"
    local roles=("${PKI_ROLES[@]}")
    [[ -n "${filter_role}" ]] && roles=("${filter_role}")

    log_info "Перевыпуск Remote-CSR mTLS сертификатов на ${name} (${ip})..."
    for role in "${roles[@]}"; do
        remote_exec_stdin "${ip}" "${REMOTE_BASE_DIR}/certs/${name}" "${role}" <<'REMOTE_NEW_CSR'
set -euo pipefail
CERT_DIR="$1"; ROLE="$2"
mkdir -p "${CERT_DIR}"
openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/${ROLE}.key.new" 2>/dev/null
chmod 600 "${CERT_DIR}/${ROLE}.key.new"
openssl req -new -sha256 -key "${CERT_DIR}/${ROLE}.key.new" -out "/tmp/${ROLE}.csr" -subj "/CN=${ROLE}/O=Ligament"
REMOTE_NEW_CSR

        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            local scp_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
            [[ -n "${SSH_IDENTITY_FILE:-}" && -f "${SSH_IDENTITY_FILE}" ]] && scp_opts+=" -i ${SSH_IDENTITY_FILE}"
            [[ -n "${ADMIN_SSH_PORT:-}" && "${ADMIN_SSH_PORT}" != "22" ]] && scp_opts+=" -P ${ADMIN_SSH_PORT}"
            # shellcheck disable=SC2086
            scp ${scp_opts} "root@${ip}:/tmp/${role}.csr" "${node_cert_dir}/${role}.csr"
            with_ca_key "${ca_dir}" _sign_csr_with_active_ca "${ca_dir}" "${node_cert_dir}/${role}.csr" "${node_cert_dir}/${role}.crt" "${san}"
        else
            log_info "[DRY-RUN] Подпись и проверка нового сертификата ${name}/${role}"
        fi

        remote_copy "${node_cert_dir}/${role}.crt" "${ip}:${REMOTE_BASE_DIR}/certs/${name}/${role}.crt.new"
        remote_exec_stdin "${ip}" "${REMOTE_BASE_DIR}/certs/${name}" "${role}" <<'REMOTE_SWAP'
set -euo pipefail
CERT_DIR="$1"; ROLE="$2"
rm -f "/tmp/${ROLE}.csr"
PUB_K=$(openssl pkey -in "${CERT_DIR}/${ROLE}.key.new" -pubout 2>/dev/null)
PUB_C=$(openssl x509 -in "${CERT_DIR}/${ROLE}.crt.new" -pubkey -noout 2>/dev/null)
[[ "${PUB_K}" == "${PUB_C}" ]] || { echo "Key/Cert mismatch for ${ROLE}!" >&2; exit 1; }
openssl verify -CAfile "${CERT_DIR}/ca.crt" "${CERT_DIR}/${ROLE}.crt.new" >/dev/null
chmod 644 "${CERT_DIR}/${ROLE}.crt.new"
if [[ "${ROLE}" == swfs-* || "${ROLE}" == "pg-client" ]]; then
    chown 1000:1000 "${CERT_DIR}/${ROLE}.key.new"
fi
mv -f "${CERT_DIR}/${ROLE}.key.new" "${CERT_DIR}/${ROLE}.key"
mv -f "${CERT_DIR}/${ROLE}.crt.new" "${CERT_DIR}/${ROLE}.crt"
REMOTE_SWAP
    done

    # Горячая перезагрузка сертификатов PostgreSQL без рестарта СУБД!
    remote_exec "${ip}" "
        CID=\$(docker ps -qf name=patroni)
        if [[ -n \"\${CID}\" ]]; then
            docker exec \"\${CID}\" bash -c 'cp -L /certs/*.crt /certs/*.key /run/pg-certs/ && chown postgres:postgres /run/pg-certs/* && chmod 600 /run/pg-certs/*.key && chmod 644 /run/pg-certs/*.crt'
            docker exec -u postgres \"\${CID}\" psql -U postgres -c 'SELECT pg_reload_conf();' >/dev/null
        fi
    "
}

reload_rotated_node_services() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    log_info "Бесшовный перезапуск mTLS-клиентов/серверов на ${name} (${ip})..."
    if is_quorum_node "${idx}" "${name}"; then
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose restart etcd swfs-master"
        wait_for_remote_health "${ip}" "etcd ${name}" \
            "docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key endpoint health" 25 2
    fi
    remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose restart swfs-volume swfs-filer swfs-s3 swfs-worker"
    wait_for_remote_health "${ip}" "SWFS Filer ${name}" \
        "curl -sf http://127.0.0.1:${SWFS_FILER_PORT:-8888}/healthz || curl -sf http://127.0.0.1:${SWFS_FILER_METRICS_PORT:-9326}/metrics >/dev/null" 20 2
}

cmd_rotate() {
    local target_node="" rotate_all=false filter_role=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node) target_node="$2"; shift 2 ;;
            --all)  rotate_all=true; shift ;;
            --role) filter_role="$2"; shift 2 ;;
            *)      log_error "Неизвестный аргумент pki rotate: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${target_node}" && "${rotate_all}" != "true" ]]; then
        log_error "Укажите --node <name> или --all"
        exit 1
    fi

    confirm_action "Выполнить ротацию mTLS-сертификатов (${target_node:-ALL})?" || exit 0
    init_op_checkpoints "pki-rotate"

    local count
    count=$(get_node_count)
    for i in $(seq "${count}" -1 1); do
        local ip dc name
        ip=$(get_node_ip "$i"); dc=$(get_node_dc "$i"); name=$(get_node_name "$i")
        if [[ -n "${target_node}" && "${name}" != "${target_node}" ]]; then
            continue
        fi
        run_checkpoint "pki-rotate" "certs-${name}" rotate_single_node_files "${ip}" "${dc}" "${name}" "$i" "${filter_role}"
        run_checkpoint "pki-rotate" "reload-${name}" reload_rotated_node_services "${ip}" "${dc}" "${name}" "$i"
    done

    clear_op_checkpoints "pki-rotate"
    log_info "✅ Бесшовная ротация mTLS-сертификатов успешно завершена"
}

main() {
    local sub="${1:-status}"
    shift || true
    case "${sub}" in
        status) cmd_status "$@" ;;
        rotate) cmd_rotate "$@" ;;
        --help|-h|help) usage ;;
        *) log_error "Неизвестная подкоманда pki: ${sub}"; usage; exit 1 ;;
    esac
}

main "$@"
