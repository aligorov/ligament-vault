#!/usr/bin/env bash
# ============================================================================
# cluster-health.sh — Сводная диагностика и статус кластера
# ============================================================================
# Вызов: ./clusterctl status [--json] [--strict]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"

JSON_OUT=false
STRICT_MODE=false
WARNINGS=0
ERRORS=0
NODES_JSON=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)   JSON_OUT=true; shift ;;
        --strict) STRICT_MODE=true; shift ;;
        *)        log_error "Неизвестный флаг status: $1"; exit 1 ;;
    esac
done

check_node_health() {
    local ip="$1" dc="$2" name="$3"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        if [[ "${JSON_OUT}" == "true" ]]; then
            NODES_JSON+=("{\"node\":\"${name}\",\"ip\":\"${ip}\",\"dc\":\"${dc}\",\"status\":\"dry-run\"}")
        else
            log_info "[DRY-RUN] Диагностика ${name} (${ip}, ${dc})"
        fi
        return 0
    fi

    local raw ntp_offset="N/A" disk_pct="N/A" patroni_role="DOWN" swfs_vol="DOWN" swfs_filer="DOWN" sftpgo_up="DOWN" haproxy_up="DOWN"
    raw=$(remote_exec_stdin "${ip}" "${PATRONI_API_PORT:-8008}" "${SWFS_VOLUME_PORT:-8082}" "${SWFS_FILER_PORT:-8888}" "${HAPROXY_PG_PORT:-5433}" <<'REMOTE_HEALTH' || true
PPORT="$1"; VPORT="$2"; FPORT="$3"; HPORT="$4"
NTP=$(chronyc tracking 2>/dev/null | awk '/System time/{printf "%.1fms", $4*1000}' || echo "N/A")
DISK=$(df -h / | awk 'NR==2{print $5}' || echo "N/A")
PROLE=$(curl -sf --max-time 3 "http://127.0.0.1:${PPORT}/patroni" 2>/dev/null | jq -r '.role // "ERR"' || echo "DOWN")
VSTAT=$(curl -sf --max-time 3 "http://127.0.0.1:${VPORT}/healthz" >/dev/null 2>&1 || curl -sf --max-time 3 "http://127.0.0.1:${VPORT}/status" >/dev/null 2>&1 && echo "OK" || echo "DOWN")
FSTAT=$(curl -sf --max-time 3 "http://127.0.0.1:${FPORT}/healthz" >/dev/null 2>&1 && echo "OK" || echo "DOWN")
HSTAT=$(nc -z 127.0.0.1 "${HPORT}" 2>/dev/null && echo "OK" || echo "DOWN")
SSTAT=$(docker exec "$(docker ps -qf name=sftpgo)" sftpgo ping --config-file /etc/sftpgo/sftpgo.json >/dev/null 2>&1 && echo "OK" || echo "DOWN")
echo "${NTP}|${DISK}|${PROLE}|${VSTAT}|${FSTAT}|${HSTAT}|${SSTAT}"
REMOTE_HEALTH
    )
    IFS='|' read -r ntp_offset disk_pct patroni_role swfs_vol swfs_filer haproxy_up sftpgo_up <<< "${raw}"

    [[ "${patroni_role}" == "DOWN" || "${patroni_role}" == "ERR" ]] && ERRORS=$((ERRORS + 1))
    [[ "${swfs_vol}" == "DOWN" || "${swfs_filer}" == "DOWN" ]]     && ERRORS=$((ERRORS + 1))
    [[ "${haproxy_up}" == "DOWN" || "${sftpgo_up}" == "DOWN" ]]    && WARNINGS=$((WARNINGS + 1))

    if [[ "${JSON_OUT}" == "true" ]]; then
        NODES_JSON+=("{\"node\":\"${name}\",\"ip\":\"${ip}\",\"dc\":\"${dc}\",\"ntp_offset\":\"${ntp_offset}\",\"disk_root\":\"${disk_pct}\",\"patroni_role\":\"${patroni_role}\",\"swfs_volume\":\"${swfs_vol}\",\"swfs_filer\":\"${swfs_filer}\",\"haproxy\":\"${haproxy_up}\",\"sftpgo\":\"${sftpgo_up}\"}")
    else
        printf "  %-8s %-15s %-5s NTP:%-9s Disk:%-5s PG:%-8s HAProxy:%-4s Vol:%-4s Filer:%-4s SFTPGo:%s\n" \
            "${name}" "${ip}" "${dc}" "${ntp_offset}" "${disk_pct}" "${patroni_role}" "${haproxy_up}" "${swfs_vol}" "${swfs_filer}" "${sftpgo_up}"
    fi
}

