# ============================================================================
# prometheus/prometheus.yml.tpl — Конфигурация Prometheus на внешнем Арбитре
# ============================================================================

global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["127.0.0.1:9093"]

rule_files:
  - /etc/prometheus/alerts.yml

scrape_configs:
  - job_name: "node-exporter"
    static_configs:
      - targets: [${PROM_TARGETS_NODE_EXPORTER}]

  - job_name: "etcd"
    static_configs:
      - targets: [${PROM_TARGETS_ETCD}]

  - job_name: "patroni"
    metrics_path: /metrics
    static_configs:
      - targets: [${PROM_TARGETS_PATRONI}]

  - job_name: "swfs-master"
    static_configs:
      - targets: [${PROM_TARGETS_SWFS_MASTER}]

  - job_name: "swfs-volume"
    static_configs:
      - targets: [${PROM_TARGETS_SWFS_VOLUME}]

  - job_name: "swfs-filer"
    static_configs:
      - targets: [${PROM_TARGETS_SWFS_FILER}]

  - job_name: "sftpgo"
    metrics_path: /metrics
    static_configs:
      - targets: [${PROM_TARGETS_SFTPGO}]

  - job_name: "blackbox-ssl-expiry"
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - "https://${DOMAIN}:${HTTPS_PORT}/web/client/login"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "127.0.0.1:9115"
