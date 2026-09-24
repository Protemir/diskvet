# SigNoz (self-hosted, docker compose)

SigNoz keeps traces, logs and metrics in ClickHouse databases `signoz_traces`,
`signoz_logs`, `signoz_metrics` and a few more. The report treats these as
SigNoz data, and `--print-payload` keeps their table names (they are the same
in every SigNoz install).

Not tested on a real SigNoz install yet: the notes below come from the SigNoz
issue tracker and from tests on plain ClickHouse images.

## Run the check

```sh
cd signoz/deploy/docker             # the folder with SigNoz's docker-compose.yaml
sh diskvet.sh report --docker auto > report.md
```

If `--docker auto` finds nothing or finds several containers, pass the name:
`--docker signoz-clickhouse` (see `docker ps`). SigNoz images are Alpine-based
(`clickhouse/clickhouse-server:<version>-alpine`); the script also works inside
such a container with busybox `sh` and `awk`:

```sh
docker cp diskvet.sh  signoz-clickhouse:/tmp/diskvet.sh
docker cp checks.sql signoz-clickhouse:/tmp/checks.sql
docker exec signoz-clickhouse sh /tmp/diskvet.sh report --host 127.0.0.1 > report.md
```

## Where the space goes

[SigNoz#12050](https://github.com/SigNoz/signoz/issues/12050): 80+ GB of
ClickHouse's own logs next to less than 500 MB of telemetry. Newer SigNoz
installers set TTLs on system logs themselves, older installs don't: check 1
tells you which case you have.

SigNoz ships its **own** ClickHouse `config.xml` and mounts it into the
container. Before you add the generated TTL file, look at how that config
defines the system logs:

```sh
docker exec signoz-clickhouse sh -c 'grep -n -A3 "_log>" /etc/clickhouse-server/config.xml | grep -E "_log>|<engine>|<ttl>|<partition_by>"'
```

- A log with `<partition_by>` or with nothing special: the generated `<ttl>`
  works.
- A log with `<engine>`: ClickHouse will not start with a separate `<ttl>` for
  it. Put the TTL inside that `<engine>` instead, the way the generated file
  does it for `opentelemetry_span_log`.

Mount the file next to SigNoz's config in the ClickHouse service and recreate
it:

```yaml
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

## Retention of SigNoz data

The TTL of traces, logs and metrics themselves is set in the SigNoz UI
(Settings, then Retention), not in ClickHouse config. If check 4 shows SigNoz
tables growing fast, change it there; don't `ALTER` SigNoz tables by hand.

## Replicated setups

SigNoz can run ClickHouse with ZooKeeper and replicated tables. The report's
`TRUNCATE` and `DROP` commands for `system.*` tables are local to one server:
run them on each replica. Replicated clusters are not covered by the tests yet.

---

Sources for every command: [README → Sources](../../README.md#sources). ClickHouse is a registered trademark of ClickHouse, Inc.; diskvet is not affiliated with ClickHouse, Inc.
