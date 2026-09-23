#!/bin/sh
# Offline tests: render saved query results (tests/fixtures/*.tsv) and check the
# statuses, the fix commands and the payload. No server needed, so this also
# runs under dash, busybox ash + busybox awk, and mawk:
#   sh tests/replay.sh            # uses ./doctor.sh
#   busybox sh tests/replay.sh
set -u
cd "$(dirname "$0")/.." || exit 2
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
has()  { if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then fail "$3 (found: $2)"; else ok "$3"; fi; }
status_of() { sed -n "s/^| $2 | [^|]* | \([A-Z_]*\) |\$/\1/p" "$1"; }
statuses() {  # file "S1 S2 ... S7"
    got=""
    for i in 1 2 3 4 5 6 7; do got="$got $(status_of "$1" "$i")"; done
    got=${got# }
    if [ "$got" = "$2" ]; then ok "statuses: $got"; else fail "statuses: got '$got', want '$2'"; fi
}

out=${TMPDIR:-/tmp}/chd-replay.$$
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT

echo "== static SQL check"
if sh tests/check_sql.sh >"$out/sql.txt" 2>&1; then ok "checks.sql passes check_sql.sh"; else fail "checks.sql: $(cat "$out/sql.txt")"; fi
if sh tests/check_sql.sh tests/fixtures/bad_checks.sql >"$out/bad.txt" 2>&1; then
    fail "check_sql.sh accepted tests/fixtures/bad_checks.sql"
else
    n=$(grep -c '^FAIL' "$out/bad.txt")
    if [ "$n" -ge 7 ]; then ok "check_sql.sh rejects bad_checks.sql ($n findings)"; else fail "check_sql.sh found only $n problems in bad_checks.sql"; fi
fi
if sh tests/check_payload.sh tests/fixtures/bad_payload.json customer_acme >"$out/badp.txt" 2>&1; then
    fail "check_payload.sh accepted tests/fixtures/bad_payload.json"
else
    n=$(grep -c '^FAIL' "$out/badp.txt")
    if [ "$n" -ge 7 ]; then ok "check_payload.sh rejects bad_payload.json ($n findings)"; else fail "check_payload.sh found only $n problems in bad_payload.json"; fi
fi

echo "== alex.tsv: Langfuse on 25.12, the example from the plan"
r=$out/alex.md
sh doctor.sh report --replay tests/fixtures/alex.tsv --docker langfuse-clickhouse-1 >"$r" 2>"$out/alex.err"
statuses "$r" "CRITICAL WARN WARN WARN OK OK WARN"
has "$r" "detected: Langfuse" "product detected"
has "$r" "88.7 GiB of ClickHouse's own logs vs 5.4 GiB of Langfuse data" "logs vs data line"
has "$r" "docker exec langfuse-clickhouse-1 sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'" "flag recipe for trace_log over 50 GB"
has "$r" "TRUNCATE TABLE system.trace_log SETTINGS max_table_size_to_drop = 0;" "per-query alternative to the flag"
has "$r" "TRUNCATE TABLE system.text_log;" "plain TRUNCATE for text_log (14.2 GiB < 50 GB)"
hasnt "$r" "TRUNCATE TABLE system.opentelemetry_span_log" "no TRUNCATE for a 1 MiB log"
has "$r" "<ttl>event_date + INTERVAL 7 DAY DELETE</ttl>" "TTL config generated"
has "$r" "ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>" "opentelemetry_span_log TTL inside <engine> with finish_date"
hasnt "$r" "<processors_profile_log>" "no TTL config for a log that has TTL"
has "$r" "DROP TABLE system.trace_log_0;" "old copy listed for DROP"
has "$r" "TTL 30 d, but the oldest row is 45 d old" "TTL present but old rows warned"
has "$r" "Not in table parts: 30.7 GiB" "space not in parts"
has "$r" "95% full in ~12 days" "rough forecast"
has "$r" "APPLY DELETED MASK IN PARTITION ID '202608';" "APPLY DELETED MASK with the real partition"
has "$r" "Before upgrading ClickHouse to 26.8+, update Langfuse first" "Langfuse version heads-up"
has "$r" "Free beta until Nov 7" "beta line"
has "$r" "<site>/beta" "beta URL placeholder"

p=$out/alex.json
sh doctor.sh --print-payload --replay tests/fixtures/alex.tsv >"$p" 2>/dev/null
if sh tests/check_payload.sh "$p" customer_acme payments_eu 202608 langfuse-clickhouse-1 >"$out/p.txt" 2>&1; then ok "payload passes check_payload.sh"; else fail "payload: $(cat "$out/p.txt")"; fi
has "$p" '"db": "db_00a41f09c2d1e0b7", "table": "t_3f9a1c2e0b77d104"' "customer table stays hashed"
has "$p" '"table": "observations"' "Langfuse table name kept"
has "$p" '"ttl_days": 30' "ttl_days for a log with TTL"
has "$p" '"lwd_parts": 3, "lwd_parts_bytes": 1932735283' "lightweight delete counters"

echo "== worst.tsv: everything on fire, ClickHouse 26.9, restricted user"
r=$out/worst.md
sh doctor.sh report --replay tests/fixtures/worst.tsv >"$r" 2>/dev/null
statuses "$r" "CRITICAL CRITICAL CRITICAL CRITICAL CRITICAL CRITICAL CRITICAL"
has "$r" "50 GB, the default: this user can't read system.server_settings" "unknown drop limit is said out loud"
has "$r" "DROP TABLE system.query_log_1;" "old copy _1"
has "$r" "DROP TABLE system.query_log_2;" "old copy _2"
has "$r" "sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'" "Docker log sizes command"
has "$r" "max-size: \"50m\"" "Docker log rotation"
has "$r" "SYSTEM START MERGES default.events_full;" "start merges"
has "$r" "OPTIMIZE TABLE default.events_full PARTITION ID '202609' FINAL;" "OPTIMIZE with warning"
has "$r" "17 rejected" "rejected inserts"
has "$r" "ALTER TABLE default.traces DROP DETACHED PART '202608_1_1_0' SETTINGS allow_drop_detached = 1;" "drop detached part"
has "$r" "KILL MUTATION WHERE database = 'default' AND table = 'traces' AND mutation_id = 'mutation_42.txt';" "kill failing mutation"
has "$r" "5 active parts in partitions of year 9999" "year 9999 partitions (langfuse#16858)"
has "$r" "ClickHouse 26.9 with Langfuse: make sure your Langfuse includes the DateTime64 fix" "26.8+ heads-up"
has "$r" "/data/clickhouse/flags/force_drop_table" "flag path follows the disk path"
p=$out/worst.json
sh doctor.sh --print-payload --replay tests/fixtures/worst.tsv >"$p" 2>/dev/null
if sh tests/check_payload.sh "$p" customer_acme mutation_42 202608_1_1_0 >"$out/p2.txt" 2>&1; then ok "payload passes check_payload.sh"; else fail "payload: $(cat "$out/p2.txt")"; fi
has "$p" '"rejected_inserts": 17' "rejected inserts in payload"
has "$p" '"mutations_failing": 1' "failing mutations in payload"

echo "== notrun.tsv: every query failed"
r=$out/notrun.md
sh doctor.sh report --replay tests/fixtures/notrun.tsv >"$r" 2>/dev/null
statuses "$r" "NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN"
has "$r" "Could not run: Code: 60. Table system.part_log does not exist." "reason shown"
p=$out/notrun.json
sh doctor.sh --print-payload --replay tests/fixtures/notrun.tsv >"$p" 2>/dev/null
has "$p" '"not_run": ["passport", "system_logs", "not_in_parts", "disk_now", "growth_24h", "too_many_parts", "inactive_parts", "deleted_rows", "mutations", "tables"]' "not_run lists required queries only"
if sh tests/check_payload.sh "$p" >"$out/p3.txt" 2>&1; then ok "empty payload passes check_payload.sh"; else fail "payload: $(cat "$out/p3.txt")"; fi

echo "== command line"
sh doctor.sh push >/dev/null 2>"$out/push.err"
if [ $? -eq 2 ] && grep -q "not available yet" "$out/push.err"; then ok "push says not available yet"; else fail "push"; fi
sh doctor.sh --bogus >/dev/null 2>&1
if [ $? -eq 2 ]; then ok "unknown option rejected"; else fail "unknown option accepted"; fi
if sh doctor.sh --help | grep -q -- '--print-payload'; then ok "--help"; else fail "--help"; fi

echo
echo "replay: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
