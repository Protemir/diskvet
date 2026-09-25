#!/bin/sh
# Integration test on real ClickHouse servers in Docker.
#   sh tests/run.sh                  # 24.8 25.12 latest
#   sh tests/run.sh 25.12            # one version
#   KEEP=1 sh tests/run.sh 24.8      # keep the container for poking around
#
# For every version it starts a throw-away container, seeds the problems from
# tests/seed.sql (plus 1.2 GiB of synthetic trace_log rows, 310 tiny inserts,
# fake disk history), then:
#   1. runs diskvet.sh from this machine with --docker <container>, then with
#      --k8s default/<container> through the fake kubectl, whose exec becomes
#      docker exec (tests/k8s_shim.sh: logins, query_log, hashing, flag line);
#   2. runs it inside the container with /bin/sh (dash) and busybox ash;
#   3. runs it as the Variant B user (readonly=1 profile, narrow grants);
#   4. runs the fix commands printed by the report and checks that they work:
#      TRUNCATE with the force_drop_table flag, the generated TTL config + restart,
#      DROP of the *_log_N copies, START MERGES, OPTIMIZE, APPLY DELETED MASK,
#      DROP DETACHED PART, KILL MUTATION;
#   5. records the facts the plan asked to verify (metric names, part_log,
#      keep_free_space, DateTime64 min_time, year-9999 partitions).
# Results: tests/out/<version>-*.md|json|txt. Needs docker; Git Bash is fine.
set -u
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
OUT=${OUT:-$ROOT/tests/out}
mkdir -p "$OUT"
VERSIONS=${*:-24.8 25.12 latest}
SALT=$(sed -n 's/^SALT=//p' tests/fixtures/test.env)
PW=diskvet-test-$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
TOTAL_PASS=0
TOTAL_FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
has()  { if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then fail "$3 (found: $2)"; else ok "$3"; fi; }
status_of() { sed -n "s/^| $2 | [^|]* | \([A-Z_]*\) |\$/\1/p" "$1"; }
expect() {  # file check-number regex
    _s=$(status_of "$1" "$2")
    if printf '%s\n' "$_s" | grep -Eqx "$3"; then ok "check $2 is $_s"; else fail "check $2 is '$_s', want $3"; fi
}
summary() { sed -n '/^| # | Check | Status |$/,/^$/p' "$1"; }
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
ch() { docker exec -i "$C" clickhouse-client "$@"; }
chq() { docker exec -i "$C" clickhouse-client -q "$1" 2>&1; }
wait_ready() {
    _i=0
    while [ $_i -lt 120 ]; do
        docker exec "$C" clickhouse-client -q 'SELECT 1' >/dev/null 2>&1 && return 0
        _i=$((_i + 1)); sleep 1
    done
    return 1
}
# SQL lines from the ```sql blocks of one report section (## N.), without comments
sql_of_section() {
    awk -v n="$2" '
        /^## [0-9]\. / { sec = substr($2, 1, 1) + 0 }
        /^---$/ { sec = 0 }
        sec == n && /^```sql$/ { inb = 1; next }
        inb && /^```$/ { inb = 0; next }
        inb && !/^--/ { print }
    ' "$1"
}
# Wait until no unfinished mutations remain on a table (or time out)
wait_mutations() {
    _i=0
    while [ $_i -lt 30 ]; do
        [ "$(chq "SELECT count() FROM system.mutations WHERE database = '$1' AND table = '$2' AND NOT is_done")" = 0 ] && return 0
        _i=$((_i + 1)); sleep 1
    done
    return 1
}

