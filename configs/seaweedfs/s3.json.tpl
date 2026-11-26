{
  "_comment": "s3.json.tpl — SeaweedFS S3 IAM для Ligament Vault",
  "_note": "Локальные S3-учетки: SFTPGo обращается к http://127.0.0.1:8333",

  "identities": [
    {
      "name": "provision-admin",
      "credentials": [
        {
          "accessKey": "provision-s3-admin",
          "secretKey": "${SWFS_ADMIN_PASSWORD}"
        }
      ],
      "actions": [
        "Admin",
        "Read",
        "Write",
        "List",
        "Tagging",
        "Lock"
      ]
    },
    {
      "name": "sftpgo-service",
      "credentials": [
        {
          "accessKey": "sftpgo-s3-access",
          "secretKey": "${SWFS_S3_SECRET_KEY_SFTPGO}"
        }
      ],
      "actions": [
        "Read",
        "Write",
        "List",
        "Tagging"
      ]
    },
    {
      "name": "backup-service",
      "credentials": [
        {
          "accessKey": "backup-s3-access",
          "secretKey": "${SWFS_S3_SECRET_KEY_BACKUP}"
        }
      ],
      "actions": [
        "Read",
        "List"
      ]
    },
    {
      "name": "anonymous",
      "actions": []
    }
  ],

  "accounts": [
    {
      "id": "provision-account",
      "displayName": "Provision Admin Account",
      "emailAddress": "provision@${CLUSTER_SLUG}.internal",
      "identities": [
        {
          "name": "provision-admin"
        }
      ]
    },
    {
      "id": "sftpgo-account",
      "displayName": "SFTPGo Service Account",
      "emailAddress": "sftpgo@${CLUSTER_SLUG}.internal",
      "identities": [
        {
          "name": "sftpgo-service"
        }
      ]
    },
    {
      "id": "backup-account",
      "displayName": "Backup Read-Only Account",
      "emailAddress": "backup@${CLUSTER_SLUG}.internal",
      "identities": [
        {
          "name": "backup-service"
        }
      ]
    }
  ]
}
