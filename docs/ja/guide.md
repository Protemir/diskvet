# セルフホストの Langfuse・SigNoz で ClickHouse® のディスクがいっぱいになる原因と対処法

*[English](../guide.md) · [Español](../es/guide.md) · [Português](../pt/guide.md) · [Русский](../ru/guide.md) · [中文](../zh/guide.md)。内容に違いがある場合は英語版が正となります。*

Langfuse や SigNoz のサーバーでディスクの空きがなくなってきたのに、トレースのデータ自体は小さい、ということがあります。公開されている報告の多くでは、容量を使っているのは ClickHouse® 自身です。具体的には、`system.trace_log` や `system.text_log` といった ClickHouse 自身のシステムログテーブル（system log tables）で、これらのテーブルにはデフォルトでサイズの上限がありません。ClickStack にも同じ問題があります。

このガイドでは、読み取り専用のクエリ 1 つで原因を確認し、すぐに容量を空け、既知の落とし穴を避けながら再発を防ぐ方法を説明します。追加のツールは必要ありません。

*公式の `clickhouse/clickhouse-server` イメージ 24.8、25.12、26.9 をそのまま使って検証しています（SigNoz 向けのコマンドは 25.5 と 25.12 で検証）。ClickHouse のサービスと設定は、Langfuse と SigNoz の compose ファイルのものを使用しました。*

## 要点（TL;DR）

1. **確認**：`system.parts` に対して読み取り専用のクエリを 1 つ実行します。`system.*_log` テーブルが自分のデータより大きければ、原因は ClickHouse 自身のログです。
2. **すぐに容量を空ける**：大きなログテーブルを `TRUNCATE` します。50 GB を超えるテーブルには `SETTINGS max_table_size_to_drop = 0` を付けます。
3. **再発を防ぐ**：`config.d` にファイルを追加して各ログテーブルに TTL（有効期限）を設定し（`opentelemetry_span_log` の TTL は `<engine>` の中に書きます）、ClickHouse を再起動します。
4. **後片付け**：再起動後に残る `*_log_0`、`*_log_1` のコピーを削除します。
5. **それでもディスクがいっぱいの場合**：Docker のコンテナログ、削除済みの行、ディスクに残ったままのパーツ（part）を確認します。Langfuse の場合は、ClickHouse を 26.8+ に上げる前に Langfuse を更新してください。

## 1. 何がディスクを使っているのか：ClickHouse のディスク使用量をテーブルごとに確認する

次のクエリを `size.sql` として保存します。ディスク上のサイズが大きい順にテーブルを表示します。

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

**Langfuse（docker compose）**：Langfuse の `docker-compose.yml` があるディレクトリで実行します。この compose ファイルでは、コンテナ内に `CLICKHOUSE_USER` と `CLICKHOUSE_PASSWORD` がすでに設定されています。

```sh
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < size.sql
```

**SigNoz（docker compose）**：コンテナ名は通常 `signoz-clickhouse` です（`docker ps` で確認してください）。SigNoz の `users.xml` では、`default` ユーザーにパスワードが設定されていません。

```sh
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --format PrettyCompact < size.sql
```

`--readonly=1` を付けるとセッションが読み取り専用になり、ClickHouse はあらゆる変更を拒否します。

**結果の見方**：`system` の行を、自分のデータ（Langfuse なら `default`、SigNoz なら `signoz_*`）と比べます。`system.trace_log` か `system.text_log` が上位にあれば、セクション 2 に進んでください。

## 2. 今すぐディスクの容量を空けるには

書き込み権限のあるクライアントを起動します。

```sh
# Langfuse
docker compose exec clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'
# SigNoz
docker exec -it signoz-clickhouse clickhouse-client
```

大きなログテーブルを空にします。

```sql
TRUNCATE TABLE system.trace_log;
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.metric_log;
TRUNCATE TABLE system.query_log;
```

これで削除されるのは ClickHouse 自身の診断データだけで、トレースは削除されません。再起動も不要です。

