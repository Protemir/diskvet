# ClickHouse® system.trace_log and text_log are huge: how to fix it
<!-- description: Why system.trace_log and text_log fill the disk in self-hosted ClickHouse®, how to empty them now and add a TTL so they stay small. -->

Your Langfuse, SigNoz or ClickStack disk keeps filling, but your own data is
small. In the size list, `system.trace_log` or `system.text_log` is at the top.

## Short answer

These tables are ClickHouse®'s own diagnostic logs, not your data. The
[documentation](https://clickhouse.com/docs/reference/system-tables/overview)
says it plainly: "By default, table growth is unlimited." Empty them with
`TRUNCATE` (no restart). Then add a TTL in `config.d`, restart, and drop the
old copies the restart leaves, so they stay small.

## Check

Save this query as `size.sql`. It lists the biggest tables by size on disk:

```sql
SELECT database, table, formatReadableSize(sum(bytes_on_disk)) AS size,
       sum(rows) AS rows, count() AS parts
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 15;
```

Run it read-only. Langfuse: in the folder with its `docker-compose.yml`.
SigNoz: the container is `signoz-clickhouse` (old compose files) or
`signoz-telemetrystore-clickhouse-0-0` (Foundry); check with `docker ps`.

```sh
# Langfuse
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < size.sql
# SigNoz
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --format PrettyCompact < size.sql
```

`--readonly=1` makes ClickHouse refuse any change. Compare the `system` rows
with your data (`default` for Langfuse, `signoz_*` for SigNoz). If the
`system` logs are bigger, this page is your fix.

Kubernetes: run the same client with `kubectl exec` in the ClickHouse pod. The
[Kubernetes recipe](../recipes/kubernetes.md#charts-at-a-glance) names the pod
and container for each Helm chart.

## Fix

### 1. Empty the logs now

Open a client with write access
([guide, section 2](../guide.md#2-how-do-i-free-the-disk-space-right-now))
and empty the big logs:

```sql
TRUNCATE TABLE system.trace_log;
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.metric_log;
TRUNCATE TABLE system.query_log;
```

This deletes only ClickHouse's own diagnostics, not your traces. Run only the
lines for logs in your size list: `TRUNCATE` of a log your server doesn't have
fails with Code 60 (`UNKNOWN_TABLE`). SigNoz's config and the stock config
before 24.8 don't turn on `text_log`.

- **Over 50 GB (46.6 GiB in the size list)?** `TRUNCATE` fails with Code 359. Add `SETTINGS max_table_size_to_drop = 0` to that statement ([Code 359 page](clickhouse-max-table-size-to-drop.md)).
- **Disk at 100%?** `TRUNCATE` can fail with Code 243 (`NOT_ENOUGH_SPACE`). The [Code 243 page](clickhouse-not-enough-space.md) has the `DROP ... SYNC` way.
- **Langfuse reads `system.query_log`** to follow some of its own queries ([#13123](https://github.com/langfuse/langfuse/issues/13123)). Empty it, but don't switch it off.

### 2. Add a TTL so they stay small

Save this as `clickhouse-ttl.xml` next to `docker-compose.yml` (the file from
[guide, step 2](../guide.md#step-2-add-a-ttl-file-in-configd)):

```xml
<clickhouse>
    <!-- Keep 7 days of ClickHouse's own logs. List only logs your server has. -->
    <query_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_log>
    <trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
    <text_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></text_log>
    <metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></metric_log>
    <asynchronous_metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></asynchronous_metric_log>
    <part_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></part_log>
    <opentelemetry_span_log>
        <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
    </opentelemetry_span_log>
</clickhouse>
```

Mount it into the `clickhouse` service (keep your existing volume lines), then
run `docker compose up -d clickhouse`. That recreates the container and
restarts ClickHouse. The TTL takes effect only at a restart.

```yaml
  clickhouse:
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

- **`opentelemetry_span_log` takes its TTL inside `<engine>`**, with the `ORDER BY` your server uses: `SELECT engine_full FROM system.tables WHERE database = 'system' AND name = 'opentelemetry_span_log'` shows it. The file above has the `ORDER BY` of the stock config in 25.3 and newer ([PR #75907](https://github.com/ClickHouse/ClickHouse/pull/75907)). On 25.2 and older (all of 24.x), and with SigNoz's and ClickStack's own `config.xml`, end it with `, trace_id)`. A plain `<ttl>` there stops ClickHouse with Code 36 ([Code 36 page](clickhouse-system-log-ttl-inside-engine.md)).
- **No `text_log` before 24.8 or on SigNoz.** The stock config turns it on from 24.8, and SigNoz's own [`config.xml`](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml) doesn't. Delete that line there, because a section in the config turns a log on: on 24.3, this line alone turned `text_log` on, with messages down to `Trace`.
- **SigNoz:** also add `processors_profile_log`, which has no TTL in that file.
- **More logs have no TTL:** `error_log`; on 24.8 also `processors_profile_log` (the stock config keeps it 30 days from 25.2 on, [PR #66139](https://github.com/ClickHouse/ClickHouse/pull/66139)); on 25.12 and 26.9 also `query_metric_log` and `background_schedule_pool_log`. If they are big on your server, add them the same way.
- **Keep the mount line.** If you replace `docker-compose.yml` with a new copy, for example when you update Langfuse, add the line again. Without the file, the next restart moves each log, TTL and all, to a `_0` copy and creates it again without a TTL.
- **Kubernetes:** the TTL goes into your Helm chart's values, not into the pod. Files written inside a container, outside its volumes, are gone when it restarts ([Kubernetes docs](https://kubernetes.io/docs/concepts/storage/volumes/)). The [Kubernetes recipe](../recipes/kubernetes.md#charts-at-a-glance) has the values key for each chart.

### 3. Drop the old copies

The restart keeps each changed log's old table, with all its rows and no TTL,
as `trace_log_0`, `text_log_0` and so on. A log moves to its new table at its
first flush after the restart, so flush first, then list the copies:

```sql
SYSTEM FLUSH LOGS;
SELECT 'DROP TABLE system.' || name || ' SYNC SETTINGS max_table_size_to_drop = 0;'
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$');
```

Read the statements, then paste them into the client. `DROP` can't be undone.
`SYNC` gives the space back at once. Without it, the `system` database
(Atomic) keeps the data for 8 minutes
([`database_atomic_delay_before_drop_table_sec`](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#database_atomic_delay_before_drop_table_sec) = 480 s).
`SYNC` goes before `SETTINGS`; after it, the statement fails with Code 62
(`SYNTAX_ERROR`). More on the copies:
[system log copies](clickhouse-system-log-copies.md).

### 4. Check the result

Run the TTL query from [guide, step 1](../guide.md#step-1-which-logs-have-no-ttl):
every big log should show a TTL, and no `_N` names should be left. ClickHouse
deletes expired rows in merges and repeats a TTL merge at most every 4 hours
([`merge_with_ttl_timeout`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout) = 14400 s).
If the size doesn't go down, see [TTL not freeing disk](clickhouse-ttl-delete-not-freeing-disk.md).

### Don't use ALTER TABLE ... MODIFY TTL

`ALTER TABLE system.query_log MODIFY TTL event_date + INTERVAL 7 DAY` works
until the next restart. Then ClickHouse sees that the table differs from its
config, logs `Renaming it to query_log_0`, and creates a new `query_log`
without a TTL. Your TTL stays on the copy. Put it in `config.d` instead.

### Or stop what writes trace_log

If nobody reads `trace_log`, add `<clickhouse><trace_log remove="1"/></clickhouse>`
as a `config.d` file (and delete the `trace_log` line from `clickhouse-ttl.xml`),
recreate the container, then drop the old table, which `remove="1"` leaves on
disk: `DROP TABLE system.trace_log SYNC SETTINGS max_table_size_to_drop = 0;`

To keep the table but stop the profilers, turning off only the query profiler
is not enough on 25.10 and newer: the global profiler keeps writing. With all
six settings below at `0` and the container recreated, `trace_log` got no new
rows on 25.12 and 26.9:

- in `users.d/`, under `<profiles><default>`: `query_profiler_real_time_period_ns`, `query_profiler_cpu_time_period_ns` and `memory_profiler_step`. Under `<profiles>` in `config.d/` they are ignored ([trigger.dev #4343](https://github.com/triggerdotdev/trigger.dev/issues/4343)). At the top level of `config.d/`, ClickHouse doesn't start: `A setting 'query_profiler_real_time_period_ns' appeared at top level in config` (Code 137, `UNKNOWN_ELEMENT_IN_CONFIG`).
- in `config.d/`, at the top level: `global_profiler_real_time_period_ns`, `global_profiler_cpu_time_period_ns` and `total_memory_profiler_step`.

## Why it happens

ClickHouse writes its own diagnostics into `system.*_log` tables, and the stock
[`config.xml`](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml) gives only a few of them a TTL:

- **With a TTL (25.12, 26.9):** `processors_profile_log`, `blob_storage_log`, `aggregated_zookeeper_log` and `zookeeper_connection_log` keep 30 days, `asynchronous_insert_log` 3 days. On 24.8 only `blob_storage_log` and `asynchronous_insert_log` have one.
- **No TTL:** `trace_log`, `text_log`, `query_log`, `metric_log`, `asynchronous_metric_log`, `part_log`, `error_log`, `opentelemetry_span_log`, `query_metric_log` and others.

Four defaults fill `trace_log` and `text_log`:

- **The query profiler** samples each query's threads once a second of real time and once a second of CPU time ([`query_profiler_real_time_period_ns` and `query_profiler_cpu_time_period_ns`](https://clickhouse.com/docs/reference/settings/session-settings/query-profiler) = 1000000000).
- **The memory profiler** writes a stack trace at every 4 MiB step of a query's memory ([`memory_profiler_step`](https://clickhouse.com/docs/reference/settings/session-settings/memory-profiler#memory_profiler_step) = 4194304). The stock `config.xml` sets the server-wide `total_memory_profiler_step` to 4 MiB too.
- **The global profiler**, on by default since 25.10 ([PR #88209](https://github.com/ClickHouse/ClickHouse/pull/88209)), samples every server thread every 10 seconds of real time and every 10 seconds of CPU time, query or not ([`global_profiler_real_time_period_ns` and `global_profiler_cpu_time_period_ns`](https://clickhouse.com/docs/reference/settings/server-settings/settings/global-profiler#global_profiler_real_time_period_ns) = 10000000000). On idle 25.12 and 26.9 test servers, most `trace_log` rows were its samples (`trace_type` `Real`, empty `query_id`).
- **`text_log`**, on by default since 24.8 ([PR #67428](https://github.com/ClickHouse/ClickHouse/pull/67428)), stores the server log at `<level>trace</level>` in the stock `config.xml`.

Public cases:

- [Langfuse #13123](https://github.com/langfuse/langfuse/issues/13123): `system.trace_log` was 66.86 GiB, while `traces`, `observations` and `scores` took about 51 MiB together.
- [Opik #6224](https://github.com/comet-ml/opik/issues/6224): `trace_log` was 66.42 GiB with 3 billion rows. ClickHouse's own tables were 98% of the volume.
- [ClickStack Helm chart #191](https://github.com/ClickHouse/ClickStack-helm-charts/issues/191): `trace_log` reached ~97 GB in about 6 weeks and filled a 108 GB PVC. [PR #275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275) adds a 7-day TTL to five logs in the chart, not to `trace_log`.
- [SigNoz #12050](https://github.com/SigNoz/signoz/issues/12050): more than 80 GB of system logs next to less than 500 MB of telemetry.
- [Laminar #2176](https://github.com/lmnr-ai/lmnr/issues/2176): 13.4 GiB of system logs (11 GiB of it `trace_log`) against 15.6 KiB of data, after a month of light use.

## Tested on

ClickHouse 24.8.14.39, 25.12.11.4 and 26.9.1.1629 (stock images, Docker
29.3.0): the defaults above and every step on this page, with the `SYNC` drop
list, `SYNC` after `SETTINGS` (Code 62) and a restart after the mount line is
gone. The `remove="1"` drop with `SYNC` on 24.8 and 26.9. On 24.3.18.7: no `text_log`,
`TRUNCATE` of it fails with Code 60, and the TTL file turns it on. The
`opentelemetry_span_log` `ORDER BY` and the `processors_profile_log` TTL are
from the stock `config.xml` of 24.1.2.5, 24.3.18.7, 24.8, 25.5.11.15,
25.8.5.17, 25.12 and 26.9, and of the source tags 24.10.1 to 25.5.1 (read, not
run). Code 359 with `max_table_size_to_drop` lowered to
1 byte. The compose commands and the diskvet 0.3.1 report on 25.12 with a
compose file like Langfuse's (Compose v5.1.0). The SigNoz command with another
container name. The global profiler is off on 25.5.11.15 and 25.8.5.17. Not
run: a full disk, a real 50 GB table, SigNoz's own `config.xml`, Kubernetes,
the two `curl` downloads (both URLs answer).

## Sources

- System tables overview (unlimited growth): https://clickhouse.com/docs/reference/system-tables/overview
- Default `config.xml` (log TTLs, `text_log` level, `total_memory_profiler_step`): https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml
- `text_log` on by default since 24.8: https://github.com/ClickHouse/ClickHouse/pull/67428, https://github.com/ClickHouse/ClickHouse/blob/master/docs/changelogs/v24.8.1.2684-lts.md
- `processors_profile_log` keeps 30 days since 25.2: https://github.com/ClickHouse/ClickHouse/pull/66139; `trace_id` left the `opentelemetry_span_log` `ORDER BY` in 25.3: https://github.com/ClickHouse/ClickHouse/pull/75907
- The rename of a changed log: https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/SystemLog.cpp
- DROP and `SYNC`, the drop delay: https://clickhouse.com/docs/reference/statements/drop, https://clickhouse.com/docs/reference/settings/server-settings/settings/other#database_atomic_delay_before_drop_table_sec
- Files in a container are lost when it restarts: https://kubernetes.io/docs/concepts/storage/volumes/
- system.trace_log (`trace_type`): https://clickhouse.com/docs/reference/system-tables/trace_log
- Profiler settings: https://clickhouse.com/docs/reference/settings/session-settings/query-profiler, https://clickhouse.com/docs/reference/settings/session-settings/memory-profiler#memory_profiler_step, https://clickhouse.com/docs/reference/settings/server-settings/settings/total-memory#total_memory_profiler_step, https://clickhouse.com/docs/reference/settings/server-settings/settings/global-profiler#global_profiler_real_time_period_ns (the global one needs a restart); on by default since 25.10: https://github.com/ClickHouse/ClickHouse/pull/88209, https://github.com/ClickHouse/ClickHouse/blob/master/docs/changelogs/v25.10.1.3832-stable.md
- Altinity KB, "System tables ate my disk" (restart needed): https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/

## Check it with diskvet

[diskvet](https://github.com/Protemir/diskvet) is a free, open-source,
read-only script. It runs the size and TTL checks and prints the `TRUNCATE`
commands for the big logs, the TTL file and the `DROP` list for your tables.
Read `checks.sql` before you run it (`--docker auto` finds SigNoz's
ClickHouse too; Kubernetes: `--k8s auto`):

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

More depth: [guide, section 3](../guide.md#3-why-are-trace_log-and-text_log-so-big) and [section 4](../guide.md#4-how-do-i-set-a-ttl-on-clickhouse-system-logs).

---

ClickHouse is a registered trademark of ClickHouse, Inc. diskvet is not affiliated with ClickHouse, Inc.