for V in $VERSIONS; do
    PASS=0
    FAIL=0
    C=chd-test-$(printf '%s' "$V" | tr -c 'a-z0-9' '-')
    F=$OUT/$V
    echo "== ClickHouse $V (container $C)"
    docker rm -f -v "$C" >/dev/null 2>&1
    if ! docker create --name "$C" --ulimit nofile=262144:262144 "clickhouse/clickhouse-server:$V" >/dev/null; then
        fail "image clickhouse/clickhouse-server:$V"
        TOTAL_FAIL=$((TOTAL_FAIL + 1)); continue
    fi
    docker cp "$(hostpath "$ROOT/tests/fixtures/ch-test.xml")" "$C:/etc/clickhouse-server/config.d/zz-diskvet-test.xml" >/dev/null
    docker start "$C" >/dev/null
    if ! wait_ready; then
        fail "server did not start"; docker logs --tail 30 "$C"
        TOTAL_FAIL=$((TOTAL_FAIL + 1)); docker rm -f -v "$C" >/dev/null; continue
    fi
    VER=$(chq "SELECT version()")
    echo "   version $VER"

    # ------------------------------------------------------------ seed
    ch --multiquery <tests/seed.sql >"$F-seed.txt" 2>&1 || { fail "seed.sql: $(tail -3 "$F-seed.txt")"; }
    i=0; while [ $i -lt 310 ]; do echo "INSERT INTO customer_acme.events_eu (id) VALUES ($i);"; i=$((i + 1)); done | ch --multiquery
    i=0; while [ $i -lt 25 ]; do echo "INSERT INTO customer_acme.hot_eu VALUES ($i);"; i=$((i + 1)); done | ch --multiquery
    # langfuse#16858: a DateTime64 sent as a JSON number of milliseconds
    echo '{"id":"t1","timestamp":1758650000000,"project_id":"p1"}' | ch -q "INSERT INTO default.traces FORMAT JSONEachRow"
    # real trace_log rows from the query profiler, then 1.2 GiB of synthetic ones
    ch -q "SELECT sum(cityHash64(number)) FROM numbers(200000000) SETTINGS query_profiler_cpu_time_period_ns = 1000000, query_profiler_real_time_period_ns = 1000000" >/dev/null
    ch -q "SYSTEM FLUSH LOGS"
    ch -q "INSERT INTO system.trace_log (event_date, event_time, trace) SELECT today(), now(), arrayMap(x -> rand64(number + x), range(100)) FROM numbers(1600000)"
    # four days of fake disk history growing 20 GiB/day, for the forecast
    used=$(chq "SELECT total_space - free_space FROM system.disks WHERE name = 'default'")
    if [ "$(chq "SELECT count() FROM system.columns WHERE database = 'system' AND table = 'asynchronous_metric_log' AND name = 'key'")" = 1 ]; then
        ch -q "INSERT INTO system.asynchronous_metric_log (event_date, event_time, metric, key, value) SELECT toDate(t), t, 'DiskUsed', 'default', greatest(0, $used - (96 - n) * 20 * 1073741824 / 24) FROM (SELECT number AS n, now() - INTERVAL 97 HOUR + toIntervalHour(number) AS t FROM numbers(96))"
    else
        ch -q "INSERT INTO system.asynchronous_metric_log (event_date, event_time, metric, value) SELECT toDate(t), t, 'DiskUsed_default', greatest(0, $used - (96 - n) * 20 * 1073741824 / 24) FROM (SELECT number AS n, now() - INTERVAL 97 HOUR + toIntervalHour(number) AS t FROM numbers(96))"
    fi
    ch -q "SYSTEM FLUSH LOGS"
    sleep 3

    # ------------------------------------------------------------ 1. from this machine
    R=$F-report.md
    if sh diskvet.sh report --docker "$C" >"$R" 2>"$F-report.err"; then ok "report from the host (--docker $C)"; else fail "report exit code: $(cat "$F-report.err")"; fi
    expect "$R" 1 WARN                    # 1.2 GiB trace_log without TTL
    expect "$R" 2 'OK|WARN|CRITICAL'      # depends on the Docker host disk
    expect "$R" 3 'OK|WARN|CRITICAL'
    expect "$R" 4 'OK|WARN|CRITICAL'
    expect "$R" 5 CRITICAL                # hot_eu: 25 parts >= its parts_to_delay_insert 20
    expect "$R" 6 INFO                    # a small detached partition
    expect "$R" 7 CRITICAL                # a failing mutation
    has "$R" "detected: Langfuse" "Langfuse detected by table names"
    has "$R" "container $C" "container named in the report"
    has "$R" "| system.trace_log |" "trace_log listed"
    has "$R" "customer_acme.events_eu | 20" "310 parts in events_eu seen"
    has "$R" "| customer_acme.hot_eu | all | 25 | 20 | 1000 | CRITICAL |" "table-level parts_to_delay_insert used"
    has "$R" "| customer_acme.payments_eu | 1 |" "lightweight delete seen in payments_eu (real name in the local report)"
    has "$R" "| default.observations | 1 |" "Langfuse-style DELETE FROM sets has_lightweight_delete"
    has "$R" "customer_acme.archive_eu | detached | 1 |" "detached partition seen"
    has "$R" "| customer_acme.broken_mut |" "failing mutation seen"
    has "$R" "95% full in ~" "rough forecast from fake history"
    has "$R" "max_table_size_to_drop = 10.0 MiB" "drop limit read from system.server_settings"
    has "$R" "Nothing was changed. Nothing was sent anywhere." "promise line"
    has "$R" "github.com/Protemir/diskvet#early-access" "beta line"
    case $VER in
        2[6-9].*|[3-9]?.*) has "$R" "partitions of year 9999" "year-9999 partition noticed (26.8+ numeric DateTime64)" ;;
        *) hasnt "$R" "partitions of year 9999" "no year-9999 partition before 26.8" ;;
    esac

    # ------------------------------------------------------------ 1b. --k8s through the fake kubectl
    # tests/k8s_shim.sh: this container as the pod default/$C. It runs before the
    # payload step below, which sends the salt in a query, because the shim checks
    # that the salt is nowhere in the server's logs.
    sh tests/k8s_shim.sh "$C" "$F" | tee "$F-k8s-shim.txt"
    k=$(sed -n 's/^k8s_shim: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\1 \2/p' "$F-k8s-shim.txt")
    if [ -n "$k" ]; then
        PASS=$((PASS + ${k% *})); FAIL=$((FAIL + ${k#* }))
    else
        fail "tests/k8s_shim.sh stopped before its summary"
    fi

    # ------------------------------------------------------------ payload
    P=$F-payload.json
    sh diskvet.sh --print-payload --docker "$C" --env tests/fixtures/test.env >"$P" 2>"$F-payload.err"
    if sh tests/check_payload.sh "$P" customer_acme payments_eu events_eu hot_eu broken_mut archive_eu mutation_ 202609 example.com "$C" "$SALT" >"$F-payload-check.txt" 2>&1; then
        ok "payload passes check_payload.sh (keys, names, forbidden strings, the salt)"
    else
        fail "payload: $(cat "$F-payload-check.txt")"
    fi
    # the salt is hashed with clickhouse local: it must not reach the server's logs
    # (checked before this test itself sends the salt in the queries below)
    ch -q "SYSTEM FLUSH LOGS"
    s1=$(printf '%s' "$SALT" | cut -c1-10); s2=$(printf '%s' "$SALT" | cut -c11-24)   # split, so this query's own text doesn't match
    x=$(chq "SELECT (SELECT count() FROM system.query_log WHERE position(query, concat('$s1', '$s2')) > 0) + (SELECT count() FROM system.text_log WHERE position(message, concat('$s1', '$s2')) > 0)")
    if [ "$x" = 0 ]; then ok "the salt is not in system.query_log or system.text_log"; else fail "the salt reached the server logs: $x rows"; fi
    x=$(chq "SELECT arrayStringConcat(groupUniqArray(Settings['readonly']), ',') FROM system.query_log WHERE log_comment = 'diskvet' AND type = 'QueryFinish'")
    if [ "$x" = 2 ]; then ok "every query of the script ran with readonly=2 (system.query_log)"; else fail "readonly seen in query_log: '$x'"; fi
    hdb=$(chq "SELECT concat('db_', leftPad(lower(hex(sipHash64('$SALT', 'customer_acme'))), 16, '0'))")
    htb=$(chq "SELECT concat('t_', leftPad(lower(hex(sipHash64('$SALT', 'customer_acme', 'payments_eu'))), 16, '0'))")
    has "$P" "\"db\": \"$hdb\", \"table\": \"$htb\"" "customer_acme.payments_eu is $hdb.$htb"
    has "$P" '"db": "default", "table": "observations"' "Langfuse table keeps its name"
    has "$P" '"db": "system", "table": "trace_log"' "system table keeps its name"
    has "$P" '"product": "langfuse"' "product in payload"
    v=$(docker exec -i "$C" clickhouse local --input-format JSONAsString --structure 'j String' -q 'SELECT isValidJSON(j) FROM table' <"$P" 2>&1)
    if [ "$v" = 1 ]; then ok "payload is valid JSON"; else fail "payload JSON: $v"; fi
    sh diskvet.sh --print-payload --docker "$C" --env /nonexistent/diskvet.env >"$F-payload-random.json" 2>"$F-payload-random.err"
    has "$F-payload-random.err" "one-time random salt" "no env file: random salt, said on stderr"
    hasnt "$F-payload-random.json" "$hdb" "random salt gives other hashes"

    # ------------------------------------------------------------ facts for the plan (before any restart: system.events resets on restart)
    {
        echo "ClickHouse $VER"
        echo "-- 3. metric names"
        chq "SELECT metric FROM system.asynchronous_metrics WHERE metric ILIKE 'Disk%default%' OR metric IN ('DiskUsed', 'DiskAvailable', 'DiskTotal', 'MaxPartCountForPartition') ORDER BY metric FORMAT TSV" | tr '\n' ' '; echo
        chq "SELECT 'asynchronous_metric_log has key column: ' || toString(count()) FROM system.columns WHERE database = 'system' AND table = 'asynchronous_metric_log' AND name = 'key'"
        chq "SELECT event, value FROM system.events WHERE event IN ('DelayedInserts', 'RejectedInserts', 'DelayedInsertsMilliseconds') SETTINGS system_events_show_zero_values = 1 FORMAT TSV" | tr '\n\t' ' ='; echo
        echo "-- 4. part_log"
        chq "SELECT 'part_log rows by database: ' || arrayStringConcat(groupArray(database || '=' || toString(c)), ' ') FROM (SELECT database, count() AS c FROM system.part_log GROUP BY database ORDER BY database)"
        echo "-- 6. DateTime64 partition key: min_time / max_time / min_date of default.observations"
        chq "SELECT min(min_time), max(max_time), min(min_date) FROM system.parts WHERE active AND database = 'default' AND table = 'observations' FORMAT TSV"
        echo "-- 7. keep_free_space (1 GiB in the test config) vs df"
        chq "SELECT 'system.disks: total=' || toString(total_space) || ' free=' || toString(free_space) || ' unreserved=' || toString(unreserved_space) || ' keep_free=' || toString(keep_free_space) FROM system.disks WHERE name = 'default'"
        docker exec "$C" sh -c 'df -B1 /var/lib/clickhouse | tail -1' | awk '{print "df: size=" $2 " used=" $3 " avail=" $4}'
        echo "-- 8. partitions of default.traces after a numeric-millisecond JSON insert"
        chq "SELECT arrayStringConcat(groupArray(partition_id), ' ') FROM system.parts WHERE active AND database = 'default' AND table = 'traces'"
        echo "-- other"
        chq "SELECT 'system.mutations has is_killed: ' || toString(count()) FROM system.columns WHERE database = 'system' AND table = 'mutations' AND name = 'is_killed'"
        chq "SELECT 'system.parts has existing_rows_count: ' || toString(count()) FROM system.columns WHERE database = 'system' AND table = 'parts' AND name = 'existing_rows_count'"
        chq "SELECT 'rows of payments_eu parts with lightweight deletes (200000 inserted, 40000 deleted): ' || toString(sum(rows)) FROM system.parts WHERE active AND database = 'customer_acme' AND table = 'payments_eu'"
    } >"$F-facts.txt" 2>&1
    sed 's/^/   | /' "$F-facts.txt"

    # ------------------------------------------------------------ 2. inside the container
    docker exec "$C" mkdir -p /tmp/chd
    docker exec -i "$C" sh -c 'cat > /tmp/chd/diskvet.sh' <diskvet.sh
    docker exec -i "$C" sh -c 'cat > /tmp/chd/checks.sql' <checks.sql
    docker exec "$C" sh /tmp/chd/diskvet.sh report --host 127.0.0.1 >"$F-report-dash.md" 2>"$F-report-dash.err"
    if [ "$(summary "$F-report-dash.md")" = "$(summary "$R")" ] && [ -n "$(summary "$R")" ]; then ok "inside the container with /bin/sh (dash): same statuses"; else fail "dash statuses differ: $(summary "$F-report-dash.md" | tr '\n' ' ')"; fi
    docker exec "$C" sh /tmp/chd/diskvet.sh --print-payload --host 127.0.0.1 >"$F-payload-dash.json" 2>/dev/null
    if sh tests/check_payload.sh "$F-payload-dash.json" customer_acme payments_eu >/dev/null 2>&1; then ok "payload from dash passes check_payload.sh"; else fail "payload from dash"; fi
    docker exec -i "$C" sh -c 'mkdir -p /tmp/chd/tests/fixtures && cat > /tmp/chd/tests/fixtures/alex.tsv' <tests/fixtures/alex.tsv
    sh diskvet.sh report --replay tests/fixtures/alex.tsv >"$F-replay-host.md" 2>&1
    if docker exec "$C" sh -c 'command -v busybox' >/dev/null 2>&1; then
        docker exec "$C" sh -c 'mkdir -p /tmp/bb && busybox --install -s /tmp/bb 2>/dev/null; PATH=/tmp/bb:$PATH busybox sh /tmp/chd/diskvet.sh report --host 127.0.0.1' >"$F-report-busybox.md" 2>"$F-report-busybox.err"
        if [ "$(summary "$F-report-busybox.md")" = "$(summary "$R")" ]; then ok "inside the container with busybox ash + busybox awk: same statuses"; else fail "busybox statuses differ: $(summary "$F-report-busybox.md" | tr '\n' ' ')"; fi
        docker exec "$C" sh -c 'PATH=/tmp/bb:$PATH busybox sh /tmp/chd/diskvet.sh report --replay /tmp/chd/tests/fixtures/alex.tsv' >"$F-replay-busybox.md" 2>&1
        if diff "$F-replay-host.md" "$F-replay-busybox.md" | grep -v '^[<>] # ClickHouse check-up' | grep -q '^[<>]'; then fail "busybox awk renders the fixture differently (see $F-replay-*.md)"; else ok "busybox awk renders the fixture byte-for-byte like the host awk"; fi
        # no clickhouse local on PATH: names can't be hashed, so no table may leave
        docker exec "$C" sh -c 'mkdir -p /tmp/nobin && printf "#!/bin/sh\nexec /usr/bin/clickhouse client \"\$@\"\n" >/tmp/nobin/clickhouse-client && chmod +x /tmp/nobin/clickhouse-client'
        docker exec "$C" sh -c 'bb=$(command -v busybox); PATH=/tmp/nobin:/tmp/bb "$bb" sh /tmp/chd/diskvet.sh --print-payload --host 127.0.0.1' >"$F-payload-nohash.json" 2>"$F-payload-nohash.err"
        if grep -q '"not_run": \[.*"tables"' "$F-payload-nohash.json" && grep -q '"tables": \[ \]' "$F-payload-nohash.json" \
            && grep -q 'cannot hash table names' "$F-payload-nohash.err" && sh tests/check_payload.sh "$F-payload-nohash.json" customer_acme payments_eu >/dev/null 2>&1; then
            ok "without clickhouse local: no tables in the payload, tables in not_run, reason on stderr"
        else
            fail "without clickhouse local: $(tail -3 "$F-payload-nohash.json") $(cat "$F-payload-nohash.err")"
        fi
    else
        echo "  skip  busybox is not in this image"
    fi
    docker exec "$C" sh /tmp/chd/diskvet.sh report --replay /tmp/chd/tests/fixtures/alex.tsv >"$F-replay-mawk.md" 2>&1 || true
    if [ -s "$F-replay-mawk.md" ] && ! diff "$F-replay-host.md" "$F-replay-mawk.md" | grep -v '^[<>] # ClickHouse check-up' | grep -q '^[<>]'; then ok "mawk renders the fixture like the host awk"; else fail "mawk renders the fixture differently"; fi

    # ------------------------------------------------------------ 3. Variant B
    sed "s/__PASSWORD__/$PW/" tests/variant_b.sql | ch --multiquery >"$F-variant-b.txt" 2>&1 || fail "variant_b.sql: $(tail -2 "$F-variant-b.txt")"
    B=$F-report-variant-b.md
    sh diskvet.sh report --docker "$C" --user diskvet --password "$PW" >"$B" 2>"$F-report-variant-b.err"
    has "$F-report-variant-b.err" "running with --readonly=1 only" "Variant B: the profile refuses the limit flags, ran with readonly=1 only"
    has "$B" "Queries ran with readonly=1." "Variant B: the report says how it ran"
    nr=$(grep -c '^| [1-7] | .* | NOT_RUN |$' "$B")
    if [ "$nr" = 0 ]; then ok "Variant B: all 7 checks ran"; else fail "Variant B: $nr checks NOT_RUN"; fi
    has "$B" "customer_acme.events_eu | 20" "Variant B user sees parts of product tables (GRANT SHOW TABLES ON *.*)"
    has "$B" "the default: this user can't read system.server_settings" "Variant B: drop limit unknown, said so"
    x=$(docker exec "$C" clickhouse-client --user diskvet --password "$PW" -q "SELECT count() FROM customer_acme.payments_eu" 2>&1)
    case $x in *ACCESS_DENIED*|*"Not enough privileges"*) ok "Variant B user cannot read product rows" ;; *) fail "Variant B user read product rows: $x" ;; esac
    x=$(docker exec "$C" clickhouse-client --user diskvet --password "$PW" -q "SELECT count() FROM system.query_log" 2>&1)
    case $x in *ACCESS_DENIED*|*"Not enough privileges"*) ok "Variant B user cannot read system.query_log" ;; *) fail "Variant B user read query_log: $x" ;; esac
    sh diskvet.sh --print-payload --docker "$C" --user diskvet --password "$PW" --env tests/fixtures/test.env >"$F-payload-variant-b.json" 2>/dev/null
    if sh tests/check_payload.sh "$F-payload-variant-b.json" customer_acme payments_eu >/dev/null 2>&1; then ok "Variant B payload passes check_payload.sh"; else fail "Variant B payload"; fi
    has "$F-payload-variant-b.json" "\"db\": \"$hdb\", \"table\": \"$htb\"" "Variant B: same hashes as the admin run"
    # A normal (not read-only) user whose profile forbids changing max_threads:
    # the limits are refused, but the queries must still run read-only.
    ch --multiquery >"$F-constraint.txt" 2>&1 <<EOF
