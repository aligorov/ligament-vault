#!/usr/bin/env bash
# ============================================================================
# deploy.sh — Функции деплоя, PKI, UFW, DNS/VIP и конфигов Ligament Vault
# ============================================================================

set -euo pipefail

state_root() {
    echo "${CONFIG_ROOT:-${SCRIPT_DIR}}"
}

ensure_quorum_nodes_initialized() {
    local qfile
    qfile="$(state_root)/.quorum_nodes"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    if [[ ! -s "${qfile}" ]]; then
        mkdir -p "$(dirname "${qfile}")"
        local count i
        count=$(get_node_count)
        for i in $(seq 1 "${count}"); do
            if (( i <= 3 )); then
                get_node_name "$i" >> "${qfile}"
            fi
        done
    fi
}

is_quorum_node() {
    local idx="$1"
    local name="$2"
    local qfile
    qfile="$(state_root)/.quorum_nodes"
    if [[ -s "${qfile}" ]]; then
        grep -qx "${name}" "${qfile}"
        return $?
    fi
    if (( idx <= 3 )); then
        return 0
    fi
    return 1
}

build_etcd_cluster_string() {
    local result="" count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local name ip
        name=$(get_node_name "$i")
        ip=$(get_node_ip "$i")
        if is_quorum_node "$i" "${name}"; then
            [[ -n "${result}" ]] && result+=","
            result+="etcd-${name}=https://${ip}:${ETCD_PEER_PORT:-2380}"
        fi
    done
    echo "${result}"
}

build_etcd_hosts() {
    local result="" count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local name ip
        name=$(get_node_name "$i")
        ip=$(get_node_ip "$i")
        if is_quorum_node "$i" "${name}"; then
            [[ -n "${result}" ]] && result+=","
            result+="${ip}:${ETCD_CLIENT_PORT:-2379}"
        fi
    done
    echo "${result}"
}

build_swfs_master_peers() {
    local result="" count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local name ip
        name=$(get_node_name "$i")
        ip=$(get_node_ip "$i")
        if is_quorum_node "$i" "${name}"; then
            [[ -n "${result}" ]] && result+=","
            result+="${ip}:${SWFS_MASTER_PORT:-9333}"
        fi
    done
    echo "${result}"
}

build_pg_hosts() {
    get_node_ips | paste -sd, -
}

build_pg_ports_csv() {
    local count
    count=$(get_node_count)
    python3 -c 'import sys; print(",".join([sys.argv[1]] * int(sys.argv[2])))' "${PG_PORT:-15432}" "${count}"
}

EXTRA_PEER_IPS="${EXTRA_PEER_IPS:-}"

get_all_peer_ips() {
    local extra_file
    extra_file="$(state_root)/.state/extra_peer_ips"
    {
        get_node_ips
        if [[ -n "${EXTRA_PEER_IPS:-}" ]]; then
            printf '%s\n' "${EXTRA_PEER_IPS}" | tr ' ' '\n'
        fi
        if [[ -f "${extra_file}" ]]; then
            cat "${extra_file}"
        fi
    } | awk 'NF && !seen[$0]++'
}

discover_extra_peer_ips() {
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    local count found=""
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local ip name ext_ip
        ip=$(get_node_ip "$i")
        name=$(get_node_name "$i")
        ext_ip=$(remote_exec "${ip}" "python3 - <<'PYIP' 2>/dev/null || true
import ipaddress, urllib.request
for url in ('https://api.ipify.org', 'https://ipv4.icanhazip.com'):
    try:
        raw = urllib.request.urlopen(url, timeout=3).read().decode().strip()
        addr = ipaddress.IPv4Address(raw)
        if addr.is_global:
            print(str(addr))
            break
    except Exception:
        pass
PYIP" 2>/dev/null | tail -n1 | tr -d '[:space:]' || true)
        if [[ "${ext_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! get_node_ips | grep -Fxq "${ext_ip}"; then
            log_info "  🌐 Обнаружен внешний NAT/egress IP узла ${name}: ${ext_ip} (добавлен в peer-allowlist)"
            found+="${found:+ }${ext_ip}"
        fi
    done
    EXTRA_PEER_IPS="${found}"
    export EXTRA_PEER_IPS
    mkdir -p "$(state_root)/.state"
    if [[ -n "${found}" ]]; then
        printf '%s\n' "${found}" | tr ' ' '\n' > "$(state_root)/.state/extra_peer_ips"
    else
        rm -f "$(state_root)/.state/extra_peer_ips"
    fi
}

build_haproxy_pg_servers() {
    local result="" count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local name ip
        name=$(get_node_name "$i")
        ip=$(get_node_ip "$i")
        result+="    server ${name} ${ip}:${PG_PORT:-15432} check port ${PATRONI_API_PORT:-8008} check-ssl verify required ca-file /certs/ca.crt"
        if (( i < count )); then
            result+=$'\n'
        fi
    done
    echo "${result}"
}

build_patroni_slots_yaml() {
    local result="" count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local name
        name=$(get_node_name "$i")
        result+="      ${name}:"$'\n'
        result+="        type: physical"
        if (( i < count )); then
            result+=$'\n'
        fi
    done
    echo "${result}"
}

build_pg_hba_peers_yaml() {
    local result="" ip
    while IFS= read -r ip; do
        [[ -z "${ip}" || "${ip}" == "127.0.0.1" || "${ip}" == "::1" ]] && continue
        [[ -n "${result}" ]] && result+=$'\n'
        result+="    - hostssl all all ${ip}/32 scram-sha-256 clientcert=verify-ca"$'\n'
        result+="    - hostssl replication replicator ${ip}/32 scram-sha-256 clientcert=verify-ca"
    done < <(get_all_peer_ips)
    echo "${result}"
}

resolve_current_active_ip() {
    local fallback
    fallback=$(get_node_ip 1)
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "${fallback}"
        return 0
    fi
    local resolved
    resolved=$(python3 - "${DOMAIN}" <<'PYEOF' 2>/dev/null || true
import socket, sys
try:
    print(socket.gethostbyname(sys.argv[1]))
except Exception:
    pass
PYEOF
    )
    local count
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        if [[ "$(get_node_ip "$i")" == "${resolved}" ]]; then
            echo "${resolved}"
            return 0
        fi
    done
    echo "${fallback}"
}

# --- Отказоустойчивое скачивание образов (Retry + GCR/Mirror.gcr.io fallback + P2P SSH transfer) ---
resolve_service_image_ref() {
    case "$1" in
        etcd)
            resolve_image_ref "${ETCD_IMAGE}" "${ETCD_DIGEST:-}"
            ;;
        patroni)
            resolve_image_ref "${PATRONI_PG_IMAGE}" "${PATRONI_PG_DIGEST:-}"
            ;;
        haproxy)
            resolve_image_ref "${HAPROXY_IMAGE}" "${HAPROXY_DIGEST:-}"
            ;;
        swfs-master|swfs-volume|swfs-filer|swfs-s3|swfs-admin|swfs-worker|swfs-backup)
            resolve_image_ref "${SEAWEEDFS_IMAGE}" "${SEAWEEDFS_DIGEST:-}"
            ;;
        sftpgo)
            resolve_image_ref "${SFTPGO_IMAGE}" "${SFTPGO_DIGEST:-}"
            ;;
        node-exporter)
            resolve_image_ref "${NODE_EXPORTER_IMAGE}" "${NODE_EXPORTER_DIGEST:-}"
            ;;
        prometheus)
            resolve_image_ref "${PROMETHEUS_IMAGE}" "${PROMETHEUS_DIGEST:-}"
            ;;
        alertmanager)
            resolve_image_ref "${ALERTMANAGER_IMAGE}" "${ALERTMANAGER_DIGEST:-}"
            ;;
        blackbox-exporter)
            resolve_image_ref "${BLACKBOX_EXPORTER_IMAGE}" "${BLACKBOX_EXPORTER_DIGEST:-}"
            ;;
        *)
            echo ""
            ;;
    esac
}

