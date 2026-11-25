# ============================================================================
# filer.toml.tpl — SeaweedFS Filer Store Config (Ligament Vault)
# ============================================================================
# Filer подключается к PostgreSQL Primary через локальный TCP-прокси HAProxy
# (127.0.0.1:${HAPROXY_PG_PORT}). Так как HAProxy работает в L4 (mode tcp),
# PostgreSQL SSLRequest (TLS verify-full) выполняется сквозным образом самим Filer!
# В SAN каждого pg-server.crt включен IP:127.0.0.1 (см. 02-pki-secrets.sh).
# ============================================================================

[filer.options]
# recursive_delete = false

[postgres2]
enabled = true
createTable = """
  CREATE TABLE IF NOT EXISTS "%s" (
    dirhash   BIGINT,
    name      VARCHAR(65535),
    directory VARCHAR(65535),
    meta      bytea,
    PRIMARY KEY (dirhash, name)
  );
"""
hostname    = "127.0.0.1"
port        = ${HAPROXY_PG_PORT}
username    = "seaweedfs"
password    = "${SWFS_FILER_DB_PASSWORD}"
database    = "seaweedfs_filer"
sslmode     = "verify-full"
sslrootcert = "/certs/ca.crt"
sslcert     = "/certs/pg-client.crt"
sslkey      = "/certs/pg-client.key"

connection_max_idle = 50
connection_max_open = 100
connection_max_lifetime_seconds = 300

# --- Все остальные stores отключены ---
[leveldb2]
enabled = false

[leveldb3]
enabled = false

[rocksdb]
enabled = false

[mysql2]
enabled = false

[tikv]
enabled = false

[redis3]
enabled = false

[etcd]
enabled = false

[mongodb]
enabled = false

[elastic7]
enabled = false

[hbase]
enabled = false
