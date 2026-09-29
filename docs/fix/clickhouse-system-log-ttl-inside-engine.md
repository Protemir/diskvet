# ClickHouse® Code 36: TTL parameters should be specified directly inside 'engine'
<!-- description: ClickHouse® exits with Code 36 after you add a TTL for opentelemetry_span_log. Put the TTL inside <engine> or switch the log off. -->

You added a `config.d` file with TTLs for the system logs, restarted, and now
ClickHouse® doesn't start. Its error log says:

```text
<Error> Application: Code: 36. DB::Exception: If 'engine' is specified for system table, TTL parameters should be specified directly inside 'engine' and 'ttl' setting doesn't make sense. (BAD_ARGUMENTS), Stack trace (when copying this message, always include the lines below):
```

The line starts with the date and time. ClickHouse 24.8, 25.12 and 26.9 print
the same text. It also appears once more, after `Caught exception while
loading metadata:`. `docker ps -a` shows the container as `Exited (36)`, or as
`Restarting (36)` with `restart: always`.

## Short answer

Your file sets `<ttl>` for a system log that the config also defines with
`<engine>`. In the stock `config.xml` that log is `opentelemetry_span_log`: it
is the only stock log with an `<engine>` in every version checked, 24.1 to
26.9. ClickHouse refuses the combination and exits at startup. Put the TTL
inside the `<engine>` string, or switch that log off.

## Check

`docker compose logs clickhouse` may not show the error. The stock images
print the server log to the console only with a TTY (the `<console>` comment
in `config.xml`). Without one, the output stops at `Logging errors to
/var/log/clickhouse-server/clickhouse-server.err.log`. Copy the error log out
of the container. This works on a stopped one too:

```sh
docker cp "$(docker compose ps -aq clickhouse)":/var/log/clickhouse-server/clickhouse-server.err.log .
grep 'Code: 36' clickhouse-server.err.log | tail -n 2
```

Two stacks ship their own `config.xml`, and it changes this step:

- **SigNoz**, from its last compose file (v0.129.0; later releases install
  through Foundry): the file sets `tty: true`, so the error is in
  `docker compose logs clickhouse` too. SigNoz's `config.xml` writes the log
  as JSON, so the text is in the `message` field. The container is
  `signoz-clickhouse`: outside the compose folder, put that name in place of
  `"$(docker compose ps -aq clickhouse)"`.
- **ClickStack**, from its compose file: the service is `ch-server`, and its
  `config.xml` logs only to the console. There is no `clickhouse-server.err.log`, so run
  `docker compose logs ch-server`. Use `ch-server` in place of `clickhouse` in
  the commands below.

Now find the logs that have an `<engine>`. ClickHouse writes the config it
built from `config.xml` and all `config.d` files to `preprocessed_configs/`.
This prints its engines without saving the file, which can hold secrets from
your config:

```sh
docker cp "$(docker compose ps -aq clickhouse)":/var/lib/clickhouse/preprocessed_configs/config.xml - | tar -xO |
  awk '/^[ \t]*<[a-z_]+_log>/ {name = $1} /^[ \t]*<engine>/, /<\/engine>/ {print name, $0}'
```

With the stock config of 25.3 and later it prints:

```text
<opentelemetry_span_log>         <engine>
<opentelemetry_span_log>             engine MergeTree
<opentelemetry_span_log>             partition by toYYYYMM(finish_date)
<opentelemetry_span_log>             order by (finish_date, finish_time_us)
<opentelemetry_span_log>         </engine>
```

