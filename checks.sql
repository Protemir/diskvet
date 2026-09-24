-- checks.sql: every query diskvet runs against your ClickHouse.
--
-- Rules (enforced by tests/check_sql.sh in CI):
--   * only SELECT, and only FROM / JOIN a fixed list of system tables or subqueries
--     (tables, parts, disks, detached_parts, merge_tree_settings, mutations,
--     part_log, asynchronous_metric_log, asynchronous_metrics, events,
--     server_settings); never system.query_log or other logs with query texts;
--   * no table functions (url, remote, remoteSecure, file, s3, cluster, input, ...),
--     no dictGet / joinGet, no "IN <table>", no comma joins, no query parameters;
--   * no SETTINGS inside SQL: the wrapper sets readonly=2 and resource limits;
--   * one query per check, the first column is check_id and equals the query id;
--   * if a query fails (old version, missing grant, no part_log), only that
--     check becomes NOT_RUN; the others still run.
--
-- Each query starts with a line "-- @query <id> [tag]". Tags:
--   optional  a failure is expected on some versions and is not reported;
--   payload   runs only for --print-payload.
--
-- Besides these queries the wrapper sends exactly one more: the probe
-- SELECT getSetting('readonly'), to confirm the session is read-only.
--
-- Nothing here reads rows of your own tables. system.parts, system.tables and
-- friends contain metadata only (names, sizes, counts, dates).


-- @query passport
-- 0. Version, uptime, which product lives here (by table names only),
--    size of product data vs ClickHouse's own logs.
SELECT
    'passport'                                               AS check_id,
    version()                                                AS clickhouse_version,
    uptime()                                                 AS uptime_s,
    multiIf(t.langfuse_tables >= 3, 'langfuse',
            t.signoz_tables > 0, 'signoz',
            t.clickstack_tables > 0, 'clickstack',
            'other')                                         AS product,
    t.has_replicated                                         AS replicated,
    p.product_bytes                                          AS product_bytes,
    p.system_log_bytes                                       AS system_log_bytes,
    p.year_9999_parts                                        AS year_9999_parts
