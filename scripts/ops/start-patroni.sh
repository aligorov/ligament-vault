#!/usr/bin/env bash
set -euo pipefail
data_dir="$1"
mkdir -p "$data_dir"
chown postgres:postgres "$(dirname "$data_dir")" "$data_dir"
chmod 700 "$data_dir"
exec /usr/local/bin/patroni-entrypoint.sh
