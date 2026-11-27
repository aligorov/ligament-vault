# ============================================================================
# security.toml.tpl — SeaweedFS Security (Ligament Vault)
# ============================================================================
# По верификации исходников SeaweedFS (DISPUTE-3.md §1 B6, §3 N21):
#   - Раздельные CN на каждую роль + allowed_commonNames (fail-closed mTLS)
#   - [grpc.client] для исходящих gRPC вызовов (s3, admin, worker, backup, shell)
#   - [https.admin] + [https.client] для шифрования Admin UI и REST API
#   - Все 4 JWT-ключа обязательны (без них либо утечка данных, либо 'wrong jwt')
#   - [filer.expose_directory_metadata] enabled = false
# ============================================================================

[grpc]
ca = "/certs/ca.crt"

# Исходящие gRPC-подключения (s3, weed shell, filer.backup, worker -> master/filer/admin)
[grpc.client]
cert = "/certs/swfs-client.crt"
key  = "/certs/swfs-client.key"

[grpc.master]
cert = "/certs/swfs-master.crt"
key  = "/certs/swfs-master.key"
allowed_commonNames = "swfs-master,swfs-volume,swfs-filer,swfs-s3,swfs-admin,swfs-worker,swfs-client"

[grpc.volume]
cert = "/certs/swfs-volume.crt"
key  = "/certs/swfs-volume.key"
allowed_commonNames = "swfs-master,swfs-filer,swfs-admin,swfs-worker,swfs-client"

[grpc.filer]
cert = "/certs/swfs-filer.crt"
key  = "/certs/swfs-filer.key"
allowed_commonNames = "swfs-master,swfs-volume,swfs-filer,swfs-s3,swfs-admin,swfs-worker,swfs-client"

[grpc.s3]
cert = "/certs/swfs-s3.crt"
key  = "/certs/swfs-s3.key"
allowed_commonNames = "swfs-filer,swfs-admin,swfs-client"

[grpc.admin]
cert = "/certs/swfs-admin.crt"
key  = "/certs/swfs-admin.key"
allowed_commonNames = "swfs-master,swfs-volume,swfs-filer,swfs-worker,swfs-client"

[grpc.worker]
cert = "/certs/swfs-worker.crt"
key  = "/certs/swfs-worker.key"

# --- HTTPS для weed admin UI (аутентификация по -adminPassword, Worker gRPC защищен mTLS в [grpc.admin]) ---
[https.admin]
cert = "/certs/swfs-admin.crt"
key  = "/certs/swfs-admin.key"

[https.client]
enabled = false
cert = "/certs/swfs-client.crt"
key  = "/certs/swfs-client.key"
ca   = "/certs/ca.crt"

# --- Все 4 JWT-ключа обязательны ---
[jwt.signing]
key = "${SWFS_JWT_SIGNING_KEY}"

[jwt.signing.read]
key = "${SWFS_JWT_SIGNING_READ_KEY}"

[jwt.filer_signing]
key = "${SWFS_JWT_FILER_SIGNING_KEY}"

[jwt.filer_signing.read]
key = "${SWFS_JWT_FILER_SIGNING_READ_KEY}"

# --- Защита метаданных и UI ---
[filer.expose_directory_metadata]
enabled = false

[access]
ui = false
