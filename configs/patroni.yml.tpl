# ============================================================================
# patroni.yml.tpl — Конфигурация Patroni для WAN-кластера Ligament Vault
# ============================================================================
# Сертификаты копируются entrypoint-скриптом в /run/pg-certs (chown postgres, 0600).
# ============================================================================

scope: ${CLUSTER_SLUG}
name: ${NODE_NAME}
namespace: /${CLUSTER_SLUG}/

# --- etcd DCS (mTLS) ---
etcd3:
  hosts: ${ETCD_HOSTS}
  cacert: /run/pg-certs/ca.crt
  cert: /run/pg-certs/etcd-client.crt
  key: /run/pg-certs/etcd-client.key

# --- REST API Patroni ---
# GET (/primary, /replica, /health, /metrics) открыты для HAProxy и Prometheus;
# мутирующие POST/PUT/PATCH/DELETE защищены Basic Auth (закрывает localhost RCE!).
restapi:
  listen: 0.0.0.0:${PATRONI_API_PORT}
  connect_address: ${NODE_IP}:${PATRONI_API_PORT}
  authentication:
    username: patroni
    password: ${PATRONI_API_PASSWORD}

# --- WAN тайминги (election >= 10 * max_RTT) ---
ttl: 60
loop_wait: 10
retry_timeout: 15
primary_start_timeout: 60
failsafe_mode: true

# --- Инициализация кластера (только на первой стартующей ноде) ---
bootstrap:
  dcs:
    ttl: 60
    loop_wait: 10
    retry_timeout: 15
    maximum_lag_on_failover: 1048576
    synchronous_mode: false           # Включается только после замера в Sprint 2
    synchronous_mode_strict: false
    failsafe_mode: true
    slots:
${PATRONI_SLOTS_YAML}
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10
        max_slot_wal_keep_size: "64GB"
        wal_log_hints: "on"
        wal_keep_size: "2GB"
        archive_mode: "on"
        archive_command: "pgbackrest --stanza=${CLUSTER_SLUG} archive-push %p"
        restore_command: 'pgbackrest --stanza=${CLUSTER_SLUG} archive-get %f "%p"'
        # --- SSL ---
        ssl: "on"
        ssl_cert_file: /run/pg-certs/pg-server.crt
        ssl_key_file: /run/pg-certs/pg-server.key
        ssl_ca_file: /run/pg-certs/ca.crt

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local all all trust
    - hostssl all all 0.0.0.0/0 scram-sha-256
    - hostssl replication replicator 0.0.0.0/0 scram-sha-256

  users:
    replicator:
      password: ${PG_REPLICATION_PASSWORD}
      options:
        - replication

# --- PostgreSQL (локальный узел) ---
postgresql:
  listen: 0.0.0.0:${PG_PORT}
  connect_address: ${NODE_IP}:${PG_PORT}
  data_dir: ${PG_DATA_DIR}/data
  bin_dir: /usr/lib/postgresql/16/bin
  pgpass: /tmp/pgpass0
  authentication:
    superuser:
      username: postgres
      password: ${PG_SUPERUSER_PASSWORD}
      sslmode: verify-full
      sslcert: /run/pg-certs/pg-client.crt
      sslkey: /run/pg-certs/pg-client.key
      sslrootcert: /run/pg-certs/ca.crt
    replication:
      username: replicator
      password: ${PG_REPLICATION_PASSWORD}
      sslmode: verify-full
      sslcert: /run/pg-certs/pg-client.crt
      sslkey: /run/pg-certs/pg-client.key
      sslrootcert: /run/pg-certs/ca.crt
    rewind:
      username: postgres
      password: ${PG_SUPERUSER_PASSWORD}
      sslmode: verify-full
      sslcert: /run/pg-certs/pg-client.crt
      sslkey: /run/pg-certs/pg-client.key
      sslrootcert: /run/pg-certs/ca.crt
  parameters:
    unix_socket_directories: /var/run/postgresql
  remove_data_directory_on_rewind_failure: true
  remove_data_directory_on_diverged_timelines: true
  create_replica_methods:
    - basebackup
  basebackup:
    checkpoint: fast

# --- Теги ---
# clonefrom: true позволяет новым/отставшим репликам клонироваться с реплики вместо Primary
tags:
  nofailover: false
  noloadbalance: false
  clonefrom: true
  nosync: false
