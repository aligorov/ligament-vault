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
  protocol: https
  hosts: ${ETCD_PATRONI_HOSTS}
  use_proxies: ${ETCD_PATRONI_USE_PROXIES}
  cacert: /run/pg-certs/ca.crt
  cert: /run/pg-certs/etcd-client.crt
  key: /run/pg-certs/etcd-client.key
  retry_timeout: 25

# --- REST API Patroni (HTTPS + mTLS на мутирующих запросах) ---
# GET (/primary, /replica, /health, /metrics) шифруются TLS;
# мутирующие POST/PUT/PATCH/DELETE требуют клиентский сертификат CA (verify_client: optional) + Basic Auth.
restapi:
  listen: 0.0.0.0:${PATRONI_API_PORT}
  connect_address: ${NODE_IP}:${PATRONI_API_PORT}
  certfile: /run/pg-certs/pg-server.crt
  keyfile: /run/pg-certs/pg-server.key
  cafile: /run/pg-certs/ca.crt
  verify_client: optional
  authentication:
    username: patroni
    password: ${PATRONI_API_PASSWORD}

ctl:
  cacert: /run/pg-certs/ca.crt
  certfile: /run/pg-certs/pg-client.crt
  keyfile: /run/pg-certs/pg-client.key

# --- WAN тайминги (ttl >= loop_wait + 2 * retry_timeout) ---
ttl: 75
loop_wait: 10
retry_timeout: 25
failsafe_mode: true

# --- Инициализация кластера (только на первой стартующей ноде) ---
bootstrap:
  dcs:
    ttl: 75
    loop_wait: 10
    retry_timeout: 25
    primary_start_timeout: 60
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
        max_slot_wal_keep_size: "${PG_MAX_SLOT_WAL_KEEP_SIZE}"
        wal_log_hints: "on"
        wal_keep_size: "128MB"
        archive_mode: "on"
        archive_command: "${PG_ARCHIVE_COMMAND}"
        restore_command: 'pgbackrest --stanza=${CLUSTER_SLUG} archive-get %f "%p"'
        password_encryption: "scram-sha-256"
        # --- SSL (Zero-Trust mTLS TLSv1.3) ---
        ssl: "on"
        ssl_min_protocol_version: "TLSv1.3"
        ssl_cert_file: /run/pg-certs/pg-server.crt
        ssl_key_file: /run/pg-certs/pg-server.key
        ssl_ca_file: /run/pg-certs/ca.crt
        ssl_crl_file: /run/pg-certs/crl.pem

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local all all trust
    - hostnossl all all 0.0.0.0/0 reject
    - hostnossl all all ::/0 reject
    - hostnossl replication all 0.0.0.0/0 reject
    - hostnossl replication all ::/0 reject
    - hostssl all all 127.0.0.1/32 scram-sha-256 clientcert=verify-ca
    - hostssl all all ::1/128 scram-sha-256 clientcert=verify-ca
    - hostssl replication replicator 127.0.0.1/32 scram-sha-256 clientcert=verify-ca
    - hostssl replication replicator ::1/128 scram-sha-256 clientcert=verify-ca
${PG_HBA_PEERS_YAML}
    - host all all 0.0.0.0/0 reject
    - host all all ::/0 reject
    - host replication all 0.0.0.0/0 reject
    - host replication all ::/0 reject

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
  pg_hba:
    - local all all trust
    - hostnossl all all 0.0.0.0/0 reject
    - hostnossl all all ::/0 reject
    - hostnossl replication all 0.0.0.0/0 reject
    - hostnossl replication all ::/0 reject
    - hostssl all all 127.0.0.1/32 scram-sha-256 clientcert=verify-ca
    - hostssl all all ::1/128 scram-sha-256 clientcert=verify-ca
    - hostssl replication replicator 127.0.0.1/32 scram-sha-256 clientcert=verify-ca
    - hostssl replication replicator ::1/128 scram-sha-256 clientcert=verify-ca
${PG_HBA_PEERS_YAML}
    - host all all 0.0.0.0/0 reject
    - host all all ::/0 reject
    - host replication all 0.0.0.0/0 reject
    - host replication all ::/0 reject
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
