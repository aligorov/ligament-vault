# Виток 3: спор с собственным витком 2

Объект спора: `/Users/aleksey/Documents/ftp/DISPUTE.md` (виток 2, включая §10 «автоматический возврат») и `PLAN.md`.
Метод тот же: бью по местам, которые виток 2 **не проверял**, а не по тем, где уже есть цитата. Приоритет — связка SFTPGo↔SeaweedFS S3 (на ней стоит весь продукт), SPOF автоматики, покрытие mTLS, WAN-цена метаданных.
Уверенность: **[C]** = первичный источник, проверен мной в этом витке; **[L]** = вывод/арифметика; **[U]** = нужен замер.
Код и конфиги не правились. Сетевые пробы — read-only.

## 0. Вердикт витка

Виток 2 выдержал проверку там, где цитировал источник, и **провалился там, где обобщал**. Шесть моих собственных формулировок аннулированы или сужены (§1), найдено 9 новых дыр (§3), из них три — продуктовые, а не инфраструктурные.

Главное, что я упустил в витках 1–2: **я ни разу не проверил, что SFTPGo вообще умеет работать с SeaweedFS S3 так, как обещает план**. Проверил в этом витке — вендор документирует совместимость, но вместе с ней документирует ограничения, которые меняют продукт: перенос непустых каталогов не работает ни в OSS, ни в Enterprise.

Вторая главная ошибка: я объявил возврат узла автоматическим (§10), не проверив, кто запускает автоматику и что будет, когда он умрёт вместе с ДЦ.

---

## 1. Аннулировано и сужено (мои утверждения витка 2 против фактов)

### B1. «`clonefrom` → активный ДЦ не платит за восстановление» (DISPUTE.md §10.1) — АННУЛИРОВАНО

В моей топологии **по одному узлу на ДЦ**. Любой basebackup для восстановления узла ДЦ1 идёт из ДЦ2 или ДЦ3, то есть **через WAN всегда**. `clonefrom` снимает нагрузку с *лидера*, а не с канала. Цитата, на которую я опирался, говорит только о выборе источника: «If set to `true` other nodes might prefer to use this node for bootstrap (take `pg_basebackup` from)». Правильная формулировка: rebuild не грузит лидера PG, но полосу WAN занимает целиком; 100 ГБ на 100 Мбит/с ≈ 2.2 ч — это число из §10.6 остаётся, а «не платит» — нет. **[C]**

### B2. «Лицензионная рамка снята полностью» (A1) — СУЖЕНО, нашлась реальная tier-разница

A1 остаётся в силе для active/standby. Но я обобщил до «в OSS нет ничего платного, что нам нужно» — и это неверно для Object Lock.

Enterprise-документация S3: поле **Checksum algorithm**, «One of `CRC32`, `CRC32C`, `CRC64NVME`, `SHA1`, `SHA256`… **Required** if Object Lock is enabled on the bucket: uploads to an Object Lock-protected bucket must include a checksum, otherwise they are rejected. The same requirement applies to S3-compatible services that implement Object Lock.»

В OSS этого поля **нет**. Проверено двумя способами: поиск по всему репозиторию `drakkan/sftpgo` — `ChecksumAlgorithm`, `checksum_algorithm`, `ChecksumAlgo`, `request_checksum_calculation`, `CRC32` дают **0 совпадений**; и исходник тега v2.7.6 `internal/vfs/s3fs.go:156–158`:

```go
o.UsePathStyle = fs.config.ForcePathStyle
o.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
o.ResponseChecksumValidation = aws.ResponseChecksumValidationWhenRequired
```

Режим **зашит в код**, не настраивается. `ForcePathStyle` — настраивается. Это не повторение ошибки F1 (там я объявил платным то, что работает): здесь платная возможность действительно существует, но её применимость к SeaweedFS — отдельный вопрос, см. N13. **[C]**

### B3. «Возврат автоматический» (§10.3) — ДЫРА: автоматика имеет SPOF

`weed admin` — один сервер с одним планировщиком; документированного failover у него нет. Хуже: руководство по миграции советует **удалить** legacy-скрипты из `master.toml` — «removing them avoids confusion and prevents them from running if the admin server is temporarily unavailable». Если это сделать и admin умрёт вместе с ДЦ, **ремонт репликации не выполняет никто**.