_image_mirror_candidates() {
    local ref="$1"
    echo "${ref}"
    # При явном @sha256 пининге не подменяем образ непроверенным тегом зеркала
    if [[ "${ref}" == *@sha256:* ]]; then
        return 0
    fi
    if [[ "${ref}" == quay.io/coreos/etcd:* ]]; then
        echo "gcr.io/etcd-development/etcd:${ref#quay.io/coreos/etcd:}"
    fi
    local first_seg="${ref%%/*}"
    if [[ "${ref}" != */* ]]; then
        echo "mirror.gcr.io/library/${ref}"
    elif [[ "${first_seg}" != *.* && "${first_seg}" != *:* && "${first_seg}" != "localhost" && "${first_seg}" != "local" ]]; then
        echo "mirror.gcr.io/${ref}"
    fi
}

_pull_image_with_mirrors_script() {
    cat <<'PULL_SCRIPT'
set -euo pipefail
TARGET="$1"; shift
if docker image inspect "${TARGET}" >/dev/null 2>&1; then
    exit 0
fi
LAST_ERR=""
for cand in "$@"; do
    for attempt in 1 2 3; do
        if ERR=$(docker pull "${cand}" 2>&1 >/dev/null); then
            if [[ "${cand}" != "${TARGET}" ]]; then
                docker tag "${cand}" "${TARGET}"
                echo "MIRROR_USED:${cand}"
            fi
            exit 0
        else
            LAST_ERR="${ERR}"
            if (( attempt < 3 )); then
                sleep $(( attempt * 2 ))
            fi
        fi
    done
done
echo "${LAST_ERR}" >&2
exit 1
PULL_SCRIPT
}

_pull_image_on_node() {
    local ip="$1" target_ref="$2"
    local candidates=()
    while IFS= read -r _c; do
        [[ -n "${_c}" ]] && candidates+=("${_c}")
    done < <(_image_mirror_candidates "${target_ref}")
    local out rc=0
    out=$(_pull_image_with_mirrors_script | remote_exec_stdin "${ip}" "${target_ref}" "${candidates[@]}" 2>&1) || rc=$?
    if (( rc == 0 )); then
        if [[ "${out}" == *"MIRROR_USED:"* ]]; then
            local used_mirror
            used_mirror=$(echo "${out}" | awk -F'MIRROR_USED:' '/MIRROR_USED:/{print $2; exit}')
            log_info "  🪞 Образ ${target_ref} загружен на ${ip} через официальное зеркало ${used_mirror}"
        fi
        return 0
    fi
    log_warn "  ⚠️  Прямой pull ${target_ref} на ${ip} завершился ошибкой: $(echo "${out}" | tail -n 3 | tr '\n' ' ')"
    return 1
}

ensure_remote_image() {
    local ip="$1" target_ref="$2"
    if [[ -z "${target_ref}" || "${target_ref}" == local/* || "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi

    if remote_exec "${ip}" "docker image inspect '${target_ref}' >/dev/null 2>&1" >/dev/null 2>&1; then
        return 0
    fi

    if _pull_image_on_node "${ip}" "${target_ref}"; then
        return 0
    fi

    # Fallback P2P: скачиваем с другой ноды кластера и передаем образ по SSH-потоку
    local peer_ip ssh_opts
    ssh_opts=$(_ssh_base_opts)
    if [[ -n "${ADMIN_SSH_PORT:-}" && "${ADMIN_SSH_PORT}" != "22" ]]; then
        ssh_opts+=" -p ${ADMIN_SSH_PORT}"
    fi
    while IFS= read -r peer_ip; do
        [[ -z "${peer_ip}" || "${peer_ip}" == "${ip}" ]] && continue
        if ! remote_exec "${peer_ip}" "docker image inspect '${target_ref}' >/dev/null 2>&1" >/dev/null 2>&1; then
            _pull_image_on_node "${peer_ip}" "${target_ref}" || continue
        fi
        log_warn "  🔄 Передаем образ ${target_ref} на ${ip} по защищенному SSH с узла ${peer_ip}..."
        # shellcheck disable=SC2086
        if ssh ${ssh_opts} "root@${peer_ip}" "docker save '${target_ref}' | gzip -1" \
            | ssh ${ssh_opts} "root@${ip}" "gunzip | docker load" >/dev/null 2>&1; then
            if remote_exec "${ip}" "docker image inspect '${target_ref}' >/dev/null 2>&1" >/dev/null 2>&1; then
                log_info "  ✅ Образ ${target_ref} доставлен на ${ip} с узла ${peer_ip}"
                return 0
            fi
        fi
    done < <(get_node_ips)

    log_error "Не удалось загрузить Docker-образ ${target_ref} на узел ${ip} (основной реестр, зеркала и P2P-копирование недоступны)"
    return 1
}

ensure_local_image() {
    local target_ref="$1"
    if [[ -z "${target_ref}" || "${target_ref}" == local/* || "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    if docker image inspect "${target_ref}" >/dev/null 2>&1; then
        return 0
    fi

    local candidates=()
    while IFS= read -r _c; do
        [[ -n "${_c}" ]] && candidates+=("${_c}")
    done < <(_image_mirror_candidates "${target_ref}")

    local out rc=0
    out=$(_pull_image_with_mirrors_script | bash -s -- "${target_ref}" "${candidates[@]}" 2>&1) || rc=$?
    if (( rc == 0 )); then
        if [[ "${out}" == *"MIRROR_USED:"* ]]; then
            local used_mirror
            used_mirror=$(echo "${out}" | awk -F'MIRROR_USED:' '/MIRROR_USED:/{print $2; exit}')
            log_info "  🪞 Образ ${target_ref} загружен локально через официальное зеркало ${used_mirror}"
        fi
        return 0
    fi

    # Fallback: передаем с первой доступной ноды кластера
    local peer_ip ssh_opts
    ssh_opts=$(_ssh_base_opts)
    if [[ -n "${ADMIN_SSH_PORT:-}" && "${ADMIN_SSH_PORT}" != "22" ]]; then
        ssh_opts+=" -p ${ADMIN_SSH_PORT}"
    fi
    while IFS= read -r peer_ip; do
        [[ -z "${peer_ip}" ]] && continue
        if ! remote_exec "${peer_ip}" "docker image inspect '${target_ref}' >/dev/null 2>&1" >/dev/null 2>&1; then
            _pull_image_on_node "${peer_ip}" "${target_ref}" || continue
        fi
        log_warn "  🔄 Загружаем ${target_ref} локально с узла ${peer_ip}..."
        # shellcheck disable=SC2086
        if ssh ${ssh_opts} "root@${peer_ip}" "docker save '${target_ref}' | gzip -1" | gunzip | docker load >/dev/null 2>&1; then
            if docker image inspect "${target_ref}" >/dev/null 2>&1; then
                return 0
            fi
        fi
    done < <(get_node_ips)

    log_error "Не удалось загрузить локальный Docker-образ ${target_ref}"
    return 1
}

remote_compose_up() {
    local ip="$1" up_flags="$2"; shift 2
    local services=("$@")
    local svc img_ref seen=" "
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d ${up_flags:+${up_flags} }${services[*]}"
        return 0
    fi
    for svc in "${services[@]}"; do
        img_ref=$(resolve_service_image_ref "${svc}")
        if [[ -n "${img_ref}" && "${seen}" != *" ${img_ref} "* ]]; then
            seen+="${img_ref} "
            ensure_remote_image "${ip}" "${img_ref}"
        fi
    done
    local attempt rc=0
    for attempt in 1 2 3; do
        rc=0
        remote_exec "${ip}" "cd '${REMOTE_BASE_DIR}' && docker compose up -d ${up_flags:+${up_flags} }${services[*]}" || rc=$?
        if (( rc == 0 )) || (( attempt == 3 )); then
            return "${rc}"
        fi
        log_warn "docker compose up (${services[*]}) на ${ip} завершился с кодом ${rc} — повтор через 3с..."
        sleep 3
    done
    return "${rc}"
}

export_node_render_vars() {
    local ip="$1" dc="$2" name="$3" idx="$4" etcd_state="${5:-new}"
    local admin_idx="${SWFS_ADMIN_NODE_INDEX:-2}"

    export CLUSTER_SLUG="${CLUSTER_SLUG:-ligament-vault}"
    export PROJECT_NAME="${PROJECT_NAME:-Ligament Vault}"
    export REMOTE_BASE_DIR="${REMOTE_BASE_DIR:-/opt/${CLUSTER_SLUG}}"
    export ARBITER_BASE_DIR="${ARBITER_BASE_DIR:-/opt/${CLUSTER_SLUG}-arbiter}"

    export NODE_IP="${ip}"
    export DC_NAME="${dc}"
    export NODE_NAME="${name}"
    export NODE_INDEX="${idx}"
    export ETCD_CLUSTER_STATE="${etcd_state}"

    export ETCD_DATA_DIR="${ETCD_DATA_DIR:-/data/etcd}"
    export SWFS_MASTER_DIR="${SWFS_MASTER_DIR:-/data/swfs-master}"
    export SFTPGO_DATA_DIR="${SFTPGO_DATA_DIR:-/data/sftpgo}"
    export SFTPGO_TEMP_PATH="${SFTPGO_TEMP_PATH:-/data/sftpgo-temp}"
    export ETCD_METRICS_PORT="${ETCD_METRICS_PORT:-2381}"
    export SFTPGO_TELEMETRY_PORT="${SFTPGO_TELEMETRY_PORT:-10000}"
    export HTTPS_PORT="${HTTPS_PORT:-443}"
    export PG_PORT="${PG_PORT:-15432}"
    export PATRONI_API_PORT="${PATRONI_API_PORT:-8008}"
    export HAPROXY_PG_PORT="${HAPROXY_PG_PORT:-5433}"
    export PG_MAX_SLOT_WAL_KEEP_SIZE="${PG_MAX_SLOT_WAL_KEEP_SIZE:-2GB}"

    if [[ -n "${ARBITER_IP:-}" ]]; then
        export SFTPGO_TELEMETRY_BIND="0.0.0.0"
    else
        export SFTPGO_TELEMETRY_BIND="127.0.0.1"
    fi

    if [[ "${LIGAMENT_2FA_ENABLED:-false}" == "true" ]]; then
        export SFTPGO_PRE_LOGIN_HOOK="/etc/sftpgo/hooks/ligament-2fa-hook.sh"
    else
        export SFTPGO_PRE_LOGIN_HOOK=""
    fi

    export ETCD_IMAGE_REF HAPROXY_IMAGE_REF PATRONI_PG_IMAGE_REF SEAWEEDFS_IMAGE_REF SFTPGO_IMAGE_REF NODE_EXPORTER_IMAGE_REF
    export PROMETHEUS_IMAGE_REF ALERTMANAGER_IMAGE_REF BLACKBOX_IMAGE_REF
    ETCD_IMAGE_REF=$(resolve_image_ref "${ETCD_IMAGE}" "${ETCD_DIGEST:-}")
    HAPROXY_IMAGE_REF=$(resolve_image_ref "${HAPROXY_IMAGE}" "${HAPROXY_DIGEST:-}")
    PATRONI_PG_IMAGE_REF=$(resolve_image_ref "${PATRONI_PG_IMAGE}" "${PATRONI_PG_DIGEST:-}")
    SEAWEEDFS_IMAGE_REF=$(resolve_image_ref "${SEAWEEDFS_IMAGE}" "${SEAWEEDFS_DIGEST:-}")
    SFTPGO_IMAGE_REF=$(resolve_image_ref "${SFTPGO_IMAGE}" "${SFTPGO_DIGEST:-}")
    NODE_EXPORTER_IMAGE_REF=$(resolve_image_ref "${NODE_EXPORTER_IMAGE}" "${NODE_EXPORTER_DIGEST:-}")
    PROMETHEUS_IMAGE_REF=$(resolve_image_ref "${PROMETHEUS_IMAGE}" "${PROMETHEUS_DIGEST:-}")
    ALERTMANAGER_IMAGE_REF=$(resolve_image_ref "${ALERTMANAGER_IMAGE}" "${ALERTMANAGER_DIGEST:-}")
    BLACKBOX_IMAGE_REF=$(resolve_image_ref "${BLACKBOX_EXPORTER_IMAGE}" "${BLACKBOX_EXPORTER_DIGEST:-}")

    export SFTPGO_ADMIN_USERNAME="${SFTPGO_ADMIN_USERNAME:-admin}"
    export ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-http://127.0.0.1:9099/alerts}"

    export SWFS_MASTER_GRPC_PORT=$(( ${SWFS_MASTER_PORT:-9333} + 10000 ))
    export SWFS_VOLUME_GRPC_PORT=$(( ${SWFS_VOLUME_PORT:-8082} + 10000 ))
    export SWFS_FILER_GRPC_PORT=$(( ${SWFS_FILER_PORT:-8888} + 10000 ))
    export SWFS_S3_METRICS_PORT=$(( ${SWFS_FILER_METRICS_PORT:-9326} + 1 ))
    export SWFS_ADMIN_IP
    SWFS_ADMIN_IP=$(get_node_ip "${admin_idx}")

    local vol_mounts="" vol_max=""
    IFS=',' read -ra _vol_dirs <<< "${SWFS_VOLUME_DIR}"
    for _vd in "${_vol_dirs[@]}"; do
        _vd="${_vd// /}"
        [[ -z "${_vd}" ]] && continue
        [[ -n "${vol_mounts}" ]] && vol_mounts+=$'\n'
        vol_mounts+="      - ${_vd}:${_vd}"
        [[ -n "${vol_max}" ]] && vol_max+=","
        vol_max+="${SWFS_VOLUME_MAX_PER_DIR:-64}"
    done
    export SWFS_VOLUME_MOUNTS="${vol_mounts}"
    export SWFS_VOLUME_MAX="${SWFS_VOLUME_MAX_OVERRIDE:-${vol_max}}"
    export SWFS_VOLUME_SIZE_LIMIT_MB="${SWFS_VOLUME_SIZE_LIMIT_MB:-128}"
    export SWFS_MIN_FREE_SPACE="${SWFS_MIN_FREE_SPACE:-128MiB}"

    if (( $(get_node_count) >= 3 && ${ETCD_ELECTION_TIMEOUT:-2500} <= 2500 )); then
        export ETCD_HEARTBEAT_INTERVAL=350
        export ETCD_ELECTION_TIMEOUT=3500
    fi

    export ETCD_INITIAL_CLUSTER ETCD_HOSTS ETCD_PATRONI_HOSTS ETCD_PATRONI_USE_PROXIES SWFS_MASTER_PEERS PG_HOSTS PG_PORTS_CSV HAPROXY_PG_SERVERS PATRONI_SLOTS_YAML PG_HBA_PEERS_YAML
    ETCD_INITIAL_CLUSTER=$(build_etcd_cluster_string)
    ETCD_HOSTS=$(build_etcd_hosts)
    if is_quorum_node "${idx}" "${name}"; then
        local self_ep="${ip}:${ETCD_CLIENT_PORT:-2379}"
        local other_eps
        other_eps=$(echo "${ETCD_HOSTS}" | tr ',' '\n' | grep -Fxv "${self_ep}" | paste -sd, - || true)
        if [[ -n "${other_eps}" ]]; then
            ETCD_PATRONI_HOSTS="${self_ep},${other_eps}"
        else
            ETCD_PATRONI_HOSTS="${self_ep}"
        fi
    else
        ETCD_PATRONI_HOSTS="${ETCD_HOSTS}"
    fi
    ETCD_PATRONI_USE_PROXIES="false"
    SWFS_MASTER_PEERS=$(build_swfs_master_peers)
    PG_HOSTS=$(build_pg_hosts)
    PG_PORTS_CSV=$(build_pg_ports_csv)
    HAPROXY_PG_SERVERS=$(build_haproxy_pg_servers)
    PATRONI_SLOTS_YAML=$(build_patroni_slots_yaml)
    PG_HBA_PEERS_YAML=$(build_pg_hba_peers_yaml)

    export BACKUP_S3_HOST
    BACKUP_S3_HOST="${BACKUP_S3_ENDPOINT#https://}"
    BACKUP_S3_HOST="${BACKUP_S3_HOST#http://}"
    BACKUP_S3_HOST="${BACKUP_S3_HOST%%/*}"

    if [[ -n "${BACKUP_S3_ACCESS_KEY:-}" && "${BACKUP_S3_ACCESS_KEY}" != *FIXME* ]]; then
        export PG_ARCHIVE_COMMAND="pgbackrest --stanza=${CLUSTER_SLUG} archive-push %p"
    else
        export PG_ARCHIVE_COMMAND="/bin/true"
    fi

    local profiles=()
    if is_quorum_node "${idx}" "${name}"; then
        profiles+=("quorum")
    fi
    if [[ "${idx}" == "${admin_idx}" ]]; then
        profiles+=("admin")
        if [[ -n "${BACKUP_S3_ACCESS_KEY:-}" && "${BACKUP_S3_ACCESS_KEY}" != *FIXME* ]]; then
            profiles+=("backup")
        fi
    fi
    export COMPOSE_PROFILES
    COMPOSE_PROFILES=$(IFS=,; echo "${profiles[*]}")
}

render_node_configs() {
    local ip="$1" dc="$2" name="$3" idx="$4" etcd_state="${5:-new}"
    export_node_render_vars "${ip}" "${dc}" "${name}" "${idx}" "${etcd_state}"

    local sroot out umask_saved
    sroot=$(state_root)
    out="${sroot}/.rendered/${name}"
    umask_saved=$(umask)
    umask 077
    mkdir -p "${sroot}/.rendered" "${out}/seaweedfs" "${out}/hooks"
    chmod 700 "${sroot}/.rendered" "${out}" "${out}/seaweedfs" "${out}/hooks"

    render_template "${SCRIPT_DIR}/docker-compose.yml.tpl" "${out}/docker-compose.yml"
    cat > "${out}/.env" <<EOF
COMPOSE_PROFILES=${COMPOSE_PROFILES}
EOF

    render_template "${SCRIPT_DIR}/configs/patroni.yml.tpl" "${out}/patroni.yml"
    render_template "${SCRIPT_DIR}/configs/haproxy-pg.cfg.tpl" "${out}/haproxy-pg.cfg"
    render_template "${SCRIPT_DIR}/configs/pgbackrest.conf.tpl" "${out}/pgbackrest.conf"

    render_template "${SCRIPT_DIR}/configs/seaweedfs/security.toml.tpl" "${out}/seaweedfs/security.toml"
    render_template "${SCRIPT_DIR}/configs/seaweedfs/master.toml.tpl" "${out}/seaweedfs/master.toml"
    render_template "${SCRIPT_DIR}/configs/seaweedfs/filer.toml.tpl" "${out}/seaweedfs/filer.toml"
    render_template "${SCRIPT_DIR}/configs/seaweedfs/replication.toml.tpl" "${out}/seaweedfs/replication.toml"
    render_template "${SCRIPT_DIR}/configs/seaweedfs/s3.json.tpl" "${out}/seaweedfs/s3.json"

    render_template "${SCRIPT_DIR}/configs/sftpgo.json.tpl" "${out}/sftpgo.json"
    if [[ ! -f "${sroot}/.pki/revoked_user_certs.json" ]]; then
        mkdir -p "${sroot}/.pki"
        echo "[]" > "${sroot}/.pki/revoked_user_certs.json"
    fi
    cp "${sroot}/.pki/revoked_user_certs.json" "${out}/revoked_user_certs.json"

    # Хук интеграции Ligament 2FA + изолированный env
    if [[ -f "${SCRIPT_DIR}/scripts/hooks/ligament-2fa-hook.sh" ]]; then
        cp "${SCRIPT_DIR}/scripts/hooks/ligament-2fa-hook.sh" "${out}/hooks/ligament-2fa-hook.sh"
        chmod 755 "${out}/hooks/ligament-2fa-hook.sh"
    fi
    cat > "${out}/hooks/ligament-2fa.env" <<EOF
LIGAMENT_2FA_ENABLED="${LIGAMENT_2FA_ENABLED:-false}"
LIGAMENT_2FA_API_URL="${LIGAMENT_2FA_API_URL:-}"
LIGAMENT_2FA_API_TOKEN="${LIGAMENT_2FA_API_TOKEN:-}"
LIGAMENT_2FA_TIMEOUT_SEC="${LIGAMENT_2FA_TIMEOUT_SEC:-5}"
LIGAMENT_2FA_FAIL_OPEN="${LIGAMENT_2FA_FAIL_OPEN:-false}"
CLUSTER_SLUG="${CLUSTER_SLUG}"
EOF
    chmod 600 "${out}/hooks/ligament-2fa.env"
    umask "${umask_saved}"

    validate_json_file "${out}/sftpgo.json"
    validate_json_file "${out}/seaweedfs/s3.json"
    validate_json_file "${out}/revoked_user_certs.json"
    validate_yaml_file "${out}/docker-compose.yml"
    validate_yaml_file "${out}/patroni.yml"
    python3 - "${out}/haproxy-pg.cfg" <<'PYHAP'
import sys
sec = None
for idx, raw in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    kw = line.split()[0]
    if kw in ("global", "defaults", "frontend", "backend", "listen"):
        sec = kw
    elif sec is None:
        raise SystemExit(f"Невалидный {sys.argv[1]}:{idx}: директива '{kw}' вне секции HAProxy")
PYHAP

    log_debug "Конфиги для ${name} отрендерены и провалидированы в ${out}"
}

push_node_configs() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    local out
    out="$(state_root)/.rendered/${name}"
    local all_vol_dirs
    all_vol_dirs=$(echo "${SWFS_VOLUME_DIR}" | tr ',' ' ')

    remote_exec_stdin "${ip}" \
        "${REMOTE_BASE_DIR}" \
        "${SFTPGO_TEMP_PATH:-/data/sftpgo-temp}" \
        "${SFTPGO_DATA_DIR:-/data/sftpgo}" \
        "${PG_DATA_DIR}" \
        "${ETCD_DATA_DIR:-/data/etcd}" \
        "${SWFS_MASTER_DIR:-/data/swfs-master}" \
        "${all_vol_dirs}" <<'REMOTE_DIRS'
set -euo pipefail
BASE_DIR="$1"; SFTP_TMP="$2"; SFTP_DATA="$3"; PG_DIR="$4"; ETCD_DIR="$5"; SWFS_MDIR="$6"; VOL_DIRS="$7"
mkdir -p "${BASE_DIR}/configs/seaweedfs" "${BASE_DIR}/certs/ssl" "${BASE_DIR}/ssh-host-keys" "${BASE_DIR}/hooks" \
         /var/lib/node_exporter/textfile_collector \
         "${SFTP_TMP}" "${SFTP_DATA}/data" "${SFTP_DATA}/empty-root" "${SFTP_DATA}/backups" "${PG_DIR}" "${ETCD_DIR}" "${SWFS_MDIR}"
for vd in ${VOL_DIRS}; do
    mkdir -p "${vd}"
    chown -R 1000:1000 "${vd}"
done
chmod 755 "${BASE_DIR}" "${BASE_DIR}/configs" "${BASE_DIR}/configs/seaweedfs" \
          "${BASE_DIR}/certs" "${BASE_DIR}/certs/ssl" "${BASE_DIR}/ssh-host-keys" "${BASE_DIR}/hooks"
chown -R 1000:1000 "${SFTP_TMP}" "${SFTP_DATA}" "${SWFS_MDIR}" "${BASE_DIR}/hooks"
chmod 555 "${SFTP_DATA}/empty-root"
chmod 700 "${ETCD_DIR}"
chmod 750 "${SWFS_MDIR}"
REMOTE_DIRS

    remote_copy "${out}/docker-compose.yml" "${ip}:${REMOTE_BASE_DIR}/docker-compose.yml"
    remote_copy "${out}/.env" "${ip}:${REMOTE_BASE_DIR}/.env"
    remote_copy "${out}/patroni.yml" "${ip}:${REMOTE_BASE_DIR}/configs/patroni.yml"
    remote_copy "${out}/haproxy-pg.cfg" "${ip}:${REMOTE_BASE_DIR}/configs/haproxy-pg.cfg"
    remote_copy "${out}/pgbackrest.conf" "${ip}:${REMOTE_BASE_DIR}/configs/pgbackrest.conf"
    remote_copy "${out}/sftpgo.json" "${ip}:${REMOTE_BASE_DIR}/configs/sftpgo.json"
    remote_copy "${out}/revoked_user_certs.json" "${ip}:${REMOTE_BASE_DIR}/configs/revoked_user_certs.json"
    remote_copy "${out}/seaweedfs/security.toml" "${ip}:${REMOTE_BASE_DIR}/configs/seaweedfs/security.toml"
    remote_copy "${out}/seaweedfs/master.toml" "${ip}:${REMOTE_BASE_DIR}/configs/seaweedfs/master.toml"
    remote_copy "${out}/seaweedfs/filer.toml" "${ip}:${REMOTE_BASE_DIR}/configs/seaweedfs/filer.toml"
    remote_copy "${out}/seaweedfs/replication.toml" "${ip}:${REMOTE_BASE_DIR}/configs/seaweedfs/replication.toml"
    remote_copy "${out}/seaweedfs/s3.json" "${ip}:${REMOTE_BASE_DIR}/configs/seaweedfs/s3.json"
    if [[ -f "${out}/hooks/ligament-2fa-hook.sh" ]]; then
        remote_copy "${out}/hooks/ligament-2fa-hook.sh" "${ip}:${REMOTE_BASE_DIR}/hooks/ligament-2fa-hook.sh"
    fi
    remote_copy "${out}/hooks/ligament-2fa.env" "${ip}:${REMOTE_BASE_DIR}/hooks/ligament-2fa.env"
    if [[ -f "$(state_root)/.pki/ca/ca.crt" ]] && [[ ! -f "$(state_root)/.pki/ca/crl.pem" ]] && [[ "${DRY_RUN:-false}" != "true" ]]; then
        ensure_ca_exists
    fi
    if [[ -f "$(state_root)/.pki/ca/ca.crt" ]]; then
        remote_copy "$(state_root)/.pki/ca/ca.crt" "${ip}:${REMOTE_BASE_DIR}/certs/ca.crt"
    fi
    if [[ -f "$(state_root)/.pki/ca/crl.pem" ]]; then
        remote_copy "$(state_root)/.pki/ca/crl.pem" "${ip}:${REMOTE_BASE_DIR}/certs/${name}/crl.pem"
        remote_copy "$(state_root)/.pki/ca/crl.pem" "${ip}:${REMOTE_BASE_DIR}/certs/${name}/ca-crl.crt"
    fi

    remote_exec "${ip}" "
        chmod 755 '${REMOTE_BASE_DIR}' '${REMOTE_BASE_DIR}/configs' '${REMOTE_BASE_DIR}/configs/seaweedfs' \
                  '${REMOTE_BASE_DIR}/certs' '${REMOTE_BASE_DIR}/certs/ssl' '${REMOTE_BASE_DIR}/ssh-host-keys' '${REMOTE_BASE_DIR}/hooks' && \
        chmod 600 '${REMOTE_BASE_DIR}/docker-compose.yml' '${REMOTE_BASE_DIR}/configs/patroni.yml' '${REMOTE_BASE_DIR}/configs/pgbackrest.conf' && \
        chown 999:999 '${REMOTE_BASE_DIR}/configs/pgbackrest.conf' && \
        chmod 644 '${REMOTE_BASE_DIR}/configs/haproxy-pg.cfg' && \
        chmod 644 '${REMOTE_BASE_DIR}/certs/ca.crt' '${REMOTE_BASE_DIR}/certs/${name}/crl.pem' '${REMOTE_BASE_DIR}/certs/${name}/ca-crl.crt' 2>/dev/null || true && \
        chown 1000:1000 '${REMOTE_BASE_DIR}/configs/seaweedfs/'*.toml '${REMOTE_BASE_DIR}/configs/seaweedfs/s3.json' && \
        chmod 600 '${REMOTE_BASE_DIR}/configs/seaweedfs/'*.toml '${REMOTE_BASE_DIR}/configs/seaweedfs/s3.json' && \
        chown 1000:1000 '${REMOTE_BASE_DIR}/configs/sftpgo.json' '${REMOTE_BASE_DIR}/configs/revoked_user_certs.json' \
                        '${REMOTE_BASE_DIR}/hooks/ligament-2fa.env' && \
        chmod 600 '${REMOTE_BASE_DIR}/configs/sftpgo.json' '${REMOTE_BASE_DIR}/hooks/ligament-2fa.env' && \
        chmod 644 '${REMOTE_BASE_DIR}/configs/revoked_user_certs.json' && \
        chmod 755 '${REMOTE_BASE_DIR}/hooks/ligament-2fa-hook.sh' 2>/dev/null || true
        if [[ -d '${REMOTE_BASE_DIR}/certs/${name}' ]]; then
            chmod 755 '${REMOTE_BASE_DIR}/certs/${name}'
            for kf in '${REMOTE_BASE_DIR}/certs/${name}'/*.key; do
                [[ -f \"\${kf}\" ]] || continue
                if grep -q 'BEGIN EC PARAMETERS' \"\${kf}\"; then
                    openssl pkey -in \"\${kf}\" -out \"\${kf}.pk8\" 2>/dev/null && mv -f \"\${kf}.pk8\" \"\${kf}\"
                fi
                chmod 600 \"\${kf}\"
            done
            chown 1000:1000 '${REMOTE_BASE_DIR}/certs/${name}'/swfs-*.key '${REMOTE_BASE_DIR}/certs/${name}/pg-client.key' 2>/dev/null || true
        fi
        PCID=\$(cd '${REMOTE_BASE_DIR}' 2>/dev/null && docker compose ps -q patroni 2>/dev/null | head -n1 || true)
        if [[ -n \"\${PCID}\" ]]; then
            docker exec \"\${PCID}\" bash -c 'if [[ -f /etc/patroni/patroni.yml ]]; then cp -L /certs/ca-crl.crt /run/pg-certs/ca-crl.crt 2>/dev/null || true; cp -L /etc/patroni/patroni.yml /run/pg-certs/patroni.yml && chown postgres:postgres /run/pg-certs/patroni.yml /run/pg-certs/ca-crl.crt 2>/dev/null || true && chmod 600 /run/pg-certs/patroni.yml && kill -HUP 1; fi' 2>/dev/null || true
        fi
    "
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        for _sf in "${out}/docker-compose.yml" "${out}/patroni.yml" "${out}/pgbackrest.conf" "${out}/sftpgo.json" "${out}/hooks/ligament-2fa.env" "${out}/seaweedfs/"*.toml "${out}/seaweedfs/s3.json"; do
            secure_wipe_file "${_sf}" 2>/dev/null || true
        done
    fi
}

# --- Бесшовное обновление UFW без отключения файрвола на живом кластере + 120s Dead-Man's Switch ---
harden_node_ufw() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    local peer_ips
    peer_ips=$(get_all_peer_ips | tr '\n' ' ')

    log_info "Синхронизация UFW на ${name} (${ip}) с внешним 120s Dead-Man's Switch..."
    remote_exec_stdin "${ip}" \
        "${CLUSTER_SLUG}" \
        "${ADMIN_SSH_NET}" "${ADMIN_SSH_PORT:-22}" \
        "${SFTP_PORT:-2022}" "${FTPS_PORT:-21}" "${FTPS_PASV_MIN:-50000}" "${FTPS_PASV_MAX:-50199}" \
        "${ETCD_CLIENT_PORT:-2379}" "${ETCD_PEER_PORT:-2380}" "${ETCD_METRICS_PORT:-2381}" \
        "${PG_PORT:-15432}" "${PATRONI_API_PORT:-8008}" \
        "${SWFS_MASTER_PORT:-9333}" "${SWFS_VOLUME_PORT:-8082}" "${SWFS_FILER_PORT:-8888}" \
        "${SWFS_ADMIN_PORT:-12535}" "${SWFS_ADMIN_GRPC_PORT:-22535}" \
        "${SWFS_MASTER_METRICS_PORT:-9324}" "${SWFS_VOLUME_METRICS_PORT:-9325}" "${SWFS_FILER_METRICS_PORT:-9326}" \
        "${SFTPGO_TELEMETRY_PORT:-10000}" \
        "${PANEL_PORT:-9443}" \
        "${HTTPS_PORT:-443}" \
        "${ARBITER_IP:-}" "${peer_ips}" <<'REMOTE_UFW'
set -euo pipefail
SLUG="$1"
ADMIN_SSH_NET="$2"; ADMIN_SSH_PORT="$3"
SFTP_PORT="$4"; FTPS_PORT="$5"; PASV_MIN="$6"; PASV_MAX="$7"
ETCD_C="$8"; ETCD_P="$9"; ETCD_M="${10}"
PG_PORT="${11}"; PATRONI_PORT="${12}"
SWFS_M="${13}"; SWFS_V="${14}"; SWFS_F="${15}"
SWFS_A="${16}"; SWFS_AG="${17}"
MET_M="${18}"; MET_V="${19}"; MET_F="${20}"
SFTP_TEL="${21}"; PANEL_P="${22}"; HTTPS_P="${23}"
ARBITER_IP="${24}"; PEER_IPS="${25}"

SWFS_MG=$((SWFS_M + 10000))
SWFS_VG=$((SWFS_V + 10000))
SWFS_FG=$((SWFS_F + 10000))

if [[ -f /run/ufw-rollback.pid ]]; then
    kill "$(cat /run/ufw-rollback.pid)" 2>/dev/null || true
    rm -f /run/ufw-rollback.pid
fi

# Разблокируем IP всех нод кластера во всех активных jail'ах fail2ban
if command -v fail2ban-client >/dev/null 2>&1; then
    for PEER_IP in ${PEER_IPS}; do
        fail2ban-client unban "${PEER_IP}" >/dev/null 2>&1 || true
    done
fi

WAS_ACTIVE=false
PRESERVE_PORTS=""
if ufw status | grep -q "Status: active"; then
    WAS_ACTIVE=true
else
    # Запоминаем уже открытые на хосте публичные TCP/UDP порты (VPN awg0, 2FA, Nginx :80/:443/:8443 и т.д.), чтобы не сломать соседние сервисы!
    PRESERVE_PORTS=$(python3 - <<'PYPORTS' 2>/dev/null || true
import subprocess
out = subprocess.check_output(["ss", "-H", "-tuln"], text=True, stderr=subprocess.DEVNULL)
seen = set()
for line in out.splitlines():
    parts = line.split()
    if len(parts) < 5:
        continue
    proto = "udp" if parts[0].startswith("udp") else "tcp"
    addr = parts[4]
    if addr.startswith(("127.", "[::1]", "169.254.")):
        continue
    port = addr.rsplit(":", 1)[-1]
    if port.isdigit() and int(port) not in (53, 68):
        seen.add(f"{port}/{proto}")
print(" ".join(sorted(seen)))
PYPORTS
    )
    ufw --force reset >/dev/null 2>&1
fi

# Если на сервере отключен IPv6 в ядре / недоступен ip6tables — отключаем IPV6 в UFW во избежание ошибки ufw-init!
if [[ -f /etc/default/ufw ]]; then
    if [[ ! -d /proc/sys/net/ipv6 ]] || ! ip6tables -L -n >/dev/null 2>&1; then
        sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw || true
    fi
fi

# Если на сервере включен IP forwarding (например, AmneziaWG / WireGuard / Docker routing) — не блокируем транзитный трафик!
if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]] && [[ -f /etc/default/ufw ]]; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
fi

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

for p_proto in ${PRESERVE_PORTS}; do
    ufw allow "${p_proto}" comment "${SLUG}:preserved-service" >/dev/null 2>&1 || true
done

ufw allow from "${ADMIN_SSH_NET}" to any port "${ADMIN_SSH_PORT}" proto tcp comment "${SLUG}:admin-ssh" >/dev/null
ufw allow from "${ADMIN_SSH_NET}" to any port "${PANEL_P}" proto tcp comment "${SLUG}:web-panel" >/dev/null

ufw allow "${SFTP_PORT}/tcp" comment "${SLUG}:public-sftp" >/dev/null
ufw allow "${FTPS_PORT}/tcp" comment "${SLUG}:public-ftps" >/dev/null
ufw allow "${PASV_MIN}:${PASV_MAX}/tcp" comment "${SLUG}:public-pasv" >/dev/null
ufw allow "${HTTPS_P}/tcp" comment "${SLUG}:public-https" >/dev/null

for PEER_IP in ${PEER_IPS}; do
    ufw allow from "${PEER_IP}" to any port "${ADMIN_SSH_PORT},${ETCD_C},${ETCD_P}" proto tcp comment "${SLUG}:peer:${PEER_IP}" >/dev/null
    ufw allow from "${PEER_IP}" to any port "${PG_PORT}" proto tcp comment "${SLUG}:peer:${PEER_IP}" >/dev/null
    ufw allow from "${PEER_IP}" to any port "${PATRONI_PORT}" proto tcp comment "${SLUG}:peer:${PEER_IP}" >/dev/null
    ufw allow from "${PEER_IP}" to any port "${SWFS_M},${SWFS_MG},${SWFS_V},${SWFS_VG},${SWFS_F},${SWFS_FG}" proto tcp comment "${SLUG}:peer:${PEER_IP}" >/dev/null
    ufw allow from "${PEER_IP}" to any port "${SWFS_A},${SWFS_AG}" proto tcp comment "${SLUG}:peer:${PEER_IP}" >/dev/null
done

if [[ -n "${ARBITER_IP}" ]]; then
    ufw allow from "${ARBITER_IP}" to any port "${ADMIN_SSH_PORT}" proto tcp comment "${SLUG}:arbiter:${ARBITER_IP}" >/dev/null
    ufw allow from "${ARBITER_IP}" to any port "${ETCD_C},${ETCD_M},${PATRONI_PORT},9100,${MET_M},${MET_V},${MET_F},${SFTP_TEL}" proto tcp comment "${SLUG}:arbiter:${ARBITER_IP}" >/dev/null
fi

if [[ "${WAS_ACTIVE}" == "true" ]]; then
    STALE_NUMS=$(python3 - "${PEER_IPS}" "${ARBITER_IP}" "${SLUG}" "${HTTPS_P}" "${SFTP_PORT}" "${FTPS_PORT}" "${PG_PORT}" "${PATRONI_PORT}" <<'PYEOF'
import re, subprocess, sys
peers = set(sys.argv[1].split())
arbiter = sys.argv[2].strip()
slug = re.escape(sys.argv[3])
https_p, sftp_p, ftps_p, pg_p, pat_p = sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
valid_single_peer_ports = {f"{pg_p}/tcp", f"{pat_p}/tcp"}
out = subprocess.check_output(["ufw", "status", "numbered"], text=True, stderr=subprocess.DEVNULL)
nums = []
for line in out.splitlines():
    m = re.match(rf"\[\s*(\d+)\]\s+(\S+).*#\s*(?:{slug}|cluster-b):(peer|arbiter):(\S+)", line)
    if m:
        rule_num, port_spec, role_kind, src_ip = int(m.group(1)), m.group(2), m.group(3), m.group(4)
        if role_kind == "peer" and src_ip not in peers:
            nums.append(rule_num)
            continue
        if role_kind == "arbiter" and (not arbiter or src_ip != arbiter):
            nums.append(rule_num)
            continue
        if role_kind == "peer" and port_spec.endswith("/tcp") and "," not in port_spec and port_spec not in valid_single_peer_ports:
            nums.append(rule_num)
            continue
    m_pub = re.match(rf"\[\s*(\d+)\]\s+(\d+)/tcp\b.*#\s*{slug}:public-(https|sftp|ftps)\b", line)
    if m_pub:
        port_val, kind = m_pub.group(2), m_pub.group(3)
        expected = {"https": https_p, "sftp": sftp_p, "ftps": ftps_p}[kind]
        if port_val != expected:
            nums.append(int(m_pub.group(1)))
for n in sorted(nums, reverse=True):
    print(n)
PYEOF
    )
    for num in ${STALE_NUMS}; do
        ufw --force delete "${num}" >/dev/null
    done
fi

nohup bash -c 'sleep 120 && ufw --force disable && echo "$(date): UFW ROLLBACK TRIGGERED" >> /var/log/ufw-rollback.log' </dev/null >/dev/null 2>&1 &
echo $! > /run/ufw-rollback.pid

if [[ "${WAS_ACTIVE}" == "false" ]]; then
    ufw --force enable >/dev/null
else
    ufw reload >/dev/null
fi

# Гарантируем приоритетный /32 допуск кластерных портов выше любых f2b-*/кастомных цепочек в INPUT
PEER_FAST_PORTS="${ADMIN_SSH_PORT},${ETCD_C},${ETCD_P},${PG_PORT},${PATRONI_PORT},${SWFS_M},${SWFS_MG},${SWFS_V},${SWFS_VG},${SWFS_F},${SWFS_FG},${SWFS_A},${SWFS_AG}"
iptables -S INPUT 2>/dev/null | { grep "${SLUG}:peer-fast:" || true; } | sed 's/^-A /-D /' | while read -r r; do
    # shellcheck disable=SC2086
    iptables $r 2>/dev/null || true
done || true
for PEER_IP in ${PEER_IPS}; do
    iptables -I INPUT 1 -p tcp -s "${PEER_IP}/32" -m multiport --dports "${PEER_FAST_PORTS}" -m comment --comment "${SLUG}:peer-fast:${PEER_IP}" -j ACCEPT 2>/dev/null || true
done
REMOTE_UFW

    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        if remote_exec "${ip}" "if [[ -f /run/ufw-rollback.pid ]]; then kill \$(cat /run/ufw-rollback.pid) 2>/dev/null || true; rm -f /run/ufw-rollback.pid; fi; echo 'EXTERNAL_SSH_VERIFIED'" | grep -q 'EXTERNAL_SSH_VERIFIED'; then
            log_info "  ✅ Внешний SSH после UFW подтвержден, таймер отката снят (${name})"
        else
            log_error "  ❌ ВНЕШНЯЯ ПРОВЕРКА SSH НЕ ПРОЙДЕНА на ${name}! UFW автоматически отключится через 120с."
            return 1
        fi
    fi
}

get_node_index_by_ip() {
    local target_ip="$1" count i
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        if [[ "$(get_node_ip "$i")" == "${target_ip}" ]]; then
            echo "$i"
            return 0
        fi
    done
    echo "1"
}

get_node_name_by_ip() {
    local target_ip="$1" count i
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        if [[ "$(get_node_ip "$i")" == "${target_ip}" ]]; then
            get_node_name "$i"
            return 0
        fi
    done
    echo "node1"
}

# shellcheck disable=SC2034
ASYMMETRIC_BLOCKED_PAIRS=()
# shellcheck disable=SC2034
PROBED_SELECTED_PORT=""

# Параллельное тестирование кандидатов портов PG на узле cand_ip со всех остальных узлов кластера.
# Результат записывается в глобальную переменную PROBED_SELECTED_PORT (во избежание subshell),
# а пары с полной блокировкой прямого TCP добавляются в ASYMMETRIC_BLOCKED_PAIRS.
probe_node_candidate_ports() {
    local cand_ip="$1" cand_name="$2" cand_ports="$3"
    PROBED_SELECTED_PORT=""
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        PROBED_SELECTED_PORT="${PG_PORT:-15432}"
        return 0
    fi
    local peer_ips
    peer_ips=$(get_all_peer_ips | tr '\n' ' ')

    local free_ports
    free_ports=$(remote_exec_stdin "${cand_ip}" "${cand_ports}" "${peer_ips}" <<'REMOTE_PROBE_START' || true
set -euo pipefail
PORTS="$1"; PEERS="$2"
if [[ -f /run/ligament-pg-probe.pid ]]; then
    kill "$(cat /run/ligament-pg-probe.pid)" 2>/dev/null || true
    rm -f /run/ligament-pg-probe.pid
fi
iptables -S INPUT 2>/dev/null | { grep 'ligament-pg-probe' || true; } | sed 's/^-A /-D /' | while read -r r; do
    # shellcheck disable=SC2086
    iptables $r 2>/dev/null || true
done

FREE_LIST=$(python3 - "${PORTS}" <<'PYFREE'
import subprocess, sys
cand = [p for p in sys.argv[1].split() if p.isdigit()]
out = subprocess.check_output(["ss", "-H", "-tln"], text=True, stderr=subprocess.DEVNULL)
busy = set()
for line in out.splitlines():
    parts = line.split()
    if len(parts) >= 4:
        port = parts[3].rsplit(":", 1)[-1]
        if port.isdigit():
            busy.add(port)
free = []
for p in cand:
    if p not in busy and p not in free:
        free.append(p)
print(" ".join(free))
PYFREE
)
[[ -n "${FREE_LIST}" ]] || exit 0
FREE_CSV="${FREE_LIST// /,}"
for pip in ${PEERS}; do
    iptables -I INPUT 1 -p tcp -s "${pip}/32" -m multiport --dports "${FREE_CSV}" -m comment --comment "ligament-pg-probe" -j ACCEPT 2>/dev/null || true
done

nohup python3 -c '
import select, socket, sys, time
socks = []
for p_str in sys.argv[1].split():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", int(p_str)))
        s.listen(32)
        s.setblocking(False)
        socks.append(s)
    except Exception:
        s.close()
deadline = time.monotonic() + 25.0
while time.monotonic() < deadline and socks:
    r, _, _ = select.select(socks, [], [], 0.5)
    for ls in r:
        try:
            conn, _ = ls.accept()
            conn.close()
        except Exception:
            pass
for s in socks:
    s.close()
' "${FREE_LIST}" </dev/null >/dev/null 2>&1 &
echo $! > /run/ligament-pg-probe.pid
sleep 0.3
echo "${FREE_LIST}"
REMOTE_PROBE_START
    )
    free_ports=$(echo "${free_ports}" | tail -n1 | xargs 2>/dev/null || true)
    if [[ -z "${free_ports}" ]]; then
        return 0
    fi

    local count common_ports="${free_ports}"
    count=$(get_node_count)
    for i in $(seq 1 "${count}"); do
        local pip pname reached
        pip=$(get_node_ip "$i")
        pname=$(get_node_name "$i")
        [[ "${pip}" == "${cand_ip}" ]] && continue

        reached=$(remote_exec_stdin "${pip}" "${cand_ip}" "${free_ports}" <<'REMOTE_PROBE_CLIENT' 2>/dev/null || true
set -euo pipefail
TARGET="$1"; PORTS="$2"
python3 - "${TARGET}" "${PORTS}" <<'PYCLIENT'
import concurrent.futures, socket, sys
target = sys.argv[1]
ports = [int(p) for p in sys.argv[2].split() if p.isdigit()]
def check(p):
    try:
        s = socket.create_connection((target, p), timeout=3.5)
        s.close()
        return p
    except Exception:
        return None
with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(ports))) as ex:
    res = [p for p in ex.map(check, ports) if p is not None]
print(" ".join(str(p) for p in res))
PYCLIENT
REMOTE_PROBE_CLIENT
        )
        reached=$(echo "${reached}" | tail -n1 | xargs 2>/dev/null || true)
        if [[ -z "${reached}" ]]; then
            log_warn "  ⚠️  Прямой TCP ${pname} (${pip}) -> ${cand_name} (${cand_ip}) закрыт провайдером на всех проверенных портах [${free_ports}]"
            ASYMMETRIC_BLOCKED_PAIRS+=("${pip}|${pname}|${cand_ip}|${cand_name}")
            common_ports=""
        else
            log_info "  🔎 Доступные порты ${pname} -> ${cand_name}: [${reached}]"
            local next_common="" cp
            for cp in ${common_ports}; do
                if [[ " ${reached} " == *" ${cp} "* ]]; then
                    next_common+="${next_common:+ }${cp}"
                fi
            done
            common_ports="${next_common}"
        fi
    done

    remote_exec_stdin "${cand_ip}" <<'REMOTE_PROBE_STOP' >/dev/null 2>&1 || true
if [[ -f /run/ligament-pg-probe.pid ]]; then
    kill "$(cat /run/ligament-pg-probe.pid)" 2>/dev/null || true
    rm -f /run/ligament-pg-probe.pid
fi
iptables -S INPUT 2>/dev/null | { grep 'ligament-pg-probe' || true; } | sed 's/^-A /-D /' | while read -r r; do
    # shellcheck disable=SC2086
    iptables $r 2>/dev/null || true
done
REMOTE_PROBE_STOP

    if [[ -n "${common_ports}" ]]; then
        # shellcheck disable=SC2034
        PROBED_SELECTED_PORT="${common_ports%% *}"
    fi
}

