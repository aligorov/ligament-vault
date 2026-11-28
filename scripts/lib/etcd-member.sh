#!/usr/bin/env bash
# Runs on a healthy voter. Reconcile the actual membership after any interrupted request.
set -euo pipefail
cd "$1"
port="$2" action="$3" member="$4" url="$5" previous_url="${6:-}"
cid=$(docker compose ps -q etcd)
[[ -n "$cid" ]] || { echo "etcd is not running" >&2; exit 1; }
ctl() {
    docker exec "$cid" etcdctl --endpoints="https://127.0.0.1:${port}" --dial-timeout=3s --command-timeout=8s \
        --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key "$@"
}
member_state() {
    ctl member list -w json | python3 -c '
import json, sys
name, url, previous = sys.argv[1:]
selected = []
for item in json.load(sys.stdin)["members"]:
    peers = item["peerURLs"]
    if item.get("name") == name or url in peers or (previous and previous in peers):
        if item.get("name", "") not in ("", name):
            sys.exit("Peer address belongs to another participant")
        if peers == [url]:
            location = "target"
        elif previous and peers == [previous]:
            location = "old"
        else:
            sys.exit("Participant has an unexpected peer URL")
        selected.append((location, format(item["ID"], "x"), "learner" if item.get("isLearner") else "voter"))
if len(selected) > 1:
    sys.exit("Conflicting etcd identities")
print(" ".join(selected[0]) if selected else "absent")
' "$member" "$url" "$previous_url"
}
if [[ "$action" == check-survivors ]]; then
    # A healthy helper can still rely on the node about to be stopped for its majority.
    endpoints=$(ctl member list -w json | python3 -c '
import json, sys
name, peer = sys.argv[1:]
for item in json.load(sys.stdin)["members"]:
    if item.get("isLearner"):
        continue
    if item.get("name") == name or peer in item["peerURLs"]:
        print("-")
    else:
        print(",".join(item.get("clientURLs", [])) or "-")
' "$member" "$url")
    voters=0; healthy=0
    while IFS= read -r endpoint; do
        [[ -n "$endpoint" ]] || continue
        voters=$((voters + 1))
        if [[ "$endpoint" != "-" ]] && ctl --endpoints="$endpoint" endpoint health >/dev/null 2>&1; then
            healthy=$((healthy + 1))
        fi
    done <<< "$endpoints"
    required=$((voters / 2 + 1))
    if (( healthy < required )); then
        echo "Остановка $member опасна: доступно других голосующих $healthy, требуется $required из $voters" >&2
        exit 1
    fi
    exit 0
fi
case "$action" in
    prepare|prepare-empty|promote|remove) ;;
    *) exit 2 ;;
esac
for _ in $(seq 1 45); do
    state=$(member_state)
    read -r location id role <<< "$state"
    case "$action:$location" in
        remove:absent|prepare:target) exit 0 ;;
        prepare-empty:target)
            if [[ "$role" == learner ]]; then exit 0; fi
            ctl member remove "$id" || :
            ;;
        remove:target|prepare:old)
            ctl member remove "$id" || :
            ;;
        prepare:absent|prepare-empty:absent)
            ctl member add "$member" --peer-urls="$url" --learner || :
            ;;
        promote:target)
            if [[ "$role" == voter ]]; then exit 0; fi
            # The leader alone decides when the learner has caught up sufficiently.
            ctl member promote "$id" || :
            ;;
        *) echo "Unexpected etcd member state: $action $state" >&2; exit 1 ;;
    esac
    sleep 2
done
echo "Timed out reconciling etcd member $member ($action)" >&2
exit 1
