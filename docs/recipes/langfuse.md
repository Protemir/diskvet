# Langfuse (self-hosted, docker compose)

Langfuse v3 keeps traces, observations and scores in ClickHouse. Its
`docker-compose.yml` runs the stock `clickhouse/clickhouse-server` image with
the default server config, so everything in the main README applies as is.
Langfuse's own FAQ covers the main fix:
[reduce ClickHouse disk size](https://langfuse.com/faq/all/reduce-clickhouse-disk-size).
This page adds what the FAQ does not say.

## Run the check

```sh
cd langfuse                         # the folder with docker-compose.yml
sh diskvet.sh report --docker auto > report.md
```

`--docker auto` asks `docker compose ps -q clickhouse` in the current folder
(the service is called `clickhouse` in Langfuse's compose file; the container
name depends on the folder name, e.g. `langfuse-clickhouse-1`). The user and
password come from the container's `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD`,
which Langfuse's compose file sets from your `.env`.

For the fixes you need the same user in `clickhouse-client` (`clickhouse`
unless your `.env` sets `CLICKHOUSE_USER`; the password is `CLICKHOUSE_PASSWORD`
from `.env`):

```sh
docker compose exec clickhouse clickhouse-client --user clickhouse --password
```

Langfuse's compose file runs ClickHouse as `user: "101:101"`, so `docker exec`
commands run as the `clickhouse` user, not root. The report's flag command
(`touch .../flags/force_drop_table && chmod 666 ...`) works as that user:
`tests/auto.sh` checks it with the same setting.

## Where the space goes

`trace_log`, `text_log`, `query_log` and `metric_log` without TTL are the usual
suspects ([langfuse#13123](https://github.com/langfuse/langfuse/issues/13123):
66.86 GiB of `trace_log` next to less than 150 MiB of Langfuse data). Check 1 of
the report gives the order of fixes: `TRUNCATE` now (with the one-time flag for
tables over 50 GB), then the TTL file and a restart, then `DROP` of the
`*_log_N` copies the restart leaves behind.

To mount the TTL file, add one line to the `clickhouse` service of
`docker-compose.yml` and recreate the service:

```yaml
  clickhouse:
    volumes:
      - langfuse_clickhouse_data:/var/lib/clickhouse
      - langfuse_clickhouse_logs:/var/log/clickhouse-server
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

```sh
docker compose up -d clickhouse
docker compose logs --tail 50 clickhouse     # make sure it started
```

Keep your existing `volumes:` lines; only the last line is new.

The other big one is Docker's own container logs
([langfuse#16339](https://github.com/langfuse/langfuse/issues/16339): 89.1 GiB).
They are outside ClickHouse, so check 2 shows them only as "not in table parts".
The fix is a `logging:` block on every service (see check 2 in the report).

## Deleted traces keep their space

Langfuse deletes traces, observations and scores with lightweight
`DELETE FROM` (trace deletion, project deletion, data retention). ClickHouse
only marks the rows; the space comes back when a part is merged, and old
monthly partitions are rarely merged. Check 7 lists the partitions and prints
`ALTER TABLE ... APPLY DELETED MASK IN PARTITION ID '...'` for each.

Newer Langfuse workers have a background job for exactly this:
`LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` (off by default; look for
it in your version's `.env.prod.example` before relying on it).

## Before you upgrade ClickHouse to 26.8 or newer

Update Langfuse first. Older Langfuse releases send DateTime64 values as JSON
numbers (milliseconds). ClickHouse 26.8 changed how it reads them, and the
timestamps become `9999-12-31 23:59:59`
([langfuse#16858](https://github.com/langfuse/langfuse/issues/16858); fixed in
[PR #16892](https://github.com/langfuse/langfuse/pull/16892)).

We reproduced the ClickHouse side of it: the same JSONEachRow insert of
`{"timestamp": 1758650000000}` into a `DateTime64(3)` column gives
`2025-09-23 17:53:20` on 24.8 and 25.12, and `9999-12-31 23:59:59` in partition
`999912` on 26.9. The report counts partitions whose ID starts with `9999` and
warns about the version.

To look yourself:

```sql
SELECT database, table, partition_id, count() AS parts
FROM system.parts
WHERE active AND startsWith(partition_id, '9999')
GROUP BY database, table, partition_id;
```

## Kubernetes (Helm chart)

Not tested yet. The script needs `clickhouse-client`, which the ClickHouse pod
has. One way:

```sh
kubectl cp diskvet.sh  <namespace>/<clickhouse-pod>:/tmp/diskvet.sh
kubectl cp checks.sql <namespace>/<clickhouse-pod>:/tmp/checks.sql
kubectl exec -n <namespace> <clickhouse-pod> -- sh /tmp/diskvet.sh report --host 127.0.0.1 --user <user> --password '<password>' > report.md
```

The fix commands in such a report are written for a plain server (`sudo sh -c
...`); run the shell parts with `kubectl exec` instead.

---

Sources for every command: [README → Sources](../../README.md#sources). ClickHouse is a registered trademark of ClickHouse, Inc.; diskvet is not affiliated with ClickHouse, Inc.
