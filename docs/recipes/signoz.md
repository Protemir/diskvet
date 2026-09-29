# SigNoz (self-hosted, Docker)

SigNoz keeps traces, logs and metrics in ClickHouse databases `signoz_traces`,
`signoz_logs`, `signoz_metrics` and a few more. The report treats these as
SigNoz data, and `--print-payload` keeps their table names (they are the same
in every SigNoz install).

Not tested on a real SigNoz install yet: the notes below come from the SigNoz
issue tracker and from tests on plain ClickHouse images.

## Run the check

```sh
sh diskvet.sh report --docker auto > report.md
```

`--docker auto` finds SigNoz's ClickHouse by its image
(`clickhouse/clickhouse-server`), or by the service `clickhouse` when you run it
in the folder of SigNoz's old `docker-compose.yaml` (`deploy/docker`, up to
v0.129.0). If it finds nothing or several containers, pass the name from
`docker ps`: `signoz-telemetrystore-clickhouse-0-0` with Foundry, SigNoz's
Docker install since v0.130.0, or `signoz-clickhouse` with the old compose
files. The commands below use `signoz-clickhouse`. The old compose files ran
`clickhouse/clickhouse-server:24.1.2-alpine` up to v0.93.0 and `25.5.6` from
v0.94.0; Foundry v0.3.0 runs `25.12.5`. The script also works inside the
container with its own `sh` and `awk` (busybox in the `-alpine` image, dash and
mawk in 25.12):

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

This part is for the old compose files. Foundry writes its ClickHouse config
as YAML (`pours/deployment/telemetrystore/clickhouse/config-0-0.yaml`), with a
1-day TTL on the system logs in its example; how to change that file so the
change stays with Foundry is not checked here.

The old compose files ship SigNoz's **own** ClickHouse `config.xml` and mount
it into the container. Before you add the generated TTL file, look at how that
config defines the system logs:

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

## Kubernetes (Helm chart)

```sh
sh diskvet.sh report --k8s auto -n signoz > report.md     # -n: the namespace of your SigNoz release
```

`--k8s` runs `clickhouse-client` inside the ClickHouse pod with
`kubectl exec -i`: nothing is copied into the pod, and you type no password
(diskvet uses the pod's own login). The shell commands in the report are
complete `kubectl` lines for that pod.

- The SigNoz chart runs ClickHouse through the Altinity operator: a pod like
  `chi-signoz-clickhouse-cluster-0-0-0`, container `clickhouse`. diskvet logs
  in as the `default` user from inside the pod, which needs no password from
  localhost (not verified yet).
- With several shards or replicas each pod has its own disk and system logs.
  `--k8s auto` then runs nothing and prints one command per pod. Run each of
  them, or loop over the pod names it prints:

  ```sh
  for pod in chi-signoz-clickhouse-cluster-0-0-0 chi-signoz-clickhouse-cluster-0-1-0; do
      sh diskvet.sh report --k8s "signoz/$pod" > "report-$pod.md"
  done
  ```

- The TTL file goes into `clickhouse.files` of your values, as
  `config.d/zz-diskvet-ttl.xml`; logs that already have a TTL from the chart
  are changed with `clickhouse.clickhouseOperator.<logName>.ttl` instead, the
  log name in camelCase, such as `queryLog` for `query_log` (read in the
  SigNoz clickhouse chart's values and templates):
  [SigNoz on Kubernetes](kubernetes.md#signoz).

SigNoz's own chart is not tested yet. The test suite's kind cluster runs the
Altinity operator 0.27.4 with a ClickHouseInstallation of its own: diskvet
logs in as the passwordless `default` user, the TTL file goes in through
`config.d/`, and the operator does **not** restart the pod for a changed
file. Once the file is in the pod, restart it with `kubectl delete pod`, as
the report says. SigNoz ships the operator 0.21.2, and whether that release
restarts the pod is not verified yet:
[SigNoz on Kubernetes](kubernetes.md#signoz). The values keys, how the pod restarts, a
full volume or node disk, and troubleshooting:
[Kubernetes: ClickHouse chart by chart](kubernetes.md). What diskvet sends to
the cluster, the permissions it needs and what the API server's audit log
shows: [README → Kubernetes](../../README.md#kubernetes).

---

Sources for every command: [README → Sources](../../README.md#sources). ClickHouse is a registered trademark of ClickHouse, Inc.; diskvet is not affiliated with ClickHouse, Inc.
