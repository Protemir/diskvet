# diskvet

[![ci](https://github.com/Protemir/diskvet/actions/workflows/ci.yml/badge.svg)](https://github.com/Protemir/diskvet/actions/workflows/ci.yml)

**A read-only disk check-up for ClickHouse®** — for the ClickHouse that runs
**inside** your self-hosted Langfuse, SigNoz or ClickStack. It finds what eats
the disk and prints the exact commands to fix it.

*diskvet is an independent project, not affiliated with or endorsed by
ClickHouse, Inc. See [Trademarks](#trademarks).*

The usual story: the disk fills up, but your own data is small.

- 66.86 GiB of `system.trace_log` next to about 51 MiB in the Langfuse tables (traces, observations, scores)
  ([langfuse#13123](https://github.com/langfuse/langfuse/issues/13123));
- 80+ GB of system logs next to less than 500 MB of telemetry
  ([SigNoz#12050](https://github.com/SigNoz/signoz/issues/12050));
- a 10 Gi volume full in 10 days
  ([ClickStack-helm-charts#275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275)).

ClickHouse does not limit its own logs by default. This script shows how big
they are and generates the fix, together with the traps that the fix hits in
practice (see [Known gotchas](#known-gotchas)).

Prefer to fix it by hand? Read the guide:
**[Why ClickHouse® fills the disk in self-hosted Langfuse and SigNoz, and how to fix it](docs/guide.md)**
— every command in it was run on ClickHouse 24.8, 25.12 and 26.9.
En español: [Por qué ClickHouse® llena el disco en Langfuse y SigNoz autoalojados](docs/es/guide.md).
Em português: [Por que o disco do ClickHouse® fica cheio no Langfuse e no SigNoz auto-hospedados](docs/pt/guide.md).
По-русски: [Почему ClickHouse® забивает диск в Langfuse и SigNoz на своём сервере](docs/ru/guide.md).
日本語：[セルフホストの Langfuse・SigNoz で ClickHouse® のディスクがいっぱいになる原因と対処法](docs/ja/guide.md)。
한국어: [셀프 호스팅 Langfuse와 SigNoz에서 ClickHouse® 디스크가 가득 차는 이유와 해결 방법](docs/ko/guide.md).
中文：[自托管 Langfuse 和 SigNoz：ClickHouse® 磁盘被占满的原因与解决方法](docs/zh/guide.md)。

Two files, both short enough to read before you run them:

| File | What it is |
|---|---|
| `checks.sql` | every query the script runs (plus one read-only probe): only `SELECT`, only `FROM system.*` |
| `diskvet.sh` | POSIX `sh` wrapper: runs the queries with `readonly=2`, renders the report |

Apache-2.0. No registration. The script talks only to your ClickHouse (or
`docker exec` into its container, or `kubectl exec` into its pod); nothing is
sent anywhere else.

## Quick start: Langfuse with docker compose (30 seconds)

On the machine where Langfuse's `docker-compose.yml` runs:

```sh
cd langfuse                     # the folder with Langfuse's docker-compose.yml
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS         # optional: both files match the release (macOS: shasum -a 256 -c)
less checks.sql                 # read it first: SELECTs from system.* only

sh diskvet.sh report --docker auto > report.md
```

`--docker auto` finds the container itself: the compose service `clickhouse` in
the current folder, otherwise the one running container whose image is
`clickhouse-server`. It runs `clickhouse-client` inside that container with
`docker exec -i`, so you need neither a ClickHouse client on the host nor an
open port. When you don't pass `--user`, it uses the container's own
`CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD` (Langfuse's compose sets them), and the
password never leaves the container.

Other ways to connect:

```sh
sh diskvet.sh report --docker signoz-clickhouse                # a container by name
sh diskvet.sh report --host 127.0.0.1 --user diskvet --password '...'   # local clickhouse-client
sh diskvet.sh report --k8s auto                                # the ClickHouse pod on Kubernetes
```

On Kubernetes, read [Kubernetes](#kubernetes) first: it says what diskvet
sends to the cluster and which permissions it needs.

## What it checks

| # | Check | From | WARN | CRITICAL |
|---|---|---|---|---|
| 1 | System logs without TTL | `system.tables`, `system.parts` | no TTL and ≥ 1 GiB or ≥ 5% of the disk; an old copy `*_log_N` ≥ 1 GiB; TTL set but rows older than TTL + 2 days | no TTL and ≥ 10 GiB or ≥ 15% of the disk |
| 2 | Disk space not in ClickHouse table parts | `system.disks` vs `bytes_on_disk` of all parts | ≥ 20% of the disk and ≥ 10 GiB | ≥ 30% of the disk and less than 20% free |
| 3 | Disk usage and rough forecast | `system.disks`, `system.asynchronous_metric_log` | ≥ 80% used or full in ≤ 14 days | ≥ 90% used, less than 5 GiB free, or full in ≤ 7 days |
| 4 | Growth per day | `system.part_log` (new parts in 24 h) | one table wrote ≥ 5% of the free space | ≥ 15% |
| 5 | Too many parts | `system.parts`, `system.merge_tree_settings`, `system.events` | ≥ 300 parts in a partition, or rejected inserts | ≥ the table's `parts_to_delay_insert` |
| 6 | Inactive and detached parts | `system.parts`, `system.detached_parts` | inactive parts stuck > 1 h; detached ≥ 1 GiB | stuck ≥ 10 GiB |
| 7 | Deleted rows and stuck mutations | `system.parts` (`has_lightweight_delete`), `system.mutations` | ≥ 10% of a table in parts with deleted rows; a mutation older than 60 min | ≥ 30% and ≥ 10 GiB; a failing mutation or one older than a day |

System logs without TTL between 100 MiB and 1 GiB are marked INFO. A check whose
query fails (old version, missing grant, no `part_log`) shows `NOT_RUN` with the
reason; the other checks still run.

The report also has a short passport: ClickHouse version, which product the
tables belong to (Langfuse, SigNoz, ClickStack or other, guessed from table
names), product data vs ClickHouse's own logs, and version-specific warnings.

Every problem comes with commands and how safe they are: `TRUNCATE` for the
logs (with the one-time flag when a table is over the 50 GB drop limit), a
generated `config.d` file with a TTL for every log that has none, the list of
old `*_log_N` copies to drop, Docker log rotation, `APPLY DELETED MASK` for
the exact partitions, `KILL MUTATION`, and `OPTIMIZE ... FINAL` only with a
warning. **Nothing runs by itself.**

## What it reads, and what it never reads

It reads metadata from these system tables: `system.tables`, `system.parts`,
`system.disks`, `system.detached_parts`, `system.merge_tree_settings`,
`system.mutations`, `system.part_log`, `system.asynchronous_metric_log`,
`system.asynchronous_metrics`, `system.events`, and, if allowed,
`system.server_settings` (only `max_table_size_to_drop`). Besides the queries
in `checks.sql` it sends one probe, `SELECT getSetting('readonly')`, to confirm
that the session is read-only.

It never reads:

- rows of your own tables: `FROM` / `JOIN` only the system tables above or
  subqueries, no comma joins, no `IN <table>`, no table functions, no
  `dictGet` / `joinGet`. `tests/check_sql.sh` enforces this in the test suite; it reads
  string literals and comments the way ClickHouse does, so a `--` inside a
  string or an escaped quote can't hide a query from it;
- `system.query_log`, query texts, mutation commands or error texts (for a
  mutation it only reads whether the last attempt failed).

The local report shows real database, table and partition names, because you
need them to run the fixes. It stays on your machine.

## Two ways to run it safely

**A. With an existing user.** The wrapper passes `--readonly=2` and limits:
`max_execution_time=30`, `max_result_rows=10000`, `result_overflow_mode=break`,
`max_threads=2`, `max_memory_usage=500000000`, `log_comment=diskvet`.
This guarantees that nothing is changed. What is read is exactly what you see
in `checks.sql`.

Before the checks the script asks the server whether the session really is
read-only. If the user's profile refuses the limit flags (a `readonly=1`
profile, or constraints on `max_threads` and the like), it runs with
`--readonly=1` alone and the user's own limits apply. If the server refuses
read-only mode for this user altogether, the script stops without running
anything (exit code 3). The first lines of the report say which case it was.

**B. With a dedicated user, for security reviews.** Only this guarantees that
product data can't be read. Since ClickHouse ~24.1 reading `system.*` needs
explicit grants (`select_from_system_db_requires_grant`), so they are listed:

```sql
CREATE SETTINGS PROFILE IF NOT EXISTS diskvet_profile SETTINGS
    readonly = 1, max_execution_time = 30, max_result_rows = 10000,
    result_overflow_mode = 'break', max_threads = 2, max_memory_usage = 500000000;

CREATE USER IF NOT EXISTS diskvet
    IDENTIFIED WITH sha256_password BY '<long random password>'
    HOST LOCAL
    SETTINGS PROFILE 'diskvet_profile';

GRANT SHOW TABLES ON *.* TO diskvet;   -- table metadata only, NOT data
GRANT SELECT ON system.parts TO diskvet;
GRANT SELECT ON system.disks TO diskvet;
GRANT SELECT ON system.merge_tree_settings TO diskvet;
GRANT SELECT ON system.mutations TO diskvet;
GRANT SELECT ON system.detached_parts TO diskvet;
GRANT SELECT ON system.part_log TO diskvet;
GRANT SELECT ON system.asynchronous_metric_log TO diskvet;
GRANT SELECT ON system.asynchronous_metrics TO diskvet;
GRANT SELECT ON system.events TO diskvet;
```

```sh
sh diskvet.sh report --docker auto --user diskvet --password '<long random password>'
```

On Kubernetes, `--k8s` refuses `--password`; use this user through
`kubectl port-forward` instead (see [Permissions](#permissions)).

`GRANT SELECT ON system.*` is not given on purpose: `system.query_log` holds the
query texts of all users.

What we saw with this user on ClickHouse 24.8, 25.12 and 26.9:

- a `readonly=1` profile refuses `--readonly=2` and the limit flags, so the
  script notices it and runs with `--readonly=1` only: the profile's own
  limits apply;
- `SHOW TABLES ON *.*` is enough to see the parts of product tables in
  `system.parts` and the tables in `system.tables`, but `SELECT` on a product
  table and on `system.query_log` is refused;
- `system.server_settings` is not granted, so the report assumes the default
  drop limit (50 GB) and says so. Add `GRANT SELECT ON system.server_settings`
  if you changed `max_table_size_to_drop`.

## Kubernetes

`--k8s` does what `--docker` does, with `kubectl exec -i` instead of
`docker exec -i`: it runs `clickhouse-client` inside the ClickHouse pod. You
need `kubectl` with a context for the cluster and the
[permissions](#permissions) below. Nothing is copied into the pod, no port is
opened, and you need no ClickHouse client on your machine.

Chart by chart (Langfuse, SigNoz, ClickStack, Bitnami, trigger.dev and
more): which pod diskvet finds, how it logs in, which Helm values take the
fixes, how the pod restarts, and a full volume versus a full node disk:
[Kubernetes: ClickHouse chart by chart](docs/recipes/kubernetes.md).

**Not tested on a real cluster yet.** So far the test suite runs `--k8s` only
against a fake `kubectl` (see [Tested on](#tested-on)); a test job on a real
cluster comes next. If you try it, an
[issue](https://github.com/Protemir/diskvet/issues/new/choose) with what you
saw helps a lot.

### Quick start on Kubernetes

Download the files as in the
[quick start](#quick-start-langfuse-with-docker-compose-30-seconds), on any
machine where `kubectl` works, then:

```sh
sh diskvet.sh report --k8s auto > report.md                  # the one ClickHouse pod you can see
sh diskvet.sh report --k8s auto -n langfuse > report.md      # only in namespace langfuse
sh diskvet.sh report --k8s langfuse/langfuse-clickhouse-0-0-0 > report.md
sh diskvet.sh report --k8s signoz/chi-signoz-clickhouse-cluster-0-0-0 --context prod-eu > report.md
sh diskvet.sh --print-payload --k8s auto -n trigger --env ./diskvet.env
sh diskvet.sh report --replay raw.tsv          # a --save-raw file from a --k8s run
```

- `--k8s auto` looks at the running pods in every namespace you may list (or
  only in `-n NS`) and takes the pod that has exactly one container with the
  image `clickhouse-server`, `clickhouse` or `bitnami*/clickhouse` (from any
  registry). It skips ClickHouse Keeper, operator, backup and version-probe
  pods, and pods run by a Job. If it finds several pods, it runs nothing: see
  [One pod per run](#one-pod-per-run).
- `--k8s NS/POD` names the pod (`--k8s POD`: in the context's current
  namespace; `pod/NAME` from `kubectl get pods -o name` works too).
  `--container NAME` picks the container when its image has another name.
  `--context NAME` uses another kubectl context.
- Before the first query diskvet names the pod on stderr, then runs without
  asking anything, so it can run from cron:

  ```text
  diskvet: kubectl context kind-dev · pod langfuse/langfuse-clickhouse-0-0-0 · container clickhouse-server
  ```

  The context is read once and passed to every kubectl call, so a
  `kubectl config use-context` in another terminal can't move a running check
  to another cluster. The report names the context only if you typed
  `--context`, so a cloud context name (an EKS ARN, say) doesn't end up in a
  report you share.
- The shell commands in the report are complete `kubectl` lines for that pod,
  for example
  `kubectl exec -n langfuse langfuse-clickhouse-0-0-0 -c clickhouse-server -- sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'`.
  Config changes go into your Helm values (or the operator's resource), never
  into files in the pod: Helm and the operators rewrite those. The keys per
  chart: [docs/recipes/kubernetes.md](docs/recipes/kubernetes.md).

### What diskvet sends to the cluster

Only these kubectl calls, each with `--context C` when there is a current
context:

1. `kubectl config current-context`, once, unless you pass `--context`.
2. `kubectl get pods` for `--k8s auto` (with `-A`, or `-n NS`; a second call
   without `-A` only after a Forbidden), or `kubectl get pod POD` for a named
   pod. Both use `--request-timeout=30s` and `-o custom-columns=...`: they
   read names, phases, images, volume claims, owner kinds and four labels,
   never env values and never Secrets.
3. `kubectl exec`, once for the probe and once per query: about 14 calls for
   `report`, 16 for `--print-payload`. Each has this shape (`explicit` instead
   of `env` when you pass `--user`):

   ```text
   kubectl --context C exec -i -n NS POD -c CTR -- sh -c '<login script>' sh env --readonly=2 --max_execution_time=30 --max_result_rows=10000 --result_overflow_mode=break --max_threads=2 --max_memory_usage=500000000 --log_comment=diskvet --format=TSV [--host H] [--port P] [--user U]
   ```

   With `--print-payload` one of them runs `clickhouse local` in the pod
   instead, to hash names (see
   [`--print-payload`](#--print-payload-what-a-snapshot-would-contain)).

- No TTY: `-i`, never `-t`. `sh -c` only picks the login and starts
  `clickhouse-client` (or `clickhouse local`). The SQL goes in on stdin and
  the results come back on stdout: only the SELECTs of `checks.sql`, with
  `readonly=2` and the limits, marked `log_comment = 'diskvet'` in
  `system.query_log`.
- Never `cp`, `debug`, `attach`, `port-forward`, `apply`, `patch`, `edit`,
  `delete`, `scale`, `rollout`, `logs` or `get secret`. Nothing is written to
  the cluster; the only thing written in the pod is `clickhouse local`'s
  temporary folder under `/tmp` with `--print-payload`, as with `--docker`.
- Every call to the API server has a time limit: 30 s for `get`, 120 s for
  each `exec` (set `DISKVET_EXEC_TIMEOUT` to other seconds, 5 or more). After
  one exec timed out, diskvet makes no more calls, and the checks left show
  `NOT_RUN`.

### How diskvet logs in

Inside the pod, a short `sh` script (`inner` in `diskvet.sh`) picks the login,
in this order:

1. `--user U`, if you pass it. With `--k8s` only the user name is passed
   (`--password` is refused, see below), so this is for a user that needs no
   password from inside the pod.
2. The pod's `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD`: the variables of the
   official ClickHouse image, as in plain manifests.
3. Bitnami's `CLICKHOUSE_ADMIN_USER` with `CLICKHOUSE_ADMIN_PASSWORD`, or with
   the file that `CLICKHOUSE_ADMIN_PASSWORD_FILE` names: the Bitnami ClickHouse
   chart, which Langfuse chart 1.x uses.
4. None of them: no `--user` and no `--password`, so clickhouse-client uses its
   own config in the pod. With the ClickHouse operator (Langfuse chart 2.x,
   ClickStack chart 2.x and later) that is the config the operator writes to
   `/etc/clickhouse-client/`: user `default`, port 9001, the password from the
   pod's env. With the Altinity operator (SigNoz) it is the `default` user
   without a password from localhost (not verified yet).

diskvet never sends `--user default --password ''`, which would override that
config. The password is read inside the pod and stays there (in the pod's env
and in clickhouse-client's command line in the pod), as with `--docker`. It is
not on your machine's command line, not in the exec request and not in the
audit log. diskvet never reads a Secret and needs no permission on Secrets.
The first lines of the report name the user ClickHouse ran the queries as
(`· user default`).

### What the API server's audit log shows

With audit logging on, each `kubectl exec` is an entry for the pod's `exec`
subresource (`pods/exec`) in its namespace, by your kubectl user. kubectl
sends the command line as `command=` parameters of the request URL, so the log's
`requestURI` holds the exec line above: the login script (it names the
variables, never their values), the read-only flags, the `--host`, `--port`
and `--user` you passed, and for `--print-payload` the constant hashing query.
It never holds a password, the salt, the SQL of the checks or a result: those
go through the exec stream (stdin and stdout), and the audit log records the
request, not the stream. That is why `--password` is refused with `--k8s`: it
would be part of that URL. (This is how kubectl and the API server work; it is
not checked against a real audit log yet.)

Runtime security tools and audit alerts often watch for `kubectl exec` into
production pods and for a shell started in a container. They may flag every
diskvet run, even without a TTY. Tell whoever watches them before you schedule
it.

### One pod per run

Each ClickHouse pod has its own disk and its own system logs, so diskvet
checks one pod per run. When `--k8s auto` finds several (Langfuse chart 1.x
runs 3 replicas by default), it runs nothing, exits with code 2 and prints one
command per pod:

```text
diskvet: found 3 ClickHouse pods. Each has its own disk and system logs, so diskvet checks one pod per run:
  sh diskvet.sh report --k8s langfuse/langfuse-clickhouse-shard0-0 > report-langfuse-clickhouse-shard0-0.md
  sh diskvet.sh report --k8s langfuse/langfuse-clickhouse-shard0-1 > report-langfuse-clickhouse-shard0-1.md
  sh diskvet.sh report --k8s langfuse/langfuse-clickhouse-shard0-2 > report-langfuse-clickhouse-shard0-2.md
```

Run each of them, or all in a loop:

```sh
for pod in langfuse-clickhouse-shard0-0 langfuse-clickhouse-shard0-1 langfuse-clickhouse-shard0-2; do
    sh diskvet.sh report --k8s "langfuse/$pod" > "report-$pod.md"
done
```

The TTL fix (Fix B, in your chart values) covers every pod; Fix A and Fix C
of check 1 are per pod.

### `--save-raw` on Kubernetes

A `--save-raw` file from a `--k8s` run also names the pod the report is about,
because the report prints it into its commands: namespace, pod, container and
PVC names, the operator's cluster or installation name, and the context if
you typed `--context`. Look at the file before you attach it to a public
issue. `sh diskvet.sh report --replay FILE` renders the same Kubernetes report
from it, without kubectl.

### Permissions

A Role in the ClickHouse pod's namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: diskvet, namespace: NS}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]        # list: only for --k8s auto
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create", "get"]      # get: API servers that authorize the WebSocket upgrade as GET (unverified)
```

Bind it to the user or ServiceAccount that runs diskvet, for example
`kubectl create rolebinding diskvet --role=diskvet --user=<user> -n NS` (or
`--serviceaccount=NS:NAME` instead of `--user`).

**`pods/exec` is effectively a shell in the ClickHouse pod.** diskvet uses it
only for the calls listed above, but Kubernetes can't limit it to them:
whoever has it can run any command in the pod as the pod's user, read
ClickHouse's data files and the pod's environment, passwords included. Grant
it only to people and accounts that may have that access anyway.

**Smaller: port-forward.** To grant no shell, put `pods/portforward` in the
Role instead of `pods/exec`, create the read-only user of
[variant B](#two-ways-to-run-it-safely), and run diskvet with a
clickhouse-client on your machine:

```sh
kubectl port-forward -n langfuse pod/langfuse-clickhouse-0-0-0 9000:9000   # leave it running
sh diskvet.sh report --host 127.0.0.1 --port 9000 --user diskvet --password '<long random password>' --save-raw raw.tsv > report.md
```

The password is then on your machine's command line, not in the cluster. That
report's shell commands are written for a plain server (`sudo sh -c '...'`,
and Docker advice in check 2). For `kubectl` lines instead, render the saved
results as a report about the pod; this connects to nothing (`--container`
defaults to `clickhouse` here):

```sh
sh diskvet.sh report --replay raw.tsv --k8s langfuse/langfuse-clickhouse-0-0-0 --container clickhouse-server > report.md
```

Listing pods in all namespaces is optional. With only the Role,
`--k8s auto` without `-n` prints `not allowed to list pods in all namespaces;
looking in your current namespace only (pass -n NAMESPACE to choose)` and
looks there; a ClusterRole with `list` on `pods` lets it look everywhere. A
named pod (`--k8s NS/POD`) needs only `get` on `pods`, plus `pods/exec`.

### Troubleshooting

diskvet stops with exit code 2 when it can't find or name the pod, and with 3
when it can't run the queries; with `--print-payload`, stdout then holds one
`"status": "ch_unreachable"` line.

- **`Error from server (Forbidden)` ... `"pods/exec"`**: your kubectl user may
  not exec into pods in that namespace. Add the Role above, or use
  port-forward.
- **`found N ClickHouse pods`**: see [One pod per run](#one-pod-per-run).
- **`no running ClickHouse pod found`**: pass `--k8s NAMESPACE/POD`, and
  `--container NAME` when the ClickHouse image has another name.
  **`pod NS/POD is Pending, not Running`**: wait for the pod.
- **`Code: 516` (authentication failed)**: ClickHouse refused the pod's own
  login. Pass `--user` for a user that needs no password from inside the pod,
  or use port-forward with `--user` and `--password`. With the ClickHouse
  operator, `--user U` alone may be refused as well: the config the operator
  writes for clickhouse-client also carries the `default` user's password,
  which clickhouse-client would then send for U (not verified yet).
- **`executable file not found`**: the container has no `sh` (a distroless
  image). Use port-forward.
- **`clickhouse-client: not found`**: diskvet is in the wrong container. Pass
  `--container NAME`.
- **`cannot hash table names, so the payload has no tables`**
  (`--print-payload` only): `clickhouse local` could not run in the pod's
  `/tmp`, for example with a read-only root file system and no writable
  `/tmp`. The payload then leaves your own tables out instead of sending their
  names; `report` is not affected.
- **`kubectl exec timed out after 120 s`**: the API server or the pod did not
  answer. Wait longer with `DISKVET_EXEC_TIMEOUT=300 sh diskvet.sh ...`. If your
  API server is older than your kubectl, try
  `KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false sh diskvet.sh ...` (kubectl then
  uses its older SPDY protocol for exec).
- **`cannot read kubectl's output (unexpected columns)`**: please
  [open an issue](https://github.com/Protemir/diskvet/issues/new/choose) with
  the output of `kubectl version`.

After the fixes (a pod that crash-loops or does not restart, a volume to
grow, evicted pods on a full node):
[Kubernetes: ClickHouse chart by chart → Troubleshooting](docs/recipes/kubernetes.md#troubleshooting).

## Example report (shortened)

````markdown
# ClickHouse check-up · 2026-10-09 06:40 UTC
diskvet 0.2.2 · ClickHouse 25.12.1.649 · detected: Langfuse · container langfuse-clickhouse-1
Nothing was changed. Nothing was sent anywhere. Queries ran with readonly=2 and resource limits.

| # | Check | Status |
|---|---|---|
| 1 | System logs without TTL | CRITICAL |
| 2 | Disk space not in ClickHouse table parts | WARN |
| 3 | Disk usage and rough forecast | WARN |
| 4 | Growth per day | WARN |
| 5 | Too many parts | OK |
| 6 | Inactive and detached parts | OK |
| 7 | Deleted rows and stuck mutations | WARN |

## 1. System logs without TTL: CRITICAL

88.7 GiB of ClickHouse's own logs vs 5.4 GiB of Langfuse data. 6 logs have no TTL (79.1 GiB together).

| Table | Size | Rows | TTL | Oldest row | Status |
|---|---|---|---|---|---|
| system.trace_log | 58.3 GiB | 912.3M | none | 212 d | CRITICAL |
| system.text_log | 14.2 GiB | 45.1M | none | 212 d | CRITICAL |
| system.query_log | 6.1 GiB | 9.1M | none | 212 d | WARN |
| system.trace_log_0 | 2.0 GiB | 31.2M | old copy | 300 d | WARN |

**Fix A: free space now.** Safe for your data, no restart: it deletes only ClickHouse's own log rows.
```sql
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.query_log;
```
system.trace_log (58.3 GiB) is over the drop limit (max_table_size_to_drop = 50 GB), so ClickHouse
refuses a plain TRUNCATE. Create the one-time flag right before it (the first TRUNCATE that needs the flag uses it up; create it again before the next big table):
```sh
docker exec langfuse-clickhouse-1 sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```
```sql
TRUNCATE TABLE system.trace_log;
```

**Fix B: stop it coming back.** Safe; needs a ClickHouse restart (about 10 s). Keeps 7 days of each log.
Save as `clickhouse-ttl.xml` ...
…
---
This is a snapshot. It can't tell when the disk will really run out, or whether your trace_log is normal for a Langfuse of your size.
Want an email before the disk fills? Join early access (free beta): https://github.com/Protemir/diskvet#early-access
````

The full example is what `sh diskvet.sh report --replay tests/fixtures/alex.tsv`
prints.

## `--print-payload`: what a snapshot would contain

```sh
sh diskvet.sh --print-payload --docker auto
```

prints the JSON that a future hourly snapshot would send, so you can review it
before anything is ever sent. **Sending is not implemented**: `push` only says
"not available yet".

- Only the fields listed in `tests/payload_keys.txt`: sizes, row and part
  counts, TTL, insert limits, counters, disk size and free space, product and
  ClickHouse version. `tests/check_payload.sh` fails on any other key.
- Never: host names, IPs, ClickHouse cluster names, users, paths, UUIDs,
  `engine_full`, query texts, mutation ids or commands, error texts, partition
  names or values, Kubernetes namespace, pod, container, volume or context
  names.
- Names of system tables and of known Langfuse, SigNoz and ClickStack tables
  are kept. Every other database and table name becomes a salted hash:
  `db_` / `t_` + 16 hex digits of `sipHash64(salt, name)`. The hash is computed
  by `clickhouse local` on your side (inside the container with `--docker`,
  inside the pod with `--k8s`), which gets the salt on stdin: the salt never
  reaches the ClickHouse server, so it is not in `system.query_log`,
  `system.text_log`, the server log files or the process list. With `--k8s`
  the salt passes the API server inside the exec stream, over TLS; the audit
  log records the exec request, not the stream, so the salt is not in the
  audit log either. Disks other than `default` become `disk_1`, `disk_2`, ...
- The salt lives only on your server, in `/etc/diskvet.env`
  (`--env` to change), as `SALT=<64 hex chars>` (at least 32 characters, or
  the script refuses it):

  ```sh
  (umask 077; printf 'SALT=%s\n' "$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')" > /etc/diskvet.env)
  ```

  Without the file the script uses a one-time random salt and says so on
  stderr. **Keep the file:** a new salt gives new hashes, and the history of
  your own tables starts from zero.

## Known gotchas

These are the traps the report handles for you. Each was checked on ClickHouse
24.8, 25.12 and 26.9 in Docker (`tests/run.sh`).

- **TRUNCATE refuses tables over 50 GB.** `max_table_size_to_drop` (default
  50 GB = 46.6 GiB) also applies to `TRUNCATE` and `DROP` of system logs. Create
  `/var/lib/clickhouse/flags/force_drop_table` (with `chmod 666`, the server
  deletes it) right before the command. The first command that needs the flag uses it up, so create
  it again before the next big table. The size that counts is the sum of
  `bytes_on_disk` of the active parts, and only a table bigger than the limit
  is refused; the report shows the flag already from 95% of the limit. On
  ClickHouse 24.1 and newer this also works without the flag (tested on 24.1,
  24.3, 24.8, 25.12, 26.9):
  `TRUNCATE TABLE system.trace_log SETTINGS max_table_size_to_drop = 0`, and the
  same `SETTINGS` for `DROP TABLE`.
- **A TTL change creates `*_log_N` copies.** `<ttl>` in `config.d` needs a
  restart (`SYSTEM RELOAD CONFIG` is not enough). On restart ClickHouse renames
  the old table to `trace_log_0` (then `_1`, ...) with all its rows and starts
  a new one. So truncate first, restart second, drop the copies third. The
  report lists the copies from `system.tables`, not from a fixed list.
- **`opentelemetry_span_log` is special.** The default server config defines it
  with `<engine>`. A plain `<ttl>` for it stops ClickHouse from starting:
  `If 'engine' is specified for system table, TTL parameters should be specified
  directly inside 'engine'`. The generated file puts its TTL inside `<engine>`
  (on `finish_date`). If your own config defines other logs with `<engine>`, do
  the same for them.
- **Docker container logs.** Space outside ClickHouse's parts is often Docker's
  `*-json.log` without rotation
  ([langfuse#16339](https://github.com/langfuse/langfuse/issues/16339): 89.1 GiB).
  The script can't see these files; check 2 shows how much is outside and how
  to rotate.
- **Lightweight deletes keep the space.** `DELETE FROM` only marks rows; the
  space comes back when the part is merged or the mask is applied. Old
  partitions are rarely merged. The report prints `APPLY DELETED MASK IN
  PARTITION ID '...'` for the exact partitions (only locally). The script can't
  count deleted rows without reading your data, so it shows the share of the
  table in affected parts, an upper bound.
- **Langfuse + ClickHouse 26.8+: update Langfuse first.** Older Langfuse sends
  DateTime64 values as JSON numbers; ClickHouse 26.8+ reads them differently and
  stores `9999-12-31 23:59:59`
  ([langfuse#16858](https://github.com/langfuse/langfuse/issues/16858), fixed in
  [PR #16892](https://github.com/langfuse/langfuse/pull/16892)). We reproduced
  it on 26.9: the row lands in partition `999912`, while 24.8 and 25.12 store the
  right date. The report counts such partitions and warns before the upgrade.
- **ClickHouse 24.x `part_log` has no rows for system tables**, so check 4 can't
  show the growth of ClickHouse's own logs there (25.12 and 26.9 do record them).
- **`free_space` already subtracts `keep_free_space_bytes`**, and so does
  `total_space`: with 1 GiB of `keep_free_space_bytes`, `system.disks` showed
  `total_space` exactly 1 GiB below `df`'s size and `free_space` about 1 GiB
  below `df`'s available space. The script uses the values as they are, so its
  percentages can differ from `df` by that amount. Also, `free_space` is what a
  non-root user may still write: on ext4 about 5% of the disk is reserved for
  root, so "used" in the report is `df`'s used plus that reserve (51 GiB on our
  1 TB test disk), and check 2 counts the reserve as "not in table parts".
- **`DelayedInserts` / `RejectedInserts` count only since the last restart**
  (`system.events` is reset), and they show up only after the first event. The
  report says "since the server started".

## Tested on

| ClickHouse | Image | Shells | Coverage |
|---|---|---|---|
| 24.8.14.39 | `clickhouse/clickhouse-server:24.8` | Git Bash (Windows), dash + mawk | full `tests/run.sh` |
| 25.12.11.4 | `clickhouse/clickhouse-server:25.12` | Git Bash, dash + mawk, busybox ash + busybox awk | full `tests/run.sh` |
| 26.9.1.1629 | `clickhouse/clickhouse-server:latest` | Git Bash, dash + mawk, busybox ash + busybox awk | full `tests/run.sh` |
| 24.8.14.39 | `clickhouse/clickhouse-server:24.8-alpine` | busybox ash + busybox awk | report and payload run, no seeded problems |
| 24.1.2.5 | `clickhouse/clickhouse-server:24.1.2-alpine` (SigNoz's) | busybox ash + busybox awk | report and payload run; a fresh 24.1 has no `part_log` until the first flush, check 4 then falls back to `system.parts`. By hand: `TRUNCATE` / `DROP ... SETTINGS max_table_size_to_drop = 0` and `APPLY DELETED MASK IN PARTITION ID` work (24.3 too for the first) |

A clean server with nothing seeded (fresh container, default config) gets OK on
all seven checks on 24.1, 24.8, 25.12 and 26.9.

`--k8s` has not run on a real Kubernetes cluster yet. What tests it so far:

| Test | Instead of a cluster | Shells | Coverage |
|---|---|---|---|
| `tests/k8s_offline.sh` (run by `tests/replay.sh`) | a fake `kubectl` (`tests/fixtures/fake-kubectl/`) that lists hand-written pods (ClickHouse operator, Bitnami, Altinity, plain, sidecars; not recorded from a real cluster yet) and runs every exec, login script included, in the test's own shell; a fake clickhouse-client answers from the fixtures | dash + mawk, busybox ash + busybox awk | finding the pod and every refusal, argument checks, each login branch, the exact kubectl argv with the pinned context, timeouts, error hints, the Kubernetes report text, payload privacy, `--save-raw` and `--replay` |
| `tests/k8s_shim.sh` (run by `tests/run.sh`) | the same fake `kubectl`, whose exec becomes `docker exec -u 101:101` into the test's ClickHouse container | Git Bash | a real ClickHouse 25.12: the same statuses as `--docker`, logins with `CLICKHOUSE_USER` and with Bitnami's admin variables (password in env and in a file), only read-only SELECTs in `query_log`, names hashed in the container, no salt or password in any kubectl command line, and the printed `kubectl exec` flag line works as uid 101 |

Not tested yet: a real Langfuse, SigNoz or ClickStack install, replicated
clusters, a real Kubernetes cluster (so no Helm chart, operator, API server or
`kubectl` version), disks on object storage (the script skips remote disks),
macOS.

## Requirements

- POSIX `sh` (dash, busybox ash, bash), `awk` (gawk, mawk, busybox awk), `sed`,
  `od`, `date`. No `jq`, no Python.
- `docker` for `--docker`, `kubectl` for `--k8s` (with the
  [permissions](#permissions) above), or `clickhouse-client` /
  `clickhouse client` on the machine for `--host`.
- For `--print-payload` also `clickhouse local` (to hash names): it is in every
  ClickHouse image and package; with `--docker` the container's copy is used,
  with `--k8s` the pod's.
- ClickHouse 24.8 or newer is what the test suite covers (24.1 also runs, see [Tested on](#tested-on)).

## Development

```sh
sh tests/replay.sh              # offline: fixtures, SQL safety, payload privacy, --k8s
sh tests/k8s_offline.sh         # offline: --k8s with the fake kubectl (replay.sh runs it too)
sh tests/check_sql.sh           # checks.sql: SELECT from the allowed system tables only
sh tests/run.sh                 # Docker: ClickHouse 24.8, 25.12, latest (~2 min each)
sh tests/auto.sh                # Docker: --docker auto with a Langfuse-like compose file
```

The `--k8s` tests never contact a cluster: they put the fake `kubectl` first
on `PATH`, set `KUBECONFIG=/dev/null`, and stop if another `kubectl` would run.

`tests/run.sh` seeds each server with the problems above, runs the script from
the host and inside the container (dash, busybox), with `--k8s` through the
fake `kubectl` (`tests/k8s_shim.sh`), as Variant B and as users
with setting constraints, checks in `system.query_log` that every query ran
read-only and that the salt never reached the server, then runs the fix
commands from the report (both the flag and the `SETTINGS` variant for tables
over the drop limit) and checks that they work. `tests/auto.sh` starts
a compose service named `clickhouse` with `CLICKHOUSE_USER` /
`CLICKHOUSE_PASSWORD`, like Langfuse's, and checks in `system.query_log` that
the script ran as that user and sent only `SELECT` queries.

The site ([diskvet.dev](https://diskvet.dev/)) is `docs/`, served by GitHub
Pages, in seven languages. The guide pages (`docs/guide/`, `docs/<xx>/guide/`)
and `docs/sitemap.xml` are generated from the Markdown guides; after editing
`docs/guide.md` or a translation, run `node tools/build-guides.mjs` (Node 18+
and a logged-in `gh`, which renders the Markdown).

## Early access

The script is free and stays free. Separately, I'm building the part a
one-off run can't do: an hourly snapshot (exactly the `--print-payload` JSON,
nothing more), an email **before** the disk fills, a signal when snapshots stop
arriving, and a short weekly report. It opens in October 2026 and is free: no
card, no plan to pick.

**Want in? Comment in [Early access (discussion #1)](https://github.com/Protemir/diskvet/discussions/1)**
with what runs your ClickHouse and roughly how big the disk is; you'll get a
reply there when the beta opens. Found a problem the script misses, or a wrong
fix? [Open an issue](https://github.com/Protemir/diskvet/issues/new/choose) —
that's the most useful thing you can do.

## Sources

Every fix the report suggests comes from public documentation or public issues:

| Topic | Source |
|---|---|
| System logs have no size limit by default; `*_log_N` copies after a schema or config change | [System tables overview](https://clickhouse.com/docs/operations/system-tables/overview) |
| `<ttl>` and `<engine>` for system logs in `config.d` | [Server settings: query_log and other logs](https://clickhouse.com/docs/operations/server-configuration-parameters/settings); the `opentelemetry_span_log` trap: [ClickHouse#88366](https://github.com/ClickHouse/ClickHouse/issues/88366) |
| `TRUNCATE`, the 50 GB drop limit and the `force_drop_table` flag | [TRUNCATE](https://clickhouse.com/docs/sql-reference/statements/truncate), [`max_table_size_to_drop` (server)](https://clickhouse.com/docs/operations/server-configuration-parameters/settings), [`max_table_size_to_drop` (query setting)](https://clickhouse.com/docs/operations/settings/settings) |
| Parts, active/inactive, `has_lightweight_delete` | [system.parts](https://clickhouse.com/docs/operations/system-tables/parts) |
| Disk size and free space | [system.disks](https://clickhouse.com/docs/operations/system-tables/disks) |
| Growth in the last 24 h | [system.part_log](https://clickhouse.com/docs/operations/system-tables/part_log) |
| Rough disk forecast | [system.asynchronous_metric_log](https://clickhouse.com/docs/operations/system-tables/asynchronous_metric_log) |
| Too many parts: `parts_to_delay_insert`, `parts_to_throw_insert` | [MergeTree settings](https://clickhouse.com/docs/operations/settings/merge-tree-settings) |
| Lightweight deletes and `APPLY DELETED MASK` | [DELETE](https://clickhouse.com/docs/sql-reference/statements/delete), [APPLY DELETED MASK](https://clickhouse.com/docs/sql-reference/statements/alter/apply-deleted-mask) |
| Stuck mutations, `KILL MUTATION` | [system.mutations](https://clickhouse.com/docs/operations/system-tables/mutations), [KILL](https://clickhouse.com/docs/sql-reference/statements/kill) |
| Detached parts, `DROP DETACHED PART` | [Manipulating partitions and parts](https://clickhouse.com/docs/sql-reference/statements/alter/partition) |
| `readonly` levels | [Permissions for queries](https://clickhouse.com/docs/operations/settings/permissions-for-queries) |
| Grants for the dedicated user | [GRANT](https://clickhouse.com/docs/sql-reference/statements/grant) |
| Hashing names on your side | [clickhouse-local](https://clickhouse.com/docs/operations/utilities/clickhouse-local), [sipHash64](https://clickhouse.com/docs/sql-reference/functions/hash-functions) |
| Docker log rotation | [json-file logging driver](https://docs.docker.com/engine/logging/drivers/json-file/) |

The version-specific behaviour listed under [Known gotchas](#known-gotchas) was
reproduced on stock `clickhouse/clickhouse-server` images by `tests/run.sh`.

## Trademarks

ClickHouse is a registered trademark of ClickHouse, Inc.
([clickhouse.com](https://clickhouse.com)). diskvet is an independent open-source
project and is not affiliated with, endorsed by or sponsored by ClickHouse, Inc.
Langfuse, SigNoz and ClickStack are trademarks of their respective owners and
are mentioned only to describe compatibility.

## License

[Apache-2.0](LICENSE).