Решение проверено в исходниках и работает: `weed/server/master_server.go:508–514` — legacy-цикл на каждой итерации проверяет `ms.isAdminServerConnectedFunc()` и делает `continue` только пока admin подключён:

```go
time.Sleep(time.Duration(sleepMinutes) * time.Minute)
if ms.Topo.IsLeader() && ms.MasterClient.GetMaster(context.Background()) != "" {
    if ms.isAdminServerConnectedFunc() {
        glog.V(1).Infof("Skipping master maintenance scripts because admin server is connected")
        continue
    }
```

Значит `[master.maintenance]` в `master.toml` надо **оставить** как страховку: при живом admin он пропускается, при мёртвом — выполняется на лидере master. Это и есть автоматический fallback без второго admin. **[C]**

### B4. «Авторемонт ≤ 17 мин» (§10.7) — СУЖЕНО

17 минут — это интервал детекции, а не гарантия выполнения. `admin_script` идёт в **первой группе default-лейна**, который берёт cluster admin lock; группы выполняются последовательно, `job_type_max_runtime_seconds` по умолчанию 30 мин, `-adminLock.fairnessWindow` 1 мин. Долгий vacuum или EC-ремонт задерживает ремонт репликации. Приёмочное число должно быть «≤ 17 мин + длительность текущего job», и его надо замерить, а не объявить. **[C]**

### B5. `upload_mode=2` на WORM-бакете (§4 п.3) — ИСПРАВЛЕНО, механизм хуже, чем я думал

Две цитаты, которые я не свёл вместе.

SFTPGo, `upload_mode` flags: `2` — «**Atomic with resume**: same as atomic, but **on error the temporary file is renamed to the requested path (not deleted)**, allowing clients to resume». И там же флаг `4` — «Store partial files for the S3 backend even if a client-side upload error is detected».

SFTPGo, S3 limitations: «`rename` is implemented as server-side copy + delete — **not atomic**».

Следствие для бакета с Object Lock: оборванная загрузка оставляет **недописанный файл на целевом пути**, а retention делает его неудаляемым. Имя занято битым объектом навсегда. Плюс «atomic» на S3 атомарным не является.

Правильно: на WORM-бакете `upload_mode=1` (temp удаляется при ошибке) или `0`, флаг `4` не ставить; `2` — только на рабочем versioned-бакете без lock. **[C]**

### B6. «Компенсация mTLS + whitelist» (§4 п.5) — КОНКРЕТИЗИРОВАНО, найдены незакрытые пути

Виток 2 заявил это без проверки. Проверено по `weed/command/scaffold/security.toml`:

- gRPC mTLS есть по компонентам (`[grpc.master]`, `[grpc.volume]`, `[grpc.filer]`, `[grpc.s3]`), «All gRPC TLS authentications are mutual (mTLS)», и fail-closed: «Once a component's cert/key are set, any error loading them or grpc.ca is **fatal**: the component never falls back to plaintext».
- **Но** `verify_server_host = false` по умолчанию, «The host name is not checked, so the certificate files can be shared», `allowed_commonNames` пуст → принимается любой сертификат, подписанный CA. Без allowlist один workload может представиться другим.
- **Но** worker↔admin: «**Fallback**: Workers fall back to insecure connections if TLS is unavailable» — тихий даунгрейд до plaintext на публичном IP.
- **Но** filer JWT не закрывает всё: «The key does not protect the other filer gRPC RPCs, which can read and write the IAM store under /etc/iam; if the filer gRPC port is reachable beyond a trusted network, enable `[grpc.filer]` mTLS».

То есть mTLS реализуем, но «включили и закрыли» — неверно: нужны allowlist по CN, отдельный `[grpc.admin]`, и firewall на filer gRPC. **[C]**

---

## 2. Что выдержало проверку

Без изменений: общий PG как filer store и отказ от `filer.sync` (A5); `defaultReplication=100` + `volumeGrowthCount` кратно копиям; multi-host PG + `target_session_attrs` у SFTPGo (A3); `use_pg_rewind` + `remove_data_directory_on_*` как механизм автоматического возврата (§10.1); permanent slots против `member_slots_ttl` 30 мин; etcd catch-up snapshot'ом; наличие `volume.fix.replication -apply` в built-in скрипте admin-плагина; коррекция RTO через `primary_start_timeout`.

