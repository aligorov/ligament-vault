# ============================================================================
# master.toml.tpl — SeaweedFS Master Config (Ligament Vault)
# ============================================================================
# [master.maintenance] оставляется как автоматический fallback (DISPUTE-3 B3):
#   - Пока weed admin подключен к мастеру, legacy-цикл пропускается
#     (weed/server/master_server.go:508-514: ms.isAdminServerConnectedFunc()).
#   - При потере ДЦ с weed admin лидер-мастер автоматически подхватывает ремонт.
# ============================================================================

[master.maintenance]
scripts = """
lock
volume.fix.replication -apply
volume.deleteEmpty -quietFor=24h -apply
s3.clean.uploads -timeAgo=24h
unlock
"""
sleep_minutes = 17

[master.sequencer]
type = "raft"