# Автоматический прозрачный SSH port-forward + OUTPUT DNAT мост при полной фильтрации прямого TCP между двумя нодами
ensure_ssh_peer_bridge() {
    local src_ip="$1" src_name="$2" dst_ip="$3" dst_name="$4"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] ensure_ssh_peer_bridge ${src_name} (${src_ip}) -> ${dst_name} (${dst_ip})"
        return 0
    fi

    local dst_idx swfs_mg swfs_vg swfs_fg base_lport ssh_p mode=""
    dst_idx=$(get_node_index_by_ip "${dst_ip}")
    swfs_mg=$(( ${SWFS_MASTER_PORT:-9333} + 10000 ))
    swfs_vg=$(( ${SWFS_VOLUME_PORT:-8082} + 10000 ))
    swfs_fg=$(( ${SWFS_FILER_PORT:-8888} + 10000 ))
    base_lport=$(( 30000 + dst_idx * 100 ))
    ssh_p="${ADMIN_SSH_PORT:-22}"

    if remote_tcp_probe "${src_ip}" "${dst_ip}" "${ssh_p}" 5; then
        mode="L"
    elif remote_tcp_probe "${dst_ip}" "${src_ip}" "${ssh_p}" 5; then
        mode="R"
    else
        log_error "Невозможно построить резервный SSH-мост ${src_name} -> ${dst_name}: порт SSH (${ssh_p}) недоступен в обе стороны!"
        return 1
    fi

    log_info "  🌉 Настройка автоматического защищенного TCP-моста (${mode}) для ${src_name} (${src_ip}) -> ${dst_name} (${dst_ip})..."

    local raw_ports=(
        "${ETCD_CLIENT_PORT:-2379}"
        "${ETCD_PEER_PORT:-2380}"
        "${PG_PORT:-15432}"
        "${PATRONI_API_PORT:-8008}"
        "${SWFS_MASTER_PORT:-9333}"
        "${swfs_mg}"
        "${SWFS_VOLUME_PORT:-8082}"
        "${swfs_vg}"
        "${SWFS_FILER_PORT:-8888}"
        "${swfs_fg}"
        "${SWFS_ADMIN_PORT:-12535}"
        "${SWFS_ADMIN_GRPC_PORT:-22535}"
    )
    local uniq_ports=() rp seen_str=" "
    for rp in "${raw_ports[@]}"; do
        if [[ "${seen_str}" != *" ${rp} "* ]]; then
            uniq_ports+=("${rp}")
            seen_str+="${rp} "
        fi
    done

    local fwd_flags="" dnat_pairs="" k=0 dport lport first_lport=""
    for dport in "${uniq_ports[@]}"; do
        k=$(( k + 1 ))
        lport=$(( base_lport + k ))
        [[ -z "${first_lport}" ]] && first_lport="${lport}"
        if [[ "${mode}" == "L" ]]; then
            fwd_flags+="${fwd_flags:+ }-L 127.0.0.1:${lport}:${dst_ip}:${dport}"
        else
            fwd_flags+="${fwd_flags:+ }-R 127.0.0.1:${lport}:${dst_ip}:${dport}"
        fi
        dnat_pairs+="${dport}:${lport} "
    done

    local client_ip server_ip client_name pubkey unit_name
    if [[ "${mode}" == "L" ]]; then
        client_ip="${src_ip}"; client_name="${src_name}"
        server_ip="${dst_ip}"
        unit_name="${CLUSTER_SLUG}-bridge-to-${dst_name}"
    else
        client_ip="${dst_ip}"; client_name="${dst_name}"
        server_ip="${src_ip}"
        unit_name="${CLUSTER_SLUG}-bridge-push-${src_name}"
    fi

    pubkey=$(remote_exec_stdin "${client_ip}" <<'REMOTE_BR_KEY'
set -euo pipefail
mkdir -p /etc/ligament-bridge && chmod 700 /etc/ligament-bridge
if [[ ! -f /etc/ligament-bridge/id_ed25519 ]]; then
    ssh-keygen -t ed25519 -f /etc/ligament-bridge/id_ed25519 -N "" -C "ligament-bridge" >/dev/null
fi
chmod 600 /etc/ligament-bridge/id_ed25519
awk '{print $1 " " $2}' /etc/ligament-bridge/id_ed25519.pub
REMOTE_BR_KEY
    )
    pubkey=$(echo "${pubkey}" | tail -n1)

    remote_exec_stdin "${server_ip}" "${pubkey}" "${CLUSTER_SLUG}-bridge-${client_name}" <<'REMOTE_BR_AUTH'
