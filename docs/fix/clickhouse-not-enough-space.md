# ClickHouse® Code 243: Cannot reserve 1.00 MiB, not enough space
<!-- description: ClickHouse says Cannot reserve 1.00 MiB, not enough space (NOT_ENOUGH_SPACE). At 100% even TRUNCATE fails. What still works and how to free space. -->

Every insert into ClickHouse® fails with this error:

```text
Code: 243. DB::Exception: Received from localhost:9000. DB::Exception: Cannot reserve 1.00 MiB, not enough space. (NOT_ENOUGH_SPACE)
```

With async inserts the message ends in `: While executing WaitForAsyncInsert`.
The Langfuse worker logs it that way. So does a plain `INSERT ... VALUES` on
ClickHouse 26.2 and newer, where `async_insert` is on by default
([settings history](https://github.com/ClickHouse/ClickHouse/blob/v26.9.1.1629-stable/src/Core/SettingsChangesHistory.cpp#L505)).
`INSERT ... SELECT` is not async, so its message ends as above, also on 26.9.

## Short answer

The disk or Kubernetes volume with ClickHouse's data is full, and ClickHouse
refuses every write. At 100% even `TRUNCATE` fails with the same error.
`DROP TABLE ... SYNC` still works and gives the space back at once. If
ClickHouse's own log tables are what's big (they usually are, `system.trace_log`
first), drop the biggest ones, then add a TTL so they don't fill up again.

## What still works on a full disk

| Statement | With `df` at 100% |
|---|---|
| `SELECT` | works |
| `INSERT`, `TRUNCATE TABLE` (also on `system.query_log`), `ALTER TABLE ... DROP PARTITION` | fail with Code 243 |
| `DROP TABLE` | succeeds, but frees nothing for about 8 minutes |
| `DROP TABLE ... SYNC` | succeeds and frees the space at once |

A plain `DROP TABLE` in an Atomic database (the default) only marks the table
as dropped. The data goes after `database_atomic_delay_before_drop_table_sec`,
480 seconds by default (`table_dropped_time` in `system.dropped_tables`
shows when). `SYNC` skips the wait.

## Check

How full is the disk? In the folder with Langfuse's `docker-compose.yml`:

```sh
docker compose exec clickhouse df -h /var/lib/clickhouse /var/log/clickhouse-server
```

SigNoz: `docker exec signoz-clickhouse df -h /var/lib/clickhouse`. On
Kubernetes each ClickHouse pod has its own volume and its own system logs, so
run the checks and the fix in the pod whose volume is full
([two kinds of "disk full"](../recipes/kubernetes.md#two-kinds-of-disk-full)).

What does ClickHouse see? Save this as `disks.sql`:

```sql
SELECT name, path, formatReadableSize(free_space) AS free,
       formatReadableSize(unreserved_space) AS unreserved,
       formatReadableSize(keep_free_space) AS keep_free
FROM system.disks;
SELECT formatReadableSize(sum(bytes_on_disk)) AS all_parts FROM system.parts;
```

Run it read-only, the same way as `size.sql` in
[section 1 of the guide](../guide.md#1-what-is-using-the-disk-check-clickhouse-disk-usage-by-table):

```sh
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < disks.sql
```

`unreserved` is the free space minus what running inserts and merges have
reserved. `free` and `unreserved` already leave out `keep_free`. An insert
needs at least 1 MiB unreserved, a big one about its own size: 10,000 rows of
1,000 bytes gave `Cannot reserve 9.61 MiB` (9.62 MiB on 24.8). Then run
`size.sql` to see what is big.

## Fix

### ClickHouse's own logs are big

In the write-access client from [section 2 of the guide](../guide.md#2-how-do-i-free-the-disk-space-right-now),
drop the biggest log:

```sql
DROP TABLE system.trace_log SYNC SETTINGS max_table_size_to_drop = 0;
```

- This deletes only ClickHouse's diagnostics, not your traces. It can't be undone. ClickHouse creates the table again, empty, at its next log flush.
- Don't leave out `SYNC`: without it the space comes back only after about 8 minutes. Keep `SYNC` before `SETTINGS`: the other order fails with a syntax error (Code 62).
- `max_table_size_to_drop = 0` lifts the 50 GB drop limit for this one statement (ClickHouse 23.12+; [Code 359 page](clickhouse-max-table-size-to-drop.md)).
- Do the same for `text_log` or any other big `system` log from `size.sql`, old copies like `trace_log_0` included ([system log copies](clickhouse-system-log-copies.md)). Once there is room again, the guide's `TRUNCATE` works too.
- The logs start growing again right away. Once there is room, add a TTL as in [section 4 of the guide](../guide.md#4-how-do-i-set-a-ttl-on-clickhouse-system-logs). A TTL alone won't get you out of a full disk: ClickHouse deletes expired rows during merges ([guide, step 5](../guide.md#step-5-check-the-result)), and a merge reserves space first.

### The space is outside the tables

`df` shows much more used than `all_parts`?

- **Rotated server logs.** ClickHouse renames old log files to `clickhouse-server.log.0.gz`, `.1.gz` and so on. It doesn't need them, and rotation goes on after you delete them. They fill the data disk only if `/var/log/clickhouse-server` is on it: compare the two lines of `df` above. Delete them with `docker compose exec clickhouse sh -c 'rm /var/log/clickhouse-server/*.gz'`, then make the logs smaller ([ClickHouse's own log files](../guide.md#are-clickhouses-own-log-files-big)).
- **Docker's container logs** are on the host, under `/var/lib/docker/containers`. Docker keeps named volumes (Langfuse's compose uses them) under `/var/lib/docker` too, so these logs usually fill the same disk: [Docker container logs](../guide.md#are-docker-container-logs-filling-the-disk).
- **Anything else on the host.** With a named volume, `df` in the container shows the file system that holds `/var/lib/docker`. Images, other volumes and files outside Docker count too. `docker system df` shows Docker's part.
- **Other folders in the data directory.** `docker compose exec clickhouse sh -c 'du -sh /var/lib/clickhouse/*'` shows which one is big. `tmp/` holds temporary files of running queries (see below). `store/` also holds tables dropped without `SYNC` until their `table_dropped_time`, and detached parts until you remove them ([old parts stuck on disk](../guide.md#are-old-parts-stuck-on-disk-inactive-and-detached-parts)). `all_parts` counts neither.

### Your own data is big

Grow the disk. On Kubernetes, see
[more room on the volume](../recipes/kubernetes.md#more-room-on-the-volume).
Rows removed by a lightweight `DELETE` take space until their parts are
rewritten ([deleted rows](../guide.md#why-do-deleted-rows-still-take-space)).
Don't delete folders under `/var/lib/clickhouse/store` by hand: ClickHouse
still counts on those files. Once there is room, remove data with SQL.

### Keep a reserve for next time

`keep_free_space_bytes` makes ClickHouse stop writing while some space is
still free. Save this as `clickhouse-reserve.xml`:

```xml
<clickhouse>
    <storage_configuration><disks><default>
        <keep_free_space_bytes>1073741824</keep_free_space_bytes>
    </default></disks></storage_configuration>
</clickhouse>
```

Mount it into `config.d` and restart ClickHouse like the TTL file (guide
section 4, steps 2 and 3). On Kubernetes, put it where your chart takes the
TTL file (XML or YAML, depending on the chart:
[Kubernetes recipe](../recipes/kubernetes.md#charts-at-a-glance)), so that a
pod restart or a `helm upgrade` keeps it.

Code 243 then comes while 1 GiB is still free. Inserts and `TRUNCATE` fail,
but `DROP TABLE ... SYNC` still works, so you can drop the big logs with the
reserve in place. If you need `TRUNCATE` or other writes to clean up, set the
value to `0` and run `SYSTEM RELOAD CONFIG` (no restart). When `disks.sql`
shows `keep_free` as `0.00 B`, free the space, then put the value back and
reload again. If `keep_free` still shows the old value, restart ClickHouse
(`docker compose restart clickhouse`).

## Same error, bigger number

Merges and mutations reserve space for the new part before they write it, so
you can see `Cannot reserve 145.10 GiB, not enough space`
([discussion #45154](https://github.com/ClickHouse/ClickHouse/discussions/45154))
or `Not enough space for mutating part`
([#48392](https://github.com/ClickHouse/ClickHouse/issues/48392)) while `df`
still shows free space. In the [source](https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/src/Storages/MergeTree/Compaction/CompactionStatistics.cpp#L29-L36),
a merge starts only if unreserved space is at least twice the size of its
source parts, and it reserves 1.1 times that size. A mutation, such as
`APPLY DELETED MASK` or `MATERIALIZE TTL`, needs 1.1 times the part. So a
100 GiB merge waits for 200 GiB of unreserved space.

## "No space left on device" instead

When the OS itself refuses a write, you get errno 28 instead of Code 243.
`clickhouse-client` on 26.9 printed this for an insert (25.12 prints the same
lines):

```text
Code: 75. DB::Exception: Received from localhost:9000. DB::ErrnoException. DB::ErrnoException: Cannot write to file /var/lib/clickhouse/store/029/029b54a8-e639-4b20-b8be-ffee49035daf/tmp_insert_all_1_1_0/s.bin: , errno: 28, strerror: No space left on device
Total space: 150.00 MiB
Available space: 84.05 MiB
Total inodes: 2.03 million
Available inodes: 2.03 million
Mount point: /var/lib/clickhouse
Filesystem: tmpfs. (CANNOT_WRITE_TO_FILE_DESCRIPTOR)
```

`Available space` isn't 0: it matched `df` right after the error, when
ClickHouse had already removed the half-written part. A `CREATE TABLE` on a
disk with 0 bytes free fails the same way, on `format_version.txt` (24.8, 25.12
and 26.9).

Reservations count only ClickHouse's planned writes. In the test for this page,
another process (`dd`) filled the disk during the insert. Temporary files of
big queries in `/var/lib/clickhouse/tmp` can do it too
([#17744](https://github.com/ClickHouse/ClickHouse/issues/17744), a join that
spilled to disk). Check `df -h` and `df -i`: without free inodes you get errno
28 with free space left
([#6252](https://github.com/ClickHouse/ClickHouse/issues/6252): inserts failed
with 75% of the disk free, most likely because the inodes had run out). If even
`docker exec` fails with
`OCI runtime exec failed: write /tmp/runc-process...: no space left on device`
([Plausible CE #256](https://github.com/plausible/community-edition/issues/256),
not reproduced here), the host's disk is full. Free space on the host first.

## What it does to the apps

- **Langfuse.** The worker logs `Cannot reserve 1.00 MiB, not enough space: While executing WaitForAsyncInsert` ([#17862](https://github.com/langfuse/langfuse/issues/17862), [OnRamp #268](https://github.com/OnRamp-2026/onramp-api/issues/268)). In OnRamp #268 the 8 Gi PVC was full and no new traces arrived for more than 23 hours; the worker called it a `non-retryable error`. The #17862 reporter saw the worker drop records after its retries ran out.
- **Laminar.** In a comment on [lmnr #2176](https://github.com/lmnr-ai/lmnr/issues/2176), `TRUNCATE TABLE system.trace_log` failed at 100%, and they had to grow the PVC and restart the pod before any cleanup could run. Ingestion had been dead for six weeks: the consumer kept retrying, the SDK got success and every pod stayed `Running`.
- **Opik.** In [#6224](https://github.com/comet-ml/opik/issues/6224) Redis on the same disk went read-only, and span ingestion returned HTTP 500.
- **ClickStack.** In [ClickStack-helm-charts #191](https://github.com/ClickHouse/ClickStack-helm-charts/issues/191) a ~97 GB `trace_log` filled a 108 GB PVC, and the user tables ended up with 125+ broken parts.

## Why it happens

Before ClickHouse writes a new part (an insert, a merge or a mutation), it
reserves disk space for it: at least 1 MiB
([`RESERVATION_MIN_ESTIMATION_SIZE`](https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/src/Storages/MergeTree/MergeTreeData.cpp#L178)).
If less than that is unreserved after `keep_free_space_bytes`, the write fails
with Code 243. On self-hosted Langfuse, SigNoz and ClickStack the space usually
goes to ClickHouse's own logs, which have no size limit by default
([section 3 of the guide](../guide.md#3-why-are-trace_log-and-text_log-so-big)).

## Tested on

Stock `clickhouse/clickhouse-server` images 24.8.14.39, 25.12.11.4 and
26.9.1.1629 (Docker 29.3.0 on Docker Desktop for Windows, Compose 5.1.0). The
compose service `clickhouse` was set up like Langfuse's (`user: "101:101"`,
`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, a logs volume), with the data folder
on a 150 MiB tmpfs.

- On all three: the Code 243 text and the table above; `disks.sql`; the `DROP ... SYNC` fix, and Code 62 with `SYNC` after `SETTINGS`; the guide's `TRUNCATE` once there was room; `table_dropped_time` 480 seconds after a plain `DROP`; the `du` line; a dropped and a detached table left out of `all_parts` but still in `store/`; errno 28 from `CREATE TABLE`.
- The reserve file, on all three: `keep_free` 1.00 GiB; inserts and `TRUNCATE` failed with Code 243 while `df` showed over 100 MiB free; `DROP ... SYNC` worked; `SYSTEM RELOAD CONFIG` switched the value both ways; `docker compose restart clickhouse` picked up a change to `0`.
- The 8-minute wait was timed on 26.9: a 143 MiB table left `df` about 480 seconds after its `DROP`.
- Errno 28 from an insert: 25.12 and 26.9 (on 24.8 our `dd` run didn't hit it).
- Only on 26.9: the `WaitForAsyncInsert` ending for `INSERT ... VALUES`; Code 243 with a 50 MiB reserve and 51 MiB free; log rotation (with `<size>1M</size>`) and the `rm` line; diskvet 0.3.1.
- The SigNoz `docker exec` line ran with our own container name. `docker system df` ran on the same host.
- Not run: 23.12 and 26.2 (those versions come from the linked source), Kubernetes, a real Langfuse, SigNoz or ClickStack install, a full host disk, the reserve on a Linux host.

## Sources

- DROP and `SYNC`: https://clickhouse.com/docs/reference/statements/drop
- Atomic database, delayed deletion: https://clickhouse.com/docs/engines/database-engines/atomic
- `database_atomic_delay_before_drop_table_sec` (480): https://clickhouse.com/docs/reference/settings/server-settings/settings/other#database_atomic_delay_before_drop_table_sec
- system.dropped_tables: https://clickhouse.com/docs/reference/system-tables/dropped_tables
- system.disks: https://clickhouse.com/docs/reference/system-tables/disks
- `keep_free_space_bytes`: https://clickhouse.com/docs/engines/table-engines/mergetree-family/mergetree#table_engine-mergetree-multiple-volumes
- `max_table_size_to_drop`: https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop
- Query-level `max_table_size_to_drop` since 23.12: https://github.com/ClickHouse/ClickHouse/pull/57452
- `async_insert` on by default since 26.2: https://github.com/ClickHouse/ClickHouse/blob/v26.9.1.1629-stable/src/Core/SettingsChangesHistory.cpp#L505
- Minimum reservation, error text: https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/src/Storages/MergeTree/MergeTreeData.cpp
- Merge and mutation coefficients: https://github.com/ClickHouse/ClickHouse/blob/v25.12.11.4-stable/src/Storages/MergeTree/Compaction/CompactionStatistics.cpp

## Check it with diskvet

[diskvet](https://github.com/Protemir/diskvet) is a free, open-source,
read-only script. It shows the free space on ClickHouse's disk, a rough
forecast of when it fills up, and how much of the disk is outside ClickHouse's
parts. Download it as in [section 7 of the guide](../guide.md#7-check-everything-at-once)
and run it once:

```sh
sh diskvet.sh report --docker auto > report.md
```

---

ClickHouse is a registered trademark of ClickHouse, Inc. diskvet is not affiliated with ClickHouse, Inc.
