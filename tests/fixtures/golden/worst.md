diskvet 0.2.2 · ClickHouse 26.9.1.1629 · detected: Langfuse
Nothing was changed. Nothing was sent anywhere. Rendered from saved query results (--replay).

| # | Check | Status |
|---|---|---|
| 1 | System logs without TTL | CRITICAL |
| 2 | Disk space not in ClickHouse table parts | CRITICAL |
| 3 | Disk usage and rough forecast | CRITICAL |
| 4 | Growth per day | CRITICAL |
| 5 | Too many parts | CRITICAL |
| 6 | Inactive and detached parts | CRITICAL |
| 7 | Deleted rows and stuck mutations | CRITICAL |

### Heads-up for your version
- 5 active parts in partitions of year 9999 (partition ID 9999...). Timestamps were stored as 9999-12-31: with Langfuse this is langfuse#16858 (ClickHouse 26.8+ with an older Langfuse). Update Langfuse to a release with PR #16892; the wrong rows need a manual fix.
- ClickHouse 26.9 with Langfuse: make sure your Langfuse includes the DateTime64 fix (langfuse#16858, PR #16892). Older Langfuse releases store timestamps as 9999-12-31 on ClickHouse 26.8+.

### How to run the fixes
Nothing below runs by itself: read each command, then run it yourself.
SQL goes into `clickhouse-client` as a user that may change tables (a read-only user can't). Shell commands run on the ClickHouse server.

## 1. System logs without TTL: CRITICAL

45.0 GiB of ClickHouse's own logs vs 20.0 GiB of Langfuse data. 2 logs have no TTL (25.0 GiB together). 2 old copies (*_log_N, left after upgrades or config changes): 60.0 GiB.

| Table | Size | Rows | TTL | Oldest row | Status |
|---|---|---|---|---|---|
| system.text_log | 20.0 GiB | 90.0M | none | 30 d | CRITICAL |
| system.trace_log | 5.0 GiB | 60.0M | none | 30 d | WARN |
| system.query_log_1 | 60.0 GiB | 1.0M | old copy | 90 d | WARN |
| system.query_log_2 | 1.0 MiB | 100 | old copy | 120 d | INFO |

**Fix A: free space now.** Safe for your data, no restart: it deletes only ClickHouse's own log rows.
```sql
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.trace_log;
```
The drop limit is unknown (max_table_size_to_drop: 50 GB, the default: this user can't read system.server_settings). If a TRUNCATE fails with Code 359, add `SETTINGS max_table_size_to_drop = 0` to it (ClickHouse 24.1+), or create the one-time flag first: `sudo sh -c 'touch /data/clickhouse/flags/force_drop_table && chmod 666 /data/clickhouse/flags/force_drop_table'`

**Fix B: stop it coming back.** Safe; needs a ClickHouse restart (about 10 s). Keeps 7 days of each log (change with --ttl-days).
Save as `clickhouse-ttl.xml` (only logs without TTL are listed):
```xml
<clickhouse>
    <!-- diskvet 0.2.2: TTL for system logs that had none -->
    <text_log>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
    </text_log>
    <trace_log>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
    </trace_log>
</clickhouse>
```
Docker compose: mount it into the ClickHouse service, then recreate it with `docker compose up -d clickhouse`:
```yaml
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```
Without Docker: copy it to `/etc/clickhouse-server/config.d/` and run `sudo systemctl restart clickhouse-server`.

On restart ClickHouse renames every changed log to `<name>_0` (its old rows stay there) and starts a new table with the TTL. Do Fix A first so these copies are small, then run this report again: it lists the copies to drop.
If ClickHouse does not start and its log says `TTL parameters should be specified directly inside 'engine'`, your config defines that log with `<engine>`: put the TTL inside that `<engine>` (like opentelemetry_span_log above) or remove the log from this file.

**Fix C: drop old copies.** Irreversible, safe for your data: ClickHouse no longer writes to these tables.
```sql
DROP TABLE system.query_log_2;
```
system.query_log_1 (60.0 GiB) is over the drop limit (max_table_size_to_drop = 50 GB, the default: this user can't read system.server_settings), so ClickHouse refuses a plain DROP. Create the one-time flag right before it (the first DROP that needs the flag uses it up; create it again before the next big table):
```sh
sudo sh -c 'touch /data/clickhouse/flags/force_drop_table && chmod 666 /data/clickhouse/flags/force_drop_table'
```
```sql
DROP TABLE system.query_log_1;
```
Or, on ClickHouse 24.1 and newer, without the flag: `DROP TABLE system.query_log_1 SETTINGS max_table_size_to_drop = 0;`

## 2. Disk space not in ClickHouse table parts: CRITICAL

Disk default: 100.0 GiB, used 97.0 GiB. ClickHouse table parts: 42.0 GiB (inactive 0 B, detached 2.0 GiB).
Not in table parts: 55.0 GiB (55% of the disk): Docker logs and images, other services (MinIO, Postgres), OS files, and the blocks the file system reserves for root (often 5% on ext4). The script can't see which.

Most common cause: Docker container logs without rotation (langfuse#16339: 89.1 GiB). See what takes the space (on the server):
```sh
sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'
sudo du -xh --max-depth=2 / 2>/dev/null | sort -h | tail -15
```

**Fix: rotate Docker logs.** Safe; recreates the containers (about 30 s of downtime).
In `docker-compose.yml`, for every service (or once in the Docker daemon config `/etc/docker/daemon.json`: `{"log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}}` and `sudo systemctl restart docker`):
```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```
Then `docker compose up -d --force-recreate`: log settings apply only to recreated containers. Recreating a container also removes its old log file and frees the space (in langfuse#16339 this gave back 81 GiB). Don't truncate or rotate Docker's `*-json.log` files with outside tools: Docker owns them (Langfuse's self-hosting README says the same).

## 3. Disk usage and rough forecast: CRITICAL

| Disk | Size | Used | Free | Rough forecast | Status |
|---|---|---|---|---|---|
| default | 100.0 GiB | 97% | 3.0 GiB | +2.0 GiB/day: 95% full in ~0 days | CRITICAL |

Forecast: straight line through the hourly maximum of ClickHouse's own disk metric (system.asynchronous_metric_log) over the last 4.1 days. A spike or a cleanup in that window skews it.

A real forecast needs hourly history: one run of this script sees only one moment.

Where to get space back fastest: check 1 (system logs), check 2 (Docker logs), check 7 (deleted rows).

## 4. Growth per day: CRITICAL

Written in the last 24 h: 1.0 GiB (new parts before merges, from system.part_log). Free on disk default: 3.0 GiB.

| Table | Written in 24 h | New parts | Share of free space | Status |
|---|---|---|---|---|
| default.events_full | 1.0 GiB | 3000 | 33% | CRITICAL |

If the top tables are system.* logs, check 1 fixes it. If they are Langfuse tables, check the retention settings of Langfuse itself.

## 5. Too many parts: CRITICAL

Most active parts in one partition: 1200 (default.events_full, partition 202609). By default inserts slow down at 1000 parts per partition and fail at 3000 (table SETTINGS can change this).
Since the server started: 523 inserts delayed, 17 rejected (Too many parts).

| Table | Partition | Active parts | Slow down at | Fail at | Status |
|---|---|---|---|---|---|
| default.events_full | 202609 | 1200 | 1000 | 3000 | CRITICAL |
| customer_acme.clicks | 20260923 | 350 | 1000 | 3000 | WARN |

**What to do.** See whether merges run: `SELECT database, table, round(elapsed) AS sec, round(progress, 2) AS progress, num_parts FROM system.merges;`
If someone stopped merges (SYSTEM STOP MERGES), start them again. Safe:
```sql
SYSTEM START MERGES default.events_full;
SYSTEM START MERGES customer_acme.clicks;
```
Many small inserts are the usual cause: send fewer, bigger INSERTs, or turn on `async_insert=1` for the writer.
To merge a partition now (heavy: rewrites it and needs free space about its size; avoid busy hours):
```sql
OPTIMIZE TABLE default.events_full PARTITION ID '202609' FINAL;
OPTIMIZE TABLE customer_acme.clicks PARTITION ID '20260923' FINAL;
```

## 6. Inactive and detached parts: CRITICAL

Inactive parts (already merged, waiting to be deleted): 40 parts, 12.0 GiB. Stuck for more than 1 hour: 35 parts, 11.5 GiB. ClickHouse normally deletes them within minutes (old_parts_lifetime, 8 min by default).
Detached parts (not used by queries, still on disk): 3 parts, 2.0 GiB.

| Table | Kind | Parts | Size | Details | Status |
|---|---|---|---|---|---|
| default.events_full | inactive, stuck > 1 h | 35 | 11.5 GiB | Candidate for deletion | CRITICAL |
| default.traces | detached | 3 | 2.0 GiB | broken-on-start, detached by user | WARN |

**Stuck inactive parts.** Usually a long query or a backup holds them. Look:
```sql
SELECT query_id, user, round(elapsed) AS sec FROM system.processes ORDER BY elapsed DESC LIMIT 5;
SELECT name, refcount, removal_state FROM system.parts WHERE NOT active AND database = 'default' AND table = 'events_full' LIMIT 20;
```
When nothing holds them any more, ClickHouse deletes them; a ClickHouse restart also does.

**Detached parts.** ClickHouse detaches broken parts itself (reason broken, unexpected, noquorum, ...); "detached by user" came from ALTER TABLE ... DETACH. Look first: `SELECT database, table, name, reason, formatReadableSize(bytes_on_disk) FROM system.detached_parts;`
Bring a part back only if you know it is valid (the commented ATTACH lines). The DROP lines delete it from disk. Irreversible:
```sql
-- ALTER TABLE default.traces ATTACH PART '202608_1_1_0';
ALTER TABLE default.traces DROP DETACHED PART '202608_1_1_0' SETTINGS allow_drop_detached = 1;
-- ALTER TABLE default.traces ATTACH PART '202608_2_2_0';
ALTER TABLE default.traces DROP DETACHED PART '202608_2_2_0' SETTINGS allow_drop_detached = 1;
-- ALTER TABLE default.traces ATTACH PART '202608_3_3_0';
ALTER TABLE default.traces DROP DETACHED PART '202608_3_3_0' SETTINGS allow_drop_detached = 1;
```

## 7. Deleted rows and stuck mutations: CRITICAL

Parts that still hold rows removed with DELETE FROM (lightweight delete). The script can't count deleted rows without reading your data, so "share" is the share of the table in such parts: the upper bound of what can come back.

| Table | Parts with deleted rows | Their size | Share of table | Status |
|---|---|---|---|---|
| default.traces | 12 | 13.0 GiB | 65% | CRITICAL |

**Fix: apply the delete mask.** Rewrites these parts in the background (a mutation) and needs free space about the size of each partition. Safe for rows that were not deleted.
```sql
ALTER TABLE default.traces APPLY DELETED MASK IN PARTITION ID '202608';
ALTER TABLE default.traces APPLY DELETED MASK IN PARTITION ID '202607';
```
Heavier alternative: `OPTIMIZE TABLE <table> PARTITION ID '<id>' FINAL` rewrites and merges the whole partition. Avoid it on big partitions in busy hours.
Newer Langfuse workers can do this themselves: `LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` (off by default; check your version's .env.prod.example).

Unfinished mutations: 2.

| Table | Mutation | Age | Parts left | Last attempt | Status |
|---|---|---|---|---|---|
| default.traces | mutation_42.txt | 2 d | 12 | failed | CRITICAL |
| default.scores | mutation_7.txt | 90 min | 3 | running | WARN |

See the command and the error first: `SELECT database, table, mutation_id, command, latest_fail_reason FROM system.mutations WHERE NOT is_done;`
Stop a broken or hanging mutation (parts it already changed stay changed; fix the cause before running it again):
```sql
KILL MUTATION WHERE database = 'default' AND table = 'traces' AND mutation_id = 'mutation_42.txt';
KILL MUTATION WHERE database = 'default' AND table = 'scores' AND mutation_id = 'mutation_7.txt';
```

---
This is a snapshot. It can't tell when the disk will really run out, or whether your text_log is normal for a Langfuse of your size.
Want an email before the disk fills? Join early access (free beta): https://github.com/Protemir/diskvet#early-access
