# ClickHouse® trace_log_0 and query_log_1: old system log copies
<!-- description: What trace_log_0, query_log_1 and other _N system tables are, why they have no TTL, and how to drop them safely. -->

Your `system` database has tables like `trace_log_0`, `query_log_1` or
`text_log_2`, and some of them are big. ClickHouse® made them itself. At the
default `trace` log level, the server log has a line for each one:

```text
<Debug> SystemLog (system.query_log): Existing table system.query_log for system log has obsolete or different structure. Renaming it to query_log_0.
```

The next two lines, `Old:` and `New:`, hold the old table's definition and
the one ClickHouse wants, so you can see what differed.

## Short answer

After a restart, when ClickHouse first writes to a system log, it compares
the log's definition in the config with the existing table. If they differ, it
renames the old table to `name_N` and creates a new one. They differ when:

- you added, changed or removed a TTL, in `config.d` or with `ALTER TABLE`;
- you changed other engine settings, such as the storage policy;
- an upgrade changed the log's schema.

The copy keeps all its old rows and gets no new ones. It keeps the TTL it had,
which for most logs is none. ClickHouse doesn't write to it again or read it
for its own work, so you can drop it.

## Check

Save this as `copies.sql`:

```sql
SELECT name,
       formatReadableSize(total_bytes) AS size,
       total_rows AS rows,
       extract(engine_full, 'TTL [^S]*') AS ttl
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$')
ORDER BY total_bytes DESC;
```

