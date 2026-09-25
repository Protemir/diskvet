# Почему ClickHouse® забивает диск в Langfuse и SigNoz на своём сервере и как это исправить

*[English version](../guide.md). Если версии расходятся, ориентируйтесь на английскую.*

На сервере с Langfuse или SigNoz кончается место, хотя трейсов у вас немного.
В большинстве известных случаев место съедает сам ClickHouse®: его собственные
таблицы-логи, например `system.trace_log` и `system.text_log`, размер которых
по умолчанию ничем не ограничен. У ClickStack та же проблема.

Ниже — как убедиться в этом одним запросом только на чтение, освободить место
прямо сейчас и не дать логам разрастись снова, обойдя известные ловушки. Дополнительные инструменты не нужны.

*Проверено на стандартных образах `clickhouse/clickhouse-server` 24.8, 25.12 и
26.9 (команды для SigNoz — на 25.5 и 25.12), с сервисом ClickHouse и конфигом
из compose-файлов Langfuse и SigNoz.*

## Коротко

1. **Проверьте.** Выполните один запрос на чтение к `system.parts`. Если таблицы `system.*_log` больше ваших данных, проблема в собственных логах ClickHouse.
2. **Освободите место сейчас.** Сделайте `TRUNCATE` больших логов. Для таблицы больше 50 ГБ добавьте `SETTINGS max_table_size_to_drop = 0`.
3. **Не дайте логам вырасти снова.** Добавьте в `config.d` файл с TTL для каждого лога (для `opentelemetry_span_log` TTL пишется внутри `<engine>`) и перезапустите ClickHouse.
4. **Приберитесь.** Удалите копии `*_log_0`, `*_log_1`, которые остаются после перезапуска.
5. **Диск всё ещё полный?** Проверьте логи контейнеров Docker, удалённые строки и застрявшие куски. Если у вас Langfuse, сначала обновите его и только потом переводите ClickHouse на 26.8+.

## 1. Что занимает диск? Размер таблиц ClickHouse

Сохраните этот запрос в файл `size.sql`. Он показывает самые большие таблицы
по размеру на диске:

```sql
SELECT database, table,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       sum(rows) AS rows,
       count() AS parts
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 15;
```

**Langfuse (docker compose).** Выполните команду в папке с `docker-compose.yml`
от Langfuse. Этот compose-файл уже задаёт `CLICKHOUSE_USER` и `CLICKHOUSE_PASSWORD`
внутри контейнера:

```sh
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < size.sql
```

**SigNoz (docker compose).** Контейнер обычно называется `signoz-clickhouse`
(проверьте через `docker ps`). В `users.xml` от SigNoz у пользователя
`default` нет пароля:

```sh
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --format PrettyCompact < size.sql
```

`--readonly=1` переводит сессию в режим только для чтения: ClickHouse отклонит
любые изменения.

**Как читать результат.** Сравните строки базы `system` со своими данными
(`default` у Langfuse, `signoz_*` у SigNoz). Если наверху `system.trace_log`
или `system.text_log`, переходите к разделу 2.

## 2. Как освободить место прямо сейчас?

Откройте клиент с правом записи:

```sh
# Langfuse
docker compose exec clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'
# SigNoz
docker exec -it signoz-clickhouse clickhouse-client
```

Очистите большие логи:

```sql
TRUNCATE TABLE system.trace_log;
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.metric_log;
TRUNCATE TABLE system.query_log;
```

Так удаляется только собственная диагностика ClickHouse, а не ваши трейсы.
Перезапуск не нужен.

