#!/bin/sh
# Static safety test for checks.sql. No server needed.
#   sh tests/check_sql.sh [checks.sql]
# Fails when checks.sql could read anything but system.* metadata or change anything:
#   - FROM / JOIN must be followed by system.<table> or a subquery "(";
#   - no table functions (url, remote, remoteSecure, file, s3, cluster, input, ...);
#   - no SETTINGS and no FORMAT inside SQL (the wrapper sets them);
#   - no statements other than SELECT (INSERT, ALTER, DROP, TRUNCATE, CREATE, ...);
#   - one statement per "-- @query <id>" block, starting with SELECT or WITH,
#     whose first string literal (the check_id column) equals <id>.
# Comments and string literals are ignored, so a comment or a message that
# mentions TRUNCATE does not count.
set -u
f=${1:-$(dirname "$0")/../checks.sql}
[ -r "$f" ] || { echo "cannot read $f"; exit 2; }
fail=0
bad() { printf 'FAIL: %s\n' "$*"; fail=1; }

# SQL without comments and with every string literal emptied, upper-cased, one line.
code=$(sed -e 's/--.*$//' "$f" | sed -e "s/'[^']*'/''/g" | tr '\n\t' '  ' | tr '[:lower:]' '[:upper:]' | tr -s ' ')

# 1. FROM / JOIN targets
targets=$(printf '%s\n' "$code" | grep -oE '(^|[^A-Z0-9_])(FROM|JOIN) +[^ ]+' | sed -E 's/^[^A-Z]*//')
printf '%s\n' "$targets" | grep -vE '^(FROM|JOIN) +(SYSTEM\.[A-Z0-9_]+|\()' | grep . >"${TMPDIR:-/tmp}/chk_sql.$$" && {
    while read -r t; do bad "reads from something that is not system.* or a subquery: $t"; done <"${TMPDIR:-/tmp}/chk_sql.$$"
}
rm -f "${TMPDIR:-/tmp}/chk_sql.$$"
[ -n "$targets" ] || bad "no FROM found at all (parser broken?)"

# 2. table functions
tf='URL|REMOTE|REMOTESECURE|FILE|S3|S3CLUSTER|CLUSTER|CLUSTERALLREPLICAS|INPUT|HDFS|HDFSCLUSTER|MYSQL|POSTGRESQL|JDBC|ODBC|MONGODB|REDIS|SQLITE|AZUREBLOBSTORAGE|GCS|OSS|COSN|ICEBERG|DELTALAKE|HUDI|MERGE|EXECUTABLE|DICTIONARY|VIEW|VALUES|GENERATERANDOM|NUMBERS|ZEROS|FORMAT|FUZZJSON|LOOP|ARROWFLIGHT|PROMETHEUSQUERY|TIMESERIESDATA'
if printf '%s\n' "$code" | grep -qE "(^|[^A-Z0-9_])($tf) *\("; then
    bad "table function used: $(printf '%s\n' "$code" | grep -oE "(^|[^A-Z0-9_])($tf) *\(" | head -n 3 | tr '\n' ' ')"
fi

# 3. SETTINGS / FORMAT / INTO OUTFILE
printf '%s\n' "$code" | grep -qE '(^|[^A-Z0-9_])SETTINGS([^A-Z0-9_]|$)' && bad "SETTINGS inside SQL (limits belong to the wrapper)"
printf '%s\n' "$code" | grep -qE '(^|[^A-Z0-9_])FORMAT +[A-Z]' && bad "FORMAT clause inside SQL (the wrapper sets the format)"
printf '%s\n' "$code" | grep -qE '(^|[^A-Z0-9_])(OUTFILE|INFILE)([^A-Z0-9_]|$)' && bad "INTO OUTFILE / INFILE"

# 4. anything that is not a SELECT
kw='INSERT|ALTER|DROP|TRUNCATE|CREATE|DELETE|UPDATE|RENAME|ATTACH|DETACH|OPTIMIZE|KILL|GRANT|REVOKE|EXCHANGE|UNDROP|BACKUP|RESTORE|REPLACE|UPSERT|MOVE|SET|USE|EXPLAIN|WATCH|CHECK|DESCRIBE|SHOW'
hits=$(printf '%s\n' "$code" | grep -oE "(^|[^A-Z0-9_.])($kw)([^A-Z0-9_]|$)" | sed -E 's/[^A-Z]//g' | sort -u | tr '\n' ' ')
[ -z "$hits" ] || bad "non-SELECT keywords: $hits"
# SYSTEM as a statement (SYSTEM STOP MERGES ...), not system.<table>
printf '%s\n' "$code" | grep -qE '(^|[^A-Z0-9_])SYSTEM +[A-Z]' && bad "SYSTEM statement"

# 5. per-query structure
awk -v q="'" '
    function flush(   c, s, first, lit) {
        if (id == "") return
        c = body
        gsub(/--[^\n]*/, "", c)                     # comments
        s = c
        lit = q "[^" q "]*" q                         # a string literal; q is a single quote
        if (match(s, lit)) first = substr(s, RSTART + 1, RLENGTH - 2); else first = ""
        gsub(lit, q q, c)
        gsub(/[ \t\n]+/, " ", c); sub(/^ /, "", c); sub(/ $/, "", c)
        sub(/;$/, "", c)
        if (toupper(c) !~ /^(SELECT|WITH) /) printf "FAIL: query %s does not start with SELECT or WITH\n", id
        if (index(c, ";") > 0) printf "FAIL: query %s has more than one statement\n", id
        if (first != id) printf "FAIL: query %s: first string literal (check_id) is [%s]\n", id, first
        nq++
    }
    /^-- @query / { flush(); id = $3; body = ""; next }
    id != "" { body = body $0 "\n" }
    END { flush(); if (nq == 0) print "FAIL: no -- @query blocks"; else printf "info: %d queries\n", nq }
' "$f" >"${TMPDIR:-/tmp}/chk_q.$$"
grep '^info:' "${TMPDIR:-/tmp}/chk_q.$$"
if grep -q '^FAIL' "${TMPDIR:-/tmp}/chk_q.$$"; then grep '^FAIL' "${TMPDIR:-/tmp}/chk_q.$$"; fail=1; fi
rm -f "${TMPDIR:-/tmp}/chk_q.$$"

if [ "$fail" -eq 0 ]; then echo "check_sql: OK ($f)"; else echo "check_sql: FAILED ($f)"; fi
exit "$fail"
