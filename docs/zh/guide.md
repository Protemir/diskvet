# 自托管 Langfuse 和 SigNoz：ClickHouse® 磁盘被占满的原因与解决方法

*[English](../guide.md) · [Русский](../ru/guide.md)。如有出入，以英文版为准。*

你的 Langfuse 或 SigNoz 服务器磁盘快满了，可 trace 数据其实并不多。在大多数公开案例中，空间其实是被 ClickHouse® 自己占用的，具体来说是它的系统日志表（system log tables），例如 `system.trace_log` 和 `system.text_log`，这些表默认没有大小限制。ClickStack 也有同样的问题。

本文介绍如何用一条只读查询确认这一点、立即释放空间，并在不踩已知坑的前提下防止问题再次出现。不需要任何额外工具。

*已在未经修改的 `clickhouse/clickhouse-server` 镜像 24.8、25.12 和 26.9 上测试（SigNoz 相关命令在 25.5 和 25.12 上测试），ClickHouse 服务和配置取自 Langfuse 和 SigNoz 的 compose 文件。*

## 要点速览

1. **检查**：对 `system.parts` 运行一条只读查询。如果 `system.*_log` 表比你自己的数据还大，问题就出在 ClickHouse 自己的日志上。
2. **立即释放空间**：对大的日志表执行 `TRUNCATE`。对超过 50 GB 的表，要加上 `SETTINGS max_table_size_to_drop = 0`。
3. **防止再次出现**：在 `config.d` 中添加一个文件，为每个日志表设置 TTL（生存时间），其中 `opentelemetry_span_log` 的 TTL 要写在 `<engine>` 里面。然后重启 ClickHouse。
4. **清理**：删除重启后遗留的 `*_log_0`、`*_log_1` 旧表。
5. **磁盘还是满的**？检查 Docker 容器日志、已删除的行和卡住的数据片段（part）。如果用的是 Langfuse，先升级 Langfuse，再把 ClickHouse 升到 26.8+。

## 1. 是什么占用了磁盘？按表查看 ClickHouse 的磁盘占用

把下面的查询保存为 `size.sql`。它会按磁盘占用列出最大的几张表：

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

**Langfuse（docker compose）**：在 Langfuse 的 `docker-compose.yml` 所在目录中运行。它的 compose 文件已经在容器内设置好了 `CLICKHOUSE_USER` 和 `CLICKHOUSE_PASSWORD`：

```sh
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < size.sql
```

**SigNoz（docker compose）**：容器名通常是 `signoz-clickhouse`（可以用 `docker ps` 确认）。SigNoz 的 `users.xml` 没有给 `default` 用户设置密码：

```sh
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --format PrettyCompact < size.sql
```

`--readonly=1` 让会话变为只读：ClickHouse 会拒绝任何修改。

**怎么看结果**：把 `system` 数据库对应的行和你自己的数据（Langfuse 是 `default`，SigNoz 是 `signoz_*`）做对比。如果排在最前面的是 `system.trace_log` 或 `system.text_log`，请继续看第 2 节。

## 2. 如何立即释放磁盘空间？

打开一个有写权限的客户端：

```sh
# Langfuse
docker compose exec clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'
# SigNoz
docker exec -it signoz-clickhouse clickhouse-client
```

清空大的日志表：

```sql
TRUNCATE TABLE system.trace_log;
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.metric_log;
TRUNCATE TABLE system.query_log;
```

这只会删除 ClickHouse 自己的诊断数据，不会删除你的 trace 数据，也不需要重启。

