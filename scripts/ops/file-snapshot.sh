#!/usr/bin/env bash
# Physical SeaweedFS backup and PostgreSQL WAL must resolve to the same point.
snapshot_controller() {
    local endpoint region bucket access secret pass
    endpoint=$(config_db_get BACKUP_S3_ENDPOINT) && region=$(config_db_get BACKUP_S3_REGION) &&
        bucket=$(config_db_get BACKUP_S3_BUCKET) && access=$(config_db_get BACKUP_S3_ACCESS_KEY) &&
        secret=$(config_db_get BACKUP_S3_SECRET_KEY) && pass=$(config_db_get BACKUP_ENCRYPTION_KEY) || return 1
    [[ "${endpoint}" == *://* ]] || endpoint="https://${endpoint}"
    python3 "${SCRIPT_DIR}/scripts/ops/file-snapshot.py" "$@" --database-settings --slug "${CLUSTER_SLUG}" \
        3< <(printf '%s\0' "${endpoint}" "${region:-us-east-1}" "${bucket}" "${access}" "${secret}"; printf %s "${pass}")
}

snapshot_on_node() {
    local node="$1" action="$2"
    shift 2
    local host
    host=$(get_node_ip "${node}") || return 1
    remote_copy "${SCRIPT_DIR}/scripts/ops/file-snapshot.py" "${host}:${REMOTE_BASE_DIR}/file-snapshot.py" || return 1
    remote_exec_stdin "${host}" "${REMOTE_BASE_DIR}" "${action}" "${CLUSTER_SLUG}" "${node}" "${SNAPSHOT_ID}" "${SWFS_S3_PORT:-8333}" "$@" <<'REMOTE_SNAPSHOT'
set -euo pipefail
base="$1"; action="$2"; slug="$3"; node="$4"; id="$5"; port="$6"; shift 6
cd "${base}"
case "${action}" in
    capture|stable|restore|destination)
        dirs=$(docker compose --profile '*' config --format json | python3 -c '
import json, sys, shlex
service = json.load(sys.stdin)["services"]["swfs-volume"]
args = service["command"]
if isinstance(args,str): args = shlex.split(args)
dirs = next(a[5:].split(",") for a in args if a.startswith("-dir="))
mounts = {v["target"]:v["source"] for v in service["volumes"] if v["type"]=="bind"}
print(",".join(mounts[d] for d in dirs))')
        if [[ "${action}" == restore || "${action}" == destination ]]; then
            [[ -z "$(docker compose ps -q swfs-volume)" ]] || { echo "Stop the destination volume server before DR" >&2; exit 1; }
        else
            [[ -n "$(docker compose ps --status running -q swfs-volume)" ]] || { echo "Source volume server is offline" >&2; exit 1; }
        fi
        set -- --dirs "${dirs}" "$@"
        ;;
esac
python3 ./file-snapshot.py "${action}" --base "${base}" --slug "${slug}" --node "${node}" --id "${id}" --port "${port}" "$@"
REMOTE_SNAPSHOT
}
