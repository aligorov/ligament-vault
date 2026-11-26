# ============================================================================
# pgbackrest.conf.tpl — Конфигурация pgBackRest для Patroni (Ligament Vault)
# ============================================================================
# Монтируется в /etc/pgbackrest/pgbackrest.conf внутри контейнера patroni.
# Клиентское AES-256-CBC шифрование выполняется до отправки в внешний S3.
# Переменные: ${PG_DATA_DIR}, ${BACKUP_S3_BUCKET}, ${BACKUP_S3_HOST},
#   ${BACKUP_S3_REGION}, ${BACKUP_S3_ACCESS_KEY}, ${BACKUP_S3_SECRET_KEY},
#   ${BACKUP_ENCRYPTION_KEY}
# ============================================================================

[global]
repo1-type=s3
repo1-s3-bucket=${BACKUP_S3_BUCKET}
repo1-s3-endpoint=${BACKUP_S3_HOST}
repo1-s3-region=${BACKUP_S3_REGION}
repo1-s3-key=${BACKUP_S3_ACCESS_KEY}
repo1-s3-key-secret=${BACKUP_S3_SECRET_KEY}
repo1-s3-uri-style=path
repo1-path=/pgbackrest

# Клиентское шифрование бэкапов и WAL
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=${BACKUP_ENCRYPTION_KEY}

# Сжатие и ретеншн
compress-type=zst
repo1-retention-full=4
repo1-retention-diff=14
process-max=2
start-fast=y
stop-auto=y
log-level-console=info
log-level-file=info

[${CLUSTER_SLUG}]
pg1-path=${PG_DATA_DIR}/data
pg1-port=${PG_PORT}
