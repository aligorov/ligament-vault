# Аудит PLAN.md — сборка «Б» (геораспределённый SFTP/FTPS/Web кластер)

> Виток 1. Часть выводов пересмотрена витком 2: см. [DISPUTE.md](DISPUTE.md) (аннулированы F6, лицензионная рамка F1, механизм F5, вариант B3 MinIO; сужены F4/F14/F19). Текст ниже сохранён как запись витка 1 без правок.

Объект: `/Users/aleksey/Documents/ftp/PLAN.md` (245 строк, версия от 23.11.2026 14:26).
Формат: якорь `PLAN.md:NN` → утверждение плана → что не так → доказательство → уверенность → что делать.
Уверенность: **[C]** = первичный источник (docs/upstream issue), **[L]** = вторичный/косвенный, **[U]** = не проверено, нужен тест.

## 0. Вердикт

План в текущем виде не собирается и не даёт заявленного уровня надёжности. **8 blocker'ов, 15 важных, 5 гигиенических** замечаний (28 всего, таблица ниже).

Три системные проблемы, из которых вырастает большинство пунктов:

1. **Половина ключей SFTPGo взята из Enterprise-доков, а не из OSS v2.7.6.** `is_shared` существует, но лежит не там; `users_policy`, `shared.instance_name`, `SIGNING_PASSPHRASE`, `master_key` — в v2.7.6 grep исходников даёт ноль; TUS в OSS нет вообще. Конфиг не поднимется или поднимется молча без того, на что рассчитан.
2. **Слой данных не обеспечивает заявленную надёжность.** SeaweedFS официально не рекомендует связку «per-node filer с локальным стором + `filer.sync` через ДЦ», Object Lock — фича от 3.94 (июль 2025) и активно правилась в 4.x, асинхронная репликация = документированная потеря данных при падении узла до синхронизации. При этом PG реплицируется синхронно → метаданные есть, файла нет. Обещание «переключение прозрачно для клиентов» (PLAN.md:164) и «0 секунд» (PLAN.md:173) не выполняются.
3. **План внутренне противоречив в сети и PKI:** ACME HTTP-01 (единственный, что умеет встроенный ACME) требует порт 80, которого нет в списке открытых портов (PLAN.md:34); «host-сеть ЛИБО DOCKER-USER» (PLAN.md:49) оставлено без выбора, а сам сниппет `DOCKER-USER` режет исходящий трафик контейнеров; включение UFW без явного `allow 22` (PLAN.md:187) — штатный путь к потере доступа на всех четырёх VPS.

Что в плане сделано правильно — трогать не надо: отказ от VPN-оверлея как осознанный trade-off с компенсацией mTLS + whitelist; единые SSH host-keys SFTP (PLAN.md:143) — корректное решение для failover; `force_passive_ip` per-node (PLAN.md:146); запрет DNS round-robin для FTP (PLAN.md:155) — верно; нечётный кворум + learner для 4-й ноды (PLAN.md:11); порядок фаз etcd → Patroni → SeaweedFS → SFTPGo.

## 1. Сводка находок

| ID | Area | Anchor | Суть | Sev | Conf |
| :-- | :-- | :-- | :-- | :-- | :-- |
| F1 | SFTPGo | 138-143 | Ключи кластерного режима вымышлены/Enterprise | P0 | [C] |
| F2 | SFTPGo | 12,148 | TUS нет в OSS 2.7.6 | P0 | [C] |
| F3 | PKI/LE | 148,208 | DNS-01 не поддерживается встроенным ACME; :80 не открыт | P0 | [C] |
| F4 | Storage | 8,120,127-130 | per-node filer + `filer.sync` cross-DC = неподдерживаемый путь; WORM не проходит через sync | P0 | [C] |
| F5 | WORM↔SFTP | 8,128 | Object Lock ломает SFTP-семантику (rename = copy+delete) | P0 | [C]/[L] |
| F6 | DB routing | 138 | `target_session_attrs=read-write` не даёт SFTPGo жить на реплике | P0 | [C] |
| F7 | Firewall | 52-59 | `DOCKER-USER` сниппет режет исходящие; нет ip6tables/идемпотентности | P0 | [C] |
| F8 | Firewall | 187-191 | UFW enable без явного allow 22 → lockout, нет fallback-доступа | P0 | [L] |
| F9 | etcd WAN | 103-104 | 250/2500 валидны только при RTT ≲250 мс; RTT не измерен | P1 | [C] |
| F10 | Patroni | 99-105 | `loop_wait+2*retry_timeout <= ttl` выполнено ровно на границе | P1 | [C] |
| F11 | Patroni | 105 | failsafe_mode защищает от отказа DCS, не от изоляции ноды | P1 | [C] |
| F12 | Failover | 158-164 | TTL не ограничивает реальное переключение; нет hysteresis, арбитр внутри домена отказа | P1 | [C] |
| F13 | Failover | 173 | «0 секунд» и «прозрачно» недостижимы | P1 | [C] |
| F14 | FTPS | 144-147 | `passive_connections_security` + смена IP рвёт дата-сессии | P1 | [C] |
| F15 | FTPS | 29,34 | FTPD по умолчанию выключен; `tls_mode` не задан | P1 | [L] |
| F16 | PG recovery | 193-196 | Нет `use_pg_rewind`/`wal_log_hints` → возврат бывшего лидера = перекачка по WAN | P1 | [C] |
| F17 | Backups | 224-244 | Бэкап-слой отсутствует целиком | P1 | [C] |
| F18 | Observability | 215-217 | Нет мониторинга/алертов, нет log rotation в Docker | P1 | [C] |
| F19 | Hardening | 34,149 | SSH :22 открыт всему миру; нет `installation_code`, defender, rate limit | P1 | [C] |
| F20 | PKI | 62-66 | Root CA на Node1 без хранения/ротации/revoke; `genrsa` вместо ECDSA | P1 | [L] |
| F21 | Capacity | 117,144 | Нет temp-диска под S3, нет PASV-ёмкости, нет `volumeGrowthCount` | P1 | [C] |
| F22 | NTP | — | Нет требования к точному времени (etcd/Patroni/ACME/PG) | P1 | [C] |
| F23 | Topology | 96,120 | 4-сторонний mesh `filer.sync` — известный баг с порядком rename; нужен star | P1 | [C] |
| F24 | WebAdmin | 149 | Дефолт 2.x — 8080, а не 8081 | P2 | [C] |
| F25 | Secrets | 182 | `cluster.env` с паролями копируется на 4 VPS в plaintext | P2 | [C] |
| F26 | Versions | 9,8 | SeaweedFS не запинен; образы по тегам, без digest | P2 | [C] |
| F27 | Healthcheck | 159-163 | Зонды не включают лаг репликации | P2 | [L] |
| F28 | Deliverables | 224-244 | Нет CI/тестов/runbook promote+failback | P2 | [C] |

