# ClickHouse® TTL not deleting old data, or DELETE not freeing disk
<!-- description: Rows are expired or deleted but ClickHouse® disk stays full. Why TTL and lightweight DELETE wait for merges, and how to force them. -->

You set a TTL or a retention period, or you ran `DELETE FROM`, but the disk
stays full. There is no error: ClickHouse® is waiting for a merge that may not
come soon.

## Short answer

ClickHouse frees disk only when it writes a part again without the rows, or
drops a whole part. Expired rows go at a TTL merge. After one TTL merge in a
partition, the next one there waits at least
[`merge_with_ttl_timeout`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout)
(14400 s, 4 hours), and until then `SELECT` still returns the expired rows. A
lightweight `DELETE` only marks rows as deleted. To free the space now, use
`MATERIALIZE TTL` for expired rows, `APPLY DELETED MASK` for deleted rows, or
`DROP PARTITION` for whole old partitions you don't need.

## Check

Open a client as in [section 1 of the guide](../guide.md#1-what-is-using-the-disk-check-clickhouse-disk-usage-by-table),
with `--readonly=1`. These queries read only `system` tables. On Kubernetes,
the pod and the login for each Helm chart are in the
[Kubernetes recipe](https://github.com/Protemir/diskvet/blob/main/docs/recipes/kubernetes.md#chart-by-chart).

**1. Which tables have a TTL?**

```sql
SELECT database, name,
       extract(engine_full, ' TTL (.+?)(?: SETTINGS |$)') AS ttl,
       extract(engine_full, 'ttl_only_drop_parts = (\\d)') AS ttl_only_drop_parts
FROM system.tables
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema') AND engine LIKE '%MergeTree'
ORDER BY total_bytes DESC LIMIT 20;
```

An empty `ttl` means the table has no table TTL (column TTLs don't show
here). An empty `ttl_only_drop_parts` means the table uses the server's value:
`SELECT value FROM system.merge_tree_settings WHERE name = 'ttl_only_drop_parts'`.
Langfuse's retention doesn't use a TTL: it removes old rows with `DELETE`
(check 3).

The query leaves out `system`. If you gave a `system.*_log` table a TTL and
the disk is still full, look for `*_log_N` copies: they keep the old rows and
usually have no TTL ([system log copies](clickhouse-system-log-copies.md)).

**2. Did the parts get their expiry dates?**

```sql
SELECT database, table, partition_id, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       min(delete_ttl_info_min) AS oldest_expiry,
       max(delete_ttl_info_max) AS newest_expiry
FROM system.parts
WHERE active AND database != 'system'
GROUP BY database, table, partition_id
ORDER BY sum(bytes_on_disk) DESC LIMIT 30;
```

- `1970-01-01 00:00:00`: the parts have no expiry date. Tables without a TTL show this too. In a table that has a TTL, the TTL was never calculated for these parts, so no TTL merge picks them. You get this after adding a TTL with `MODIFY TTL ... SETTINGS materialize_ttl_after_modify = 0`.
- `oldest_expiry` in the past: some rows have expired and wait for a TTL merge.
- `newest_expiry` in the past: every row in the partition has expired. 25.12 and 26.9 dropped such a part within a minute; 24.8 can wait up to 4 hours after an earlier TTL merge in the partition. If it stays longer, see [ClickHouse bugs](#clickhouse-bugs-that-keep-expired-parts).
- Expiry dates later than the new TTL would give: the parts still carry the old TTL. `MODIFY TTL` with `materialize_ttl_after_modify = 0` doesn't recalculate them. In the tests, a 365-day TTL changed to 7 days this way kept the 2027 expiry dates, and all 200,000 rows stayed, about 176,000 of them older than 7 days.

**3. Rows removed with DELETE** (the same query as in the guide):

```sql
SELECT database, table, partition_id, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active AND has_lightweight_delete
GROUP BY database, table, partition_id
ORDER BY sum(bytes_on_disk) DESC;
```

**4. Parts too big to merge, and free space**

```sql
SELECT database, table, partition_id, name, formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE active
  AND bytes_on_disk > (SELECT toUInt64(value) FROM system.merge_tree_settings
                       WHERE name = 'max_bytes_to_merge_at_max_space_in_pool')
ORDER BY bytes_on_disk DESC;

SELECT name, formatReadableSize(free_space) AS free, formatReadableSize(unreserved_space) AS unreserved FROM system.disks;
```

Background merges skip parts over
[`max_bytes_to_merge_at_max_space_in_pool`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool)
(150 GiB). Since 25.1, so do TTL merges that delete rows. With the limit set
to 1 MB on a test table, 25.12 and 26.9 left an
18.5 MiB part with expired rows alone. 24.8 still ran a TTL merge on it: it
takes the part with the oldest expiry whatever its size
([`TTLMergeSelector.cpp` in 24.8](https://github.com/ClickHouse/ClickHouse/blob/v24.8.14.39-lts/src/Storages/MergeTree/TTLMergeSelector.cpp)).
A merge starts only if unreserved space is at least twice the size
of its parts; a mutation needs about 1.1 times the size of the part
([`CompactionStatistics.cpp`](https://github.com/ClickHouse/ClickHouse/blob/master/src/Storages/MergeTree/Compaction/CompactionStatistics.cpp)).

**5. Stuck mutations**

```sql
SELECT database, table, mutation_id, command, create_time, parts_to_do, latest_fail_reason
FROM system.mutations WHERE NOT is_done;
```

A mutation with `parts_to_do` above 0 and an empty `latest_fail_reason` may
be waiting for free space. The server log
(`/var/log/clickhouse-server/clickhouse-server.log`, at the default `trace`
level) then has `Will not mutate part ... yet`. In the tests the mutation
started by itself once there was room.

## Fix

Use a client with write access ([guide, section 2](../guide.md#2-how-do-i-free-the-disk-space-right-now)).
Take the partition ids from checks 2 and 3, and run check 5 before the next partition.

### Expired rows: MATERIALIZE TTL

```sql
ALTER TABLE <db>.<table> MATERIALIZE TTL IN PARTITION ID '202608';
```

On a test table (200,000 rows over 60 days, a 7-day TTL added with
`materialize_ttl_after_modify = 0`) it left 23,338 rows, and 38.31 MiB became
4.47 MiB (on 24.8, 38.68 MiB became 4.51 MiB).

- It is a mutation: it rewrites the parts and needs free space of about 1.1 times each part, or it waits (check 5). The 150 GiB merge limit doesn't apply to it: with the limit set to 1 MB, it rewrote the 18.5 MiB part that TTL merges had skipped.
- The old parts stay on disk for [`old_parts_lifetime`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime) (480 s), so `df` shows the space 8 minutes or more later. The same goes for `APPLY DELETED MASK` and `OPTIMIZE` below.
- `MODIFY TTL` does this to the whole table by itself. With the default [`materialize_ttl_after_modify`](https://clickhouse.com/docs/reference/settings/session-settings/materialize#materialize_ttl_after_modify) = 1 it starts a `MATERIALIZE TTL` mutation that rewrites every part, even when no row has expired: on a test table with a 365-day TTL, it read every column of the part and removed no rows. On a nearly full disk, run `MODIFY TTL ... SETTINGS materialize_ttl_after_modify = 0`, then `MATERIALIZE TTL` partition by partition.
- A lighter option: run `ALTER TABLE <db>.<table> MODIFY SETTING materialize_ttl_recalculate_only = 1` first. `MATERIALIZE TTL` then only fills in the expiry dates, and background TTL merges remove the rows later, with all their limits. The setting stays on the table until `ALTER TABLE <db>.<table> RESET SETTING materialize_ttl_recalculate_only`.
- On a table with `ttl_only_drop_parts = 1`, 24.10 and newer do the same by themselves: `MATERIALIZE TTL` reads only the columns the TTL needs, drops the parts where every row has expired, and leaves the expired rows in the other parts ([PR #65488](https://github.com/ClickHouse/ClickHouse/pull/65488)). On the monthly test table [below](#tables-partitioned-by-day-ttl_only_drop_parts), 25.12 and 26.9 kept all 96,677 rows of September; `OPTIMIZE ... FINAL` removed the expired ones. 24.8 removed them with `MATERIALIZE TTL`.

### Deleted rows: APPLY DELETED MASK

```sql
ALTER TABLE <db>.<table> APPLY DELETED MASK IN PARTITION ID '202605';
```

On the same test table, a `DELETE` of 90% of the rows left about 20,000 rows in
`count()`, but the size grew from 38.31 MiB to 38.37 MiB. `APPLY DELETED MASK`
brought it down to about 3.8 MiB.

- It is a heavyweight mutation, the same as `ALTER TABLE ... DELETE WHERE _row_exists = 0` ([docs](https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask)). It rewrites the parts, so it needs free space and loads the disk. In [Langfuse discussion #13969](https://github.com/orgs/langfuse/discussions/13969) it freed about 360 GiB per replica in about 17 minutes.
- Partition ids that start with `patch-` in check 3 come from `lightweight_delete_mode = 'lightweight_update'`. Check 3 then shows only the small patch parts, not the space: under 200 KiB for a 10 MiB partition in the tests. Run the command with the plain id, everything after `patch-<hash>-`: `202605` for `patch-…-202605`, as Langfuse's cleaner does, and `202605-1` for `patch-…-202605-1` with a tuple partition key. With the full `patch-` id it ran without an error and removed nothing, even after three runs. With `202605` it took two runs: the first only wrote the mask into the parts, and the size stayed the same; the second removed the rows. The small `patch-` parts left check 3 a few minutes later.
- `OPTIMIZE TABLE <db>.<table> PARTITION ID '<id>' FINAL` removes expired and deleted rows too, but it merges the whole partition into one part. In the tests it also removed expired rows from parts with `1970-01-01` expiry dates and from a table with `ttl_only_drop_parts = 1`. It needs unreserved space of twice the partition. Without that, `OPTIMIZE` returns OK and does nothing ([docs](https://clickhouse.com/docs/reference/statements/optimize)). Add `SETTINGS optimize_throw_if_noop = 1` to see why: `Code: 388 ... (CANNOT_ASSIGN_OPTIMIZE)` with the space it needs.

### Whole old partitions: DROP PARTITION

```sql
ALTER TABLE <db>.<table> DROP PARTITION ID '202604';
```

Nothing is rewritten, so it needs almost no free space, but on a disk at 100%
it fails too, with `Code: 243` ([not enough space](clickhouse-not-enough-space.md)).
It deletes every row of the partition and can't be undone. A partition over
50 GB fails with `Code: 359`
([guide](../guide.md#truncate-fails-with-code-359-tables-over-50-gb)): add
`SETTINGS max_partition_size_to_drop = 0`.

### Tables partitioned by day: ttl_only_drop_parts

```sql
ALTER TABLE <db>.<table> MODIFY SETTING ttl_only_drop_parts = 1;
```

With [`ttl_only_drop_parts`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#ttl_only_drop_parts)
= 1 (default 0), TTL merges drop a part once all its rows have expired and no
longer rewrite parts to delete rows. It removes no more than the default does:
it saves the rewrites and the free space they need. It fits daily partitions.
On a monthly test table with a 7-day TTL, the August part went within
seconds, but all 96,677 rows of September stayed, 73,339 of them expired.

## Langfuse, SigNoz and ClickStack

- **Langfuse** partitions `traces`, `observations`, `scores`, `events_full` and `events_core` by month and removes old rows with `DELETE`. At high ingest, parts reach 150 GiB and are not merged again: in #13969 a May partition of about 802 GiB was about 85% deleted rows. Since v3.179.0 the worker has a cleaner, off by default: `LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` ([PR #14035](https://github.com/langfuse/langfuse/pull/14035)). Its query picks only `patch-*` partitions, except the current month's ([`helpers.ts`](https://github.com/langfuse/langfuse/blob/v3.225.11/worker/src/features/deleted-mask-cleaner/helpers.ts#L40-L56)). With the default `CLICKHOUSE_LIGHTWEIGHT_DELETE_MODE=alter_update`, a `DELETE` writes no patch parts, so the cleaner finds nothing; v3's tables have neither the `_block_number` nor the `_block_offset` column that patch parts need ([requirements](https://clickhouse.com/docs/reference/statements/update#lightweight-update-requirements)), so `lightweight_update` falls back to a mutation there too. Run `APPLY DELETED MASK` yourself. `DROP PARTITION` of an old month is fine only if no project keeps data that long (the cleaner's author in #13969).
- **SigNoz** partitions its logs, traces and metrics tables by day, most of them with `ttl_only_drop_parts = 1`. Change retention on the Settings page, Workspace tab, and don't change the TTL of SigNoz tables by hand. A new retention applies only to newly ingested data ([SigNoz docs](https://signoz.io/docs/userguide/retention-period/)): SigNoz runs `MODIFY TTL` with `materialize_ttl_after_modify=0`, and logs keep their retention in a `_retention_days` column. Old data leaves on the old schedule. In [SigNoz #9553](https://github.com/SigNoz/signoz/issues/9553) the UI showed the new value while the TTL stayed at 30 days, so run check 1 after a change.
- **ClickStack** also partitions by day with `ttl_only_drop_parts = 1`, and keeps 3 days by default. Its [TTL docs](https://clickhouse.com/docs/clickstack/managing/ttl) change retention with `MODIFY TTL`. On a test table like that (daily partitions, `ttl_only_drop_parts = 1`, one row TTL), the `MATERIALIZE TTL` it starts read only the TTL column on 25.12 and 26.9, and every column on 24.8 ([PR #65488](https://github.com/ClickHouse/ClickHouse/pull/65488), in 24.10 and newer). With `SETTINGS materialize_ttl_after_modify = 0`, old parts keep the old TTL.

## ClickHouse bugs that keep expired parts

- **Fully expired parts over 150 GiB.** Since 25.1, TTL didn't drop such a part, and the parts after it in the partition stayed too ([#80681](https://github.com/ClickHouse/ClickHouse/issues/80681), reported on 25.3). Fixed by [PR #86439](https://github.com/ClickHouse/ClickHouse/pull/86439): in 25.9 and newer, and in 25.8 LTS from 25.8.12.129. The 25.3 cherry-pick was closed without merging. With the limit set to 1 MB, 25.8.5 kept a fully expired 20 MiB part, and 24.8, 25.12 and 26.9 dropped it. Until you upgrade, use `MATERIALIZE TTL` or `DROP PARTITION`: on 25.8.5, `MATERIALIZE TTL IN PARTITION ID` emptied that part.
- **Volumes with `prefer_not_to_merge`**, such as a cold volume. Since 25.1, TTL didn't drop expired parts there ([#85636](https://github.com/ClickHouse/ClickHouse/issues/85636), [SigNoz charts #820](https://github.com/SigNoz/charts/issues/820)). [PR #90059](https://github.com/ClickHouse/ClickHouse/pull/90059) drops whole expired parts there again; it is in 25.12.1.649 and newer, with no backport found. TTL merges that delete rows skip such volumes by design, in 24.8 and in the [current source](https://github.com/ClickHouse/ClickHouse/blob/master/src/Storages/MergeTree/Compaction/MergeSelectors/TTLMergeSelector.cpp), so there the expired rows of a part that isn't fully expired stay. SigNoz's Helm chart moved to ClickHouse 25.12.5 in June 2026 ([charts PR #887](https://github.com/SigNoz/charts/pull/887)); older installs ran 25.5.6.

## Why it happens

Parts on disk never change. To remove rows, ClickHouse writes a new part
without them, or drops a part whose rows have all expired. "Data with an
expired TTL is removed when ClickHouse merges data parts"
([docs](https://clickhouse.com/docs/reference/engines/table-engines/mergetree-family/mergetree#mergetree-removing-expired-data)).
A lightweight `DELETE` writes a hidden `_row_exists` mask and leaves the rows
in place until the next merge ([docs](https://clickhouse.com/docs/reference/statements/delete)).
Old partitions get no writes and are rarely merged, and parts over 150 GiB are
skipped, so in a table partitioned by month the space may never come back by
itself.

*Tested on stock `clickhouse/clickhouse-server` 24.8.14.39, 25.12.11.4 and
26.9.1.1629, and 25.8.5.17 for the fully expired part over the merge limit,
one server, no replication (the `patch-` case on 25.12 and 26.9 only). The
free-space cases (`OPTIMIZE`, the waiting mutation, `DROP PARTITION` at 100%)
ran with the data folder on a 320 MiB tmpfs. Not tested on Langfuse, SigNoz or
ClickStack installs.*

## Sources

- TTL, lightweight DELETE, APPLY DELETED MASK, MODIFY TTL, DROP PARTITION, OPTIMIZE, system.parts, system.mutations: https://clickhouse.com/docs/reference/engines/table-engines/mergetree-family/mergetree#mergetree-removing-expired-data, https://clickhouse.com/docs/reference/statements/delete, https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask, https://clickhouse.com/docs/reference/statements/alter/ttl, https://clickhouse.com/docs/reference/statements/alter/partition#drop-partitionpart, https://clickhouse.com/docs/reference/statements/optimize, https://clickhouse.com/docs/reference/system-tables/parts, https://clickhouse.com/docs/reference/system-tables/mutations
- MergeTree settings: https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout, https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#ttl_only_drop_parts, https://clickhouse.com/docs/reference/settings/merge-tree-settings/materialize#materialize_ttl_recalculate_only, https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool
- Query settings: https://clickhouse.com/docs/reference/settings/session-settings/materialize#materialize_ttl_after_modify, https://clickhouse.com/docs/reference/settings/session-settings/lightweight#lightweight_delete_mode, https://clickhouse.com/docs/reference/settings/session-settings/max#max_partition_size_to_drop, https://clickhouse.com/docs/reference/settings/session-settings/optimize#optimize_throw_if_noop
- Lightweight updates (the `patch-` parts) need the `_block_number` and `_block_offset` columns: https://clickhouse.com/docs/reference/statements/update#lightweight-update-requirements
- Source code: https://github.com/ClickHouse/ClickHouse/blob/master/src/Storages/MergeTree/Compaction/MergeSelectorApplier.cpp, https://github.com/ClickHouse/ClickHouse/blob/master/src/Storages/MergeTree/Compaction/MergeSelectors/TTLMergeSelector.cpp, https://github.com/ClickHouse/ClickHouse/blob/master/src/Storages/MergeTree/Compaction/CompactionStatistics.cpp, https://github.com/ClickHouse/ClickHouse/blob/master/src/Storages/MergeTree/MergeTreeDataMergerMutator.cpp, https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/MutationsInterpreter.cpp, and in 24.8 (TTL drops wait for the timer, a TTL merge always takes its first part): https://github.com/ClickHouse/ClickHouse/blob/v24.8.14.39-lts/src/Storages/MergeTree/MergeTreeDataMergerMutator.cpp, https://github.com/ClickHouse/ClickHouse/blob/v24.8.14.39-lts/src/Storages/MergeTree/TTLMergeSelector.cpp
- ClickHouse PR #65488 (`MATERIALIZE TTL` with `ttl_only_drop_parts`): https://github.com/ClickHouse/ClickHouse/pull/65488
- ClickHouse #80681, PR #86439, 25.8 backport PR #89708, 25.3 cherry-pick #89706: https://github.com/ClickHouse/ClickHouse/issues/80681, https://github.com/ClickHouse/ClickHouse/pull/86439, https://github.com/ClickHouse/ClickHouse/pull/89708, https://github.com/ClickHouse/ClickHouse/pull/89706
- ClickHouse #85636, PR #90059, SigNoz charts #820, PR #887: https://github.com/ClickHouse/ClickHouse/issues/85636, https://github.com/ClickHouse/ClickHouse/pull/90059, https://github.com/SigNoz/charts/issues/820, https://github.com/SigNoz/charts/pull/887
- ClickHouse #48928 (deleted rows stay until a merge) and the ClickStack TTL docs: https://github.com/ClickHouse/ClickHouse/issues/48928, https://clickhouse.com/docs/clickstack/managing/ttl
- Langfuse discussion #13969, PR #14035, the cleaner's tables and query, the delete mode default: https://github.com/orgs/langfuse/discussions/13969, https://github.com/langfuse/langfuse/pull/14035, https://github.com/langfuse/langfuse/blob/v3.225.11/worker/src/features/deleted-mask-cleaner/helpers.ts#L40-L56, https://github.com/langfuse/langfuse/blob/v3.225.11/packages/shared/src/env.ts#L135-L137
- SigNoz retention docs, #9553, `reader.go`, logs, traces and metrics schemas: https://signoz.io/docs/userguide/retention-period/, https://github.com/SigNoz/signoz/issues/9553, https://github.com/SigNoz/signoz/blob/main/pkg/query-service/app/clickhouseReader/reader.go, https://github.com/SigNoz/signoz-otel-collector/blob/main/cmd/signozschemamigrator/schema_migrator/v2_squashed_logs_migration.go, https://github.com/SigNoz/signoz-otel-collector/blob/main/cmd/signozschemamigrator/schema_migrator/squashed_traces_migrations.go, https://github.com/SigNoz/signoz-otel-collector/blob/main/cmd/signozschemamigrator/schema_migrator/squashed_metrics_migrations.go

More on deleted rows in Langfuse: [the guide](../guide.md#why-do-deleted-rows-still-take-space).
[diskvet](https://github.com/Protemir/diskvet) is a free, open-source, read-only script. Its check 7
lists partitions with deleted rows and unfinished mutations, and prints `APPLY DELETED MASK` where they are 10% of a table or more.
In `lightweight_update` mode it counts the parts the `patch-` parts apply to, and prints the command twice with the plain id.
Read `checks.sql` before you run it (`--docker auto` finds SigNoz's ClickHouse too):

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

---

ClickHouse is a registered trademark of ClickHouse, Inc. diskvet is not affiliated with ClickHouse, Inc.
