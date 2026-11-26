# ============================================================================
# docker-compose.yml.tpl — Единый стек ноды Ligament Vault
# ============================================================================
# Все постоянные данные монтируются напрямую на хостовый раздел /data/...
# (никаких именованных томов в /var/lib/docker на системном разделе /!).
#
# Профили Docker Compose (${REMOTE_BASE_DIR}/.env -> COMPOSE_PROFILES):
#   - quorum : etcd + swfs-master (голосующие ноды, всегда нечетное число)
#   - admin  : swfs-admin (1 узел админки, по умолчанию node2)
#   - backup : swfs-backup (непрерывный weed filer.backup на admin-ноде при настроенном S3)
# ============================================================================

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "50m"
    max-file: "3"

x-restart: &default-restart
  restart: unless-stopped

services:
  # ════════════════════════════════════════════════════════════════════════
  # etcd (профиль quorum)
  # ════════════════════════════════════════════════════════════════════════
  etcd:
    image: "${ETCD_IMAGE_REF}"
    profiles: ["quorum"]
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    cap_add:
      - DAC_OVERRIDE
    logging: *default-logging
    environment:
      ETCD_NAME: "etcd-${NODE_NAME}"
      ETCD_DATA_DIR: "/etcd-data"
      ETCD_LISTEN_CLIENT_URLS: "https://${NODE_IP}:${ETCD_CLIENT_PORT},https://127.0.0.1:${ETCD_CLIENT_PORT}"
      ETCD_ADVERTISE_CLIENT_URLS: "https://${NODE_IP}:${ETCD_CLIENT_PORT}"
      ETCD_LISTEN_PEER_URLS: "https://${NODE_IP}:${ETCD_PEER_PORT}"
      ETCD_INITIAL_ADVERTISE_PEER_URLS: "https://${NODE_IP}:${ETCD_PEER_PORT}"
      ETCD_LISTEN_METRICS_URLS: "http://${NODE_IP}:${ETCD_METRICS_PORT},http://127.0.0.1:${ETCD_METRICS_PORT}"
      ETCD_INITIAL_CLUSTER: "${ETCD_INITIAL_CLUSTER}"
      ETCD_INITIAL_CLUSTER_TOKEN: "${CLUSTER_SLUG}-etcd"
      ETCD_INITIAL_CLUSTER_STATE: "${ETCD_CLUSTER_STATE}"
      # --- mTLS + CRL ---
      ETCD_CERT_FILE: "/certs/etcd-server.crt"
      ETCD_KEY_FILE: "/certs/etcd-server.key"
      ETCD_TRUSTED_CA_FILE: "/certs/ca.crt"
      ETCD_CLIENT_CRL_FILE: "/certs/crl.pem"
      ETCD_PEER_CERT_FILE: "/certs/etcd-peer.crt"
      ETCD_PEER_KEY_FILE: "/certs/etcd-peer.key"
      ETCD_PEER_TRUSTED_CA_FILE: "/certs/ca.crt"
      ETCD_PEER_CRL_FILE: "/certs/crl.pem"
      ETCD_CLIENT_CERT_AUTH: "true"
      ETCD_PEER_CLIENT_CERT_AUTH: "true"
      # --- WAN Тайминги ---
      ETCD_HEARTBEAT_INTERVAL: "${ETCD_HEARTBEAT_INTERVAL}"
      ETCD_ELECTION_TIMEOUT: "${ETCD_ELECTION_TIMEOUT}"
    volumes:
      - ${ETCD_DATA_DIR}:/etcd-data
      - ./certs/${NODE_NAME}:/certs:ro
    healthcheck:
      test: ["CMD", "etcdctl", "--endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT}",
             "--cacert=/certs/ca.crt", "--cert=/certs/etcd-client.crt",
             "--key=/certs/etcd-client.key", "endpoint", "health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ════════════════════════════════════════════════════════════════════════
  # Patroni + PostgreSQL 16 + pgBackRest
  # ════════════════════════════════════════════════════════════════════════
  patroni:
    image: "${PATRONI_PG_IMAGE_REF}"
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
      - SETUID
      - SETGID
    logging: *default-logging
    volumes:
      - ${PG_DATA_DIR}:${PG_DATA_DIR}
      - ./configs/patroni.yml:/etc/patroni/patroni.yml:ro
      - ./configs/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro
      - ./certs/${NODE_NAME}:/certs:ro
    environment:
      PATRONI_NAME: "${NODE_NAME}"
      PATRONI_SCOPE: "${CLUSTER_SLUG}"
      PATRONI_POSTGRESQL_DATA_DIR: "${PG_DATA_DIR}/data"
      PATRONICTL_CONFIG_FILE: "/run/pg-certs/patroni.yml"
      PGPORT: "${PG_PORT}"
    healthcheck:
      test: ["CMD", "curl", "-sf", "--cacert", "/run/pg-certs/ca.crt", "https://127.0.0.1:${PATRONI_API_PORT}/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ════════════════════════════════════════════════════════════════════════
  # HAProxy — локальный L4 роутер Filer -> PG Primary (127.0.0.1:5433)
  # ════════════════════════════════════════════════════════════════════════
  haproxy:
    image: "${HAPROXY_IMAGE_REF}"
    <<: [*default-restart]
    network_mode: host
    read_only: true
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    logging: *default-logging
    volumes:
      - ./configs/haproxy-pg.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
      - ./certs/${NODE_NAME}/ca.crt:/certs/ca.crt:ro
    depends_on:
      patroni:
        condition: service_started
    healthcheck:
      test: ["CMD", "haproxy", "-c", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
      interval: 5s
      timeout: 3s
      retries: 3

  # ════════════════════════════════════════════════════════════════════════
  # SeaweedFS Master (профиль quorum)
  # ════════════════════════════════════════════════════════════════════════
  swfs-master:
    image: "${SEAWEEDFS_IMAGE_REF}"
    profiles: ["quorum"]
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - CHOWN
    logging: *default-logging
    command: >-
      master
      -ip=${NODE_IP}
      -ip.bind=0.0.0.0
      -port=${SWFS_MASTER_PORT}
      -port.grpc=${SWFS_MASTER_GRPC_PORT}
      -metricsPort=${SWFS_MASTER_METRICS_PORT}
      -peers=${SWFS_MASTER_PEERS}
      -defaultReplication=${SWFS_DEFAULT_REPLICATION}
      -mdir=/master-data
      -electionTimeout=10s
      -telemetry=false
    volumes:
      - ${SWFS_MASTER_DIR}:/master-data
      - ./configs/seaweedfs:/etc/seaweedfs:ro
      - ./certs/${NODE_NAME}:/certs:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:${SWFS_MASTER_PORT}/cluster/status"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ════════════════════════════════════════════════════════════════════════
  # SeaweedFS Volume Server
  # ════════════════════════════════════════════════════════════════════════
  swfs-volume:
    image: "${SEAWEEDFS_IMAGE_REF}"
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - CHOWN
    logging: *default-logging
    command: >-
      volume
      -ip=${NODE_IP}
      -ip.bind=0.0.0.0
      -port=${SWFS_VOLUME_PORT}
      -port.grpc=${SWFS_VOLUME_GRPC_PORT}
      -metricsPort=${SWFS_VOLUME_METRICS_PORT}
      -master=${SWFS_MASTER_PEERS}
      -dataCenter=${DC_NAME}
      -dir=${SWFS_VOLUME_DIR}
      -max=${SWFS_VOLUME_MAX}
      -compactionMBps=50
    volumes:
${SWFS_VOLUME_MOUNTS}
      - ./configs/seaweedfs:/etc/seaweedfs:ro
      - ./certs/${NODE_NAME}:/certs:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:${SWFS_VOLUME_PORT}/healthz"]
      interval: 15s
      timeout: 5s
      retries: 3

  # ════════════════════════════════════════════════════════════════════════
  # SeaweedFS Filer ([postgres2] verify-full через HAProxy :5433)
  # ════════════════════════════════════════════════════════════════════════
  swfs-filer:
    image: "${SEAWEEDFS_IMAGE_REF}"
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - CHOWN
    logging: *default-logging
    command: >-
      filer
      -ip=${NODE_IP}
      -ip.bind=0.0.0.0
      -port=${SWFS_FILER_PORT}
      -port.grpc=${SWFS_FILER_GRPC_PORT}
      -metricsPort=${SWFS_FILER_METRICS_PORT}
      -master=${SWFS_MASTER_PEERS}
    volumes:
      - ./configs/seaweedfs:/etc/seaweedfs:ro
      - ./certs/${NODE_NAME}:/certs:ro
    depends_on:
      haproxy:
        condition: service_healthy
    healthcheck:
      # /healthz и порт метрик не требуют клиентского JWT (в отличие от GET / -> 401!)
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:${SWFS_FILER_PORT}/healthz || wget -q -O /dev/null http://127.0.0.1:${SWFS_FILER_METRICS_PORT}/metrics"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ════════════════════════════════════════════════════════════════════════
  # SeaweedFS S3 Gateway (строго 127.0.0.1:8333)
  # ════════════════════════════════════════════════════════════════════════
  swfs-s3:
    image: "${SEAWEEDFS_IMAGE_REF}"
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - CHOWN
    logging: *default-logging
    command: >-
      s3
      -ip.bind=127.0.0.1
      -port=${SWFS_S3_PORT}
      -metricsPort=${SWFS_S3_METRICS_PORT}
      -filer=${NODE_IP}:${SWFS_FILER_PORT}
      -config=/etc/seaweedfs/s3.json
    volumes:
      - ./configs/seaweedfs:/etc/seaweedfs:ro
      - ./certs/${NODE_NAME}:/certs:ro
    depends_on:
      swfs-filer:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "nc", "-z", "127.0.0.1", "${SWFS_S3_PORT}"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ════════════════════════════════════════════════════════════════════════
  # SeaweedFS Admin Server (профиль admin — 1 узел, -port.legacy=0)
  # ════════════════════════════════════════════════════════════════════════
  swfs-admin:
    image: "${SEAWEEDFS_IMAGE_REF}"
    profiles: ["admin"]
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - CHOWN
    logging: *default-logging
    command: >-
      admin
      -port=${SWFS_ADMIN_PORT}
      -port.grpc=${SWFS_ADMIN_GRPC_PORT}
      -port.legacy=0
      -master=${SWFS_MASTER_PEERS}
      -adminPassword=${SWFS_ADMIN_PASSWORD}
      -dataDir=/data
    volumes:
      - swfs-admin-data:/data
      - ./configs/seaweedfs:/etc/seaweedfs:ro
      - ./certs/${NODE_NAME}:/certs:ro
    healthcheck:
      test: ["CMD", "nc", "-z", "127.0.0.1", "${SWFS_ADMIN_PORT}"]
      interval: 15s
      timeout: 5s
      retries: 3

  # ════════════════════════════════════════════════════════════════════════
  # SeaweedFS Worker (на всех нодах)
  # ════════════════════════════════════════════════════════════════════════
  swfs-worker:
    image: "${SEAWEEDFS_IMAGE_REF}"
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - CHOWN
    logging: *default-logging
    command: >-
      worker
      -admin=${SWFS_ADMIN_IP}:${SWFS_ADMIN_PORT}
      -jobType=vacuum,ec,balance
      -workingDir=/data
      -maxExecute=2
    volumes:
      - swfs-worker-data:/data
      - ./configs/seaweedfs:/etc/seaweedfs:ro
      - ./certs/${NODE_NAME}:/certs:ro
    depends_on:
      swfs-filer:
        condition: service_healthy

  # ════════════════════════════════════════════════════════════════════════
  # SeaweedFS Continuous Off-Cluster Backup (профиль backup — на admin-ноде)
  # ════════════════════════════════════════════════════════════════════════
  swfs-backup:
    image: "${SEAWEEDFS_IMAGE_REF}"
    profiles: ["backup"]
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - CHOWN
    logging: *default-logging
    command: >-
      filer.backup
      -filer=127.0.0.1:${SWFS_FILER_PORT}
    volumes:
      - ./configs/seaweedfs:/etc/seaweedfs:ro
      - ./certs/${NODE_NAME}:/certs:ro
    depends_on:
      swfs-filer:
        condition: service_healthy

  # ════════════════════════════════════════════════════════════════════════
  # SFTPGo OSS (>= 2.7, UID 1000, NET_BIND_SERVICE для портов :21 и :443)
  # ════════════════════════════════════════════════════════════════════════
  sftpgo:
    image: "${SFTPGO_IMAGE_REF}"
    <<: [*default-restart]
    network_mode: host
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    logging: *default-logging
    cap_add:
      - NET_BIND_SERVICE
    environment:
      SFTPGO_DATA_PROVIDER__CREATE_DEFAULT_ADMIN: "true"
      SFTPGO_DEFAULT_ADMIN_USERNAME: "${SFTPGO_ADMIN_USERNAME}"
      SFTPGO_DEFAULT_ADMIN_PASSWORD: "${SFTPGO_ADMIN_PASSWORD}"
    volumes:
      - ./configs/sftpgo.json:/etc/sftpgo/sftpgo.json:ro
      - ./configs/revoked_user_certs.json:/etc/sftpgo/revoked_user_certs.json:ro
      - ./hooks:/etc/sftpgo/hooks:ro
      - ${SFTPGO_DATA_DIR}:/srv/sftpgo
      - ${SFTPGO_TEMP_PATH}:${SFTPGO_TEMP_PATH}
      - ./certs/${NODE_NAME}/ca.crt:/certs/ca.crt:ro
      - ./certs/${NODE_NAME}/pg-client.crt:/certs/pg-client.crt:ro
      - ./certs/${NODE_NAME}/pg-client.key:/certs/pg-client.key:ro
      - ./certs/ssl:/etc/sftpgo/ssl:ro
      - ./ssh-host-keys:/etc/sftpgo/host_keys:ro
    depends_on:
      swfs-s3:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "sftpgo", "ping", "--config-file", "/etc/sftpgo/sftpgo.json"]
      interval: 15s
      timeout: 5s
      retries: 3

  # ════════════════════════════════════════════════════════════════════════
  # node_exporter
  # ════════════════════════════════════════════════════════════════════════
  node-exporter:
    image: "${NODE_EXPORTER_IMAGE_REF}"
    <<: [*default-restart]
    network_mode: host
    read_only: true
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    logging: *default-logging
    command:
      - "--web.listen-address=${NODE_IP}:9100"
      - "--path.rootfs=/host"
      - "--collector.textfile.directory=/textfile_collector"
    volumes:
      - /:/host:ro,rslave
      - /var/lib/node_exporter/textfile_collector:/textfile_collector:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://${NODE_IP}:9100/metrics"]
      interval: 30s
      timeout: 5s
      retries: 2

volumes:
  swfs-admin-data:
  swfs-worker-data:
