#!/bin/sh
# --k8s against a real ClickHouse server, without a cluster: the fake kubectl
# (tests/fixtures/fake-kubectl/kubectl, KFAKE_EXEC=docker) turns diskvet's
# "kubectl exec -i -n default CONTAINER -c clickhouse -- CMD" into
# "docker exec -i -u 101:101 [-e K=V]... CONTAINER CMD". So the test container
# of tests/run.sh is the pod, and CMD runs as uid 101, as in a ClickHouse pod
# with runAsUser: 101. No cluster is ever contacted: KUBECONFIG=/dev/null, and
# the fake is first on PATH (the test stops if it is not).
# Called by tests/run.sh right after its step 1, before run.sh itself sends the
# salt in a query. On its own, only on a freshly seeded container:
#   sh tests/k8s_shim.sh CONTAINER [OUT_PREFIX]     # results: OUT_PREFIX-k8s-*
# Checks:
#   - the status table of --k8s default/CONTAINER is the one of --docker CONTAINER;
#   - the pod's CLICKHOUSE_USER / CLICKHOUSE_PASSWORD log in: "user clickhouse" in the header;
#   - Bitnami's CLICKHOUSE_ADMIN_USER with CLICKHOUSE_ADMIN_PASSWORD, and with
#     CLICKHOUSE_ADMIN_PASSWORD_FILE, log in as bn_admin (both users: tests/seed.sql);
#   - every query_log row of diskvet is a Select with readonly=2;
#   - --print-payload hashes the names inside the pod: with the same SALT, the
#     same tables as --docker;
#   - the salt is not in query_log, text_log or any kubectl command line, and
#     no password is in any kubectl command line;
#   - the kubectl flag line the report prints creates the flag as uid 101, and
#     the TRUNCATE it guards then passes the drop limit.
set -u
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV
cd "$(dirname "$0")/.." || exit 2
C=${1:?usage: sh tests/k8s_shim.sh CONTAINER [OUT_PREFIX]}
F=${2:-tests/out/$C}
mkdir -p "$(dirname "$F")" || exit 2
SALT=$(sed -n 's/^SALT=//p' tests/fixtures/test.env)
# the passwords of the two logins in tests/seed.sql
pw_of() { sed -n "s/^CREATE USER IF NOT EXISTS $1 IDENTIFIED WITH sha256_password BY '\([^']*\)'.*/\1/p" tests/seed.sql; }
CHPW=$(pw_of clickhouse)
BNPW=$(pw_of bn_admin)
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
has()  { if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then fail "$3 (found: $2)"; else ok "$3"; fi; }
summary() { sed -n '/^| # | Check | Status |$/,/^$/p' "$1"; }
ch() { docker exec -i "$C" clickhouse-client "$@"; }
chq() { docker exec -i "$C" clickhouse-client -q "$1" 2>&1; }

if [ -z "$CHPW" ] || [ -z "$BNPW" ]; then
    echo "k8s_shim: no clickhouse / bn_admin login in tests/seed.sql; stopping"
    exit 2
fi
W=$(mktemp -d 2>/dev/null) || W=""
if [ -z "$W" ] || [ ! -d "$W" ]; then
    W=${TMPDIR:-/tmp}/chd-shim.$$
    mkdir -p "$W" || exit 2
fi
trap 'rm -rf "$W"' EXIT
mkdir "$W/bin" "$W/pods" || exit 2
# only the fake kubectl: clickhouse-client is the real one, in the container.
# A copied checkout may have lost the +x bit.
cp tests/fixtures/fake-kubectl/kubectl "$W/bin/" && chmod +x "$W/bin/kubectl" || exit 2
# the container, listed as the pod default/CONTAINER (kubectl's custom-columns layout)
img=$(docker inspect --format '{{.Config.Image}}' "$C" 2>/dev/null | tr -d '\r')
if [ -z "$img" ]; then
    echo "k8s_shim: no container $C; stopping"
    exit 2