## 2. Blocker'ы подробно

### F1. Кластерные ключи SFTPGo: имена неверны, часть — платная

План (PLAN.md:138-143): `is_shared = 1`, единый `SIGNING_PASSPHRASE`, единый `master_key` (KMS), «кластерный режим» как данность OSS.

Факт по v2.7.6 (последний стабильный релиз, опубликован 19.09.2026):

- `is_shared` — реально существует, но как `data_provider.is_shared` (env `SFTPGO_DATA_PROVIDER__IS_SHARED=1`), не «в sftpgo.json корнем».
- `data_provider.users_policy`, `data_provider.shared.instance_name`, `base_transfer_queue_directory`, `skip_inherit_directory`, `empty_transfer_root_if_duplicate` — **в v2.7.6 отсутствуют**. Реальный межузловой механизм — `data_provider.node.host/port/proto` (`SFTPGO_DATA_PROVIDER__NODE__HOST|_PORT|_PROTO`), и в доках помечен: «Inter-node communication requires the HA feature of the Ultimate tier». То есть штатный SFTPGo-HA — это Enterprise.
- `SIGNING_PASSPHRASE` как имени env нет: есть `httpd.signing_passphrase` / `SFTPGO_HTTPD__SIGNING_PASSPHRASE` (+ `signing_passphrase_file`).
- `master_key` (KMS) лежит в топовом `kms.secrets.master_key` / `master_key_path`, env `SFTPGO_KMS__SECRETS__MASTER_KEY`. Никакого `SFTPGO_MASTER_KEY` нет.

Последствие: `sftpgo` на таком конфиге либо проигнорирует unknown-ключи молча, либо не соберёт узлы в кластер вовсе.

Что делать: принять **D1** (OSS active-passive vs Enterprise Ultimate). Для OSS-варианта: общая PG + идентичные host-keys + идентичный `kms`/`signing_passphrase` + общая файловая backing-система (в нашем случае S3) — этого достаточно для failover; «кластер» в смысле inter-node REST не нужен вообще, но и обещать одновременную работу 4 узлов нельзя.