Новое подтверждение прежней рекомендации: SeaweedFS **не требует** checksum для Object Lock — в `object_lock_utils.go`, `s3api_object_retention.go`, `s3api_object_handlers_retention.go` нет ни одного упоминания checksum, а Content-MD5 в `request_body.go` разбирается только если присутствует. Это снимает остроту N13 именно для SeaweedFS (но не для AWS S3). **[C]**

---

## 3. Новые находки витка 3

### N13. Object Lock + checksum: расхождение вендорского требования и OSS-возможностей

См. B2. Итог по рискам: на SeaweedFS требование, судя по исходникам, не применяется → WORM-бакет, вероятно, работает с OSS SFTPGo **[L]**, но это **обязательный spike**, а не допущение. Если WORM-бакет когда-либо переедет на AWS S3 или другого провайдера, который требует checksum, — OSS SFTPGo туда загружать не сможет, и это уже tier-вопрос. **[C]**

### N14. Перенос непустых каталогов не работает. Ни в OSS, ни в Enterprise

OSS: «We don't support renaming non empty directories since we should rename all the contents too and this could take a long time: think about directories with thousands of files: for each file we should do an AWS API call.»
Enterprise: «Renaming non-empty directories is not supported (each object would require a separate API call).»

Это **продуктовое** ограничение, а не инфраструктурное: пользователь не может `mv` папку с файлами, WinSCP/FileZilla при переносе каталога получат ошибку. План этого не обещает и не запрещает — то есть требование просто не сформулировано. Решение за пользователем (D12). **[C]**

### N15. Это сервис передачи файлов, а не файловая система

Из обоих документов S3-бэкенда: `truncate`, `symlink`, `readlink` не поддерживаются; одновременное открытие файла на чтение и запись не поддерживается; `chtime` не поддерживается; «Clients that require advanced filesystem-like features (e.g. `sshfs`) are not supported»; «A local home directory is still required to store temporary files»; «The configured bucket must exist».

Следствия, которые надо объявить: mtime не сохраняется (миграция и `rsync -a` деградируют), монтировать кластер как ФС нельзя, temp-каталог на каждом узле обязателен и его сайзинг — часть развёртывания, бакеты создаёт deploy-скрипт. **[C]**

### N16. Совместимость с SeaweedFS документирована вендором — и даёт готовый конфиг

Страница S3-compatible services содержит раздел SeaweedFS: endpoint «Your SeaweedFS S3 gateway URL (e.g., `http://seaweedfs:8333`)», region «Any string; `us-east-1` is safe», **Force path style — enabled**, credentials «configured in SeaweedFS (`weed s3.configure` or the config file)». Там же: «There is no separate backend for Cloudflare R2, Backblaze B2, MinIO, or any other S3-compatible service — they all use the same S3 backend».

Это снимает мой неозвученный риск «а вдруг несовместимо» и даёт точные значения. Отдельно: «the only code-level adjustments SFTPGo has made for non-AWS services are around optional features (request checksums, storage class mappings)» — то есть checksums и есть известная точка трения. **[C]**

### N17. Порты и TLS admin/worker: в плане нет ничего из этого

- admin HTTP по умолчанию **12535**, gRPC для worker'ов = **HTTP + 10000 = 22535**, переопределяется `-port.grpc`; worker, получивший `-admin=host:http`, выводит gRPC-порт сам, явно фиксируется как `host:http.grpc`.
- Новые релизы **дополнительно** слушают legacy 23646 (HTTP) и 33646 (gRPC); отключается `-port.legacy=0`. Старый 33646 попадал в ephemeral-диапазон Linux (32768–60999) и мог быть занят исходящим соединением до бинда.
- **Пароль admin не защищает worker-порт**: «Worker gRPC (`-port.grpc`) stays on the `-ip` value and does not follow the authenticated `0.0.0.0` upgrade — its authentication comes from `[grpc.admin]` mTLS, not the admin password».
- admin по умолчанию биндится на `127.0.0.1`; `-ip=0.0.0.0 -allowInsecureBind` помечен как «INSECURE: admin API exposed unauthenticated».
- TLS: `[https.admin]` (cert/key/ca, mTLS при наличии ca) и `[grpc.admin]` для worker'ов; worker fallback в insecure (B6).