Langfuse 会读取 `system.query_log` 来跟踪它自己的部分查询（[#13123](https://github.com/langfuse/langfuse/issues/13123)）。所以可以清空它，但不要关闭它。

### TRUNCATE 报错 Code 359？超过 50 GB 的表

ClickHouse 不会删除或清空大小超过 `max_table_size_to_drop` 的表（默认 50,000,000,000 字节，约 46.6 GiB）。这个限制对 `TRUNCATE` 同样生效，更大的表会报错 `Code: 359 ... (TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT)`。

大的日志表确实会碰到这个限制：[Langfuse 讨论 #15024](https://github.com/orgs/langfuse/discussions/15024) 中的 `text_log` 有 59.20 GiB。有两种方法可以绕过它。

**方案 A**：只对这一条语句取消限制：

```sql
-- ClickHouse 23.12+：只对这一条语句取消限制
TRUNCATE TABLE system.text_log SETTINGS max_table_size_to_drop = 0;
```

**方案 B**：先创建一次性的标志文件，再执行普通的 `TRUNCATE`：

```sh
docker compose exec clickhouse sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```

（SigNoz：用 `docker exec signoz-clickhouse sh -c '...'` 执行同样的命令。）ClickHouse 会在第一次需要这个标志文件的 `DROP` 或 `TRUNCATE` 之后把它删掉，所以处理下一张大表之前要重新创建。

现在空间已经释放出来了，但日志表马上又会开始增长。第 4 节解决这个问题，第 3 节解释为什么会这样。

## 3. 为什么 trace_log 和 text_log 这么大？

ClickHouse 会把自己的诊断信息写进 `system` 数据库中的表：`query_log`、`trace_log`、`text_log`、`metric_log` 等。[文档](https://clickhouse.com/docs/reference/system-tables/overview)说得很直白：“By default, table growth is unlimited.”（默认情况下，表会无限增长。）

较新的[默认配置](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml)只给少数几个小的日志表设置了 TTL（从 25.9 开始，`processors_profile_log` 保留 30 天），大的日志表都没有。有两个默认设置让这些大表增长得很快：

- 查询分析器（query profiler）默认开启，会把正在运行的查询的堆栈采样写入 `trace_log`；
- `text_log` 以 `trace` 级别保存服务器日志。

公开案例：

- **Langfuse [#13123](https://github.com/langfuse/langfuse/issues/13123)**：`system.trace_log` 达到 66.86 GiB，而该 issue 中列出的 Langfuse 表（`traces`、`observations`、`scores`）加起来只有约 51 MiB。维护者决定不覆盖 ClickHouse 的默认设置，而是新增了一个 [FAQ 页面](https://langfuse.com/faq/all/reduce-clickhouse-disk-size)。
- **SigNoz [#12050](https://github.com/SigNoz/signoz/issues/12050)**：系统日志超过 80 GB（包括一张 `trace_log_0` 旧表），而遥测数据不到 500 MB。清空 `system.*` 表后释放了约 80 GB。SigNoz 新的 Foundry 安装器会设置 TTL，而之前用 docker compose 部署的环境没有 TTL。
- **ClickStack Helm chart [PR #275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275)**：一个 10 Gi 的卷在 10 天后用到了 100%，其中有 5.2 GB 的 trace 级别服务器日志和 3.7 GB 的 `system.text_log`，而遥测数据只有约 70 MB。该 PR 于 2026 年 9 月合并，增加了 7 天的 TTL。

## 4. 如何为 ClickHouse 系统日志表设置 TTL？

有了 TTL，ClickHouse 会自己删除旧的日志行。请在执行完第 2 节的 `TRUNCATE` **之后**再设置 TTL，这和 ClickHouse 应用 TTL 的方式有关。

添加 TTL 并重启后，ClickHouse 不会缩减旧表。它会把旧表连同所有数据行一起重命名为 `trace_log_0`，再创建一张带 TTL 的新表。如果你先清空过，这些旧表就很小，第 4 步会把它们删掉。

下面的 SQL 请在第 2 节那个有写权限的客户端中运行。

### 第 1 步：哪些日志表没有 TTL？

```sql
SELECT name,
       formatReadableSize(total_bytes) AS size,
       extract(engine_full, 'TTL [^S]*') AS ttl
FROM system.tables
WHERE database = 'system' AND engine LIKE '%MergeTree' AND match(name, '_log(_[0-9]+)?$')
ORDER BY total_bytes DESC;
```

`ttl` 为空表示这个日志表会被永久保留。名字类似 `trace_log_0` 的是旧表，第 4 步会删除它们。

### 第 2 步：在 config.d 中添加 TTL 文件

把下面的内容保存为 `clickhouse-ttl.xml`，放在 `docker-compose.yml` 所在的目录中：

```xml
<clickhouse>
    <!-- 保留 7 天的 ClickHouse 自身日志。只列出你的服务器上存在的日志表。 -->
    <query_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_log>
    <trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
    <text_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></text_log>
    <metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></metric_log>
    <asynchronous_metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></asynchronous_metric_log>
    <part_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></part_log>

    <!-- 默认配置用 <engine> 定义了这个日志表，因此单独写 <ttl>
         会导致服务器无法启动（ClickHouse#88366）。TTL 要写在 engine 里面。 -->
    <opentelemetry_span_log>
        <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
    </opentelemetry_span_log>
</clickhouse>
```

把它挂载到 `clickhouse` 服务中（保留你原有的 volumes 配置行）：

```yaml
  clickhouse:
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

这一步有三个坑：

- **`opentelemetry_span_log` 的 TTL 要写在 `<engine>` 里面**。默认配置用 `<engine>` 定义了这个日志表，而根据[文档](https://clickhouse.com/docs/reference/system-tables/overview)，这与 `<ttl>` 冲突。此时服务器会退出并报错 `If 'engine' is specified for system table, TTL parameters should be specified directly inside 'engine'`（[ClickHouse #88366](https://github.com/ClickHouse/ClickHouse/issues/88366)）。`PARTITION BY` 和 `ORDER BY` 请从 `SELECT engine_full FROM system.tables WHERE database = 'system' AND name = 'opentelemetry_span_log'` 的结果中复制（SigNoz 的配置还会按 `trace_id` 排序）。也可以用 `<opentelemetry_span_log remove="1"/>` 关闭这个日志表（见 Langfuse 的 [Scaling 文档](https://langfuse.com/self-hosting/configuration/scaling)）。`remove` 不会删除已有的表，需要你自己删除。
- **只列出你的服务器上存在的日志表**。只有配置里有对应的配置段，这个日志表才会启用（默认的 `config.xml` 就是通过把 `session_log` 注释掉来禁用它的）。SigNoz 自己的 [`config.xml`](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml) 没有启用 `text_log`，所以在 SigNoz 上要删掉这一行。另外还要加上 `processors_profile_log`，它在那个文件里没有 TTL。
- **profile 设置要放进 users.d，而不是 config.d**。如果你还要关闭查询分析器（把 `query_profiler_real_time_period_ns` 和 `query_profiler_cpu_time_period_ns` 设为 0，就像 Langfuse 的 Scaling 文档中那样），请把这个 `<profiles>` 块放进 `users.d/`。放在 `config.d/` 里会被静默忽略（[trigger.dev #4343](https://github.com/triggerdotdev/trigger.dev/issues/4343)）。

### 第 3 步：重启 ClickHouse

`config.d` 中的 TTL 只有在服务器重启后才会生效（[Altinity KB](https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/)）。只重新加载配置是不够的。使用 compose 时：

```sh
docker compose up -d clickhouse     # 用新的挂载重新创建容器
docker compose ps clickhouse
```

如果 ClickHouse 一直在重启，原因会写在容器内的错误日志里。`docker compose logs` 不一定能看到：

```sh
docker cp "$(docker compose ps -aq clickhouse)":/var/log/clickhouse-server/clickhouse-server.err.log .
tail -n 20 clickhouse-server.err.log
```

### 第 4 步：删除 trace_log_0 等旧表

重启后，每个改动过的日志表都会留下一张类似 `trace_log_0` 的旧表（之后再改动，会出现 `_1`、`_2`）。旧表保留了所有旧数据行，而且没有 TTL（见 ClickStack PR #275 中的升级说明，以及 [Sentry snuba #7311](https://github.com/getsentry/snuba/issues/7311)）。

下面的查询会帮你生成 `DROP` 语句。先读一遍，再粘贴到客户端中执行：

```sql
SELECT 'DROP TABLE system.' || name || ' SETTINGS max_table_size_to_drop = 0;'
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$');
```

ClickHouse 已经不再往这些表写入数据。`DROP` 无法撤销。

### 第 5 步：检查结果

再运行一次第 1 步的查询。每个大的日志表都应该显示 TTL，并且不应再有 `_N` 形式的表名。

ClickHouse 会在合并（merge）时删除过期的行，默认最多每 4 小时一次（[`merge_with_ttl_timeout`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout)），所以表会在接下来的几个小时内逐渐变小。

也可以让脚本替你检查：[diskvet](https://github.com/Protemir/diskvet) 以只读方式运行第 1 步的检查，并针对你的表输出 `TRUNCATE` 命令、TTL 文件和 `DROP` 列表；对超过删除限制的表，还会给出创建标志文件的命令（见第 7 节）。

## 5. 磁盘还是满的？空间还可能去了哪里

对比 `df -h` 和所有数据片段的总大小（`SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts`）。如果磁盘上的占用远大于这个数，说明空间被 ClickHouse 表之外的东西占用了。

### Docker 容器日志占满了磁盘？

Docker 默认的 `json-file` 日志驱动没有大小限制（`max-size` 默认为 `-1`，见 [Docker 文档](https://docs.docker.com/engine/logging/drivers/json-file/)）。在 [Langfuse #16339](https://github.com/langfuse/langfuse/issues/16339) 中，ClickHouse 容器的日志涨到了 89.1 GiB，占满了 244 GiB 的系统盘。

找出最大的几个日志文件：

```sh
sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'
docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'   # 目录名就是容器 ID
```

修复方法是在 `docker-compose.yml` 的每个服务中添加 `logging:` 配置块。在 #16339 中，Langfuse 维护者建议对所有容器都这样做，而不只是 ClickHouse。SigNoz 的 [compose 文件](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml)已经设置了 `50m` × 3。

```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

然后运行 `docker compose up -d --force-recreate`，因为日志选项只对新创建的容器生效。重建容器也会删除旧的日志文件；在 #16339 中，这一步释放了 81 GiB。

两点说明：

- 如果你的 Docker 守护进程（daemon）使用的是其他日志驱动，请改为在该驱动中配置日志保留策略，不要添加上面的配置块，因为 compose 里的 `driver: json-file` 会覆盖守护进程的日志驱动。
- Langfuse 的 README（[PR #16363](https://github.com/langfuse/langfuse/pull/16363)）介绍了在守护进程层面统一设置的方法：把 `max-size` 和 `max-file` 设为守护进程的默认值，然后重启 Docker 并重建容器。README 还建议不要用外部工具截断或轮转这些文件。

### ClickHouse 自己的日志文件很大？

ClickHouse 还会把普通的日志文件写到 `/var/log/clickhouse-server`（在 Langfuse 的 compose 中，这是一个单独的卷）。默认日志级别为 `trace`，文件达到 1000M 时轮转，最多保留 10 个旧文件（[`logger` 文档](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger)）。

ClickStack PR #275 使用的是下面这些值。把它们保存为另一个 `config.d` 文件，像 TTL 文件一样挂载，然后重启 ClickHouse（第 4 节第 3 步）：

```xml
<clickhouse>
    <logger><level>information</level><size>100M</size><count>10</count></logger>
</clickhouse>
```

### 为什么已删除的行仍然占用空间？

Langfuse 的数据保留（data retention）功能用[轻量级 `DELETE`](https://clickhouse.com/docs/reference/statements/delete)（lightweight DELETE）删除旧的数据行。ClickHouse 只会给这些行打上标记，要等数据片段被合并后，空间才会释放。

后台合并会跳过大于 [`max_bytes_to_merge_at_max_space_in_pool`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool)（150 GiB）的数据片段，而旧的按月分区（partition）也很少被合并。在 [Langfuse 讨论 #13969](https://github.com/orgs/langfuse/discussions/13969) 中，一个约 802 GiB 的 5 月分区里约 85% 是已删除的行。

找出含有已删除行的分区：

```sql
SELECT database, table, partition_id, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active AND has_lightweight_delete
GROUP BY database, table, partition_id
ORDER BY sum(bytes_on_disk) DESC;
```

然后逐个分区应用删除掩码（[APPLY DELETED MASK](https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask)）：

```sql
ALTER TABLE default.observations APPLY DELETED MASK IN PARTITION ID '202605';
```

**注意**：这是一个重量级变更（mutation）。它会重写受影响的数据片段，所以需要有空闲空间来写入重写后的新数据片段，同时会加重磁盘负载。请在业务低峰期执行，并用 `SELECT * FROM system.mutations WHERE NOT is_done` 观察进度。在 #13969 中，这个操作在约 17 分钟内为每个副本（replica）释放了约 360 GiB。

从 v3.179.0 开始，Langfuse worker 可以定时自动执行这个操作：`LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true`（默认关闭；见 `.env.prod.example`，[PR #14035](https://github.com/langfuse/langfuse/pull/14035)）。

### 旧的数据片段卡在磁盘上？（非活动和已分离的数据片段）

```sql
SELECT database, table, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       min(remove_time) AS oldest, max(refcount) AS max_refcount
FROM system.parts
WHERE NOT active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;
```

非活动数据片段（inactive part）是合并后遗留下来的。等过了 [`old_parts_lifetime`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime)（480 秒），并且已经没有查询在使用它们（`refcount` = 1），ClickHouse 才会删除它们。

如果它们越积越多（Langfuse 讨论 #15024 中积累了 112.55 GiB），而且 `oldest` 已经是几个小时前，就到 `system.processes` 里找长时间运行的查询，并用 `KILL QUERY WHERE query_id = '...'` 终止它们。

已分离的数据片段（detached part）会一直留在磁盘上，直到你把它们删除：

```sql
SELECT database, table, reason, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.detached_parts
GROUP BY database, table, reason;
```

先查看 `reason`。删除已分离的数据片段要用 `ALTER TABLE <db>.<table> DROP DETACHED PART '<name>' SETTINGS allow_drop_detached = 1`，不要直接删除目录。

## 6. 准备升级 ClickHouse？先检查这些

- **Langfuse + ClickHouse 26.8 或更新版本：先升级 Langfuse**。ClickHouse 26.8 把 `input_format_read_datetime_number_as_raw_value` 的默认值从 1 改成了 0。旧版 Langfuse 以毫秒数值的形式发送 `DateTime64` 值，在 26.8+ 上这些值最终会被存成 `9999-12-31 23:59:59`（[Langfuse #16858](https://github.com/langfuse/langfuse/issues/16858)：按项目统计，0.59% 到 21.43% 的写入受到影响）。修复见 [PR #16892](https://github.com/langfuse/langfuse/pull/16892)（v3 的 backport 见 [PR #16957](https://github.com/langfuse/langfuse/pull/16957)），已随 Langfuse v4.28.0 和 v3.225.7 发布。Langfuse 按月分区，所以这类行会落到 `999912` 分区。检查你的版本，并查找这些行：

  ```sql
  SELECT version();
  SELECT database, table, partition_id, count() AS parts
  FROM system.parts
  WHERE active AND startsWith(partition_id, '9999')
  GROUP BY database, table, partition_id;
  ```

- **每次升级之后，都要再运行一次第 4 节第 1 步的查询**。当某个版本修改了日志表的结构时，ClickHouse 会重命名当前表并创建一张新表，于是又会出现带 `_N` 后缀的旧表。按第 4 步删除它们。

## 7. 一次检查所有问题

[diskvet](https://github.com/Protemir/diskvet) 是一个开源（Apache-2.0）的只读脚本，它会运行上面的大部分检查，并输出一份附带修复命令的报告。它看不到 Docker 的日志文件，但会显示磁盘上有多少空间不在 ClickHouse 的数据片段里。报告为英文。

在有 Langfuse `docker-compose.yml` 的机器上运行（运行前请先读一遍 `checks.sql`）：

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

如果是 SigNoz，请使用 `--docker signoz-clickhouse`。

它只从 `system.*` 表（`system.tables`、`system.parts`、`system.disks`、`system.detached_parts`、`system.mutations`、`system.part_log` 等）读取元数据，并在 `readonly=2` 和资源限制下运行。它从不读取你的表中的数据行、`system.query_log` 或查询文本，也不会向任何地方发送任何数据。不会有任何操作自动执行：每一条修复命令都由你自己阅读并执行。

每小时检查一次、在磁盘写满之前发出预警的版本即将推出（免费内测将于 2026 年 10 月开始）。

## 参考资料

ClickHouse 文档和源码：

- 系统表概览（无限增长、`<engine>` 与 `<ttl>`、表结构变化时的重命名）：https://clickhouse.com/docs/reference/system-tables/overview
- 默认的 `config.xml`（没有 TTL 的日志表、`opentelemetry_span_log` 的 engine、`trace` 级别的 `text_log` 和 logger、被注释掉的 `session_log`）：https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml
- `max_table_size_to_drop`，服务器设置与 `force_drop_table`：https://clickhouse.com/docs/reference/settings/server-settings/settings/max-table#max_table_size_to_drop
- `max_table_size_to_drop`，查询设置：https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop
- 自 23.12 起支持在查询级别覆盖：https://github.com/ClickHouse/ClickHouse/pull/57452
- 标志文件用过即删（`checkCanBeDropped`）：https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/Context.cpp
- TRUNCATE：https://clickhouse.com/docs/reference/statements/truncate
- `opentelemetry_span_log` 的 TTL 报错：https://github.com/ClickHouse/ClickHouse/issues/88366
- MergeTree 设置：`merge_with_ttl_timeout`（14400 秒）https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout, `old_parts_lifetime`（480 秒）https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime, `max_bytes_to_merge_at_max_space_in_pool`（150 GiB）https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool
- 服务器日志轮转（`logger`：`level`、`size`、`count`）：https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger
- 轻量级 DELETE：https://clickhouse.com/docs/reference/statements/delete
- APPLY DELETED MASK：https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask
- system.parts：https://clickhouse.com/docs/reference/system-tables/parts
- system.detached_parts：https://clickhouse.com/docs/reference/system-tables/detached_parts
- DROP DETACHED PART：https://clickhouse.com/docs/reference/statements/alter/partition
- `allow_drop_detached`：https://clickhouse.com/docs/reference/settings/session-settings/allow#allow_drop_detached
- system.mutations：https://clickhouse.com/docs/reference/system-tables/mutations
- KILL QUERY：https://clickhouse.com/docs/reference/statements/kill
- Altinity KB，“System tables ate my disk”（需要重启）：https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/

Docker：

- json-file 日志驱动（`max-size` 默认为 -1；已有容器保留旧设置）：https://docs.docker.com/engine/logging/drivers/json-file/

Langfuse：

- FAQ，减小 ClickHouse 的磁盘占用：https://langfuse.com/faq/all/reduce-clickhouse-disk-size
- Scaling 文档，ClickHouse 系统日志表：https://langfuse.com/self-hosting/configuration/scaling
- #13123，系统表无限增长：https://github.com/langfuse/langfuse/issues/13123
- #16339，Docker 日志无限增长：https://github.com/langfuse/langfuse/issues/16339
- PR #16363，README 中的 Docker 日志轮转（守护进程默认值，不要用外部工具截断）：https://github.com/langfuse/langfuse/pull/16363
- 讨论 #13969，经轻量级删除标记的行：https://github.com/orgs/langfuse/discussions/13969
- 讨论 #15024，非活动数据片段和 59 GiB 的 text_log：https://github.com/orgs/langfuse/discussions/15024
- PR #14035，删除掩码清理（随 v3.179.0 发布）：https://github.com/langfuse/langfuse/pull/14035, https://github.com/langfuse/langfuse/releases/tag/v3.179.0
- #16858，ClickHouse 26.8+ 上的 DateTime64：https://github.com/langfuse/langfuse/issues/16858
- PR #16892 及 v3 backport PR #16957：https://github.com/langfuse/langfuse/pull/16892, https://github.com/langfuse/langfuse/pull/16957
- 包含修复的版本：https://github.com/langfuse/langfuse/releases/tag/v4.28.0, https://github.com/langfuse/langfuse/releases/tag/v3.225.7

SigNoz、ClickStack 及其他：

- SigNoz #12050，80+ GB 系统日志：https://github.com/SigNoz/signoz/issues/12050
- SigNoz v0.129.0 的 ClickHouse `config.xml` 和 `users.xml`：https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml, https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/users.xml
- SigNoz v0.129.0 的 `docker-compose.yaml`（容器 `signoz-clickhouse`、`max-size: 50m`、`max-file: "3"`）：https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml
- ClickStack Helm chart PR #275：https://github.com/ClickHouse/ClickStack-helm-charts/pull/275
- Sentry snuba #7311，没有 TTL 的 `*_log_N` 旧表：https://github.com/getsentry/snuba/issues/7311
- trigger.dev #4343，config.d 中的 profile 设置被忽略：https://github.com/triggerdotdev/trigger.dev/issues/4343

---

ClickHouse 是 ClickHouse, Inc. 的注册商标。diskvet 与 ClickHouse, Inc. 无关。Langfuse、SigNoz 和 ClickStack 是其各自所有者的商标。