Run it read-only, like `size.sql` in the
[guide](../guide.md#1-what-is-using-the-disk-check-clickhouse-disk-usage-by-table):

```sh
# Langfuse
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < copies.sql
# SigNoz
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --format PrettyCompact < copies.sql
```

No rows means no copies. An empty `ttl` means the copy keeps its rows forever.

Right after a restart, some copies may not exist yet. By default a log makes
its copy at its first flush, not at startup: a busy log within seconds, a log
that gets no new rows (such as `backup_log`) only when it gets one. To make
them all now, run `SYSTEM FLUSH LOGS;` in a client with write access
([guide, section 2](../guide.md#2-how-do-i-free-the-disk-space-right-now)).

To see when each copy was made (Langfuse; SigNoz's
[config](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml)
logs at `information` level, which doesn't show these lines):

```sh
docker compose exec -T clickhouse sh -c 'zgrep -h "Renaming it to" /var/log/clickhouse-server/clickhouse-server.log*'
```

`zgrep` also reads the rotated `.gz` files. The stock config keeps 10 of them,
so lines older than that are gone.

## Fix

Save the `DROP` generator from
[step 4 of the guide](../guide.md#step-4-drop-the-old-trace_log_0-copies) as
`drop-gen.sql`:

```sql
SELECT 'DROP TABLE system.' || name || ' SYNC SETTINGS max_table_size_to_drop = 0;'
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$');
```

Write the statements to a file, read it, then run it:

```sh
# Langfuse
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1' < drop-gen.sql > drops.sql
cat drops.sql
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery' < drops.sql
# SigNoz
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 < drop-gen.sql > drops.sql
cat drops.sql
docker exec -i signoz-clickhouse clickhouse-client --multiquery < drops.sql
```

Each line deletes one table with all its rows, so keep only the lines you
mean. Then run `copies.sql` again: it should return nothing.

Traps:

- **Keep `SYNC`.** The `system` database uses the Atomic engine. A `DROP` without `SYNC` only marks the table as dropped, and the data is deleted after [`database_atomic_delay_before_drop_table_sec`](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#database_atomic_delay_before_drop_table_sec) (480 s), 8 minutes later. `SELECT table FROM system.dropped_tables` lists the tables still waiting. `SYNC` deletes the data at once. It goes before `SETTINGS`: after `SETTINGS`, `SYNC` is a syntax error (Code 62). On a full disk, that is what gets the space back now ([Code 243 page](clickhouse-not-enough-space.md)).
- **Big copies need the setting.** A copy over the default limit of 50 GB fails without `SETTINGS max_table_size_to_drop = 0`, with Code 359 ([Code 359 page](clickhouse-max-table-size-to-drop.md)). The query setting needs ClickHouse 23.12 or newer ([PR #57452](https://github.com/ClickHouse/ClickHouse/pull/57452)).
- **On 26.7 and newer, a new copy without a TTL is read-only.** When 26.7 or newer makes a copy of a plain `MergeTree` log that has no TTL, it sets `table_readonly` on it ([PR #95079](https://github.com/ClickHouse/ClickHouse/pull/95079)). On 26.9 the copy's `engine_full` then ends with `table_readonly = true`. Copies with a TTL, `ReplicatedMergeTree` copies and copies made by an older version stay writable. On a read-only copy, the fixes suggested in [snuba #7311](https://github.com/getsentry/snuba/issues/7311), `ALTER TABLE system.trace_log_3 MODIFY TTL ...` or `TRUNCATE`, fail with the error below (26.9.1.1629). `DROP` still works. To keep the table instead, `ALTER TABLE system.query_log_0 MODIFY SETTING table_readonly = 0` turns this off ([docs](https://clickhouse.com/docs/reference/settings/merge-tree-settings/table#table_readonly)).

  ```text
  Code: 774. DB::Exception: Received from localhost:9000. DB::Exception: Table is in readonly mode. (TABLE_IS_PERMANENTLY_READ_ONLY)
  ```

- **`ALTER TABLE ... MODIFY TTL` on a live log makes a copy at the next restart.** Don't run `ALTER TABLE system.query_log MODIFY TTL event_date + INTERVAL 7 DAY`. It works until the restart. Then the table differs from the config, so ClickHouse renames it to `query_log_0`, with your TTL, and creates a new `query_log` from the config, without it. An `ALTER` that matches the config TTL exactly makes no copy. Put TTLs in `config.d` ([guide, step 2](../guide.md#step-2-add-a-ttl-file-in-configd)).
- **Truncate before you add a TTL.** The copy takes every row the table had at the restart. After a `TRUNCATE` ([guide, section 2](../guide.md#2-how-do-i-free-the-disk-space-right-now)) it is tiny.
- **Upgrades make new copies.** In our test, moving one volume from 25.12 to 26.9 turned all 22 system logs into `_0` copies. Run `copies.sql` after every upgrade ([guide, section 6](../guide.md#6-upgrading-clickhouse-check-this-first)).
- **Config changes skip the copies.** A TTL or storage policy in the config applies to the current table only; a copy keeps what it had ([ClickHouse #81068](https://github.com/ClickHouse/ClickHouse/issues/81068)). Drop the copies; don't manage them.
- **Keep the TTL file mounted.** A file you put into the container with `docker cp` or `docker exec` is gone when compose recreates the container, for example at `docker compose up -d` after `docker compose pull`. The next start then sees a log without a TTL in the config: the table with the TTL becomes a copy, and the new table has no TTL. Mount the file as in the [guide, step 2](../guide.md#step-2-add-a-ttl-file-in-configd).
- **Kubernetes: every pod has its own copies.** Each ClickHouse pod has its own system logs, so run `copies.sql` and the drops in each pod. After a `helm upgrade` that changes the image or the TTL, the next pod restart can make new copies. Which pod and container each chart runs, and how it restarts: [Kubernetes recipe](../recipes/kubernetes.md).

## Why it happens

In general ClickHouse can't apply such changes to an existing table, and some,
like the partitioning, can't be changed at all (a ClickHouse contributor in
[#93778](https://github.com/ClickHouse/ClickHouse/issues/93778)). The
[docs](https://clickhouse.com/docs/reference/system-tables/overview) describe
the rename for schema changes in a new release. The code does the same for
any difference from the config
([`SystemLog.cpp`](https://github.com/ClickHouse/ClickHouse/blob/v26.9.1.1629-stable/src/Interpreters/SystemLog.cpp),
`prepareTable`, 26.9). The number is the first free one: `trace_log_3` means
`_0` to `_2` existed when it was made. Since 26.8, the opt-in `all_...` tables
(`create_union_system_log_tables` with `merge_rotated_tables`) also read the
copies, so a drop removes their rows from those tables too.

This is why people report that a TTL in `config.d` works only on new tables
([Langfuse #13123](https://github.com/langfuse/langfuse/issues/13123),
[lmnr #2176](https://github.com/lmnr-ai/lmnr/issues/2176)). It does work: the
table ClickHouse creates has the TTL. The old rows stay behind in `_N`.

Public cases:

- [snuba #7311](https://github.com/getsentry/snuba/issues/7311) and [ClickHouse #84639](https://github.com/ClickHouse/ClickHouse/issues/84639): TTLs set in the Helm config for `query_log`, `trace_log` and others, and then `trace_log_3` is huge.
- [ClickHouse #81068](https://github.com/ClickHouse/ClickHouse/issues/81068) (25.4): `text_log_2` 70.16 GiB, `processors_profile_log_1` 30.60 GiB, `query_log_0` 20.09 GiB, `part_log_1` 17.05 GiB, while the current `text_log`, `query_log` and `part_log` were under 20 MiB each.
- [ClickHouse #93778](https://github.com/ClickHouse/ClickHouse/issues/93778) (24.5): after `ALTER TABLE system.query_log ... MODIFY TTL`, the `_0` copies had the TTL and the new tables didn't. Six copies held 67.87 GiB, `processors_profile_log_0` alone 24.85 GiB.
- [SigNoz #12050](https://github.com/SigNoz/signoz/issues/12050) (25.5): `trace_log_0` among more than 80 GB of system logs, next to less than 500 MB of telemetry.
- [langfuse-k8s #333](https://github.com/langfuse/langfuse-k8s/issues/333): 115 MiB in `trace_log_0` alone, and system tables 20 times the size of the Langfuse data. The workaround there, a daily `ALTER TABLE ... MODIFY TTL` job, makes a new copy at each restart after it runs.
- [ClickStack Helm chart PR #275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275): its upgrade note warns that the new TTL leaves the old rows in `system.<table>_0`.

## Tested on

Stock `clickhouse/clickhouse-server` images 24.8.14.39, 25.5.11.15,
25.12.11.4 and 26.9.1.1629.

- On all four: a TTL in `config.d` and a restart make `_0`, a restart with no
  change makes nothing, and a changed TTL makes `_1` with the old TTL.
  `ALTER ... MODIFY TTL` plus a restart moves the TTL into `query_log_0`, a
  second `ALTER` makes `query_log_1`, and the matching `ALTER` makes no copy.
  Truncating first leaves an empty copy. Also the log line, `copies.sql`, the
  generator, the plain and `SYNC` drops, `SYNC` after `SETTINGS` and
  `system.dropped_tables`.
- On 24.8, 25.12 and 26.9: a changed storage policy, and Code 359 with
  `max_table_size_to_drop = 1`. A busy log's copy appeared within 30 s of the
  restart without a flush; the copy of `backup_log`, which got no new rows,
  only at `SYSTEM FLUSH LOGS`.
- Only on 26.9: `table_readonly` on copies without a TTL, Code 774,
  `table_readonly = 0`, and a copy with a TTL staying writable. The 25.12 to
  26.9 upgrade, where a copy made by 25.12 stayed writable. A removed TTL file
  turning the tables with a TTL into `_1` copies. The `Old:` and `New:` lines
  (the 24.1, 24.8 and 25.12 source prints the same). `zgrep` after a real log
  rotation. `all_metric_log` with `merge_rotated_tables`.
- The compose commands and `diskvet.sh report --docker auto` (0.3.1) ran with
  Langfuse's ClickHouse service (25.12), and so did the `zgrep` command, with
  a gzipped old log file. The SigNoz commands ran on plain containers.

Not run: 23.12, 26.7, 26.8, a real SigNoz install, Kubernetes, a copy over
50 GB.

## Sources

- System tables overview (rename on schema change, unlimited growth): https://clickhouse.com/docs/reference/system-tables/overview
- `SystemLog.cpp` in 26.9 (the comparison, the `Old:` and `New:` lines, the first free `_N`, `table_readonly` only for non-replicated copies without a TTL): https://github.com/ClickHouse/ClickHouse/blob/v26.9.1.1629-stable/src/Interpreters/SystemLog.cpp
- `table_readonly` setting and PR #95079 (26.7): https://clickhouse.com/docs/reference/settings/merge-tree-settings/table#table_readonly, https://github.com/ClickHouse/ClickHouse/pull/95079
- Changelog (26.7 `table_readonly` for copies, 26.8 `create_union_system_log_tables`): https://github.com/ClickHouse/ClickHouse/blob/master/CHANGELOG.md
- DROP and `SYNC`, the Atomic engine, the drop delay: https://clickhouse.com/docs/reference/statements/drop, https://clickhouse.com/docs/reference/engines/database-engines/atomic, https://clickhouse.com/docs/reference/settings/server-settings/settings/other#database_atomic_delay_before_drop_table_sec
- `max_table_size_to_drop` as a query setting (23.12, PR #57452): https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop, https://github.com/ClickHouse/ClickHouse/pull/57452
- Cases: https://github.com/getsentry/snuba/issues/7311, https://github.com/ClickHouse/ClickHouse/issues/84639, https://github.com/ClickHouse/ClickHouse/issues/81068, https://github.com/ClickHouse/ClickHouse/issues/93778, https://github.com/SigNoz/signoz/issues/12050, https://github.com/langfuse/langfuse-k8s/issues/333, https://github.com/langfuse/langfuse/issues/13123, https://github.com/lmnr-ai/lmnr/issues/2176, https://github.com/ClickHouse/ClickStack-helm-charts/pull/275

## Check it with diskvet

[diskvet](https://github.com/Protemir/diskvet) is a free, open-source,
read-only script. Its report lists the `_N` copies with their sizes and prints
the `DROP` statements, with the flag for a copy over the drop limit. Read
`checks.sql` before you run it (SigNoz: `--docker signoz-clickhouse`):

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

---

ClickHouse is a registered trademark of ClickHouse, Inc. diskvet is not affiliated with ClickHouse, Inc.