fi
printf 'default   %s   Running   clickhouse   %s   data-%s   <none>   <none>   <none>   <none>   StatefulSet\n' \
    "$C" "$img" "$C" >"$W/pods/pods.shim"

PATH=$W/bin:$PATH
KUBECONFIG=/dev/null
KLOG=$W/klog
KFAKE=shim
KFAKE_PODS=$W/pods
KFAKE_EXEC=docker
KFAKE_DOCKER=$C
KFAKE_DOCKER_USER=101:101
export PATH KUBECONFIG KLOG KFAKE KFAKE_PODS KFAKE_EXEC KFAKE_DOCKER KFAKE_DOCKER_USER
unset KFAKE_CTX KFAKE_NS KFAKE_FORBID_ALL KFAKE_CRLF KFAKE_ENV KFAKE_PODPATH KFAKE_PRINTED \
    KFAKE_AUTH KFAKE_PROFILE_RO KFAKE_STREAM CLOG DISKVET_EXEC_TIMEOUT
if [ "$(command -v kubectl)" != "$W/bin/kubectl" ]; then
    echo "k8s_shim: the fake kubectl is not first on PATH ($(command -v kubectl)); stopping"
    exit 2
fi
: >"$KLOG"

# k8s_run "K=V ..." ARGS...: diskvet with the words as the pod's environment
k8s_run() { _e=$1; shift; KFAKE_ENV=$_e sh diskvet.sh "$@" </dev/null; }
pod=default/$C
official="CLICKHOUSE_USER=clickhouse CLICKHOUSE_PASSWORD=$CHPW"
bitnami="CLICKHOUSE_USER= CLICKHOUSE_PASSWORD= CLICKHOUSE_ADMIN_USER=bn_admin"

# ------------------------------------------------------------ report
D=$F-k8s-docker.md
K=$F-k8s-report.md
sh diskvet.sh report --docker "$C" >"$D" 2>"$D.err" </dev/null
if k8s_run "$official" report --k8s "$pod" >"$K" 2>"$K.err"; then ok "--k8s $pod through the fake kubectl: exit 0"; else fail "--k8s $pod: exit $?: $(cat "$K.err")"; fi
has "$K.err" "kubectl context fake-ctx · pod $pod · container clickhouse" "--k8s: the pod and container announced on stderr"
if [ -n "$(summary "$D")" ] && [ "$(summary "$K")" = "$(summary "$D")" ]; then
    ok "--k8s: the status table equals the one of --docker $C"
else
    fail "--k8s: status table $(summary "$K" | tr '\n' ' ')differs from --docker: $(summary "$D" | tr '\n' ' ')"
fi
nr=$(grep -c '^| [1-7] | .* | NOT_RUN |$' "$K")
if [ "$nr" = 0 ]; then ok "--k8s: all 7 checks ran"; else fail "--k8s: $nr checks NOT_RUN"; fi
if grep -q "· pod $pod · user clickhouse\$" "$K"; then ok "--k8s: ran_as in the header is the pod's CLICKHOUSE_USER (clickhouse)"; else fail "--k8s: header $(grep -m 1 '^diskvet ' "$K")"; fi

# ------------------------------------------------------------ payload
PD=$F-k8s-payload-docker.json
PK=$F-k8s-payload.json
# the "tables" rows without the system tables: their logs grow between two runs
user_tables() { grep '^    { "db": ' "$1" | grep -v '^    { "db": "system", ' | sed 's/ },$/ }/'; }
try=0
while [ $try -lt 2 ]; do
    try=$((try + 1))
    sh diskvet.sh --print-payload --docker "$C" --env tests/fixtures/test.env >"$PD" 2>"$PD.err" </dev/null
    k8s_run "$official" --print-payload --k8s "$pod" --env tests/fixtures/test.env >"$PK" 2>"$PK.err"
    user_tables "$PD" >"$W/tables.docker"
    user_tables "$PK" >"$W/tables.k8s"
    # a merge or part cleanup between the two runs changes a number: once more
    if [ -s "$W/tables.k8s" ] && cmp -s "$W/tables.docker" "$W/tables.k8s"; then break; fi
