# Виток 2: спор и критика собственного аудита PLAN.md

Продолжение: `DISPUTE-3.md` (виток 3) — спор уже с этим документом. Там аннулированы/сужены B1 `clonefrom` и WAN, A1 в части checksum, автоматизм §10.3 (SPOF admin), приёмочное «≤17 мин» §10.7, `upload_mode=2` на WORM-бакете §4 п.3, покрытие mTLS §4 п.5. При расхождении читать виток 3.

Объект спора: `/Users/aleksey/Documents/ftp/AUDIT-PLAN.md` (виток 1, 28 находок) и сам `PLAN.md` (245 строк).
Метод: каждое моё утверждение витка 1 перепроверено по первичному источнику (docs upstream, исходники в клоне, GitHub API, комментарий мейнтейнера). Где нашлись данные против — утверждение **аннулируется явно**, а не защищается.
Уверенность: **[C]** = первичный источник, процитирован дословно и проверен мной в этом витке; **[L]** = косвенное/вывод; **[U]** = не проверено, нужен замер.
Код и конфиги не правились. Сетевые пробы — только read-only.

## 0. Вердикт витка

**Из 28 находок витка 1: 1 аннулирована полностью (F6), 5 сужены/исправлены (F1, F4, F5, F14, F19), 1 снята сменой архитектуры (F23), 21 выдержала проверку без изменений.**
Дополнительно аннулированы 2 моих собственных тезиса вне нумерации находок: «потеря одного ДЦ = отказ записи» (A9) и вариант B3 «MinIO site replication» (A10).
Blocker'ов (P0) было 8 → стало **5**: F2 (TUS), F3 (ACME/:80), F4 (топология filer), F7 (DOCKER-USER), F8 (UFW lockout).
Главная ошибка витка 1: я объявил платным то, что в OSS работает, и потребовал отдельный компонент (HAProxy/PgBouncer) там, где он не нужен. Из-за этого план выглядел хуже, чем есть.
Главная ошибка самого плана, которая **не** снялась: слой данных построен на topology, которую upstream прямо называет нерабочей, и на обещаниях «0 секунд» / «прозрачно», которые не выполняются.

Нового в этом витке: 12 находок, которых в аудите не было (§3), включая две, меняющие выбор движка: **репозиторий MinIO архивирован** (мой вариант B3 мёртв) и **у SeaweedFS есть собственный SFTP-сервер и TUS** (появились/обновлены в wiki 27.10.2026). Двенадцатая (N12) найдена при разборе сценария «падает ДЦ с лидером PG» и исправляет мою же рекомендацию §4.

Требование «возврат узла — автоматически» принято как скоуп и пересобрано в **§10**: ключи Patroni, etcd catch-up, встроенный авторемонт репликации SeaweedFS, DNS-failback с воротами. Там же исправлен мой собственный RTO: «40–90 с» держались только при явно заданном `primary_start_timeout`, с дефолтом 300 worst case = 320 с.

---

## 1. Аннулировано и сужено (мои утверждения против фактов)

### A1. «Штатный SFTPGo-HA — это Enterprise» (F1) — АННУЛИРОВАНО

Виток 1 писал: inter-node REST помечен «requires the HA feature of the Ultimate tier», значит кластер = подписка.
Факт, страница Enterprise Clustering & HA, раздел **Active/standby**, дословно:

> «This setup does not need the HA feature and works with every [tier](https://sftpgo.com/on-premises).»
> «The **Node** and **Signing passphrase** settings **do not apply**. Sessions are not carried over: after a switchover, WebAdmin and WebClient users sign in again.»

Источник: <https://docs.sftpgo.com/enterprise/clustering/> **[C]**

Следствие: для схемы плана (один активный узел, DNS-failover) не нужны ни `data_provider.node`, ни `httpd.signing_passphrase`. План требовал общий `SIGNING_PASSPHRASE` (PLAN.md:141) — это **лишнее требование**, а не «неверное имя ключа». Моя формулировка F1 «часть — платная» снимается.
Что остаётся от F1 (переведено в P1, гигиена конфига): `is_shared` лежит в `data_provider`, KMS-ключ — в `kms.secrets.master_key` (env `SFTPGO_KMS__SECRETS__MASTER_KEY`), `signing_passphrase` — в `httpd`. Имена в плане надо привести к реальным, но на работоспособность active/passive это не влияет. **[C]**

### A2. Критика ключей, которых в плане нет (F1) — АННУЛИРОВАНО

Виток 1 ругал `users_policy`, `shared.instance_name`, `base_transfer_queue_directory`, `skip_inherit_directory`, `empty_transfer_root_if_duplicate`.
Проверка: `grep -n "users_policy\|instance_name\|base_transfer_queue\|skip_inherit\|empty_transfer_root" PLAN.md` → **0 совпадений**. План этих ключей не использует. Я критиковал соломенное чучело. Пункт удалён из зачёта. **[C]**

### A3. «SFTPGo не живёт на реплике, нужен HAProxy/PgBouncer» (F6, был P0) — АННУЛИРОВАНО

Виток 1 утверждал: `target_session_attrs=read-write` на реплике = ошибка, узел уйдёт в crash-loop, нужен локальный роутер к лидеру.
Факт, OSS-доки 2.7, config-file, `data_provider`:

> `host`: «Database host. For `postgresql` and `cockroachdb` drivers, you can **specify multiple hosts separated by commas**.»
> `target_session_attrs`: «Typically used with multiple host names to **select the first acceptable alternative**. Supported values: `any`, `read-write`, `read-only`, `primary`, `standby`, `prefer-standby`.»

Источник: <https://docs.sftpgo.com/2.7/config-file/> **[C]**

То есть строка PLAN.md:138 **корректна как есть**: `host="IP1,IP2,IP3"` + `target_session_attrs=read-write` — это штатный libpq-перебор до writable-узла. Никакого HAProxy/PgBouncer не требуется, и мой пункт «этого компонента нет в списке файлов» (F28) отменяется в этой части.
Что остаётся (P1, производительность, не блокер): когда лидер PG в другом ДЦ, каждая аутентификация/`ls`/`stat` и **каждое новое соединение** (defender, см. N4) платят WAN RTT. Заявление «NVMe-speed loopback» (PLAN.md:116) верно только для локального S3-gateway, но не для метаданных.
Дополнительно найдено готовое решение для миграций: `update_mode` — «`0` means automatically. `1` means manually using the `initprovider` sub-command» → ставим `1` и один раз прогоняем `sftpgo initprovider`, чтобы 4 узла не делали DDL одновременно. **[C]**

### A4. «Object Lock ломает SFTP rename» (F5, был P0) — МЕХАНИЗМ АННУЛИРОВАН

Виток 1: rename в S3 = copy + delete, залоченный объект удалить нельзя → rename падает.
Факт, SeaweedFS wiki S3-Object-Versioning, раздел «When Versioning is Enabled»:

> «**DELETE Object**: Creates a delete marker (soft delete)»
> «**DELETE Object with version ID**: Permanently deletes that specific version»

Источник: <https://github.com/seaweedfs/seaweedfs/wiki/S3-Object-Versioning> (клон `/tmp/swfs-wiki`, строки 107–108) **[C]**

SFTPGo шлёт DELETE **без VersionId** → создаётся delete marker, retention не проверяется. Значит `mv` и `rm` залоченного файла в versioned-бакете **проходят**, а сама версия остаётся неизменяемой — ровно то, что нужно WORM. Мой «прямой конфликт» снят.
Что остаётся от F5 (P1, реальные ограничения S3-бэкенда, не выдуманные): rename неатомарен (copy+delete), «We don't support renaming non empty directories», `truncate`/`symlink`/`readlink` не поддержаны, `chown`/`chmod` падают → `setstat_mode` 1|2, локальный home нужен под temp-файлы, `sshfs` не работает. Источник: <https://docs.sftpgo.com/2.7/s3/> **[C]**
Комплаенс-нюанс, который надо объявить: пользователь видит файл «удалённым», но версия жива до истечения retention. Для WORM это плюс, для UX — сюрприз. **[L]**

### A5. «SeaweedFS не рекомендует per-node filer + sync» (F4) — СУЖЕНО, и найден благословлённый путь

Виток 1 цитировал Limitation из wiki и делал вывод про всю связку. Полная цитата показывает, что ограничение **про leveldb**, а не про репликацию вообще:

> «Each filer store will auto generate a unique `filer.store.id`. So **for shared filer stores, such as mysql/postgres/redis, there is no need to setup peers** because the `filer.store.id` will be the same.»

Благословлённая топология в той же странице: `filer1(mysql) <-> filer2(mysql)`. Запрещённая: `filer1(leveldb) <--XX NOT WORKING XX---> filer2(mysql)`.
Источник: <https://github.com/seaweedfs/seaweedfs/wiki/Filer-Store-Replication> **[C]**

Следствие: проблема плана (PLAN.md:120) — не «filer.sync через ДЦ» сам по себе, а **N локальных leveldb-сторов**. Лечится не отказом от SeaweedFS, а переходом на **один кластер + общий PostgreSQL filer store** (`[postgres2]`), где `filer.sync` не нужен вообще. F4 остаётся P0 (текущая схема нерабочая), но получает конкретное штатное решение вместо «смените движок».
Ключи стора проверены по исходникам (`weed/command/scaffold/filer.toml:158–195`): `enabled`, `hostname`, `port`, `username`, `password`, `database`, `schema`, `sslmode = "disable"` (по умолчанию!), `sslcert`/`sslkey`/`sslrootcert`/`sslcrl` для `verify-full`, `connection_max_idle = 50`, `connection_max_open = 50`, `connection_max_lifetime_seconds = 300`, `pgbouncer_compatible`, `enableUpsert`. **[C]**

### A6. Доказательство «data loss» по issue #8562 — УВЕРЕННОСТЬ ПОНИЖЕНА [C] → [L]

Виток 1 подал цитату «there will be data loss» как решение мейнтейнера. Перепроверка: это **комментарий контрибьютора**, пересказывающий wiki, а не ruling мейнтейнера. Сам факт асинхронности и окна потери остаётся верным (он следует из природы async-репликации), но вес доказательства ниже заявленного. **[L]**

### A7. «План ошибся с force_passive_ip» (F14) — СУЖЕНО: план прав

Факт, config-file:

> `force_passive_ip`: «External IPv4 address for passive connections. Leave empty to auto-detect. **Must be a valid IPv4 address if set**.»
> `passive_host`: «Hostname for passive connections. **Resolved on each passive connection request**, which may introduce noticeable latency depending on DNS configuration. **Enable only if you have a dynamic IP address**.»

Источник: <https://docs.sftpgo.com/2.7/config-file/> **[C]**

Подстановка индивидуального `PUBLIC_IP` (PLAN.md:146) — **корректное решение**, а `passive_host` для статических белых IP не нужен и добавил бы DNS-задержку на каждое дата-соединение. Моя рекомендация «указать passive_host» отзывается.
Что остаётся (P2, объявить ограничение): при смене активного узла mid-session FTPS-дата-соединение рвётся; `passive_connections_security=0` требует совпадения peer-IP control/data. Это свойство протокола, не дефект плана.

### A8. Defender: «бан распространяется минутами» (F19) — ИСПРАВЛЕНО

Виток 1 смешал два разных механизма. Дословно со страницы defender:

> про `provider`: «the defender implementation may do many database queries (**at least one query every time a new client connects to check if it is banned**)»
> про списки: «The `defender` can also check **permanent block and safe lists** of IP addresses/networks… In multi-nodes setups, **the list entries propagation between nodes may take some minutes**.»

Источник: <https://docs.sftpgo.com/2.7/defender/> **[C]**

«Минуты» относятся к permanent block/safe **спискам**, а не к банам: бан проверяется запросом в БД на каждом соединении. recommendation `driver=provider` остаётся, оговорка про минуты переносится на списки.

### A9. Моё собственное «потеря ДЦ = отказ записи» (из пересборки топологии) — АННУЛИРОВАНО

В прошлом витке я написал, что при синхронной кросс-ДЦ репликации падение одного ДЦ останавливает запись (fail-closed). Исходники это опровергают:

> `weed/operation/upload_content_test.go:186–188`: «A volume whose replica peer is down reports "failed to write to replicas": the primary write lands but replication fails. **The client must re-assign to a volume on live nodes and retry rather than losing the write.**»
> Тест: `TestUploadWithRetryDataReassignsOnReplicaWriteFailure` — 3 неудачные попытки на volume-a, затем re-assign на volume-b и успех.

Клон `/tmp/swfs-src`, проверено чтением файла. **[C]**

Точная формулировка вместо прежней: при `defaultReplication=100` (2 копии в разных ДЦ) и **трёх** ДЦ потеря одного ДЦ запись переживает — клиент переназначается на живые узлы. Отказ записи наступает, когда живых ДЦ меньше, чем требует placement (остался 1 ДЦ при `100`, или 2 ДЦ при `200`). Прежний тезис «потеря одного ДЦ = write outage» неверен для 3-ДЦ схемы.
Остаётся непроверенным **[U]**: что происходит с метаданными filer, если volume-запись прошла, а коммит в PG — нет (осиротевшие чанки). Это пункт лабораторного теста, не утверждение.

### A10. Вариант B3 «MinIO site replication» (F4/D2) — АННУЛИРОВАН, движок мёртв

Виток 1 рекомендовал MinIO как штатную альтернативу с versioning + object lock + async site replication. Перепроверка через GitHub API (первично):

```
gh api repos/minio/minio → {"archived": true, "pushed_at": "2026-04-24T17:54:39Z", ...}
```

Репозиторий **архивирован** (по сообщениям сообщества — 12.02.2026, с пометкой «THIS REPOSITORY IS NO LONGER MAINTAINED»), site replication из бесплатной версии убран, развитие ушло в коммерческий AIStor. Лицензия AGPL-3.0.
Источники: GitHub API `repos/minio/minio` **[C]**; [обсуждение #21318](https://github.com/minio/minio/discussions/21318), [MinIO AIStor vs OSS](https://www.min.io/blog/minio-aistor-vs-minio-oss-technical-comparison), [разбор архивации](https://thecloudsupportengineer.com/the-end-of-an-era-minio-community-edition-is-archived-whats-next/) **[L]** (вторичные, порядок величин).
Следствие: B3 исключается из выбора. Заодно это снимает мой непроверенный лицензионный тезис — проверять больше нечего, движок не поддерживается.

### A11. F23 «4-сторонний mesh filer.sync сломан» — СНЯТО СМЕНОЙ АРХИТЕКТУРЫ

Не опровергнуто: при переходе на один кластер с общим PG-стором `filer.sync` между нодами не нужен, и пункт про mesh/star теряет предмет. Если же останется вариант со sync (D2), star + `-isActivePassive` по-прежнему обязателен; флаг проверен в исходниках: `weed/command/filer_sync.go:94` — «one directional follow from A to B if true», и там же «filer.sync only works between two filers». **[C]**

---

## 2. Что выдержало проверку

21 находка подтверждена без изменений. Ниже они вместе с F4 и F19, которые сужены (§1), но остались в зачёте.

| ID | Суть | Sev виток 2 | Что изменилось в доказательствах |
| :-- | :-- | :-- | :-- |
| F2 | TUS нет в OSS WebClient | **P0** | Усилено: в OSS-странице Web UIs TOC = только WebAdmin/WebClient/Internationalization, **секции «Reverse proxies and load balancers» и TUS нет вообще**; Enterprise ссылается на свою `../web-interfaces/#reverse-proxies-and-load-balancers`. [C] |
| F3 | Встроенный ACME без DNS-01; :80 не открыт | **P0** | Подтверждено: `http01_challenge.port` = 80, есть `webroot`/`proxy_header`; DNS-01 отсутствует. [C] |
| F4 | Топология filer нерабочая | **P0** | Сужено (A5), но остался блокером: N leveldb + sync = запрещённая wiki топология. Решение — общий PG-стор. [C] |
| F7 | DOCKER-USER режет исходящие | **P0** | Без изменений: ACCEPT только по `-s`/`--dports`, новый исходящий → DROP; host-сеть делает сниппет бессмысленным. [C] |
| F8 | UFW enable без allow 22 → lockout | **P0** | Без изменений. [L] |
| F9 | etcd 250/2500 без замера RTT | P1 | Без изменений: election ≥ 10×RTT, heartbeat ≈ 0.5–1.5×RTT. [C] |
| F10 | `loop_wait+2*retry_timeout <= ttl` впритык | P1 | Без изменений: 10+20 ≤ 30 ровно на границе. [C] |
| F11 | failsafe_mode — про отказ DCS, не изоляцию ноды | P1 | Без изменений: требует ack **всех** членов, иначе demote. [C] |
| F12/F13 | «10–30 с», «0 секунд», «прозрачно» | P1 | Без изменений: RFC 2181 §8 (TTL — максимум), Route 53 threshold 3 / 18%. Мои «40–90 с» уточнены в §10.1: с дефолтным `primary_start_timeout` 300 worst case = 320 с; объявлять ≈100–150 с для клиента. [C] |
| F15 | FTPD по умолчанию не слушает | P1 | **Уверенность поднята [L]→[C]**: config-file, `ftpd.bindings[].port` default `0`, «Port for serving FTP requests. `0` disables the binding.» Плюс `tls_mode` default 0. |
| F16 | Нет `use_pg_rewind`/`wal_log_hints` | P1 | Повышено до обязательного: возврат узла должен быть автоматическим (§10.1), добавлены permanent slots и `remove_data_directory_on_*`. [C] |
| F17 | Бэкап-слой отсутствует | P1 | Усилено конкретным решением (N9). [C] |
| F18 | Нет мониторинга/ротации логов | P1 | Без изменений. [C] |
| F19 | SSH :22 миру, нет installation_code/defender/rate limit | P1 | Defender-оговорка исправлена (A8); `installation_code` подтверждён дословно: «Until an admin account exists, the setup screen is available to anyone who can reach the WebAdmin.» [C] |
| F20 | PKI без хранения/ротации/revoke | P1 | Усилено: найдены ключи mTLS до PG (N10). [C] |
| F21 | Ёмкость не посчитана | P1 | Усилено двумя числами из docs (N2, N3) и проверкой в исходниках: `volumeGrowthCount %d should be divided by replication copy count %d` (`weed/shell/command_fs_configure.go:137–138`). [C] |
| F22 | Нет NTP-требования | P1 | Без изменений. [C] |
| F24–F28 | WebAdmin 8080, секреты, версии, зонды, deliverables | P2 | F24 подтверждён: дефолт `http://127.0.0.1:8080/web/admin`. F28 лишён пункта про HAProxy (A3). [C] |

Версии перепроверены GitHub API: `drakkan/sftpgo` latest = **v2.7.6**, published 19.09.2026 **[C]**; `seaweedfs/seaweedfs` не архивирован, push 23.11.2026, лицензия **Apache-2.0** **[C]**.

---

## 3. Новые находки витка 2 (которых не было в аудите)

**N1. Окно ~10 минут: отключённый аккаунт может пережить failover.** Мейнтейнер (drakkan), комментарий проверен через `gh api repos/drakkan/sftpgo/issues/comments/4816494623`:

> «In the open-source edition this is by design. The node that performs the change updates its own cache immediately; peers pick it up on their next refresh. It's a fixed interval… Immediate cross-node cache invalidation… is part of the HA/clustering in the Enterprise edition. For the OSS setup, **the 10-minute window is the expected propagation time**.»

Механизм **[C]**, следствие для active/passive **[L]**: standby-узел обновляет кэш периодически, поэтому в момент переключения его кэш может быть старше до ~10 мин → пользователь, созданный/заблокированный/удалённый незадолго до аварии, на новом активном узле может быть ещё не виден или ещё пускать. Это надо объявить в README и закрыть процедурой (после переключения — принудительный refresh/рестарт SFTPGo на новом активном узле). В витке 1 этого пункта не было вообще.

**N2. Квоты между узлами соблюдаются eventually consistent, окно ~1 минута.** config-file, `is_shared`:

> «each node publishes its in-flight transfer sizes to the database **about once a minute**… concurrent uploads spread across nodes can **momentarily exceed a quota by roughly the volume one node moves within that window**.»

Число для сайзинга: превышение ≈ throughput одного узла × 60 с. **[C]**

**N3. Лимиты не кластерные, а per-node: N × число узлов.** config-file, `data_provider.node`:

> «Inter-node communication provides a uniform _view_ of the cluster; **it does not pool _enforcement_**… a per-node limit of N can allow up to **N times the number of nodes** across the cluster.»

Значит `max_per_host_connections=20` на 4 узлах = до 80 соединений с одного IP. Для публичного файлового сервиса это надо считать осознанно. **[C]**

**N4. Defender `provider` = минимум один запрос в БД на каждое новое соединение.** Прямое следствие для WAN: когда лидер PG в другом ДЦ, каждый коннект платит RTT. Это усиливает остаток F6 (производительность) и даёт критерий: либо лидер PG в том же ДЦ, что активный SFTPGo, либо принять задержку на auth. **[C]**

**N5. Докачка и атомарность на S3: конкретные ключи.** config-file:
- `common.resume_max_size` default `0`: «Maximum file size in bytes for which upload resume is allowed on storage backends with immutable objects (S3, GCS, Azure Blob). **SFTPGo must rewrite the entire file on resume. `0` means resume is disabled.**» → без явного значения SFTP-resume на S3 выключен.
- `upload_mode` флаг `2`: «**Atomic with resume**: same as atomic, but on error the temporary file is renamed to the requested path (not deleted), allowing clients to resume.»
- `common.temp_path`: «Must exist, be writable, and **reside on the same filesystem as user home directories** (otherwise atomic renames become copies).»
- `setstat_mode` 1|2 для облачных бэкендов, `metadata.read` для чтения метаданных перед download. **[C]**

**N6. `memory_pipes` — Enterprise-ключ, для OSS не предлагать.** Enterprise clustering советует `SFTPGO_HOOK__MEMORY_PIPES__ENABLED=1` («transfers then stream through memory instead of temporary files on the local disk, which would otherwise need as much free space as the files being transferred»). В OSS config-file (полная страница, 3746 строк, включая `kms`/`plugins`) `memory_pipes` **отсутствует**. Следствие для OSS: temp-диск надо сайзить под объём одновременных передач, «бесплатного» обхода нет. **[C]**

**N7. У SeaweedFS есть собственный SFTP-сервер — новый option, не бесплатная победа.** Wiki «SFTP Server» (отредактирована chrislusf **27.10.2026**):

```
weed sftp -filer=localhost:8888 -port=2022 -userStoreFile=/path/to/users.json
weed filer -sftp.port=2022 -sftp.userStoreFile=/path/to/users.json
```

Плюсы: работает **напрямую с filer**, а не через S3 → rename/truncate нативные, без copy+delete; `-hostKeysFolder` (общие host-keys для failover), `-authMethods=password,publickey,certificate` + `-trustedUserCAKeysFile` (короткоживущие SSH-сертификаты), `-dataCenter` (предпочтение локального ДЦ), chroot-home, JWT к filer подхватывается автоматически.
Минусы, которые надо принять до выбора: пользователи — **JSON-файл** (`users.json`), не БД и не WebAdmin → раздача файла на все узлы и свой процесс ротации; «`Uid` and `Gid`… **currently must be 0** for proper functioning»; **обходит S3-слой, значит Versioning/Object Lock на этом пути не применяются** → требование WORM (PLAN.md:8) не выполняется; нет FTPS и WebClient.
Источник: <https://github.com/seaweedfs/seaweedfs/wiki/SFTP-Server> **[C]**. Вынесено в D11.

**N8. TUS есть у SeaweedFS на filer — но это отдельный путь загрузки.** Wiki «TUS Resumable Uploads»: «TUS is enabled by default at the `/.tus` endpoint»; флаги `-tusBasePath` (default `/.tus`, пусто = выключить), `-tusMaxSizeMB` (default **5120**), `-tusSessionExpiry` (default **24h**); расширения creation/creation-with-upload/concatenation.
Это даёт resumable uploads **без Enterprise**, но не через SFTPGo WebClient: другой endpoint, другая авторизация (filer JWT), другой клиент (tus-js-client и т.п.). Требование «WebClient с TUS» так не закрывается — закрывается «докачка вообще». Вынесено в D9. **[C]**

**N9. Бэкап тем же движком: `filer.backup` + `filer.meta.backup`, с ловушкой шифрования.** Wiki Async-Backup: «`weed filer.backup` will run continuously and keep retrying if any error happens», прогресс-offset хранится на filer, можно продолжить с другого сервера с тем же `replication.toml`. Sink'и в scaffold: `[sink.s3]`, `[sink.local]`, `[sink.filer]`, `[sink.google_cloud_storage]`, `[sink.azure]`. Метаданные отдельно: `weed filer.meta.backup` → LevelDB/Sqlite → S3, stop/resume.
**Ловушка, дословно:** «`weed filer.backup` **transparently decrypts SSE-S3 and SSE-KMS encrypted objects** before uploading to the destination sink. **The destination receives plaintext** — use the destination storage's own encryption if encryption at rest is needed.»
То есть off-cluster бэкап надо класть в бакет с собственным шифрованием, иначе комплаенс-требование ломается на бэкапе. Это конкретный ответ на F17 без нового компонента. **[C]**

**N10. mTLS до PostgreSQL реально настраивается с обеих сторон.** План обещает «сквозное шифрование mTLS» (PLAN.md:7), но не даёт ключей. Найдены:
- SFTPGo: `data_provider.client_cert` / `client_key` — «Path to the client certificate for **two-way TLS authentication**».
- SeaweedFS filer store: `[postgres2] sslmode="verify-full"` + `sslcert`/`sslkey`/`sslrootcert`/`sslcrl` (scaffold, строки 176–182).
Плюс `revoked_user_certs_file` в SFTPGo перечитывается по SIGHUP → готовый механизм отзыва клиентских сертификатов без рестарта. **[C]**

**N11. Лицензии проверены (правило «сначала юридика, потом чужой движок»).** SeaweedFS — **Apache-2.0** (LICENSE в клоне + GitHub API). SFTPGo OSS — **AGPL-3.0** (GitHub API). MinIO — AGPL-3.0 и архив (A10).
Практическое следствие AGPL для SFTPGo: при модификации и предоставлении сервиса по сети третьим лицам возникает обязанность предложить исходники (§13). Для внутреннего использования без модификаций риска нет; если планируется «файловый сервис для клиентов компании» — это надо решить до генерации конфигов, а не после. **[C]** факт лицензии, **[L]** трактовка применимости.

**N12. Filer не умеет искать лидера PG — роутер нужен, и моя §4 без него неполна.** Найдено при разборе сценария «падает ДЦ с лидером PG».
- `weed/filer/postgres2/postgres2_store.go:91–96`: строка соединения собирается как `sqlUrl += " host=" + hostname` — **одно значение**, списка хостов в конфиге нет.
- `weed/util/pgxutil/pgx_conn.go`, `BuildDSN`: `dsn += " host=" + quoteDSNValue(opts.Hostname)`, `target_session_attrs` **не добавляется нигде**; драйвер — `jackc/pgx/v5`.
- Поиск по репозиторию: `gh api "search/code?q=target_session_attrs+repo:seaweedfs/seaweedfs"` → `total_count: 0`.
- `connect_timeout=30` зашит в DSN → попытка подключения к мёртвому хосту висит до 30 с.

Следствие: при смерти узла-лидера PG filer на остальных узлах либо стучится в мёртвый адрес (если `hostname` = IP лидера), либо при списке хостов подключается к первому живому — а это может быть **read-only реплика**, и запись метаданных падает. Ни того, ни другого не лечится конфигом filer.
Лечение: локальный роутер к лидеру на каждом узле — HAProxy с `option httpchk GET /primary` на Patroni REST :8008, либо PgBouncer (в сторе есть `pgbouncer_compatible`) — либо `hostname` = DNS-имя лидера, которое переключает арбитр (добавляет DNS TTL к простою хранилища).
Честная оговорка к A3: аннулирование F6 **для SFTPGo остаётся в силе** (там multi-host + `read-write` нативно). Но тот же класс проблемы для filer я в витке 2 не проверил — и там роутер обязателен. §4 исправлена. **[C]**

---

## 4. Пересобранная рекомендуемая топология (чистовая, без «было/стало»)

Один кластер SeaweedFS на 3 ДЦ, общий PostgreSQL под Patroni как filer store и как data provider SFTPGo, SFTPGo OSS в active/passive, один TLS-сертификат на кластер через DNS-01, host-networking + обычный UFW.

```
ДЦ1 (active)            ДЦ2                     ДЦ3                  [ДЦ4 optional]
─────────────           ─────────────           ─────────────        ─────────────
etcd voter              etcd voter              etcd voter           etcd learner
Patroni + PG16 leader   Patroni + PG16 replica  Patroni + PG16       Patroni standby
SWFS master (raft)      SWFS master             SWFS master          —
SWFS volume -dataCenter=dc1  volume dc2         volume dc3           volume dc4
SWFS filer ─┐           SWFS filer ─┤           SWFS filer ─┤        SWFS filer ─┤
S3 gw :8333 ┘           S3 gw :8333 ┘           S3 gw :8333 ┘        S3 gw :8333 ┘
SFTPGo (active)         SFTPGo (standby)        SFTPGo (standby)     SFTPGo (standby)
   │                        │                       │                    │
   └────────────────────────┴───────────────────────┴────────────────────┘
              все filer → локальный роутер (HAProxy /primary или PgBouncer)
              все SFTPGo → host="IP1,IP2,IP3" + target_session_attrs=read-write
              оба пути ведут на ОДИН Patroni PG (лидер), verify-full + client cert
```

Ключевые решения и их цена:

1. **Метаданные filer — в общем PG, `filer.sync` между нодами нет.** Три filer смотрят в один стор, `filer.store.id` совпадает, peers не нужны (A5). **Обязателен локальный роутер к лидеру PG на каждом узле** (HAProxy с `option httpchk GET /primary` на :8008, либо PgBouncer + `pgbouncer_compatible=true`): filer не умеет ни список хостов, ни `target_session_attrs` (N12), без роутера смерть лидера PG останавливает запись файлов на всех узлах. Цена: каждая metadata-операция идёт к лидеру PG; если лидер в другом ДЦ — WAN RTT; плюс один процесс на узел. Смягчение: активный SFTPGo и лидер PG в одном ДЦ (DNS-failover переключает их вместе).
2. **Данные — placement-репликация `defaultReplication=100`** (2 копии в разных ДЦ), volume-серверы с `-dataCenter`. Запись синхронная → платит WAN RTT. При 3 ДЦ потеря одного ДЦ запись переживает (A9). `fs.configure -volumeGrowthCount=2` — кратно числу копий (проверено в исходниках). Цена: честный RPO≈0 по данным при 2 живых ДЦ и явный отказ записи, когда живых ДЦ меньше требуемого.
3. **SFTPGo OSS active/passive.** `data_provider.host="IP1,IP2,IP3"`, `target_session_attrs=read-write`, `update_mode=1` + однократный `sftpgo initprovider`, `is_shared=1`, общий `kms.secrets.master_key`, общие SSH host-keys, `ftpd.bindings[0].port=21` + `tls_mode=1` + `force_passive_ip=PUBLIC_IP` + `passive_port_range 50000–50199`, WebAdmin `127.0.0.1:8081`, WebClient `:443`, `installation_code`, `defender.driver=provider`, `common.resume_max_size=<N>` + `upload_mode=2` + `setstat_mode=2`. `node` и `signing_passphrase` не нужны (A1).
4. **TLS — lego DNS-01, один сертификат на кластер**, раздача тем же deploy-скриптом, reload по SIGHUP. :80 наружу не нужен. Цена: нужен API-токен DNS-провайдера в секретах.
5. **Сеть — `network_mode: host` + UFW**, без DOCKER-USER. Правила добавляются **до** `ufw --force enable`, SSH только с `ADMIN_SSH_NET`, rollback-таймер на 120 с, персистентность и идемпотентность. Цена: host-networking снимает сетевую изоляцию контейнеров — компенсация mTLS + whitelist остаётся обязательной.
6. **WORM — отдельный бакет/префикс**, создаётся с object-lock **до первого PUT**; рабочая пользовательская область — versioning без lock. На WORM-префикс per-directory permissions `["list","download"]` (+ upload без overwrite). Цена: два разных бакета в сайзинге и бэкапе.
7. **DNS-failover и failback — внешний арбитр** (он же мониторинг), зонды: Patroni `/primary`, S3 gateway, лаг репликации, dry-run `volume.fix.replication`, cooldown. Failback **автоматический с воротами** (§10.5). Объявленный RTO для клиента ≈100–150 с, не 10–30 (§10.1).
8. **Бэкап — `pgbackrest` (WAL + full) вне кластера + `weed filer.backup` → `[sink.s3]` у другого провайдера + `weed filer.meta.backup`**, с обязательным шифрованием на стороне получателя (N9) и еженедельным restore-тестом.
9. **Время — chrony на всех узлах**, проверка в `cluster-health.sh`.
10. **Автоматика возврата — обязательная часть развёртывания** (§10): Patroni `use_pg_rewind` + `remove_data_directory_on_*` + permanent slots по именам узлов + `clonefrom` на репликах; `weed admin` + `weed worker` (built-in скрипт уже содержит `volume.fix.replication -apply`, интервал 17 мин); DNS-failback с воротами. Цена: `pg_wal` растёт, пока узел мёртв — нужен лимит и алерт.

Что остаётся нерешённым без замеров: состав ДЦ и etcd-таймауты (RTT), `synchronous_mode` Patroni (каждый commit через WAN или нет), поведение осиротевших чанков при смерти узла между volume-write и metadata-commit **[U]**.

---

## 5. D-таблица витка 2 (решения за пользователем)

| ID | Вопрос | Варианты | Рекомендация | Цена |
| :-- | :-- | :-- | :-- | :-- |
| ~~D1~~ | ~~Лицензия SFTPGo~~ | — | **СНЯТО**: active/standby работает на любом tier (A1). Вопрос про докачку перенесён в D9 | — |
| D2 | Слой данных | (а) один SWFS + общий PG filer store + `replication=100`; (б) star `filer.sync` с явным RPO; (в) иное | **(а)** | WAN RTT на каждую запись; отказ записи при нехватке живых ДЦ |
| D3 | RTO/RPO числами | PG ttl 30 vs 60; данные RPO 0 vs окно | **ttl 60 / retry_timeout 15 / loop_wait 10**; RPO по файлам ≈0 при 2 живых ДЦ, объявить | 30 с чаще даёт ложные demote при джиттере |
| D4 | Состав ДЦ и etcd | 3 voter cross-DC / witness-нода / per-site DCS + standby_cluster | **замер RTT до выбора**; при max RTT > 250 мс — standby_cluster с ручным promote | ручной promote = RTO минуты, RPO > 0 |
| D5 | SSH :22 | публичный / ADMIN_SSH_NET / bastion | **restrict + key-only + fail2ban** | операционные шаги |
| D6 | Бэкап | провайдер, retention, restore-тест | off-cluster у **другого** провайдера, шифрование получателя обязательно (N9), GFS, еженедельный auto-restore | стоимость хранилища |
| D7 | Мониторинг/арбитр | локальный стек / внешний | **внешний арбитр = он же монитор** | 1 маленькая VPS |
| D8 | Failback | manual / auto+воротами | **auto+воротами** (§10.5) — требование «нужно автоматически» | второй разрыв сессий при возврате; ворота убирают осцилляцию, не разрыв |
| D9 | Докачка (TUS) | снять требование / Enterprise / `/.tus` на filer отдельным путём / клиентский resume (lftp, `curl -C -`) | **снять TUS из WebClient-требований**, оставить SFTP-resume через `resume_max_size`+`upload_mode=2`; если докачка в браузере обязательна — отдельный путь N8 или подписка | Enterprise = деньги; filer TUS = второй контур авторизации |
| D10 | WORM-область | отдельный бакет с lock / versioning без lock | **отдельный бакет + per-dir permissions** | два бакета в сайзинге |
| D11 | SFTP-шлюз | SFTPGo OSS / `weed sftp` | **SFTPGo OSS** (нужны FTPS, WebClient, БД пользователей, WORM через S3) | `weed sftp` нативнее к filer, но обходит S3 → WORM не работает, users.json, Uid/Gid=0 |

---

## 6. Этапы-спринты с gate и kill-критерием

| Спринт | Содержание | Приёмочное число / gate | Kill-критерий |
| :-- | :-- | :-- | :-- |
| 0. Замеры | RTT-матрица 3–4 VPS (`ping -c 100`, mtr), дисковый сайзинг temp | max RTT зафиксирован; etcd election ≥ 10×max RTT | max RTT > 250 мс → cross-DC etcd отзывается, переход на standby_cluster/смена ДЦ |
| 1. Лаборатория | 3 compose-ноды на одном хосте, `iptables DROP` между ними | demote→promote ≤ 60 с; SFTPGo на реплике **не** crash-loop'ит (multi-host PG); PUT проходит при убитом volume-пире (re-assign) | SFTPGo не переживает потерю лидера PG → пересмотр data_provider-конфига до генерации файлов |
| 2. WORM | бакет с object-lock, SFTP `mv`/`rm` залоченного файла | rename проходит (delete marker), версия жива, удаление версии в COMPLIANCE = AccessDenied | lock не переживает бэкап/восстановление → WORM-требование пересогласовать |
| 3. Failover | DNS-арбитр, флаппинг, обрыв сессий | переключение ≤ 90 с; нет осцилляции при cooldown; разрыв сессий объявлен | арбитр переключает на узел без последних файлов → gate по лагу обязателен |
| 4. Бэкап/DR | pgbackrest + filer.backup + meta.backup, restore вне кластера | restore-тест пройден, время восстановления зафиксировано числами | бэкап приезжает plaintext (N9) → шифрование получателя до релиза |
| 5. Периметр | UFW host-профиль, rollback-таймер, lego DNS-01, defender | lockout-тест на стенде пройден; cert renew без :80; бан виден на втором узле | — |
| 6. Возврат узла | rewind + permanent slots + `clonefrom`, `weed admin`/`worker`, DNS-ворота | числа §10.7: возврат без оператора после 5 мин и после 2 ч простоя; авторемонт репликации ≤ 17 мин | простой 2 ч всё равно даёт полный rebuild, не укладывающийся в окно → пересмотр сайзинга `pg_wal` до генерации файлов |

---

## 7. Вне скоупа осознанно

- **VPN-оверлей** — запрещён требованием (PLAN.md:7); компенсация mTLS + whitelist остаётся.
- **Active-active SFTPGo (все узлы обслуживают одновременно)** — требует Enterprise HA + session affinity для HTTP; в OSS лимиты per-node (N3) и кэш ~10 мин (N1). Не делаем.
- **MinIO** — репозиторий архивирован (A10), site replication убран из бесплатной версии. Не предлагаем.
- **`weed sftp` как основной шлюз** — обходит S3, значит WORM не применяется; нет FTPS/WebClient (N7). Держим как option D11, не как рекомендацию.
- **Встроенный ACME SFTPGo** — DNS-01 нет, HTTP-01 требует :80 и привязан к активному узлу (F3). Заменён внешним lego.
- **Ручной возврат узла** — снят требованием «нужно автоматически»; автоматический возврат описан в §10. Ручными осознанно остаются только членские операции etcd при потерянном data dir (§10.2) и DR из бэкапа при потере кворума.
- **Автоматические членские операции etcd (remove/add)** — при 3 voter и одном мёртвом кворум уже 2 из 3; автоматика здесь повышает риск потери кворума, а не снижает (§10.2).

---

## 8. Что проверить до генерации файлов (V-шаги, обновлено)

1. `sftpgo --version` + дефолтный конфиг на целевой VPS → grep `is_shared`, `kms`, `ftpd`, `passive`, `resume_max_size`, `defender`. Закрывает остатки F1/F15/F24/N5. (Пункт про `node`/`signing_passphrase` больше не нужен — A1.)
2. `weed version`, `weed filer.sync -h`, `weed filer.backup -h`, `weed sftp -h` → зафиксировать версию и наличие флагов; проверить `[postgres2]` в scaffold на целевой версии.
3. RTT-матрица (спринт 0) — **до** фиксации etcd-таймаутов и состава ДЦ.
4. Лаборатория partition (спринт 1) — замер demote/promote, поведение SFTPGo на реплике, re-assign при убитом volume.
5. WORM-тест (спринт 2) + **тест осиротевших чанков**: убить узел между volume-write и metadata-commit, посмотреть, появляется ли файл после восстановления **[U]**.
6. Проверить `synchronous_mode` Patroni и `synchronous_node_count` на WAN: каждый commit через ДЦ или асинхронно — это число надо объявить, а не угадать.
7. **Сценарий «умер ДЦ с лидером PG»** (закрывает N12): убить лидера и замерить, через сколько filer на остальных узлах снова пишет метаданные — с роутером и без. Без роутера ожидается отказ записи; с роутером — окно ≤ ttl PG + время health-check. Это главный gate спринта 1.
8. **Сценарий «ДЦ вернулся»** (§10.7): возврат после 5 мин и после 2 ч простоя, потеря data dir PG, авторемонт репликации, DNS-failback с воротами. Замерить рост `pg_wal` за время простоя и время rebuild по WAN. Это главный gate спринта 6.

---

## 9. Источники витка 2

Проверено мной лично в этом витке (дословные цитаты выше):
- SFTPGo OSS 2.7: [config-file](https://docs.sftpgo.com/2.7/config-file/) (`host`, `target_session_attrs`, `update_mode`, `is_shared`, `node`, `ftpd.port`, `force_passive_ip`, `passive_host`, `resume_max_size`, `upload_mode`, `temp_path`, `client_cert/client_key`) · [Web UIs](https://docs.sftpgo.com/2.7/web-interfaces/) (отсутствие TUS) · [defender](https://docs.sftpgo.com/2.7/defender/) · [S3 backend](https://docs.sftpgo.com/2.7/s3/)
- SFTPGo Enterprise: [Clustering & HA](https://docs.sftpgo.com/enterprise/clustering/) (Active/standby, memory_pipes, TUS session affinity)
- Мейнтейнер: `gh api repos/drakkan/sftpgo/issues/comments/4816494623` (drakkan, 10-minute window) · `gh api repos/drakkan/sftpgo/releases/latest` (v2.7.6, 19.09.2026) · `gh api repos/drakkan/sftpgo/license` (AGPL-3.0)
- SeaweedFS wiki (клон `/tmp/swfs-wiki`): [Filer-Store-Replication](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Store-Replication) · [Replication](https://github.com/seaweedfs/seaweedfs/wiki/Replication) (нотация `xyz`: «100 — replicate once on a different data center», «200 — replicate twice on two other different data center») · [S3-Object-Versioning](https://github.com/seaweedfs/seaweedfs/wiki/S3-Object-Versioning) · [S3-Object-Lock-and-Retention](https://github.com/seaweedfs/seaweedfs/wiki/S3-Object-Lock-and-Retention) · [SFTP-Server](https://github.com/seaweedfs/seaweedfs/wiki/SFTP-Server) · [TUS-Resumable-Uploads](https://github.com/seaweedfs/seaweedfs/wiki/TUS-Resumable-Uploads) · [Async-Backup](https://github.com/seaweedfs/seaweedfs/wiki/Async-Backup) · [Async-Filer-Metadata-Backup](https://github.com/seaweedfs/seaweedfs/wiki/Async-Filer-Metadata-Backup)
- SeaweedFS исходники (клон `/tmp/swfs-src`): `weed/operation/upload_content_test.go:186–226` · `weed/shell/command_fs_configure.go:137–138` · `weed/command/scaffold/filer.toml:158–195` · `weed/command/scaffold/replication.toml` · `weed/command/filer_sync.go:94,131–140` · `LICENSE` (Apache-2.0)
- MinIO: `gh api repos/minio/minio` → `archived: true`, push 24.04.2026 · [discussion #21318](https://github.com/minio/minio/discussions/21318) · [AIStor vs OSS](https://www.min.io/blog/minio-aistor-vs-minio-oss-technical-comparison) · [разбор архивации](https://thecloudsupportengineer.com/the-end-of-an-era-minio-community-edition-is-archived-whats-next/)
- etcd/Patroni/PG/DNS (подтверждено в витке 1, не перепроверялось повторно): [etcd tuning](https://etcd.io/docs/v3.5/tuning/) · [Patroni DCS failsafe](https://patroni.readthedocs.io/en/latest/dcs_failsafe_mode.html) · [Patroni standby clusters](https://patroni.readthedocs.io/en/latest/standby_cluster.html) · [pg_rewind](https://www.postgresql.org/docs/current/app-pgrewind.html) · [RFC 2181 §8](https://www.rfc-editor.org/rfc/rfc2181) · [Route 53 failover](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-failover.html)

---

## 10. Автоматический возврат узла (требование: «нужно автоматически»)

Решение принято: упавший ДЦ возвращается в кластер **без человека**. Это меняет D8 и §7. Ниже — минимальный набор ключей, что вернётся само, и где автоматика упирается в физику, а не в конфиг. Всё проверено в этом витке по исходникам и docs upstream.

### 10.1 PostgreSQL: бывший лидер возвращается сам

Ни одного из этих ключей в плане нет (PLAN.md:99–105, 193–196). Минимум:

```yaml
bootstrap:
  dcs:
    primary_start_timeout: 60           # иначе дефолт 300 → worst case failover 320 с
    postgresql:
      use_pg_rewind: true
      use_slots: true
      remove_data_directory_on_rewind_failure: true
      remove_data_directory_on_diverged_timelines: true
      parameters:
        wal_log_hints: "on"
        max_slot_wal_keep_size: "64GB"    # предохранитель, PG13+, default -1 = без лимита
    slots:                                # permanent physical slots по именам узлов
      node1: {type: physical}
      node2: {type: physical}
      node3: {type: physical}
```

плюс `initdb --data-checksums` при bootstrap и тег `clonefrom: true` на репликах.

- **`use_pg_rewind`** — «Defaults to *false*. Note that either the cluster must be initialized with `data page checksums` (`--data-checksums` option for `initdb`) and/or `wal_log_hints` must be set to `on`, or `pg_rewind` will not work.» checksums задаются только при initdb, потом не включить — это решение этапа развёртывания, не эксплуатации. **[C]**
- **`remove_data_directory_on_rewind_failure` / `..._on_diverged_timelines`** — именно они убирают «ручную перекачку». `patroni/postgresql/rewind.py:577–583`: при неудаче rewind, если хотя бы один флаг установлен, Patroni сам вызывает `remove_data_directory()` и переводит состояние в `REWIND_STATUS.INITIAL` → дальше штатный `create_replica` (basebackup). Перекачка остаётся, но она автоматическая и без оператора. **[C]**
- **permanent slots по именам узлов** — иначе возврат дешёвый только первые полчаса: «In case the node is absent and its member key in DCS gets expired, the corresponding replication slot is dropped after `member_slots_ttl` (default value is *30min*)», и тут же рекомендация для статической топологии — «configure permanent physical replication slots with names corresponding to the names of the nodes to avoid slots removal and recycling of WAL files while replica is temporarily down». Цена: пока узел мёртв, WAL держится и `pg_wal` растёт. Предохранитель — `max_slot_wal_keep_size`: «if restart_lsn of a replication slot falls behind the current LSN by more than the given size, the standby using the slot may no longer be able to continue replication due to removal of required WAL files» → слот инвалидируется, возврат становится полным rebuild. Это осознанный обмен «диск против времени возврата». **[C]**
- **`clonefrom: true`** на репликах — «If set to `true` other nodes might prefer to use this node for bootstrap (take `pg_basebackup` from)» → rebuild тянется с реплики, а не с лидера, активный ДЦ не платит за восстановление. **[C]**
- `synchronous_mode_strict` держать **off**: «prevents disabling synchronous replication if no synchronous replicas are available, blocking all client writes to the primary» — иначе единственный выживший узел встанет на запись. Сам `synchronous_mode` остаётся решением D3/V6. **[C]**

**Коррекция моего RTO.** В §2 (F12/F13) и §4 п.7 я написал «реалистично 40–90 с». Это число не свойство плана, а свойство ключа, которого в плане нет: `primary_start_timeout` — «Default is 300 seconds… Worst case failover time for primary failure is: `loop_wait + primary_start_timeout + loop_wait`». С дефолтами это **320 с**, а не 90. Два разных пути надо считать отдельно: **[C]**

| Сценарий | Формула | При ttl 60 / loop_wait 10 / primary_start_timeout 60 |
| :-- | :-- | :-- |
| Умер весь ДЦ (лок лидера истёк) | ttl + loop_wait + promote | ≈ 70–90 с |
| Упал только процесс PG, узел жив | loop_wait + primary_start_timeout + loop_wait | ≤ 80 с |
| Видно клиенту (плюс DNS TTL 30–60 с и кэш резолвера) | предыдущее + TTL | **≈ 100–150 с** |

Объявлять надо ≈ 2 минуты для клиента. «10–30 с» из PLAN.md:172 не выполняется ни при каких ключах; мои «40–90 с» выполнялись только при ttl 30 и явно заданном `primary_start_timeout`.

### 10.2 etcd: догоняет сам, если data dir цел

Возврат члена с целым каталогом данных — штатный: он догоняет raft-лог, а если отстал слишком далеко, лидер шлёт snapshot — «etcd sends a snapshot of its complete key-value store to refresh slow followers». Риск именно для cross-DC: «if the cluster is ingesting data with high throughput, slow followers may livelock by needing a new snapshot before finishing receiving a snapshot», и etcd предупреждает, когда snapshot летит дольше 30 с. На WAN это значит: возвращающийся узел может не догнать никогда при высокой частоте записи — замерять, а не обещать. **[C]**

Ручной остаётся только потеря/порча data dir: «To replace the machine, follow the instructions for removing the member from the cluster, and then add a new member in its place». Процедура в runbook: `member remove` → `member add --learner` → дождаться catch-up → `member promote`. Автоматизировать членские операции не надо: «Reconfiguration requests can only be processed when a majority of cluster members are functioning», а при 3 voter и одном мёртвом кворум уже 2 из 3 — «Machines that have failed but haven't been removed adversely affect the quorum and reduce the tolerance for an additional failure». `--force-new-cluster` в runbook запрещён как процедура восстановления. **[C]**

### 10.3 SeaweedFS: переподключение само, ремонт репликации — по расписанию

- **volume-сервер** возвращается без человека: цикл heartbeat перебирает seed-мастеров и подсказки о лидере, переподключается с backoff (`weed/server/volume_grpc_client_to_master.go:152–207`, `:212–247`). **[C]**
- **master** (raft) возвращается с целым data dir — **[L]**, отдельно не проверялось в исходниках. **filer** переподключается к PG сам (пул `database/sql`), но **только через локальный роутер к лидеру** (N12): без роутера возврат узла не лечит запись метаданных. **[C]**
- **Недореплицированные тома сами не чинятся мгновенно, но чинятся по расписанию — и это уже встроено.** Отдельного job-типа `replication` в `weed/worker/tasks` upstream нет (balance, ec_balance, erasure_coding, iceberg, s3_lifecycle, vacuum), однако admin-script-плагин имеет built-in скрипт, в котором `volume.fix.replication -apply` уже стоит: «The admin script plugin has a built-in default script: `ec.balance -apply` / `fs.log.purge -daysAgo=7` / `volume.deleteEmpty -quietFor=24h -apply` / `volume.fix.replication -apply` / `s3.clean.uploads -timeAgo=24h`», интервал по умолчанию **17 минут**, настраивается в admin UI `/plugin` (`Volume-Management.md:18–28`). Условие: запущены `weed admin -master=…` и `weed worker -admin=…`. Без них работает legacy-fallback `[master.maintenance]` в `master.toml`. **[C]**
- Том с недостающей репликой помечается readonly и снова становится writable после ремонта: «If a volume is replicated and one replica is missing, the volume will be marked as readonly… This volume id will be marked as writable» (`Volume-Management.md:40–44`). Значит «запись в том встала» после потери ДЦ — состояние временное, до ближайшего прогона, а не до оператора. **[C]**

Итог по слою данных: `weed admin` + `weed worker` обязательны в составе развёртывания, иначе автоматического возврата к 2 копиям не будет.

### 10.4 SFTPGo

`restart: unless-stopped` + `data_provider.host="IP1,IP2,IP3"` + `target_session_attrs=read-write` → процесс поднимается и находит лидера сам. Остаток: кэш OSS ~10 мин (N1) — вернувшийся узел может держать устаревшее состояние пользователей. Процедура: не пускать на него трафик (DNS-ворота ниже) и перезапустить контейнер после того, как PG-реплика вышла в streaming. Сессии не переносятся — это объявлено, а не лечится. **[C]**

### 10.5 DNS-failback: автоматический, но с воротами

Раз возврат автоматический, failback тоже автоматический — иначе «автоматически» упирается в кнопку. Арбитр переключает A-запись обратно **только при всех условиях сразу**:

1. Patroni: узел `streaming`, лаг репликации 0 (или ≤ `maximum_lag_on_failover`).
2. etcd: член здоров, raftIndex догнал лидера.
3. `volume.fix.replication` без `-apply` (dry-run) — пустой вывод, недореплицированных томов нет.
4. Сквозная проба на узле: S3 PUT → GET → DELETE и SFTP-логин проходят.
5. Всё выше держится **5 зондов подряд по 30 с** (≈2.5 мин) **и** прошло ≥ **10 мин** с последнего переключения (cooldown). Не чаще одного failback в час.

Цена, которую надо объявить: failback — это **второй разрыв сессий** для пользователей, уже переподключившихся к резервному ДЦ. Ворота убирают осцилляцию, но не убирают разрыв.

### 10.6 Где автоматика заканчивается честно

- **WAL ушёл** (простой дольше, чем держит слот, или сработал `max_slot_wal_keep_size`) → полный `pg_basebackup` по WAN. Автоматически, но не быстро: 100 ГБ на 100 Мбит/с ≈ 2.2 часа. Это физика канала, а не настройка.
- **Потерян data dir etcd** → членская операция remove/add, вручную по runbook (§10.2).
- **`pg_wal` растёт, пока узел мёртв** → нужен алерт на 70% тома под `pg_wal` и явный лимит `max_slot_wal_keep_size`; без них permanent slots превращают отказ одного ДЦ в переполнение диска на остальных.
- **Два ДЦ из трёх одновременно** → нет кворума etcd и нет второй копии данных. Никакая автоматика не помогает; это сценарий DR из бэкапа (спринт 4).
- **Осиротевшие чанки** при смерти узла между volume-write и metadata-commit — по-прежнему **[U]**, замер в спринте 2.

### 10.7 Приёмка и kill-критерий (спринт 6)

| Проверка | Приёмочное число |
| :-- | :-- |
| Убить ДЦ-лидер, вернуть через 5 мин | узел сам становится `streaming`, лаг 0 ≤ 2 мин после восстановления сети, ноль действий оператора |
| Убить ДЦ-лидер, вернуть через 2 ч (> `member_slots_ttl`) | всё ещё rewind, **не** rebuild; рост `pg_wal` зафиксирован числом |
| Потерян data dir PG | автоматический reinit с `clonefrom`-реплики; p95 записи активного ДЦ не деградирует > 20% |
| Недореплицированные тома после возврата | dry-run `volume.fix.replication` пуст ≤ 17 мин + время копирования |
| etcd с целым data dir | член здоров ≤ 1 мин при RTT из спринта 0 |
| DNS-failback | не раньше cooldown 10 мин и 5 зелёных зондов; осцилляции нет при флаппинге |

**Kill-критерий:** если при простое 2 ч возврат всё равно требует полного rebuild (слот инвалидирован) и rebuild не укладывается в объявленное окно — пересмотреть дисковый сайзинг под `pg_wal` и `max_slot_wal_keep_size` **до** генерации файлов, а не после первого инцидента.

### 10.8 Источники §10

- Patroni: [dynamic_configuration](https://patroni.readthedocs.io/en/latest/dynamic_configuration.html) (`use_pg_rewind`, `member_slots_ttl`, permanent `slots`, `primary_start_timeout`, `synchronous_mode_strict`) · [yaml_configuration](https://patroni.readthedocs.io/en/latest/yaml_configuration.html) (тег `clonefrom`) · исходник `patroni/postgresql/rewind.py:577–583`
- PostgreSQL: [runtime-config-replication](https://www.postgresql.org/docs/current/runtime-config-replication.html) (`max_slot_wal_keep_size`, `wal_keep_size`)
- etcd: [runtime-configuration](https://etcd.io/docs/v3.5/op-guide/runtime-configuration/) (replace a failed machine, quorum) · [FAQ](https://etcd.io/docs/v3.5/faq/) (snapshot slow followers, livelock)
- SeaweedFS: клон wiki `/tmp/swfs-wiki` — `Volume-Management.md:8–44` (admin+worker, built-in скрипт с `volume.fix.replication -apply`, 17 мин, readonly→writable) · `Worker.md` · `Plugin-Worker-Scheduling.md:61–134`; клон исходников `/tmp/swfs-src` — `weed/server/volume_grpc_client_to_master.go:152–247`; `gh api repos/seaweedfs/seaweedfs/contents/weed/worker/tasks` (список job-типов, `replication` отсутствует)