Sources: [docs.sftpgo.com/2.7/config-file](https://docs.sftpgo.com/2.7/config-file/), [clustering (Enterprise)](https://docs.sftpgo.com/enterprise/clustering/), [KMS](https://docs.sftpgo.com/2.7/kms/), [v2.7.6 release](https://github.com/drakkan/sftpgo/releases/tag/v2.7.6).

### F2. TUS в OSS WebClient нет

План (PLAN.md:12, 148, 208) строит WebClient-докачку на TUS. Страница Features (v2.7) не упоминает TUS/resumable uploads вообще; страница Web UIs — тоже; в enterprise-доках TUS перечислен среди того, что добавляет подписка, и требует session affinity. **[C]**

Что делать: либо снять TUS из требований, либо заложить enterprise-лицензию (вместе с F1 одним решением), либо закрыть «докачку» на стороне клиента (lftp/curl `-C -`, SFTP resume работает и так).

### F3. Let's Encrypt: DNS-01 недоступен, HTTP-01 заблокирован фаерволом

План (PLAN.md:148): «автоматическое получение сертификата Let's Encrypt через встроенный ACME HTTP-01 / DNS-01».

Факт: «The ACME protocol built into SFTPGo supports `HTTP-01` and `TLS-ALPN-01` challenge types» — **DNS-01 нет**. HTTP-01 работает только на порту 80: «this challenge will only work on port `80` due to security measures». В списке открытых портов (PLAN.md:34, 190) 80 нет — только 21, 22/2022, 443, 50000-50199. Значит встроенный ACME не сможет пройти челлендж никогда. И даже с открытым :80 в active/passive схеме перевыпуск на ноде, куда домен не смотрит, будет падать (LE приходит на IP из A-записи). **[C]**

Что делать (два варианта, нужен выбор):
1. **Внешний cert-агент** (`lego --dns-<provider>` + hook, который кладёт сертификат в `/var/lib/sftpgo/certs` и делает `systemctl reload sftpgo` / SIGHUP — SFTPGo перечитывает сертификаты без рестарта) с DNS-01. Тогда :80 наружу не нужен вовсе, и валидация не зависит от активного узла. Требование LE к HTTP-01 обходится, а rate limit (5 identical certs/неделю) снимается, т.к. сертификат один на кластер и раздаётся узлам.
2. TLS-ALPN-01 на :443 — работает только на узле, куда смотрит домен, т.е. требует, чтобы каждая нода была способна пережить перевыпуск в момент, когда она не активна. Плохо.

Рекомендую (1): DNS-01 через lego/certbot, сертификат распространяется тем же `deploy-all.sh`, что и PKI-материалы.

Sources: [tutorials/lets-encrypt-certificate](https://docs.sftpgo.com/2.7/tutorials/lets-encrypt-certificate/), [features](https://docs.sftpgo.com/2.7/features/).

### F4. SeaweedFS: предложенная схема репликации — та, которую docs не рекомендуют

План (PLAN.md:8, 120): на каждой ноде свой filer, кросс-DC синхронизация только через `filer.sync` по gRPC mTLS, «обязательная» поддержка Versioning + Object Lock.

Факты:

- Wiki, Filer Store Replication, Limitation: «Multiple filers with local leveldb filer stores can work well. However, **this layout does not work well with `weed filer.sync` cross data center replication as of now** … `filer.store.id` will confuse the `weed filer.sync`». Ровно это PLAN.md:120 и предлагает. **[C]**
- `filer.sync` копирует и данные тоже (fetch content → write to the other destination), но: «limited by network bandwidth and latency… **data discrepancies if a file is changed quickly in two distant data centers**»; асинхронность = при смерти узла до синхронизации «**there will be data loss**» (issue #8562). **[C]**
- Мульти-DC по-другому у SeaweedFS тоже есть: **один** кластер с `-dataCenter`/`-rack` на volume-серверах и placement-репликацией (`defaultReplication` вида `100`/`010`, где «x = number of replica in other data centers»). Но volume-репликация **синхронная** («the write operation does not complete until replication is confirmed on all volumes», quorum W+R>N, W=N) → каждое запись платит WAN RTT и падает, когда второй ДЦ недоступен. **[C]**
- S3 Versioning/Object Lock появились в 3.94 (14.07.2025) и правились через 3.95→4.5x; Object Lock включается **только при создании бакета**, требует Versioning, нет MFA delete, `RestoreObject` не реализован, версионно-зависимый lifecycle «not fully implemented». **[C]**
- Проходят ли version-история и lock-метаданные через `filer.sync` — документально не гарантировано; вокруг полно свежих фиксов (#8710 «prevent double-versioning when syncing to versioned central bucket», #12459 «keep the remote object while a version under a delete marker is locked»). Для WORM-требования это **непроверенная зона**. **[U]**

Последствие: durabilty в сборке «Б» обеспечивается механизмом, который upstream называет проблемным, а комплаенс-требование (WORM) стоит на неподтверждённой семантике репликации.

Что делать — ключевая вилка, **D2**:
- **B1 (минимальная правка, честный active-passive):** одна «ведущая» файловая нода пишет, остальные получают `filer.sync`; DNS переключается только при лаге < порога (gate по метрике sync); RPO по данным объявляется явно (= окно sync), а не 0.
- **B2 (правильный SeaweedFS):** один кластер SeaweedFS на 3 ДЦ (3 мастера на Raft, volume с `-dataCenter`, `defaultReplication` с кросс-ДЦ копией). Цена: синхронная репликация → каждая запись = WAN RTT; при недоступности ДЦ запись падает. Плюс нужен `volumeGrowthCount`, кратный числу реплик, иначе «Not enough data nodes found!».
- **B3 (смена СУБД-слоя):** MinIO site replication — versioning + Object Lock + асинхронный cross-site replication как штатная фича. Но один узел на ДЦ не переживает (нужен эрasure-код ≥4 диска/узла либо ≥2 ноды на ДЦ).

Если цель — «не потерять файл, загруженный минуту назад» при active/passive, честнее B3 или B1 + обязательный off-cluster бэкап (F17).

Sources: [Filer Active-Active cross cluster sync](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Active-Active-cross-cluster-continuous-synchronization), [Filer Store Replication](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Store-Replication), [Replication](https://github.com/seaweedfs/seaweedfs/wiki/Replication), [S3 Object Lock and Retention](https://github.com/seaweedfs/seaweedfs/wiki/S3-Object-Lock-and-Retention), [release 3.94](https://github.com/seaweedfs/seaweedfs/releases/tag/3.94), [issue 8562](https://github.com/seaweedfs/seaweedfs/issues/8562).

### F5. WORM и SFTP-семантика конфликтуют напрямую

План требует одновременно Object Lock (PLAN.md:8,128) и полноценный SFTP/FTPS-доступ пользователей.

Факт (docs SFTPGo, S3): «`rename` is a two step operation: server-side copy and then deletion. So, it is not atomic»; «We don't support renaming non empty directories»; «`truncate`, `symlink`, `readlink` are not supported»; «opening a file for both reading and writing at the same time is not supported»; «`chown` and `chmod` will fail. … set `setstat_mode` to 1 or 2»; «A local home directory is still required to store temporary files»; «Clients that require advanced filesystem-like features such as `sshfs` are not supported»; «The configured bucket must exist». **[C]**

Ключевой конфликт: под retention-lock объект нельзя удалить, а rename в S3-бэкенде = copy+**delete**. Значит пользовательское переименование (или `rm`) залоченного файла даёт ошибку, и поведение зависит от режима (governance vs compliance) и от того, умеет ли вообще SFTPGo OSS это передавать — а ключей versioning/object-lock в S3-секции OSS-конфига нет (issue #1336 закрыт как «This is an S3 bug»). **[C]/[L]**

Что делать: разделить слои. WORM — для отдельного бакета/префикса архива (куда SFTP пишет только append-подобно и куда доступ `upload only, overwrite=false` через per-directory permissions, что в SFTPGo OSS есть). Для «рабочей» пользовательской области — versioning вместо Object Lock.

### F6. SFTPGo не сможет работать на реплике: не хватает маршрутизации к лидеру PG

План (PLAN.md:138): «Подключение к пулу Patroni PostgreSQL (`target_session_attrs=read-write`)».

Проблема: в active/passive схеме SFTPGo запущен на всех нодах, но PG на узлах 2-3 — реплика. `target_session_attrs=read-write` на реплике = ошибка подключения; SFTPGo на старте делает миграции и пишет transfer-лог → узел не поднимется/будет в crash-loop. После failover лидером станет другая нода — и конфиг должен указать на неё, а он захардкожен списком хостов. Кроме того, если SFTPGo на узле 2 подключается к лидеру на узле 1 по WAN, каждая `ls`/`stat`/auth = RTT между ДЦ, что противоречит заявлению «NVMe-speed loopback» (PLAN.md:116). **[C]**

Что делать: на каждой ноде — локальный **PgBouncer/HAProxy** перед локальным PG, с health-check «я лидер» (Patroni REST `/primary`) и `default_target_server` на себя; либо SFTPGo указывает на `127.0.0.1:5432` + сервис-логика Patroni перенаправляет не-лидера (Patroni это делает только через REST, не через PgBouncer сам). Практичный вариант: HAProxy на ноде, backend = локальный PG с `option httpchk GET /primary`, и fallback на DNS-имя текущего лидера, обновляемое тем же арбитром, что и DNS. Это отдельный компонент — в списке файлов (PLAN.md:224-245) его нет.

### F7. Сниппет `DOCKER-USER` режет исходящий трафик контейнеров

План (PLAN.md:51-60). Разбор порядка правил при `iptables -I` (вставка всегда в позицию 1): итог = `ESTABLISHED ACCEPT`, `multiport ACCEPT`, по одному ACCEPT на IP ноды, `DROP`. Для входящих — работает. Но:

- Правила ACCEPT завязаны на `--dports 21,2022,443,50000:50199` и на `-s <нода>`, т.е. описывают только **входящие**. Любой **новый исходящий** пакет из контейнера (ACME на :443 к LE, `filer.sync` на внешний peer, если IP не в списке, DNS- API, pull образов) упирается в `-j DROP`. **[C]**
- `DOCKER-USER` просматривается только в `FORWARD`-пути, т.е. только для **опубликованных** портов. Если выбран `network_mode: host` (PLAN.md:49 «ЛИБО»), весь сниппет бесполезен, а границей становится чисто хостовый UFW. Нужно выбрать одно и переписать раздел.
- Нет ip6tables: Docker публикует и v6 → v6-обход UFW останется.
- Нет идемпотентности (повтор запуска `ufw-setup.sh` множит правила), нет персистентности (`DOCKER-USER` пересоздаётся при старте dockerd; нужен `netfilter-persistent`/systemd unit), нет `--ctstate NEW -i br-+`-скоупинга, нет `ip_forward` в `/etc/ufw/sysctl.conf`.
- `multiport --dports 50000:50199` — диапазон через `:` валиден, но SFTPGo-дефолт 50000-50100 (200 портов ≠ дефолт; в плане это осознанно, но надо синхронизировать с `passive_port_range`).

Что делать: два взаимоисключающих профиля в `ufw-setup.sh --mode host|bridge`. В host-режиме — только UFW (плюс `ufw default deny incoming`, `allow 22/tcp from <admin-net>`, `allow in on lo`, `allow 80/tcp` если HTTP-01 остаётся). В bridge-режиме — канонический DOCKER-USER: `ACCEPT established,related`, `ACCEPT all from cluster IPs`, `ACCEPT <pub ports>`, `DROP`, **плюс** `ACCEPT all -o <outside-if>` для исходящих и то же самое в ip6tables, всё идемпотентно (`-C` before `-I`) и через unit, который применяется после `docker.service`.

### F8. Включение UFW без явного правила SSH и без fallback-доступа

PLAN.md:187-191: «Включение UFW с блокировкой всех входящих соединений по умолчанию». Правило `allow 22/tcp` в перечне отсутствует (порт 22 упоминается только в схеме, PLAN.md:34). Последовательность «deny incoming → enable» без предварительного allow и без проверки через serial/console/облачную консоль = гарантированный lockout при первой же опечатке, на четырёх машинах сразу, без VPN-обхода (он запрещён архитектурой, PLAN.md:7).

Что делать в `ufw-setup.sh`: (1) добавить правила до `ufw --force enable`; (2) `ufw status verbose` + self-check подключности извне перед применением; (3) `at`/systemd **rollback-таймер** («если через 120 c SSH не подтверждён — откатить»); (4) завести в `cluster.env` `ADMIN_SSH_NET` и открывать 22 только с него; (5) описать в README доступ через консоль провайдера как последний рубеж. **[L]** (вывод из текста плана, не из внешних источников)

## 3. Важные замечания (P1)

**F9. etcd-таймауты без замера RTT.** etcd tuning: «Election timeouts must be at least 10 times the round-trip time», heartbeat «normally around 0.5-1.5x the round-trip time», «The heartbeat interval and election timeout value should be the same for all members», верхняя граница election timeout 50000 ms «which should only be used when deploying a globally-distributed etcd cluster», ориентиры RTT: continental US ≈130 ms, US↔Japan 350-400 ms. Отдельно hardware-док: «Deploy etcd members within a single data center when possible… If a failure domain in another data center is required, choose a data center closer to the existing one» и «an unreliable network with partitioning outages will lead to poor availability». Значит пара 250/2500 (PLAN.md:103-104) покрывает RTT ≲250 мс — это EU↔US везёт, EU↔Asia/Аmericas-юг — нет. Максимум RTT в etcd docs не назван; **замер между конкретными выбранными VPS обязателен до фиксации таймаутов**. Также: `--strict-reconfig-check` включён по умолчанию, а восстановление через `--force-new-cluster` — «strongly discouraged because it will panic if other members from previous cluster are still alive»; это надо прописать в runbook как запрет, а не как процедуру. **[C]**

**F10. Patroni-параметры на границе допустимого.** Цитата-ограничение: «when changing values of `loop_wait`, `retry_timeout`, or `ttl` you have to follow the rule: `loop_wait + 2 * retry_timeout <= ttl`» (defaults 10/30/10, minimums 1/20/3). План даёт 10/30/10 → 30 ≤ 30, ровно впритык, без запаса на WAN-джиттер; одновременно «DCS or network issues shorter than this [retry_timeout] will not cause Patroni to demote the leader», а «shorter than ttl» — это окно, в которое записи нет. Это **D3**: какой RTO для PostgreSQL приемлем (10-30 s против 60 s)? Если ДЦ разношены, разумно ttl 60 / retry_timeout 15 / loop_wait 10 (10+30 ≤ 60). **[C]**

**F11. failsafe_mode обоснован неверно.** PLAN.md:105 называет его «защитой от ложного Split-Brain при кратковременном скачке сетевой задержки». Реально: фича введена в **Patroni 3.0.0** и «makes it possible to survive temporary **DCS outages** without demoting primary»; механика — «the existing primary connects to all members presented in the `/failsafe` key via the `POST /failsafe` REST API and may continue to run as a primary **if all replicas acknowledge it**. **If one of the members doesn't respond, the primary is demoted**». То есть при изоляции самой лидер-ноды failsafe **не** спасает, и обязательное предусловие — `restapi.connect_address` доступен со всех узлов (+ `check_timeline` по умолчанию `false`). В план нужно добавить это предусловие в UFW-раздел (8008 доступен между нодами — есть) и переформулировать назначение. **[C]**

**F12-F13. DNS-failover: цифры и обещания не сходятся.**
- PLAN.md:172 обещает 10-30 с на весь цикл (demote + выборы + смена A-записи). Patroni: «the node is allowed to run Postgres as the primary only if it can update the leader lock in DCS. In case the update of the leader lock fails, Postgres is immediately demoted and started as read-only», новый лидер берёт лок — суммарно до `ttl` (30 c) **плюс** обнаружение (loop_wait) **плюс** сам DNS. Реалистично 40-90 c.
- PLAN.md:173 «Мгновенно (0 секунд простоя для кластера)» — для записи это неверно: изолированный лидер demote'ится, а новый ещё не выбран, т.е. окно read-only до ttl.
- TTL 30-60 c не ограничивает клиентское переключение: RFC 2181 §8 — «Implementations are always free to place an upper bound on any TTL received… The TTL specifies a maximum time to live, not a mandatory time to live»; установленные TCP-сессии SFTP/FTPS домен не пере-резолвят вообще никогда. Прецедент по анти-flapping: Route 53 — интервал 10-30 c, failure threshold 3, и «The 18% value was chosen to make sure that health checkers in multiple regions… prevents an endpoint from being considered unhealthy only because network conditions have isolated the endpoint». Отсюда: `dns-failover.sh` «на внешнем арбитре **или нодах кластера**» (PLAN.md:159) — запуск внутри домена отказа недопустим, нужен ≥1 внешний арбитр с собственной проверкой (или облачный health-check как условия записи).
- Failback в плане не описан: без cooldown и «кто сейчас владелец A-записи» получится осцилляция. **[C]**

**F14. FTPS PASV + смена активного узла.** Дефолт `passive_connections_security` = требовать совпадения peer-IP control- и data-соединений; `force_passive_ip` — «Must be a valid IPv4 address if set» (шаблон-имя хоста не примет). Клиенты это обходят флагами (`lftp`: `ftp:ignore-pasv-address`, `ftp:fix-pasv-address`), но FileZilla/WinSCP при смене IP в разе сессии получат рассинхрон. Так что «переключение прозрачно» (PLAN.md:164) для FTPS — нет. Добавь в план: смена DNS только между сессиями, плюс явное указание `passive_host`/`passive_ip_overrides` и явный `force_passive_ip` = PUBLIC_IP узла, который обслуживает сессию. **[C]**

**F15. FTPD по умолчанию не слушает :21.** В примерах и дефолтах 2.x FTP-биндинг идёт на 2121, а «включён» он только если задан порт; в плане (PLAN.md:29,34,190) :21 уже считается открытым. Плюс для «FTPS» обязателен `SFTPGO_FTPD__BINDINGS__0__TLS_MODE=1` (в docs-примере именно `tls_mode: 1` = TLS для control и data), которого в плане нет. **[L]** — проверить выводом `sftpgo env`/дефолтного конфига на целевом хосте до генерации шаблонов.

**F16. Возврат бывшего лидера не спроектирован.** `pg_rewind` — «for synchronizing a PostgreSQL cluster with another copy of the same cluster, **after the clusters' timelines have diverged**. A typical scenario is to bring an old primary server back online after failover»; требует «`wal_log_hints` … enabled … or data checksums enabled», и «if the target cluster ran for a long time after the divergence, its old WAL files might no longer be present» → «taking a new fresh backup is recommended». Patroni это автоматизирует только при `use_pg_rewind: true` (default false) и/или `remove_data_directory_on_diverged_timelines: true` (default false). В плане (PLAN.md:99-105, 193-196) ни одного из них нет → после первого же реального failover нода 1 возвращается ручной перекачкой GB/TB по WAN. Это же решает и выбор `wal_level`/checksum на этапе инициализации кластера — потом `data_checksums` не включить. **[C]**

**F17. Бэкапов нет.** В спецификации файлов (PLAN.md:224-245) нет ни `pgbackrest`, ни выгрузки бакетов, ни off-cluster хранилища. Нужно прописать: (а) WAL-архив + полный бэкап PG **вне** кластера (другой провайдер/регион), (б) отдельная immutable-копия бакета/префикса WORM (versioning и Object Lock — это не бэкап: они не спасают от удаления всего кластера и не дают точки восстановления вне кластера), (в) регулярный **restore-тест** (без него бэкап не существует). Отдельно заметка про 2.7.6: в нём исправлены 4 security- advisories, включая stored XSS в WebClient (GHSA-f9qc-3v4f-32w3) и неиспользуемые share-ссылки при отключённом аккаунте (GHSA-5jhj-cjcp-jr8r) — для публичного файлового сервиса это аргумент фиксировать версию не ниже 2.7.6. **[C]**

**F18. Нет observability и ротации логов.** `restart: always` (PLAN.md:174) без `depends_on: condition: service_healthy` и без healthcheck'ов даст старт SFTPGo раньше лидера PG. Docker json-file по умолчанию без `max-size` → переполнение диска кладёт и PG, и volume-серверы (SeaweedFS отдельно требует «leave some disk space for a couple of volume size, so that the compaction can run»). SFTPGo, Patroni, etcd и SeaweedFS отдают Prometheus-метрики — стек и алерты (etcd leader changes, PG replication lag, `filer.sync` lag, watermark диска, expiry сертификатов) должны быть в плане файлами и фазами. **[C]**

**F19. Hardening периметра.** SSH :22 открыт «для всего мира» (PLAN.md:34) на всех узлах при отказе от VPN — для файлового сервиса под комплаенс это лишний вектор; минимум: restrict по `ADMIN_SSH_NET`, `PasswordAuthentication no`, fail2ban. В SFTPGo есть встроенный defender — правильные ключи: `common.defender.enabled/driver/threshold/observation_time/ban_time` (дефолт `enabled=false`, `driver=memory`, ban_time 30 min, threshold 15), и для кластера docs советуют `driver=provider`, «so that a ban applies to every node» (с оговоркой: «list entries propagation between nodes may take some minutes»). Плюс отдельный, неочевидный риск из доков: «Until an admin account exists, the setup screen is available to anyone who can reach the WebAdmin. Set an `installation_code`» — в плане про `installation_code` ничего нет, а `deploy-all.sh` создаёт админа потом. И `common.max_per_host_connections` (20) / `max_total_connections` / per-protocol rate limiting в плане не заданы. **[C]**

**F20. PKI: не хватает halves.** (PLAN.md:62-66) описаны генерация CA и «ключи не передаются», но нет: где и как защищён root-ключ CA (Node 1 = единая точка компрометации), нет срока действия/цикла ротации серверных сертификатов, нет CRL/revoke при компрометации ноды, нет раздельных leaf-наборов для etcd/PG/SeaweedFS/Patroni. Практические правки: ECDSA P-256 вместо `genrsa` (дешевле handshake по WAN), SAN = и IP, и hostname **всех** узлов, и подключение всегда по имени из SAN (Go-валидация по IP работает только если IP в SAN). Отдельно из Patroni docs: с `etcd3` «Patroni uses Etcd's gRPC-gateway… **TLS common name authentication is not possible**», и рекомендуется `etcd.use_proxies`, чтобы Patroni не делал topology discovery. **[C]**

**F21. Ёмкость не посчитана.** Нужны явные числа в `cluster.env.example`: (а) локальный temp-диск под S3 («A local home directory is still required to store temporary files»; multipart-буферы + `common.temp_path`, который «must reside on the same filesystem as user home directories, otherwise atomic renames become copies»); (б) PASV-ёмкость: 200 портов = ~200 одновременных дата-сессий, при превышении клиент получит refused — либо расширять диапазон, либо ограничивать `max_total_connections`; (в) для SeaweedFS — предсозданные writable volumes на каждый ДЦ (`fs.configure -volumeGrowthCount`, «multiple of the number of replicas»), иначе запись в «холодный» ДЦ падает с «Not enough data nodes found!»; (г) `-volumeSizeLimitMB` и «at least 7 volumes… 30GB» на бакет. **[C]**

**F22. Нет NTP-требования.** Для etcd (lease/heartbeat), Patroni (ttl), ACME и mTLS-валидации время обязательно; на четырёх VPS из разных ДЦ без chrony будут «false elections». В план нужен шаг фазы 2: `chrony`/`systemd-timesyncd` + проверка `timedatectl` в `cluster-health.sh`. **[C]** (вывод из требований upstream-дов по etcd/Patroni, см. F9)

**F23. Топология синхронизации: 4-сторонний mesh сломан по документации.** Upstream помечает проблему порядка rename в fully-connected loops («rename ordering breaks in fully-connected loops»). При 4 узлах с перекрёстными `filer.sync`-парами (PLAN.md:200) это ускорит рассинхрон. Решение: **star** — DC1 (ведущий) → DC2/DC3/DC4, `-isActivePassive`, `-concurrency`/`-chunkConcurrency`, `-a.fromTsMs` для первичного наполнения, `-a.security`/`-b.security` для mTLS (PR #8872), plus учти 30-минутное «give-up» окно для vacuumed chunks (issue #12175). **[C]**

## 4. Гигиена (P2)

**F24.** WebAdmin на `127.0.0.1:8081` (PLAN.md:12,149): в 2.x дефолт — `http://127.0.0.1:8080/web/admin`, 8081 в шаблонах 2.x не встречается; биндинг задаётся через `httpd.bindings[].address`/`port` (**не** `ip_address`). Если 8081 — осознанный выбор, пусть будет явно в шаблоне; WebClient же на :443 требует отдельного binding с `enable_https=1` + `certificate_file`. **[C]**

**F25.** Секреты: единый `cluster.env` со всеми паролями хранится в plaintext на рабочих машинах + копируется scp на 4 VPS (PLAN.md:214). Нужны: sops/age-шифрование файла в git, отдельный `.gitignore`, `install -m 600` на узлах, и отсутствие секретов в docker-compose (env_file вместо inline). Отдельно — не коммитить `cluster.env` и не положить его в артефакты Docker-образа. **[C]**

**F26.** Версии: SeaweedFS не запинен вообще (PLAN.md:8), а Versioning/Object Lock живут только с 3.94 и правились в 4.5x → нужен явный `seaweedfs:4.x.y` + digest; Patroni «3.x» — ок, но `failsafe_mode` требует одинаковой версии на всех членах («please make sure that Patroni version on all members is up-to-date»); SFTPGo — пинить `>=2.7.6` из-за security-фиксов. **[C]**

**F27.** Зонды `dns-failover.sh` (PLAN.md:159-163) проверяют только «порт живой» (:21, :2022, :8008, :8333). Для корректного решения нужны: роль PG (`/primary` vs `/replica`), лаг `filer.sync`, свежий heartbeat узла, и **cooldown/кворум мнений** арбитров; иначе арбитр переключит DNS на узел, у которого нет последних файлов. **[L]**

**F28.** В спецификации файлов нет: `scripts/ufw-rollback`/persist-юнита, `configs/seaweedfs/s3.json` + шага инициализации бакетов (Object Lock включается только при создании — значит `bucket create --object-locking-enabled` должен быть до первого PUT), `configs/haproxy|pgbouncer` (F6), lego/certbot-шаг (F3), `tests/` или compose-лаборатории для имитации partition, `.github/workflows` (lint shell + `docker build` + `sftpgo serve --check-config`?), и README-разделов «DR runbook: promote», «failback», «cert rotation», «node replacement». **[C]**

## 5. Решения, которые нужны от тебя (D-таблица)

| ID | Вопрос | Варианты | Рекомендация | Цена выбора |
| :-- | :-- | :-- | :-- | :-- |
| D1 | Лицензия SFTPGo | OSS / Enterprise Ultimate | **OSS + active-passive**: убрать TUS и inter-node HA из требований | подписка vs отказ от WebClient-докачки и «горячего» кластера |
| D2 | Слой данных | B1 SeaweedFS + star sync / B2 один SeaweedFS на 3 ДЦ / B3 MinIO site replication | **B1 для v1** (честный RPO) + обязательный off-cluster бэкап; B2/B3 — если RPO≈0 по файлам | B2 = WAN RTT на каждую запись; B3 = ≥2 ноды или ≥4 диска на узле |
| D3 | RTO/RPO | PG: ttl 30 vs 60; данные: 0 vs окно sync | **PG 60 c / данные — явный RPO ≤ N c**, прописать числом в README | 30 c чаще даёт ложные demote при джиттере |
| D4 | RTT между выбранными ДЦ | замерить до фиксации состава | **обязательный замер 3 пар, 100 пакетов** | если >250 мс — WAN-etcd отзывается, состав ДЦ меняется |
| D5 | SSH :22 | публичный / `ADMIN_SSH_NET` / bastion | **restrict + key-only + fail2ban** (у тебя уже есть xray/WireGuard-навыки, один туннель для админа не ломает «no-VPN» для клиентов) | чуть больше операционных шагов |
| D6 | Бэкапы | провайдер, retention, restore-тест | off-cluster S3 у **другого** провайдера, GFS-retention, еженедельный auto-restore-тест | +стоимость хранилища |
| D7 | Мониторинг | локальный VictoriaMetrics/Grafana / облачный | внешний арбитр = он же монитор (убиваем двух зайцев: F12 + F18) | 1 маленькая VPS |
| D8 | Failback | manual / auto с cooldown | **manual** | auto = риск осцилляции при кратковременном восстановлении |

## 6. Что проверить до генерации файлов (V-шаги)

1. `sftpgo --version` + `sftpgo env` (или дефолтный `sftpgo.json`) на целевом VPS → grep по `is_shared`, `node`, `kms`, `signing_passphrase`, `defender`, `ftpd`, `passive`. Закрывает F1/F15/F24 и даёт единственный источник истины по именам ключей.
2. `weed filer.sync -h`, `weed -h`, `weed shell` → наличие `-isActivePassive`, `-a.security`, object-lock команд; зафиксировать версию (F4/F26).
3. RTT-матрица между 3-4 выбранными VPS (`ping -c 100`, mtr) → до выбора etcd-таймаутов (F9, D4).
4. Лаборатория на одном хосте: 3 compose-ноды + `iptables DROP` между узлами → замерить реальное время demote/promote, поведение SFTPGo при потере PG, поведение DNS-арбитра (F10/F11/F12/F6). Это же станет base для `tests/` (F28).
5. Тестовый бакет с Object Lock + `filer.sync` между двумя инстансами: проверить, доживают ли version history и lock-метаданные после синхронизации, и что делает SFTP-`mv` на залоченном объекте (F4/F5) — это тот пункт, где косвенные знания кончаются.

## 7. Ключевые источники

- SFTPGo 2.7: [config-file](https://docs.sftpgo.com/2.7/config-file/) · [clustering (Enterprise)](https://docs.sftpgo.com/enterprise/clustering/) · [S3 backend](https://docs.sftpgo.com/2.7/s3/) · [KMS](https://docs.sftpgo.com/2.7/kms/) · [defender](https://docs.sftpgo.com/2.7/defender/) · [Let's Encrypt tutorial](https://docs.sftpgo.com/2.7/tutorials/lets-encrypt-certificate/) · [features](https://docs.sftpgo.com/2.7/features/) · [Web UIs](https://docs.sftpgo.com/2.7/web-interfaces/) · [v2.7.6 release notes](https://github.com/drakkan/sftpgo/releases/tag/v2.7.6) · [issue #1336](https://github.com/drakkan/sftpgo/issues/1336)
- SeaweedFS: [Filer Active-Active cross-cluster sync](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Active-Active-cross-cluster-continuous-synchronization) · [Filer Store Replication (Limitation)](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Store-Replication) · [Replication / placement](https://github.com/seaweedfs/seaweedfs/wiki/Replication) · [S3 Object Lock and Retention](https://github.com/seaweedfs/seaweedfs/wiki/S3-Object-Lock-and-Retention) · [S3 Object Versioning](https://github.com/seaweedfs/seaweedfs/wiki/S3-Object-Versioning) · [release 3.94](https://github.com/seaweedfs/seaweedfs/releases/tag/3.94) · [issue #8562](https://github.com/seaweedfs/seaweedfs/issues/8562) · [discussion #8481](https://github.com/seaweedfs/seaweedfs/discussions/8481)
- etcd/Patroni/PG: [etcd tuning](https://etcd.io/docs/v3.5/tuning/) · [etcd hardware](https://etcd.io/docs/v3.5/op-guide/hardware/) · [etcd FAQ](https://etcd.io/docs/v3.5/faq/) · [etcd runtime reconfig](https://etcd.io/docs/v3.5/op-guide/runtime-configuration/) · [Patroni DCS failsafe](https://patroni.readthedocs.io/en/latest/dcs_failsafe_mode.html) · [Patroni standby clusters](https://patroni.readthedocs.io/en/latest/standby_cluster.html) · [pg_rewind](https://www.postgresql.org/docs/current/app-pgrewind.html) · [RFC 2181 §8](https://www.rfc-editor.org/rfc/rfc2181) · [lftp man](https://lftp.yar.ru/lftp-man.html) · [Route 53 failover](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-failover.html)
