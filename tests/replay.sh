#!/bin/sh
# Offline tests: render saved query results (tests/fixtures/*.tsv), check the
# statuses, the fix commands and the payload, and cmp them with tests/fixtures/golden/.
# No server needed, so this also runs under dash, busybox ash + busybox awk, and mawk:
#   sh tests/replay.sh            # uses ./diskvet.sh
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
    if [ "$n" -ge 8 ] && grep -q "^FAIL: query _target: query id" "$out/bad.txt"; then ok "check_sql.sh rejects bad_checks.sql ($n findings, the reserved id _target too)"; else fail "check_sql.sh found only $n problems in bad_checks.sql, or missed the reserved id _target"; fi
fi
sh tests/check_sql.sh tests/fixtures/bad_checks_tricky.sql >"$out/tricky.txt" 2>&1
missed=""
sed -n 's/^-- @query \([a-z0-9_]*\).*/\1/p' tests/fixtures/bad_checks_tricky.sql >"$out/tricky.ids"
while read -r q; do
    grep -q "^FAIL: query $q:" "$out/tricky.txt" || missed="$missed $q"
done <"$out/tricky.ids"
if [ -z "$missed" ]; then ok "check_sql.sh catches every trick in bad_checks_tricky.sql (strings, comments, comma joins, IN, dictGet, heredocs, query logs)"; else fail "check_sql.sh missed:$missed"; fi
if sh tests/check_payload.sh tests/fixtures/bad_payload.json customer_acme >"$out/badp.txt" 2>&1; then
    fail "check_payload.sh accepted tests/fixtures/bad_payload.json"
else
    n=$(grep -c '^FAIL' "$out/badp.txt")
    if [ "$n" -ge 7 ]; then ok "check_payload.sh rejects bad_payload.json ($n findings)"; else fail "check_payload.sh found only $n problems in bad_payload.json"; fi
fi

echo "== the render awk: no \"(\" right after a variable (busybox awk up to 1.33)"
# busybox awk up to 1.33 reads "name (" as a call of a function "name", so
# `s = s p ((x) ? a : b)` stops the render with "Call to undefined function"
# (busybox 1.35 and later, mawk and gawk take it as a concatenation). This
# lint reads the render awk of diskvet.sh (between its __RENDER_AWK__ lines)
# without strings, regex literals and comments, and prints every name before
# a "(" that is not a keyword, a builtin or a function of the program.
cat >"$out/parenlint.awk" <<'EOF'
BEGIN {
    split("if while for do else return in delete print printf getline next exit function func BEGIN END " \
        "length substr index split sub gsub match sprintf sin cos atan2 exp log sqrt int rand srand tolower toupper system close fflush", w, " ")
    for (i in w) known[w[i]] = 1
}
FNR == 1 { on = 0 }
/^cat >"\$tmp\/render\.awk" <<'__RENDER_AWK__'$/ { on = 1; next }
/^__RENDER_AWK__$/ { on = 0; next }
!on { next }
{ src[++nl] = $0; lno[nl] = FNR; if (match($0, /^function [A-Za-z_][A-Za-z0-9_]*/)) known[substr($0, 10, RLENGTH - 9)] = 1 }
END {
    for (k = 1; k <= nl; k++) {
        t = strip(src[k])
        while (match(t, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/)) {
            nm = substr(t, RSTART, RLENGTH - 1); sub(/[ \t]+$/, "", nm)
            pre = (RSTART > 1) ? substr(t, RSTART - 1, 1) : ""
            if (pre !~ /[A-Za-z0-9_.]/ && !(nm in known)) { print "line " lno[k] ": " nm " (: " src[k]; bad++ }
            t = substr(t, RSTART + RLENGTH)
        }
    }
    exit bad ? 1 : 0
}
# the line without its strings (each becomes ""), regex literals (//) and comment
function strip(s,   out, i, c, n, last) {
    out = ""; n = length(s); last = ""
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\"") {
            for (i++; i <= n; i++) { c = substr(s, i, 1); if (c == "\\") i++; else if (c == "\"") break }
            out = out "\"\""; last = "\""; continue
        }
        if (c == "#") break
        if (c == "/" && (last == "" || index("(,~!&|{};=", last))) {
            for (i++; i <= n; i++) {
                c = substr(s, i, 1)
                if (c == "\\") i++
                else if (c == "[") { i++; if (substr(s, i, 1) == "^") i++; if (substr(s, i, 1) == "]") i++; while (i <= n && substr(s, i, 1) != "]") i++ }
                else if (c == "/") break
            }
            out = out "//"; last = "/"; continue
        }
        out = out c
        if (c != " " && c != "\t") last = c
    }
    return out
}
EOF
if awk -f "$out/parenlint.awk" diskvet.sh >"$out/paren.txt" 2>&1; then ok "the render awk has no name followed by ( that busybox 1.33 reads as a call"; else fail "the render awk: $(cat "$out/paren.txt")"; fi
# the lint itself: the line of diskvet 0.3.0 that broke busybox 1.33, and friends
# shellcheck disable=SC2016
for m in 's = s p ((x) ? a : b) ":"' 's = s (x)' 'q = a / b (c)' 'if (x ~ /y/) s = s p (1)'; do
    printf 'cat >"$tmp/render.awk" <<'\''__RENDER_AWK__'\''\nfunction f(x) { return x }\n{ %s }\n__RENDER_AWK__\n' "$m" >"$out/paren.sh"
    if awk -f "$out/parenlint.awk" "$out/paren.sh" >/dev/null 2>&1; then fail "the paren lint misses: $m"; else ok "the paren lint catches: $m"; fi