The stock config up to 25.2 (all of 24.x) and the `config.xml` of
[SigNoz](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml)
and
[ClickStack](https://github.com/ClickHouse/ClickStack/blob/463e1ab65b92cfc76c6dfd8ed22bcffed9d0807f/docker/clickhouse/local/config.xml)
sort by `(finish_date, finish_time_us, trace_id)`, so there the `order by`
line ends in `trace_id)`.

Don't give any log in this list a `<ttl>` in your file. Keep its
`PARTITION BY` and `ORDER BY` for fix 1.

When the server runs, this query shows the table's current engine. Run it
read-only, as in [section 1 of the guide](../guide.md#1-what-is-using-the-disk-check-clickhouse-disk-usage-by-table):

```sql
SELECT engine_full FROM system.tables
WHERE database = 'system' AND name = 'opentelemetry_span_log';
```

## Fix

Pick one of the three, then recreate the container (`docker-compose.yml` didn't change):

```sh
docker compose up -d --force-recreate clickhouse
docker compose ps clickhouse
```

### Fix 1: put the TTL inside `<engine>`

Replace the `opentelemetry_span_log` section of your file with this one. Use
the `PARTITION BY` and `ORDER BY` from the check. This one has the keys of
25.3 and later; up to 25.2 and on SigNoz and ClickStack, end the `ORDER BY`
with `, trace_id)`:

```xml
<opentelemetry_span_log>
    <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
</opentelemetry_span_log>
```

Three traps:

- **No `<ttl>` next to it.** A section with both `<engine>` and `<ttl>` still fails with Code 36.
- **The column is `finish_date`.** This log has no `event_date` column, so don't copy the TTL of the other logs.
- **Not only `<ttl>`.** With an `<engine>`, ClickHouse also refuses `<partition_by>`, `<order_by>`, `<storage_policy>` and `<settings>` for that log, each with its own Code 36 message ([source](https://github.com/ClickHouse/ClickHouse/blob/37b5e007f5d85cd264ef7fb22dd5b5b935580d2f/src/Interpreters/SystemLog.cpp#L173-L194)).

### Fix 2: switch the log off

```xml
<opentelemetry_span_log remove="1"/>
```

This is how Langfuse's [scaling docs](https://langfuse.com/self-hosting/configuration/scaling)
do it; Langfuse doesn't read this table
([#13123](https://github.com/langfuse/langfuse/issues/13123)). `remove`
doesn't delete a table that already exists: it keeps its old rows, and
ClickHouse no longer writes to it. Drop it in the write-access client from
[section 2 of the guide](../guide.md#2-how-do-i-free-the-disk-space-right-now):

```sql
DROP TABLE system.opentelemetry_span_log;
```

`DROP` can't be undone. Over 50 GB, add `SETTINGS max_table_size_to_drop = 0`
([Code 359](../guide.md#truncate-fails-with-code-359-tables-over-50-gb)).

### Fix 3: take the section out

Delete the `opentelemetry_span_log` section from your file. The server starts,
but this log still has no TTL and keeps every span written to it. In Langfuse
#13123 it was 64.53 MiB, next to a 66.86 GiB `trace_log`.

## After the fix

Right after the restart, an existing `opentelemetry_span_log` can still show no
TTL. ClickHouse applies the new engine when it next flushes that log: it
renames the old table to `opentelemetry_span_log_0` (`_1` if a `_0` is already
there), with all its old rows and its old engine, and creates a new one with
the TTL. To make that happen now, run this in the write-access client:

```sql
SYSTEM FLUSH LOGS;

SELECT name, extract(engine_full, 'TTL [^S]*') AS ttl
FROM system.tables
WHERE database = 'system' AND name LIKE 'opentelemetry_span_log%';
```

With fix 1 you should see `TTL finish_date + toIntervalDay(7)` on
`opentelemetry_span_log`, and an empty `ttl` on `opentelemetry_span_log_0`.
Drop each copy the query lists (there is none if the table didn't exist
before). `DROP` can't be undone:

```sql
DROP TABLE system.opentelemetry_span_log_0;
```

The other logs your file gave a TTL get a copy too, such as `query_log_0`.
[Step 4 of the guide](../guide.md#step-4-drop-the-old-trace_log_0-copies)
writes the `DROP` for all these copies.

## Kubernetes

Charts that run the ClickHouse operator, such as Langfuse's chart 2.x, take
this config as YAML: the log becomes `engine: "..."` with the same text.
SigNoz's chart defines 14 more system logs with their own `<engine>`, among
them `query_log`, `part_log`, `trace_log` and `metric_log`
([source](https://github.com/SigNoz/charts/blob/8aa479daf5d25a751ba9cf7a5df99dfbed80bc6c/charts/clickhouse/templates/clickhouse-operator/configmaps/etc-configd-files.yaml)),
so there a `<ttl>` for any of them stops ClickHouse too. Change their TTL
with the chart's values instead: `clickhouse.clickhouseOperator.<logName>.ttl`,
in days, with the log name in camelCase, such as `queryLog`
([values](https://github.com/SigNoz/charts/blob/8aa479daf5d25a751ba9cf7a5df99dfbed80bc6c/charts/signoz/values.yaml)).
The
[Kubernetes recipe](https://github.com/Protemir/diskvet/blob/main/docs/recipes/kubernetes.md#troubleshooting)
shows how to read the crashed pod's log, and which values key takes the TTL
for each chart.

## Why it happens

ClickHouse merges each `config.d` file into `config.xml`: a section with the
same name is merged with the stock one, child by child
([docs](https://clickhouse.com/docs/concepts/features/configuration/server-config/configuration-files)).
Your `<opentelemetry_span_log>` with a `<ttl>` lands next to the stock
`<engine>`.

The stock config defines this log with an `<engine>` because it has no
`event_time`, only a start and a finish time, and it is sorted by finish time
([`config.xml`](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml)).
The [docs](https://clickhouse.com/docs/reference/system-tables/overview) say
that `engine` "conflicts with partition_by and ttl": set together, the server
raises an exception and exits. This holds for any system log that your config
defines with `<engine>`, not only this one.
[ClickHouse #88366](https://github.com/ClickHouse/ClickHouse/issues/88366),
which asks for a TTL without touching the stock config, is still open.

## Tested on

Stock `clickhouse/clickhouse-server` 24.8.14.39, 25.12.11.4 and 26.9.1.1629
in Docker: the error and the two log lines, the `docker cp` and `awk` checks,
the `engine_full` query, the five Code 36 checks, all three fixes, the `_0`
copy and both `DROP`s. On 24.8 and 26.9 only: the error in `docker logs` with
a TTY, fix 1 with `trace_id` in the `ORDER BY`, `SETTINGS
max_table_size_to_drop = 0` against a lower server limit, and the TTL file of
diskvet 0.3.1. On 26.9 only: the compose commands, `restart: always`, the
`_1` copy and the `query_log_0` copy, and ClickStack's `config.xml` with the
failing file (the error in `docker logs` without a TTY, no `err.log`; its
compose file uses 26.1). SigNoz v0.129.0's `config.xml` on 25.5.11 with a TTY: the error
as JSON in `docker logs` and in `err.log`, and the `awk` check. The
`<engine>` list and the `trace_id` change: the stock `config.xml` of the
images 24.1.2, 24.3.18, 25.5.11 and 25.8.5, and of the source tags 24.10,
24.12 and 25.1 to 25.4. SigNoz's compose files and chart were read, not run,
and so was the Kubernetes part.

## Sources

- System tables overview (`engine` conflicts with `partition_by` and `ttl`): https://clickhouse.com/docs/reference/system-tables/overview
- Configuration files (merging, `remove`, preprocessed files): https://clickhouse.com/docs/concepts/features/configuration/server-config/configuration-files
- Default `config.xml` (`opentelemetry_span_log` with `<engine>`, console logging only with a TTY): https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml
- The five checks in `SystemLog.cpp`: https://github.com/ClickHouse/ClickHouse/blob/37b5e007f5d85cd264ef7fb22dd5b5b935580d2f/src/Interpreters/SystemLog.cpp#L173-L194
- ClickHouse #88366, TTL for `opentelemetry_span_log`: https://github.com/ClickHouse/ClickHouse/issues/88366
- Langfuse scaling docs (`remove="1"`, TTL inside `<engine>`): https://langfuse.com/self-hosting/configuration/scaling
- Langfuse #13123 (table sizes, tables Langfuse reads): https://github.com/langfuse/langfuse/issues/13123
- SigNoz v0.129.0 ClickHouse `config.xml`: https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml
- SigNoz v0.129.0 compose file (`tty: true`, `signoz-clickhouse`): https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml
- SigNoz v0.130.0 deploy README (compose files deprecated, Foundry): https://github.com/SigNoz/signoz/blob/v0.130.0/deploy/README.md
- SigNoz chart, the logs it defines with `<engine>`: https://github.com/SigNoz/charts/blob/8aa479daf5d25a751ba9cf7a5df99dfbed80bc6c/charts/clickhouse/templates/clickhouse-operator/configmaps/etc-configd-files.yaml
- SigNoz chart values (`clickhouseOperator.<logName>.ttl`): https://github.com/SigNoz/charts/blob/8aa479daf5d25a751ba9cf7a5df99dfbed80bc6c/charts/signoz/values.yaml
- ClickStack compose file (`ch-server`): https://github.com/ClickHouse/ClickStack/blob/463e1ab65b92cfc76c6dfd8ed22bcffed9d0807f/docker-compose.yml
- ClickStack `config.xml` (console only, no log files, `trace_id` in the span log's `ORDER BY`): https://github.com/ClickHouse/ClickStack/blob/463e1ab65b92cfc76c6dfd8ed22bcffed9d0807f/docker/clickhouse/local/config.xml

The full TTL setup is in [step 2 of the guide](../guide.md#step-2-add-a-ttl-file-in-configd).
Once the server runs again, [diskvet](https://github.com/Protemir/diskvet)
checks all system logs at once. It is a free, read-only script. The TTL file
it prints already puts this TTL inside `<engine>`, with the keys of your
table. Read `checks.sql` before you run it:

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

---

ClickHouse is a registered trademark of ClickHouse, Inc. diskvet is not affiliated with ClickHouse, Inc.
