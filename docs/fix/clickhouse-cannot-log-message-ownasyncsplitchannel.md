# ClickHouse®: Cannot log message in OwnAsyncSplitChannel channel
<!-- description: ClickHouse® can't write its log file, floods stderr and Docker's json log, and burns CPU. Why it happens and how to stop it. -->

`docker logs` shows this message again and again, each time with a stack trace
(the file can also be `clickhouse-server.err.log`):

```text
Cannot log message in OwnAsyncSplitChannel channel: Poco::Exception. Code: 1000, e.code() = 0, File access error: /var/log/clickhouse-server/clickhouse-server.log, Stack trace (when copying this message, always include the lines below):

0. Poco::RotateBySizeStrategy::mustRotate(Poco::LogFile*) @ 0x00000000223def83
1. Poco::FileChannel::log(Poco::Message const&) @ 0x00000000223b7f49
2. DB::OwnFormattingChannel::logExtended(DB::ExtendedLogMessage const&) @ 0x000000001daa95d9
3. DB::OwnRunnableForChannel::run() @ 0x000000001dab33ac
4. Poco::ThreadImpl::runnableEntry(void*) @ 0x00000000223e5e4f
5. ? @ 0x0000000000094ac3
6. clone @ 0x0000000000125a84
 (version 25.12.11.4 (official build))
```

## Short answer

ClickHouse® can't write `/var/log/clickhouse-server/clickhouse-server.log`,
usually because that disk is full. Every log line then fails, and ClickHouse
prints the error with a stack trace to stderr instead. Docker stores stderr in
the container's `*-json.log`, which has no size limit by default. Before
ClickHouse 26.7, freeing space doesn't stop it. Only a restart does.

What it costs:

- In our test on 25.12, with no queries running: about 105% CPU (4% before), and the container log grew by 30 to 45 MB a second, to 7.7 GB in under 4 minutes. After one failed query, `clickhouse-server.err.log` looped too, and CPU went to about 120%.
- [Langfuse #16339](https://github.com/langfuse/langfuse/issues/16339): an 89.1 GiB container log filled a 244 GiB disk, and `docker exec` failed with `no space left on device`.
- [OpenPanel #324](https://github.com/Openpanel-dev/openpanel/issues/324): about 140% CPU on an idle server for 20+ days.

## Which versions

This message comes from asynchronous logging, on by default since 25.7. The
retry that prints it came with
[PR #88814](https://github.com/ClickHouse/ClickHouse/pull/88814), in 25.8.11,
25.9.4 and 25.10. What a full log disk does, by version:

- **25.8.11 to 26.6:** the loop on this page. Langfuse's compose file uses 25.12.
- **26.7 and later:** no loop for a full disk. Other write errors can still send a stack trace to stderr for every log line (see [Why it happens](#why-it-happens)).
- **25.6 and older:** each log line goes to stderr as `Cannot add message to the log:`, with the line and a stack trace. There is no loop: in our 24.8 test CPU stayed at about 3%. But the log file stayed stuck after we freed space, so the container log keeps growing until you restart.
- **25.7, 25.8.1 to 25.8.10, 25.9.2 and 25.9.3:** in our 25.8.5 test the logging thread for the file stopped. Nothing went to the container log, and the file stayed stuck after we freed space. PR #88814 says the server could also abort.

Below 26.7 the fix is the same for all of them: free the space, then restart.

## Check

On the host, find what is full:

```sh
df -h
sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'
docker compose exec clickhouse sh -c 'df -h /var/log/clickhouse-server; du -sh /var/log/clickhouse-server'
```

Is it happening now? Count the message in the last lines of the container
log. Any count above 0 means yes. The second pattern is the message on 25.6
and older, where one message with its stack trace took 17 to 29 lines in our
test. Normally the stock image writes only a few startup lines there (under
1 KB in our tests); the server log goes to the files.

```sh
docker compose logs --tail 100 clickhouse | grep -cE 'Cannot log message|Cannot add message to the log'
```

Then check the version and the free space from inside ClickHouse. Save this as
`check.sql`:

```sql
SELECT version();
SELECT name, path,
       formatReadableSize(free_space) AS free,
       formatReadableSize(total_space) AS total
FROM system.disks;
SELECT formatReadableSize(sum(bytes_on_disk)) AS parts FROM system.parts;
```

Run it read-only, as in [guide section 1](../guide.md#1-what-is-using-the-disk-check-clickhouse-disk-usage-by-table)
(Langfuse's compose file sets the user and password inside the container;
for SigNoz, use the `docker exec` command from that section):

```sh
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < check.sql
```

Below 26.7, the log stays stuck until you restart
([Which versions](#which-versions)). Docker keeps container logs and named
volumes under `/var/lib/docker` by default, so the logs, the log volume and the
data usually share one disk. If `df -h` shows much more used than `parts`, the
space is outside ClickHouse's tables.

## Fix

**1. Cap Docker's container logs.** Add a `logging:` block to every service in
`docker-compose.yml`, as in the [guide](../guide.md#are-docker-container-logs-filling-the-disk):

```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

**2. Free the space, then restart.** If `/var/log/clickhouse-server` itself is
full, first delete ClickHouse's rotated files (`clickhouse-server.log.0.gz`,
`.1.gz` and so on). They hold old server logs only. The current `.log` files
stay:

```sh
docker compose exec clickhouse sh -c 'rm -f /var/log/clickhouse-server/*.log.*.gz'
```

Then recreate the containers, because log options apply only to new ones. This
restarts every service in the compose file, deletes each old container's log
file (in #16339 that freed 81 GiB) and ends the loop:

```sh
docker compose up -d --force-recreate
```

If `docker compose exec` fails with `no space left on device`, as in #16339,
remove the ClickHouse container instead: that deletes its container log.
Before you do, check where the data is:

```sh
docker inspect -f '{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}}{{println}}{{end}}' $(docker compose ps -aq clickhouse)
```

On the `/var/lib/clickhouse` line you want `bind` or a named volume, as in
Langfuse's compose file. A name of 64 hex characters is an anonymous volume:
a new container gets a new, empty one. In our test the table was gone after
`rm -sf` and `up -d`, while `up -d --force-recreate` kept it. With an
anonymous volume, free space some other way and use `--force-recreate`.

```sh
docker compose rm -sf clickhouse     # stop and remove the container, not its volumes
docker compose up -d
```

Once there is space, run the `--force-recreate` command above too, so the
other services get the log cap. Don't run `docker compose down -v`: `-v`
deletes the named volumes, and your data with them.

**3. Check.** `docker compose logs --tail 5 clickhouse` should end with the
startup lines, not a stack trace. If you freed space without recreating, run
`docker compose restart clickhouse` first: before 26.7 only a restart ends the loop.

**4. Cap ClickHouse's own log files.** The stock image's `config.xml` sets
`trace` level, rotation at 1000M and up to 10 old files. Mount this as a
`config.d` file and restart, as in the [guide](../guide.md#are-clickhouses-own-log-files-big):

```xml
<clickhouse>
    <logger><level>information</level><size>100M</size><count>10</count></logger>
</clickhouse>
```

**5. Upgrade.** The fix for a full disk is in ClickHouse 26.7 and later.
Langfuse's [compose file](https://github.com/langfuse/langfuse/blob/main/docker-compose.yml)
uses `clickhouse-server:25.12`, which doesn't have it. On Langfuse, update
Langfuse before you move ClickHouse to 26.8 or newer
([guide section 6](../guide.md#6-upgrading-clickhouse-check-this-first)).

**On Kubernetes**, the kubelet rotates container logs (by default at 10 MiB,
keeping 5 files, see the
[Kubernetes docs](https://kubernetes.io/docs/concepts/cluster-administration/logging/#log-rotation)),
so step 1 is for Docker only. If ClickHouse's log folder fills there, free the
space, then restart the pod. We didn't test this on Kubernetes.

Traps:

- **Free space before you restart.** On 25.12, a restart with the log disk still full started the loop again right away.
- **A log cap doesn't stop the loop.** With `50m` × 3 the container log stayed under 150 MB in our test, but CPU stayed at about 105% until the restart.
- **Use `--tail` with `docker compose logs`.** Without it, Docker reads the whole file: for a 2.6 GB log it still hadn't finished after 90 seconds in our test, against half a second with `--tail`.
- **Don't truncate or rotate `*-json.log` by hand.** Docker's docs say only the Docker daemon should touch these files, and Langfuse's README ([PR #16363](https://github.com/langfuse/langfuse/pull/16363)) says the same.
- **A host `logrotate` isn't needed.** OpenPanel #324 suspected one had replaced the log file under ClickHouse. We didn't test that. ClickHouse rotates its own files.

## Why it happens

Before 26.7 (we read the 25.12 source; `LogFile_STD.cpp` and `FileChannel.cpp`
are the same in 24.1 and 24.8):

1. A write to the log file fails, for example on a full disk. For "no space left" the code has a handler that deletes the oldest rotated log or empties the current one. In our 25.12 test the log wasn't emptied: it kept its size (116 KiB) and stopped changing. Either way, the file stream stays in an error state.
2. Before each message, ClickHouse checks the file size for rotation (`RotateBySizeStrategy::mustRotate`). In that error state the check throws `File access error`. Nothing resets the state, so it throws every time, even after you free space.
3. On 25.8.11 to 26.6, the logging thread prints the error to stderr and tries the same message again, with no pause. So the server spins even with no queries. Each log file has its own thread, so an error message starts a second loop on `clickhouse-server.err.log`.

[PR #93127](https://github.com/ClickHouse/ClickHouse/pull/93127) ("fix LogFile
recovery after disk full error", merged 2026-07-02) resets the stream after a
failed write. We checked `LogFile_STD.cpp` at these tags. The fix is in
v26.7.1.1315-stable, v26.8.15.10-lts and v26.9.1.1629-stable. It is not in
v26.6.8.7-stable, v26.3.36.6-lts, v25.12.12.1-stable or v25.8.33.6-lts.

On 26.9 our full log disk gave no loop: ClickHouse emptied its log, nothing
went to the container log, CPU stayed at about 4%, and logging went on after
we freed space. Per
[ClickHouse #68438](https://github.com/ClickHouse/ClickHouse/issues/68438), a
log file that can't be written for other reasons (permissions, a read-only
file system, `chattr +i`) still sends a stack trace to stderr for every log
line on 26.9. We didn't run that case.

*Tested on stock `clickhouse/clickhouse-server` images 25.12.11.4 and
26.9.1.1629, Docker 29.3.0 (Docker Desktop on Windows, 12 CPUs) and Compose
v5.1.0, with a 2 MiB tmpfs as the log folder, and a compose file like
Langfuse's (named volumes, user 101:101). We ran `df` and `du` on the host as
root in a helper container on Docker Desktop's VM, without `sudo`. The rotated
file names come from a test with `<size>1M</size><count>3</count>`. For
[Which versions](#which-versions) and the anonymous volume case we also ran
24.8.14.39 and 25.8.5.17 with the same 2 MiB tmpfs log folder.*

## Sources

- ClickHouse PR #93127, the fix (merged into 26.7): https://github.com/ClickHouse/ClickHouse/pull/93127
- ClickHouse PR #88814, the retry and this message in the async logging thread (25.8.11, 25.9.4, 25.10): https://github.com/ClickHouse/ClickHouse/pull/88814
- `OwnSplitChannel.cpp` at 24.8 (`Cannot add message to the log`): https://github.com/ClickHouse/ClickHouse/blob/v24.8.14.39-lts/src/Loggers/OwnSplitChannel.cpp
- ClickHouse #68438, logging doesn't recover after a full disk; unwritable files on 26.9: https://github.com/ClickHouse/ClickHouse/issues/68438
- Earlier reports: ClickHouse #54433 (2023) https://github.com/ClickHouse/ClickHouse/issues/54433, #101444 (clickhouse-keeper into syslog) https://github.com/ClickHouse/ClickHouse/issues/101444
- `LogFile_STD.cpp` without and with the fix: https://github.com/ClickHouse/ClickHouse/blob/v25.12.12.1-stable/base/poco/Foundation/src/LogFile_STD.cpp, https://github.com/ClickHouse/ClickHouse/blob/v26.7.1.1315-stable/base/poco/Foundation/src/LogFile_STD.cpp
- `FileChannel.cpp` (the "no space left" handler) and `PurgeStrategy.cpp`: https://github.com/ClickHouse/ClickHouse/blob/v25.12.12.1-stable/base/poco/Foundation/src/FileChannel.cpp, https://github.com/ClickHouse/ClickHouse/blob/v25.12.12.1-stable/base/poco/Foundation/src/PurgeStrategy.cpp
- `OwnSplitChannel.cpp` at 25.12 (one thread per log file, the retry and the stderr message): https://github.com/ClickHouse/ClickHouse/blob/v25.12.12.1-stable/src/Loggers/OwnSplitChannel.cpp
- Server log settings (`logger`: `level`, `size`, `count`): https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger
- Docker json-file driver (`max-size` defaults to -1; files are for the daemon only): https://docs.docker.com/engine/logging/drivers/json-file/
- Docker volumes (stored under `/var/lib/docker/volumes`, not removed with the container): https://docs.docker.com/engine/storage/volumes/
- Kubernetes log rotation (`containerLogMaxSize` 10Mi, `containerLogMaxFiles` 5): https://kubernetes.io/docs/concepts/cluster-administration/logging/#log-rotation
- Langfuse #16339, 89.1 GiB container log: https://github.com/langfuse/langfuse/issues/16339
- Langfuse PR #16363, Docker log rotation in the README: https://github.com/langfuse/langfuse/pull/16363
- Langfuse `docker-compose.yml` (ClickHouse 25.12, log volume): https://github.com/langfuse/langfuse/blob/main/docker-compose.yml
- OpenPanel #324, idle CPU from the log loop: https://github.com/Openpanel-dev/openpanel/issues/324

For the other checks, [diskvet](https://github.com/Protemir/diskvet) is a free,
read-only script. It can't see Docker's log files, but it shows how much of
the disk is outside ClickHouse's parts. Download it as in
[guide section 7](../guide.md#7-check-everything-at-once), then run it in the
folder with `docker-compose.yml`:

```sh
sh diskvet.sh report --docker auto > report.md
```

---

ClickHouse is a registered trademark of ClickHouse, Inc. diskvet is not affiliated with ClickHouse, Inc.
