# 셀프 호스팅 Langfuse와 SigNoz에서 ClickHouse® 디스크가 가득 차는 이유와 해결 방법

*[English](../guide.md) · [Español](../es/guide.md) · [Português](../pt/guide.md) · [Русский](../ru/guide.md) · [日本語](../ja/guide.md) · [中文](../zh/guide.md). 버전 간 내용이 다르면 영어 버전이 기준입니다.*

Langfuse나 SigNoz 서버의 디스크가 부족해지는데, 정작 트레이스 데이터는 크지 않은 경우가 있습니다. 공개된 사례 대부분에서 공간을 차지하는 것은 ClickHouse® 자체입니다. 정확히는 `system.trace_log`, `system.text_log` 같은 ClickHouse의 시스템 로그 테이블(system log tables)이며, 이 테이블에는 기본적으로 크기 제한이 없습니다. ClickStack에도 같은 문제가 있습니다.

이 가이드에서는 읽기 전용 쿼리 하나로 원인을 확인하고, 공간을 바로 확보한 뒤, 알려진 함정을 피하면서 재발을 막는 방법을 설명합니다. 별도의 도구는 필요하지 않습니다.

*수정하지 않은 공식 `clickhouse/clickhouse-server` 이미지 24.8, 25.12, 26.9에서 테스트했습니다(SigNoz 명령은 25.5와 25.12에서 테스트). ClickHouse 서비스와 설정은 Langfuse와 SigNoz의 compose 파일에서 가져왔습니다.*

## 요약(TL;DR)

1. **확인.** `system.parts`에 읽기 전용 쿼리를 하나 실행합니다. `system.*_log` 테이블이 사용자 데이터보다 크다면 원인은 ClickHouse 자체 로그입니다.
2. **지금 바로 공간 확보.** 큰 로그를 `TRUNCATE`로 비웁니다. 50 GB가 넘는 테이블에는 `SETTINGS max_table_size_to_drop = 0`을 붙입니다.
3. **재발 방지.** 로그마다 TTL(보존 기간)을 지정하는 `config.d` 파일을 추가하고(`opentelemetry_span_log`의 TTL은 `<engine>` 안에 씁니다) ClickHouse를 재시작합니다.
4. **정리.** 재시작 후 남는 `*_log_0`, `*_log_1` 사본을 삭제합니다.
5. **그래도 가득 차 있다면?** Docker 컨테이너 로그, 삭제된 행, 디스크에 남아 있는 파트(part)를 확인합니다. Langfuse를 쓴다면 ClickHouse를 26.8+로 올리기 전에 Langfuse부터 업데이트하십시오.

## 1. 무엇이 디스크를 차지하는가? 테이블별 ClickHouse 디스크 사용량 확인

다음 쿼리를 `size.sql`로 저장합니다. 디스크에서 차지하는 크기가 큰 테이블부터 순서대로 보여 줍니다.

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

**Langfuse(docker compose).** Langfuse의 `docker-compose.yml`이 있는 폴더에서 실행합니다. Langfuse의 compose 파일은 컨테이너 안에 `CLICKHOUSE_USER`와 `CLICKHOUSE_PASSWORD`를 이미 설정해 둡니다.

```sh
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < size.sql
```

**SigNoz(docker compose).** 컨테이너 이름은 보통 `signoz-clickhouse`입니다(`docker ps`로 확인하십시오). SigNoz의 `users.xml`에는 `default` 사용자의 비밀번호가 설정되어 있지 않습니다.

```sh
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --format PrettyCompact < size.sql
```

`--readonly=1`을 지정하면 세션이 읽기 전용이 되어, ClickHouse가 모든 변경을 거부합니다.

**결과 읽는 법.** `system` 행을 사용자 데이터(Langfuse는 `default`, SigNoz는 `signoz_*`)와 비교합니다. `system.trace_log`나 `system.text_log`가 맨 위에 있다면 섹션 2로 넘어가십시오.