done
if [ -s "$W/tables.k8s" ] && cmp -s "$W/tables.docker" "$W/tables.k8s" \
    && grep -q '"db": "db_[0-9a-f]\{16\}", "table": "t_[0-9a-f]\{16\}"' "$W/tables.k8s"; then
    ok "--print-payload --k8s: names hashed inside the pod; with the same SALT the tables are those of --docker ($(grep -c . "$W/tables.k8s") non-system rows)"
else
    fail "--print-payload --k8s: tables differ from --docker: $(diff "$W/tables.docker" "$W/tables.k8s" | sed -n '2p;4p' | cut -c1-160 | tr '\n' ' ')$(cat "$PK.err")"
fi
# the namespace (default) and the container (clickhouse) are words every payload has
if sh tests/check_payload.sh "$PK" customer_acme payments_eu events_eu "$C" "data-$C" fake-ctx "$SALT" >"$F-k8s-payload-check.txt" 2>&1; then
    ok "--print-payload --k8s passes check_payload.sh (no pod, PVC, context, own names or salt)"
else
    fail "--print-payload --k8s: $(cat "$F-k8s-payload-check.txt")"
fi

# ------------------------------------------------------------ Bitnami logins
B=$F-k8s-bitnami.md
if k8s_run "$bitnami CLICKHOUSE_ADMIN_PASSWORD=$BNPW" report --k8s "$pod" >"$B" 2>"$B.err"; then ok "Bitnami env (CLICKHOUSE_ADMIN_USER + CLICKHOUSE_ADMIN_PASSWORD): exit 0"; else fail "Bitnami env: exit $?: $(cat "$B.err")"; fi
if grep -q "· pod $pod · user bn_admin\$" "$B"; then ok "Bitnami env: logged in as bn_admin, empty CLICKHOUSE_USER / CLICKHOUSE_PASSWORD ignored"; else fail "Bitnami env: header $(grep -m 1 '^diskvet ' "$B")"; fi
# Bitnami chart 9.x: the password only in a file (a mounted Secret), readable by the pod's user
pwfile=/tmp/diskvet-shim-admin-password
printf '%s' "$BNPW" | docker exec -i -u 101:101 "$C" sh -c "umask 077 && cat >$pwfile"
B=$F-k8s-bitnami-file.md
if k8s_run "$bitnami CLICKHOUSE_ADMIN_PASSWORD_FILE=$pwfile" report --k8s "$pod" >"$B" 2>"$B.err"; then ok "Bitnami env with CLICKHOUSE_ADMIN_PASSWORD_FILE: exit 0"; else fail "Bitnami _FILE: exit $?: $(cat "$B.err")"; fi
if grep -q "· pod $pod · user bn_admin\$" "$B"; then ok "Bitnami _FILE: logged in as bn_admin with the password from the file"; else fail "Bitnami _FILE: header $(grep -m 1 '^diskvet ' "$B")"; fi
docker exec "$C" rm -f "$pwfile"

# ------------------------------------------------------------ what the server and kubectl saw
ch -q "SYSTEM FLUSH LOGS"
x=$(chq "SELECT arrayStringConcat(arraySort(groupUniqArray(user)), ',') FROM system.query_log WHERE log_comment = 'diskvet' AND type = 'QueryFinish' AND user IN ('clickhouse', 'bn_admin')")
if [ "$x" = "bn_admin,clickhouse" ]; then ok "query_log: diskvet ran as clickhouse (official env) and bn_admin (Bitnami env)"; else fail "query_log users of the --k8s runs: '$x'"; fi
x=$(chq "SELECT toString(countIf(query_kind != 'Select' OR Settings['readonly'] != '2')) || ' of ' || toString(count()) FROM system.query_log WHERE log_comment = 'diskvet'")
case $x in
    "0 of "[1-9]*) ok "query_log: every row of diskvet is a Select with readonly=2 (${x#0 of } rows, every type)" ;;
    *) fail "query_log: rows of diskvet that are not a Select with readonly=2: $x: $(chq "SELECT type, query_kind, Settings['readonly'], user, substring(query, 1, 60) FROM system.query_log WHERE log_comment = 'diskvet' AND (query_kind != 'Select' OR Settings['readonly'] != '2') LIMIT 3" | tr '\n\t' '  ')" ;;
