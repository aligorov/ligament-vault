{
  "_comment": "sftpgo.json.tpl — Конфигурация SFTPGo OSS (>=2.7) для Ligament Vault",

  "common": {
    "idle_timeout": 15,
    "upload_mode": ${SFTPGO_UPLOAD_MODE},
    "temp_path": "${SFTPGO_TEMP_PATH}",
    "rename_mode": 0,
    "setstat_mode": 2,
    "resume_max_size": 0,
    "proxy_protocol": 0,
    "startup_hook": "",
    "post_connect_hook": "",
    "post_disconnect_hook": "",
    "max_total_connections": 0,
    "max_per_host_connections": 0,
    "defender": {
      "enabled": true,
      "driver": "provider",
      "ban_time": 30,
      "ban_time_increment": 50,
      "threshold": 15,
      "score_invalid": 2,
      "score_valid": 1,
      "score_limit_exceeded": 3,
      "observation_time": 30,
      "entries_soft_limit": 100,
      "entries_hard_limit": 150,
      "safelist": []
    }
  },

  "sftpd": {
    "bindings": [
      {
        "port": ${SFTP_PORT},
        "address": "",
        "apply_proxy_config": true
      }
    ],
    "max_auth_tries": 6,
    "host_keys": [
      "/etc/sftpgo/host_keys/id_ed25519",
      "/etc/sftpgo/host_keys/id_ecdsa",
      "/etc/sftpgo/host_keys/id_rsa"
    ],
    "host_certificates": [],
    "host_key_algorithms": [],
    "kex_algorithms": [],
    "ciphers": [],
    "macs": [],
    "revoked_user_certs_file": "/etc/sftpgo/revoked_user_certs.json",
    "login_banner_file": "",
    "enabled_ssh_commands": ["md5sum", "sha1sum", "sha256sum", "cd", "pwd", "scp"]
  },

  "ftpd": {
    "bindings": [
      {
        "port": ${FTPS_PORT},
        "address": "",
        "apply_proxy_config": false,
        "tls_mode": 1,
        "min_tls_version": 12,
        "force_passive_ip": "${NODE_IP}",
        "passive_ip_overrides": [],
        "client_auth_type": 0,
        "tls_cipher_suites": [],
        "passive_connections_security": 0,
        "active_connections_security": 0
      }
    ],
    "passive_port_range": {
      "start": ${FTPS_PASV_MIN},
      "end": ${FTPS_PASV_MAX}
    },
    "certificate_file": "/etc/sftpgo/ssl/fullchain.pem",
    "certificate_key_file": "/etc/sftpgo/ssl/privkey.pem",
    "ca_certificates": [],
    "ca_revocation_lists": []
  },

  "webdavd": {
    "bindings": []
  },

  "httpd": {
    "bindings": [
      {
        "_comment": "WebClient — публичный HTTPS (WebAdmin и REST API выключены)",
        "port": ${HTTPS_PORT},
        "address": "",
        "enable_web_admin": false,
        "enable_web_client": true,
        "enable_rest_api": false,
        "enabled_login_methods": 0,
        "enable_https": true,
        "certificate_file": "/etc/sftpgo/ssl/fullchain.pem",
        "certificate_key_file": "/etc/sftpgo/ssl/privkey.pem",
        "min_tls_version": 13,
        "client_auth_type": 0
      },
      {
        "_comment": "WebAdmin + REST API — строго localhost (только SSH-туннель)",
        "port": 8081,
        "address": "127.0.0.1",
        "enable_web_admin": true,
        "enable_web_client": false,
        "enable_rest_api": true,
        "enabled_login_methods": 0
      }
    ],
    "setup": {
      "installation_code": "${SFTPGO_INSTALLATION_CODE}"
    },
    "signing_passphrase": "${SFTPGO_SIGNING_PASSPHRASE}",
    "token_validation": 0,
    "cors": {
      "enabled": false
    }
  },

  "data_provider": {
    "driver": "postgresql",
    "name": "sftpgo",
    "host": "",
    "port": 0,
    "username": "sftpgo",
    "password": "${SFTPGO_DB_PASSWORD}",
    "connection_string": "host=127.0.0.1,${PG_HOSTS} port=${HAPROXY_PG_PORT},${PG_PORTS_CSV} dbname=sftpgo user=sftpgo password=${SFTPGO_DB_PASSWORD} sslmode=verify-full sslrootcert=/certs/ca.crt sslcert=/certs/pg-client.crt sslkey=/certs/pg-client.key target_session_attrs=read-write connect_timeout=5",
    "sql_tables_prefix": "",
    "track_quota": 2,
    "delayed_quota_update": 0,
    "pool_size": 0,
    "users_base_dir": "/srv/sftpgo/data",
    "pre_login_hook": "${SFTPGO_PRE_LOGIN_HOOK}",
    "actions": {
      "execute_on": [],
      "execute_for": [],
      "hook": ""
    },
    "update_mode": 0,
    "create_default_admin": true,
    "skip_natural_keys_validation": false,
    "password_hashing": {
      "bcrypt_options": {
        "cost": 10
      },
      "argon2_options": {
        "memory": 65536,
        "iterations": 1,
        "parallelism": 2
      }
    },
    "password_validation": {
      "admins": {
        "min_entropy": 0,
        "length": 12,
        "uppers": 1,
        "lowers": 1,
        "digits": 1,
        "specials": 0
      },
      "users": {
        "min_entropy": 0,
        "length": 12,
        "uppers": 1,
        "lowers": 1,
        "digits": 1,
        "specials": 0
      }
    },
    "is_shared": 1,
    "node": {
      "host": "",
      "port": 0,
      "proto": ""
    },
    "backups_path": "/srv/sftpgo/backups"
  },

  "kms": {
    "secrets": {
      "url": "",
      "master_key": "${SFTPGO_KMS_MASTER_KEY}"
    }
  },

  "telemetry": {
    "bind_port": ${SFTPGO_TELEMETRY_PORT},
    "bind_address": "${SFTPGO_TELEMETRY_BIND}"
  },

  "smtp": {
    "host": "",
    "port": 0,
    "from": "",
    "user": "",
    "password": ""
  },

  "plugins": []
}
