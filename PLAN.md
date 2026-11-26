# Архитектурный и эксплуатационный план кластера SFTP/FTPS/Web (Сборка «Б» • v4)

> Единая спецификация **Day-0 / Day-1 / Day-2** для геораспределенного кластера на 3–4+ Linux VPS без VPN-оверлея.  
> Базируется на результатах трех раундов аудита ([AUDIT-PLAN.md](file:///Users/aleksey/Documents/ftp/AUDIT-PLAN.md), [DISPUTE.md](file:///Users/aleksey/Documents/ftp/DISPUTE.md), [DISPUTE-3.md](file:///Users/aleksey/Documents/ftp/DISPUTE-3.md)) и верификации исходников `SFTPGo v2.7.6+`, `SeaweedFS 4.x`, `Patroni >= 3.3` и `etcd v3.5`.

---

## 1. Концепция и осознанные границы системы

### Цель
Отказаться от ручной настройки серверов и «зоопарка» разнородных утилит: вся инфраструктура управляется декларативно через единый CLI-оркестратор **`./clusterctl`**, конфигурацию `cluster.env` + `secrets.env` (поддержка `age`/`sops`) и манифест пинованных образов `versions.env` (`@sha256`).

### Продуктовые и архитектурные границы (зафиксированы до старта)
1. **Модель обслуживания — Active/Standby (Active/Passive):** В каждый момент клиентский трафик принимает один активный узел, на который указывает DNS (`files.company.com`). В `SFTPGo OSS` для этого не нужна платная лицензия Enterprise (`data_provider.node` и перенос HTTP-сессий не требуются; при аварии веб-клиенты логинятся заново).
2. **Объектное хранилище вместо POSIX ФС (transfer-only):**
   - По ограничениям `SFTPGo ↔ S3` **переименование непустых каталогов не поддерживается** (ни в OSS, ни в Enterprise); отсутствуют `truncate`, `symlink`, `readlink`, `chtime`, `sshfs`; `chown/chmod` отключаются (`setstat_mode=2`).
   - Для буферизации загрузок обязателен локальный `temp_path` на NVMe (в OSS нет `memory_pipes`).
3. **Докачка файлов (без TUS в браузере):** В `SFTPGo OSS v2.7.6` протокола TUS нет (Enterprise-функция). Докачка работает в SFTP-клиентах (`common.resume_max_size` + `upload_mode=2` на рабочем бакете); в WebClient — стандартная HTTP-загрузка.
4. **Окно кэша SFTPGo OSS (~10 минут):** В OSS-редакции изменения учетных записей доходят до standby-узлов с задержкой кэша до 10 мин. Любое переключение активного узла в скриптах сопровождается принудительным перезапуском/сбросом кэша `sftpgo` до смены DNS.

---

## 2. Целевая топология компонентов

Используется **единый кластер SeaweedFS** с общим метадата-хранилищем в **PostgreSQL (`[postgres2]`)** под управлением **Patroni + etcd**. Схема со множеством локальных `leveldb`-филеров и cross-DC `filer.sync` полностью исключена как неподдерживаемая upstream.

```
VPS 1 (DC1 • Active Edge)       VPS 2 (DC2 • Standby)           VPS 3 (DC3 • Standby)          [VPS 4 (DC4 • Опция)]
─────────────────────────       ─────────────────────           ─────────────────────          ─────────────────────
etcd voter (1/3)                etcd voter (2/3)                etcd voter (3/3)               — (без etcd voter)
Patroni + PG16 (Primary)        Patroni + PG16 (Replica)        Patroni + PG16 (Replica)       Patroni + PG16 (Standby)
HAProxy (:5433 -> /primary)     HAProxy (:5433 -> /primary)     HAProxy (:5433 -> /primary)    HAProxy (:5433 -> /primary)
SWFS Master (Raft 1/3)          SWFS Master (Raft 2/3)          SWFS Master (Raft 3/3)         — (без Master)
SWFS Volume (-dataCenter=dc1)   SWFS Volume (-dataCenter=dc2)   SWFS Volume (-dataCenter=dc3)  SWFS Volume (-dataCenter=dc4)
SWFS Filer ([postgres2])        SWFS Filer ([postgres2])        SWFS Filer ([postgres2])       SWFS Filer ([postgres2])
SWFS S3 Gateway (:8333)         SWFS S3 Gateway (:8333)         SWFS S3 Gateway (:8333)        SWFS S3 Gateway (:8333)
weed worker                     weed admin + worker             weed worker                    weed worker
SFTPGo 2.7.6+ (Active)          SFTPGo 2.7.6+ (Standby)         SFTPGo 2.7.6+ (Standby)        SFTPGo 2.7.6+ (Standby)
   │                               │                               │                              │
   ├── SWFS Filer ──► локальный HAProxy (127.0.0.1:5433, GET /primary) ───────────────────────────┴─► Актуальный PG Leader
   └── SFTPGo ──────► нативный multi-host libpq (host=IP1,IP2,IP3..., target_session_attrs=read-write) ─► Актуальный PG Leader
```

**Ключевые связки:**
- **Локальный HAProxy (`127.0.0.1:5433`):** `weed filer` (`[postgres2]` на `pgx`) не принимает список хостов и `target_session_attrs`. HAProxy на каждой ноде проверяет Patroni `GET /primary` (:8008) и маршрутизирует запросы Филера строго на актуального лидера PG.
- **Размещение данных (`defaultReplication=100`):** Каждая запись попадает на Volume в 2 разных ДЦ (`volumeGrowthCount=2`). При падении 1 из 3 ДЦ клиент автоматически переназначает загрузку на 2 выживших ДЦ (`RPO ≈ 0`).

---

## 3. Сеть, порты, UFW, PKI и SSL

### 3.1. Сетевая гигиена и защита от Lockout
- **Чистый `network_mode: host` + UFW:** Все контейнеры делят сетевой стек хоста. Это убирает 200 процессов `docker-proxy` под FTPS PASV и исключает проблему обхода UFW цепочками Docker (`DOCKER-USER` не требуется).
- **Безопасное применение UFW (`120s` Dead-Man's Switch):** Разрешение SSH (`ADMIN_SSH_NET`, key-only + `fail2ban`) добавляется **до** `ufw --force enable`. Перед включением взводится откат-таймер `ufw-rollback` на 120 сек — таймер отменяется скриптом только после подтвержденной проверки SSH-доступа снаружи.
- **Точное время:** Обязательный `chrony` на всех узлах с контролем дрейфа в `clusterctl status`.

### 3.2. Матрица портов

| Сервис | Порты | Bind IP | Доступ в UFW | Назначение |
| :--- | :--- | :--- | :--- | :--- |
| **Host SSH (`sshd`)** | `22` *(опц. `2222`)* | `0.0.0.0` | **`ADMIN_SSH_NET`** (+ fail2ban) | Управление, `clusterctl`, SSH-туннель к WebAdmin |
| **SFTPGo FTPS** | `21` + `50000–50199` | `0.0.0.0` | Весь мир | Explicit FTPS (`tls_mode=1`, `force_passive_ip=PUBLIC_IP`) |
| **SFTPGo SFTP** | `2022` *(опц. `22`)* | `0.0.0.0` | Весь мир | SFTP с общими SSH host-keys |
| **SFTPGo WebClient** | `443` | `0.0.0.0` | Весь мир | HTTPS WebClient (`WebAdmin` и `REST API` выключены) |
| **SFTPGo WebAdmin** | `8081` | `127.0.0.1` | **Закрыто извне** | Панель управления и REST API (только SSH-туннель) |
| **HAProxy / SWFS S3** | `5433` / `8333` | `127.0.0.1` | **Закрыто извне** | Локальные прокси до PG Primary и S3-шлюза |
| **etcd** | `2379`, `2380` | `PUBLIC_IP` (+`lo`) | **IP нод + Арбитр** | Raft и DCS Patroni (mTLS) |
| **PG 16 / Patroni API** | `15432`, `8008` | `0.0.0.0` | **IP нод (`/32`) + Арбитр (`:8008`)** | БД (`TLSv1.3` + mTLS `clientcert=verify-ca` + `scram-sha-256`), WAL-репликация (`verify-full`), `/primary`, `/failsafe` |
| **SeaweedFS Core** | `9333`, `19333`, `8082`, `18082`, `8888`, `18888` | `0.0.0.0` | **Только IP нод** | Master Raft (`-electionTimeout=10s`), Volume, Filer (mTLS + JWT) |
| **SWFS Admin / Worker** | `12535`, `22535` | `PUBLIC_IP`/`lo` | **Только IP нод** | Админка (`-port.legacy=0`) и gRPC worker (`[grpc.admin]`) |
| **Metrics (`Prom`)** | `9100`, `9324`, `8008` | `PUBLIC_IP`/`lo` | **Только IP Арбитра** | Сбор метрик без экспорта в интернет |

### 3.3. PKI (ECDSA P-256, Remote-CSR) и SSL (`lego DNS-01`)
1. **Zero-Knowledge Remote-CSR:** Приватный ключ Root CA (`ca.key`) создается и хранится только у оператора (или в vault). Ключи узлов (`ECDSA P-256`) генерируются удаленно внутри каждой VPS; по сети ходят только `.csr` и подписанные `.crt` с полными SAN (`IP + hostname`).
2. **Раздельные leaf-сертификаты и `allowed_commonNames`:** У каждой роли SeaweedFS (`master`, `volume`, `filer`, `s3`, `admin`, `worker`) свой CN и лист допуска `allowed_commonNames` в `security.toml` (закрывает доверие ко всем подряд сертификатам одного CA).
3. **4 JWT-ключа + закрытые метаданные:** В `security.toml` задаются все 4 ключа (`signing`, `signing.read`, `filer_signing`, `filer_signing.read`) и `[filer.expose_directory_metadata] enabled = false`.
4. **SSL через внешний `lego DNS-01`:** Порт `:80` не открывается; единый wildcard/доменный сертификат перевыпускается по API DNS-провайдера, раскладывается на все ноды и подхватывается SFTPGo без разрыва сессий по сигналу `SIGHUP`. Для отзыва сертификатов настроен CRL / `revoked_user_certs_file`.

---

## 4. База данных, хранение WORM, бэкапы и отказоустойчивость

### 4.1. Patroni + PostgreSQL 16 (Автоматический возврат и WAN-тайминги)
- **Тайминги:** `etcd` (по результатам RTT-замера в Спринте 0: `election >= 10×max_RTT`, при RTT ≤ 250 мс — `250ms / 2500ms`), Patroni (`loop_wait=10`, `retry_timeout=15`, `ttl=60`, `primary_start_timeout=60`, `synchronous_mode_strict=off`).
- **Режим коммитов (`synchronous_mode`):** Выбирается по итогам замера мелких файлов в Спринте 2 (в cross-DC WAN синхронный коммит добавляет ~2×RTT на каждую метадата-операцию Филера).
- **Механика авто-возврата бывшего лидера:**
  - `initdb: ["--data-checksums"]` + `wal_log_hints: "on"` + `use_pg_rewind: true`.
  - Постоянные физические `slots` по именам узлов + предохранитель **`max_slot_wal_keep_size: "64GB"`** (и алерт на 70% диска `pg_wal`).
  - `remove_data_directory_on_rewind_failure: true` и `..._on_diverged_timelines: true` + `clonefrom: true` на репликах (если WAL ушел — автоматическая пересборка с реплики, не нагружая активного лидера).
  - При `failsafe_mode: true` учитывается обязательная доступность всех узлов на `:8008` (удаление ноды — только через вывод из Patroni).

### 4.2. Стратегия двух бакетов (Versioning + WORM) и ремонт томов
- **Все бакеты с Versioning:** Включенный Versioning избавляет от асинхронного бага `CopyObject` (`200 OK` с XML-ошибкой) в SeaweedFS и защищает от случайных удалений.
- **Рабочий бакет (`sftp-work`):** Versioning ON, Object Lock OFF, `upload_mode=2` (Atomic with resume), `resume_max_size > 0`.
- **Архивный WORM-бакет (`sftp-worm`):** Создается с `--object-locking-enabled` до первого `PUT`; **`upload_mode=1`** (запрещены `upload_mode=2` и флаг `4`, чтобы оборванная загрузка не заблокировалась retention навсегда); per-directory ACL запрещают перезапись.
- **Ремонт репликации без SPOF:** Работают `weed admin` (на узле 2/3) + `weed worker` (`volume.fix.replication -apply` каждые 17 мин), а `[master.maintenance]` в `master.toml` **сохраняется** — по исходникам SeaweedFS он автоматически подхватывает ремонт, если ДЦ с `weed admin` вышел из строя.

### 4.3. Внешний Арбитр, Бэкапы и реальные RTO/RPO
- **Арбитр / Мониторинг (1 легкая внешняя VPS, fallback — `etcd` lease):**
  - Внешний Prometheus + Alertmanager (метрики `etcd`, Patroni lag/`pg_wal`, SWFS under-replication, expiry SSL, disk compaction headroom). Ротация Docker-логов (`max-size: 50m`, `max-file: 3`) на всех узлах.
  - **Failover DNS:** переключение по API провайдера после 3 провалов проб подряд (интервал 15–20с), с рестартом `sftpgo` на новом активном узле перед сменой A-записи и выравниванием PG Primary.
  - **Автоматический Failback с 5 воротами:** возврат только при одновременном прохождении: (1) PG `streaming` + lag = 0, (2) `etcd` здоров, (3) `volume.fix.replication` dry-run пуст, (4) сквозная проба `S3 + SFTP` зелена 5 раз подряд по 30с, (5) прошел cooldown ≥ 10 мин (не чаще 1 раза/час).
- **Off-cluster DR-бэкапы:** `pgbackrest` (WAL + full) + `weed filer.backup` + `weed filer.meta.backup` на стороннего S3-провайдера **с принудительным шифрованием на стороне приемника** (`filer.backup` расшифровывает SSE-S3 при чтении!) + регулярный автотест восстановления.
- **Реальные SLA:** Failover внутри кластера **~70–90с**, для клиента (с учетом DNS TTL 30–60с) — **~100–150с** (активные TCP-сессии переподключаются клиентом); потеря данных при гибели 1 из 3+ ДЦ **RPO ≈ 0** благодаря `defaultReplication=100`.

---

## 5. Жизненный цикл и единый CLI-оркестратор (`./clusterctl`)

Вместо разрозненных одноразовых скриптов все операции Day-0 / Day-1 / Day-2 сведены в единую, логичную и безопасную утилиту `./clusterctl` (с поддержкой `--dry-run`, `--yes` и детерминированного манифеста `versions.env`).

### 5.1. Day-0: Pre-flight и Установка (`preflight` / `install` / `sync-config`)
- **`./clusterctl preflight`** *(Спринт 0)*: проверяет SSH (key-only), собирает полную матрицу RTT между всеми ДЦ (`ping -c 100`, **hard stop** при `max_RTT > 250ms`), проверяет NTP (`chrony`), свободный диск под `temp_path`/`pg_wal`/compaction и `PASV`-емкость.
- **`./clusterctl install`**: послойный запуск с защитным guardrail (при повторном запуске на живом кластере **не трогает** БД/тома и предлагает `sync-config` или `upgrade`):
  1. `Host Hardening` (NTP, fail2ban, UFW с 120s rollback).
  2. `PKI & Secrets` (Remote-CSR ECDSA P-256, общие SSH host-keys, KMS, JWT).
  3. `etcd 1–3` одновременно → ожидание Raft-кворума.
  4. `Patroni PG16 (--data-checksums)` Node 1 → реплики 2–4 (`clonefrom`) → локальные `HAProxy :5433` → однократный `sftpgo initprovider` (`update_mode=1`).
  5. `SeaweedFS` (Masters 1–3, Volumes `-dataCenter`, Filers `[postgres2]`, `fs.configure -volumeGrowthCount=2`, `weed admin/worker`, бакеты `sftp-work`/`sftp-worm`) + `lego DNS-01`.
  6. `SFTPGo` (`installation_code`, `defender=provider`, `:443` / `127.0.0.1:8081`) → Арбитр/DNS → настройка `pgbackrest` и `filer.backup`.
- **`./clusterctl sync-config`**: безопасное обновление шаблонов (`sftpgo.json`, `haproxy-pg.cfg`, `ufw` IP-листов) с валидацией синтаксиса (`sftpgo serve --check-config` / `haproxy -c`) и reload без перезапуска БД.

### 5.2. Day-1: Приемка и Chaos-тестирование (`verify`)
Перед переводом продакшн-трафика `./clusterctl verify` прогоняет обязательные приемочные гейты (Спринты 1–6):
- **Sprint 1 (S3↔WORM Spike):** тест `PUT/GET/LIST/rename` файла, запрет `mv` непустой папки, `PUT` в WORM-бакет **без checksum**, тест обрыва загрузки при `upload_mode=1` vs `2` (**hard stop** при ошибке записи в WORM).
- **Sprint 2–3 (Латентность & Partition):** бенчмарк мелких файлов (`synchronous_mode on/off`), тест обрыва связи (`iptables DROP`) — проверка непрерывной записи Filer через `HAProxy :5433`, SFTPGo на реплике и `re-assign` при потере Volume.
- **Sprint 4–6 (Возврат, Бэкап, Периметр):** возврат узла после 5 мин и >2 ч простоя (`pg_rewind`), падение `weed admin` и автоподхват `[master.maintenance]`, restore-тест `pgbackrest`/`filer.backup`, lockout-проверка UFW и чтение SWFS без JWT.

### 5.3. Day-2: Масштабирование и замена нод (`scale`)
Никаких ручных правок: каждая команда соблюдает кворумные и сетевые инварианты.
- **`./clusterctl scale add --ip <IP> --dc <dc4> [--role edge|quorum]`**:
  - При `3 → 4` поднимает только `Volume + Filer + S3 + HAProxy + Patroni Replica + SFTPGo + worker` (не портит нечетный кворум `etcd`/`Master`!). При `3 → 5` в режиме `quorum` добавляет `etcd` строго по одному через `member add --learner` → wait catch-up → `member promote`.
  - **До старта** новой ноды: расширяет UFW и конфиги на существующих узлах, регистрирует новый permanent slot в Patroni (`patronictl edit-config`), выпускает Remote-CSR сертификат и раздает секреты.
  - После присоединения `weed volume`: проверяет `cluster.status` и при `--rebalance` запускает в `weed shell` команды **`volume.balance`** и **`volume.fix.replication`** для распределения данных по новому ДЦ.
- **`./clusterctl scale replace --old <node> --new-ip <IP>`**:
  - На сгоревшем узле отзывает старый сертификат (CRL / `revoked_user_certs_file`), чистит старый IP в UFW; для `etcd` на живом кворуме делает `member remove` → `member add --learner` новой VPS → `promote`; перезаливает PG с `clonefrom`-реплики и восстанавливает потерянные копии томов через `volume.fix.replication -apply`.
- **`./clusterctl scale remove --node <node>`**:
  - Дренаж трафика/DNS и PG Primary (если узел активный) → эвакуация/вывод volume и `volume.fix.replication` → **`patronictl remove`** (обязательно при `failsafe_mode: true`) → вывод из `etcd` (если voter) → очистка UFW и конфигов на оставшихся узлах.
- **`./clusterctl scale expand-disk --node <node> --dir </mnt/nvme2> --max-volumes <N>`**:
  - Бесшовное подключение дополнительного диска к `weed volume` без добавления нового сервера.

### 5.4. Day-2: Rolling-обновление и откат (`upgrade` / `rollback`)
Транзакционное обновление версий ПО из `versions.env` по пинованным `@sha256` без потери кворума и целостности схемы БД:
1. **Pre-Upgrade Gate & Snapshot:** проверка здорового статуса (`clusterctl status --strict`, лаг `0`, dry-run SWFS чист) → снятие `etcdctl snapshot save` + инкремента `pgbackrest` → запись текущих `@sha256` в `.rollback_state`.
2. **Этап 1 — `etcd` (по 1 узлу):** фолловер 1 → health + catch-up → фолловер 2 → `move-leader` → бывший лидер.
3. **Этап 2 — `Patroni + PostgreSQL` (минорные версии):** поочередное обновление реплик с проверкой `streaming` и `lag=0` → управляемый `patronictl switchover` на обновленную реплику → обновление бывшего Primary (единая версия Patroni для `failsafe_mode`). *(Смена мажорной версии PG 16 → 17 програмно заблокирована и вынесена в отдельный runbook `pg_upgrade` / logical replication).*
4. **Этап 3 — `SeaweedFS` (сверху вниз):** `weed worker/admin` → `Filer/S3` по одной ноде → `Volume` по одному ДЦ за раз → `Masters` (фолловеры → лидер последним).
5. **Этап 4 — `SFTPGo` (Standby-first Edge Cutover):** обновление Standby-узлов → при смене версии БД однократный прогон `sftpgo initprovider` (`update_mode=1`, после бэкапа PG) → плановый перевод DNS на обновленную Standby-ноду (с рестартом для сброса кэша) → обновление бывшей Active-ноды.
6. **`./clusterctl rollback`:** откат контейнеров на сохраненные дайджесты из `.rollback_state` (плюс процедура отката БД по бэкапу при несовместимых миграциях).

### 5.5. Мониторинг состояния: `./clusterctl status [--json]`
Единая команда диагностики: выводит статус `chrony` (дрейф мс), кворум `etcd`, таблицу Patroni (`role`, `lag`, `slots`, `% pg_wal`), `volume.fix.replication` (dry-run), свободное место томов/`temp_path`, активный DNS-edge, дату истечения SSL-сертификатов и статус последнего бэкапа `pgbackrest`/`filer.backup`.

---

## 6. Современная структура проекта

```text
/Users/aleksey/Documents/ftp/
├── PLAN.md                         # Настоящий план (v4: Day-0 / Day-1 / Day-2)
├── clusterctl                      # Единый CLI-оркестратор (preflight, install, sync-config, verify, scale, upgrade, rollback, status)
├── versions.env                    # Зафиксированные версии и @sha256 дайджесты образов (SFTPGo >=2.7.6, SWFS 4.x, PG16/Patroni, etcd, HAProxy, lego)
├── cluster.env.example             # Топология, DC/RTT-пороги, ADMIN_SSH_NET, DNS API, квоты, SFTP_PORT
├── secrets.env.example             # Секреты (поддержка шифрования через age/sops, права 600)
├── docker-compose.yml.tpl          # Единый стек ноды (network_mode: host, healthchecks, log rotation 50m x3)
├── Dockerfile.patroni              # PostgreSQL 16 + Patroni (>=3.3) + etcd3 + pgbackrest
├── configs/
│   ├── patroni.yml.tpl             # WAN тайминги, use_pg_rewind, permanent slots, clonefrom, mTLS, failsafe
│   ├── haproxy-pg.cfg.tpl          # Локальный роутер 127.0.0.1:5433 -> Patroni GET /primary для Filer
│   ├── sftpgo.json.tpl             # Multi-host PG, update_mode=1, :443 WebClient / 127.0.0.1:8081 Admin, defender, FTPD :21
│   ├── prometheus/                 # Правила алертов (pg_wal 70%, lag, SWFS under-replication, SSL expiry, host disk)
│   └── seaweedfs/
│       ├── security.toml.tpl       # 4 JWT-ключа + mTLS CN allowlist + disable_expose_metadata + admin TLS
│       ├── master.toml.tpl         # [master.maintenance] fallback при падении weed admin
│       ├── filer.toml.tpl          # [postgres2] через HAProxy 127.0.0.1:5433 (verify-full)
│       ├── replication.toml.tpl    # Конфиг weed filer.backup (off-cluster S3 с шифрованием приемника)
│       └── s3.json.tpl             # Локальные S3-учетки для SFTPGo → http://127.0.0.1:8333
├── scripts/
│   ├── lib/
│   │   └── common.sh               # SSH-обертка, логгер, dry-run/guardrail, etcd/Patroni/SWFS API хелперы
│   ├── stages/
│   │   ├── 00-preflight.sh         # Замеры RTT (kill >250ms), дисковый сайзинг, проверка SSH/PASV
│   │   ├── 01-host-hardening.sh    # chrony NTP, fail2ban, UFW + 120s rollback-таймер, sysctl
│   │   ├── 02-pki-secrets.sh       # Remote-CSR ECDSA P-256 (ca.key локально), SAN, CRL, KMS, host-keys
│   │   ├── 03-bootstrap-db.sh      # etcd 1-3, Patroni initdb --data-checksums, HAProxy, initprovider
│   │   ├── 04-bootstrap-swfs.sh    # Masters/Volumes/Filers, fs.configure, бакеты work/worm, admin/worker
│   │   └── 05-edge-ssl-backup.sh   # lego DNS-01 (+SIGHUP), SFTPGo, арбитр failover, pgbackrest + filer.backup
│   ├── ops/
│   │   ├── scale-cluster.sh        # add / replace / remove node, expand-disk, volume.balance, etcd --learner
│   │   ├── upgrade-cluster.sh      # Поэтапный rolling upgrade + pre-upgrade snapshots + --rollback
│   │   ├── acme-lego-dns01.sh      # Cron-обновление сертификата DNS-01 + SIGHUP по всем нодам
│   │   ├── dns-failover-arbiter.sh # Внешний арбитр (+ etcd-lease fallback) с 5 воротами авто-failback
│   │   └── backup-job.sh           # Расписание pgbackrest + шифрованный weed filer.backup + restore check
│   └── verify/
│       ├── sprint1-s3-worm.sh      # Spike SFTPGo OSS ↔ SeaweedFS S3 (Object Lock, upload_mode, rename)
│       ├── cluster-health.sh       # Сводный статус и метрики (--json / human)
│       └── chaos-dr-test.sh        # Имитация падения лидера/ДЦ и проверка авто-возврата
└── README.md                       # Быстрый старт, таблица ./clusterctl, туннель WebAdmin, DR & pg_upgrade runbooks
```
