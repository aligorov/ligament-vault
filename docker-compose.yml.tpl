# ============================================================================
# docker-compose.yml.tpl — Единый стек ноды Ligament Vault
# ============================================================================
# Все постоянные данные монтируются напрямую на хостовый раздел /data/...
# (никаких именованных томов в /var/lib/docker на системном разделе /!).
#
# Профили Docker Compose (из ролей в базе контроллера):
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
    command:
      - "/usr/local/bin/etcd"
      - "--name=etcd-${NODE_NAME}"
      - "--data-dir=/etcd-data"
      - "--listen-client-urls=https://${NODE_BIND_IP}:${ETCD_CLIENT_PORT},https://127.0.0.1:${ETCD_CLIENT_PORT}"
      - "--advertise-client-urls=https://${NODE_IP}:${ETCD_CLIENT_PORT}"
      - "--listen-peer-urls=https://${NODE_BIND_IP}:${ETCD_PEER_PORT}"
      - "--initial-advertise-peer-urls=https://${NODE_IP}:${ETCD_PEER_PORT}"
      - "--listen-metrics-urls=http://${NODE_BIND_IP}:${ETCD_METRICS_PORT},http://127.0.0.1:${ETCD_METRICS_PORT}"
      - "--initial-cluster=${ETCD_INITIAL_CLUSTER}"
      - "--initial-cluster-token=${CLUSTER_SLUG}-etcd"
      - "--initial-cluster-state=${ETCD_CLUSTER_STATE}"
      - "--cert-file=/certs/etcd-server.crt"
      - "--key-file=/certs/etcd-server.key"
      - "--trusted-ca-file=/certs/ca.crt"
      - "--client-crl-file=/certs/crl.pem"
      - "--peer-cert-file=/certs/etcd-peer.crt"
      - "--peer-key-file=/certs/etcd-peer.key"
      - "--peer-trusted-ca-file=/certs/ca.crt"
      - "--peer-crl-file=/certs/crl.pem"
      - "--client-cert-auth=true"
      - "--peer-client-cert-auth=true"
      - "--experimental-peer-skip-client-san-verification=true"
      - "--heartbeat-interval=${ETCD_HEARTBEAT_INTERVAL}"
      - "--election-timeout=${ETCD_ELECTION_TIMEOUT}"
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
      - ./configs/start-patroni.sh:/usr/local/bin/start-vault-patroni:ro
    entrypoint: ["bash", "/usr/local/bin/start-vault-patroni", "${PG_DATA_DIR}/data"]
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
      -peers=${SWFS_MASTER_SEEDS}
      -defaultReplication=${SWFS_DEFAULT_REPLICATION}
      -volumeSizeLimitMB=${SWFS_VOLUME_SIZE_LIMIT_MB}
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
      -minFreeSpace=${SWFS_MIN_FREE_SPACE}
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
    command:
      - admin
      - -ip=0.0.0.0
      - -port=${SWFS_ADMIN_PORT}
      - -port.grpc=${SWFS_ADMIN_GRPC_PORT}
      - -port.legacy=0
      - -master=${SWFS_MASTER_PEERS}
      - ${SWFS_ADMIN_PASSWORD}
      - -dataDir=/data
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
    command: ["sftpgo", "serve", "--config-dir", "/etc/sftpgo", "--loaddata-from", "/etc/sftpgo/bootstrap.json", "--loaddata-mode", "1", "--log-level", "debug", "--log-utc-time", "--log-file-path", "/logs/events.log", "--log-max-size", "50", "--log-max-backups", "5", "--log-compress=false"]
    volumes:
      - ${SFTPGO_DATA_DIR}-audit/logs:/logs
      - ./configs/sftpgo-bootstrap.json:/etc/sftpgo/bootstrap.json:ro
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
      client-audit:
        condition: service_started
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
  client-audit:
    image: "${PATRONI_PG_IMAGE_REF}"
    user: "1000:1000"
    restart: unless-stopped
    network_mode: host
    read_only: true
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    logging: *default-logging
    entrypoint: ["/usr/bin/python3", "/app/client-audit.py", "/app/config.json"]
    healthcheck:
      disable: true
    volumes:
      - ./configs/client-audit.py:/app/client-audit.py:ro
      - ./configs/client-audit.json:/app/config.json:ro
      - ${SFTPGO_DATA_DIR}-audit/logs:/logs:ro
      - ${SFTPGO_DATA_DIR}-audit/spool:/spool
      - ./certs/${NODE_NAME}/ca.crt:/certs/ca.crt:ro
      - ./certs/${NODE_NAME}/pg-client.crt:/certs/pg-client.crt:ro
      - ./certs/${NODE_NAME}/pg-client.key:/certs/pg-client.key:ro

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
      - "--web.listen-address=${NODE_BIND_IP}:9100"
      - "--path.rootfs=/host"
      - "--collector.textfile.directory=/textfile_collector"
    volumes:
      - /:/host:ro
      - /var/lib/node_exporter/textfile_collector:/textfile_collector:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://${NODE_IP}:9100/metrics"]
      interval: 30s
      timeout: 5s
      retries: 2

volumes:
  swfs-admin-data:
  swfs-worker-data:
