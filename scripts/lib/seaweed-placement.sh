#!/usr/bin/env bash
# Read the metadata of every mounted volume, including full and read-only volumes.
set -euo pipefail
python3 - "$@" <<'PY'
import collections
import json
import re
import subprocess
import sys

masters, policy = sys.argv[1:]
if not re.fullmatch(r"[0-9]{3}", policy):
    sys.exit("Некорректная политика репликации: " + policy)
dc_count, rack_count, node_count = map(int, policy)

def fetch(server, path):
    result = subprocess.run(
        ["curl", "-fsS", "--max-time", "6", "http://" + server + path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    )
    return json.loads(result.stdout)

def verify():
    for master in masters.split(","):
        try:
            if fetch(master, "/cluster/status").get("IsLeader") is True:
                topology = fetch(master, "/dir/status")["Topology"]
                break
        except (OSError, subprocess.SubprocessError, ValueError, KeyError):
            continue
    else:
        raise ValueError("нет доступного лидера SeaweedFS")
    replicas = collections.defaultdict(set)
    servers = set()
    for dc in topology["DataCenters"]:
        for rack in dc["Racks"]:
            for node in rack["DataNodes"]:
                server = node["Url"]
                if server in servers or node.get("EcShards", 0):
                    raise ValueError(f"{server}: дублированный узел или тома с EC-шардами")
                servers.add(server)
                volumes = fetch(server, "/status")["Volumes"] or []
                if len(volumes) != node["Volumes"]:
                    raise ValueError(f"{server}: мастер и volume server сообщают разное число томов")
                for volume in volumes:
                    vid = volume["Id"]
                    layout = volume["ReplicaPlacement"]
                    reported = "".join(str(layout.get(k, 0)) for k in ("dc", "rack", "node"))
                    if reported != policy:
                        raise ValueError(f"том {vid} на {server}: метка {reported}, требуется {policy}")
                    location = (dc["Id"], rack["Id"], server)
                    if location in replicas[vid]:
                        raise ValueError(f"том {vid} дважды на {server}")
                    replicas[vid].add(location)
    if not servers:
        raise ValueError("нет зарегистрированных volume servers")
    for vid, copies in replicas.items():
        zones = {dc for dc, _, _ in copies}
        if len(zones) <= dc_count or not any(
            len({r for d, r, _ in copies if d == dc}) > rack_count
            and sum(d == dc and r == rack for d, r, _ in copies) > node_count
            for dc, rack, _ in copies
        ):
            raise ValueError(f"том {vid}: размещение {sorted(copies)} не выполняет {policy}")
    print(f"Проверено томов: {len(replicas)}, volume servers: {len(servers)}, политика: {policy}")

try:
    verify()
except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError) as exc:
    sys.exit("SeaweedFS: " + str(exc))
PY
