# ============================================================================
# arbiter-compose.yml.tpl — Стек мониторинга на внешнем Арбитре (Ligament Vault)
# ============================================================================
# Рендерится в ${ARBITER_BASE_DIR}/docker-compose.yml стадией 05-edge-ssl-backup.
# ============================================================================

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "50m"
    max-file: "3"

services:
  prometheus:
    image: "${PROMETHEUS_IMAGE_REF}"
    restart: unless-stopped
    network_mode: host
    logging: *default-logging
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=30d"
      - "--web.listen-address=127.0.0.1:9090"
    volumes:
      - prometheus-data:/prometheus
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/alerts.yml:/etc/prometheus/alerts.yml:ro

  alertmanager:
    image: "${ALERTMANAGER_IMAGE_REF}"
    restart: unless-stopped
    network_mode: host
    logging: *default-logging
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
      - "--web.listen-address=127.0.0.1:9093"
    volumes:
      - alertmanager-data:/alertmanager
      - ./prometheus/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro

  blackbox:
    image: "${BLACKBOX_IMAGE_REF}"
    restart: unless-stopped
    network_mode: host
    logging: *default-logging
    command:
      - "--config.file=/etc/blackbox_exporter/config.yml"
      - "--web.listen-address=127.0.0.1:9115"
    volumes:
      - ./prometheus/blackbox.yml:/etc/blackbox_exporter/config.yml:ro

volumes:
  prometheus-data:
  alertmanager-data:
