diskvet 0.2.2 · ClickHouse 25.12.1.649 · detected: Langfuse · container langfuse-clickhouse-1
Nothing was changed. Nothing was sent anywhere. Rendered from saved query results (--replay).

| # | Check | Status |
|---|---|---|
| 1 | System logs without TTL | CRITICAL |
| 2 | Disk space not in ClickHouse table parts | WARN |
| 3 | Disk usage and rough forecast | WARN |
| 4 | Growth per day | WARN |
| 5 | Too many parts | OK |
| 6 | Inactive and detached parts | OK |
| 7 | Deleted rows and stuck mutations | WARN |

### Heads-up for your version
- ClickHouse 25.12 is fine for Langfuse. Before upgrading ClickHouse to 26.8+, update Langfuse first (DateTime64 fix: langfuse#16858, PR #16892).

### How to run the fixes
Nothing below runs by itself: read each command, then run it yourself.
SQL goes into clickhouse-client as a user that may change tables (a read-only user can't): `docker exec -it langfuse-clickhouse-1 clickhouse-client --user <user> --password`. In Langfuse's docker compose the user is CLICKHOUSE_USER from your .env. Shell commands run on the Docker host.

## 1. System logs without TTL: CRITICAL

88.7 GiB of ClickHouse's own logs vs 5.4 GiB of Langfuse data. 6 logs have no TTL (79.1 GiB together). 1 old copy (*_log_N, left after upgrades or config changes): 2.0 GiB.

| Table | Size | Rows | TTL | Oldest row | Status |
|---|---|---|---|---|---|
| system.trace_log | 58.3 GiB | 912.3M | none | 212 d | CRITICAL |
| system.text_log | 14.2 GiB | 45.1M | none | 212 d | CRITICAL |
| system.query_log | 6.1 GiB | 9.1M | none | 212 d | WARN |
| system.trace_log_0 | 2.0 GiB | 31.2M | old copy | 300 d | WARN |
| system.metric_log | 500.0 MiB | 612.3k | none | 212 d | INFO |
| system.processors_profile_log | 286.1 MiB | 1.2M | 30 d | 45 d | WARN |
| system.opentelemetry_span_log | 1.0 MiB | 1234 | none | 12 d | OK |

And 2 smaller logs, 976.6 KiB together.

**Fix A: free space now.** Safe for your data, no restart: it deletes only ClickHouse's own log rows.
```sql
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.query_log;
TRUNCATE TABLE system.metric_log;
```
system.trace_log (58.3 GiB) is over the drop limit (max_table_size_to_drop = 50 GB), so ClickHouse refuses a plain TRUNCATE. Create the one-time flag right before it (the first TRUNCATE that needs the flag uses it up; create it again before the next big table):
```sh
docker exec langfuse-clickhouse-1 sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```
```sql
TRUNCATE TABLE system.trace_log;
```
Or, on ClickHouse 24.1 and newer, without the flag: `TRUNCATE TABLE system.trace_log SETTINGS max_table_size_to_drop = 0;`

**Fix B: stop it coming back.** Safe; needs a ClickHouse restart (about 10 s). Keeps 7 days of each log (change with --ttl-days).
Save as `clickhouse-ttl.xml` (only logs without TTL are listed):
```xml
<clickhouse>
    <!-- diskvet 0.2.2: TTL for system logs that had none -->
    <trace_log>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
    </trace_log>
    <text_log>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
    </text_log>
    <query_log>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
    </query_log>
    <metric_log>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
    </metric_log>
    <opentelemetry_span_log>
        <!-- the default config sets an engine for this log, so its TTL goes inside the engine -->
        <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
    </opentelemetry_span_log>
    <crash_log>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
    </crash_log>
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
DROP TABLE system.trace_log_0;
```

**TTL is set but old rows are still there.** ClickHouse removes expired rows during merges (by default at most every 4 h, merge_with_ttl_timeout).
- system.processors_profile_log: TTL 30 d, but the oldest row is 45 d old.
If it stays like this for a day, force it (heavy: rewrites the table): `ALTER TABLE system.<log> MATERIALIZE TTL;`

## 2. Disk space not in ClickHouse table parts: WARN

Disk default: 150.0 GiB, used 124.8 GiB. ClickHouse table parts: 94.1 GiB (inactive 100.0 MiB, detached 0 B).
Not in table parts: 30.7 GiB (20% of the disk): Docker logs and images, other services (MinIO, Postgres), OS files, and the blocks the file system reserves for root (often 5% on ext4). The script can't see which.

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

## 3. Disk usage and rough forecast: WARN

| Disk | Size | Used | Free | Rough forecast | Status |
|---|---|---|---|---|---|
| default | 150.0 GiB | 83% | 25.2 GiB | +1.5 GiB/day: 95% full in ~12 days | WARN |

Forecast: straight line through the hourly maximum of ClickHouse's own disk metric (system.asynchronous_metric_log) over the last 7.0 days. A spike or a cleanup in that window skews it.

A real forecast needs hourly history: one run of this script sees only one moment.

Where to get space back fastest: check 1 (system logs), check 2 (Docker logs), check 7 (deleted rows).

## 4. Growth per day: WARN

Written in the last 24 h: 1.5 GiB (new parts before merges, from system.part_log). Free on disk default: 25.2 GiB.

| Table | Written in 24 h | New parts | Share of free space | Status |
|---|---|---|---|---|
| system.trace_log | 1.4 GiB | 96 | 5.6% | WARN |
| default.observations | 102.4 MiB | 1440 | 0.4% | OK |

If the top tables are system.* logs, check 1 fixes it. If they are Langfuse tables, check the retention settings of Langfuse itself.

## 5. Too many parts: OK

Most active parts in one partition: 214 (default.observations, partition 202609). By default inserts slow down at 1000 parts per partition and fail at 3000 (table SETTINGS can change this).
Since the server started: 0 inserts delayed, 0 rejected (Too many parts).

| Table | Partition | Active parts | Slow down at | Fail at | Status |
|---|---|---|---|---|---|
| default.observations | 202609 | 214 | 1000 | 3000 | OK |
| default.traces | 202609 | 120 | 1000 | 3000 | OK |

## 6. Inactive and detached parts: OK

Inactive parts (already merged, waiting to be deleted): 12 parts, 100.0 MiB. Stuck for more than 1 hour: none. ClickHouse normally deletes them within minutes (old_parts_lifetime, 8 min by default).
Detached parts (not used by queries, still on disk): none.

## 7. Deleted rows and stuck mutations: WARN

Parts that still hold rows removed with DELETE FROM (lightweight delete). The script can't count deleted rows without reading your data, so "share" is the share of the table in such parts: the upper bound of what can come back.

| Table | Parts with deleted rows | Their size | Share of table | Status |
|---|---|---|---|---|
| default.observations | 3 | 1.8 GiB | 46% | WARN |

**Fix: apply the delete mask.** Rewrites these parts in the background (a mutation) and needs free space about the size of each partition. Safe for rows that were not deleted.
```sql
ALTER TABLE default.observations APPLY DELETED MASK IN PARTITION ID '202608';
```
Heavier alternative: `OPTIMIZE TABLE <table> PARTITION ID '<id>' FINAL` rewrites and merges the whole partition. Avoid it on big partitions in busy hours.
Newer Langfuse workers can do this themselves: `LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` (off by default; check your version's .env.prod.example).

No unfinished mutations.

---
This is a snapshot. It can't tell when the disk will really run out, or whether your trace_log is normal for a Langfuse of your size.
Want an email before the disk fills? Join early access (free beta): https://github.com/Protemir/diskvet#early-access
