# ============================================================================
# haproxy-pg.cfg.tpl — Локальный роутер Filer -> PG Primary (Ligament Vault)
# ============================================================================
# weed filer ([postgres2]) подключается к 127.0.0.1:HAPROXY_PG_PORT.
# HAProxy выбирает актуального лидера PG через Patroni HTTP check GET /primary.
# Переменные: HAPROXY_PG_PORT, HAPROXY_PG_SERVERS
# ============================================================================

global
    maxconn     256
    log         stdout format raw local0 info

defaults
    mode        tcp
    log         global
    retries     3
    timeout connect  5s
    timeout client  60s
    timeout server  60s
    timeout check    3s

resolvers cluster_dns
    parse-resolv-conf
    resolve_retries 3
    timeout resolve 1s
    timeout retry 1s
    hold valid 5s
    hold nx 2s
    hold refused 2s
    hold timeout 2s
    hold obsolete 2s

# --- Фронтенд: локальный вход для SeaweedFS Filer ---
frontend pg_primary_frontend
    bind 127.0.0.1:${HAPROXY_PG_PORT}
    default_backend pg_primary_backend

# --- Бэкенд: все ноды Patroni (генерируются динамически из CLUSTER_NODES) ---
backend pg_primary_backend
    option httpchk
    http-check send meth GET uri /primary ver HTTP/1.1 hdr Host patroni
    http-check expect status 200
    default-server inter 2s fall 2 rise 1 maxconn 128 on-marked-down shutdown-sessions

${HAPROXY_PG_SERVERS}

# --- Статистика (только localhost) ---
listen stats
    bind 127.0.0.1:8405
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