done
# shellcheck disable=SC2016
printf 'cat >"$tmp/render.awk" <<'\''__RENDER_AWK__'\''\nfunction f(x) { return x }\n{ s = s p "" ((x) ? a : b); n = length (s) + f(1) / (2); if ($0 ~ /a (b)/) y = "c (d)" } # e (f)\n__RENDER_AWK__\n' >"$out/paren.sh"
if awk -f "$out/parenlint.awk" "$out/paren.sh" >"$out/paren.txt" 2>&1; then ok "the paren lint passes strings, regexes, comments, builtins and functions"; else fail "the paren lint refuses good awk: $(cat "$out/paren.txt")"; fi

echo "== alex.tsv: Langfuse on 25.12, the example from the plan"
r=$out/alex.md
sh diskvet.sh report --replay tests/fixtures/alex.tsv --docker langfuse-clickhouse-1 >"$r" 2>"$out/alex.err"
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
has "$r" "Join early access (free beta)" "beta line"
has "$r" "github.com/Protemir/diskvet#early-access" "beta URL"

p=$out/alex.json
sh diskvet.sh --print-payload --replay tests/fixtures/alex.tsv >"$p" 2>/dev/null
if sh tests/check_payload.sh "$p" customer_acme payments_eu 202608 langfuse-clickhouse-1 >"$out/p.txt" 2>&1; then ok "payload passes check_payload.sh"; else fail "payload: $(cat "$out/p.txt")"; fi
has "$p" '"db": "db_00a41f09c2d1e0b7", "table": "t_3f9a1c2e0b77d104"' "customer table stays hashed"
has "$p" '"table": "observations"' "Langfuse table name kept"
has "$p" '"ttl_days": 30' "ttl_days for a log with TTL"
has "$p" '"lwd_parts": 3, "lwd_parts_bytes": 1932735283' "lightweight delete counters"

echo "== worst.tsv: everything on fire, ClickHouse 26.9, restricted user"
r=$out/worst.md
sh diskvet.sh report --replay tests/fixtures/worst.tsv >"$r" 2>/dev/null
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
sh diskvet.sh --print-payload --replay tests/fixtures/worst.tsv >"$p" 2>/dev/null
if sh tests/check_payload.sh "$p" customer_acme mutation_42 202608_1_1_0 >"$out/p2.txt" 2>&1; then ok "payload passes check_payload.sh"; else fail "payload: $(cat "$out/p2.txt")"; fi
has "$p" '"rejected_inserts": 17' "rejected inserts in payload"
has "$p" '"mutations_failing": 1' "failing mutations in payload"

echo "== notrun.tsv: every query failed"
r=$out/notrun.md
sh diskvet.sh report --replay tests/fixtures/notrun.tsv >"$r" 2>/dev/null
statuses "$r" "NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN"
has "$r" "Could not run: Code: 60. Table system.part_log does not exist." "reason shown"
p=$out/notrun.json
sh diskvet.sh --print-payload --replay tests/fixtures/notrun.tsv >"$p" 2>/dev/null
has "$p" '"not_run": ["passport", "system_logs", "not_in_parts", "disk_now", "growth_24h", "too_many_parts", "inactive_parts", "deleted_rows", "mutations", "tables"]' "not_run lists required queries only"
if sh tests/check_payload.sh "$p" >"$out/p3.txt" 2>&1; then ok "empty payload passes check_payload.sh"; else fail "payload: $(cat "$out/p3.txt")"; fi