FROM
(
    SELECT
        countIf(database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')
                AND name IN ('traces', 'observations', 'scores'))              AS langfuse_tables,
        countIf(startsWith(database, 'signoz_'))                               AS signoz_tables,
        countIf(name IN ('otel_logs', 'otel_traces', 'hyperdx_sessions'))      AS clickstack_tables,
        toUInt8(countIf(startsWith(engine, 'Replicated')) > 0)                 AS has_replicated
    FROM system.tables
) AS t
CROSS JOIN
(
    SELECT
        sumIf(bytes_on_disk, database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')) AS product_bytes,
        sumIf(bytes_on_disk, database = 'system' AND match(table, '_log(_[0-9]+)?$'))                AS system_log_bytes,
        -- partition IDs 9999, 999912, 99991231 (year, month, day); hashed IDs of other keys don't count
        countIf(database != 'system' AND match(partition_id, '^9999([0-9][0-9])?([0-9][0-9])?$'))   AS year_9999_parts
    FROM system.parts
    WHERE active
) AS p;


-- @query drop_limit optional
-- Size limit for DROP / TRUNCATE (default 50 GB). Needs SELECT on
-- system.server_settings; without it the report assumes the default.
SELECT
    'drop_limit'    AS check_id,
    name            AS setting,
    value           AS setting_value
FROM system.server_settings
WHERE name = 'max_table_size_to_drop';


-- @query system_logs
-- 1. ClickHouse's own logs (system.*_log) and old copies (*_log_N):
--    size, TTL, age of the oldest row, date column for the TTL recipe.
SELECT
    'system_logs'                                                   AS check_id,
    t.name                                                          AS log_table,
    toUInt8(match(t.name, '_[0-9]+$'))                              AS is_old_copy,
    toUInt8(positionCaseInsensitive(t.engine_full, ' TTL ') > 0)    AS has_ttl,
    multiIf(
        match(t.engine_full, 'toIntervalDay\\('),
            toUInt64(toUInt32OrZero(extract(t.engine_full, 'toIntervalDay\\((\\d+)\\)'))),
        match(t.engine_full, 'toIntervalWeek\\('),
            7 * toUInt64(toUInt32OrZero(extract(t.engine_full, 'toIntervalWeek\\((\\d+)\\)'))),
        match(t.engine_full, 'toIntervalMonth\\('),
            30 * toUInt64(toUInt32OrZero(extract(t.engine_full, 'toIntervalMonth\\((\\d+)\\)'))),
        match(t.engine_full, 'toIntervalHour\\('),
            intDiv(toUInt64(toUInt32OrZero(extract(t.engine_full, 'toIntervalHour\\((\\d+)\\)'))), 24),
        toUInt64(0))                                                AS ttl_days,
    p.log_bytes                                                     AS size_bytes,
    p.log_rows                                                      AS size_rows,
    if(p.first_day > toDate(0), dateDiff('day', p.first_day, today()), 0) AS oldest_days,
    if(extract(t.partition_key, '(\\w*date\\w*)') != '',
       extract(t.partition_key, '(\\w*date\\w*)'), 'event_date')    AS date_column,
    t.partition_key                                                 AS partition_expr,
    t.sorting_key                                                   AS sorting_expr,
    d.total_space                                                   AS disk_total_bytes
FROM system.tables AS t
LEFT JOIN
(
    SELECT
        table,
        sum(bytes_on_disk)                        AS log_bytes,
        sum(rows)                                 AS log_rows,
        minIf(min_date, min_date > toDate(0))     AS first_day,
        argMax(disk_name, bytes_on_disk)          AS disk
    FROM system.parts
    WHERE active AND database = 'system'
    GROUP BY table
) AS p ON p.table = t.name
LEFT JOIN system.disks AS d ON d.name = p.disk
WHERE t.database = 'system'
  AND match(t.name, '_log(_[0-9]+)?$')
  AND endsWith(t.engine, 'MergeTree')
ORDER BY size_bytes DESC, log_table
LIMIT 100;


-- @query not_in_parts
-- 2. Used disk space vs. what ClickHouse table parts take
--    (active + inactive parts from system.parts, plus detached parts).
SELECT
    'not_in_parts'                     AS check_id,
    d.name                             AS disk,
    d.total_space                      AS total_bytes,
    d.free_space                       AS free_bytes,
    p.all_parts_bytes                  AS parts_bytes,
    p.inactive_parts_bytes             AS inactive_bytes,
    dp.detached_parts_bytes            AS detached_bytes
FROM system.disks AS d
LEFT JOIN
(
    SELECT
        disk_name,
        sum(bytes_on_disk)                 AS all_parts_bytes,
        sumIf(bytes_on_disk, NOT active)   AS inactive_parts_bytes
    FROM system.parts
    GROUP BY disk_name
) AS p ON p.disk_name = d.name
LEFT JOIN
(
    SELECT disk, sum(bytes_on_disk) AS detached_parts_bytes
    FROM system.detached_parts
    GROUP BY disk
) AS dp ON dp.disk = d.name
WHERE NOT d.is_remote
ORDER BY disk;


-- @query disk_now
-- 3a. Disk size and free space right now (local disks only).
SELECT
    'disk_now'          AS check_id,
    name                AS disk,
    path                AS disk_path,
    total_space         AS total_bytes,
    free_space          AS free_bytes,
    unreserved_space    AS unreserved_bytes,
    keep_free_space     AS keep_free_bytes
FROM system.disks
WHERE NOT is_remote
ORDER BY disk;


-- @query disk_history optional
-- 3b. Hourly disk usage for the last 7 days, older metric names
--     (DiskUsed_<disk>, ClickHouse up to 25.x). Fails harmlessly elsewhere.
SELECT
    'disk_history'                                                        AS check_id,
    h.disk                                                                AS disk,
    count()                                                               AS points,
    dateDiff('hour', min(h.hour), max(h.hour))                            AS span_hours,
    simpleLinearRegression(toFloat64(toUnixTimestamp(h.hour)), h.used).1 * 86400 AS growth_bytes_per_day
FROM
(
    SELECT
        substring(metric, 10)            AS disk,
        toStartOfHour(event_time)        AS hour,
        max(value)                       AS used
    FROM system.asynchronous_metric_log
    WHERE metric LIKE 'DiskUsed\\_%'
      AND event_date >= today() - 8
      AND event_time >= now() - INTERVAL 7 DAY
    GROUP BY disk, hour
) AS h
GROUP BY disk;


-- @query disk_history_kv optional
-- 3b. Same, newer layout: metric DiskUsed with the disk name in column "key"
--     (ClickHouse 26.x). Fails harmlessly on older versions.
SELECT
    'disk_history_kv'                                                     AS check_id,
    h.disk                                                                AS disk,
    count()                                                               AS points,
    dateDiff('hour', min(h.hour), max(h.hour))                            AS span_hours,
    simpleLinearRegression(toFloat64(toUnixTimestamp(h.hour)), h.used).1 * 86400 AS growth_bytes_per_day
FROM
(
    SELECT
        key                              AS disk,
        toStartOfHour(event_time)        AS hour,
        max(value)                       AS used
    FROM system.asynchronous_metric_log
    WHERE metric = 'DiskUsed'
      AND event_date >= today() - 8
      AND event_time >= now() - INTERVAL 7 DAY
    GROUP BY disk, hour
) AS h
GROUP BY disk;


-- @query growth_24h
-- 4. Bytes written per table in the last 24 hours (new parts, before merges).
SELECT
    'growth_24h'            AS check_id,
    database                AS db,
    table                   AS tbl,
    sum(size_in_bytes)      AS written_bytes_24h,
    count()                 AS new_parts
FROM system.part_log
WHERE event_type = 'NewPart'
  AND event_date >= yesterday()
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY db, tbl
ORDER BY written_bytes_24h DESC
LIMIT 100;


-- @query growth_parts optional
-- 4. Fallback when system.part_log is missing: active parts modified in the
--    last 24 hours (includes merges, so it overestimates).
SELECT
    'growth_parts'          AS check_id,
    database                AS db,
    table                   AS tbl,
    sum(bytes_on_disk)      AS recent_bytes,
    count()                 AS recent_parts
FROM system.parts
WHERE active AND modification_time >= now() - INTERVAL 1 DAY
GROUP BY db, tbl
ORDER BY recent_bytes DESC
LIMIT 100;


-- @query too_many_parts
-- 5. Partitions with the most active parts, the insert limits that apply to
--    them (table SETTINGS override the server defaults), and one server row:
--    MaxPartCountForPartition, delayed and rejected inserts since start.
SELECT
    'too_many_parts'                                        AS check_id,
    'partition'                                             AS kind,
    p.database                                              AS db,
    p.table                                                 AS tbl,
    p.partition_id                                          AS partition_id,
    p.parts                                                 AS parts,
    if(o.delay_at > 0, o.delay_at, s.delay_at)              AS parts_to_delay_insert,
    if(o.throw_at > 0, o.throw_at, s.throw_at)              AS parts_to_throw_insert,
    toUInt64(0)                                             AS delayed_inserts,
    toUInt64(0)                                             AS rejected_inserts
FROM
(
    SELECT database, table, partition_id, count() AS parts
    FROM system.parts
    WHERE active
    GROUP BY database, table, partition_id
    ORDER BY parts DESC
    LIMIT 20
) AS p
LEFT JOIN
(
    SELECT
        database,
        name,
        toUInt64OrZero(extract(engine_full, 'parts_to_delay_insert = (\\d+)')) AS delay_at,
        toUInt64OrZero(extract(engine_full, 'parts_to_throw_insert = (\\d+)')) AS throw_at
    FROM system.tables
    WHERE engine_full LIKE '%parts\\_to\\_%'
) AS o ON o.database = p.database AND o.name = p.table
CROSS JOIN
(
    SELECT
        toUInt64OrZero(anyIf(value, name = 'parts_to_delay_insert')) AS delay_at,
        toUInt64OrZero(anyIf(value, name = 'parts_to_throw_insert')) AS throw_at
    FROM system.merge_tree_settings
    WHERE name IN ('parts_to_delay_insert', 'parts_to_throw_insert')
) AS s
UNION ALL
SELECT
    'too_many_parts', 'server', '', '', '',
    (SELECT toUInt64(max(value)) FROM system.asynchronous_metrics WHERE metric = 'MaxPartCountForPartition'),
    (SELECT toUInt64OrZero(any(value)) FROM system.merge_tree_settings WHERE name = 'parts_to_delay_insert'),
    (SELECT toUInt64OrZero(any(value)) FROM system.merge_tree_settings WHERE name = 'parts_to_throw_insert'),
    (SELECT sum(value) FROM system.events WHERE event = 'DelayedInserts'),
    (SELECT sum(value) FROM system.events WHERE event = 'RejectedInserts');


-- @query inactive_parts
-- 6. Inactive parts (replaced by merges, waiting for deletion; "stuck" if
--    older than 1 hour) and detached parts, per table.
SELECT
    'inactive_parts'                                                            AS check_id,
    'inactive'                                                                  AS kind,
    database                                                                    AS db,
    table                                                                       AS tbl,
    count()                                                                     AS parts,
    sum(bytes_on_disk)                                                          AS size_bytes,
    countIf(remove_time > toDateTime(0) AND remove_time < now() - INTERVAL 1 HOUR)               AS stuck_parts,
    sumIf(bytes_on_disk, remove_time > toDateTime(0) AND remove_time < now() - INTERVAL 1 HOUR)  AS stuck_bytes,
    toUInt64(max(refcount))                                                     AS max_refcount,
    toString(anyIf(removal_state, remove_time > toDateTime(0) AND remove_time < now() - INTERVAL 1 HOUR)) AS reasons,
    ''                                                                          AS part_names
FROM system.parts
WHERE NOT active
GROUP BY db, tbl
UNION ALL
SELECT
    'inactive_parts',
    'detached',
    database,
    table,
    count(),
    sum(bytes_on_disk),
    toUInt64(0),
    toUInt64(0),
    toUInt64(0),
    arrayStringConcat(arraySort(groupUniqArray(if(reason = '', 'detached by user', reason))), ', '),
    arrayStringConcat(groupArray(10)(name), ' ')
FROM system.detached_parts
GROUP BY database, table;


-- @query deleted_rows
-- 7a. Active parts that still contain rows removed by lightweight DELETE,
--     per partition, with the size of the whole table for comparison.
SELECT
    'deleted_rows'          AS check_id,
    l.database              AS db,
    l.table                 AS tbl,
    l.partition_id          AS partition_id,
    l.lwd_parts             AS lwd_parts,
    l.lwd_bytes             AS lwd_bytes,
    t.table_bytes           AS table_bytes
FROM
(
    SELECT database, table, partition_id,
           count()               AS lwd_parts,
           sum(bytes_on_disk)    AS lwd_bytes
    FROM system.parts
    WHERE active AND has_lightweight_delete
    GROUP BY database, table, partition_id
) AS l
LEFT JOIN
(
    SELECT database, table, sum(bytes_on_disk) AS table_bytes
    FROM system.parts
    WHERE active
    GROUP BY database, table
) AS t ON t.database = l.database AND t.table = l.table
ORDER BY lwd_bytes DESC
LIMIT 200;


-- @query mutations
-- 7b. Mutations that are not finished. The mutation command text and the
--     error text are not read, only whether the last attempt failed.
SELECT
    'mutations'                                   AS check_id,
    database                                      AS db,
    table                                         AS tbl,
    mutation_id                                   AS mutation,
    dateDiff('minute', create_time, now())        AS age_minutes,
    parts_to_do                                   AS parts_left,
    toUInt8(latest_fail_reason != '')             AS failing
FROM system.mutations
WHERE NOT is_done
ORDER BY age_minutes DESC
LIMIT 100;


-- @query tables payload
-- Payload only: per-table sizes for the snapshot. Names of system tables and
-- of known Langfuse / SigNoz / ClickStack tables are kept (keep_db / keep_tbl = 1);
-- every other database and table name is replaced by the wrapper with
-- db_/t_ + 16 hex of sipHash64(salt, name), computed by `clickhouse local` on
-- your side: the salt is never sent to the server. Columns 4 and 5 must stay
-- keep_db and keep_tbl (diskvet.sh, hash_names).
SELECT
    'tables'                                                            AS check_id,
    p.database                                                          AS db,
    p.table                                                             AS tbl,
    toUInt8(p.database IN ('system', 'INFORMATION_SCHEMA', 'information_schema', 'default',
                           'signoz_traces', 'signoz_logs', 'signoz_metrics', 'signoz_analytics',
                           'signoz_meter', 'signoz_metadata'))           AS keep_db,
    toUInt8(multiIf(
        match(p.table, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'),
            0,
        p.database IN ('system', 'INFORMATION_SCHEMA', 'information_schema'),
            1,
        p.database IN ('signoz_traces', 'signoz_logs', 'signoz_metrics', 'signoz_analytics',
                       'signoz_meter', 'signoz_metadata'),
            1,
        p.table IN ('traces', 'observations', 'scores', 'event_log', 'blob_storage_file_log',
                    'schema_migrations', 'project_environments', 'dataset_run_items',
                    'dataset_run_items_rmt', 'events', 'events_core', 'events_full',
                    'observations_batch_staging', 'traces_null', 'traces_all_amt',
                    'traces_7d_amt', 'traces_30d_amt', 'analytics_traces',
                    'analytics_observations', 'analytics_scores',
                    'otel_logs', 'otel_traces', 'otel_traces_trace_id_ts',
                    'otel_metrics_gauge', 'otel_metrics_sum', 'otel_metrics_histogram',
                    'otel_metrics_exponential_histogram', 'otel_metrics_summary',
                    'hyperdx_sessions'),
            1,
        0))                                                             AS keep_tbl,
    toUInt8(positionCaseInsensitive(t.engine_full, ' TTL ') > 0)        AS has_ttl,
    p.table_bytes                                                       AS size_bytes,
    p.table_rows                                                        AS size_rows,
    p.table_parts                                                       AS active_parts,
    p.max_pp                                                            AS max_parts_in_partition,
    if(p.database = 'system' AND p.first_day > toDate(0),
       dateDiff('day', p.first_day, today()), 0)                        AS oldest_days
FROM
(
    SELECT
        database,
        table,
        sum(bytes_on_disk)                                        AS table_bytes,
        sum(rows)                                                 AS table_rows,
        count()                                                   AS table_parts,
        arrayMax(sumMap([partition_id], [toUInt64(1)]).2)         AS max_pp,
        minIf(min_date, min_date > toDate(0))                     AS first_day
    FROM system.parts
    WHERE active
    GROUP BY database, table
) AS p
LEFT JOIN system.tables AS t ON t.database = p.database AND t.name = p.table
ORDER BY size_bytes DESC
LIMIT 200;