if [[ "${JSON_OUT}" != "true" ]]; then
    log_step "Состояние узлов кластера"
fi
for_each_node check_node_health

swfs_repl_ok=true
ssl_days="N/A"
last_backup="N/A"

if [[ "${DRY_RUN:-false}" != "true" ]]; then
    local_ip=$(get_node_ip 1)

    if [[ "${JSON_OUT}" != "true" ]]; then
        log_step "Кворум etcd и Patroni"
        remote_exec "${local_ip}" "
            docker exec \$(docker ps -qf name=etcd) etcdctl --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT:-2379} \
                --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key \
                endpoint status -w table 2>/dev/null || true
            docker exec \$(docker ps -qf name=patroni) patronictl list 2>/dev/null || true
        " || WARNINGS=$((WARNINGS + 1))
    fi

    master_peers=$(echo "${CLUSTER_NODES}" | xargs -n1 | head -n3 | awk -F: -v p="${SWFS_MASTER_PORT:-9333}" '{print $1 ":" p}' | paste -sd, -)
    dry_fix=$(remote_exec "${local_ip}" "docker exec -i \$(docker ps -qf name=swfs-filer) weed shell -master='${master_peers}' <<< 'volume.fix.replication'" 2>/dev/null || echo "ERR")
    if echo "${dry_fix}" | grep -qiE "replicate|under-replicated|ERR"; then
        swfs_repl_ok=false
        WARNINGS=$((WARNINGS + 1))
        if [[ "${JSON_OUT}" != "true" ]]; then
            log_warn "SeaweedFS: обнаружены недореплицированные тома (volume.fix.replication dry-run)"
        fi
    else
        if [[ "${JSON_OUT}" != "true" ]]; then
            log_info "  ✅ Репликация томов SeaweedFS в норме"
        fi
    fi

    cert_path="${CONFIG_ROOT:-${SCRIPT_DIR}}/.ssl/certificates/${DOMAIN}.crt"
    if [[ -f "${cert_path}" ]]; then
        ssl_days=$(python3 - "${cert_path}" <<'PYEOF'
import datetime, subprocess, sys
out = subprocess.check_output(["openssl", "x509", "-in", sys.argv[1], "-noout", "-enddate"], text=True).strip()
dt_str = out.split("=", 1)[1].replace(" GMT", "").strip()
exp = datetime.datetime.strptime(dt_str, "%b %d %H:%M:%S %Y").replace(tzinfo=datetime.timezone.utc)
print((exp - datetime.datetime.now(datetime.timezone.utc)).days)
PYEOF
        ) || ssl_days="N/A"
        if [[ "${ssl_days}" != "N/A" ]] && (( ssl_days < 14 )); then
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        WARNINGS=$((WARNINGS + 1))
    fi

    last_backup=$(remote_exec "${local_ip}" "docker exec -u postgres \$(docker ps -qf name=patroni) pgbackrest --stanza='${CLUSTER_SLUG}' info --output=json 2>/dev/null | jq -r '.[0].backup[-1].label // \"none\"'" 2>/dev/null || echo "N/A")

    if [[ "${JSON_OUT}" != "true" ]]; then
        log_step "SSL и Бэкапы"
        log_info "  SSL (${DOMAIN}): осталось дней = ${ssl_days}"
        log_info "  Последний pgBackRest бэкап: ${last_backup}"
    fi
fi

if [[ "${JSON_OUT}" == "true" ]]; then
    nodes_joined=$(IFS=,; echo "${NODES_JSON[*]}")
    printf '{"nodes":[%s],"swfs_replication_healthy":%s,"ssl_days_remaining":"%s","last_backup":"%s","warnings":%d,"errors":%d}\n' \
        "${nodes_joined}" "${swfs_repl_ok}" "${ssl_days}" "${last_backup}" "${WARNINGS}" "${ERRORS}"
fi

if (( ERRORS > 0 )); then
    if [[ "${JSON_OUT}" != "true" ]]; then
        log_error "Статус: CRITICAL (errors=${ERRORS}, warnings=${WARNINGS})"
    fi
    exit 1
fi

if [[ "${STRICT_MODE}" == "true" && "${WARNINGS}" -gt 0 ]]; then
    if [[ "${JSON_OUT}" != "true" ]]; then
        log_error "Статус (--strict): найдены предупреждения (${WARNINGS})"
    fi
    exit 1
fi

if [[ "${JSON_OUT}" != "true" ]]; then
    log_info "✅ Кластер здоров (warnings=${WARNINGS})"
fi