set -euo pipefail
PUB="$1"; TAG="$2"
if [[ -d /etc/ssh/sshd_config.d ]]; then
    cat > /etc/ssh/sshd_config.d/98-ligament-bridge.conf <<'SSHD_BR'
AllowTcpForwarding yes
GatewayPorts no
SSHD_BR
fi
if [[ -f /etc/ssh/sshd_config ]]; then
    sed -i 's/^[[:space:]]*AllowTcpForwarding[[:space:]]\+no/AllowTcpForwarding yes/I' /etc/ssh/sshd_config || true
fi
if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
awk -v pub="${PUB}" -v tag="${TAG}" 'index($0, pub) == 0 && index($0, tag) == 0' /root/.ssh/authorized_keys > /root/.ssh/authorized_keys.tmp
mv /root/.ssh/authorized_keys.tmp /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo "restrict,port-forwarding,command=\"/bin/false\" ${PUB} ${TAG}" >> /root/.ssh/authorized_keys
REMOTE_BR_AUTH

    remote_exec_stdin "${client_ip}" "${unit_name}" "${server_ip}" "${ssh_p}" "${fwd_flags}" <<'REMOTE_BR_UNIT'
set -euo pipefail
UNIT="$1"; SRV_IP="$2"; SSH_P="$3"; FLAGS="$4"
mkdir -p /etc/ligament-bridge && chmod 700 /etc/ligament-bridge
touch /etc/ligament-bridge/known_hosts && chmod 600 /etc/ligament-bridge/known_hosts
ssh-keygen -R "${SRV_IP}" -f /etc/ligament-bridge/known_hosts >/dev/null 2>&1 || true
ssh-keygen -R "[${SRV_IP}]:${SSH_P}" -f /etc/ligament-bridge/known_hosts >/dev/null 2>&1 || true

