#!/usr/bin/env bash
set -euo pipefail
cd "$1"
peers="$2" filer_port="$3" old_host="$4" master_port="$5"
cid=$(docker compose ps -q swfs-filer)
[[ -n "$cid" ]]
shell() { docker exec -i "$cid" weed shell -master="$peers" -filer="127.0.0.1:$filer_port"; }
for _ in $(seq 1 35); do
    roster=$(shell <<< 'cluster.raft.ps') || { sleep 3; continue; }
    # Each row supplies the actual member ID, its transport address and its vote.
    ids=$(awk '$1=="*" && ($NF=="(Voter)" || $NF=="(Leader)") {print $2}' <<< "$roster")
    ready=true
    IFS=',' read -ra expected <<< "$peers"
    for address in "${expected[@]}"; do
        awk -v target="$address" '{id=$0; sub(/\.[0-9]+$/, "", id); if (id==target || $0==target) seen=1} END {exit !seen}' <<< "$ids" || ready=false
    done
    if [[ "$ready" == true ]]; then
        if [[ -n "$old_host" ]]; then
            old_id=$(awk -v target="$old_host:$master_port" '{id=$0; sub(/\.[0-9]+$/, "", id); if (id==target || $0==target) print $0}' <<< "$ids")
            if [[ -n "$old_id" ]]; then
                [[ "$old_id" =~ ^[A-Za-z0-9.:-]+$ ]]
                shell <<< "cluster.raft.remove -id $old_id"
                sleep 2
                continue
            fi
        fi
        count=$(awk 'NF {n++} END {print n+0}' <<< "$ids")
        [[ "$count" == "${#expected[@]}" ]] && exit 0
    fi
    sleep 3
done
echo "SeaweedFS Raft voters do not match $peers: ${roster:-no leader}" >&2
exit 1
