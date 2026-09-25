# Kubernetes: ClickHouse chart by chart

The report of a `--k8s` run links here. For each Helm chart that runs
ClickHouse, this page says which pod diskvet finds, how it logs in, which
values key takes the TTL file from check 1 (Fix B) and the logger settings,
how the pod restarts, and where the data volume is. After that: restarts, the
two kinds of "disk full", more room on the volume, permissions and
troubleshooting.

diskvet itself only reads: it runs the SELECTs of `checks.sql` through
`kubectl exec -i` and prints every change for you to run. How to run it, what
it sends to the cluster, what the API server's audit log shows and the full
Role: [README → Kubernetes](../../README.md#kubernetes).

**Nothing on this page has been run on a real cluster yet.** A test job on a
real cluster is being built; this page will say what it confirms. Until then:

- **source**: we read it in the chart's or operator's own files (templates and
  default values) of the version named, on 2026-09-25;
- ***not verified yet***: from research notes, not checked in the source.
  Look it up in your chart's values before you rely on it. A row with **no**
  in the last column of the table is not verified at all.

The key names below are for the chart versions named. Your version may differ:
`helm show values REPO/CHART --version VERSION` lists its keys, and
`helm get values RELEASE -n NAMESPACE` shows what you set.

## Run the check

```sh
sh diskvet.sh report --k8s auto -n NAMESPACE > report.md     # the namespace of your release
```

The report's commands are complete `kubectl` lines for that pod. Each
ClickHouse pod has its own disk and system logs, so diskvet checks one pod per
run; with several pods, `--k8s auto` runs nothing and prints one command per
pod ([README → One pod per run](../../README.md#one-pod-per-run)).

## Charts at a glance

| Chart | Pod (example) | Container | Login diskvet uses | TTL file (check 1, Fix B) | Logger (server log files) | Restart after `helm upgrade` | Data volume (default) | Source checked |
|---|---|---|---|---|---|---|---|---|
| [Langfuse 2.x](#langfuse-chart-2x) (ClickHouse operator) | `langfuse-clickhouse-0-0-0` *(name not verified yet)* | `clickhouse-server` | none passed: the operator's client config (`default`, port 9001, password from the pod's env) | `clickhouse.cluster.settings`, YAML | `clickhouse.cluster.settings.logger` (charts up to 2.1.2 ignore `clickhouse.cluster.logger`); operator 0.0.7 default: trace, 50 files of 1000M | the operator *(not verified yet)* | PVC, 100Gi; server log files on the same PVC *(not verified yet)* | yes: chart 2.1.2, operator 0.0.7 |
| [Langfuse 1.x](#langfuse-chart-1x) (Bitnami ClickHouse 8.0.5) | `langfuse-clickhouse-shard0-0`, `-1`, `-2`: 3 pods | `clickhouse` | `CLICKHOUSE_ADMIN_USER` + `CLICKHOUSE_ADMIN_PASSWORD` | `clickhouse.extraOverrides`, one XML string | the same string, `<logger>` | StatefulSet, one pod at a time *(not verified yet)* | one PVC per pod, 8Gi | yes: Langfuse 1.5.41 values, Bitnami 8.0.5 |
| [ClickStack 2.x, 3.x](#clickstack-chart-2x-and-3x) (ClickHouse operator) | `clickstack-clickhouse-clickhouse-0-0-0` *(not verified yet)* | `clickhouse-server` | none passed: the operator's client config (`default`) | `clickhouse.cluster.spec.settings.extraConfig`, YAML; 3.4.0 sets 7 days on five logs | `clickhouse.cluster.spec.settings.logger`; 3.4.0: information, 10 files of 100M | the operator *(not verified yet)* | PVC, 10Gi (Keeper: 5Gi) | yes: chart 3.4.0 defaults |
| [ClickStack 1.x](#clickstack-chart-1x), hdx-oss-v2 | `<fullname>-clickhouse-<hash>-<id>` (a Deployment) | `clickhouse` | none passed: `default` from localhost | no value: a Kustomize post-renderer | the same post-renderer | Deployment | *not verified yet* | no |
| [SigNoz](#signoz) (Altinity operator) | `chi-signoz-clickhouse-cluster-0-0-0` | `clickhouse` (optional sidecar `logs-system-exporter`) | none passed: `default` from localhost *(not verified yet)* | `clickhouse.files`, key `config.d/zz-diskvet-ttl.xml` *(partly verified)*; logs the chart already limits: `clickhouse.clickhouseOperator.<log>.ttl` *(not verified yet)* | the same `files` key, `<logger>` | the operator *(not verified yet)* | PVC from `data-volumeclaim-template`; the log volume template is commented out | partly: SigNoz clickhouse chart templates |
| [Opik](#opik) (Altinity operator) | `chi-<chi>-<cluster>-0-0-0` | `clickhouse` | none passed | `clickhouse.configuration.files`, names under `config.d/` | the same key, `<logger>` | the operator | *not verified yet* | no |
| [PostHog](#posthog) (Altinity operator) | `chi-<chi>-<cluster>-0-0-0` | `clickhouse` | none passed | no files key: `clickhouse.settings`, `metric_log/ttl`; never `query_log` or `part_log` | *not verified yet* | the operator | *not verified yet* | no |
| [Your own ClickHouseInstallation](#your-own-clickhouseinstallation) (Altinity operator) | `chi-<chi>-<cluster>-0-0-0` | `clickhouse` | none passed | `spec.configuration.files`, key `config.d/zz-diskvet-ttl.xml` | the same key, `<logger>` | the operator | your `volumeClaimTemplates` | no |
| [trigger.dev 4.5.10+](#triggerdev) | `trigger-clickhouse-0` | `clickhouse` | `CLICKHOUSE_USER` + `CLICKHOUSE_PASSWORD` | `clickhouse.configdFiles`, key `clickhouse-ttl.xml` | the same key, `<logger>` | StatefulSet | *not verified yet* | no |
| [trigger.dev up to 4.5.9](#triggerdev) (Bitnami ClickHouse 9.x) | `<release>-clickhouse-shard0-0` | `clickhouse` | `CLICKHOUSE_ADMIN_USER` + `CLICKHOUSE_ADMIN_PASSWORD_FILE` | `clickhouse.configdFiles`, key `00-diskvet-ttl.xml` | the same key, `<logger>` | StatefulSet | *not verified yet* | no |
| [Laminar](#laminar) | `laminar-clickhouse-0` | `clickhouse` | `CLICKHOUSE_USER` + `CLICKHOUSE_PASSWORD` | not known: see [Other charts](#other-charts) | the same way | StatefulSet | in s3 mode the data is in S3 | no |
| [Sentry up to 28](#sentry), sentry-kubernetes clickhouse chart | `sentry-clickhouse-0` | `sentry-clickhouse` (diskvet picks it by its image) | none passed | `clickhouse.clickhouse.configmap.configOverride`; the clickhouse chart on its own: `clickhouse.configmap.configOverride` | the same key | StatefulSet | clickhouse chart: `clickhouse.persistentVolumeClaim.enabled` | no |
| [Plausible](#plausible) (IMIO chart, Bitnami 7.x) | `<release>-clickhouse-shard0-0` | `clickhouse` | `CLICKHOUSE_ADMIN_USER` + `CLICKHOUSE_ADMIN_PASSWORD` | as Bitnami 8.x: `clickhouse.extraOverrides` | the same string, `<logger>` | StatefulSet | `persistence.enabled` of the ClickHouse chart | no |
| [Bitnami chart 9.x](#bitnami-chart-9x) on its own | `<release>-clickhouse-shard0-0` to `shard1-2`: 6 pods | `clickhouse` | `CLICKHOUSE_ADMIN_USER` + `CLICKHOUSE_ADMIN_PASSWORD_FILE` | `configdFiles`, key `00-diskvet-ttl.xml` | the same key, `<logger>` | StatefulSet | one PVC per pod | no |
| [Sentry 29+, ClickHouse Cloud, managed](#clickhouse-outside-the-cluster) | none | none | use `--host` | | | | | no |

"none passed" means diskvet passes no `--user` and no `--password`, so
clickhouse-client inside the pod uses its own config. diskvet never sends
`--user default --password ''`, which would override that config.

## Chart by chart

The examples below keep 7 days of `trace_log` only. Check 1 of **your
report** lists exactly the logs that have no TTL on your server, with your
`--ttl-days`: put those into the block for your chart instead. Where a chart
takes YAML (the ClickHouse operator) and your report shows the TTLs as XML,
each log becomes two lines:

```text
<trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
```

```yaml
trace_log:
  ttl: "event_date + INTERVAL 7 DAY DELETE"
```

A log with `<engine>...</engine>` instead of `<ttl>` (`opentelemetry_span_log`,
which the default server config defines with an engine) becomes
`engine: "..."` with the same text.

### Langfuse chart 2.x

Source: chart 2.1.2 (app 4.38.0) and ClickHouse operator 0.0.7.

Chart 2.x has no ClickHouse subchart. It creates a `ClickHouseCluster` and a
`KeeperCluster` (`clickhouse.com/v1alpha1`) for the ClickHouse operator.
Defaults: image `clickhouse/clickhouse-server:26.4`, 100Gi, 1 replica, 3
Keeper replicas. The operator's server container is `clickhouse-server`; the
pod carries the label `clickhouse.com/role=clickhouse-server`, which also
finds it when you don't know its name:

```sh
kubectl get pods -n langfuse -l clickhouse.com/role=clickhouse-server
```

**Login.** The operator writes a client config to `/etc/clickhouse-client/`
in the pod: user `default`, port 9001, and the password from the pod's env
(the chart's Secret `<fullname>-clickhouse-auth`, key `password`). The
operator gives `default` all grants. So diskvet passes no login, and
`kubectl exec -it ... -c clickhouse-server -- clickhouse-client` needs none
either.

**TTL and logger.** The chart maps `clickhouse.cluster.settings` to the
operator's `extraConfig`, which the operator writes to
`config.d/99-extra-config.yaml`. It takes **YAML, not XML**, and it also
takes the logger: the operator's own logger settings are in the pod's main
`config.yaml`, and the `config.d` file wins. Released charts up to 2.1.2 have
no `clickhouse.cluster.logger` value (it is ignored); the chart's main branch
adds one. Add to the values you deploy Langfuse with:

```yaml
clickhouse:
  cluster:
    settings:
      logger:
        level: information
        size: "100M"
        count: 10
      trace_log:
        ttl: "event_date + INTERVAL 7 DAY DELETE"
```

**Server log files.** The chart's values say the operator's default logger
level is `trace`, and operator 0.0.7 keeps up to 50 files of 1000M each. The
operator writes them to `/var/log/clickhouse-server/`. That this folder is on
the same PVC as the data (so up to about 50 GB of a 100Gi volume) is *not
verified yet*. See how big it is (read-only):

```sh
kubectl exec -n langfuse POD -c clickhouse-server -- du -sh /var/log/clickhouse-server
```

To free that space now, delete only the rotated files; the current ones stay.
Irreversible, safe for your data, no restart (that rotated files are named
`*.log.*`, such as `clickhouse-server.log.0.gz`, is *not verified yet*):

```sh
kubectl exec -n langfuse POD -c clickhouse-server -- sh -c 'rm -f /var/log/clickhouse-server/*.log.*'
```

The logger block above keeps them small from the next restart on.

Operator 0.0.7 also defines `query_log`, `part_log`, `text_log`,
`asynchronous_metric_log` and `metric_log` itself, without a TTL. On the
operator's main branch that template sets a TTL for them (operator PR #329);
check 1 tells you which case you have.

### Langfuse chart 1.x

Source: Langfuse chart 1.5.41 values and Bitnami ClickHouse chart 8.0.5.

Chart 1.x uses the Bitnami ClickHouse chart (image `bitnamilegacy/clickhouse`)
with 1 shard and 3 replicas: pods `langfuse-clickhouse-shard0-0`, `-1` and
`-2` for a release named `langfuse`. Each has its own 8Gi volume (no
persistence override, so Bitnami's default), its own system logs and its own
report:

```sh
for pod in langfuse-clickhouse-shard0-0 langfuse-clickhouse-shard0-1 langfuse-clickhouse-shard0-2; do
    sh diskvet.sh report --k8s "langfuse/$pod" > "report-$pod.md"
done
```

**Login.** The container `clickhouse` has `CLICKHOUSE_ADMIN_USER` (`default`
in Langfuse's values) and `CLICKHOUSE_ADMIN_PASSWORD` from a Secret. diskvet
passes them to clickhouse-client inside the pod; the password never leaves
it. The data is under `/bitnami/clickhouse` (`/tmp` is an emptyDir); the
report takes the path of the one-time drop flag from the server itself.

**TTL and logger.** `clickhouse.extraOverrides` is one XML string that the
chart adds to the server config. If you already set it, put the new lines
inside your existing `<clickhouse>`:

```yaml
clickhouse:
  extraOverrides: |
    <clickhouse>
        <trace_log>
            <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
        </trace_log>
    </clickhouse>
```

The Bitnami ClickHouse chart 8.x on its own takes the same `extraOverrides`
without the `clickhouse:` level.

The TTL fix (Fix B) covers all 3 pods; Fix A and Fix C of check 1 are per
pod. Whether the chart restarts the pods by itself after a config change
(a checksum annotation on the pod template) is *not verified yet*: see
[Restarting the pod](#restarting-the-pod).

### ClickStack chart 2.x and 3.x

Source: chart 3.4.0 (app 2.39.1) defaults.

The chart runs ClickHouse through the ClickHouse operator (that 2.x does it
the same way is *not verified yet*), so everything about the operator in
[Langfuse chart 2.x](#langfuse-chart-2x) applies: container
`clickhouse-server`, the label `clickhouse.com/role=clickhouse-server`, and
the operator's client config as the login (`default`). The pod name
`clickstack-clickhouse-clickhouse-0-0-0` is *not verified yet*. Defaults in
3.4.0: image tag `25.7-alpine`, a 10Gi volume, a Keeper with 1 replica and
5Gi.

A 10Gi volume fills fast without TTLs
([ClickStack-helm-charts#275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275)).
**Chart 3.4.0 and later already sets a 7-day TTL on five system logs and the
logger to information, 10 files of 100M.** Upgrading the chart is the simplest
fix. Or add this to your values (YAML, not XML):

```yaml
clickhouse:
  cluster:
    spec:
      settings:
        logger:
          level: information
          size: "100M"
          count: 10
        extraConfig:
          trace_log:
            ttl: "event_date + INTERVAL 7 DAY DELETE"
```

### ClickStack chart 1.x

*Not verified yet*: everything about chart 1.x, starting with the pod:
`<fullname>-clickhouse-<hash>-<id>` (a Deployment), container `clickhouse`,
the `default` user from localhost. The same goes for the older hdx-oss-v2
chart.

Chart 1.x has no value for extra config files. ClickStack chart 3.4.0 and
later sets the TTLs, but chart 2.0 moved ClickHouse to an operator: that is a
migration, not an in-place upgrade. Until you migrate, add the TTL file with
a Kustomize post-renderer, which changes the chart's output on its way to the
cluster. Not tested yet; the file names are examples. In a folder of its own:

`clickhouse-ttl.xml`: the XML block from check 1 of your report.

`kustomization.yaml`:

```yaml
resources:
  - all.yaml
configMapGenerator:
  - name: clickhouse-ttl
    files:
      - clickhouse-ttl.xml
patches:
  - target:
      kind: Deployment
      name: .*-clickhouse
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: not-used
      spec:
        template:
          spec:
            volumes:
              - name: clickhouse-ttl
                configMap:
                  name: clickhouse-ttl
            containers:
              - name: clickhouse
                volumeMounts:
                  - name: clickhouse-ttl
                    mountPath: /etc/clickhouse-server/conf.d/clickhouse-ttl.xml
                    subPath: clickhouse-ttl.xml
                    readOnly: true
```

`kustomize.sh` (make it executable with `chmod +x kustomize.sh`):

```sh
#!/bin/sh
# helm pipes the rendered chart in and applies what comes out
set -e
cd "$(dirname "$0")"
cat > all.yaml
exec kubectl kustomize .      # runs locally, contacts no cluster
```

```sh
helm upgrade RELEASE REPO/CHART --version VERSION -n NAMESPACE -f values.yaml --post-renderer ./kustomize.sh
```

- Check the Deployment and container names first
  (`kubectl get deploy -n NAMESPACE`; the container is the one diskvet named
  on stderr) and change `name: .*-clickhouse` and `name: clickhouse` if they
  differ.
- Kustomize adds a hash of the file to the ConfigMap's name and updates the
  Deployment with it, so each change of the file restarts the pod.
- Every later `helm upgrade` of this release needs the same
  `--post-renderer`, or the file is gone again.
- The flag is for Helm 3. Helm 4 changed how post-renderers are passed:
  check `helm upgrade --help` before you use it.

### SigNoz

Source, partly: the SigNoz clickhouse chart's templates. They create a
`ClickHouseInstallation` (`clickhouse.altinity.com/v1`) for the Altinity
operator, with the container `clickhouse`, an optional `logs-system-exporter`
sidecar (diskvet picks the ClickHouse container by its image), the data
volume from `data-volumeclaim-template`, and the log volume template
commented out. That `configuration.files` of that resource comes from the
values key `clickhouse.files` is only partly confirmed.

*Not verified yet*: that diskvet's login (the `default` user from localhost
without a password) works, the TTL files the chart already ships, the
`clickhouse.clickhouseOperator.<log>.ttl` keys, the operator's
`01-clickhouse-*` file names and the image version.

Add to the values you deploy SigNoz with. The file name must sort after the
operator's `01-clickhouse-*` files:

```yaml
clickhouse:
  files:
    config.d/zz-diskvet-ttl.xml: |
      <clickhouse>
          <trace_log>
              <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
          </trace_log>
      </clickhouse>
```

Logs that already have a TTL from the chart are changed with
`clickhouse.clickhouseOperator.<log>.ttl` (days), never in that file: where
the chart defines a log with an `<engine>`, a separate `<ttl>` for it stops
ClickHouse from starting. The TTL of traces, logs and metrics themselves is
set in the SigNoz UI ([SigNoz recipe](signoz.md#retention-of-signoz-data)).

With the log volume template commented out, ClickHouse's server log files
are not on the data volume but in the container, that is on the node's disk
(*not verified yet*): see [Two kinds of "disk full"](#two-kinds-of-disk-full).

### Opik

*Not verified yet.* Opik's chart runs ClickHouse through the Altinity
operator. Put the TTL file into `clickhouse.configuration.files` of your
values, under `config.d/`, not `conf.d/`: conf.d files load before the
operator's files and lose.

```yaml
clickhouse:
  configuration:
    files:
      config.d/zz-diskvet-ttl.xml: |
        <clickhouse>
            <trace_log>
                <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
            </trace_log>
        </clickhouse>
```

### PostHog

*Not verified yet.* PostHog's chart runs ClickHouse through the Altinity
operator but has no key for extra config files. Use `clickhouse.settings`
instead, one entry per log, in the operator's `path/to/setting` form:

```yaml
clickhouse:
  settings:
    metric_log/ttl: "event_date + INTERVAL 7 DAY DELETE"
```

Never add `query_log` or `part_log` there.

### Your own ClickHouseInstallation

*Not verified yet.* With the Altinity operator and a ClickHouseInstallation
of your own (or one your chart renders), the file goes into
`spec.configuration.files`, named under `config.d/` (see [Opik](#opik) for
why not `conf.d/`):

```yaml
spec:
  configuration:
    files:
      config.d/zz-diskvet-ttl.xml: |
        <clickhouse>
            <trace_log>
                <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
            </trace_log>
        </clickhouse>
```

Change it in the Helm values or manifest that creates the resource.
`kubectl edit chi -n NAMESPACE NAME` works too, but the next `helm upgrade`
overwrites it. List its pods with
`kubectl get pods -n NAMESPACE -l clickhouse.altinity.com/chi=NAME`.

### trigger.dev

*Not verified yet.*

- **Chart 4.5.10 and later**: pod `trigger-clickhouse-0`, container
  `clickhouse`; diskvet logs in with its `CLICKHOUSE_USER` /
  `CLICKHOUSE_PASSWORD`.
  The TTL file goes into `clickhouse.configdFiles`:

  ```yaml
  clickhouse:
    configdFiles:
      clickhouse-ttl.xml: |
        <clickhouse>
            <trace_log>
                <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
            </trace_log>
        </clickhouse>
  ```

- **Chart up to 4.5.9**: the Bitnami ClickHouse chart 9.x as a subchart; pod
  `<release>-clickhouse-shard0-0`, login from `CLICKHOUSE_ADMIN_USER` and the
  file `CLICKHOUSE_ADMIN_PASSWORD_FILE` names. Use the block from
  [Bitnami chart 9.x](#bitnami-chart-9x) under `clickhouse:`.

### Laminar

*Not verified yet.* Pod `laminar-clickhouse-0`, container `clickhouse`;
diskvet logs in with its `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD`. We don't
know a values key for extra config files: see [Other charts](#other-charts).
Upstream issue:
[lmnr-ai/lmnr#2176](https://github.com/lmnr-ai/lmnr/issues/2176).

In s3 mode Laminar keeps ClickHouse's data in S3. diskvet skips remote disks
in `system.disks`, so checks 2 and 3 are about the pod's local volume only.
Check 1 still lists the system logs and their size, wherever they are
stored.

### Sentry

*Not verified yet.* Sentry's chart up to version 28 bundles the
sentry-kubernetes clickhouse chart: pod `sentry-clickhouse-0`, container
`sentry-clickhouse` (diskvet picks it by its image), the `default` user from
localhost. Config keys:

- Sentry chart up to 28: `clickhouse.clickhouse.configmap.configOverride`;
- the sentry-kubernetes clickhouse chart on its own:
  `clickhouse.configmap.configOverride`.

Look at your chart's values for what the key expects (a whole `<clickhouse>`
file or lines inside one) before you paste the report's block. Without a PVC
(`clickhouse.persistentVolumeClaim.enabled` in the clickhouse chart) the data
is on the node's disk. Sentry chart 29 and later expects an external
ClickHouse: see [ClickHouse outside the cluster](#clickhouse-outside-the-cluster).

### Plausible

*Not verified yet.* The IMIO Plausible chart uses the Bitnami ClickHouse
chart 7.x: pod `<release>-clickhouse-shard0-0`, login from
`CLICKHOUSE_ADMIN_USER` / `CLICKHOUSE_ADMIN_PASSWORD`. The report treats it
like Bitnami 8.x and prints an `extraOverrides` block; check with
`helm show values` that your chart version has that key. Persistence is
`persistence.enabled` of the ClickHouse chart; without it the data is on the
node's disk. For the zekker6 chart, it is not verified whether it has a value
for extra ClickHouse config; if not, see [Other charts](#other-charts).

### Bitnami chart 9.x

*Not verified yet*: everything in this section. The default is said to be
2 shards of 3 replicas (6 pods; `--k8s auto` refuses and prints 6 commands),
`usePasswordFiles=true` (diskvet reads the file
`CLICKHOUSE_ADMIN_PASSWORD_FILE` names, inside the pod), a `08-sampling.xml`
among the chart's config files, and `bitnamilegacy/clickhouse` images for
9.x.

The TTL file goes into `configdFiles`. Its name starts with `00-` so that it
loads before the chart's `08-sampling.xml` and logs the chart turned off stay
off (the loading order is *not verified yet*):

```yaml
configdFiles:
  00-diskvet-ttl.xml: |
    <clickhouse>
        <trace_log>
            <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
        </trace_log>
    </clickhouse>
```

As a subchart (trigger.dev up to 4.5.9), put it under `clickhouse:`.

Chart 9.1 and later turns most system logs off, but their old tables stay on
disk and never shrink. See which ones are no longer written (read-only), and
`DROP` those instead of giving them a TTL:

```sql
SELECT table, max(modification_time) AS last_write
FROM system.parts
WHERE database = 'system' AND active
GROUP BY table
ORDER BY last_write;
```

### Other charts

The TTL file has to reach the pod through the chart. Never copy it into the
running pod: it is gone after the next restart.

1. Look for a value that takes extra config files:
   `helm show values REPO/CHART --version VERSION | grep -n -i -E 'configd|config\.d|override|files|extravolume'`.
2. If the chart has only extra volumes (often `extraVolumes` and
   `extraVolumeMounts`; the names differ per chart), make a ConfigMap from the
   file and mount it with `subPath` into `conf.d`:

   ```sh
   kubectl create configmap clickhouse-ttl -n NAMESPACE --from-file=clickhouse-ttl.xml
   ```

   ```yaml
   extraVolumes:
     - name: clickhouse-ttl
       configMap:
         name: clickhouse-ttl
   extraVolumeMounts:
     - name: clickhouse-ttl
       mountPath: /etc/clickhouse-server/conf.d/clickhouse-ttl.xml
       subPath: clickhouse-ttl.xml
       readOnly: true
   ```

   `conf.d`, because many charts mount `config.d` as one ConfigMap. A file
   mounted with `subPath` does not change in a running pod when you edit the
   ConfigMap: restart the pod.
3. Otherwise, a Kustomize post-renderer as for
   [ClickStack chart 1.x](#clickstack-chart-1x), with the kind (`StatefulSet`
   or `Deployment`) and names of your chart.

### ClickHouse outside the cluster

Sentry chart 29 and later expects an external ClickHouse (*not verified
yet*), and ClickHouse Cloud and managed services have no pod you can exec
into. `--k8s` does not apply. If the external ClickHouse runs as a pod in a
cluster you can reach, use `--k8s NAMESPACE/POD` there; otherwise use a
clickhouse-client on a machine that reaches it, with a read-only user
(not tested with managed services):

```sh
sh diskvet.sh report --host HOST --port 9000 --user diskvet --password '...' > report.md
```

## Server log files

Besides its system log tables, ClickHouse writes server log files, rotated
by size (the `logger` setting). Where the chart takes YAML (the ClickHouse
operator), the logger block is in the Langfuse and ClickStack examples above.
Where it takes XML files, add a `<logger>` block to the same file as the
TTLs, inside `<clickhouse>`:

```xml
    <logger>
        <level>information</level>
        <size>100M</size>
        <count>10</count>
    </logger>
```

`size` is the size at which ClickHouse starts a new file, `count` the number
of old files it keeps (for the error log too). It applies after a restart.
To see the current size (read-only; use the container name from the
report):

```sh
kubectl exec -n NAMESPACE POD -c CONTAINER -- du -sh /var/log/clickhouse-server
```

Container console output is a different thing: the kubelet rotates it (by
default 10 MiB x 5 files per container, *not verified yet*), and it is on the
node's disk, not on ClickHouse's volume.

## Restarting the pod

A TTL change needs a ClickHouse restart. On Kubernetes it happens through
Helm, in this order.

**1. `helm upgrade` with your values.**

```sh
helm list -n NAMESPACE                                   # the release; CHART shows its name-version
helm get values RELEASE -n NAMESPACE -o yaml > values.yaml   # if you don't have your values file
# add the block from the report to values.yaml, then:
helm upgrade RELEASE REPO/CHART --version VERSION -n NAMESPACE -f values.yaml
```

Pass `--version` with the version you run: without it, helm takes the newest
chart, and that also upgrades Langfuse, SigNoz or ClickStack. Add
`--kube-context NAME` if you use another kubectl context.

- **Operator charts** (ClickHouse operator: Langfuse 2.x, ClickStack 2.x and
  later; Altinity operator: SigNoz, Opik, PostHog, your own
  ClickHouseInstallation): Helm changes the operator's resource, and the
  operator restarts the pod with the new config (*not verified yet*).
- **Charts without an operator** (Bitnami, trigger.dev, Laminar, Sentry,
  Plausible, ClickStack 1.x): Kubernetes restarts the pods only when their
  template changes. Many charts put a checksum of their config on the
  template for this; then a StatefulSet restarts its pods one at a time.
  Whether your chart does is *not verified yet*.

Look at the AGE column of `kubectl get pod -n NAMESPACE POD`: a pod that was
replaced is only minutes old.

**2. Never `kubectl rollout restart` on a StatefulSet an operator owns.** The
operator writes that StatefulSet's pod template itself. A `rollout restart`
changes the template behind its back; the operator can undo the change or
restart the pods a second time. To see who owns a StatefulSet:

```sh
kubectl get statefulset -n NAMESPACE -o 'custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[*].kind'
```

`ClickHouseCluster` or `ClickHouseInstallation` in the OWNER column means an
operator (that both operators set this owner is *not verified yet*; the
charts listed above as operator charts are operator-owned either way). For a
StatefulSet without an operator, `rollout restart` is fine, but step 3 works
for every chart.

**3. Last resort: delete the pod.** If the pod has not restarted within 5
minutes:

```sh
kubectl delete pod -n NAMESPACE POD
```

Its StatefulSet (or the operator) recreates it with the same name and the
same volume: about a minute of downtime; the data stays on the volume. (A
Deployment's new pod gets a new name.) With several pods, delete one at a
time, and go on only when `kubectl get pod -n NAMESPACE POD` shows it ready
again.

After the restart, ClickHouse renames each log whose TTL changed to
`<name>_0` and starts a new table. Run the report again: check 1 lists those
copies for Fix C.

## Two kinds of "disk full"

On Kubernetes "the disk is full" can mean two different disks.

| | The volume (PVC) is full | The node's disk is full |
|---|---|---|
| What fills it | ClickHouse's data and system logs; `backup/`, `shadow/` and `tmp/` in its data folder; with the ClickHouse operator probably its server log files too (*not verified yet*) | container images, container console logs, `emptyDir` volumes and whatever containers write outside a volume: ClickHouse without a PVC, or server log files with no volume of their own |
| What you see | ClickHouse errors `Code: 243` (`NOT_ENOUGH_SPACE`) on inserts and merges; the pod keeps running | the node's `DiskPressure` condition, then evicted pods (`The node was low on resource: ephemeral-storage`); a pod over its own `ephemeral-storage` limit is evicted too |
| What diskvet sees | this volume: checks 1 to 3 are about it | only when ClickHouse's data is on the node (the report then has a heads-up for a pod with no PVC); nothing about images or other pods |
| Where to look | the report, and `kubectl exec -n NAMESPACE POD -c CONTAINER -- df -h /var/lib/clickhouse` | `kubectl describe node NODE` (Conditions) and `kubectl get events -n NAMESPACE --field-selector reason=Evicted`; this needs read access to nodes and events |
| What helps | checks 1, 2 and 7 of the report; then [more room on the volume](#more-room-on-the-volume) | the server log files' logger (above); persistence on in the chart; a bigger node disk (ask whoever runs the nodes) |

`kubectl get pod -n NAMESPACE POD -o wide` shows the pod's node. When the
chart turns persistence on, existing data does not move to the new volume by
itself.

## More room on the volume

**Charts without an operator** (plain StatefulSets, Bitnami), if the
StorageClass allows it:

```sh
kubectl get pvc -n NAMESPACE                  # the pod's PVC, its size and StorageClass
kubectl get storageclass                      # that class needs ALLOWVOLUMEEXPANSION true
kubectl patch pvc -n NAMESPACE PVC -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

- It can't be undone: a volume never shrinks.
- Each pod of a StatefulSet has its own PVC; patch each one you want to grow.
- Leave the size in your Helm values as it is. A StatefulSet's
  `volumeClaimTemplates` can't be changed, so `helm upgrade` with a new size
  fails.
- If `kubectl get pvc` shows the new size but `df` in the pod does not,
  `kubectl describe pvc -n NAMESPACE PVC` may show `FileSystemResizePending`:
  that storage driver grows the file system only when the pod restarts.

**Operator charts** (ClickHouse operator, Altinity operator): *not verified
yet.* The volume belongs to the operator's resource, so the size is changed
there, through your Helm values. Whether either operator then grows the
existing PVCs is not verified yet, so the report prints no resize command for
them. Find the size key of your chart (for example
`helm show values langfuse/langfuse --version 2.1.2 | grep -n -B3 100Gi`),
change it, `helm upgrade`, and watch `kubectl get pvc -n NAMESPACE`. If the
PVC does not grow, patching it by hand may work, but the operator's resource
then still names the old size, and what the operator does with that is not
verified either.

## Permissions and port-forward

diskvet needs a Role in the ClickHouse pod's namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: diskvet, namespace: NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]        # list: only for --k8s auto
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create", "get"]      # get: API servers that authorize the WebSocket upgrade as GET (not verified yet)
```

A named pod (`--k8s NAMESPACE/POD`) needs only `get` on `pods`. Listing pods
in all namespaces is optional: without it, `--k8s auto` without `-n` looks in
your current namespace only and says so.

**`pods/exec` is effectively a shell in the ClickHouse pod.** Kubernetes can't
limit it to diskvet's calls: whoever has it can run any command in the pod,
read ClickHouse's files and the pod's environment, passwords included.

**Smaller: port-forward.** Put `pods/portforward` in the Role instead of
`pods/exec`, create the read-only user of
[variant B](../../README.md#two-ways-to-run-it-safely) (through the admin
login of your chart), and run diskvet with a clickhouse-client on your
machine:

```sh
kubectl port-forward -n NAMESPACE pod/POD 9000:9000     # leave it running
sh diskvet.sh report --host 127.0.0.1 --port 9000 --user diskvet --password '...' --save-raw raw.tsv > report.md
sh diskvet.sh report --replay raw.tsv --k8s NAMESPACE/POD --container CONTAINER > report-k8s.md
```

The first report's commands are for a plain server. The `--replay` line
connects to nothing: it renders the saved results as a report about the pod,
with `kubectl` lines. The password is then on your machine's command line,
not in the cluster; `--k8s` refuses `--password` because the exec request
URL would carry it into the API server's audit log.

## Troubleshooting

For discovery, login and exec errors see also
[README → Troubleshooting](../../README.md#troubleshooting).

- **The pod crash-loops after Fix B.** Read the previous log:
  `kubectl logs -n NAMESPACE POD -c CONTAINER --previous`. With
  `TTL parameters should be specified directly inside 'engine'`, that log is
  already defined with `<engine>` elsewhere (SigNoz: use its
  `clickhouseOperator.<log>.ttl` key): take it out of your values and
  upgrade again. With the ClickHouse operator, check that you pasted YAML,
  not XML.
- **The pod did not restart after `helm upgrade`.** See
  [Restarting the pod](#restarting-the-pod), step 3.
- **`helm upgrade` fails with `Forbidden: updates to statefulset spec`**
  (charts without an operator). The values change the volume size. Set it
  back, and grow the PVC instead
  ([more room on the volume](#more-room-on-the-volume)).
- **`*_log_0` tables after the restart.** Expected: they hold the old rows.
  Fix C of the next report drops them.
- **`found 3 ClickHouse pods`** (Langfuse 1.x) or 6 (Bitnami 9.x): one run
  per pod; the loop is in [Langfuse chart 1.x](#langfuse-chart-1x).
- **`no running ClickHouse pod found`**: a ClickHouse image with another name
  (pass `--k8s NAMESPACE/POD --container NAME`), a pod that is not Running,
  or ClickHouse [outside the cluster](#clickhouse-outside-the-cluster).
  diskvet skips Keeper, operator, backup and version-probe pods on purpose.
- **`Code: 516` with `--user U`** and the ClickHouse operator: the operator's
  client config also carries the `default` user's password, which
  clickhouse-client may then send for U (*not verified yet*). Leave out
  `--user`, or use port-forward.
- **Pods `Evicted`, node `DiskPressure`**: the node's disk, not the volume:
  see [Two kinds of "disk full"](#two-kinds-of-disk-full).
- **The rotated server log files are still there** after the `rm` line
  (check 2 of the report, or [Langfuse chart 2.x](#langfuse-chart-2x)): it
  deletes files named
  `*.log.*` (such as `clickhouse-server.log.0.gz`; *not verified yet*). List
  the folder with
  `kubectl exec -n NAMESPACE POD -c CONTAINER -- ls -l /var/log/clickhouse-server`.
- **`cannot hash table names`** (`--print-payload` only): `/tmp` in the pod
  is not writable, so the payload leaves your own tables out; `report` is not
  affected. ClickHouse operator PR #343 (merged 2026-09-23) makes the root
  file system read-only only for the operator's version-probe Job, not for
  the server pod; how older operator releases set it is *not verified yet*.
- **`kubectl exec timed out`**: `DISKVET_EXEC_TIMEOUT=300`; with an API server
  older than your kubectl, `KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false` (*not
  verified yet*).

---

Sources for every command: [README → Sources](../../README.md#sources). ClickHouse is a registered trademark of ClickHouse, Inc.; diskvet is not affiliated with ClickHouse, Inc. Langfuse, SigNoz, ClickStack and the other products named are trademarks of their respective owners.