cat > "/etc/systemd/system/${UNIT}.service" <<EOF
[Unit]
Description=Ligament Vault Peer TCP Bridge (${UNIT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ssh -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/etc/ligament-bridge/known_hosts -o BatchMode=yes -p ${SSH_P} -i /etc/ligament-bridge/id_ed25519 ${FLAGS} root@${SRV_IP}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${UNIT}.service" >/dev/null 2>&1 || true
systemctl restart "${UNIT}.service"
REMOTE_BR_UNIT

    wait_for_remote_health "${src_ip}" "SSH-мост ${src_name} -> ${dst_name} (127.0.0.1:${first_lport})" \
        "ss -H -tln | awk '{print \$4}' | grep -Fxq '127.0.0.1:${first_lport}'" 15 1 \
        "$( [[ "${mode}" == "L" ]] && echo "systemctl status '${unit_name}.service' --no-pager -l 2>/dev/null || true" || echo "ss -H -tln | head -n 20 || true" )"

    remote_exec_stdin "${src_ip}" "${CLUSTER_SLUG}" "${dst_name}" "${dst_ip}" "${dst_idx}" "${dnat_pairs}" <<'REMOTE_BR_DNAT'
set -euo pipefail
SLUG="$1"; DST_NAME="$2"; DST_IP="$3"; DST_IDX="$4"; PAIRS="$5"
CHAIN="LIG_BR_${DST_IDX}"
SCRIPT="/usr/local/sbin/${SLUG}-dnat-${DST_NAME}.sh"

cat > /etc/sysctl.d/98-ligament-bridge.conf <<'SYSBR'
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.lo.route_localnet = 1
SYSBR
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.lo.route_localnet=1 >/dev/null 2>&1 || true

cat > "${SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.lo.route_localnet=1 >/dev/null 2>&1 || true
iptables -t nat -N "${CHAIN}" 2>/dev/null || iptables -t nat -F "${CHAIN}"
iptables -t nat -C OUTPUT -p tcp -d "${DST_IP}/32" -j "${CHAIN}" 2>/dev/null || iptables -t nat -I OUTPUT 1 -p tcp -d "${DST_IP}/32" -j "${CHAIN}"
iptables -t nat -C POSTROUTING -o lo -p tcp -d 127.0.0.1/32 --dport 30100:39999 -j SNAT --to-source 127.0.0.1 2>/dev/null || iptables -t nat -A POSTROUTING -o lo -p tcp -d 127.0.0.1/32 --dport 30100:39999 -j SNAT --to-source 127.0.0.1
for pair in ${PAIRS}; do
    dp="\${pair%%:*}"
    lp="\${pair##*:}"
    iptables -t nat -A "${CHAIN}" -p tcp -d "${DST_IP}/32" --dport "\${dp}" -j DNAT --to-destination "127.0.0.1:\${lp}"
done
EOF
chmod 700 "${SCRIPT}"
"${SCRIPT}"

cat > "/etc/systemd/system/${SLUG}-dnat-${DST_NAME}.service" <<EOF
[Unit]
Description=Ligament Vault OUTPUT DNAT for Peer Bridge to ${DST_NAME} (${DST_IP})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SLUG}-dnat-${DST_NAME}.service" >/dev/null 2>&1 || true
REMOTE_BR_DNAT

    log_info "  ✅ Прозрачный мост ${src_name} -> ${dst_name} активен (сквозной mTLS сохранен)"
}

tune_node_wan_and_swap() {
    local ip="$1"
    local peer_ips
    peer_ips=$(get_all_peer_ips | tr '\n' ' ')
    remote_exec_stdin "${ip}" "${ADMIN_SSH_PORT:-22}" "${peer_ips}" <<'REMOTE_TUNE'
set -euo pipefail
SSH_PORT="$1"; PEER_IPS="$2"

# Отключаем обратный DNS-поиск в sshd (иначе на некоторых VPS логин висит по 15-30с!)
if [[ -d /etc/ssh/sshd_config.d ]]; then
    if [[ -f /etc/ssh/sshd_config.d/99-ligament-keyonly.conf ]] && ! grep -q '^UseDNS no' /etc/ssh/sshd_config.d/99-ligament-keyonly.conf; then
        echo "UseDNS no" >> /etc/ssh/sshd_config.d/99-ligament-keyonly.conf
        sshd -t 2>/dev/null && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true)
    fi
fi

# Белый список узлов кластера в fail2ban
if [[ -d /etc/fail2ban/jail.d ]]; then
    F2B_BACKEND=""
    [[ ! -f /var/log/auth.log ]] && F2B_BACKEND="backend = systemd"
    cat > /etc/fail2ban/jail.d/sshd.conf <<F2B
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
${F2B_BACKEND}
ignoreip = 127.0.0.1/8 ::1 ${PEER_IPS}
maxretry = 6
bantime = 3600
findtime = 600
F2B
    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
fi

# Автоматический swap 1GB на малых VPS (< 3GB RAM), чтобы сборка/контейнеры не вешали sshd в OOM-thrash
MEM_MB=$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 4096)
SWAP_MB=$(awk '/SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)
FREE_ROOT_MB=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
if (( MEM_MB < 3000 && SWAP_MB < 256 && FREE_ROOT_MB >= 3500 )) && [[ ! -f /swapfile ]]; then
    (fallocate -l 1024M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none) && \
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && \
    (grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab) || rm -f /swapfile
fi
REMOTE_TUNE
}