CREATE SETTINGS PROFILE IF NOT EXISTS cons_profile SETTINGS max_threads = 4 CONST;
CREATE USER IF NOT EXISTS cons IDENTIFIED WITH sha256_password BY '$PW' HOST LOCAL SETTINGS PROFILE 'cons_profile';
GRANT SELECT ON system.* TO cons;
GRANT SHOW TABLES ON *.* TO cons;
CREATE SETTINGS PROFILE IF NOT EXISTS rw_profile SETTINGS readonly = 0 CONST;
CREATE USER IF NOT EXISTS rw IDENTIFIED WITH sha256_password BY '$PW' HOST LOCAL SETTINGS PROFILE 'rw_profile';
GRANT SELECT ON system.* TO rw;
EOF
    sh diskvet.sh report --docker "$C" --user cons --password "$PW" >"$F-report-constraint.md" 2>"$F-report-constraint.err"
    has "$F-report-constraint.err" "running with --readonly=1 only" "user with a setting constraint: limits refused, still read-only"
    ch -q "SYSTEM FLUSH LOGS"
    x=$(chq "SELECT arrayStringConcat(groupUniqArray(Settings['readonly']), ',') FROM system.query_log WHERE user = 'cons' AND type = 'QueryFinish'")
    if [ "$x" = 1 ]; then ok "user with a setting constraint: every query ran with readonly=1 (system.query_log)"; else fail "user with a setting constraint: readonly in query_log '$x'"; fi
    sh diskvet.sh report --docker "$C" --user rw --password "$PW" >"$F-report-rw.md" 2>"$F-report-rw.err"
    rc=$?
    if [ $rc -eq 3 ] && grep -q "nothing was run" "$F-report-rw.err"; then ok "user that can't be made read-only: refused, exit 3"; else fail "user that can't be made read-only: rc=$rc $(cat "$F-report-rw.err")"; fi

    # ------------------------------------------------------------ 4. fix commands from the report
    # Fix A: trace_log is over the 10 MiB test drop limit
    x=$(chq "TRUNCATE TABLE system.trace_log")
    case $x in *"Code: 359"*) ok "plain TRUNCATE of a big log is refused (Code 359, max_table_size_to_drop)" ;; *) fail "plain TRUNCATE was not refused: $x" ;; esac
    flagcmd=$(grep -m 1 "^docker exec $C sh -c 'touch " "$R")
    if [ -n "$flagcmd" ] && sh -c "$flagcmd"; then ok "flag command from the report runs"; else fail "flag command: '$flagcmd'"; fi
    x=$(chq "TRUNCATE TABLE system.trace_log")
    if [ -z "$x" ]; then ok "TRUNCATE after the flag works"; else fail "TRUNCATE after the flag: $x"; fi
    if docker exec "$C" test -e /var/lib/clickhouse/flags/force_drop_table; then fail "flag still there after TRUNCATE"; else ok "the flag is used up by one TRUNCATE"; fi
    # Fix A without the flag: the report's "SETTINGS max_table_size_to_drop = 0" variant
    ch -q "INSERT INTO system.trace_log (event_date, event_time, trace) SELECT today(), now(), arrayMap(x -> rand64(number + x), range(100)) FROM numbers(150000)"
    sh diskvet.sh report --docker "$C" >"$F-report-big-again.md" 2>/dev/null
    alt=$(grep -o 'TRUNCATE TABLE system\.trace_log SETTINGS max_table_size_to_drop = 0;' "$F-report-big-again.md" | sed -n 1p)
    x=$(chq "${alt:-SELECT 'no SETTINGS variant in the report'}")
    left=$(chq "SELECT count() FROM system.trace_log")
    if [ -n "$alt" ] && [ -z "$x" ] && [ "$left" -lt 1000 ]; then ok "TRUNCATE ... SETTINGS max_table_size_to_drop = 0 from the report works without the flag"; else fail "SETTINGS variant: '$alt' -> $x ($left rows left)"; fi
    # rows for the next step: after the restart they become trace_log_0, over the drop limit
    ch -q "INSERT INTO system.trace_log (event_date, event_time, trace) SELECT today(), now(), arrayMap(x -> rand64(number + x), range(100)) FROM numbers(30000)"
    # Fix B: generated TTL config, restart
    awk '/^```xml$/ { f = 1; next } f && /^```$/ { exit } f { print }' "$R" >"$F-ttl.xml"
    if grep -q '<ttl>' "$F-ttl.xml"; then ok "TTL config extracted ($(grep -c '</ttl>\|DELETE</engine>' "$F-ttl.xml") logs)"; else fail "no TTL config in the report"; fi
    notll_before=$(chq "SELECT count() FROM system.tables WHERE database = 'system' AND match(name, '_log\$') AND endsWith(engine, 'MergeTree') AND positionCaseInsensitive(engine_full, ' TTL ') = 0")
    docker exec -i "$C" sh -c 'cat > /etc/clickhouse-server/config.d/clickhouse-ttl.xml' <"$F-ttl.xml"
    t0=$(date +%s)
    docker restart "$C" >/dev/null
    if wait_ready; then ok "ClickHouse restarts with the generated TTL config ($(($(date +%s) - t0)) s)"; else fail "ClickHouse does not start with the TTL config"; docker logs --tail 20 "$C"; fi
    ch -q "SELECT 1 FROM system.one" >/dev/null 2>&1
    ch -q "SYSTEM FLUSH LOGS" >/dev/null 2>&1
    sleep 2
    nottl_after=$(chq "SELECT count() FROM system.tables WHERE database = 'system' AND match(name, '_log\$') AND endsWith(engine, 'MergeTree') AND positionCaseInsensitive(engine_full, ' TTL ') = 0")
    nottl_left=$(chq "SELECT arrayStringConcat(groupArray(name), ' ') FROM system.tables WHERE database = 'system' AND match(name, '_log\$') AND endsWith(engine, 'MergeTree') AND positionCaseInsensitive(engine_full, ' TTL ') = 0")
    if [ "$nottl_after" = 0 ]; then ok "every system log has a TTL after restart (was: $notll_before without)"; else fail "$nottl_after logs still without TTL after restart: $nottl_left"; fi
    copies=$(chq "SELECT count() FROM system.tables WHERE database = 'system' AND match(name, '_log_[0-9]+\$')")
    if [ "$copies" -gt 0 ]; then ok "restart renamed the old logs to *_log_N ($copies copies)"; else fail "no *_log_N copies after restart"; fi
    otel=$(chq "SELECT extract(engine_full, 'TTL [^S]*') FROM system.tables WHERE database = 'system' AND name = 'opentelemetry_span_log'")
    case $otel in *finish_date*) ok "opentelemetry_span_log TTL on finish_date: $otel" ;; *) fail "opentelemetry_span_log TTL: '$otel'" ;; esac
    # Fix C: the second report lists the copies; drop them
    R2=$F-report-after-ttl.md
    sh diskvet.sh report --docker "$C" >"$R2" 2>/dev/null
    expect "$R2" 1 'OK|INFO'
    sql_of_section "$R2" 1 | grep '^DROP TABLE system\.' >"$F-drops.sql"
    nd=$(grep -c . "$F-drops.sql")
    if [ "$nd" = "$copies" ]; then ok "report lists all $nd copies for DROP, each once"; else fail "report lists $nd DROPs for $copies copies"; fi
    # trace_log_0 is over the 10 MiB drop limit: the report gives it the flag and the SETTINGS variant
    grep -o 'DROP TABLE system\.[A-Za-z0-9_]* SETTINGS max_table_size_to_drop = 0;' "$R2" >"$F-drops-big.sql"
    if grep -qx 'DROP TABLE system.trace_log_0 SETTINGS max_table_size_to_drop = 0;' "$F-drops-big.sql"; then ok "big copy trace_log_0 gets the flag and the SETTINGS variant"; else fail "no SETTINGS variant for trace_log_0: $(cat "$F-drops-big.sql")"; fi
    x=$(chq "DROP TABLE system.trace_log_0")
    case $x in *"Code: 359"*) ok "plain DROP of the big copy is refused (Code 359)" ;; *) fail "plain DROP of the big copy was not refused: $x" ;; esac
    sed 's/ SETTINGS max_table_size_to_drop = 0;$/;/' "$F-drops-big.sql" >"$F-drops-big-plain.sql"
    grep -vxF -f "$F-drops-big-plain.sql" "$F-drops.sql" | cat - "$F-drops-big.sql" >"$F-drops-run.sql"
    ch --multiquery <"$F-drops-run.sql" >"$F-drops.txt" 2>&1 || fail "DROP: $(tail -2 "$F-drops.txt")"
    left=$(chq "SELECT count() FROM system.tables WHERE database = 'system' AND match(name, '_log_[0-9]+\$')")
    if [ "$left" = 0 ]; then ok "DROP commands from the report removed every copy"; else fail "$left copies left"; fi
    # Checks 5, 6, 7: run the SQL the first report printed (merges started again by the restart anyway)
    for n in 5 6 7; do
        sql_of_section "$R" "$n" >"$F-fix-$n.sql"
        if [ -s "$F-fix-$n.sql" ]; then
            if ch --multiquery <"$F-fix-$n.sql" >"$F-fix-$n.txt" 2>&1; then ok "check $n fix SQL runs ($(grep -c . "$F-fix-$n.sql") statements)"; else fail "check $n fix SQL: $(tail -2 "$F-fix-$n.txt")"; fi
        else
            fail "check $n printed no fix SQL"
        fi
    done
    wait_mutations customer_acme payments_eu
    wait_mutations default observations
    lwd=$(chq "SELECT count() FROM system.parts WHERE active AND has_lightweight_delete AND database IN ('customer_acme', 'default')")
    if [ "$lwd" = 0 ]; then ok "APPLY DELETED MASK cleared has_lightweight_delete"; else fail "$lwd parts still have lightweight deletes"; fi
    det=$(chq "SELECT count() FROM system.detached_parts WHERE database = 'customer_acme'")
    if [ "$det" = 0 ]; then ok "DROP DETACHED PART removed the detached part"; else fail "$det detached parts left"; fi
    mut=$(chq "SELECT count() FROM system.mutations WHERE database = 'customer_acme' AND table = 'broken_mut' AND NOT is_done")
    if [ "$mut" = 0 ]; then ok "KILL MUTATION stopped the failing mutation"; else fail "failing mutation still there"; fi
    parts=$(chq "SELECT count() FROM system.parts WHERE active AND database = 'customer_acme' AND table = 'events_eu'")
    if [ "$parts" -lt 10 ]; then ok "OPTIMIZE ... FINAL merged events_eu (310 -> $parts parts)"; else fail "events_eu still has $parts parts"; fi
    R3=$F-report-after-fixes.md
    sh diskvet.sh report --docker "$C" >"$R3" 2>/dev/null
    expect "$R3" 5 'OK'
    expect "$R3" 6 'OK'
    expect "$R3" 7 'OK'


    if [ "${KEEP:-0}" = 1 ]; then echo "   kept container $C"; else docker rm -f -v "$C" >/dev/null; fi
    echo "   $V: $PASS passed, $FAIL failed"
    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
done

echo
echo "run: $TOTAL_PASS passed, $TOTAL_FAIL failed"
[ "$TOTAL_FAIL" -eq 0 ]