Langfuse は、自身が発行したクエリの一部を追跡するために `system.query_log` を読み取っています（[#13123](https://github.com/langfuse/langfuse/issues/13123)）。そのため、空にするのは構いませんが、無効にはしないでください。

### TRUNCATE が Code 359 で失敗する場合（50 GB を超えるテーブル）

ClickHouse は、`max_table_size_to_drop`（デフォルトは 50,000,000,000 バイト、約 46.6 GiB）を超えるテーブルを DROP しません。この制限は `TRUNCATE` にも適用され、これより大きいテーブルでは `Code: 359 ... (TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT)` というエラーで失敗します。

大きなログテーブルが実際にこの制限を超えることもあります。[Langfuse のディスカッション #15024](https://github.com/orgs/langfuse/discussions/15024) では、`text_log` が 59.20 GiB ありました。回避する方法は 2 つあります。

**方法 A**：1 つのステートメントに限って制限を解除します。

```sql
-- ClickHouse 23.12+：このステートメントに限って制限を解除する
TRUNCATE TABLE system.text_log SETTINGS max_table_size_to_drop = 0;
```

**方法 B**：一度だけ有効なフラグファイルを作成してから、通常の `TRUNCATE` を実行します。

```sh
docker compose exec clickhouse sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```

（SigNoz では、同じコマンドを `docker exec signoz-clickhouse sh -c '...'` で実行します。）ClickHouse は、このフラグを必要とした最初の `DROP` または `TRUNCATE` の後でフラグファイルを削除します。次の大きなテーブルを処理する前に、もう一度作成してください。

これで容量は戻りましたが、ログテーブルはすぐにまた増え始めます。これを止める方法はセクション 4 で、増える理由はセクション 3 で説明します。

## 3. trace_log と text_log はなぜこれほど大きくなるのか

ClickHouse は、自身の診断情報を `system` データベースのテーブル（`query_log`、`trace_log`、`text_log`、`metric_log` など）に書き込みます。[ドキュメント](https://clickhouse.com/docs/reference/system-tables/overview)には「By default, table growth is unlimited.」（デフォルトでは、テーブルの増大に制限はありません）とはっきり書かれています。

最近の[デフォルト設定](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml)でも、TTL が設定されているのは一部の小さなログテーブルだけで（25.9 以降、`processors_profile_log` は 30 日間保持）、大きなログテーブルには設定されていません。大きなログテーブルが急速に増えるのは、次の 2 つのデフォルト設定が原因です。

- クエリプロファイラー（query profiler）が有効になっており、実行中のクエリのスタックサンプルを `trace_log` に書き込みます。
- `text_log` は、サーバーログを `trace` レベルで保存します。

公開されている事例を挙げます。

- **Langfuse [#13123](https://github.com/langfuse/langfuse/issues/13123)**：`system.trace_log` が 66.86 GiB あったのに対し、その issue に挙げられている Langfuse のテーブル（`traces`、`observations`、`scores`）は合計で約 51 MiB でした。メンテナーは ClickHouse のデフォルトを上書きしないことにし、代わりに [FAQ ページ](https://langfuse.com/faq/all/reduce-clickhouse-disk-size)を追加しました。
- **SigNoz [#12050](https://github.com/SigNoz/signoz/issues/12050)**：システムログテーブル（`trace_log_0` のコピーを含む）が 80 GB を超えていたのに対し、テレメトリーは 500 MB 未満でした。`system.*` テーブルを空にしたところ、約 80 GB が解放されました。SigNoz の新しい Foundry インストーラーは TTL を設定しますが、それ以前の docker compose によるインストールには TTL がありません。
- **ClickStack Helm chart [PR #275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275)**：10 Gi のボリュームが 10 日で使用率 100% に達しました。trace レベルのサーバーログが 5.2 GB、`system.text_log` が 3.7 GB あったのに対し、テレメトリーは約 70 MB でした。2026 年 9 月にマージされたこの PR で、7 日間の TTL が追加されています。

## 4. ClickHouse のシステムログテーブルに TTL を設定するには

TTL を設定すると、ClickHouse が古いログの行を自動で削除するようになります。ClickHouse が TTL を適用する仕組みの都合上、TTL はセクション 2 の `TRUNCATE` を実行した**後に**設定してください。

TTL を追加して再起動しても、ClickHouse は既存のテーブルを縮小しません。代わりに、既存のテーブルは全行を残したまま `trace_log_0` にリネームされ、TTL 付きのテーブルが新しく作成されます。先に空にしておけばこれらのコピーはごく小さく、ステップ 4 で削除できます。

以下の SQL は、セクション 2 で起動した書き込み権限のあるクライアントで実行します。

### ステップ 1：TTL が設定されていないログテーブルはどれか

```sql
SELECT name,
       formatReadableSize(total_bytes) AS size,
       extract(engine_full, 'TTL [^S]*') AS ttl
FROM system.tables
WHERE database = 'system' AND engine LIKE '%MergeTree' AND match(name, '_log(_[0-9]+)?$')
ORDER BY total_bytes DESC;
```

`ttl` が空の場合、そのログテーブルの行は無期限に保持されます。`trace_log_0` のような名前のものは古いコピーで、ステップ 4 で削除します。

### ステップ 2：config.d に TTL ファイルを追加する

次の内容を `clickhouse-ttl.xml` として、`docker-compose.yml` と同じディレクトリに保存します。

```xml
<clickhouse>
    <!-- ClickHouse 自身のログを 7 日間保持する。サーバーに存在するログテーブルだけを記載すること。 -->
    <query_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_log>
    <trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
    <text_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></text_log>
    <metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></metric_log>
    <asynchronous_metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></asynchronous_metric_log>
    <part_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></part_log>

    <!-- 標準の設定ではこのログテーブルが <engine> で定義されているため、<ttl> を別に書くと
         サーバーが起動しなくなる（ClickHouse#88366）。TTL は <engine> の中に書く。 -->
    <opentelemetry_span_log>
        <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
    </opentelemetry_span_log>
</clickhouse>
```

このファイルを `clickhouse` サービスにマウントします（既存の volumes の行はそのまま残してください）。

```yaml
  clickhouse:
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

このステップには落とし穴が 3 つあります。

- **`opentelemetry_span_log` の TTL は `<engine>` の中に書きます**。標準の設定ではこのログテーブルが `<engine>` で定義されており、[ドキュメント](https://clickhouse.com/docs/reference/system-tables/overview)によると、これは `<ttl>` と競合します。その場合、サーバーは `If 'engine' is specified for system table, TTL parameters should be specified directly inside 'engine'` というエラーで終了します（[ClickHouse #88366](https://github.com/ClickHouse/ClickHouse/issues/88366)）。`PARTITION BY` と `ORDER BY` は、`SELECT engine_full FROM system.tables WHERE database = 'system' AND name = 'opentelemetry_span_log'` の結果からコピーしてください（SigNoz の設定では `trace_id` でもソートしています）。または、`<opentelemetry_span_log remove="1"/>` でこのログテーブルを無効にする方法もあります（Langfuse の[スケーリングに関するドキュメント](https://langfuse.com/self-hosting/configuration/scaling)）。`remove` は既存のテーブルを削除しないので、テーブルは自分で DROP してください。
- **サーバーに存在するログテーブルだけを記載します**。設定ファイルにログテーブルのセクションがあると、そのログテーブルが有効になります（標準の `config.xml` では、`session_log` をコメントアウトすることで無効にしています）。SigNoz 独自の [`config.xml`](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml) では `text_log` が有効になっていないため、SigNoz ではその行を削除してください。また、SigNoz の `config.xml` では `processors_profile_log` に TTL が設定されていないため、TTL ファイルにこのログテーブルの行も追加してください。
- **プロファイル設定は config.d ではなく users.d に書きます**。あわせてクエリプロファイラーも無効にする場合（Langfuse のスケーリングに関するドキュメントにあるように、`query_profiler_real_time_period_ns` と `query_profiler_cpu_time_period_ns` を 0 にする場合）、その `<profiles>` ブロックは `users.d/` に置いてください。`config.d/` に置くと、エラーも出ずに無視されます（[trigger.dev #4343](https://github.com/triggerdotdev/trigger.dev/issues/4343)）。

### ステップ 3：ClickHouse を再起動する

`config.d` の TTL は、サーバーを再起動したときにだけ反映されます（[Altinity KB](https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/)）。設定の再読み込みだけでは反映されません。compose の場合は次のとおりです。

```sh
docker compose up -d clickhouse     # 新しいマウントでコンテナを作り直す
docker compose ps clickhouse
```

ClickHouse が再起動を繰り返す場合、原因はコンテナ内のエラーログに記録されています。`docker compose logs` には表示されないことがあります。

```sh
docker cp "$(docker compose ps -aq clickhouse)":/var/log/clickhouse-server/clickhouse-server.err.log .
tail -n 20 clickhouse-server.err.log
```

### ステップ 4：古い trace_log_0 のコピーを削除する

再起動後、変更したログテーブルごとに `trace_log_0` のようなコピーができます（その後さらに変更すると `_1`、`_2` と続きます）。コピーには古い行がすべて残っており、TTL もありません（ClickStack PR #275 のアップグレードに関する注記、[Sentry snuba #7311](https://github.com/getsentry/snuba/issues/7311)）。

次のクエリで `DROP` ステートメントを生成できます。内容を確認してから、クライアントに貼り付けて実行してください。

```sql
SELECT 'DROP TABLE system.' || name || ' SETTINGS max_table_size_to_drop = 0;'
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$');
```

これらのテーブルに ClickHouse が書き込むことはもうありません。`DROP` は元に戻せません。

### ステップ 5：結果を確認する

ステップ 1 のクエリをもう一度実行します。大きなログテーブルにはすべて TTL が表示され、`_N` の付いた名前は残っていないはずです。

ClickHouse は、期限切れの行をマージ（merge）の際に削除します。この削除が行われるのは、デフォルトでは多くても 4 時間に 1 回です（[`merge_with_ttl_timeout`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout)）。そのため、サイズはその後の数時間で徐々に小さくなります。

この確認はスクリプトに任せることもできます。[diskvet](https://github.com/Protemir/diskvet) はステップ 1 のチェックを読み取り専用で実行し、実際のテーブルに合わせて `TRUNCATE` コマンド、TTL ファイル、`DROP` の一覧を出力します。DROP のサイズ制限を超えるテーブルについては、フラグファイルを作成するコマンドも出力します（セクション 7 を参照）。

## 5. それでもディスクがいっぱいの場合：容量を使っているほかの場所

`df -h` の結果を、すべてのパーツの合計サイズ（`SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts`）と比べます。ディスクの使用量がこれを大きく上回る場合、容量は ClickHouse のテーブル以外で使われています。

### Docker のコンテナログがディスクを埋めていないか

Docker のデフォルトのログドライバー `json-file` には、サイズの上限がありません（`max-size` のデフォルトは `-1`。[Docker のドキュメント](https://docs.docker.com/engine/logging/drivers/json-file/)を参照）。[Langfuse #16339](https://github.com/langfuse/langfuse/issues/16339) では、ClickHouse コンテナのログが 89.1 GiB に達し、244 GiB のルートディスクを使い切りました。

サイズの大きいログファイルを探します。

```sh
sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'
docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'   # ディレクトリ名がコンテナ ID
```

対処するには、`docker-compose.yml` のすべてのサービスに `logging:` ブロックを追加します。#16339 で Langfuse のメンテナーは、ClickHouse だけでなくすべてのコンテナにこの設定をするよう勧めています。SigNoz の [compose ファイル](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml)では、すでに `50m` × 3 が設定されています。

```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

その後、`docker compose up -d --force-recreate` を実行します。ログのオプションは、新しく作成されたコンテナにしか適用されないためです。コンテナを作り直すと古いログファイルも削除され、#16339 ではこれで 81 GiB が空きました。

注意点が 2 つあります。

- Docker デーモンで別のログドライバーを使っている場合は、代わりにそのドライバー側でログの保持期間を設定してください。`driver: json-file` を書くと、デーモンのログドライバーが上書きされてしまいます。
- Langfuse の README（[PR #16363](https://github.com/langfuse/langfuse/pull/16363)）では、デーモン全体で設定する方法が説明されています。`max-size` と `max-file` をデーモンのデフォルトとして設定し、Docker を再起動してからコンテナを作り直す方法です。README では、これらのファイルを外部ツールで切り詰めたりローテーションしたりしないようにとも勧めています。

### ClickHouse 自身のログファイルが大きくなっていないか

ClickHouse は、通常のログファイルも `/var/log/clickhouse-server` に書き込みます（Langfuse の compose ではボリュームになっています）。デフォルトでは `trace` レベルで、1000M ごとにローテーションされ、古いファイルは最大 10 個まで保持されます（[`logger` のドキュメント](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger)）。

ClickStack PR #275 では、次の値を使っています。これを別の `config.d` ファイルとして保存し、TTL ファイルと同じようにマウントして、ClickHouse を再起動します（セクション 4 のステップ 3）。

```xml
<clickhouse>
    <logger><level>information</level><size>100M</size><count>10</count></logger>
</clickhouse>
```

### 削除した行が容量を使い続けるのはなぜか

Langfuse のデータ保持（data retention）機能は、[論理削除（lightweight `DELETE`）](https://clickhouse.com/docs/reference/statements/delete)で古い行を削除します。ClickHouse はこうした行に削除済みの印を付けるだけで、容量が戻るのはそのパーツがマージされたときです。

バックグラウンドのマージは [`max_bytes_to_merge_at_max_space_in_pool`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool)（150 GiB）を超えるパーツを対象にせず、古い月単位のパーティション（partition）がマージされることもほとんどありません。[Langfuse のディスカッション #13969](https://github.com/orgs/langfuse/discussions/13969) では、約 802 GiB ある 5 月のパーティションの約 85% が削除済みの行でした。

削除済みの行を含むパーティションを探します。

```sql
SELECT database, table, partition_id, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active AND has_lightweight_delete
GROUP BY database, table, partition_id
ORDER BY sum(bytes_on_disk) DESC;
```

次に、パーティションを 1 つずつ指定して削除マスクを適用します（[APPLY DELETED MASK](https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask)）。

```sql
ALTER TABLE default.observations APPLY DELETED MASK IN PARTITION ID '202605';
```

**注意**：これはヘビーウェイトなミューテーション（mutation）です。対象のパーツを書き直すため、新しいコピーを書き込むための空き容量が必要になり、ディスクにも負荷がかかります。ピーク時間帯を避けて実行し、`SELECT * FROM system.mutations WHERE NOT is_done` で進行状況を確認してください。#13969 では、約 17 分でレプリカ 1 台あたり約 360 GiB が空きました。

v3.179.0 以降の Langfuse worker では、これを定期的に自動実行できます。`LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` を設定してください（デフォルトは無効。`.env.prod.example` と [PR #14035](https://github.com/langfuse/langfuse/pull/14035) を参照）。

### 古いパーツがディスクに残っていないか（非アクティブなパーツとデタッチされたパーツ）

```sql
SELECT database, table, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       min(remove_time) AS oldest, max(refcount) AS max_refcount
FROM system.parts
WHERE NOT active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;
```

非アクティブなパーツ（inactive part）は、マージの後に残ったものです。ClickHouse は、[`old_parts_lifetime`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime)（480 秒）が経過し、どのクエリにも使われなくなった（`refcount` = 1）時点でこれらを削除します。

非アクティブなパーツがたまり続け（Langfuse のディスカッション #15024 では 112.55 GiB）、`oldest` が何時間も前になっている場合は、`system.processes` で長時間実行されているクエリを探し、`KILL QUERY WHERE query_id = '...'` で停止してください。

デタッチされたパーツ（detached part）は、削除するまでディスクに残ります。

```sql
SELECT database, table, reason, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.detached_parts
GROUP BY database, table, reason;
```

まず `reason` を確認してください。パーツを削除するときは、ディレクトリを直接消すのではなく、`ALTER TABLE <db>.<table> DROP DETACHED PART '<name>' SETTINGS allow_drop_detached = 1` を使います。

## 6. ClickHouse をアップグレードする前に確認すること

- **Langfuse で ClickHouse 26.8 以降を使う場合は、先に Langfuse を更新してください**。ClickHouse 26.8 で、`input_format_read_datetime_number_as_raw_value` のデフォルトが 1 から 0 に変わりました。古い Langfuse は `DateTime64` の値をミリ秒単位の数値として送るため、26.8+ ではその値が `9999-12-31 23:59:59` として保存されてしまいます（[Langfuse #16858](https://github.com/langfuse/langfuse/issues/16858)：プロジェクトごとに書き込みの 0.59% から 21.43%）。修正は [PR #16892](https://github.com/langfuse/langfuse/pull/16892)（v3 には [PR #16957](https://github.com/langfuse/langfuse/pull/16957) でバックポート）で、Langfuse v4.28.0 と v3.225.7 でリリースされています。Langfuse は月単位でパーティションを分けているため、こうした行はパーティション `999912` に入ります。バージョンを確認し、該当する行を探してください。

  ```sql
  SELECT version();
  SELECT database, table, partition_id, count() AS parts
  FROM system.parts
  WHERE active AND startsWith(partition_id, '9999')
  GROUP BY database, table, partition_id;
  ```

- **アップグレードのたびに、セクション 4 のステップ 1 のクエリを再実行してください**。新しいリリースでログテーブルのスキーマが変わると、ClickHouse は現在のテーブルをリネームして新しいテーブルを作成するため、新たに `_N` のコピーができます。ステップ 4 と同じ手順で削除してください。

## 7. すべてをまとめてチェックする

[diskvet](https://github.com/Protemir/diskvet) は、オープンソース（Apache-2.0）の読み取り専用スクリプトです。上記のチェックの大部分を実行し、修正コマンド付きのレポートを出力します。Docker のログファイルは確認できませんが、ディスクのうち ClickHouse のパーツ以外で使われている量は表示します。レポートは英語です。

Langfuse の `docker-compose.yml` があるマシンで、次のコマンドを実行します（実行する前に `checks.sql` の内容を確認してください）。

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

SigNoz の場合は `--docker signoz-clickhouse` を指定します。

diskvet が読み取るのは、`system.*` テーブル（`system.tables`、`system.parts`、`system.disks`、`system.detached_parts`、`system.mutations`、`system.part_log` など）のメタデータだけで、`readonly=2` とリソース制限を付けて実行します。自分のテーブルの行、`system.query_log`、クエリのテキストは一切読み取らず、どこにもデータを送信しません。修正が自動で実行されることはなく、各修正の内容を確認したうえで自分で実行します。

1 時間ごとにチェックし、ディスクがいっぱいになる前に警告するバージョンを準備中です（2026 年 10 月に無料ベータを開始予定）。

## 参考資料

ClickHouse のドキュメントとソースコード：

- システムテーブルの概要（無制限の増大、`<engine>` と `<ttl>`、スキーマ変更時のリネーム）：https://clickhouse.com/docs/reference/system-tables/overview
- デフォルトの `config.xml`（TTL のないログテーブル、`opentelemetry_span_log` の engine、`trace` レベルの `text_log` と logger、コメントアウトされた `session_log`）：https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml
- `max_table_size_to_drop`、サーバー設定と `force_drop_table`：https://clickhouse.com/docs/reference/settings/server-settings/settings/max-table#max_table_size_to_drop
- `max_table_size_to_drop`、クエリ設定：https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop
- 23.12 以降のクエリ単位での上書き：https://github.com/ClickHouse/ClickHouse/pull/57452
- フラグファイルは使用後に削除される（`checkCanBeDropped`）：https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/Context.cpp
- TRUNCATE：https://clickhouse.com/docs/reference/statements/truncate
- `opentelemetry_span_log` の TTL のエラー：https://github.com/ClickHouse/ClickHouse/issues/88366
- MergeTree の設定：`merge_with_ttl_timeout`（14400 秒）https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout, `old_parts_lifetime`（480 秒）https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime, `max_bytes_to_merge_at_max_space_in_pool`（150 GiB）https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool
- サーバーログのローテーション（`logger`：`level`、`size`、`count`）：https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger
- 論理削除（lightweight DELETE）：https://clickhouse.com/docs/reference/statements/delete
- APPLY DELETED MASK：https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask
- system.parts：https://clickhouse.com/docs/reference/system-tables/parts
- system.detached_parts：https://clickhouse.com/docs/reference/system-tables/detached_parts
- DROP DETACHED PART：https://clickhouse.com/docs/reference/statements/alter/partition
- `allow_drop_detached`：https://clickhouse.com/docs/reference/settings/session-settings/allow#allow_drop_detached
- system.mutations：https://clickhouse.com/docs/reference/system-tables/mutations
- KILL QUERY：https://clickhouse.com/docs/reference/statements/kill
- Altinity KB「System tables ate my disk」（再起動が必要）：https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/

Docker：

- json-file ログドライバー（`max-size` のデフォルトは -1。既存のコンテナは古い設定のまま）：https://docs.docker.com/engine/logging/drivers/json-file/

Langfuse：

- FAQ、ClickHouse のディスクサイズを減らす方法：https://langfuse.com/faq/all/reduce-clickhouse-disk-size
- スケーリングに関するドキュメント、ClickHouse のシステムログテーブル：https://langfuse.com/self-hosting/configuration/scaling
- #13123、システムテーブルが際限なく増える：https://github.com/langfuse/langfuse/issues/13123
- #16339、上限のない Docker ログ：https://github.com/langfuse/langfuse/issues/16339
- PR #16363、README の Docker ログローテーション（デーモンのデフォルト、外部ツールで切り詰めない）：https://github.com/langfuse/langfuse/pull/16363
- ディスカッション #13969、論理削除された行：https://github.com/orgs/langfuse/discussions/13969
- ディスカッション #15024、非アクティブなパーツと 59 GiB の text_log：https://github.com/orgs/langfuse/discussions/15024
- PR #14035、削除マスクのクリーナー（v3.179.0 でリリース）：https://github.com/langfuse/langfuse/pull/14035, https://github.com/langfuse/langfuse/releases/tag/v3.179.0
- #16858、ClickHouse 26.8+ での DateTime64：https://github.com/langfuse/langfuse/issues/16858
- PR #16892 と v3 へのバックポート PR #16957：https://github.com/langfuse/langfuse/pull/16892, https://github.com/langfuse/langfuse/pull/16957
- 修正を含むリリース：https://github.com/langfuse/langfuse/releases/tag/v4.28.0, https://github.com/langfuse/langfuse/releases/tag/v3.225.7

SigNoz、ClickStack、その他：

- SigNoz #12050、80 GB を超えるシステムログテーブル：https://github.com/SigNoz/signoz/issues/12050
- SigNoz v0.129.0 の ClickHouse `config.xml` と `users.xml`：https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml, https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/users.xml
- SigNoz v0.129.0 の `docker-compose.yaml`（コンテナ `signoz-clickhouse`、`max-size: 50m`、`max-file: "3"`）：https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml
- ClickStack Helm chart PR #275：https://github.com/ClickHouse/ClickStack-helm-charts/pull/275
- Sentry snuba #7311、TTL のない `*_log_N` のコピー：https://github.com/getsentry/snuba/issues/7311
- trigger.dev #4343、config.d に書いたプロファイル設定が無視される：https://github.com/triggerdotdev/trigger.dev/issues/4343

---

ClickHouse は ClickHouse, Inc. の登録商標です。diskvet は ClickHouse, Inc. とは関係ありません。Langfuse、SigNoz、ClickStack はそれぞれの所有者の商標です。
