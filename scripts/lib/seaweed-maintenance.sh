#!/usr/bin/env bash
# Runs on a live filer after the replacement volume has joined its data centre.
set -euo pipefail
cd "$1"
peers="$2" port="$3" balance="$4"
cid=$(docker compose ps -q swfs-filer)
[[ -n "$cid" ]] || { echo "SeaweedFS filer is not running" >&2; exit 1; }
weed_shell() {
    docker exec -i "$cid" weed shell -master="$peers" -filer="127.0.0.1:$port"
}
# Wait for the leader to apply volume heartbeats before it computes missing replicas.
# A stale heartbeat can otherwise make a removed disk look like a healthy second copy.
required="${5:-}" dc="${6:-}" retired="${7:-}"
if [[ -n "$required" || -n "$retired" ]]; then
    IFS=',' read -ra masters <<< "$peers"
    visible=false
    for _ in $(seq 1 30); do
        for master in "${masters[@]}"; do
            if ! curl -fsS --max-time 3 "http://$master/cluster/status" | jq -e '.IsLeader == true' >/dev/null; then continue; fi
            if curl -fsS --max-time 4 "http://$master/dir/status" | jq -e --arg new "$required" --arg dc "$dc" --arg old "$retired" '
                [.Topology.DataCenters[] | .Id as $zone | .Racks[] | .DataNodes[] | {zone:$zone, url:.Url}] as $nodes
                | ($nodes | length > 0)
                and ($new == "" or any($nodes[]; .zone == $dc and .url == $new))
                and ($old == "" or all($nodes[]; .url != $old))
            ' >/dev/null; then visible=true; break 2; fi
        done
        sleep 2
    done
    [[ "$visible" == true ]] || { echo "SeaweedFS topology has not converged: $required ($dc), retired $retired" >&2; exit 1; }
fi
# weed shell owns its lock per session. A failure terminates the session and releases it.
{
    echo lock
    if [[ "$balance" == true ]]; then echo 'volume.balance -apply'; fi
    echo 'volume.fix.replication -apply'
    echo unlock
} | weed_shell
for _ in $(seq 1 12); do
    result=$(weed_shell <<< $'lock\nvolume.fix.replication\nunlock' 2>&1) || { echo "$result" >&2; exit 1; }
    if ! grep -Eqi 'under[ -]replicated|over[ -]replicated|replicating volume|deleting volume|error:' <<< "$result"; then exit 0; fi
    sleep 2
done
echo "SeaweedFS volume placement did not converge: $result" >&2
exit 1
