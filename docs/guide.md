# Why ClickHouse® fills the disk in self-hosted Langfuse and SigNoz, and how to fix it

*Also in [Spanish](es/guide.md), [Portuguese](pt/guide.md), [Russian](ru/guide.md), [Japanese](ja/guide.md), [Korean](ko/guide.md) and [Chinese](zh/guide.md).*

Your Langfuse or SigNoz server is running out of disk, but your traces are
small. In most public reports the space goes to ClickHouse® itself: to its own
log tables, such as `system.trace_log` and `system.text_log`, which have no
size limit by default. ClickStack has the same problem.

This guide shows how to confirm it with one read-only query, free the space
now, and stop it from coming back without hitting the known traps. You don't
need any extra tools.

*Tested on stock `clickhouse/clickhouse-server` images 24.8, 25.12 and 26.9
(the SigNoz commands on 25.5 and 25.12), with the ClickHouse service and
config taken from Langfuse's and SigNoz's compose files.*

## TL;DR

1. **Check.** Run one read-only query on `system.parts`. If `system.*_log` tables are bigger than your data, ClickHouse's own logs are the problem.
2. **Free space now.** `TRUNCATE` the big logs. For a table over 50 GB, add `SETTINGS max_table_size_to_drop = 0`.
3. **Stop it coming back.** Add a `config.d` file with a TTL for each log (for `opentelemetry_span_log` the TTL goes inside `<engine>`), then restart ClickHouse.
4. **Clean up.** Drop the `*_log_0`, `*_log_1` copies that the restart leaves behind.
5. **Still full?** Check Docker's container logs, deleted rows and stuck parts. On Langfuse, update Langfuse before you move ClickHouse to 26.8+.

## 1. What is using the disk? Check ClickHouse disk usage by table

Save this query as `size.sql`. It lists the biggest tables by size on disk:

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

**Langfuse (docker compose).** Run this in the folder with Langfuse's
`docker-compose.yml`. Its compose file already sets `CLICKHOUSE_USER` and
`CLICKHOUSE_PASSWORD` inside the container:

```sh
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < size.sql
```

**SigNoz (docker compose).** The container is usually called
`signoz-clickhouse` (check with `docker ps`). SigNoz's `users.xml` leaves the
`default` user without a password:

```sh
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --format PrettyCompact < size.sql
```

`--readonly=1` makes the session read-only: ClickHouse refuses any change.

**How to read it.** Compare the `system` rows with your own data (`default`
for Langfuse, `signoz_*` for SigNoz). If `system.trace_log` or
`system.text_log` is at the top, go on to section 2.

## 2. How do I free the disk space right now?

Open a client with write access:

```sh
# Langfuse
docker compose exec clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'
# SigNoz
docker exec -it signoz-clickhouse clickhouse-client
```

Empty the big logs:

```sql
TRUNCATE TABLE system.trace_log;
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.metric_log;
TRUNCATE TABLE system.query_log;
```

This deletes only ClickHouse's own diagnostics, not your traces, and needs no
restart.

