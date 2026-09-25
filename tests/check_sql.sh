#!/bin/sh
# Static safety test for checks.sql. No server needed.
#   sh tests/check_sql.sh [checks.sql]
# Fails when checks.sql could read anything but system.* metadata or change anything:
#   - FROM / JOIN must be followed by a subquery "(" or by one of the system
#     tables in ALLOWED below (so never system.query_log, system.processes, ...);
#   - no comma joins ("FROM system.parts, other.table") and no "IN <table>";
#   - no table functions (url, remote, remoteSecure, file, s3, cluster, input, ...)
#     and no functions that read other tables or dictionaries (dictGet, joinGet, ...)
#     or reveal identities (hostName, currentUser, ...; currentUser() is allowed in
#     the passport only, whose ran_as column the payload never reads);
#   - no SETTINGS, no FORMAT and no INTO OUTFILE inside SQL (the wrapper sets them);
#   - no statements other than SELECT (INSERT, ALTER, DROP, TRUNCATE, CREATE, SYSTEM, ...);
#   - one statement per "-- @query <id>" block, starting with SELECT or WITH,
#     whose first string literal (the check_id column) equals <id>;
#   - <id> is lower-case letters, digits and _, and does not start with _
#     (diskvet reserves those ids for its own sections, such as _target).
# The SQL is tokenized the way ClickHouse reads it: string literals with \ and ''
# escapes, "--" and "/* */" comments only outside strings. Characters the
# checks do not need outside string literals (quoted identifiers, "#" comments,
# $$ heredocs, {query parameters}, backslashes) are refused, so nothing can
# hide code from this test. Every finding names the query.
set -u
f=${1:-$(dirname "$0")/../checks.sql}
[ -r "$f" ] || { echo "cannot read $f"; exit 2; }
out=${TMPDIR:-/tmp}/chk_sql.$$
trap 'rm -f "$out"' EXIT

awk -v Q="'" '
BEGIN {
    split("TABLES PARTS DISKS DETACHED_PARTS MERGE_TREE_SETTINGS MUTATIONS PART_LOG " \
          "ASYNCHRONOUS_METRIC_LOG ASYNCHRONOUS_METRICS EVENTS SERVER_SETTINGS", a, " ")
    for (i in a) ALLOWED[a[i]] = 1
    # table functions, and functions that read other tables, dictionaries or identities
    split("URL REMOTE REMOTESECURE FILE S3 S3CLUSTER CLUSTER CLUSTERALLREPLICAS INPUT HDFS " \
          "HDFSCLUSTER MYSQL POSTGRESQL JDBC ODBC MONGODB REDIS SQLITE AZUREBLOBSTORAGE " \
          "AZUREBLOBSTORAGECLUSTER GCS OSS COSN ICEBERG ICEBERGS3 DELTALAKE HUDI MERGE " \
          "EXECUTABLE DICTIONARY VIEW VALUES GENERATERANDOM NUMBERS NUMBERS_MT ZEROS ZEROS_MT " \
          "FORMAT FUZZJSON FUZZQUERY LOOP ARROWFLIGHT PROMETHEUSQUERY TIMESERIESDATA " \
          "TIMESERIESMETRICS TIMESERIESTAGS MERGETREEINDEX MERGETREEPROJECTION " \
          "JOINGET JOINGETORNULL DICTGET DICTGETORDEFAULT DICTGETORNULL DICTHAS DICTISIN " \
          "DICTGETHIERARCHY DICTGETCHILDREN DICTGETDESCENDANTS DICTGETALL " \
          "HOSTNAME FQDN GETMACRO SERVERUUID CURRENTUSER USER CURRENTPROFILES CURRENTROLES " \
          "ENABLEDPROFILES ENABLEDROLES DEFAULTPROFILES DEFAULTROLES", b, " ")
    for (i in b) BADFN[b[i]] = 1
    split("INSERT ALTER DROP TRUNCATE CREATE DELETE UPDATE RENAME ATTACH DETACH OPTIMIZE " \
          "KILL GRANT REVOKE EXCHANGE UNDROP BACKUP RESTORE REPLACE UPSERT MOVE SET USE " \
          "EXPLAIN WATCH CHECK DESCRIBE SHOW SYSTEM SETTINGS OUTFILE INFILE", c, " ")
    for (i in c) BADKW[c[i]] = 1
    # words that may follow a table in FROM / JOIN (anything else is an alias)
    split("WHERE PREWHERE GROUP ORDER LIMIT OFFSET HAVING JOIN LEFT RIGHT INNER OUTER " \
          "FULL CROSS ANY ALL ASOF SEMI ANTI ARRAY GLOBAL ON USING UNION EXCEPT " \
          "INTERSECT FINAL SAMPLE WINDOW QUALIFY SETTINGS FORMAT INTO PASTE", d, " ")
    for (i in d) FOLLOW[d[i]] = 1
    nq = 0
}
function bad(msg) { printf "FAIL: query %s: %s\n", id, msg; nbad++ }