Следствие: worker'ы на других узлах требуют `-ip` + TLS + пароль, а whitelist должен открывать 22535 (и 33646, если legacy не отключён). В списке портов плана (PLAN.md:29–34) нет ни одного. **[C]**

### N18. CopyObject в SeaweedFS отдаёт 200 до завершения — но не для versioned-бакетов

«a CopyObject or UploadPartCopy that is still running after about one second gets a `200 OK` straight away… If the copy fails after that point, the status stays 200 and the body holds an `<Error>` document… **This does not apply when the destination bucket has versioning enabled**».

Так как rename в SFTPGo = copy+delete, а наши бакеты versioned — мы на безопасной ветке. Но любой бакет без versioning получает асинхронный copy с ошибкой внутри 200. Это аргумент **включать versioning везде**, а не только на WORM. **[C]**

### N19. WAN-цена метаданных: число, которого нет ни в плане, ни в моих витках

Каждая metadata-операция filer идёт к лидеру PG (§4 п.1, N12). При `synchronous_mode: on` commit дополнительно ждёт подтверждения синхронной реплики в другом ДЦ. Арифметика при RTT 50 мс: один write ≈ 50 мс доехать + 50 мс подтверждение ≈ **100 мс**; создание файла в SFTP — это несколько metadata-операций (запись entry, атрибуты, mtime каталога) → **сотни мс на файл**. 10 000 мелких файлов ≈ часы, а не минуты. **[L]** — арифметика, не замер.

Это делает `synchronous_mode` (D3/V6) не только вопросом RPO, но и вопросом пропускной способности по мелким файлам. Замер обязателен до фиксации режима (D15).

### N20. Master raft SeaweedFS терпимее к WAN, чем etcd в плане

`weed/command/master.go:129–130`: `-heartbeatInterval` по умолчанию **300 мс** (случайный множитель [1, 1.25)), `-electionTimeout` по умолчанию **10 с**. Оба настраиваются флагами.

То есть masters в трёх ДЦ — не слабое место: 10 с election timeout против 2500 мс у etcd в плане (PLAN.md:99–105). Узкое место — etcd, и замер RTT (спринт 0) нужен именно для него. Моё молчаливое опасение про cross-DC raft masters снято. **[C]**

### N21. Filer: JWT на чтение обязателен, метаданные по умолчанию открыты

Из `security.toml`: `[jwt.signing.read]` — «every process that reads chunks straight from volume servers generates its own: filer, s3, mount, webdav, sftp, filer.sync, filer.backup, workers, admin and weed shell. **Without the key, their reads fail with "wrong jwt"**». `[filer.expose_directory_metadata] enabled = true` по умолчанию — «This can be a security risk if the filer is exposed to the public and the JWT for reads is not set». `[access] ui = false` включается автоматически при заданном signing key.

Следствие для кластера на публичных IP без VPN: ключи JWT обязательны (иначе либо чтения не работают, либо метаданные открыты), и их надо раздавать тем же deploy-скриптом, что и сертификаты. В плане JWT не упомянут. **[C]**

---

## 4. Исправленная конфигурация (чистовая, только дельта к витку 2)

Топология витка 2 остаётся. Меняются пять мест.

**1. S3-бэкенд SFTPGo** (значения из N16):

```
endpoint          = http://127.0.0.1:8333     # S3 gw на том же узле
region            = us-east-1                 # любая строка
force_path_style  = true                      # обязательно для SeaweedFS
bucket            = <существующий бакет>      # создаёт deploy
access_key/secret = из weed s3.configure
```

Checksum algorithm в OSS недоступен (B2) — на SeaweedFS не требуется по исходникам, но проверяется spike'ом (N13).

**2. `upload_mode` per-area** (B5): рабочий versioned-бакет — `2` + `resume_max_size`; WORM-бакет с Object Lock — `1` или `0`, флаг `4` не ставить. `setstat_mode=2` везде (chown/chmod не работают).

**3. `master.toml` — legacy maintenance оставить** (B3):