esac
# Searched here, not by a query: a WHERE on the salt would leave it in text_log
# (the server logs the folded condition), and run.sh checks the same logs later.
if ch -q "SELECT query FROM system.query_log FORMAT TSVRaw" >"$W/server.log" 2>&1 \
    && ch -q "SELECT message FROM system.text_log FORMAT TSVRaw" >>"$W/server.log" 2>&1 && [ -s "$W/server.log" ]; then
    x=$(grep -cF -- "$(printf '%s' "$SALT" | cut -c1-24)" "$W/server.log")
    if [ "$x" = 0 ]; then ok "--k8s: the salt is not in system.query_log or system.text_log"; else fail "--k8s: the salt reached the server logs: $x lines"; fi
else
    fail "cannot read system.query_log and system.text_log: $(sed -n '1p' "$W/server.log")"
fi
cp "$KLOG" "$F-k8s-kubectl.log"
hasnt "$KLOG" "$SALT" "the salt is in no kubectl command line"
hasnt "$KLOG" "$CHPW" "CLICKHOUSE_PASSWORD is in no kubectl command line"
hasnt "$KLOG" "$BNPW" "the Bitnami admin password is in no kubectl command line"

# ------------------------------------------------------------ the printed flag line
# Pasted as a person would (no -i). The TRUNCATE it guards is tried on a scratch
# table over the 10 MiB test drop limit: run.sh still needs system.trace_log.
flag=/var/lib/clickhouse/flags/force_drop_table
flagcmd=$(grep -m 1 "^kubectl exec -n default $C -c clickhouse -- sh -c 'touch " "$K")
ch --multiquery >"$F-k8s-scratch.txt" 2>&1 <<'EOF'
CREATE TABLE default.diskvet_shim_big (s String) ENGINE = MergeTree ORDER BY tuple();
INSERT INTO default.diskvet_shim_big SELECT randomString(64) FROM numbers(300000);
EOF
x=$(chq "TRUNCATE TABLE default.diskvet_shim_big")
case $x in *"Code: 359"*) ok "plain TRUNCATE of an 18 MiB scratch table is refused (Code 359, max_table_size_to_drop)" ;; *) fail "plain TRUNCATE of the scratch table was not refused: $x $(cat "$F-k8s-scratch.txt")" ;; esac
if [ -n "$flagcmd" ] && KFAKE_PRINTED=1 sh -c "$flagcmd" </dev/null >"$F-k8s-flag.txt" 2>&1; then ok "the report's kubectl flag line runs through the shim"; else fail "kubectl flag line: '$flagcmd' $(cat "$F-k8s-flag.txt" 2>/dev/null)"; fi
x=$(docker exec "$C" stat -c %u "$flag" 2>&1)
if [ "$x" = 101 ]; then ok "the flag was created as uid 101, the pod's user"; else fail "flag owner: '$x'"; fi
x=$(chq "TRUNCATE TABLE default.diskvet_shim_big")
if [ -z "$x" ]; then ok "TRUNCATE after the kubectl flag line works"; else fail "TRUNCATE after the kubectl flag line: $x"; fi
if docker exec "$C" test -e "$flag"; then fail "flag still there after TRUNCATE"; else ok "the flag is used up by one TRUNCATE"; fi
docker exec "$C" rm -f "$flag"
chq "DROP TABLE IF EXISTS default.diskvet_shim_big SYNC" >/dev/null

echo "k8s_shim: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