echo "== golden files: docker and local renders are byte-identical to v0.2.2"
# tests/fixtures/golden/ holds what v0.2.2 printed for these fixtures, frozen
# before the Kubernetes work: the reports without their date line, the payload
# without sent_at. New report text must not reach docker or local reports, so
# only the version number may differ. Never regenerate them to make this pass.
ver=$(sed -n 's/^VERSION=//p' diskvet.sh | sed 's/\./\\./g')
same() {  # NAME FILE: FILE, minus the date line and sent_at, with this version written as 0.2.2, is golden/NAME
    g=tests/fixtures/golden/$1
    sed -e '/^# ClickHouse check-up /d' -e 's/"sent_at": "[^"]*", //' \
        -e "s|diskvet $ver|diskvet 0.2.2|g" -e "s|\"diskvet/$ver\"|\"diskvet/0.2.2\"|" "$2" >"$2.cmp"
    if cmp -s "$g" "$2.cmp"; then
        ok "$1 is byte-identical to the v0.2.2 render"
    else
        fail "$1: $(cmp "$g" "$2.cmp" 2>&1)"
        diff "$g" "$2.cmp" 2>/dev/null | head -20
    fi
}
sh diskvet.sh report --replay tests/fixtures/alex.tsv >"$out/alex-local.md" 2>/dev/null
sh diskvet.sh report --replay tests/fixtures/worst.tsv --docker langfuse-clickhouse-1 >"$out/worst-docker.md" 2>/dev/null
same alex-docker.md "$out/alex.md"
same alex.md "$out/alex-local.md"
same worst-docker.md "$out/worst-docker.md"
same worst.md "$out/worst.md"
same notrun.md "$out/notrun.md"
same alex-payload.json "$out/alex.json"

echo "== a disk path that is not a plain path never reaches a printed shell command"
# TSV sends a ' in the path as \'; inside sh -c '...' it would end the quotes and
# run the rest where the command is pasted (as root, with sudo)
qpath="/var/lib/clickhouse/\\\\'\$(id>/tmp/pwned)\\\\'/"   # awk -v makes each \\ one \
awk -F '\t' -v p="$qpath" 'BEGIN { OFS = "\t" } $1 == "disk_now" && $2 == "default" { $3 = p } 1' tests/fixtures/alex.tsv >"$out/quote.tsv"
has "$out/quote.tsv" "/var/lib/clickhouse/\\'\$(id>/tmp/pwned)\\'/" "the test file has the path as TSV sends it"
sh diskvet.sh report --replay "$out/quote.tsv" --docker x >"$out/quote-docker.md" 2>/dev/null
hasnt "$out/quote-docker.md" "pwned" "docker: the path is in no printed command"
has "$out/quote-docker.md" "docker exec x sh -c 'touch <data path>/flags/force_drop_table && chmod 666 <data path>/flags/force_drop_table'" "docker: the flag line gets <data path>"
sh diskvet.sh report --replay "$out/quote.tsv" >"$out/quote-local.md" 2>/dev/null
hasnt "$out/quote-local.md" "pwned" "local: the path is in no printed command"
has "$out/quote-local.md" "sudo sh -c 'touch <data path>/flags/force_drop_table && chmod 666 <data path>/flags/force_drop_table'" "local: the flag line gets <data path>"

echo "== command line"
sh diskvet.sh push >/dev/null 2>"$out/push.err"
if [ $? -eq 2 ] && grep -q "not available yet" "$out/push.err"; then ok "push says not available yet"; else fail "push"; fi
sh diskvet.sh --bogus >/dev/null 2>&1
if [ $? -eq 2 ]; then ok "unknown option rejected"; else fail "unknown option accepted"; fi
if sh diskvet.sh --help | grep -q -- '--print-payload'; then ok "--help"; else fail "--help"; fi

echo "== --k8s with a fake kubectl (tests/k8s_offline.sh)"
# its checks count here too; no summary line means it stopped early
sh tests/k8s_offline.sh | tee "$out/k8s.txt"
k=$(sed -n 's/^k8s_offline: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\1 \2/p' "$out/k8s.txt")
if [ -n "$k" ]; then
    PASS=$((PASS + ${k% *})); FAIL=$((FAIL + ${k#* }))
else
    fail "tests/k8s_offline.sh stopped before its summary"
fi

echo
echo "replay: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