harden_node_full() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    local peer_ips
    peer_ips=$(get_all_peer_ips | tr '\n' ' ')
    log_info "Укрепление ОС на ${name} (${ip})..."

    local pasv_range="${FTPS_PASV_MIN:-50000}-${FTPS_PASV_MAX:-50199}"
    remote_exec_stdin "${ip}" \
        "${REMOTE_BASE_DIR}" \
        "${ADMIN_SSH_PORT:-22}" \
        "${SFTPGO_TEMP_PATH:-/data/sftpgo-temp}" \
        "${SFTPGO_DATA_DIR:-/data/sftpgo}" \
        "${SWFS_VOLUME_DIR%%,*}" \
        "${PG_DATA_DIR}" \
        "${ETCD_DATA_DIR:-/data/etcd}" \
        "${SWFS_MASTER_DIR:-/data/swfs-master}" \
        "${peer_ips}" \
        "${pasv_range}" <<'REMOTE_HARDEN'
set -euo pipefail
BASE_DIR="$1"; SSH_PORT="$2"; SFTP_TMP="$3"; SFTP_DATA="$4"; SWFS_DIR="$5"; PG_DIR="$6"; ETCD_DIR="$7"; SWFS_MDIR="$8"; PEER_IPS="$9"; PASV_RANGE="${10}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq chrony fail2ban python3-systemd ufw jq curl python3 python3-yaml netcat-openbsd conntrack iproute2
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

systemctl enable --now chrony 2>/dev/null || echo "WARN: chrony skipped (system clock managed by host)" >&2

if [[ -s /root/.ssh/authorized_keys ]]; then
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-ligament-keyonly.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
UseDNS no
SSHD
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi
fi

cat > /etc/sysctl.d/99-ligament-vault.conf <<SYSCTL
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 32768 60999
net.ipv4.ip_local_reserved_ports = ${PASV_RANGE}
net.ipv4.ip_unprivileged_port_start = 21
net.ipv4.tcp_tw_reuse = 1
vm.swappiness = 1
SYSCTL
sysctl -w net.ipv4.ip_local_port_range="32768 60999" >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_local_reserved_ports="${PASV_RANGE}" >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_unprivileged_port_start=21 >/dev/null 2>&1 || true
sysctl --system >/dev/null 2>&1 || true

mkdir -p /etc/docker
NEW_DAEMON='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}'
if [[ ! -f /etc/docker/daemon.json ]]; then
    printf "%s\n" "${NEW_DAEMON}" > /etc/docker/daemon.json
    if [[ -z "$(docker ps -q 2>/dev/null || true)" ]]; then
        systemctl restart docker 2>/dev/null || true
    fi
fi

F2B_BACKEND=""
[[ ! -f /var/log/auth.log ]] && F2B_BACKEND="backend = systemd"
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.conf <<F2B
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
${F2B_BACKEND}
ignoreip = 127.0.0.1/8 ::1 ${PEER_IPS}
maxretry = 6
bantime = 3600
findtime = 600
F2B
systemctl enable --now fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true

mkdir -p "${BASE_DIR}/configs/seaweedfs" "${BASE_DIR}/certs/ssl" "${BASE_DIR}/ssh-host-keys" "${BASE_DIR}/hooks" \
         /var/lib/node_exporter/textfile_collector \
         "${SFTP_TMP}" "${SFTP_DATA}/data" "${SFTP_DATA}/empty-root" "${SFTP_DATA}/backups" "${SWFS_DIR}" "${PG_DIR}" "${ETCD_DIR}" "${SWFS_MDIR}"
chown -R 1000:1000 "${SFTP_TMP}" "${SFTP_DATA}" "${SWFS_DIR}" "${SWFS_MDIR}" "${BASE_DIR}/hooks"
chmod 555 "${SFTP_DATA}/empty-root"
REMOTE_HARDEN

    tune_node_wan_and_swap "${ip}" "${dc}" "${name}"
    harden_node_ufw "${ip}" "${dc}" "${name}" "${idx}"
    log_info "  ✅ Хост ${name} готов"
}

# Гарантирует базовые пакеты и sysctl на узлах, добавленных/замененных после прохождения Стадии 1 (--resume)
ensure_node_base_prereqs() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    if ! remote_exec "${ip}" "command -v jq >/dev/null && command -v ufw >/dev/null && command -v nc >/dev/null && command -v conntrack >/dev/null && python3 -c 'import yaml' 2>/dev/null" >/dev/null 2>&1; then
        log_info "  ⚙️  Доустановка базовых системных пакетов на ${name} (${ip})..."
        harden_node_full "${ip}" "${dc}" "${name}" "${idx}"
        return 0
    fi
    local pasv_range="${FTPS_PASV_MIN:-50000}-${FTPS_PASV_MAX:-50199}"
    remote_exec "${ip}" "
        changed=0
        if [[ -f /etc/sysctl.d/99-ligament-vault.conf ]] && grep -q 'ip_local_port_range = 1024 65535' /etc/sysctl.d/99-ligament-vault.conf; then
            sed -i 's/net.ipv4.ip_local_port_range = 1024 65535/net.ipv4.ip_local_port_range = 32768 60999/' /etc/sysctl.d/99-ligament-vault.conf
            changed=1
        fi
        if [[ -f /etc/sysctl.d/99-ligament-vault.conf ]] && ! grep -q 'ip_local_reserved_ports' /etc/sysctl.d/99-ligament-vault.conf; then
            echo 'net.ipv4.ip_local_reserved_ports = ${pasv_range}' >> /etc/sysctl.d/99-ligament-vault.conf
            changed=1
        fi
        if (( changed == 1 )); then
            sysctl -w net.ipv4.ip_local_port_range='32768 60999' >/dev/null 2>&1 || true
            sysctl -w net.ipv4.ip_local_reserved_ports='${pasv_range}' >/dev/null 2>&1 || true
            sysctl --system >/dev/null 2>&1 || true
        fi
    " >/dev/null 2>&1 || true
}

# --- Установка ограниченного forced-command SSH-хелпера для Арбитра (вкл. TCP RST fencing) ---
install_arbiter_helper_on_node() {
    local ip="$1" arbiter_pubkey="$2"
    local master_peers
    master_peers=$(build_swfs_master_peers)

    remote_exec_stdin "${ip}" \
        "${arbiter_pubkey}" \
        "${REMOTE_BASE_DIR}" \
        "${CLUSTER_SLUG}" \
        "${ETCD_CLIENT_PORT:-2379}" \
        "${SFTP_PORT:-2022}" \
        "${FTPS_PORT:-21}" \
        "${HTTPS_PORT:-443}" \
        "${master_peers}" \
        "${SWFS_FILER_PORT:-8888}" <<'REMOTE_ARB_HELPER'
set -euo pipefail
PUBKEY="$1"; BASE_DIR="$2"; SLUG="$3"; EC_PORT="$4"; SFTP_P="$5"; FTPS_P="$6"; HTTPS_P="$7"; MASTER_PEERS="$8"; FILER_P="$9"

cat > /usr/local/bin/arbiter-helper.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
CMD="\${SSH_ORIGINAL_COMMAND:-}"
case "\${CMD}" in
    restart-sftpgo)
        cd "${BASE_DIR}" && docker compose up -d sftpgo && docker compose restart sftpgo
        ;;
    fence-edge)
        # Остановка SFTPGo + принудительный TCP RST активных сессий для мгновенного реконнекта клиентов!
        cd "${BASE_DIR}" && docker compose stop sftpgo || true
        for p in "${SFTP_P}" "${FTPS_P}" "${HTTPS_P}"; do
            ss -K "sport = :\${p}" >/dev/null 2>&1 || true
            conntrack -D -p tcp --dport "\${p}" >/dev/null 2>&1 || true
        done
        echo "FENCED_OK"
        ;;
    check-gates)
        ETCD_CID=\$(cd "${BASE_DIR}" && docker compose ps -q etcd | head -n1 || true)
        if [[ -n "\${ETCD_CID}" ]]; then
            docker exec "\${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC_PORT}" \
                --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
                endpoint health >/dev/null
        fi
        FILER_CID=\$(cd "${BASE_DIR}" && docker compose ps -q swfs-filer | head -n1 || true)
        [[ -n "\${FILER_CID}" ]] || { echo "FILER_DOWN"; exit 1; }
        FIX_OUT=\$(docker exec -i "\${FILER_CID}" weed shell -master="${MASTER_PEERS}" -filer="127.0.0.1:${FILER_P}" <<< "volume.fix.replication" 2>/dev/null || echo "ERR")
        if echo "\${FIX_OUT}" | grep -qiE "replicating|copying|deleting|under-replicated|over-replicated|flag provided|\bERR\b|error:"; then
            echo "SWFS_DIRTY"
            exit 1
        fi
        echo "GATES_OK"
        ;;
    etcd-lease\ *)
        EDGE_IP="\${CMD#etcd-lease }"
        if [[ ! "\${EDGE_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            exit 1
        fi
        ETCD_CID=\$(cd "${BASE_DIR}" && docker compose ps -q etcd | head -n1 || true)
        [[ -n "\${ETCD_CID}" ]] || exit 1
        LID=\$(docker exec "\${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC_PORT}" \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
            lease grant 60 2>/dev/null | awk '/lease/{print \$2}')
        [[ -n "\${LID}" ]] || exit 1
        docker exec "\${ETCD_CID}" etcdctl --endpoints="https://127.0.0.1:${EC_PORT}" \
            --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
            put "/${SLUG}/arbiter/active_edge" "\${EDGE_IP}" --lease="\${LID}" >/dev/null
        ;;
    *)
        echo "Forbidden arbiter command" >&2
        exit 1
        ;;
esac
EOF
chmod 755 /usr/local/bin/arbiter-helper.sh

mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
sed -i "/${SLUG}-arbiter-restricted/d" /root/.ssh/authorized_keys
sed -i '/cluster-b-arbiter-restricted/d' /root/.ssh/authorized_keys
echo "restrict,command=\"/usr/local/bin/arbiter-helper.sh\" ${PUBKEY} ${SLUG}-arbiter-restricted" >> /root/.ssh/authorized_keys
REMOTE_ARB_HELPER
}

# --- PKI: Root CA (с поддержкой ca.key.age в RAM) + Remote-CSR ---
PKI_ROLES=("swfs-master" "swfs-volume" "swfs-filer" "swfs-s3" "swfs-admin" "swfs-worker" "swfs-client" "etcd-server" "etcd-peer" "etcd-client" "pg-server" "pg-client")

_write_ca_config() {
    local ca_dir="$1"
    local priv_key="${2:-${ca_dir}/ca.key}"
    cat > "${ca_dir}/openssl-ca.cnf" <<EOF
[ca]
default_ca = CA_default

[CA_default]
dir               = ${ca_dir}
certs             = ${ca_dir}/newcerts
new_certs_dir     = ${ca_dir}/newcerts
database          = ${ca_dir}/index.txt
serial            = ${ca_dir}/serial
crlnumber         = ${ca_dir}/crlnumber
certificate       = ${ca_dir}/ca.crt
private_key       = ${priv_key}
default_md        = sha256
default_days      = 180
default_crl_days  = 30
preserve          = no
unique_subject    = no
policy            = policy_loose

[policy_loose]
commonName              = supplied
organizationName        = optional
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationalUnitName  = optional
emailAddress            = optional

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF
}

_init_crl_with_active_ca() {
    local ca_dir="$1"
    _write_ca_config "${ca_dir}" "${ACTIVE_CA_KEY}"
    openssl ca -config "${ca_dir}/openssl-ca.cnf" -gencrl -out "${ca_dir}/crl.pem" 2>/dev/null || true
    _write_ca_config "${ca_dir}"
}

ensure_ca_exists() {
    local ca_dir
    ca_dir="$(state_root)/.pki/ca"
    mkdir -p "${ca_dir}/newcerts"
    touch "${ca_dir}/index.txt"
    [[ -f "${ca_dir}/serial" ]]         || echo "1000" > "${ca_dir}/serial"
    [[ -f "${ca_dir}/crlnumber" ]]      || echo "01"   > "${ca_dir}/crlnumber"
    [[ -f "${ca_dir}/index.txt.attr" ]] || echo "unique_subject = no" > "${ca_dir}/index.txt.attr"
    _write_ca_config "${ca_dir}"

    if [[ -f "${ca_dir}/ca.crt" ]] && [[ -f "${ca_dir}/ca.key" || -f "${ca_dir}/ca.key.age" ]]; then
        if [[ ! -f "${ca_dir}/crl.pem" && "${DRY_RUN:-false}" != "true" ]]; then
            with_ca_key "${ca_dir}" _init_crl_with_active_ca "${ca_dir}"
        fi
        return 0
    fi

    log_info "Генерация Root CA (${PROJECT_NAME}, ECDSA P-256) локально на машине оператора..."
    run_or_dry openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "${ca_dir}/ca.key"
    run_or_dry openssl req -new -x509 -sha256 -key "${ca_dir}/ca.key" \
        -config "${ca_dir}/openssl-ca.cnf" -extensions v3_ca \
        -out "${ca_dir}/ca.crt" -days 3650 \
        -subj "/CN=${PROJECT_NAME} Root CA/O=Ligament"
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        chmod 600 "${ca_dir}/ca.key"
        with_ca_key "${ca_dir}" _init_crl_with_active_ca "${ca_dir}"
    fi
    log_warn "  ⚠️  Root CA ключ будет автоматически зашифрован в ca.key.age после развертывания (или храните offline)!"
}

_sign_csr_with_active_ca() {
    local ca_dir="$1" csr_file="$2" crt_file="$3" san="$4"
    _write_ca_config "${ca_dir}" "${ACTIVE_CA_KEY}"
    local extfile="${crt_file}.ext"
    printf "subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\nbasicConstraints=CA:FALSE\n" "${san}" > "${extfile}"
    openssl ca -batch -notext \
        -config "${ca_dir}/openssl-ca.cnf" \
        -extfile "${extfile}" \
        -in "${csr_file}" \
        -out "${crt_file}" 2>/dev/null
    rm -f "${extfile}"
    _write_ca_config "${ca_dir}"
}