Langfuse читает `system.query_log`, чтобы следить за некоторыми своими
запросами ([#13123](https://github.com/langfuse/langfuse/issues/13123)).
Поэтому очищать его можно, а отключать не надо.

### TRUNCATE падает с Code 359? Таблицы больше 50 ГБ

ClickHouse не удаляет и не очищает таблицу больше `max_table_size_to_drop`
(по умолчанию 50 000 000 000 байт, около 46,6 ГиБ). Лимит действует и на
`TRUNCATE`: для таблицы больше лимита запрос падает с
`Code: 359 ... (TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT)`.

Большие логи в него действительно упираются: `text_log` в
[обсуждении Langfuse #15024](https://github.com/orgs/langfuse/discussions/15024)
занимал 59,20 ГиБ. Обойти лимит можно двумя способами.

**Способ А.** Снять лимит для одного запроса:

```sql
-- ClickHouse 23.12+: снять лимит только для этого запроса
TRUNCATE TABLE system.text_log SETTINGS max_table_size_to_drop = 0;
```

**Способ Б.** Создать одноразовый файл-флаг, а потом выполнить обычный
`TRUNCATE`:

```sh
docker compose exec clickhouse sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```

(Для SigNoz: `docker exec signoz-clickhouse sh -c '...'` с той же командой.)
ClickHouse удаляет флаг после первого `DROP` или `TRUNCATE`, которому он
понадобился, поэтому перед следующей большой таблицей создайте его снова.

Место вернулось, но логи сразу начинают расти снова. Как это остановить — в
разделе 4, а почему так происходит — в разделе 3.

## 3. Почему trace_log и text_log такие большие?

ClickHouse пишет собственную диагностику в таблицы базы `system`:
`query_log`, `trace_log`, `text_log`, `metric_log` и другие. В
[документации](https://clickhouse.com/docs/reference/system-tables/overview)
так прямо и сказано: «By default, table growth is unlimited» — по умолчанию
рост таблиц не ограничен.

Свежие [стандартные конфиги](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml)
задают TTL только нескольким небольшим логам (с 25.9 `processors_profile_log`
хранится 30 дней), а большим — нет. Быстро растут они из-за двух настроек по
умолчанию:

- профилировщик запросов включён и пишет в `trace_log` сэмплы стеков выполняющихся запросов;
- `text_log` хранит лог сервера на уровне `trace`.

Публичные примеры:

- **Langfuse [#13123](https://github.com/langfuse/langfuse/issues/13123):** `system.trace_log` занимал 66,86 ГиБ, а перечисленные там таблицы Langfuse (`traces`, `observations`, `scores`) — около 51 МиБ вместе. Мейнтейнеры решили не менять настройки ClickHouse по умолчанию и вместо этого добавили [страницу в FAQ](https://langfuse.com/faq/all/reduce-clickhouse-disk-size).
- **SigNoz [#12050](https://github.com/SigNoz/signoz/issues/12050):** больше 80 ГБ системных логов (включая копию `trace_log_0`) при менее чем 500 МБ телеметрии. Очистка таблиц `system.*` освободила около 80 ГБ. Новый установщик SigNoz Foundry задаёт TTL, а в старых установках через docker compose TTL не задан.
- **Helm-чарт ClickStack, [PR #275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275):** том на 10 Gi заполнился на 100% за 10 дней: 5,2 ГБ серверных логов уровня trace и 3,7 ГБ в `system.text_log` против ~70 МБ телеметрии. PR приняли в сентябре 2026 года, он добавляет TTL на 7 дней.

## 4. Как задать TTL системным логам ClickHouse?

С TTL ClickHouse сам удаляет старые строки логов. Задавайте его **после**
`TRUNCATE` из раздела 2, и вот почему.

Когда вы добавляете TTL и перезапускаете сервер, ClickHouse не уменьшает
старую таблицу. Он переименовывает её в `trace_log_0` со всеми строками и
создаёт новую, уже с TTL. Если сначала сделать `TRUNCATE`, эти копии будут
крошечными, и шаг 4 их удалит.

SQL ниже выполняйте в том же клиенте с правом записи, что и в разделе 2.

### Шаг 1: у каких логов нет TTL?

```sql
SELECT name,
       formatReadableSize(total_bytes) AS size,
       extract(engine_full, 'TTL [^S]*') AS ttl
FROM system.tables
WHERE database = 'system' AND engine LIKE '%MergeTree' AND match(name, '_log(_[0-9]+)?$')
ORDER BY total_bytes DESC;
```

Пустой `ttl` значит, что лог хранится вечно. Имена вроде `trace_log_0` — это
старые копии, их удалит шаг 4.

### Шаг 2: добавьте файл с TTL в config.d

Сохраните это как `clickhouse-ttl.xml` рядом с `docker-compose.yml`:

```xml
<clickhouse>
    <!-- Хранить собственные логи ClickHouse 7 дней. Перечислите только логи, которые есть на вашем сервере. -->
    <query_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_log>
    <trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
    <text_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></text_log>
    <metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></metric_log>
    <asynchronous_metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></asynchronous_metric_log>
    <part_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></part_log>

    <!-- В стандартном конфиге этот лог задан через <engine>, поэтому отдельный <ttl>
         не даст серверу запуститься (ClickHouse#88366). TTL пишется внутри. -->
    <opentelemetry_span_log>
        <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
    </opentelemetry_span_log>
</clickhouse>
```

Смонтируйте файл в сервис `clickhouse` (уже существующие строки в `volumes`
оставьте):

```yaml
  clickhouse:
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

На этом шаге три ловушки:

- **У `opentelemetry_span_log` TTL задаётся внутри `<engine>`.** Стандартный конфиг задаёт этот лог через `<engine>`, а по [документации](https://clickhouse.com/docs/reference/system-tables/overview) это конфликтует с `<ttl>`. Тогда сервер завершается с ошибкой `If 'engine' is specified for system table, TTL parameters should be specified directly inside 'engine'` ([ClickHouse #88366](https://github.com/ClickHouse/ClickHouse/issues/88366)). Скопируйте `PARTITION BY` и `ORDER BY` из `SELECT engine_full FROM system.tables WHERE database = 'system' AND name = 'opentelemetry_span_log'` (в конфиге SigNoz сортировка ещё и по `trace_id`). Или отключите этот лог: `<opentelemetry_span_log remove="1"/>` ([документация Langfuse по масштабированию](https://langfuse.com/self-hosting/configuration/scaling)). `remove` не удаляет существующую таблицу, так что удалите её сами.
- **Перечисляйте только те логи, которые есть на вашем сервере.** Именно секция в конфиге включает лог (в стандартном `config.xml` секция `session_log` закомментирована, поэтому он выключен). Собственный [`config.xml`](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml) SigNoz не включает `text_log`, так что для SigNoz уберите строку `text_log` из `clickhouse-ttl.xml`. И добавьте туда `processors_profile_log`: в `config.xml` SigNoz у него нет TTL.
- **Настройки профилей — в users.d, а не в config.d.** Если вы заодно отключаете профилировщик запросов (`query_profiler_real_time_period_ns` и `query_profiler_cpu_time_period_ns` = 0, как в документации Langfuse по масштабированию), положите этот блок `<profiles>` в `users.d/`. В `config.d/` он молча игнорируется ([trigger.dev #4343](https://github.com/triggerdotdev/trigger.dev/issues/4343)).

### Шаг 3: перезапустите ClickHouse

TTL из `config.d` начинает действовать только после перезапуска сервера
([Altinity KB](https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/)).
Перечитать конфиг недостаточно. С compose:

```sh
docker compose up -d clickhouse     # пересоздаёт контейнер с новым файлом
docker compose ps clickhouse
```

Если ClickHouse постоянно перезапускается, причина — в его логе ошибок внутри
контейнера. `docker compose logs` может её не показать:

```sh
docker cp "$(docker compose ps -aq clickhouse)":/var/log/clickhouse-server/clickhouse-server.err.log .
tail -n 20 clickhouse-server.err.log
```

### Шаг 4: удалите старые копии trace_log_0

После перезапуска у каждого изменённого лога появляется копия вроде
`trace_log_0` (при следующих изменениях — `_1`, `_2`). В копии остаются все
старые строки, и TTL у неё нет (заметка об обновлении в ClickStack PR #275,
[Sentry snuba #7311](https://github.com/getsentry/snuba/issues/7311)).

Этот запрос сам составит команды `DROP`. Прочитайте их, потом вставьте в
клиент:

```sql
SELECT 'DROP TABLE system.' || name || ' SETTINGS max_table_size_to_drop = 0;'
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$');
```

ClickHouse в эти таблицы больше не пишет. `DROP` нельзя отменить.

### Шаг 5: проверьте результат

Снова выполните запрос из шага 1. У каждого большого лога должен быть TTL, а
имён с `_N` не должно остаться.

Устаревшие строки ClickHouse удаляет при слияниях, по умолчанию не чаще раза в
4 часа ([`merge_with_ttl_timeout`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout)),
так что размер уменьшится в ближайшие часы.

Проверку может сделать и скрипт:
[diskvet](https://github.com/Protemir/diskvet) выполняет проверку из шага 1
в режиме только для чтения и печатает команды `TRUNCATE`, файл с TTL и список
`DROP` для ваших таблиц, с файлом-флагом для таблиц больше лимита на удаление
(см. раздел 7).

## 5. Диск всё ещё полный? Куда ещё уходит место

Сравните `df -h` с общим размером всех кусков
(`SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts`). Если на
диске занято намного больше, значит, место занимает что-то помимо таблиц
ClickHouse.

### Логи контейнеров Docker забивают диск?

У `json-file`, драйвера логов Docker по умолчанию, нет ограничения размера
(`max-size` по умолчанию `-1`, см. [документацию Docker](https://docs.docker.com/engine/logging/drivers/json-file/)).
В [Langfuse #16339](https://github.com/langfuse/langfuse/issues/16339) лог
контейнера ClickHouse дорос до 89,1 ГиБ и заполнил корневой диск на 244 ГиБ.

Найдите самые большие:

```sh
sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'
docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'   # имя папки — это ID контейнера
```

Чтобы это исправить, добавьте блок `logging:` в каждый сервис в
`docker-compose.yml`. В #16339 мейнтейнеры Langfuse советовали сделать это для
всех контейнеров, а не только для ClickHouse. В [compose-файле](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml)
SigNoz уже стоит `50m` × 3.

```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

Потом выполните `docker compose up -d --force-recreate`: настройки логов
действуют только для заново созданных контейнеров. При пересоздании старый
файл лога тоже удаляется — в #16339 это освободило 81 ГиБ.

Два замечания:

- Если демон Docker использует другой драйвер логов, настройте ограничение логов в нём, а этот блок не добавляйте: `driver: json-file` переопределит ваш драйвер.
- В README Langfuse ([PR #16363](https://github.com/langfuse/langfuse/pull/16363)) описан способ для всего демона: задать `max-size` и `max-file` по умолчанию в настройках демона, затем перезапустить Docker и пересоздать контейнеры. Там же советуют не обрезать и не ротировать эти файлы сторонними инструментами.

### Разрослись файлы логов самого ClickHouse?

ClickHouse пишет и обычные файлы логов в `/var/log/clickhouse-server` (в
compose-файле Langfuse это отдельный том). По умолчанию уровень — `trace`,
ротация при 1000M, хранится до 10 старых файлов
([документация `logger`](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger)).

В ClickStack PR #275 используются значения ниже. Сохраните их как ещё один
файл в `config.d`, подключите так же, как файл с TTL, и перезапустите
ClickHouse (раздел 4, шаг 3):

```xml
<clickhouse>
    <logger><level>information</level><size>100M</size><count>10</count></logger>
</clickhouse>
```

### Почему удалённые строки всё ещё занимают место?

Если в Langfuse включено ограничение срока хранения данных (data retention),
старые строки удаляются через [облегчённый (lightweight) `DELETE`](https://clickhouse.com/docs/reference/statements/delete).
ClickHouse такие строки только помечает, а место возвращается при слиянии
куска.

Фоновые слияния пропускают куски больше
[`max_bytes_to_merge_at_max_space_in_pool`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool)
(150 ГиБ), а куски в старых месячных партициях сливаются редко. В
[обсуждении Langfuse #13969](https://github.com/orgs/langfuse/discussions/13969)
майская партиция на ~802 ГиБ примерно на 85% состояла из удалённых строк.

Найдите партиции с удалёнными строками:

```sql
SELECT database, table, partition_id, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active AND has_lightweight_delete
GROUP BY database, table, partition_id
ORDER BY sum(bytes_on_disk) DESC;
```

Потом примените маску удаления, по одной партиции за раз
([APPLY DELETED MASK](https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask)):

```sql
ALTER TABLE default.observations APPLY DELETED MASK IN PARTITION ID '202605';
```

**Осторожно:** это тяжёлая мутация. Она переписывает затронутые куски, поэтому
ей нужно свободное место под новые копии, и она нагружает диск. Запускайте её
в часы низкой нагрузки и следите через
`SELECT * FROM system.mutations WHERE NOT is_done`. В #13969 она освободила
~360 ГиБ на каждой реплике примерно за 17 минут.

Начиная с v3.179.0 воркер Langfuse умеет делать это по расписанию:
`LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` (по умолчанию
выключено; см. `.env.prod.example`, [PR #14035](https://github.com/langfuse/langfuse/pull/14035)).

### Старые куски застряли на диске? (неактивные и отсоединённые куски)

```sql
SELECT database, table, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       min(remove_time) AS oldest, max(refcount) AS max_refcount
FROM system.parts
WHERE NOT active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;
```

Неактивные куски остаются после слияний. ClickHouse удаляет их по истечении
[`old_parts_lifetime`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime)
(480 с), когда их больше не использует ни один запрос (`refcount` = 1).

Если они копятся (в обсуждении Langfuse #15024 их набралось на 112,55 ГиБ), а
`oldest` — несколько часов назад, поищите долгие запросы в `system.processes`
и остановите их через `KILL QUERY WHERE query_id = '...'`.

Отсоединённые (detached) куски лежат на диске, пока вы их не удалите:

```sql
SELECT database, table, reason, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.detached_parts
GROUP BY database, table, reason;
```

Сначала посмотрите на `reason`. Удаляйте кусок командой
`ALTER TABLE <db>.<table> DROP DETACHED PART '<name>' SETTINGS allow_drop_detached = 1`,
а не удалением папок.

## 6. Обновляете ClickHouse? Сначала проверьте это

- **Langfuse и ClickHouse 26.8 или новее: сначала обновите Langfuse.** В ClickHouse 26.8 значение по умолчанию у настройки `input_format_read_datetime_number_as_raw_value` сменилось с 1 на 0. Старые версии Langfuse отправляют значения `DateTime64` числами в миллисекундах, и на 26.8+ они сохраняются как `9999-12-31 23:59:59` ([Langfuse #16858](https://github.com/langfuse/langfuse/issues/16858): от 0,59% до 21,43% записей, в зависимости от проекта). Исправление — [PR #16892](https://github.com/langfuse/langfuse/pull/16892) (бэкпорт в v3 — [PR #16957](https://github.com/langfuse/langfuse/pull/16957)), оно вышло в Langfuse v4.28.0 и v3.225.7. Langfuse делит данные на партиции по месяцам, поэтому такие строки попадают в партицию `999912`. Проверьте версию и поищите их:

  ```sql
  SELECT version();
  SELECT database, table, partition_id, count() AS parts
  FROM system.parts
  WHERE active AND startsWith(partition_id, '9999')
  GROUP BY database, table, partition_id;
  ```

- **После любого обновления снова выполните запрос из шага 1 раздела 4.** Когда релиз меняет схему лога, ClickHouse переименовывает текущую таблицу и создаёт новую, так что появляются новые копии `_N`. Удалите их, как в шаге 4.

## 7. Проверить всё сразу

[diskvet](https://github.com/Protemir/diskvet) — открытый (Apache-2.0) скрипт
только для чтения: он выполняет большинство проверок выше и печатает отчёт с
командами для исправления. Файлы логов Docker он не видит, но показывает,
сколько места на диске занято не кусками ClickHouse. Отчёт он пишет
по-английски.

На машине с `docker-compose.yml` от Langfuse (прочитайте `checks.sql` перед
запуском):

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

Для SigNoz используйте `--docker signoz-clickhouse`.

Скрипт читает только метаданные из таблиц `system.*` (`system.tables`,
`system.parts`, `system.disks`, `system.detached_parts`, `system.mutations`,
`system.part_log` и ещё нескольких), с `readonly=2` и ограничениями ресурсов.
Он никогда не читает ни строки ваших таблиц, ни `system.query_log`, ни тексты
запросов и ничего никуда не отправляет. Автоматически ничего не выполняется:
каждое исправление вы читаете и запускаете сами.

Скоро появится версия, которая проверяет сервер каждый час и предупреждает до
того, как диск заполнится (бесплатная бета откроется в октябре 2026 года).

## Источники

Документация и исходный код ClickHouse:

- Обзор системных таблиц (неограниченный рост, `<engine>` против `<ttl>`, переименование при смене схемы): https://clickhouse.com/docs/reference/system-tables/overview
- `config.xml` по умолчанию (логи без TTL, engine у `opentelemetry_span_log`, `text_log` и logger на уровне `trace`, закомментированный `session_log`): https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml
- `max_table_size_to_drop`, серверная настройка и `force_drop_table`: https://clickhouse.com/docs/reference/settings/server-settings/settings/max-table#max_table_size_to_drop
- `max_table_size_to_drop`, настройка запроса: https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop
- Переопределение на уровне запроса с 23.12: https://github.com/ClickHouse/ClickHouse/pull/57452
- Флаг удаляется после использования (`checkCanBeDropped`): https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/Context.cpp
- TRUNCATE: https://clickhouse.com/docs/reference/statements/truncate
- Ошибка TTL у `opentelemetry_span_log`: https://github.com/ClickHouse/ClickHouse/issues/88366
- Настройки MergeTree: `merge_with_ttl_timeout` (14400 с) https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout, `old_parts_lifetime` (480 с) https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime, `max_bytes_to_merge_at_max_space_in_pool` (150 ГиБ) https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool
- Ротация логов сервера (`logger`: `level`, `size`, `count`): https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger
- Облегчённый DELETE: https://clickhouse.com/docs/reference/statements/delete
- APPLY DELETED MASK: https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask
- system.parts: https://clickhouse.com/docs/reference/system-tables/parts
- system.detached_parts: https://clickhouse.com/docs/reference/system-tables/detached_parts
- DROP DETACHED PART: https://clickhouse.com/docs/reference/statements/alter/partition
- `allow_drop_detached`: https://clickhouse.com/docs/reference/settings/session-settings/allow#allow_drop_detached
- system.mutations: https://clickhouse.com/docs/reference/system-tables/mutations
- KILL QUERY: https://clickhouse.com/docs/reference/statements/kill
- Altinity KB, «System tables ate my disk» (нужен перезапуск): https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/

Docker:

- Драйвер логов json-file (`max-size` по умолчанию -1; у существующих контейнеров остаются старые настройки): https://docs.docker.com/engine/logging/drivers/json-file/

Langfuse:

- FAQ, как уменьшить размер ClickHouse на диске: https://langfuse.com/faq/all/reduce-clickhouse-disk-size
- Документация по масштабированию, системные таблицы-логи ClickHouse: https://langfuse.com/self-hosting/configuration/scaling
- #13123, системные таблицы растут без ограничений: https://github.com/langfuse/langfuse/issues/13123
- #16339, лог Docker без ограничений: https://github.com/langfuse/langfuse/issues/16339
- PR #16363, ротация логов Docker в README (настройки демона, без сторонней обрезки): https://github.com/langfuse/langfuse/pull/16363
- Обсуждение #13969, строки после облегчённого удаления: https://github.com/orgs/langfuse/discussions/13969
- Обсуждение #15024, неактивные куски и text_log на 59 ГиБ: https://github.com/orgs/langfuse/discussions/15024
- PR #14035, очистка по маске удаления (вышла в v3.179.0): https://github.com/langfuse/langfuse/pull/14035, https://github.com/langfuse/langfuse/releases/tag/v3.179.0
- #16858, DateTime64 на ClickHouse 26.8+: https://github.com/langfuse/langfuse/issues/16858
- PR #16892 и бэкпорт в v3, PR #16957: https://github.com/langfuse/langfuse/pull/16892, https://github.com/langfuse/langfuse/pull/16957
- Релизы с исправлением: https://github.com/langfuse/langfuse/releases/tag/v4.28.0, https://github.com/langfuse/langfuse/releases/tag/v3.225.7

SigNoz, ClickStack и другие:

- SigNoz #12050, 80+ ГБ системных логов: https://github.com/SigNoz/signoz/issues/12050
- `config.xml` и `users.xml` ClickHouse в SigNoz v0.129.0: https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml, https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/users.xml
- `docker-compose.yaml` в SigNoz v0.129.0 (контейнер `signoz-clickhouse`, `max-size: 50m`, `max-file: "3"`): https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml
- Helm-чарт ClickStack, PR #275: https://github.com/ClickHouse/ClickStack-helm-charts/pull/275
- Sentry snuba #7311, копии `*_log_N` без TTL: https://github.com/getsentry/snuba/issues/7311
- trigger.dev #4343, настройки профилей в config.d игнорируются: https://github.com/triggerdotdev/trigger.dev/issues/4343

---

ClickHouse — зарегистрированный товарный знак ClickHouse, Inc. diskvet не связан с ClickHouse, Inc.
Langfuse, SigNoz и ClickStack — товарные знаки их владельцев.
