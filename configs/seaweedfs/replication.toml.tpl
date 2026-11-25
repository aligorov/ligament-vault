# ============================================================================
# replication.toml.tpl — SeaweedFS Filer Backup Config (Ligament Vault)
# ============================================================================
# Конфигурация weed filer.backup для off-cluster DR-копии на внешний S3.
#
# ⚠️ КРИТИЧНО (PLAN.md §4.3):
#   filer.backup расшифровывает внутреннее SSE-S3 шифрование при чтении!
#   На бакете-приемнике (${BACKUP_S3_BUCKET}) ОБЯЗАТЕЛЬНО должна быть включена
#   политика Default Encryption (SSE-S3 / SSE-KMS) на стороне внешнего S3-провайдера.
# ============================================================================

[sink.s3]
enabled               = true
aws_access_key_id     = "${BACKUP_S3_ACCESS_KEY}"
aws_secret_access_key = "${BACKUP_S3_SECRET_KEY}"
region                = "${BACKUP_S3_REGION}"
bucket                = "${BACKUP_S3_BUCKET}"
directory             = "/filer-backup"
endpoint              = "${BACKUP_S3_ENDPOINT}"
forcePathStyle        = true

[source.filer]
grpcAddress = "127.0.0.1:${SWFS_FILER_GRPC_PORT}"
directory   = "/"