generate_node_certs() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    local sroot ca_dir node_cert_dir
    sroot=$(state_root)
    ca_dir="${sroot}/.pki/ca"
    node_cert_dir="${sroot}/certs/${name}"
    mkdir -p "${node_cert_dir}"

    log_info "Zero-Knowledge Remote-CSR генерация сертификатов для ${name} (${ip})..."
    remote_exec "${ip}" "mkdir -p '${REMOTE_BASE_DIR}/certs/${name}' && chmod 755 '${REMOTE_BASE_DIR}/certs' '${REMOTE_BASE_DIR}/certs/${name}'"
    remote_copy "${ca_dir}/ca.crt" "${ip}:${REMOTE_BASE_DIR}/certs/ca.crt"
    remote_copy "${ca_dir}/ca.crt" "${ip}:${REMOTE_BASE_DIR}/certs/${name}/ca.crt"
    if [[ -f "${ca_dir}/crl.pem" ]]; then
        remote_copy "${ca_dir}/crl.pem" "${ip}:${REMOTE_BASE_DIR}/certs/${name}/crl.pem"
        remote_copy "${ca_dir}/crl.pem" "${ip}:${REMOTE_BASE_DIR}/certs/${name}/ca-crl.crt"
        remote_exec "${ip}" "chmod 644 '${REMOTE_BASE_DIR}/certs/ca.crt' '${REMOTE_BASE_DIR}/certs/${name}/ca.crt' '${REMOTE_BASE_DIR}/certs/${name}/crl.pem' '${REMOTE_BASE_DIR}/certs/${name}/ca-crl.crt'"
    else
        remote_exec "${ip}" "chmod 644 '${REMOTE_BASE_DIR}/certs/ca.crt' '${REMOTE_BASE_DIR}/certs/${name}/ca.crt'"
    fi

    local san="IP:${ip},IP:127.0.0.1,DNS:${name},DNS:${name}.${CLUSTER_SLUG}.internal,DNS:localhost"

    for role in "${PKI_ROLES[@]}"; do
        remote_exec_stdin "${ip}" "${REMOTE_BASE_DIR}/certs/${name}" "${role}" <<'REMOTE_CSR'
set -euo pipefail
CERT_DIR="$1"; ROLE="$2"
KEY="${CERT_DIR}/${ROLE}.key"
CSR="/tmp/${ROLE}.csr"
if [[ ! -f "${KEY}" ]]; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "${KEY}" 2>/dev/null
fi
chmod 600 "${KEY}"
openssl req -new -sha256 -key "${KEY}" -out "${CSR}" -subj "/CN=${ROLE}/O=Ligament"
REMOTE_CSR

        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            local scp_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
            [[ -n "${SSH_IDENTITY_FILE:-}" && -f "${SSH_IDENTITY_FILE}" ]] && scp_opts+=" -i ${SSH_IDENTITY_FILE}"
            [[ -n "${ADMIN_SSH_PORT:-}" && "${ADMIN_SSH_PORT}" != "22" ]] && scp_opts+=" -P ${ADMIN_SSH_PORT}"
            # shellcheck disable=SC2086
            scp ${scp_opts} "root@${ip}:/tmp/${role}.csr" "${node_cert_dir}/${role}.csr"
            with_ca_key "${ca_dir}" _sign_csr_with_active_ca "${ca_dir}" "${node_cert_dir}/${role}.csr" "${node_cert_dir}/${role}.crt" "${san}"
        else
            log_info "[DRY-RUN] Подпись CSR ${name}/${role} с SAN=${san}"
        fi

        remote_copy "${node_cert_dir}/${role}.crt" "${ip}:${REMOTE_BASE_DIR}/certs/${name}/${role}.crt"
        local extra_chown=""
        if [[ "${role}" == swfs-* || "${role}" == "pg-client" ]]; then
            extra_chown="chown 1000:1000 '${REMOTE_BASE_DIR}/certs/${name}/${role}.key' && "
        fi
        remote_exec "${ip}" "${extra_chown}rm -f '/tmp/${role}.csr' && chmod 644 '${REMOTE_BASE_DIR}/certs/${name}/${role}.crt'"
    done
    log_info "  ✅ Сертификаты для ${name} развернуты в ${REMOTE_BASE_DIR}/certs/${name}"
}

