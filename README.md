# Ligament Vault — Геораспределенный кластер SFTP / FTPS / Web / WORM

> Отказоустойчивое файловое хранилище корпоративного уровня на **SFTPGo OSS (`>=2.7.6`) + SeaweedFS (`4.x`) + Patroni/PostgreSQL 16 + etcd (`v3.5`)** на 3–5+ независимых Linux VPS в разных ДЦ **без VPN-оверлея**.  
> Архитектурная база: [PLAN.md](file:///Users/aleksey/Documents/ftp/PLAN.md) (v4).

---

## 1. Быстрый старт (Day-0)

### 1.1. Подготовка конфигурации и шифрованных секретов (`age`)

```bash
# 1. Конфигурация кластера (заполните IP, ДЦ, DOMAIN, ADMIN_SSH_NET, ARBITER_IP)
cp cluster.env.example cluster.env
chmod 600 cluster.env

# 2. Автогенерация криптостойких паролей/ключей с шифрованием в secrets.env.age (Zero-Plaintext в RAM!)
./ligactl secrets init

# 3. Заполнение внешних токенов (CF_DNS_API_TOKEN, BACKUP_S3_*, LIGAMENT_2FA_API_TOKEN) в RAM-буфере
./ligactl secrets edit
```

> При наличии `secrets.env.age` оркестратор расшифровывает секреты напрямую в оперативную память через `age` (ключ `~/.config/ligament/age.key`), не создавая открытый `secrets.env` на диске. Для шифрования ключа УЦ после первичной генерации выполните `./ligactl secrets encrypt`.

### 1.2. Проверка, установка и приемка через `./ligactl`

```bash
# 1. Проверка готовности всех VPS (SSH, RTT-матрица, NTP, диски, PASV, Docker)
./ligactl preflight

# 2. Пробный прогон и фиксация реальных @sha256 дайджестов в versions.env
./ligactl install --dry-run
./ligactl pin-versions

# 3. Послойная установка (Стадии 0–5, с распределенным etcd-локом и поддержкой --resume)
./ligactl install

# 4. Приемочные тесты Day-1 (S3/WORM Spike + Health + Chaos/DR)
./ligactl verify --sprint 1
./ligactl status
```

---

## 2. Справочник команд `./ligactl` (совместим с `./clusterctl`)

| Фаза | Команда | Назначение |
| :--- | :--- | :--- |
| **Day-0** | `./ligactl secrets <init\|edit\|encrypt\|decrypt\|status>` | Генерация и `age`-шифрование секретов и `ca.key` без хранения plaintext на диске |
| **Day-0** | `./ligactl preflight` | Проверка SSH, замер RTT (`hard stop > 250ms`), NTP (`chrony`), диски `/data`, PASV, Docker |
| **Day-0** | `./ligactl install [--stage N] [--resume]` | Послойное развертывание с чекпоинтами `.state/journal.jsonl` и продолжением с упавшего шага |
| **Day-0** | `./ligactl sync-config [--skip-ufw]` | Рендер и валидация шаблонов, бесшовный sync UFW (без окна сброса) и hot-reload |
| **Day-0** | `./ligactl pin-versions` | Фиксация реальных `@sha256` дайджестов образов в `versions.env` |
| **Day-0** | `./ligactl publish-image [--multiarch]` | Сборка `Dockerfile.patroni` и публикация `aligorov/ligament_vault_patroni:16` в Docker Hub |
| **Day-1** | `./ligactl verify [--sprint 1] [--disruptive]` | Приемочные гейты (S3/WORM Spike, Patroni failover, периметр без JWT) |
| **Day-1** | `./ligactl lab <up\|verify\|status\|down>` | Локальная песочница из 3 Ubuntu VM на `Multipass` / `Lima` + MinIO S3 |
| **Day-2** | `./ligactl user <add\|list\|disable\|set-quota\|rotate-key\|disconnect>` | Управление клиентами SFTPGo (профили `dual`/`work-only`/`worm-only`, квоты, ключи, TOTP) |
| **Day-2** | `./ligactl pki <status\|rotate> [--all\|--node N]` | Контроль сроков и бесшовная Remote-CSR ротация внутренних mTLS-сертификатов |
| **Day-2** | `./ligactl scale <add\|replace\|remove\|expand-disk>` | Добавление `edge`/`quorum` узлов, замена сгоревших нод (CRL + `clonefrom`), расширение дисков |
| **Day-2** | `./ligactl upgrade [--component ...] [--resume]` | Транзакционное rolling-обновление по `@sha256` дайджестам со снапшотами |
| **Day-2** | `./ligactl rollback` | Откат контейнеров на сохраненные дайджесты из `.rollback_state` |
| **Day-2** | `./ligactl dr <restore\|verify-backup> [--target-time TS]` | Автоматический подъем кластера «из пепла» на чистых VPS из внешнего S3 (PITR) |
| **Day-2** | `./ligactl status [--json] [--strict]` | Сводная диагностика: NTP, etcd, Patroni, SeaweedFS репликация, SSL, бэкапы |
| **Day-2** | `./ligactl unlock [--force]` | Сброс локальной и распределенной (`etcd`) блокировки операций |

Глобальные флаги: `--env <prod|stage|lab>`, `--resume`, `--dry-run`, `--yes`, `--verbose`, `--help`.

---

## 3. Управление пользователями и интеграция с `Ligament 2FA`

```bash
# Создать клиента с папками /work (докачка) и /worm (неудаляемый архив), квотой 100 ГБ и 2FA
./ligactl user add \
  --username partner-bank \
  --profile dual \
  --quota-gb 100 \
  --ssh-key @~/.ssh/partner_ed25519.pub \
  --require-2fa

# Мгновенно заблокировать пользователя и разорвать его активные SFTP/FTPS/Web сессии на всех нодах
./ligactl user disable --username partner-bank
```

- Для включения централизованной проверки политик и блокировок через сервис **`Ligament 2FA`** установите `LIGAMENT_2FA_ENABLED="true"` и `LIGAMENT_2FA_API_URL` в `cluster.env`, задайте `LIGAMENT_2FA_API_TOKEN` в секретах и выполните `./ligactl sync-config`.
- Панель WebAdmin (`127.0.0.1:8081`) закрыта извне; доступ для отладки — только через локальный SSH-туннель:
  ```bash
  ssh -N -L 8081:127.0.0.1:8081 root@<ACTIVE_NODE_IP>
  ```

---

## 4. Автоматические задачи, Наблюдаемость и Fast Failover

- **Продление публичного SSL (`lego DNS-01` + `SIGHUP` без разрыва сессий):**
  ```cron
  15 3 * * * /path/to/scripts/ops/acme-lego-dns01.sh >> /var/log/ligament-acme.log 2>&1
  ```
- **Резервное копирование (`pgbackrest` + непрерывный демон `swfs-backup` + метрики Prometheus):**
  ```cron
  0 */6 * * * /path/to/scripts/ops/backup-job.sh incr >> /var/log/ligament-backup.log 2>&1
  0 2 * * 0   /path/to/scripts/ops/backup-job.sh full >> /var/log/ligament-backup.log 2>&1
  30 4 * * 1  /path/to/scripts/ops/backup-job.sh verify-restore >> /var/log/ligament-backup.log 2>&1
  0 5 * * *   /path/to/ligactl pki status >/dev/null 2>&1
  ```
- **Быстрый Failover (`RTO ~10–15 сек`):** поддерживаются режимы `FAILOVER_MODE="dns|floating-ip|hybrid"` (Hetzner / DigitalOcean / custom VIP hook) в паре с `fence-edge` (`ss -K` + `conntrack -D`), принудительно отправляющим `TCP RST` зависшим сессиям изолированного узла.
- **Grafana:** готовый дашборд находится в [ligament-vault-dashboard.json](file:///Users/aleksey/Documents/ftp/configs/grafana/ligament-vault-dashboard.json).

---

## 5. Ключевые инварианты архитектуры

- **`network_mode: host` + UFW**: обновления правил выполняются поверх активного UFW без окна сброса с внешним 120-секундным таймером авто-отката.
- **Прямые bind-mounts на `/data/...`**: данные `PostgreSQL`, `etcd`, `SeaweedFS` и `SFTPGo` никогда не попадают в Docker volumes на корневом разделе `/`.
- **Двойная защита WORM (`sftp-worm`)**: запрет удаления/перезаписи на уровне прав SFTPGo (`/worm`) + автоматический S3 `DefaultRetention` (`COMPLIANCE`) + `upload_mode=1`.
- **Мажорный апгрейд PostgreSQL (`16 -> 17`)**: программно заблокирован в `./ligactl upgrade`; выполняется через плановое окно с полным бэкапом и `pg_upgrade` / logical replication.