Langfuse reads `system.query_log` to follow some of its own queries
([#13123](https://github.com/langfuse/langfuse/issues/13123)). So empty it,
but don't switch it off.

### TRUNCATE fails with Code 359? Tables over 50 GB

ClickHouse won't drop or truncate a table bigger than
`max_table_size_to_drop` (default 50,000,000,000 bytes, about 46.6 GiB). The
limit applies to `TRUNCATE` too, and a bigger table fails with
`Code: 359 ... (TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT)`.

Big logs do hit it: the `text_log` in
[Langfuse discussion #15024](https://github.com/orgs/langfuse/discussions/15024)
was 59.20 GiB. There are two ways around it.

**Option A.** Lift the limit for one statement:

```sql
-- ClickHouse 23.12+: lift the limit for this one statement
TRUNCATE TABLE system.text_log SETTINGS max_table_size_to_drop = 0;
```

**Option B.** Create the one-time flag file, then run the plain `TRUNCATE`:

```sh
docker compose exec clickhouse sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```

(SigNoz: `docker exec signoz-clickhouse sh -c '...'` with the same command.)
ClickHouse deletes the flag after the first `DROP` or `TRUNCATE` that needs it,
so create it again before the next big table.

The space is back now, but the logs start growing again right away. Section 4
stops that. Section 3 explains why it happens.

## 3. Why are trace_log and text_log so big?

ClickHouse writes its own diagnostics into tables in the `system` database:
`query_log`, `trace_log`, `text_log`, `metric_log` and more. The
[documentation](https://clickhouse.com/docs/reference/system-tables/overview)
says it plainly: "By default, table growth is unlimited."

Recent [default configs](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml)
set a TTL only for a few small logs (since 25.9, `processors_profile_log` keeps 30 days),
not for the big ones. Two defaults make the big ones grow fast:

- the query profiler is on and writes stack samples of running queries into `trace_log`;
- `text_log` stores the server log at `trace` level.

Public examples:

- **Langfuse [#13123](https://github.com/langfuse/langfuse/issues/13123):** `system.trace_log` was 66.86 GiB, while the Langfuse tables listed there (`traces`, `observations`, `scores`) took about 51 MiB together. The maintainers decided not to override ClickHouse's defaults and added a [FAQ page](https://langfuse.com/faq/all/reduce-clickhouse-disk-size) instead.
- **SigNoz [#12050](https://github.com/SigNoz/signoz/issues/12050):** more than 80 GB of system logs (including a `trace_log_0` copy) next to less than 500 MB of telemetry. Truncating the `system.*` tables freed about 80 GB. SigNoz's new Foundry installer sets TTLs; older docker compose installs don't have them.
- **ClickStack Helm chart [PR #275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275):** a 10 Gi volume hit 100% after 10 days, with 5.2 GB of trace-level server logs and a 3.7 GB `system.text_log` against ~70 MB of telemetry. The PR, merged in September 2026, adds a 7-day TTL.

## 4. How do I set a TTL on ClickHouse system logs?

A TTL makes ClickHouse delete old log rows by itself. Set it **after** the
`TRUNCATE` from section 2, because of how ClickHouse applies it.

When you add a TTL and restart, ClickHouse doesn't shrink the old table. It
renames it to `trace_log_0` with all its rows and creates a new one with the
TTL. If you truncated first, these copies are tiny, and step 4 drops them.

Run the SQL below in the same write-access client as in section 2.

### Step 1: which logs have no TTL?

```sql
SELECT name,
       formatReadableSize(total_bytes) AS size,
       extract(engine_full, 'TTL [^S]*') AS ttl
FROM system.tables
WHERE database = 'system' AND engine LIKE '%MergeTree' AND match(name, '_log(_[0-9]+)?$')
ORDER BY total_bytes DESC;
```

An empty `ttl` means the log is kept forever. Names like `trace_log_0` are old
copies; step 4 removes them.

### Step 2: add a TTL file in config.d

Save this as `clickhouse-ttl.xml` next to `docker-compose.yml`:

```xml
<clickhouse>
    <!-- Keep 7 days of ClickHouse's own logs. List only logs your server has. -->
    <query_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_log>
    <trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
    <text_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></text_log>
    <metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></metric_log>
    <asynchronous_metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></asynchronous_metric_log>
    <part_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></part_log>

    <!-- The stock config defines this log with <engine>, so a separate <ttl>
         stops the server from starting (ClickHouse#88366). TTL goes inside. -->
    <opentelemetry_span_log>
        <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
    </opentelemetry_span_log>
</clickhouse>
```

Mount it into the `clickhouse` service (keep your existing volume lines):

```yaml
  clickhouse:
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

Three traps in this step:

- **`opentelemetry_span_log` takes its TTL inside `<engine>`.** The stock config defines this log with `<engine>`, and per the [docs](https://clickhouse.com/docs/reference/system-tables/overview) that conflicts with `<ttl>`. The server then exits with `If 'engine' is specified for system table, TTL parameters should be specified directly inside 'engine'` ([ClickHouse #88366](https://github.com/ClickHouse/ClickHouse/issues/88366)). Copy `PARTITION BY` and `ORDER BY` from `SELECT engine_full FROM system.tables WHERE database = 'system' AND name = 'opentelemetry_span_log'` (SigNoz's config also sorts by `trace_id`). Or switch the log off with `<opentelemetry_span_log remove="1"/>` (Langfuse's [scaling docs](https://langfuse.com/self-hosting/configuration/scaling)). `remove` doesn't delete the existing table, so drop it yourself.
- **List only the logs your server has.** A section in the config is what turns a log on (the stock `config.xml` disables `session_log` by commenting it out). SigNoz's own [`config.xml`](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml) doesn't enable `text_log`, so delete that line there. Also add `processors_profile_log`, which has no TTL in that file.
- **Profile settings go into users.d, not config.d.** If you also turn off the query profiler (`query_profiler_real_time_period_ns` and `query_profiler_cpu_time_period_ns` = 0, as in Langfuse's scaling docs), put that `<profiles>` block into `users.d/`. In `config.d/` it is silently ignored ([trigger.dev #4343](https://github.com/triggerdotdev/trigger.dev/issues/4343)).

### Step 3: restart ClickHouse

The TTL from `config.d` takes effect only when the server restarts
([Altinity KB](https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/)).
A config reload is not enough. With compose:

```sh
docker compose up -d clickhouse     # recreates the container with the new mount
docker compose ps clickhouse
```

If ClickHouse keeps restarting, the reason is in its error log inside the
container. `docker compose logs` may not show it:

```sh
docker cp "$(docker compose ps -aq clickhouse)":/var/log/clickhouse-server/clickhouse-server.err.log .
tail -n 20 clickhouse-server.err.log
```

### Step 4: drop the old trace_log_0 copies

After the restart, every changed log has a copy like `trace_log_0` (then `_1`,
`_2` after later changes). The copy keeps all the old rows and has no TTL
(ClickStack PR #275 upgrade note,
[Sentry snuba #7311](https://github.com/getsentry/snuba/issues/7311)).

This query writes the `DROP` statements for you. Read them, then paste them
into the client:

```sql
SELECT 'DROP TABLE system.' || name || ' SETTINGS max_table_size_to_drop = 0;'
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$');
```

ClickHouse no longer writes to these tables. `DROP` can't be undone.

### Step 5: check the result

Run the step 1 query again. Every big log should show a TTL, and no `_N` names
should be left.

ClickHouse removes expired rows during merges, by default at most every 4
hours ([`merge_with_ttl_timeout`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout)),
so the size shrinks over the next hours.

A script can do the checking for you:
[diskvet](https://github.com/Protemir/diskvet) runs the step 1 check read-only
and prints the `TRUNCATE` commands, the TTL file and the `DROP` list for your
tables, with the flag for tables over the drop limit (see section 7).

## 5. Disk still full? Where else the space goes

Compare `df -h` with the total size of all parts
(`SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts`). If the
disk holds much more than that, the space is outside ClickHouse's tables.

### Are Docker container logs filling the disk?

Docker's default `json-file` log driver has no size limit (`max-size` defaults
to `-1`, see the [Docker docs](https://docs.docker.com/engine/logging/drivers/json-file/)).
In [Langfuse #16339](https://github.com/langfuse/langfuse/issues/16339) the
ClickHouse container's log reached 89.1 GiB and filled a 244 GiB root disk.

Find the biggest ones:

```sh
sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'
docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'   # the folder name is the container ID
```

To fix it, add a `logging:` block to every service in `docker-compose.yml`.
In #16339 the Langfuse maintainers recommended doing it for all containers,
not only ClickHouse. SigNoz's [compose file](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml)
already sets `50m` × 3.

```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

Then run `docker compose up -d --force-recreate`: log options apply only to
newly created containers. Recreating also removes the old log file; in #16339
that freed 81 GiB.

Two notes:

- If your Docker daemon uses another logging driver, set retention there instead, because `driver: json-file` overrides it.
- Langfuse's README ([PR #16363](https://github.com/langfuse/langfuse/pull/16363)) describes the daemon-wide way: set `max-size` and `max-file` as daemon defaults, then restart Docker and recreate the containers. It also advises against truncating or rotating these files with external tools.

### Are ClickHouse's own log files big?

ClickHouse also writes plain log files to `/var/log/clickhouse-server` (a
volume in Langfuse's compose). By default they are at `trace` level, rotated at
1000M, with up to 10 old files kept
([`logger` docs](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger)).

ClickStack PR #275 uses the values below. Save them as another `config.d`
file, mount it like the TTL file and restart ClickHouse (section 4, step 3):

```xml
<clickhouse>
    <logger><level>information</level><size>100M</size><count>10</count></logger>
</clickhouse>
```

### Why do deleted rows still take space?

Langfuse's data retention removes old rows with a
[lightweight `DELETE`](https://clickhouse.com/docs/reference/statements/delete).
ClickHouse only marks such rows; the space comes back when the part is merged.

Background merges skip parts over
[`max_bytes_to_merge_at_max_space_in_pool`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool)
(150 GiB), and old monthly partitions are rarely merged. In
[Langfuse discussion #13969](https://github.com/orgs/langfuse/discussions/13969)
a May partition of ~802 GiB was ~85% deleted rows.

Find the partitions with deleted rows:

```sql
SELECT database, table, partition_id, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active AND has_lightweight_delete
GROUP BY database, table, partition_id
ORDER BY sum(bytes_on_disk) DESC;
```

Then apply the delete mask, one partition at a time
([APPLY DELETED MASK](https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask)):

```sql
ALTER TABLE default.observations APPLY DELETED MASK IN PARTITION ID '202605';
```

**Careful:** this is a heavyweight mutation. It rewrites the affected parts, so
it needs free space for the new copies and loads the disk. Run it off-peak and
watch it with `SELECT * FROM system.mutations WHERE NOT is_done`. In #13969 it
freed ~360 GiB per replica in ~17 minutes.

Since v3.179.0 the Langfuse worker can do this on a schedule:
`LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` (off by default; see
`.env.prod.example`, [PR #14035](https://github.com/langfuse/langfuse/pull/14035)).

### Are old parts stuck on disk? (inactive and detached parts)

```sql
SELECT database, table, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       min(remove_time) AS oldest, max(refcount) AS max_refcount
FROM system.parts
WHERE NOT active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;
```

Inactive parts are left over from merges. ClickHouse deletes them after
[`old_parts_lifetime`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime)
(480 s), once no query uses them (`refcount` = 1).

If they pile up (112.55 GiB of them in Langfuse discussion #15024) and `oldest`
is hours ago, look for long queries in `system.processes` and stop them with
`KILL QUERY WHERE query_id = '...'`.

Detached parts stay on disk until you remove them:

```sql
SELECT database, table, reason, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.detached_parts
GROUP BY database, table, reason;
```

Check `reason` first. Remove a part with
`ALTER TABLE <db>.<table> DROP DETACHED PART '<name>' SETTINGS allow_drop_detached = 1`,
not by deleting folders.

## 6. Upgrading ClickHouse? Check this first

- **Langfuse + ClickHouse 26.8 or newer: update Langfuse first.** ClickHouse 26.8 changed the default of `input_format_read_datetime_number_as_raw_value` from 1 to 0. Older Langfuse sends `DateTime64` values as millisecond numbers, and on 26.8+ they end up stored as `9999-12-31 23:59:59` ([Langfuse #16858](https://github.com/langfuse/langfuse/issues/16858): 0.59% to 21.43% of writes per project). The fix is [PR #16892](https://github.com/langfuse/langfuse/pull/16892) (backported to v3 in [PR #16957](https://github.com/langfuse/langfuse/pull/16957)), released in Langfuse v4.28.0 and v3.225.7. Langfuse partitions by month, so such rows land in partition `999912`. Check your version and look for them:

  ```sql
  SELECT version();
  SELECT database, table, partition_id, count() AS parts
  FROM system.parts
  WHERE active AND startsWith(partition_id, '9999')
  GROUP BY database, table, partition_id;
  ```

- **After any upgrade, run the step 1 query from section 4 again.** When a release changes a log's schema, ClickHouse renames the current table and creates a new one, so new `_N` copies appear. Drop them as in step 4.

## 7. Check everything at once

[diskvet](https://github.com/Protemir/diskvet) is an open-source (Apache-2.0)
read-only script that runs most of the checks above and prints a report with
the fix commands. It can't see Docker's log files, but it shows how much of the
disk is outside ClickHouse's parts.

On the machine with Langfuse's `docker-compose.yml` (read `checks.sql` before
you run it):

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

For SigNoz, use `--docker signoz-clickhouse`.

It reads only metadata from `system.*` tables (`system.tables`,
`system.parts`, `system.disks`, `system.detached_parts`, `system.mutations`,
`system.part_log` and a few more), with `readonly=2` and resource limits. It
never reads rows of your tables, `system.query_log` or query texts, and sends
nothing anywhere. Nothing runs by itself: you read each fix and run it.

An hourly version that warns before the disk fills is coming (a free beta opens in
October 2026).

## Sources

ClickHouse documentation and source:

- System tables overview (unlimited growth, `<engine>` vs `<ttl>`, renaming on schema change): https://clickhouse.com/docs/reference/system-tables/overview
- Default `config.xml` (logs without TTL, `opentelemetry_span_log` engine, `text_log` and logger at `trace`, `session_log` commented out): https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml
- `max_table_size_to_drop`, server setting and `force_drop_table`: https://clickhouse.com/docs/reference/settings/server-settings/settings/max-table#max_table_size_to_drop
- `max_table_size_to_drop`, query setting: https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop
- Query-level override since 23.12: https://github.com/ClickHouse/ClickHouse/pull/57452
- The flag is removed after use (`checkCanBeDropped`): https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/Context.cpp
- TRUNCATE: https://clickhouse.com/docs/reference/statements/truncate
- `opentelemetry_span_log` TTL error: https://github.com/ClickHouse/ClickHouse/issues/88366
- MergeTree settings: `merge_with_ttl_timeout` (14400 s) https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout, `old_parts_lifetime` (480 s) https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime, `max_bytes_to_merge_at_max_space_in_pool` (150 GiB) https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool
- Server log rotation (`logger`: `level`, `size`, `count`): https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger
- Lightweight DELETE: https://clickhouse.com/docs/reference/statements/delete
- APPLY DELETED MASK: https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask
- system.parts: https://clickhouse.com/docs/reference/system-tables/parts
- system.detached_parts: https://clickhouse.com/docs/reference/system-tables/detached_parts
- DROP DETACHED PART: https://clickhouse.com/docs/reference/statements/alter/partition
- `allow_drop_detached`: https://clickhouse.com/docs/reference/settings/session-settings/allow#allow_drop_detached
- system.mutations: https://clickhouse.com/docs/reference/system-tables/mutations
- KILL QUERY: https://clickhouse.com/docs/reference/statements/kill
- Altinity KB, "System tables ate my disk" (restart needed): https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/

Docker:

- json-file logging driver (`max-size` defaults to -1; existing containers keep old settings): https://docs.docker.com/engine/logging/drivers/json-file/

Langfuse:

- FAQ, reduce ClickHouse disk size: https://langfuse.com/faq/all/reduce-clickhouse-disk-size
- Scaling docs, ClickHouse system log tables: https://langfuse.com/self-hosting/configuration/scaling
- #13123, system tables grow unbounded: https://github.com/langfuse/langfuse/issues/13123
- #16339, unbounded Docker log: https://github.com/langfuse/langfuse/issues/16339
- PR #16363, Docker log rotation in the README (daemon defaults, no external truncation): https://github.com/langfuse/langfuse/pull/16363
- Discussion #13969, lightweight-deleted rows: https://github.com/orgs/langfuse/discussions/13969
- Discussion #15024, inactive parts and 59 GiB text_log: https://github.com/orgs/langfuse/discussions/15024
- PR #14035, deleted-mask cleaner (released in v3.179.0): https://github.com/langfuse/langfuse/pull/14035, https://github.com/langfuse/langfuse/releases/tag/v3.179.0
- #16858, DateTime64 on ClickHouse 26.8+: https://github.com/langfuse/langfuse/issues/16858
- PR #16892 and v3 backport PR #16957: https://github.com/langfuse/langfuse/pull/16892, https://github.com/langfuse/langfuse/pull/16957
- Releases with the fix: https://github.com/langfuse/langfuse/releases/tag/v4.28.0, https://github.com/langfuse/langfuse/releases/tag/v3.225.7

SigNoz, ClickStack and others:

- SigNoz #12050, 80+ GB of system logs: https://github.com/SigNoz/signoz/issues/12050
- SigNoz v0.129.0 ClickHouse `config.xml` and `users.xml`: https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml, https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/users.xml
- SigNoz v0.129.0 `docker-compose.yaml` (container `signoz-clickhouse`, `max-size: 50m`, `max-file: "3"`): https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml
- ClickStack Helm chart PR #275: https://github.com/ClickHouse/ClickStack-helm-charts/pull/275
- Sentry snuba #7311, `*_log_N` copies without TTL: https://github.com/getsentry/snuba/issues/7311
- trigger.dev #4343, profile settings in config.d ignored: https://github.com/triggerdotdev/trigger.dev/issues/4343

---

ClickHouse is a registered trademark of ClickHouse, Inc. diskvet is not affiliated with ClickHouse, Inc.
Langfuse, SigNoz and ClickStack are trademarks of their respective owners.

