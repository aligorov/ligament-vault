#!/usr/bin/env bash
set -euo pipefail
cd "$1"
port="$2" key="$3" action="$4" token="$5"
cid=$(docker compose ps -q etcd)
[[ -n "$cid" ]] || exit 1
ctl() {
    docker exec -i "$cid" etcdctl --endpoints="https://127.0.0.1:$port" --dial-timeout=2s --command-timeout=5s \
        --cacert=/certs/ca.crt --cert=/certs/etcd-client.crt --key=/certs/etcd-client.key "$@"
}
if [[ "$action" == force ]]; then ctl del "$key" >/dev/null; echo UNLOCKED; exit 0; fi
if [[ "$action" == acquire ]]; then
    reply=$(ctl txn <<TXN
create("$key") = "0"

put "$key" "$token"

get "$key"

TXN
)
    if [[ "${reply%%$'\n'*}" == SUCCESS || "${reply##*$'\n'}" == "$token" ]]; then echo LOCKED; else echo BUSY; fi
else
    reply=$(ctl txn <<TXN
value("$key") = "$token"

del "$key"

get "$key"

TXN
)
    if [[ "${reply%%$'\n'*}" == SUCCESS ]]; then echo UNLOCKED; else echo NOT_OWNER; fi
fi
