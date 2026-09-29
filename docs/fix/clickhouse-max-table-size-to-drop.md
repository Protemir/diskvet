# ClickHouse® Code 359: Table or Partition was not dropped (max_table_size_to_drop, 50 GB)
<!-- description: TRUNCATE or DROP over 50 GB fails with Code 359 TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT. Lift the limit for one statement or use the force_drop_table flag. -->

You run `TRUNCATE`, `DROP TABLE` or `ALTER TABLE ... DROP PARTITION`, and
ClickHouse® refuses:

```text
Received exception from server (version 25.12.11):
Code: 359. DB::Exception: Received from localhost:9000. DB::Exception: Table or Partition in default.t was not dropped.
Reason:
1. Size (368.00 B) is greater than max_[table/partition]_size_to_drop (1.00 B)
2. File '/var/lib/clickhouse/flags/force_drop_table' intended to force DROP doesn't exist
How to fix this:
1. Either increase (or set to zero) max_[table/partition]_size_to_drop in server config
2. Either pass a bigger (or set to zero) max_[table/partition]_size_to_drop through query settings
3. Either create forcing file /var/lib/clickhouse/flags/force_drop_table and make sure that ClickHouse has write permission for it.
Example:
sudo touch '/var/lib/clickhouse/flags/force_drop_table' && sudo chmod 666 '/var/lib/clickhouse/flags/force_drop_table'. (TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT)
(query: TRUNCATE TABLE t)
```