```toml
[master.maintenance]
scripts = [
  "volume.fix.replication -apply",
  "volume.deleteEmpty -quietFor=24h -apply",
  "s3.clean.uploads -timeAgo=24h",
]
sleep_minutes = 17
```

При живом `weed admin` пропускается, при мёртвом — выполняется на лидере master. Это страховка автоматики, а не дубль.

**4. Размещение admin/worker** (B3, N17): `weed admin` на узле, который не является единственным кандидатом в лидеры PG; worker на каждом узле; `-ip` + `[https.admin]` + `-adminPassword` для HTTP, `[grpc.admin]` mTLS для worker-порта (пароль его не закрывает); `-port.legacy=0`; в whitelist — 22535. Второй admin не поднимаем: документированного failover нет, страховка — п.3.

**5. `security.toml`** (B6, N21): `[grpc.master]`/`[grpc.volume]`/`[grpc.filer]`/`[grpc.s3]` cert+key+ca; `allowed_commonNames` по ролям; `[jwt.signing]`, `[jwt.signing.read]`, `[jwt.filer_signing]`, `[jwt.filer_signing.read]` — все четыре ключа; `[filer.expose_directory_metadata] enabled = false`.

---

## 5. D-таблица витка 3 (решения за пользователем)

| ID | Вопрос | Варианты | Рекомендация | Цена |
| :-- | :-- | :-- | :-- | :-- |
| D12 | Перенос непустых каталогов | принять ограничение / сменить продукт / отдельный путь через filer | **принять и объявить** (N14) | пользователи не смогут `mv` папку; Enterprise не лечит |
| D13 | WORM-провайдер и checksum | SeaweedFS (не требует) / AWS S3 (требует → Enterprise) | **SeaweedFS + spike** (N13) | переезд на AWS потребует подписки |
| D14 | Размещение admin | один узел / два / только legacy | **один + legacy-fallback** (B3) | при смерти узла ремонт идёт через master, без UI |
| D15 | `synchronous_mode` и латентность | on (RPO 0, ~100 мс/op) / off (быстрее, RPO>0) | **замер до выбора** (N19) | мелкие файлы — главный потребитель латентности |
| D16 | `upload_mode` по областям | 2 везде / 1 на WORM / 0 на WORM | **1 на WORM, 2 на рабочей** (B5) | на WORM нет докачки; битый файл не занимает имя |
| D17 | mtime и ФС-семантика | объявить transfer-only / требовать ФС | **transfer-only** (N15) | `rsync -a`, sshfs, сохранение mtime не работают |

D2–D11 витка 2 остаются в силе; D8 уже изменён на auto+воротами (§10.5 витка 2).

---

## 6. Спринты: порядок изменён

Главный gate теперь **не Patroni, а связка SFTPGo↔SeaweedFS S3**. Если она не даёт нужной продуктовой семантики, выбор стека меняется целиком, и лаборатория Patroni не нужна.

| Спринт | Содержание | Приёмочное число / gate | Kill-критерий |
| :-- | :-- | :-- | :-- |
| 0. Замеры | RTT-матрица, дисковый сайзинг temp и `pg_wal` | max RTT зафиксирован | max RTT > 250 мс → cross-DC etcd отзывается |
| **1. S3-связка** | SFTPGo OSS + SeaweedFS S3: PUT/GET/LIST/rename файла, rename каталога, Object Lock PUT, multipart, обрыв загрузки | файл загружается и читается; rename файла работает; PUT в lock-бакет проходит **без** checksum; обрыв не оставляет битый файл на целевом пути | PUT в lock-бакет отвергается → D13 (Enterprise или смена провайдера); rename каталога нужен продукту → D12 |
| 2. Латентность | замер мелких файлов при RTT из спринта 0, `synchronous_mode` on/off | число мс/файл и файлов/с зафиксированы | > 500 мс на файл при целевом профиле → пересмотр D15 или топологии |
| 3. Лаборатория HA | 3 ноды, partition, multi-host PG, роутер к лидеру | demote→promote ≤ 80 с; filer пишет после смерти лидера PG | filer не переживает потерю лидера → роутер обязателен (N12) |
| 4. Возврат узла | §10.7 витка 2 + B3/B4 | возврат без оператора после 5 мин и 2 ч; ремонт ≤ 17 мин + текущий job | rebuild не укладывается в окно → сайзинг `pg_wal` до генерации файлов |
| 5. WORM и бэкап | lock-бакет, retention, pgbackrest + filer.backup | COMPLIANCE-версия неудаляема; restore-тест пройден | бэкап приезжает plaintext → шифрование получателя |
| 6. Периметр | UFW, lego DNS-01, security.toml, JWT, defender | lockout-тест пройден; чтения без JWT не работают; worker↔admin только TLS | worker падает в insecure → firewall до релиза |

