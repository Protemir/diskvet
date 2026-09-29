# ClickHouse® Code 252: Too many parts. Merges are processing significantly slower than inserts
<!-- description: What Too many parts (Code 252, TOO_MANY_PARTS) means, how to check parts, merges and free space, and how to fix it with fewer, bigger inserts. -->

Your inserts fail, and ClickHouse® says:

```text
Code: 252. DB::Exception: Too many parts (3 with average size of 262.00 B) in table 'default.t (2a45a11e-0e4b-4fb9-98aa-cb69e9b29a6d)'. Merges are processing significantly slower than inserts. (TOO_MANY_PARTS)
```

This text comes from `clickhouse local` 25.12 and a test table with
`parts_to_throw_insert = 3`. 24.8 and 26.9 print the same text with another
average size. A 26.9 server, where async inserts are on by default, adds
`: While executing WaitForAsyncInsert` after `slower than inserts`. Real
reports read `Too many parts (10001 with average size of 12.94 KiB) in table
'signoz_metrics.time_series_v4_1week ...'` ([SigNoz #7983](https://github.com/SigNoz/signoz/issues/7983))
or `(3001 with average size of 37.52 KiB)` ([SigNoz #9794](https://github.com/SigNoz/signoz/issues/9794)),
often with a `while pushing to view ...` tail: the insert came through a
materialized view, and the table in the error is the target of the first view
named.

## Short answer

One partition of the table has reached `parts_to_throw_insert` active parts.
The default is 3000. From `parts_to_delay_insert` = 1000, ClickHouse slows each
insert down, by up to 1 s. Before 23.6 the limits were 300 and 150. Each insert
writes at least one new part (async inserts can share one), and background
merges join parts into bigger ones. So either the inserts are too many and too
small, or merges can't run. The checks below tell which.

Don't raise the limit: the [docs](https://clickhouse.com/docs/reference/settings/merge-tree-settings/parts-to#parts_to_throw_insert)
warn that SELECTs may get slower and that you notice a merge problem, such as
low disk space, later. A SigNoz maintainer called 10000 "way too many" (#7983).

## Check

Run these in a read-only client (`--readonly=1`, see [guide, section 1](../guide.md#1-what-is-using-the-disk-check-clickhouse-disk-usage-by-table)).

**1. Which partitions have the most parts, and what are the limits?**

```sql
SELECT database, table, partition_id, count() AS parts
FROM system.parts WHERE active
GROUP BY database, table, partition_id
ORDER BY parts DESC LIMIT 10;

SELECT name, value, changed FROM system.merge_tree_settings
WHERE name IN ('parts_to_delay_insert', 'parts_to_throw_insert');

SELECT event, value FROM system.events WHERE event IN ('DelayedInserts', 'RejectedInserts');
```

`changed = 1` means someone changed the server default. A table can also set
its own limits in `SETTINGS` (see `SHOW CREATE TABLE`). The last query counts
inserts slowed down or rejected since the server started; no row means zero.

**2. Do merges run?**

```sql
SELECT database, table, round(elapsed) AS sec, round(progress, 2) AS progress, num_parts FROM system.merges;
```

No merges while a partition has thousands of parts usually means they are
blocked: someone ran `SYSTEM STOP MERGES`, or the disk is nearly full. Merges
that run all the time while the count still grows can't keep up.

**3. Is there free space for merges?**

```sql
SELECT name, formatReadableSize(free_space) AS free,
       formatReadableSize(unreserved_space) AS unreserved, formatReadableSize(total_space) AS total
FROM system.disks;
```

A background merge takes source parts only up to half of the unreserved free
space ([CompactionStatistics.cpp](https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/src/Storages/MergeTree/Compaction/CompactionStatistics.cpp)),
so on a nearly full disk only small merges run. In our test, 8 parts of 7.7 MiB
with 22 MiB unreserved stayed unmerged, and 3 new 1 MiB parts stayed next to
them: 11 parts after 2 minutes. Once we freed space (167 MiB unreserved), all
11 merged into one within 30 s. Don't wait for a log message: the server log
gave no reason for the skipped background merges. Only `OPTIMIZE` says why
([Fix](#fix)). Disk nearly full? Start with [Not enough space](clickhouse-not-enough-space.md).

**4. How fast do new parts arrive?**

```sql
SELECT database, table, count() AS new_parts_last_hour,
       round(avg(rows)) AS avg_rows, formatReadableSize(avg(size_in_bytes)) AS avg_size
FROM system.part_log
WHERE event_type = 'NewPart' AND event_date >= yesterday() AND event_time > now() - INTERVAL 1 HOUR
GROUP BY database, table ORDER BY new_parts_last_hour DESC LIMIT 10;
```

Thousands of new parts an hour with a few rows each is the usual cause. On
25.12 and 26.9 the `system.*` logs show up too, up to about 480 parts an hour
each (one per flush), which is normal. 24.8 leaves system tables out of
`part_log` ([Context.cpp](https://github.com/ClickHouse/ClickHouse/blob/v24.8.14.39-lts/src/Interpreters/Context.cpp)).
If the query fails with Code 60 (`UNKNOWN_TABLE`), `part_log` is off on your
server, or the server started seconds ago: the table appears with the first
flush.

## Fix

**Send fewer, bigger inserts.** The ClickHouse docs recommend inserting "in
batches of at least 1,000 rows, and ideally between 10,000–100,000 rows", and
about one insert query per second
([insert strategy](https://clickhouse.com/docs/best-practices/selecting-an-insert-strategy#batch-inserts-if-synchronous)).

If many clients send small inserts at once, let the server batch them: add
`SETTINGS async_insert = 1, wait_for_async_insert = 1` to the `INSERT`, or set
both in the writer's settings. Keep the second at 1: with 0, the client may not
see insert errors (same docs page). Traps:

- **With `wait_for_async_insert = 1`, it helps only with concurrent inserts.** On 24.8, 25.12 and 26.9, 100 single-row inserts sent at once (100 parallel HTTP requests) made 100 parts with `async_insert = 0` and 1 or 2 with `async_insert = 1`. One writer that sends a row, waits, then sends the next still made one part per insert (20 of 20).
- **It is on by default since 26.2** ([`async_insert`](https://clickhouse.com/docs/reference/settings/session-settings/async-insert#async_insert)). On 26.9 the same 100 inserts made 1 part with no settings.
- **Langfuse already does it.** Its client sends every query with `async_insert: 1` and `wait_for_async_insert: 1` ([client.ts](https://github.com/langfuse/langfuse/blob/d59f50ea3636605629ac061597be0c104a70d58b/packages/shared/src/server/clickhouse/client.ts#L268-L269)).
  On Langfuse, look at merges and free space first (checks 2 and 3).

**SigNoz: fewer, bigger writes from the collector.** SigNoz writes through its
OpenTelemetry collector. Its `batch` processor sends a batch when
`send_batch_size` items have come in or when `timeout` has passed, whichever
comes first. `send_batch_max_size` splits bigger batches; 0, the default, means
no cap ([batch processor](https://github.com/open-telemetry/opentelemetry-collector/blob/v0.144.0/processor/batchprocessor/README.md)).
So to write less often, raise `send_batch_size` and `timeout` above what you
run now. A shorter `timeout` or a lower cap means more writes. Each collector
replica batches on its own. What SigNoz ships (size = `send_batch_size`, cap =
`send_batch_max_size`):

- **Docker Compose**, `deploy/docker/otel-collector-config.yaml`: size 10000, cap 11000, timeout 10s ([v0.129.0](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/otel-collector-config.yaml#L27-L30), the last release with these files). Restart the collector after the edit: `docker compose restart otel-collector` in `deploy/docker`.
- **Foundry**, SigNoz's Docker install after that release ([migration guide](https://github.com/SigNoz/signoz/blob/v0.144.0/deploy/MIGRATION.md)): its example `ingester/ingester.yaml` has size 50000, cap 55000, timeout 5s ([Foundry example](https://github.com/SigNoz/foundry/blob/db8a859301d373812680fe5c01d6c6564918438d/docs/examples/docker/compose/pours/deployment/ingester/ingester.yaml#L44-L47)). `foundryctl forge` writes that file. How to change it so the change stays is not checked here.
- **Helm**, `otelCollector.config.processors.batch`: size 50000, no cap, timeout 1s ([chart signoz-0.144.0](https://github.com/SigNoz/charts/blob/signoz-0.144.0/charts/signoz/values.yaml#L1642-L1644)). Put your values in the values file you pass to every `helm upgrade`.

In #7983 a maintainer found `send_batch_size: 512` too low. SigNoz team members
there and in #9794 suggested `send_batch_size: 20000`, `send_batch_max_size: 25000`,
`timeout: 1s`. That is smaller than what Helm and Foundry ship. Against the
Compose file, it writes every second instead of every 10 s at low traffic. So
compare it with your config before you copy it. None of the SigNoz settings
are tested here. Bigger batches didn't fix every case: in #7983 the user found
the suggested config worse, and still got the error with `send_batch_size:
100000` and `timeout: 22s`. In #9794 the chart's 50000 and 1s were in place,
and one metric had over 1.5 million time series.

**Free disk space if merges are blocked** (ClickHouse's own logs: [guide, section 2](../guide.md#2-how-do-i-free-the-disk-space-right-now)).
Merges then start again by themselves. If someone stopped them, start them
(safe). A restart starts them too: after `SYSTEM STOP MERGES` and a container
restart, 12 parts merged into one within a minute on 24.8 and 26.9.
`OPTIMIZE` merges one partition now, but it is heavy: it rewrites the whole
partition and needs more than twice its size in unreserved space. Take the
`partition_id` from check 1:

```sql
SYSTEM START MERGES db.table;
OPTIMIZE TABLE db.table PARTITION ID '202609' FINAL SETTINGS optimize_throw_if_noop = 1;
```

Without `optimize_throw_if_noop = 1`, an `OPTIMIZE` that can't run returns no
error and does nothing. With it, a nearly full disk gives `Code: 388 ...
(CANNOT_ASSIGN_OPTIMIZE)`. For 8 parts of 61.28 MiB, 25.12 said `Cannot
OPTIMIZE table: Not enough free space to merge parts from all_1_1_0 to
all_8_8_0. Has 20.69 MiB free and unreserved, 122.56 MiB required now`, and
26.9 gave the same message. 24.8 said `Cannot OPTIMIZE table: Insufficient
available disk space, required 122.80 MiB` and logged a warning, `Won't merge
parts from ... because not enough free space`. While merges are stopped,
`OPTIMIZE` fails with `Cancelled merging parts. (ABORTED)`, with or without
the setting. After a merge, the old parts stay on disk for [`old_parts_lifetime`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime)
(480 s).

**Your own tables: check `PARTITION BY`.** A key that is too fine (by hour, or
by a column with many values) splits each insert into many partitions, one part
each. That gives two other Code 252 errors (tested): `Too many partitions for single INSERT block (more than 100)`
([`max_partitions_per_insert_block`](https://clickhouse.com/docs/reference/settings/session-settings/max-partitions#max_partitions_per_insert_block))
and `Too many parts (N) in all partitions in total` ([`max_parts_in_total`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-parts#max_parts_in_total), default 100000).

## System logs hit it too

ClickHouse's own logs are MergeTree tables. Most flush every 7.5 s (stock
[config.xml](https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/programs/server/config.xml)),
one new part per flush: our 25.12 test server's `system.metric_log` got 39 in 5
minutes. If merges stop, they pile up. In ClickHouse #86927, `system.metric_log`
hit `Too many parts (300 ...)` on 23.4, where the limit was still 300; a
ClickHouse member called the version obsolete and asked to upgrade.

If a system log is the table in your error, find what blocks the merges
(checks 2 and 3). To get rid of its parts at once, empty it; its rows are lost
([guide, section 2](../guide.md#2-how-do-i-free-the-disk-space-right-now); a
log over 50 GB needs [the Code 359 fix](clickhouse-max-table-size-to-drop.md)).
Then set a TTL ([guide, section 4](../guide.md#4-how-do-i-set-a-ttl-on-clickhouse-system-logs)).
A TTL keeps the log small later; it doesn't lower the part count now.

## Why it happens

Each insert writes a new part: at least one per partition it touches, more for
a big insert (a 4-million-row `INSERT ... SELECT` made 4 parts in our test).
Merges join them in a pool with a fixed number of slots, and each merge needs
free disk space. When parts arrive faster than merges remove them, ClickHouse
slows inserts down at 1000 parts in one partition and rejects them at 3000
([`delayInsertOrThrowIfNeeded`](https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/src/Storages/MergeTree/MergeTreeData.cpp)).
Materialized views multiply this: an insert into the source table also writes a
part into each view's target table (tested with two views). Big parts can hit
the limit too: they averaged 84.45 MiB in ClickHouse #95158. The check skips a
partition only when its parts average more than 1 GiB
([`max_avg_part_size_for_too_many_parts`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max#max_avg_part_size_for_too_many_parts)).

## Tested on

ClickHouse 24.8.14.39, 25.12.11.4 and 26.9.1.1629 (`clickhouse/clickhouse-server`
images, 800 MiB memory limit): the error texts (`clickhouse local` and server,
also through a materialized view), defaults, the checks with `--readonly=1`,
async inserts (100 parallel HTTP inserts, 20 in a row), the 4-million-row
insert, the two partition errors, `SYSTEM START MERGES`, `OPTIMIZE` with
merges stopped and on a nearly full disk (a 256 MiB tmpfs), and the
`old_parts_lifetime` default. Merges after a restart: 24.8 and 26.9. The
unmerged parts on the nearly full disk and the `metric_log` count: 25.12 only.
The `part_log` error: also 24.1.2. diskvet 0.3.1 ran against 26.9. The SigNoz
settings come from the issues and SigNoz's own files, not from a deploy.

## Sources

- Settings: `parts_to_delay_insert`, `parts_to_throw_insert` (defaults, 300 before 23.6, raising it) https://clickhouse.com/docs/reference/settings/merge-tree-settings/parts-to, 150 and 300 in 23.5 https://github.com/ClickHouse/ClickHouse/blob/v23.5.5.92-stable/src/Storages/MergeTree/MergeTreeSettings.h, `max_avg_part_size_for_too_many_parts` https://clickhouse.com/docs/reference/settings/merge-tree-settings/max#max_avg_part_size_for_too_many_parts, `max_delay_to_insert` https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-delay#max_delay_to_insert, `max_parts_in_total` https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-parts#max_parts_in_total, `max_partitions_per_insert_block` https://clickhouse.com/docs/reference/settings/session-settings/max-partitions#max_partitions_per_insert_block
- Insert strategy (batch size, one insert per second, async inserts): https://clickhouse.com/docs/best-practices/selecting-an-insert-strategy
- `async_insert` on by default since 26.2: https://clickhouse.com/docs/reference/settings/session-settings/async-insert#async_insert, https://github.com/ClickHouse/ClickHouse/blob/v26.9.1.1629-stable/src/Core/SettingsChangesHistory.cpp
- Source (limit check and error texts; half of unreserved space; `Not enough free space to merge parts`): https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/src/Storages/MergeTree/MergeTreeData.cpp, https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/src/Storages/MergeTree/Compaction/CompactionStatistics.cpp, https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/src/Storages/MergeTree/MergeTreeDataMergerMutator.cpp; 24.8 (`Insufficient available disk space`, `Won't merge parts`) https://github.com/ClickHouse/ClickHouse/blob/v24.8.14.39-lts/src/Storages/MergeTree/MergeTreeDataMergerMutator.cpp; 24.8 leaves system tables out of `part_log` https://github.com/ClickHouse/ClickHouse/blob/v24.8.14.39-lts/src/Interpreters/Context.cpp
- `old_parts_lifetime`: https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime
- Statements and tables: OPTIMIZE https://clickhouse.com/docs/reference/statements/optimize, `optimize_throw_if_noop` https://clickhouse.com/docs/reference/settings/session-settings/optimize#optimize_throw_if_noop, SYSTEM START MERGES https://clickhouse.com/docs/reference/statements/system#start-merges, https://clickhouse.com/docs/reference/system-tables/parts, https://clickhouse.com/docs/reference/system-tables/merges, https://clickhouse.com/docs/reference/system-tables/disks, https://clickhouse.com/docs/reference/system-tables/part_log
- Stock `config.xml` (system logs flush every 7500 ms): https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/programs/server/config.xml
- Issues: ClickHouse #86927 https://github.com/ClickHouse/ClickHouse/issues/86927, #95158 https://github.com/ClickHouse/ClickHouse/issues/95158; SigNoz #7983 https://github.com/SigNoz/signoz/issues/7983, #9794 https://github.com/SigNoz/signoz/issues/9794
- OpenTelemetry batch processor (`send_batch_size`, `timeout`, `send_batch_max_size`): https://github.com/open-telemetry/opentelemetry-collector/blob/v0.144.0/processor/batchprocessor/README.md
- SigNoz v0.129.0 collector config and compose file https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/otel-collector-config.yaml, https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml; Foundry migration https://github.com/SigNoz/signoz/blob/v0.144.0/deploy/MIGRATION.md; Foundry example collector config https://github.com/SigNoz/foundry/blob/db8a859301d373812680fe5c01d6c6564918438d/docs/examples/docker/compose/pours/deployment/ingester/ingester.yaml; SigNoz Helm chart signoz-0.144.0 https://github.com/SigNoz/charts/blob/signoz-0.144.0/charts/signoz/values.yaml
- Langfuse ClickHouse client https://github.com/langfuse/langfuse/blob/d59f50ea3636605629ac061597be0c104a70d58b/packages/shared/src/server/clickhouse/client.ts

## Check it with diskvet

[diskvet](https://github.com/Protemir/diskvet) is a free, open-source,
read-only script. Its check 5 ([What it checks](https://github.com/Protemir/diskvet#what-it-checks))
lists the partitions with the most parts next to each table's own limits: WARN
from 300 parts, CRITICAL at the table's `parts_to_delay_insert`, plus delayed
and rejected inserts. Read `checks.sql` first (SigNoz: `--docker signoz-clickhouse`;
Kubernetes: `--k8s auto`):

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

---

ClickHouse is a registered trademark of ClickHouse, Inc. diskvet is not affiliated with ClickHouse, Inc.