This is `TRUNCATE TABLE t` on ClickHouse 25.12.11, a test server with both
limits set to 1 byte. 24.1.2, 24.8.14 and 26.9.1 print the same text; only the
version and the size differ. On a real server, the `1. Size` line shows your
size against the default, for example
`Size (113.41 GB) is greater than max_[table/partition]_size_to_drop (50.00 GB)`
([ClickHouse #72967](https://github.com/ClickHouse/ClickHouse/issues/72967)).
If your error lists only two ways to fix it, without "through query
settings", your server is older than 23.12: use the flag (Fix B).

## Short answer

ClickHouse won't `DROP`, `TRUNCATE` or `DROP PARTITION` anything bigger than
`max_table_size_to_drop` (tables) or `max_partition_size_to_drop`
(partitions). Both default to 50,000,000,000 bytes: 50 GB, about 46.57 GiB.
Add the setting to that one statement:

```sql
TRUNCATE TABLE system.text_log SETTINGS max_table_size_to_drop = 0;
```

For `DROP PARTITION`, the setting is `max_partition_size_to_drop`.

## Check

Which limits does your server use, and what is over them? Save this as
`drop-limit.sql`:

```sql
SELECT name, value FROM system.server_settings
WHERE name IN ('max_table_size_to_drop', 'max_partition_size_to_drop');

WITH (SELECT toUInt64(value) FROM system.server_settings
      WHERE name = 'max_table_size_to_drop') AS lim
SELECT database, table, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active
GROUP BY database, table
HAVING lim > 0 AND sum(bytes_on_disk) > lim
ORDER BY sum(bytes_on_disk) DESC;

WITH (SELECT toUInt64(value) FROM system.server_settings
      WHERE name = 'max_partition_size_to_drop') AS lim
SELECT database, table, partition_id, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active
GROUP BY database, table, partition_id
HAVING lim > 0 AND sum(bytes_on_disk) > lim
ORDER BY sum(bytes_on_disk) DESC LIMIT 20;
```

Run it read-only, as `size.sql` in the
[guide](../guide.md#1-what-is-using-the-disk-check-clickhouse-disk-usage-by-table),
plus `--multiquery` (the 24.1 client needs it for a file with several queries):

```sh
# Langfuse
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --multiquery --format PrettyCompact' < drop-limit.sql
# SigNoz
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --multiquery --format PrettyCompact < drop-limit.sql
```

A `value` of `0` means no limit. If only the first table prints, nothing is
over it: the client prints nothing for an empty result. The size that counts
is the sum of `bytes_on_disk` of the active parts
([MergeTreeData.cpp](https://github.com/ClickHouse/ClickHouse/blob/master/src/Storages/MergeTree/MergeTreeData.cpp)).
The error prints it in decimal units (GB), `formatReadableSize` in binary ones
(GiB): a table shown as 47 GiB is already over 50 GB.

## Fix

Open a client with write access ([guide, section 2](../guide.md#2-how-do-i-free-the-disk-space-right-now)).

### Fix A: lift the limit for one statement

```sql
TRUNCATE TABLE system.text_log SETTINGS max_table_size_to_drop = 0;
DROP TABLE system.text_log_2 SYNC SETTINGS max_table_size_to_drop = 0;
ALTER TABLE system.trace_log DROP PARTITION ID '202605' SETTINGS max_partition_size_to_drop = 0;
```

These are three examples; run only the one you need. Each one deletes data:
`TRUNCATE` deletes all rows, `DROP TABLE` the whole table, `DROP PARTITION`
one partition. If you drop a live system log such as `system.text_log`,
ClickHouse creates it again, empty, at the next log flush; a `_2` copy stays
gone.

- **Partitions have their own setting.** `DROP PARTITION ... SETTINGS max_table_size_to_drop = 0` still fails with Code 359.
- **Take the partition from the check.** `PARTITION ID` takes the `partition_id` column as printed. System logs are partitioned by month by default (`toYYYYMM(event_date)`), so `202605` is May 2026.
- **`DROP TABLE` needs `SYNC` to free the space now.** The `system` database is Atomic: after a plain `DROP` the data stays on disk for [`database_atomic_delay_before_drop_table_sec`](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#database_atomic_delay_before_drop_table_sec) (480 s), and `system.dropped_tables` lists the table until then. Put `SYNC` before `SETTINGS`: after it, `SYNC` is a syntax error (Code 62). In our tests `TRUNCATE` and `DROP PARTITION` freed the space at once.
- **Only this statement.** The query setting replaces the server value for the statement it is on ([docs](https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop)). `SET max_table_size_to_drop = 0` works too, but then every later `DROP TABLE` and `TRUNCATE` in that session runs without the guard.
- **ClickHouse 23.12 and newer.** The query setting came with [PR #57452](https://github.com/ClickHouse/ClickHouse/pull/57452). We didn't run 23.12; 24.1.2 and newer work. On older servers, use Fix B.

### Fix B: the one-time flag file

Create the flag, then run the plain statement:

```sh
docker compose exec clickhouse sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```

```sql
TRUNCATE TABLE system.text_log;
```

(SigNoz: `docker exec signoz-clickhouse sh -c '...'` with the same command.)
The path is the one in the stock image. The `2. File` line of your error shows
the flag path your server uses: the `flags` folder in its data path
([Server.cpp](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/Server.cpp)).

Traps:

- **One flag, one big table.** ClickHouse deletes the flag when the first `DROP`, `TRUNCATE` or `DROP PARTITION` over the limit uses it ([`checkCanBeDropped`](https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/Context.cpp)). The next big table fails again, so create the flag before each one. [SigNoz #10819](https://github.com/SigNoz/signoz/issues/10819) creates it once and then truncates seven logs: if two of them are over the limit, the second one fails.
- **It works on any table.** The flag lets the next big drop through, whichever table it is. Smaller statements leave it in place, so it can wait for days. Run only the statement you mean, and remove a flag you didn't use:

  ```sh
  docker compose exec clickhouse rm -f /var/lib/clickhouse/flags/force_drop_table
  ```

- **A failed statement uses it up too.** On a full disk, `TRUNCATE` deletes the flag and then fails with Code 243 (seen on all four versions under Tested on).
- **Kubernetes** (not run): `kubectl exec -n NAMESPACE POD -c CONTAINER -- sh -c 'touch FLAG && chmod 666 FLAG'`, with `FLAG` the path from the `2. File` line. Not every chart keeps the data in `/var/lib/clickhouse`: the Bitnami-based Langfuse chart keeps it under `/bitnami/clickhouse`. Each ClickHouse pod has its own system logs (plain `MergeTree` tables by default, not replicated) and its own flag, so check and clean each pod; the Langfuse chart 1.x runs 3. Which pod and container each Helm chart runs: [Kubernetes recipe](../recipes/kubernetes.md). Fix A needs no file in the pod, so it is simpler there.

### Don't raise the limit in the server config

`<max_table_size_to_drop>0</max_table_size_to_drop>` in `config.d` works
without a restart
([docs](https://clickhouse.com/docs/reference/settings/server-settings/settings/max-table#max_table_size_to_drop)).
But then no table on the server is protected, your own data included, until
you undo it. For a one-time cleanup, use Fix A.

### Disk already 100% full?

The plain `TRUNCATE` of a big table still fails with Code 359 first. With
`SETTINGS max_table_size_to_drop = 0` it then fails with Code 243
(`NOT_ENOUGH_SPACE`), and so does `DROP PARTITION`. `DROP TABLE ... SYNC
SETTINGS max_table_size_to_drop = 0` worked and freed the space at once (seen
on all four versions under Tested on). What still works and what to drop: the
[Code 243 page](clickhouse-not-enough-space.md).

## Why it happens

The limit is there to stop an accidental `DROP` of a big table (the comment on
the default in `Context.cpp`). Your own tables rarely need a `TRUNCATE`.
ClickHouse's own logs do: by default `trace_log` and `text_log` have no TTL,
and on a busy server they can pass 50 GB. Public cases:

- [Langfuse discussion #15024](https://github.com/orgs/langfuse/discussions/15024): `text_log` was 59.20 GiB.
- [Langfuse #13123](https://github.com/langfuse/langfuse/issues/13123): `trace_log` was 66.86 GiB. A cleanup script in the comments there runs `SET max_table_size_to_drop = 0` before its `TRUNCATE`s.
- [Opik #6224](https://github.com/comet-ml/opik/issues/6224): `trace_log` was 66.42 GiB.
- [ClickStack Helm chart #191](https://github.com/ClickHouse/ClickStack-helm-charts/issues/191): `trace_log` reached ~97 GB and filled a 108 GB volume.
- [ClickHouse #81068](https://github.com/ClickHouse/ClickHouse/issues/81068): `text_log_2`, an old copy of `text_log`, was 70.16 GiB. Dropping a copy over the limit needs the same setting ([system log copies](clickhouse-system-log-copies.md)).

After the cleanup, add a TTL so the logs don't grow back:
[trace_log page](clickhouse-trace-log-huge.md) and
[guide, section 4](../guide.md#4-how-do-i-set-a-ttl-on-clickhouse-system-logs).

## Tested on

ClickHouse 24.1.2.5, 24.8.14.39, 25.12.11.4 and 26.9.1.1629 (stock
`clickhouse/clickhouse-server` images), with both limits set to 1 byte in
`config.d`. On all four:

- `TRUNCATE`, `DROP PARTITION` and `DROP TABLE` fail with Code 359, and so
  does `DROP PARTITION ... SETTINGS max_table_size_to_drop = 0`.
- Fix A, `SET` and the flag work. The flag is gone after one big drop and
  stays after a drop under the limit.
- `system.server_settings` shows the 50,000,000,000 default for both limits.
- A `config.d` file with `0` works without a restart.
- `drop-limit.sql` runs with the commands above.
- The full disk (a 150 MB tmpfs) gives the results in the section above.
- `system` is an Atomic database. After a plain `DROP TABLE` of a system log
  copy, its folder stays and `system.dropped_tables` lists it.
  `DROP TABLE ... SYNC SETTINGS max_table_size_to_drop = 0` removes the folder
  at once, and `... SETTINGS max_table_size_to_drop = 0 SYNC` fails with
  Code 62.
- `DROP PARTITION ID` with `max_partition_size_to_drop = 0` works.

On 24.1 and 26.9, a 60 MB table in two partitions went down to 30 MB right
after `DROP PARTITION ID` and to under 100 KB right after `TRUNCATE`. On 24.8,
25.12 and 26.9, the system logs are `MergeTree` tables partitioned by
`toYYYYMM(event_date)`, and a `system.query_log` dropped with `SYNC` was back
after `SYSTEM FLUSH LOGS`.

The `docker compose` commands ran on 26.9, in a compose service `clickhouse`
set up like Langfuse's (`user: "101:101"`, `CLICKHOUSE_USER`,
`CLICKHOUSE_PASSWORD`). The SigNoz `docker exec` commands ran with our own
container name. On 24.8, 25.12 and 26.9 the Fix A block ran as written, as one
file with `--multiquery`, and so did Fix B. `text_log_2` was made with
`RENAME TABLE`, and `DROP PARTITION ID` also ran on 202609, the one partition
with data. 24.1.2 has no `system.text_log` by default (it is commented out in
its `config.xml`), so there the `text_log` statements fail with Code 60
(`UNKNOWN_TABLE`).

Not run: 23.12, Kubernetes, a real 50 GB table.

## Sources

- Server settings `max_table_size_to_drop` (with `force_drop_table`) and `max_partition_size_to_drop`: https://clickhouse.com/docs/reference/settings/server-settings/settings/max-table#max_table_size_to_drop, https://clickhouse.com/docs/reference/settings/server-settings/settings/max#max_partition_size_to_drop
- Both as query settings (they replace the server value): https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop
- Query-level override, merged for 23.12: https://github.com/ClickHouse/ClickHouse/pull/57452 (request: https://github.com/ClickHouse/ClickHouse/issues/44715; 23.12 changelog: https://github.com/ClickHouse/ClickHouse/blob/master/docs/changelogs/archive/v23.12.1.1368-stable.md)
- The check, the error text and the flag removal (`checkCanBeDropped`): https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/Context.cpp
- The size that counts (active parts) and the query setting: https://github.com/ClickHouse/ClickHouse/blob/master/src/Storages/MergeTree/MergeTreeData.cpp
- TRUNCATE and DROP PARTITION: https://clickhouse.com/docs/reference/statements/truncate, https://clickhouse.com/docs/reference/statements/alter/partition
- DROP and `SYNC` ("dropped without delay"), and the delay itself: https://clickhouse.com/docs/reference/statements/drop, https://clickhouse.com/docs/reference/settings/server-settings/settings/other#database_atomic_delay_before_drop_table_sec
- The `flags` folder in the data path: https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/Server.cpp
- Error texts: with 113.41 GB https://github.com/ClickHouse/ClickHouse/issues/72967, an old one with two ways to fix it https://github.com/ClickHouse/ClickHouse/issues/9802

## Check it with diskvet

[diskvet](https://github.com/Protemir/diskvet) is a free, open-source,
read-only script. Its report prints the `TRUNCATE` and `DROP` commands for your
big logs. For a table over or near the limit it adds the flag command, with the
data path your server reports, and on 24.1 and newer the
`SETTINGS max_table_size_to_drop = 0` form. Read `checks.sql` before you run it
(SigNoz: `--docker signoz-clickhouse`):

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

The short version is in the
[guide](../guide.md#truncate-fails-with-code-359-tables-over-50-gb).

---

ClickHouse is a registered trademark of ClickHouse, Inc. diskvet is not affiliated with ClickHouse, Inc.