---

## 7. Вне скоупа осознанно

- **Enterprise ради checksum** — не предлагаем до spike'а: на SeaweedFS требование, по исходникам, не применяется (N13).
- **Второй `weed admin`** — документированного failover нет; страховка через legacy-скрипты (B3).
- **ФС-семантика (sshfs, truncate, mtime, перенос каталогов)** — не лечится конфигом S3-бэкенда; объявлено как ограничение продукта (N14, N15, D17).
- **VPN-оверлей** — запрещён требованием (PLAN.md:7).
- **Active-active SFTPGo, MinIO, `weed sftp` как основной шлюз, встроенный ACME** — остаются вне скоупа по витку 2.

---

## 8. V-шаги витка 3 (до генерации файлов)

1. **Spike S3-связки** (спринт 1) — главный gate. PUT в Object Lock-бакет без checksum; rename файла и каталога; обрыв загрузки при `upload_mode` 1 и 2; multipart при WAN-полосе.
2. Замер мс/файл и файлов/с при `synchronous_mode` on/off (спринт 2).
3. Проверить на целевой версии `weed admin`: порт gRPC, legacy-порты, `[grpc.admin]`, поведение worker при отсутствии TLS.
4. Проверить fallback: убить `weed admin` и убедиться, что leader master выполняет `[master.maintenance]` (B3).
5. Замер роста `pg_wal` за 2 ч простоя узла и времени rebuild по WAN (§10.7 витка 2).
6. Проверить, что чтения без `[jwt.signing.read]` падают, а с ключом работают на всех компонентах (N21).
7. RTT-матрица и etcd-таймауты — как в витке 2.

---

## 9. Источники витка 3

- SFTPGo OSS 2.7: [S3 backend](https://docs.sftpgo.com/2.7/s3/) (limitations, multipart, temp home) · [config-file](https://docs.sftpgo.com/2.7/config-file/) (`upload_mode` flags 0/1/2/4) · исходник тега v2.7.6 `internal/vfs/s3fs.go:156–158` · `gh api search/code` по `drakkan/sftpgo` (ChecksumAlgorithm / checksum_algorithm / ChecksumAlgo / request_checksum_calculation / CRC32 = 0; ForcePathStyle = 7)
- SFTPGo Enterprise docs: [S3](https://docs.sftpgo.com/enterprise/s3/) (Checksum algorithm, Limitations) · [S3-compatible services](https://docs.sftpgo.com/enterprise/s3-compatible-services/) (раздел SeaweedFS, Object Lock and checksums, troubleshooting)
- SeaweedFS исходники (клон `/tmp/swfs-src`): `weed/server/master_server.go:508–514` · `weed/command/master.go:129–130,274–277` · `weed/command/scaffold/security.toml` (grpc.*, jwt.*, filer.expose_directory_metadata, access.ui) · `weed/s3api/request_body.go` · `weed/s3api/object_lock_utils.go`, `s3api_object_retention.go`, `s3api_object_handlers_retention.go` (checksum не упоминается)
- SeaweedFS wiki (клон `/tmp/swfs-wiki`): `Amazon-S3-API.md:124,150–166` (CopyObject, multipart, async-200 quirk) · `Admin-UI.md:16,28,30–31,53,58,72,235–270` (порты, bind, TLS, worker gRPC без пароля, legacy-порты, fallback) · `Migrate-Maintenance-Scripts-to-Admin-Script-Plugin.md:29,41,87,108` · `Volume-Management.md:18–44` · `Plugin-Worker-Scheduling.md:61–134`
- Patroni: [yaml_configuration](https://patroni.readthedocs.io/en/latest/yaml_configuration.html) (`clonefrom`) — перечитано для B1