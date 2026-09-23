#!/bin/sh
# Test --docker auto the way a Langfuse user runs it: from the folder with the
# compose file, with the user and password only in the container's environment.
#   sh tests/auto.sh            # CH_VERSION=25.12 by default
# Also checks the fallback (no compose file here: find the one running
# clickhouse-server container by image) and the error when nothing runs.
set -u
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
OUT=${OUT:-$ROOT/tests/out}
mkdir -p "$OUT"
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
has()  { if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (missing: $2)"; fi; }

echo "== --docker auto with docker compose (CH_VERSION=${CH_VERSION:-25.12})"
cd tests/compose || exit 2
docker compose up -d --quiet-pull >/dev/null 2>&1 || { echo "docker compose up failed"; exit 1; }
id=$(docker compose ps -q clickhouse | tr -d '\r')
# With CLICKHOUSE_USER set, the image's entrypoint first starts a temporary
# server to create the user, stops it, then starts the real one: wait for the
# real one (it answers several times in a row).
i=0
up=0
while [ $i -lt 120 ] && [ $up -lt 3 ]; do
    if docker exec "$id" clickhouse-client --user clickhouse --password clickhouse -q 'SELECT 1' >/dev/null 2>&1; then
        up=$((up + 1))
    else
        up=0
    fi
    i=$((i + 1)); sleep 1
done
name=$(docker inspect --format '{{.Name}}' "$id" | tr -d '\r' | sed 's|^/||')

if sh "$ROOT/doctor.sh" report --docker auto >"$OUT/auto-report.md" 2>"$OUT/auto-report.err"; then ok "report with --docker auto from the compose folder"; else fail "report: $(cat "$OUT/auto-report.err")"; fi
has "$OUT/auto-report.md" "container $name" "found the compose service 'clickhouse' ($name)"
n=$(grep -c '^| [1-7] | .* | NOT_RUN |$' "$OUT/auto-report.md")
rows=$(grep -c '^| [1-7] | ' "$OUT/auto-report.md")
if [ "$rows" = 7 ] && [ "$n" = 0 ]; then ok "all checks ran with the container's CLICKHOUSE_USER / CLICKHOUSE_PASSWORD"; else fail "$n checks NOT_RUN"; fi
docker exec "$id" clickhouse-client --user clickhouse --password clickhouse -q 'SYSTEM FLUSH LOGS' >/dev/null 2>&1
x=$(docker exec "$id" clickhouse-client --user clickhouse --password clickhouse -q "SELECT arrayStringConcat(groupUniqArray(user), ',') FROM system.query_log WHERE log_comment = 'clickhouse-doctor' AND type = 'QueryFinish'" 2>&1)
if [ "$x" = clickhouse ]; then ok "queries ran as the container's CLICKHOUSE_USER, tagged log_comment=clickhouse-doctor"; else fail "users seen in query_log: '$x'"; fi
x=$(docker exec "$id" clickhouse-client --user clickhouse --password clickhouse -q "SELECT countIf(query_kind != 'Select') FROM system.query_log WHERE log_comment = 'clickhouse-doctor' AND type = 'QueryFinish'" 2>&1)
if [ "$x" = 0 ]; then ok "query_log: every query of the script was a SELECT"; else fail "non-SELECT queries in query_log: $x"; fi

# --print-payload: names are hashed by clickhouse local inside the container, as uid 101
docker exec "$id" clickhouse-client --user clickhouse --password clickhouse --multiquery \
    -q "CREATE DATABASE IF NOT EXISTS customer_acme; CREATE TABLE IF NOT EXISTS customer_acme.payments_eu (id UInt64) ENGINE = MergeTree ORDER BY id; INSERT INTO customer_acme.payments_eu VALUES (1)" >/dev/null 2>&1
sh "$ROOT/doctor.sh" --print-payload --docker auto --env "$ROOT/tests/fixtures/test.env" >"$OUT/auto-payload.json" 2>"$OUT/auto-payload.err"
salt=$(sed -n 's/^SALT=//p' "$ROOT/tests/fixtures/test.env")
if sh "$ROOT/tests/check_payload.sh" "$OUT/auto-payload.json" customer_acme payments_eu "$name" "$salt" >"$OUT/auto-payload-check.txt" 2>&1 \
    && grep -q '"db": "db_[0-9a-f]*", "table": "t_[0-9a-f]*"' "$OUT/auto-payload.json"; then
    ok "--print-payload with --docker auto: customer names hashed inside the container (clickhouse local as uid 101)"
else
    fail "payload: $(cat "$OUT/auto-payload-check.txt" "$OUT/auto-payload.err")"
fi

# The flag command from the report, as the container's own user (uid 101 in Langfuse's compose)
who=$(docker exec "$name" id -un 2>&1)
if docker exec "$name" sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table' 2>"$OUT/auto-flag.err"; then
    ok "force_drop_table flag command works as the container user ($who)"
    docker exec "$name" rm -f /var/lib/clickhouse/flags/force_drop_table
else
    fail "flag command as $who: $(cat "$OUT/auto-flag.err")"
fi

cd "$ROOT" || exit 2
running=$(docker ps --format '{{.Image}}' | tr -d '\r' | grep -c 'clickhouse-server')
if [ "$running" = 1 ]; then
    sh doctor.sh report --docker auto >"$OUT/auto-report-image.md" 2>"$OUT/auto-report-image.err"
    has "$OUT/auto-report-image.md" "container $name" "without a compose file: found the container by image"
else
    echo "  skip  $running clickhouse-server containers are running; the by-image fallback needs exactly one"
fi

cd tests/compose && docker compose down -v >/dev/null 2>&1
cd "$ROOT" || exit 2
if [ "$(docker ps --format '{{.Image}}' | tr -d '\r' | grep -c 'clickhouse-server')" = 0 ]; then
    sh doctor.sh report --docker auto >/dev/null 2>"$OUT/auto-none.err"
    rc=$?
    if [ $rc -eq 2 ] && grep -q "no running ClickHouse container found" "$OUT/auto-none.err"; then ok "nothing running: clear error, exit 2"; else fail "nothing running: rc=$rc $(cat "$OUT/auto-none.err")"; fi
    sh doctor.sh --print-payload --docker no-such-container >"$OUT/auto-none.json" 2>/dev/null
    if grep -q '"status": "ch_unreachable"' "$OUT/auto-none.json"; then ok "--print-payload for a missing container prints status ch_unreachable"; else fail "no ch_unreachable payload: $(cat "$OUT/auto-none.json")"; fi
fi

echo "auto: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