## 2. 디스크 공간을 지금 바로 확보하려면?

쓰기 권한이 있는 클라이언트를 엽니다.

```sh
# Langfuse
docker compose exec clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'
# SigNoz
docker exec -it signoz-clickhouse clickhouse-client
```

큰 로그를 비웁니다.

```sql
TRUNCATE TABLE system.trace_log;
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.metric_log;
TRUNCATE TABLE system.query_log;
```

이 명령은 ClickHouse 자체의 진단 데이터만 삭제하고 트레이스는 건드리지 않으며, 재시작도 필요 없습니다.

Langfuse는 직접 실행한 쿼리 일부를 추적하기 위해 `system.query_log`를 읽습니다([#13123](https://github.com/langfuse/langfuse/issues/13123)). 따라서 비우는 것은 괜찮지만 끄지는 마십시오.

### TRUNCATE가 Code 359로 실패한다면? 50 GB가 넘는 테이블

ClickHouse는 `max_table_size_to_drop`(기본값 50,000,000,000바이트, 약 46.6 GiB)보다 큰 테이블을 삭제하거나 비우지 않습니다. 이 제한은 `TRUNCATE`에도 적용되며, 이보다 큰 테이블에서는 `Code: 359 ... (TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT)` 오류로 실패합니다.

큰 로그는 실제로 이 제한에 걸립니다. [Langfuse discussion #15024](https://github.com/orgs/langfuse/discussions/15024)에서는 `text_log`가 59.20 GiB였습니다. 우회하는 방법은 두 가지입니다.

**방법 A.** SQL 문 하나에서만 제한을 해제합니다.

```sql
-- ClickHouse 23.12+: 이 SQL 문에서만 제한 해제
TRUNCATE TABLE system.text_log SETTINGS max_table_size_to_drop = 0;
```

**방법 B.** 한 번만 쓰이는 플래그 파일을 만든 다음, 일반 `TRUNCATE`를 실행합니다.

```sh
docker compose exec clickhouse sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```

(SigNoz에서는 같은 명령을 `docker exec signoz-clickhouse sh -c '...'` 형태로 실행합니다.) ClickHouse는 이 플래그가 필요한 첫 번째 `DROP` 또는 `TRUNCATE`를 실행한 뒤 플래그를 삭제합니다. 따라서 다음 큰 테이블을 처리하기 전에 다시 만드십시오.

이제 공간은 확보되었지만, 로그는 곧바로 다시 늘어나기 시작합니다. 이를 막는 방법은 섹션 4에서, 이런 일이 생기는 이유는 섹션 3에서 설명합니다.

## 3. trace_log와 text_log는 왜 이렇게 커지는가?

ClickHouse는 자체 진단 정보를 `system` 데이터베이스의 테이블(`query_log`, `trace_log`, `text_log`, `metric_log` 등)에 기록합니다. [공식 문서](https://clickhouse.com/docs/reference/system-tables/overview)에도 "By default, table growth is unlimited."(기본적으로 테이블 크기 증가에는 제한이 없습니다)라고 분명히 적혀 있습니다.

최근 버전의 [기본 설정](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml)도 일부 작은 로그에만 TTL을 지정하고(25.9부터 `processors_profile_log`는 30일간 보관), 큰 로그에는 지정하지 않습니다. 큰 로그가 빠르게 커지는 원인은 다음 두 가지 기본 설정입니다.

- 쿼리 프로파일러(query profiler)가 켜져 있어, 실행 중인 쿼리의 스택 샘플을 `trace_log`에 기록합니다.
- `text_log`는 서버 로그를 `trace` 레벨로 저장합니다.

공개된 사례는 다음과 같습니다.

- **Langfuse [#13123](https://github.com/langfuse/langfuse/issues/13123)**: `system.trace_log`는 66.86 GiB였던 반면, 이 이슈에 나열된 Langfuse 테이블(`traces`, `observations`, `scores`)은 모두 합쳐 약 51 MiB였습니다. 메인테이너는 ClickHouse의 기본값을 덮어쓰지 않기로 하고, 대신 [FAQ 페이지](https://langfuse.com/faq/all/reduce-clickhouse-disk-size)를 추가했습니다.
- **SigNoz [#12050](https://github.com/SigNoz/signoz/issues/12050)**: 텔레메트리는 500 MB도 되지 않는데 시스템 로그는 80 GB가 넘었습니다(`trace_log_0` 사본 포함). `system.*` 테이블을 비우자 약 80 GB가 확보되었습니다. SigNoz의 새 Foundry 설치 프로그램은 TTL을 설정하지만, docker compose로 설치한 기존 환경에는 TTL이 없습니다.
- **ClickStack Helm chart [PR #275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275)**: 10 Gi 볼륨이 10일 만에 100%에 도달했습니다. 텔레메트리는 약 70 MB였지만 trace 레벨 서버 로그가 5.2 GB, `system.text_log`가 3.7 GB였습니다. 2026년 9월에 머지된 이 PR은 7일 TTL을 추가합니다.

## 4. ClickHouse 시스템 로그에 TTL을 설정하려면?

TTL을 설정하면 ClickHouse가 오래된 로그 행을 스스로 삭제합니다. ClickHouse가 TTL을 적용하는 방식 때문에, TTL은 섹션 2의 `TRUNCATE`를 실행한 **후에** 설정하십시오.

TTL을 추가하고 재시작해도 ClickHouse는 기존 테이블을 줄이지 않습니다. 기존 테이블은 모든 행이 남은 상태로 이름만 `trace_log_0` 등으로 바뀌고, TTL이 적용된 새 테이블이 생성됩니다. 먼저 비워 두었다면 이 사본은 아주 작으며, 4단계에서 삭제합니다.

아래 SQL은 섹션 2에서 연 쓰기 권한이 있는 클라이언트에서 실행합니다.

### 1단계: TTL이 없는 로그 확인

```sql
SELECT name,
       formatReadableSize(total_bytes) AS size,
       extract(engine_full, 'TTL [^S]*') AS ttl
FROM system.tables
WHERE database = 'system' AND engine LIKE '%MergeTree' AND match(name, '_log(_[0-9]+)?$')
ORDER BY total_bytes DESC;
```

`ttl`이 비어 있으면 그 로그는 영구히 보관됩니다. `trace_log_0` 같은 이름은 예전 사본이며, 4단계에서 삭제합니다.

### 2단계: config.d에 TTL 파일 추가

다음 내용을 `docker-compose.yml`과 같은 폴더에 `clickhouse-ttl.xml`로 저장합니다.

```xml
<clickhouse>
    <!-- ClickHouse 자체 로그를 7일간 보관합니다. 서버에 있는 로그만 나열하십시오. -->
    <query_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_log>
    <trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
    <text_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></text_log>
    <metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></metric_log>
    <asynchronous_metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></asynchronous_metric_log>
    <part_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></part_log>

    <!-- 기본 설정은 이 로그를 <engine>으로 정의하므로, <ttl>을 따로 쓰면
         서버가 시작되지 않습니다(ClickHouse#88366). TTL은 <engine> 안에 씁니다. -->
    <opentelemetry_span_log>
        <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
    </opentelemetry_span_log>
</clickhouse>
```

이 파일을 `clickhouse` 서비스에 마운트합니다(기존 볼륨 설정은 그대로 둡니다).

```yaml
  clickhouse:
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

이 단계에는 함정이 세 가지 있습니다.

- **`opentelemetry_span_log`의 TTL은 `<engine>` 안에 씁니다.** 기본 설정은 이 로그를 `<engine>`으로 정의하는데, [공식 문서](https://clickhouse.com/docs/reference/system-tables/overview)에 따르면 이는 `<ttl>`과 충돌합니다. 이 경우 서버는 `If 'engine' is specified for system table, TTL parameters should be specified directly inside 'engine'` 오류를 내고 종료됩니다([ClickHouse #88366](https://github.com/ClickHouse/ClickHouse/issues/88366)). `PARTITION BY`와 `ORDER BY`는 `SELECT engine_full FROM system.tables WHERE database = 'system' AND name = 'opentelemetry_span_log'`의 결과에서 복사하십시오(SigNoz 설정은 `trace_id`로도 정렬합니다). 또는 `<opentelemetry_span_log remove="1"/>` 설정으로 이 로그를 끌 수도 있습니다(Langfuse의 [스케일링 문서](https://langfuse.com/self-hosting/configuration/scaling)). `remove`는 기존 테이블을 삭제하지 않으므로, 테이블은 직접 삭제하십시오.
- **서버에 있는 로그만 나열합니다.** 설정에 로그 섹션을 두면 그 로그가 켜집니다(기본 `config.xml`은 `session_log`를 주석 처리해서 꺼 둡니다). SigNoz 자체의 [`config.xml`](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml)은 `text_log`를 켜지 않으므로, SigNoz에서는 그 줄을 삭제하십시오. 또한 SigNoz의 `config.xml`에는 `processors_profile_log`의 TTL이 없으므로, TTL 파일에 `processors_profile_log`도 추가하십시오.
- **프로필 설정은 config.d가 아니라 users.d에 넣습니다.** 쿼리 프로파일러도 끄려면(Langfuse 스케일링 문서처럼 `query_profiler_real_time_period_ns`와 `query_profiler_cpu_time_period_ns`를 0으로 설정), 그 `<profiles>` 블록은 `users.d/`에 넣으십시오. `config.d/`에 넣으면 아무 오류 없이 무시됩니다([trigger.dev #4343](https://github.com/triggerdotdev/trigger.dev/issues/4343)).

### 3단계: ClickHouse 재시작

`config.d`의 TTL은 서버를 재시작해야만 적용됩니다([Altinity KB](https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/)). 설정을 다시 읽어 들이는 것만으로는 부족합니다. compose에서는 다음과 같이 합니다.

```sh
docker compose up -d clickhouse     # 새 마운트로 컨테이너를 다시 생성합니다
docker compose ps clickhouse
```

ClickHouse가 계속 재시작된다면, 원인은 컨테이너 안의 오류 로그에 기록되어 있습니다. `docker compose logs`에는 나타나지 않을 수 있습니다.

```sh
docker cp "$(docker compose ps -aq clickhouse)":/var/log/clickhouse-server/clickhouse-server.err.log .
tail -n 20 clickhouse-server.err.log
```

### 4단계: 오래된 trace_log_0 사본 삭제

재시작하고 나면 변경한 로그마다 `trace_log_0` 같은 사본이 생깁니다(이후 다시 변경하면 `_1`, `_2`). 사본에는 예전 행이 모두 남아 있고 TTL도 없습니다(ClickStack PR #275의 업그레이드 안내, [Sentry snuba #7311](https://github.com/getsentry/snuba/issues/7311)).

다음 쿼리는 `DROP` 문을 만들어 줍니다. 내용을 읽어 본 뒤 클라이언트에 붙여 넣으십시오.

```sql
SELECT 'DROP TABLE system.' || name || ' SETTINGS max_table_size_to_drop = 0;'
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$');
```

ClickHouse는 이 테이블에 더 이상 기록하지 않습니다. `DROP`은 되돌릴 수 없습니다.

### 5단계: 결과 확인

1단계의 쿼리를 다시 실행합니다. 큰 로그에는 모두 TTL이 표시되어야 하고, `_N` 형태의 이름은 남아 있지 않아야 합니다.

ClickHouse는 만료된 행을 머지(merge) 과정에서 삭제하는데, 이 삭제는 기본적으로 4시간에 최대 한 번만 일어납니다([`merge_with_ttl_timeout`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout)). 따라서 크기는 이후 몇 시간에 걸쳐 줄어듭니다.

이 확인은 스크립트에 맡길 수도 있습니다. [diskvet](https://github.com/Protemir/diskvet)은 1단계 점검을 읽기 전용으로 실행하고, 실제 테이블에 맞춘 `TRUNCATE` 명령, TTL 파일, `DROP` 목록을 출력합니다. 삭제 제한을 넘는 테이블에는 플래그 파일을 만드는 명령도 함께 출력합니다(섹션 7 참고).

## 5. 그래도 디스크가 가득 차 있다면? 공간을 차지하는 다른 곳

`df -h`의 결과를 모든 파트의 전체 크기(`SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts`)와 비교합니다. 디스크 사용량이 이보다 훨씬 많다면, 그 차이만큼의 공간은 ClickHouse 테이블 밖에서 쓰이고 있습니다.

### Docker 컨테이너 로그가 디스크를 채우고 있는가?

Docker의 기본 로깅 드라이버인 `json-file`에는 크기 제한이 없습니다(`max-size`의 기본값은 `-1`입니다. [Docker 문서](https://docs.docker.com/engine/logging/drivers/json-file/)를 참고하십시오). [Langfuse #16339](https://github.com/langfuse/langfuse/issues/16339)에서는 ClickHouse 컨테이너의 로그가 89.1 GiB까지 커져 244 GiB 루트 디스크를 가득 채웠습니다.

가장 큰 로그 파일을 찾습니다.

```sh
sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'
docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'   # 폴더 이름이 컨테이너 ID입니다
```

해결하려면 `docker-compose.yml`의 모든 서비스에 `logging:` 블록을 추가합니다. #16339에서 Langfuse 메인테이너는 ClickHouse뿐 아니라 모든 컨테이너에 이 설정을 하라고 권장했습니다. SigNoz의 [compose 파일](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml)에는 이미 `50m` × 3이 설정되어 있습니다.

```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

그런 다음 `docker compose up -d --force-recreate`를 실행합니다. 로그 옵션은 새로 생성된 컨테이너에만 적용되기 때문입니다. 컨테이너를 다시 생성하면 예전 로그 파일도 삭제되며, #16339에서는 이것으로 81 GiB가 확보되었습니다.

참고할 점이 두 가지 있습니다.

- Docker 데몬이 다른 로깅 드라이버를 사용한다면, 위 블록 대신 그 드라이버에서 보존 설정을 하십시오. `driver: json-file`을 지정하면 데몬의 드라이버 설정을 덮어쓰기 때문입니다.
- Langfuse의 README([PR #16363](https://github.com/langfuse/langfuse/pull/16363))는 데몬 전체에 적용하는 방법을 설명합니다. `max-size`와 `max-file`을 데몬 기본값으로 설정한 다음, Docker를 재시작하고 컨테이너를 다시 생성하는 방법입니다. 또한 이 파일들을 외부 도구로 잘라 내거나 로테이션하지 말라고 권고합니다.

### ClickHouse 자체 로그 파일이 커졌는가?

ClickHouse는 일반 로그 파일도 `/var/log/clickhouse-server`에 기록합니다(Langfuse의 compose에서는 이 경로가 볼륨으로 마운트됩니다). 기본값은 `trace` 레벨이며, 1000M마다 로테이션되고 이전 파일은 최대 10개까지 보관됩니다([`logger` 문서](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger)).

ClickStack PR #275는 아래 값을 사용합니다. 이 내용을 별도의 `config.d` 파일로 저장하고, TTL 파일처럼 마운트한 다음 ClickHouse를 재시작합니다(섹션 4의 3단계).

```xml
<clickhouse>
    <logger><level>information</level><size>100M</size><count>10</count></logger>
</clickhouse>
```

### 삭제한 행이 왜 계속 공간을 차지하는가?

Langfuse의 데이터 보존(data retention) 기능은 [경량 `DELETE`(lightweight DELETE)](https://clickhouse.com/docs/reference/statements/delete)로 오래된 행을 삭제합니다. ClickHouse는 이런 행에 삭제 표시만 하고, 공간은 해당 파트가 머지될 때 확보됩니다.

백그라운드 머지는 [`max_bytes_to_merge_at_max_space_in_pool`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool)(150 GiB)보다 큰 파트를 건너뛰고, 오래된 월별 파티션(partition)은 거의 머지되지 않습니다. [Langfuse discussion #13969](https://github.com/orgs/langfuse/discussions/13969)에서는 약 802 GiB인 5월 파티션의 약 85%가 삭제된 행이었습니다.

삭제된 행이 있는 파티션을 찾습니다.

```sql
SELECT database, table, partition_id, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active AND has_lightweight_delete
GROUP BY database, table, partition_id
ORDER BY sum(bytes_on_disk) DESC;
```

그런 다음 파티션 하나씩 삭제 마스크를 적용합니다([APPLY DELETED MASK](https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask)).

```sql
ALTER TABLE default.observations APPLY DELETED MASK IN PARTITION ID '202605';
```

**주의:** 이 작업은 비용이 큰 뮤테이션(heavyweight mutation)입니다. 영향을 받는 파트를 다시 쓰기 때문에 새 사본이 들어갈 여유 공간이 필요하고, 디스크에 부하를 줍니다. 사용량이 적은 시간대에 실행하고, `SELECT * FROM system.mutations WHERE NOT is_done` 쿼리로 진행 상황을 지켜보십시오. #13969에서는 약 17분 만에 레플리카당 약 360 GiB가 확보되었습니다.

v3.179.0부터는 Langfuse worker가 이 작업을 주기적으로 실행할 수 있습니다. `LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true`로 켭니다(기본값은 꺼져 있습니다. `.env.prod.example`과 [PR #14035](https://github.com/langfuse/langfuse/pull/14035)를 참고하십시오).

### 오래된 파트가 디스크에 남아 있는가? (비활성 파트와 분리된 파트)

```sql
SELECT database, table, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       min(remove_time) AS oldest, max(refcount) AS max_refcount
FROM system.parts
WHERE NOT active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;
```

비활성 파트(inactive part)는 머지 후에 남은 파트입니다. ClickHouse는 [`old_parts_lifetime`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime)(480초)이 지나고 이 파트를 사용하는 쿼리가 없어지면(`refcount` = 1) 삭제합니다.

비활성 파트가 쌓이고(Langfuse discussion #15024에서는 112.55 GiB) `oldest`가 몇 시간 전이라면, `system.processes`에서 오래 실행 중인 쿼리를 찾아 `KILL QUERY WHERE query_id = '...'` 명령으로 중지하십시오.

분리된 파트(detached part)는 직접 삭제하기 전까지 디스크에 남아 있습니다.

```sql
SELECT database, table, reason, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.detached_parts
GROUP BY database, table, reason;
```

먼저 `reason`을 확인하십시오. 파트를 삭제할 때는 폴더를 직접 지우지 말고 `ALTER TABLE <db>.<table> DROP DETACHED PART '<name>' SETTINGS allow_drop_detached = 1`을 사용하십시오.

## 6. ClickHouse를 업그레이드한다면? 먼저 확인할 것

- **Langfuse에서 ClickHouse 26.8 이상을 쓴다면 Langfuse부터 업데이트하십시오.** ClickHouse 26.8에서 `input_format_read_datetime_number_as_raw_value`의 기본값이 1에서 0으로 바뀌었습니다. 이전 버전의 Langfuse는 `DateTime64` 값을 밀리초 단위 숫자로 보내는데, 26.8+에서는 이 값이 `9999-12-31 23:59:59`로 저장되어 버립니다([Langfuse #16858](https://github.com/langfuse/langfuse/issues/16858): 프로젝트별로 쓰기 작업의 0.59%에서 21.43%). 수정 사항은 [PR #16892](https://github.com/langfuse/langfuse/pull/16892)(v3에는 [PR #16957](https://github.com/langfuse/langfuse/pull/16957)로 백포트)이며, Langfuse v4.28.0과 v3.225.7에 포함되어 릴리스되었습니다. Langfuse는 월 단위로 파티션을 나누므로, 이런 행은 `999912` 파티션에 들어갑니다. 버전을 확인하고 이런 행이 있는지 찾아보십시오.

  ```sql
  SELECT version();
  SELECT database, table, partition_id, count() AS parts
  FROM system.parts
  WHERE active AND startsWith(partition_id, '9999')
  GROUP BY database, table, partition_id;
  ```

- **업그레이드한 뒤에는 항상 섹션 4의 1단계 쿼리를 다시 실행하십시오.** 릴리스에서 로그의 스키마가 바뀌면 ClickHouse가 현재 테이블의 이름을 바꾸고 새 테이블을 만들기 때문에, 새로운 `_N` 사본이 생깁니다. 4단계와 같은 방법으로 삭제하십시오.

## 7. 한 번에 모두 점검하기

[diskvet](https://github.com/Protemir/diskvet)은 오픈 소스(Apache-2.0) 읽기 전용 스크립트로, 위에서 설명한 점검 대부분을 실행하고 수정 명령이 담긴 보고서를 출력합니다. Docker 로그 파일은 볼 수 없지만, 디스크 공간 중 ClickHouse 파트 밖에 있는 양은 보여 줍니다. 보고서는 영어로 출력됩니다.

Langfuse의 `docker-compose.yml`이 있는 머신에서 다음을 실행합니다(실행하기 전에 `checks.sql`을 읽어 보십시오).

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

SigNoz에서는 `--docker signoz-clickhouse`를 사용합니다.

diskvet은 `system.*` 테이블(`system.tables`, `system.parts`, `system.disks`, `system.detached_parts`, `system.mutations`, `system.part_log` 등)의 메타데이터만 읽으며, `readonly=2`와 리소스 제한을 걸고 실행됩니다. 사용자 테이블의 행, `system.query_log`, 쿼리 텍스트는 절대 읽지 않고, 어디에도 데이터를 보내지 않습니다. 자동으로 실행되는 수정은 없습니다. 각 수정 명령은 직접 읽어 보고 실행합니다.

매시간 점검하고 디스크가 가득 차기 전에 경고하는 버전을 준비하고 있습니다(2026년 10월 무료 베타 시작 예정).

## 참고 자료

ClickHouse 문서와 소스 코드:

- 시스템 테이블 개요(무제한 증가, `<engine>`과 `<ttl>`의 충돌, 스키마 변경 시 이름 변경): https://clickhouse.com/docs/reference/system-tables/overview
- 기본 `config.xml`(TTL이 없는 로그, `opentelemetry_span_log`의 engine, `trace` 레벨의 `text_log`와 logger, 주석 처리된 `session_log`): https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml
- `max_table_size_to_drop` 서버 설정과 `force_drop_table`: https://clickhouse.com/docs/reference/settings/server-settings/settings/max-table#max_table_size_to_drop
- `max_table_size_to_drop` 쿼리 설정: https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop
- 23.12부터 가능한 쿼리 단위 재정의: https://github.com/ClickHouse/ClickHouse/pull/57452
- 사용 후 플래그 삭제(`checkCanBeDropped`): https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/Context.cpp
- TRUNCATE: https://clickhouse.com/docs/reference/statements/truncate
- `opentelemetry_span_log`의 TTL 오류: https://github.com/ClickHouse/ClickHouse/issues/88366
- MergeTree 설정: `merge_with_ttl_timeout`(14400초) https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout, `old_parts_lifetime`(480초) https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime, `max_bytes_to_merge_at_max_space_in_pool`(150 GiB) https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool
- 서버 로그 로테이션(`logger`: `level`, `size`, `count`): https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger
- 경량 DELETE(lightweight DELETE): https://clickhouse.com/docs/reference/statements/delete
- APPLY DELETED MASK: https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask
- system.parts: https://clickhouse.com/docs/reference/system-tables/parts
- system.detached_parts: https://clickhouse.com/docs/reference/system-tables/detached_parts
- DROP DETACHED PART: https://clickhouse.com/docs/reference/statements/alter/partition
- `allow_drop_detached`: https://clickhouse.com/docs/reference/settings/session-settings/allow#allow_drop_detached
- system.mutations: https://clickhouse.com/docs/reference/system-tables/mutations
- KILL QUERY: https://clickhouse.com/docs/reference/statements/kill
- Altinity KB, "System tables ate my disk"(재시작 필요): https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/

Docker:

- json-file 로깅 드라이버(`max-size` 기본값 -1, 기존 컨테이너는 이전 설정 유지): https://docs.docker.com/engine/logging/drivers/json-file/

Langfuse:

- FAQ, ClickHouse 디스크 사용량 줄이기: https://langfuse.com/faq/all/reduce-clickhouse-disk-size
- 스케일링 문서, ClickHouse 시스템 로그 테이블: https://langfuse.com/self-hosting/configuration/scaling
- #13123, 시스템 테이블이 제한 없이 커짐: https://github.com/langfuse/langfuse/issues/13123
- #16339, 크기 제한이 없는 Docker 로그: https://github.com/langfuse/langfuse/issues/16339
- PR #16363, README의 Docker 로그 로테이션(데몬 기본값, 외부 도구로 잘라 내지 않기): https://github.com/langfuse/langfuse/pull/16363
- Discussion #13969, 경량 DELETE로 삭제된 행: https://github.com/orgs/langfuse/discussions/13969
- Discussion #15024, 비활성 파트와 59 GiB text_log: https://github.com/orgs/langfuse/discussions/15024
- PR #14035, 삭제 마스크 클리너(v3.179.0에서 릴리스): https://github.com/langfuse/langfuse/pull/14035, https://github.com/langfuse/langfuse/releases/tag/v3.179.0
- #16858, ClickHouse 26.8+에서의 DateTime64: https://github.com/langfuse/langfuse/issues/16858
- PR #16892와 v3 백포트 PR #16957: https://github.com/langfuse/langfuse/pull/16892, https://github.com/langfuse/langfuse/pull/16957
- 수정이 포함된 릴리스: https://github.com/langfuse/langfuse/releases/tag/v4.28.0, https://github.com/langfuse/langfuse/releases/tag/v3.225.7

SigNoz, ClickStack 및 기타:

- SigNoz #12050, 80 GB가 넘는 시스템 로그: https://github.com/SigNoz/signoz/issues/12050
- SigNoz v0.129.0의 ClickHouse `config.xml`과 `users.xml`: https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml, https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/users.xml
- SigNoz v0.129.0의 `docker-compose.yaml`(컨테이너 `signoz-clickhouse`, `max-size: 50m`, `max-file: "3"`): https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml
- ClickStack Helm chart PR #275: https://github.com/ClickHouse/ClickStack-helm-charts/pull/275
- Sentry snuba #7311, TTL이 없는 `*_log_N` 사본: https://github.com/getsentry/snuba/issues/7311
- trigger.dev #4343, config.d의 프로필 설정이 무시됨: https://github.com/triggerdotdev/trigger.dev/issues/4343

---

ClickHouse는 ClickHouse, Inc.의 등록 상표입니다. diskvet은 ClickHouse, Inc.와 관련이 없습니다. Langfuse, SigNoz, ClickStack은 각 소유자의 상표입니다.