_revoke_certs_with_active_ca() {
    local ca_dir="$1" node_cert_dir="$2"
    _write_ca_config "${ca_dir}" "${ACTIVE_CA_KEY}"
    for crt in "${node_cert_dir}"/*.crt; do
        [[ -f "${crt}" ]] || continue
        run_or_dry openssl ca -config "${ca_dir}/openssl-ca.cnf" -revoke "${crt}" 2>/dev/null || true
    done
    run_or_dry openssl ca -config "${ca_dir}/openssl-ca.cnf" -gencrl -out "${ca_dir}/crl.pem" 2>/dev/null || true
    _write_ca_config "${ca_dir}"
}

revoke_node_certs() {
    local old_name="$1"
    local sroot ca_dir node_cert_dir
    sroot=$(state_root)
    ca_dir="${sroot}/.pki/ca"
    node_cert_dir="${sroot}/certs/${old_name}"

    if [[ ! -d "${node_cert_dir}" ]]; then
        log_warn "Каталог сертификатов ${node_cert_dir} не найден, пропускаем CRL-отзыв"
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] CRL-отзыв сертификатов ${old_name} -> ${ca_dir}/crl.pem"
        return 0
    fi
    with_ca_key "${ca_dir}" _revoke_certs_with_active_ca "${ca_dir}" "${node_cert_dir}"
    if [[ -f "${ca_dir}/crl.pem" ]]; then
        local count
        count=$(get_node_count)
        for i in $(seq 1 "${count}"); do
            local cip cname
            cip=$(get_node_ip "$i"); cname=$(get_node_name "$i")
            [[ "${cname}" == "${old_name}" ]] && continue
            remote_copy "${ca_dir}/crl.pem" "${cip}:${REMOTE_BASE_DIR}/certs/${cname}/crl.pem" 2>/dev/null || continue
            remote_copy "${ca_dir}/crl.pem" "${cip}:${REMOTE_BASE_DIR}/certs/${cname}/ca-crl.crt" 2>/dev/null || true
            remote_exec "${cip}" "
                chmod 644 '${REMOTE_BASE_DIR}/certs/${cname}/crl.pem' '${REMOTE_BASE_DIR}/certs/${cname}/ca-crl.crt'
                PCID=\$(cd '${REMOTE_BASE_DIR}' 2>/dev/null && docker compose ps -q patroni 2>/dev/null | head -n1 || true)
                if [[ -n \"\${PCID}\" ]]; then
                    docker exec \"\${PCID}\" bash -c 'cp -L /certs/ca-crl.crt /run/pg-certs/ca-crl.crt && chown postgres:postgres /run/pg-certs/ca-crl.crt && chmod 644 /run/pg-certs/ca-crl.crt' 2>/dev/null || true
                    docker exec -u postgres \"\${PCID}\" psql -U postgres -c 'SELECT pg_reload_conf();' >/dev/null 2>&1 || true
                fi
            " 2>/dev/null || true
        done
    fi
    log_info "  ✅ Сертификаты ${old_name} отозваны и CRL обновлен на живых узлах (${ca_dir}/crl.pem)"
}

distribute_ssh_keys_to_node() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    local keys_dir
    keys_dir="$(state_root)/ssh-host-keys"
    remote_exec "${ip}" "mkdir -p '${REMOTE_BASE_DIR}/ssh-host-keys'"
    for keyfile in "${keys_dir}"/id_*; do
        [[ -f "${keyfile}" ]] || continue
        local bname
        bname=$(basename "${keyfile}")
        remote_copy "${keyfile}" "${ip}:${REMOTE_BASE_DIR}/ssh-host-keys/${bname}"
    done
    remote_exec "${ip}" "chown 1000:1000 '${REMOTE_BASE_DIR}'/ssh-host-keys/id_* && chmod 600 '${REMOTE_BASE_DIR}'/ssh-host-keys/id_* && chmod 644 '${REMOTE_BASE_DIR}'/ssh-host-keys/*.pub"
}

distribute_ssl_to_node() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    local ssl_dir
    ssl_dir="$(state_root)/.ssl/certificates"
    remote_exec "${ip}" "mkdir -p '${REMOTE_BASE_DIR}/certs/ssl'"
    if [[ -f "${ssl_dir}/${DOMAIN}.crt" && -f "${ssl_dir}/${DOMAIN}.key" ]]; then
        remote_copy "${ssl_dir}/${DOMAIN}.crt" "${ip}:${REMOTE_BASE_DIR}/certs/ssl/fullchain.pem"
        remote_copy "${ssl_dir}/${DOMAIN}.key" "${ip}:${REMOTE_BASE_DIR}/certs/ssl/privkey.pem"
        remote_exec "${ip}" "chown 1000:1000 '${REMOTE_BASE_DIR}/certs/ssl/privkey.pem' && chmod 600 '${REMOTE_BASE_DIR}/certs/ssl/privkey.pem' && chmod 644 '${REMOTE_BASE_DIR}/certs/ssl/fullchain.pem'"
    else
        log_warn "  ⚠️  SSL-сертификат ${ssl_dir}/${DOMAIN}.crt отсутствует; пропускаем раскладку на ${name}"
    fi
}

build_patroni_image_on_node() {
    local ip="$1" dc="$2" name="$3" idx="$4"
    local target_ref df_hash
    target_ref=$(resolve_image_ref "${PATRONI_PG_IMAGE}" "${PATRONI_PG_DIGEST:-}")
    df_hash=$(sha256sum "${SCRIPT_DIR}/Dockerfile.patroni" 2>/dev/null | awk '{print $1}' || shasum -a 256 "${SCRIPT_DIR}/Dockerfile.patroni" | awk '{print $1}')
    log_info "Подготовка образа Patroni (${target_ref}) на ${name} (${ip})..."
    local cached
    cached=$(remote_exec_stdin "${ip}" "${PATRONI_PG_IMAGE}" "${REMOTE_BASE_DIR}/build-patroni" "${df_hash}" <<'REMOTE_CACHE_CHK' || echo "MISS"
IMG="$1"; BUILD_DIR="$2"; DF_HASH="$3"
HASH_FILE="${BUILD_DIR}/.built.sha256"
if docker image inspect "${IMG}" >/dev/null 2>&1; then
    cur_hash=""
    if [[ -f "${HASH_FILE}" ]]; then
        cur_hash=$(cat "${HASH_FILE}" 2>/dev/null || true)
    elif [[ -f "${BUILD_DIR}/Dockerfile.patroni" ]]; then
        cur_hash=$(sha256sum "${BUILD_DIR}/Dockerfile.patroni" 2>/dev/null | awk '{print $1}' || true)
    fi
    if [[ "${cur_hash}" == "${DF_HASH}" ]]; then
        printf "%s\n" "${DF_HASH}" > "${HASH_FILE}"
        echo "HIT"
        exit 0
    fi
fi
echo "MISS"
REMOTE_CACHE_CHK
    )
    if [[ "${cached}" == *"HIT"* && "${DRY_RUN:-false}" != "true" ]]; then
        log_info "  ✅ Образ ${PATRONI_PG_IMAGE} уже собран и актуален на ${name} — пропуск пересборки"
        return 0
    fi

    # Если на другой ноде кластера актуальный образ Patroni уже собран — копируем его по P2P SSH за ~15с без повторной сборки!
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        local peer_ip ssh_opts peer_hit
        ssh_opts=$(_ssh_base_opts)
        if [[ -n "${ADMIN_SSH_PORT:-}" && "${ADMIN_SSH_PORT}" != "22" ]]; then
            ssh_opts+=" -p ${ADMIN_SSH_PORT}"
        fi
        while IFS= read -r peer_ip; do
            [[ -z "${peer_ip}" || "${peer_ip}" == "${ip}" ]] && continue
            peer_hit=$(remote_exec_stdin "${peer_ip}" "${PATRONI_PG_IMAGE}" "${REMOTE_BASE_DIR}/build-patroni" "${df_hash}" <<'REMOTE_PEER_CHK' 2>/dev/null || echo "MISS"
IMG="$1"; BUILD_DIR="$2"; DF_HASH="$3"
HASH_FILE="${BUILD_DIR}/.built.sha256"
if docker image inspect "${IMG}" >/dev/null 2>&1 && [[ -f "${HASH_FILE}" ]] && [[ "$(cat "${HASH_FILE}" 2>/dev/null || true)" == "${DF_HASH}" ]]; then
    echo "HIT"
else
    echo "MISS"
fi
REMOTE_PEER_CHK
            )
            if [[ "${peer_hit}" == *"HIT"* ]]; then
                log_info "  🔄 Копируем готовый образ ${PATRONI_PG_IMAGE} на ${name} (${ip}) с узла ${peer_ip} по SSH..."
                # shellcheck disable=SC2086
                if ssh ${ssh_opts} "root@${peer_ip}" "docker save '${PATRONI_PG_IMAGE}' | gzip -1" \
                    | ssh ${ssh_opts} "root@${ip}" "gunzip | docker load" >/dev/null 2>&1; then
                    remote_exec "${ip}" "mkdir -p '${REMOTE_BASE_DIR}/build-patroni' && printf '%s\n' '${df_hash}' > '${REMOTE_BASE_DIR}/build-patroni/.built.sha256'"
                    log_info "  ✅ Образ ${PATRONI_PG_IMAGE} доставлен на ${name} без локальной пересборки"
                    return 0
                fi
            fi
        done < <(get_node_ips)
    fi

    remote_exec "${ip}" "mkdir -p '${REMOTE_BASE_DIR}/build-patroni'"
    remote_copy "${SCRIPT_DIR}/Dockerfile.patroni" "${ip}:${REMOTE_BASE_DIR}/build-patroni/Dockerfile.patroni"
    ensure_remote_image "${ip}" "postgres:16-bookworm" || true
    remote_exec_stdin "${ip}" "${PATRONI_PG_IMAGE}" "${target_ref}" "${REMOTE_BASE_DIR}/build-patroni" "${df_hash}" <<'REMOTE_BUILD'
set -euo pipefail
IMG="$1"; TARGET_REF="$2"; BUILD_DIR="$3"; DF_HASH="$4"
HASH_FILE="${BUILD_DIR}/.built.sha256"

if docker image inspect "${IMG}" >/dev/null 2>&1; then
    docker tag "${IMG}" "local/patroni-pg16:rollback" >/dev/null 2>&1 || true
fi

PULLED_REF=""
for cand in "${TARGET_REF}" "ghcr.io/aligorov/ligament_vault_patroni:16"; do
    [[ -n "${cand}" && "${cand}" != local/* ]] || continue
    if docker pull -q "${cand}" >/dev/null 2>&1; then
        if [[ "${cand}" != "${IMG}" ]]; then
            docker tag "${cand}" "${IMG}"
        fi
        PULLED_REF="${cand}"
        break
    fi
done

if [[ -n "${PULLED_REF}" ]]; then
    echo "Pulled ${PULLED_REF} -> ${IMG}"
    printf "%s\n" "${DF_HASH}" > "${HASH_FILE}"
else
    echo "Registry pull unavailable — building ${IMG} locally from Dockerfile.patroni (1-2 min)..."
    cd "${BUILD_DIR}"
    BUILD_LOG=$(mktemp)
    if ! docker build --progress=plain -t "${IMG}" -f Dockerfile.patroni . >"${BUILD_LOG}" 2>&1; then
        echo "ERROR: docker build failed for ${IMG}:" >&2
        tail -n 45 "${BUILD_LOG}" >&2
        rm -f "${BUILD_LOG}"
        exit 1
    fi
    grep -E '^#[0-9]+ \[[0-9]+/[0-9]+\]|^Step [0-9]+/|Successfully|DONE' "${BUILD_LOG}" || true
    rm -f "${BUILD_LOG}"
    printf "%s\n" "${DF_HASH}" > "${HASH_FILE}"
    docker builder prune -af >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
fi
REMOTE_BUILD
}

cloudflare_dns_update() {
    local target_ip="$1"
    if [[ -z "${CF_DNS_API_TOKEN:-}" || "${CF_DNS_API_TOKEN}" == *FIXME* ]]; then
        log_warn "CF_DNS_API_TOKEN не задан — пропуск автоматического обновления DNS A-записи"
        return 1
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Cloudflare DNS: ${DOMAIN} -> ${target_ip} (TTL=${DNS_TTL:-60})"
        return 0
    fi

    python3 - "${DOMAIN}" "${target_ip}" "${DNS_TTL:-60}" "${CLOUDFLARE_ZONE_ID:-}" <<'PYEOF'
import json, os, sys, urllib.request

domain, ip, ttl, zone_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
token = os.environ["CF_DNS_API_TOKEN"]
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def api(method, path, data=None):
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4{path}",
        data=json.dumps(data).encode() if data is not None else None,
        headers=headers,
        method=method,
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read().decode())
    if not body.get("success"):
        raise RuntimeError(f"Cloudflare API error: {body}")
    return body["result"]

if not zone_id:
    parts = domain.split(".")
    for i in range(len(parts) - 1):
        cand = ".".join(parts[i:])
        res = api("GET", f"/zones?name={cand}")
        if res:
            zone_id = res[0]["id"]
            break
    if not zone_id:
        raise RuntimeError(f"Не найден Cloudflare Zone ID для {domain}")

records = api("GET", f"/zones/{zone_id}/dns_records?type=A&name={domain}")
payload = {"type": "A", "name": domain, "content": ip, "ttl": ttl, "proxied": False}
if records:
    rec_id = records[0]["id"]
    api("PUT", f"/zones/{zone_id}/dns_records/{rec_id}", payload)
else:
    api("POST", f"/zones/{zone_id}/dns_records", payload)
print(f"Cloudflare DNS A updated: {domain} -> {ip} (TTL={ttl})")
PYEOF
}

assign_floating_ip() {
    local target_ip="$1"
    local provider="${FLOATING_IP_PROVIDER:-}"
    local fip_id="${FLOATING_IP_ID:-}"

    if [[ -n "${FLOATING_IP_HOOK:-}" && -x "${FLOATING_IP_HOOK}" ]]; then
        run_or_dry "${FLOATING_IP_HOOK}" "${target_ip}" "${fip_id}"
        return $?
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Floating IP (${provider:-custom}, id=${fip_id}) -> ${target_ip}"
        return 0
    fi

    case "${provider}" in
        hetzner)
            [[ -n "${HETZNER_CLOUD_TOKEN:-}" && -n "${fip_id}" ]] || { log_warn "Не заданы HETZNER_CLOUD_TOKEN или FLOATING_IP_ID"; return 1; }
            python3 - "${fip_id}" "${target_ip}" <<'PYEOF'
import json, os, sys, urllib.request
fip_id, ip = sys.argv[1:]
tok = os.environ["HETZNER_CLOUD_TOKEN"]
hdr = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
req = urllib.request.Request("https://api.hetzner.cloud/v1/servers", headers=hdr)
servers = json.loads(urllib.request.urlopen(req, timeout=10).read().decode()).get("servers", [])
srv_id = next((s["id"] for s in servers if s.get("public_net", {}).get("ipv4", {}).get("ip") == ip), None)
if not srv_id:
    raise RuntimeError(f"Hetzner server with IP {ip} not found")
act = urllib.request.Request(
    f"https://api.hetzner.cloud/v1/floating_ips/{fip_id}/actions/assign",
    data=json.dumps({"server": srv_id}).encode(),
    headers=hdr,
    method="POST",
)
urllib.request.urlopen(act, timeout=10).read()
print(f"Hetzner Floating IP {fip_id} assigned to server {srv_id} ({ip})")
PYEOF
            ;;
        digitalocean)
            [[ -n "${DO_API_TOKEN:-}" && -n "${fip_id}" ]] || { log_warn "Не заданы DO_API_TOKEN или FLOATING_IP_ID"; return 1; }
            python3 - "${fip_id}" "${target_ip}" <<'PYEOF'
import json, os, sys, urllib.request
fip, ip = sys.argv[1:]
tok = os.environ["DO_API_TOKEN"]
hdr = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
req = urllib.request.Request("https://api.digitalocean.com/v2/droplets?per_page=200", headers=hdr)
droplets = json.loads(urllib.request.urlopen(req, timeout=10).read().decode()).get("droplets", [])
did = next((d["id"] for d in droplets for n in d.get("networks", {}).get("v4", []) if n.get("ip_address") == ip), None)
if not did:
    raise RuntimeError(f"DO droplet with IP {ip} not found")
act = urllib.request.Request(
    f"https://api.digitalocean.com/v2/reserved_ips/{fip}/actions",
    data=json.dumps({"type": "assign", "droplet_id": did}).encode(),
    headers=hdr,
    method="POST",
)
urllib.request.urlopen(act, timeout=10).read()
print(f"DigitalOcean Reserved IP {fip} assigned to droplet {did} ({ip})")
PYEOF
            ;;
        *)
            log_warn "FLOATING_IP_PROVIDER='${provider}' не настроен (укажите hetzner, digitalocean или FLOATING_IP_HOOK)"
            return 1
            ;;
    esac
}

update_dns_provider() {
    local target_ip="$1"
    local mode="${FAILOVER_MODE:-dns}"
    local rc=0

    if [[ "${mode}" == "floating-ip" || "${mode}" == "hybrid" ]]; then
        assign_floating_ip "${target_ip}" || rc=1
    fi

    if [[ "${mode}" == "dns" || "${mode}" == "hybrid" ]]; then
        if [[ "${DNS_PROVIDER:-cloudflare}" == "cloudflare" ]]; then
            cloudflare_dns_update "${target_ip}" || rc=1
        elif [[ -n "${DNS_UPDATE_HOOK:-}" && -x "${DNS_UPDATE_HOOK}" ]]; then
            run_or_dry "${DNS_UPDATE_HOOK}" "${DOMAIN}" "${target_ip}" "${DNS_TTL:-60}" || rc=1
        else
            log_warn "DNS провайдер '${DNS_PROVIDER:-}': обновите A-запись ${DOMAIN} -> ${target_ip} вручную или задайте DNS_UPDATE_HOOK"
            rc=1
        fi
    fi
    return "${rc}"
}

# --- Экспорт минимального набора DNS/VIP-токенов (совместим с secrets.env.age в RAM!) ---
write_clean_lego_env() {
    local out_file="$1"
    mkdir -p "$(dirname "${out_file}")"
    local sec_file
    sec_file="$(state_root)/secrets.env"
    python3 - "${sec_file}" "${out_file}" <<'PYEOF'
import os, shlex, sys

sec_path, out_path = sys.argv[1], sys.argv[2]
dns_prefixes = (
    "CF_", "CLOUDFLARE_", "AWS_", "HETZNER_", "DO_", "DIGITALOCEAN_",
    "ROUTE53_", "OVH_", "GANDI_", "LINODE_", "PORKBUN_", "NAMECHEAP_", "DESEC_",
)
internal_block = {
    "SFTPGO_KMS_MASTER_KEY", "SFTPGO_SIGNING_PASSPHRASE", "SFTPGO_INSTALLATION_CODE",
    "SFTPGO_ADMIN_PASSWORD", "PG_SUPERUSER_PASSWORD", "PG_REPLICATION_PASSWORD",
    "PATRONI_API_PASSWORD", "SFTPGO_DB_PASSWORD", "SWFS_FILER_DB_PASSWORD",
    "SWFS_ADMIN_PASSWORD", "ETCD_ROOT_PASSWORD", "BACKUP_ENCRYPTION_KEY",
    "CA_KEY_PASSPHRASE", "LIGAMENT_2FA_API_TOKEN",
}
collected = {}

for k, v in os.environ.items():
    if k.startswith(dns_prefixes) and v and "FIXME" not in v:
        collected[k] = v

if os.path.exists(sec_path):
    for raw in open(sec_path, encoding="utf-8"):
        s = raw.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        try:
            tokens = shlex.split(s, comments=True)
            if tokens and "=" in tokens[0]:
                k, v = tokens[0].split("=", 1)
                if k in internal_block or k.startswith(("SWFS_", "BACKUP_S3_", "PG_", "SFTPGO_")):
                    continue
                if v and "FIXME" not in v:
                    collected[k] = v
        except Exception:
            pass

with open(out_path, "w", encoding="utf-8") as f:
    for k in sorted(collected):
        f.write(f"{k}={collected[k]}\n")
os.chmod(out_path, 0o600)
PYEOF
}

sftpgo_provision_s3_folders() {
    local node_ip="$1"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] SFTPGo REST API: создание Virtual Folders 'sftp-work' и 'sftp-worm' (-> 127.0.0.1:${SWFS_S3_PORT:-8333})"
        return 0
    fi

    log_info "Настройка S3 Virtual Folders (sftp-work, sftp-worm) в SFTPGo через REST API..."
    remote_exec_env_stdin "${node_ip}" "SFTPGO_ADMIN_PASSWORD,SWFS_S3_SECRET_KEY_SFTPGO" \
        "${SFTPGO_ADMIN_USERNAME:-admin}" "${SWFS_S3_PORT:-8333}" "sftpgo-s3-access" <<'REMOTE_PROV'
set -euo pipefail
ADMIN_USER="$1"; S3_PORT="$2"; S3_AK="$3"

python3 - "${ADMIN_USER}" "${S3_PORT}" "${S3_AK}" <<'PYEOF'
import base64, json, os, sys, urllib.error, urllib.request

user, s3_port, ak = sys.argv[1:]
pw = os.environ["SFTPGO_ADMIN_PASSWORD"]
sk = os.environ["SWFS_S3_SECRET_KEY_SFTPGO"]
base = "http://127.0.0.1:8081/api/v2"

def req(method, path, body=None, headers=None):
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

basic = base64.b64encode(f"{user}:{pw}".encode()).decode()
try:
    st, tok_resp = req("GET", "/token", headers={"Authorization": f"Basic {basic}"})
    if st != 200 or not isinstance(tok_resp, dict) or "access_token" not in tok_resp:
        raise RuntimeError(f"Не удалось получить токен SFTPGo admin (HTTP {st}): {tok_resp}")
    auth = {"Authorization": f"Bearer {tok_resp['access_token']}"}

    for bucket_name in ("sftp-work", "sftp-worm"):
        folder_payload = {
            "name": bucket_name,
            "description": f"SeaweedFS S3 bucket {bucket_name}",
            "filesystem": {
                "provider": 1,
                "s3config": {
                    "bucket": bucket_name,
                    "region": "us-east-1",
                    "endpoint": f"http://127.0.0.1:{s3_port}",
                    "access_key": ak,
                    "access_secret": {"status": "Plain", "payload": sk},
                    "force_path_style": True,
                },
            },
        }
        st_f, _ = req("GET", f"/folders/{bucket_name}", headers=auth)
        if st_f == 200:
            st_u, body_u = req("PUT", f"/folders/{bucket_name}", body=folder_payload, headers=auth)
            if st_u not in (200, 204):
                raise RuntimeError(f"PUT folder {bucket_name} -> HTTP {st_u}: {body_u}")
        else:
            st_c, body_c = req("POST", "/folders", body=folder_payload, headers=auth)
            if st_c not in (200, 201):
                raise RuntimeError(f"POST folder {bucket_name} -> HTTP {st_c}: {body_c}")
        print(f"SFTPGo virtual folder ensured: {bucket_name}")
except Exception as exc:
    sys.stderr.write(f"Ошибка SFTPGo S3 folders: {exc}\n")
    sys.exit(1)
PYEOF
REMOTE_PROV
}