# Tokenize body into T[1..nt]: upper-case words, "(" ")" "," ";" and the
# placeholder LIT for every string literal. Sets first (the first literal).
function tokenize(b,   n, i, ch, nx, j, lit, code) {
    n = length(b); i = 1; code = ""; first = ""; nlit = 0
    while (i <= n) {
        ch = substr(b, i, 1); nx = substr(b, i + 1, 1)
        if (ch == "-" && nx == "-") {                       # -- comment
            j = index(substr(b, i), "\n"); i = (j == 0) ? n + 1 : i + j; code = code " "; continue
        }
        if (ch == "/" && nx == "*") {                       # /* comment */
            j = index(substr(b, i + 2), "*/")
            if (j == 0) { bad("unterminated /* comment"); return 0 }
            i = i + 2 + j + 1; code = code " "; continue
        }
        if (ch == Q) {                                      # string literal
            j = i + 1; lit = ""
            while (1) {
                if (j > n) { bad("unterminated string literal"); return 0 }
                ch = substr(b, j, 1)
                if (ch == "\\") { lit = lit substr(b, j, 2); j += 2; continue }
                if (ch == Q) {
                    if (substr(b, j + 1, 1) == Q) { lit = lit Q; j += 2; continue }
                    break
                }
                lit = lit ch; j++
            }
            nlit++; if (nlit == 1) first = lit
            code = code " LIT "; i = j + 1; continue
        }
        if (ch ~ /[A-Za-z0-9_.]/) { code = code toupper(ch); i++; continue }
        if (index(" \t\r\n", ch)) { code = code " "; i++; continue }
        if (index("(),;*+/%=<>!-[]", ch)) { code = code " " ch " "; i++; continue }
        bad("character [" ch "] outside a string literal is not allowed (quoted identifiers, # comments, $$ strings, {parameters} and backslashes could hide code)")
        return 0
    }
    nt = split(code, T, " ")
    return 1
}

# index of the token after the group that starts at T[k] == "("
function skip_group(k,   depth) {
    depth = 0
    for (; k <= nt; k++) {
        if (T[k] == "(") depth++
        else if (T[k] == ")") { depth--; if (depth == 0) return k + 1 }
    }
    return nt + 1
}

function flush(   k, t, nxt, tbl, after, stmt_end) {
    if (id == "") return
    nq++
    if (id !~ /^[a-z0-9][a-z0-9_]*$/) bad("query id must be lower-case letters, digits and _, not starting with _ (reserved for diskvet)")
    if (!tokenize(body)) return
    if (nt == 0) { bad("empty"); return }
    if (T[1] != "SELECT" && T[1] != "WITH") bad("does not start with SELECT or WITH")
    stmt_end = nt
    if (T[nt] == ";") stmt_end = nt - 1
    if (first != id) bad("first string literal (check_id) is [" first "], want [" id "]")
    for (k = 1; k <= stmt_end; k++) {
        t = T[k]; nxt = (k < nt) ? T[k + 1] : ""
        if (t == ";") bad("more than one statement")
        if (t in BADKW && nxt != "(") bad("keyword " t " (only SELECT is allowed, no SETTINGS / OUTFILE)")
        if (t == "FORMAT" && nxt != "(") bad("FORMAT clause (the wrapper sets the format)")
        if (t in BADFN && nxt == "(" && !(t == "CURRENTUSER" && id == "passport"))
            bad("function " t "() reads outside system metadata or reveals identities")
        if (t == "IN" && nxt != "(") bad("IN " nxt ": IN must be followed by a list or a subquery in parentheses")
        if (t ~ /^SYSTEM\./) {
            tbl = substr(t, 8)
            if (!(tbl in ALLOWED)) bad("system table " t " is not on the allowed list")
        }
        if (t == "FROM" || t == "JOIN") {
            if (nxt == "(") after = skip_group(k + 1)
            else if (nxt ~ /^SYSTEM\.[A-Z0-9_]+$/) after = k + 2
            else { bad(t " " nxt ": reads from something that is not an allowed system table or a subquery"); continue }
            # optional alias, then a comma would be a comma join
            if (T[after] == "AS") after += 2
            else if (T[after] ~ /^[A-Z_][A-Z0-9_]*$/ && !(T[after] in FOLLOW) && T[after] != "LIT") after++
            if (T[after] == ",") bad("comma join after " t " " nxt)
        }
    }
}
/^-- @query / { flush(); id = $3; body = ""; next }
id != "" { body = body $0 "\n" }
END {
    flush()
    if (nq == 0) { print "FAIL: no -- @query blocks"; nbad++ }
    printf "info: %d queries\n", nq
    exit (nbad > 0)
}
' "$f" >"$out"
rc=$?
cat "$out"
if [ "$rc" -eq 0 ] && ! grep -q '^FAIL' "$out"; then echo "check_sql: OK ($f)"; exit 0; fi
echo "check_sql: FAILED ($f)"
exit 1
