#!/bin/sh
# Offline tests of --docker. A fake docker (tests/fixtures/fake-docker/) lists
# hand-written containers and runs every exec right here, where the fake
# clickhouse-client of tests/fixtures/fake-kubectl/ answers from
# tests/fixtures/alex.tsv. No Docker daemon is ever contacted: the fake docker
# and docker-compose are first on PATH, and the test stops if another one would run.
# Called at the end of tests/replay.sh; also on its own:
#   sh tests/docker_offline.sh
#   busybox sh tests/docker_offline.sh
set -u
cd "$(dirname "$0")/.." || exit 2
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
has()  { if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then fail "$3 (found: $2)"; else ok "$3"; fi; }
rc_is() { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (exit $1, want $2)"; fi; }
status_of() { sed -n "s/^| $2 | [^|]* | \([A-Z_]*\) |\$/\1/p" "$1"; }
statuses() {  # file "S1 S2 ... S7" DESC
    got=""
    for i in 1 2 3 4 5 6 7; do got="$got $(status_of "$1" "$i")"; done
    got=${got# }
    if [ "$got" = "$2" ]; then ok "$3: $got"; else fail "$3: got '$got', want '$2'"; fi
}

W=$(mktemp -d 2>/dev/null) || W=""
if [ -z "$W" ] || [ ! -d "$W" ]; then
    W=${TMPDIR:-/tmp}/chd-docker.$$
    mkdir -p "$W" || exit 2
fi
trap 'rm -rf "$W"' EXIT
mkdir "$W/bin" "$W/ps" || exit 2
# a copied checkout may have lost the +x bits
cp tests/fixtures/fake-docker/* tests/fixtures/fake-kubectl/clickhouse-client tests/fixtures/fake-kubectl/clickhouse "$W/bin/" \
    && chmod +x "$W/bin/"* || exit 2

# The containers (and a few images and volumes) of each case, as the fake docker
# reads them: container ID IMAGE NAME STATE [ENV...], image NAME, volume NAME.
lf=3f9a1c2e0b77
cat >"$W/ps/langfuse" <<EOF
container $lf clickhouse/clickhouse-server:25.12 langfuse-clickhouse-1 running CLICKHOUSE_USER=clickhouse CLICKHOUSE_PASSWORD=clickhouse
container 0a1b2c3d4e5f langfuse/langfuse:3 langfuse-langfuse-web-1 running
container 1b2c3d4e5f60 langfuse/langfuse-worker:3 langfuse-langfuse-worker-1 running
container 2c3d4e5f6071 postgres:17 langfuse-postgres-1 running
container 3d4e5f607182 redis:7 langfuse-redis-1 running
container 4e5f60718293 minio/minio:latest langfuse-minio-1 running
image clickhouse/clickhouse-server:25.12
volume langfuse_langfuse_clickhouse_data
EOF
# images that are not a ClickHouse server, and a stopped server
cat >"$W/ps/lookalikes" <<'EOF'
container 8293a4b5c6d7 clickhouse/clickhouse-keeper:25.12 keeper running
container 93a4b5c6d7e8 altinity/clickhouse-backup:2.6.3 ch-backup running
container a4b5c6d7e8f9 altinity/clickhouse-operator:0.25.3 ch-operator running
container b5c6d7e8f9a0 bitnami/clickhouse-keeper:25.3.3 bn-keeper running
container c6d7e8f9a0b1 ghcr.io/example/clickhouse-exporter:1.0 ch-exporter running
container d7e8f9a0b1c2 clickhouse/clickhouse-server:25.12 old-clickhouse exited
container e8f9a0b1c2d3 signoz/signoz-otel-collector:v0.129.6 signoz-otel-collector running
EOF
# SigNoz's compose next to Langfuse's: two ClickHouse servers
{ cat "$W/ps/langfuse"; printf '%s\n' "container 5f60718293a4 clickhouse/clickhouse-server:25.5.6 signoz-clickhouse running" \
    "container 60718293a4b5 signoz/zookeeper:3.7.1 signoz-zookeeper-1 running"; } >"$W/ps/two"
# an image and a volume named clickhouse, but no container of that name
{ cat "$W/ps/langfuse"; printf '%s\n' "image clickhouse" "volume clickhouse"; } >"$W/ps/same-name"
printf 'container %s clickhouse/clickhouse-server:25.12 langfuse-clickhouse-1 exited\n' "$lf" >"$W/ps/stopped"

host_path=$PATH
PATH=$W/bin:$PATH
DLOG=$W/dlog
CLOG=$W/clog
KFAKE_STREAM=$PWD/tests/fixtures/alex.tsv
export PATH DLOG CLOG KFAKE_STREAM
unset DFAKE_PS DFAKE_COMPOSE DFAKE_SERVICE DFAKE_DAEMON DFAKE_HANG DFAKE_EXEC DFAKE_CTRPATH DFAKE_CRLF \
    KFAKE_AUTH KFAKE_PROFILE_RO DISKVET_EXEC_TIMEOUT
if [ "$(command -v docker)" != "$W/bin/docker" ] || [ "$(command -v docker-compose)" != "$W/bin/docker-compose" ]; then
    echo "docker_offline: the fake docker and docker-compose are not first on PATH ($(command -v docker), $(command -v docker-compose)); stopping"
    exit 2
fi

# before each run: empty docker and client logs (every call is kept in dlog.all)
fresh() { cat "$DLOG" >>"$W/dlog.all" 2>/dev/null; : >"$DLOG"; : >"$CLOG"; rm -f "$DLOG.n"; }
# dv "VAR=value ..." ARGS...: diskvet with fresh logs. The words set the fake's
# environment for this run only (values without spaces); DFAKE_PS=NAME is $W/ps/NAME.
# shellcheck disable=SC2046
dv() { _e=$1; shift; fresh; env DFAKE_PS="$W/ps/langfuse" $(printf '%s' "$_e" | sed "s|DFAKE_PS=|DFAKE_PS=$W/ps/|") sh diskvet.sh "$@" </dev/null; }
execs() { grep -c '^\[exec\]' "$DLOG"; }
calls_of() { grep -c "^\[$1\]" "$DLOG"; }
# every exec is docker exec -i CONTAINER sh -c ..., or -w /tmp CONTAINER clickhouse local for the hashes
every_exec() {  # CONTAINER DESC
    if awk -v a="[exec] [-i] [$1] [sh] [-c] " -v b="[exec] [-i] [-w] [/tmp] [$1] [clickhouse] [local] " '
            /^\[exec\]/ { n++; if (index($0, a) != 1 && index($0, b) != 1) bad++ } END { exit !(n > 0 && !bad) }' "$DLOG"; then
        ok "$2"
    else
        fail "$2: $(grep '^\[exec\]' "$DLOG" | sed -n '1p' | cut -c1-160)"
    fi
}
unreachable() {  # FILE DESC: FILE is exactly one ch_unreachable line that passes check_payload.sh
    if [ "$(grep -c . "$1")" = 1 ] && grep -q '"status": "ch_unreachable"' "$1" && sh tests/check_payload.sh "$1" >/dev/null 2>&1; then
        ok "$2"
    else
        fail "$2: $(sed -n '1,3p' "$1")"
    fi
}
picked() {  # NAME IMAGE: the one note of a container found by its image
    printf "diskvet: no compose service 'clickhouse' is running in this folder, so diskvet picked container %s by its image (%s). Pass --docker NAME to check another one.\n" "$1" "$2"
}

echo "== diskvet.sh runs docker only through dk() and dx()"
# tests/calls.awk reads the shell part of diskvet.sh as code only (no comments,
# strings or quoted here-documents) and names each docker or docker-compose call
# outside dk() and dx(): each goes through bounded, so none can hang the run.
calls() { awk -v q="'" -v cmd='docker|docker-compose' -v fns='dk dx' -v want=2 -f tests/calls.awk "$1" >"$W/calls"; }
if calls diskvet.sh; then
    ok "the only docker and docker-compose commands are in dk() and dx() (and the command -v checks)"
else
    fail "docker outside dk()/dx(): $(sed -n '1p' "$W/calls")"
fi
# the check itself: each of these lines, added to a copy of diskvet.sh, is caught
# shellcheck disable=SC2016
for m in 'docker exec -i x sh' '_v=$(docker ps -q)' '_v="$(docker inspect x)"' '_v=`docker compose ps -q`' \
        'docker-compose ps -q clickhouse' '_v=$(echo "$(docker-compose ps -q)")' 'cat <<EOF~$(docker ps)~EOF' \
        'FOO=1 docker ps' '[ -n "$x" ] && docker ps'; do
    printf '%s\n' "$m" | tr '~' '\n' >"$W/mut"
    { sed -n '1p' diskvet.sh; cat "$W/mut"; sed '1d' diskvet.sh; } >"$W/mut.sh"
    if calls "$W/mut.sh"; then fail "the docker check misses: $m"; else ok "the docker check catches: $m"; fi
done
# shellcheck disable=SC2016
for m in 'note "docker ps is never run"' "cat <<'EOF'~\$(docker ps)~EOF" 'cat <<EOF~docker exec x (text)~EOF' \
        "_v='\$(docker ps)'" 'command -v docker-compose >/dev/null' '[ "$t" = docker ] || t=docker'; do
    printf '%s\n' "$m" | tr '~' '\n' >"$W/mut"
    { sed -n '1p' diskvet.sh; cat "$W/mut"; sed '1d' diskvet.sh; } >"$W/mut.sh"
    if calls "$W/mut.sh"; then ok "the docker check lets text through: $m"; else fail "the docker check flags text: $m: $(sed -n '1p' "$W/calls")"; fi
done

echo "== --docker auto: the compose service, Compose v1, then the image"
dv "DFAKE_SERVICE=$lf" report --docker auto --save-raw "$W/raw" >"$W/r.md" 2>"$W/r.err"; rc_is $? 0 "compose v2, service clickhouse: exit 0"
nexec=$(execs)
statuses "$W/r.md" "CRITICAL WARN WARN WARN OK OK WARN" "the fake container gives the statuses of the alex.tsv replay"
has "$W/r.md" " · container langfuse-clickhouse-1" "the report names the container (docker inspect's name, not the ID)"
if [ ! -s "$W/r.err" ]; then ok "compose v2: nothing on stderr"; else fail "compose v2: stderr: $(cat "$W/r.err")"; fi
has "$DLOG" "[compose] [ps] [-q] [clickhouse] " "compose v2: docker compose ps -q clickhouse"
rc_is "$(calls_of ps)" 0 "compose v2: no docker ps"
has "$DLOG" "[inspect] [--type] [container] [--format] [{{.Name}}] [$lf] " "docker inspect --type container"
every_exec "$lf" "every exec is docker exec -i $lf sh -c ... ($nexec execs)"
if [ -s "$CLOG" ] && awk 'index($0, "[--user] [clickhouse] [--password] [clickhouse] [--readonly=2] [--max_execution_time=30] ") != 1 { bad = 1 } END { exit bad }' "$CLOG"; then
    ok "every query ran with the container's CLICKHOUSE_USER / CLICKHOUSE_PASSWORD and --readonly=2 ($(grep -c . "$CLOG") calls)"
else
    fail "login: $(sed -n '1p' "$CLOG" | cut -c1-200)"
fi
# the live report of the fake container is the golden of the alex.tsv replay
ver=$(sed -n 's/^VERSION=//p' diskvet.sh | sed 's/\./\\./g')
sed -e '/^# ClickHouse check-up /d' -e "s|diskvet $ver|diskvet 0.2.2|" \
    -e 's/ Queries ran with readonly=2 and resource limits\.$/ Rendered from saved query results (--replay)./' "$W/r.md" >"$W/r.cmp"
if cmp -s tests/fixtures/golden/alex-docker.md "$W/r.cmp"; then
    ok "the report is golden/alex-docker.md (without the date line)"
else
    fail "the live docker report: $(cmp tests/fixtures/golden/alex-docker.md "$W/r.cmp" 2>&1)"
    diff tests/fixtures/golden/alex-docker.md "$W/r.cmp" | head -10
fi

dv "DFAKE_COMPOSE=v1 DFAKE_SERVICE=$lf" report --docker auto >"$W/r.md" 2>"$W/r.err"; rc_is $? 0 "Compose v1 (docker-compose only): exit 0"
has "$DLOG" "[docker-compose] [ps] [-q] [clickhouse] " "Compose v1: docker-compose ps -q clickhouse"
has "$W/r.md" " · container langfuse-clickhouse-1" "Compose v1: the compose service's container"
if [ ! -s "$W/r.err" ] && [ "$(calls_of ps)" = 0 ]; then ok "Compose v1: no note, no docker ps"; else fail "Compose v1: $(calls_of ps) docker ps: $(cat "$W/r.err")"; fi

# no compose file here, the service not running, no Compose at all: the image
for e in "" "DFAKE_SERVICE=" "DFAKE_COMPOSE=none" "DFAKE_COMPOSE=v1" "DFAKE_CRLF=1"; do
    dv "$e" report --docker auto >"$W/r.md" 2>"$W/r.err"; rc=$?
    picked langfuse-clickhouse-1 clickhouse/clickhouse-server:25.12 >"$W/want"
    if [ "$rc" = 0 ] && cmp -s "$W/want" "$W/r.err" && grep -qF " · container langfuse-clickhouse-1" "$W/r.md" && [ "$(calls_of ps)" = 1 ]; then
        ok "${e:-no compose file}: found by its image, with one note on stderr"
    else
        fail "${e:-no compose file}: exit $rc: $(cat "$W/r.err")"
    fi
done
has "$W/dlog.all" "[docker-compose] [version] " "no compose plugin: docker-compose is tried"

echo "== --docker auto: which images are a ClickHouse server"
n=0
for img in clickhouse/clickhouse-server:25.12 docker.io/clickhouse/clickhouse-server:24.1-alpine clickhouse:25.8 \
        altinity/clickhouse-server:24.8.14.10459.altinitystable yandex/clickhouse-server:21.8 \
        clickhouse/clickhouse-server@sha256:0f5b2c4a8e9d bitnami/clickhouse:25.3.3 docker.io/bitnami/clickhouse:25.3 \
        bitnamilegacy/clickhouse:25.3.3-debian-12-r0 mirror.example.com:5000/bitnami/clickhouse:24.8; do
    n=$((n + 1))
    { cat "$W/ps/lookalikes"; printf 'container f9a0b1c2d3%02d %s ch-%s running\n' "$n" "$img" "$n"; } >"$W/ps/img$n"
    dv "DFAKE_PS=img$n" report --docker auto >"$W/r.md" 2>"$W/r.err"; rc=$?
    picked "ch-$n" "$img" >"$W/want"
    if [ "$rc" = 0 ] && cmp -s "$W/want" "$W/r.err" && grep -qF " · container ch-$n" "$W/r.md"; then ok "$img: found, among the lookalikes"; else fail "$img: exit $rc: $(cat "$W/r.err")"; fi
done
nocontainer="diskvet: no running ClickHouse container found (looked for compose service 'clickhouse' here and for images clickhouse-server, clickhouse or bitnami*/clickhouse). Pass --docker <container name>."
refused() {  # "VAR=value ..." EXIT MESSAGE ARGS...: that exit and MESSAGE, no exec; with --print-payload one ch_unreachable line
    _e=$1 _x=$2 _msg=$3; shift 3
    dv "$_e" report "$@" >"$W/r.md" 2>"$W/r.err"; _rc=$?
    if [ "$_rc" = "$_x" ] && grep -qxF -- "$_msg" "$W/r.err" && [ ! -s "$W/r.md" ] && [ "$(execs)" = 0 ]; then
        ok "${_e:+$_e }$*: $_msg"
    else
        fail "${_e:+$_e }$*: exit $_rc, $(execs) execs: $(cat "$W/r.err")"
    fi
    dv "$_e" --print-payload "$@" >"$W/p.json" 2>/dev/null; _rc=$?
    if [ "$_rc" = "$_x" ]; then unreachable "$W/p.json" "  ... and with --print-payload: one ch_unreachable line, exit $_x"; else fail "  ... --print-payload: exit $_rc"; fi
}
refused "DFAKE_PS=lookalikes" 2 "$nocontainer" --docker auto
refused "DFAKE_PS=stopped" 2 "$nocontainer" --docker auto
refused "DFAKE_PS=two" 2 "diskvet: found 2 ClickHouse containers: langfuse-clickhouse-1, signoz-clickhouse. Pass --docker <container name> with one of them." --docker auto
refused "DFAKE_PS=two DFAKE_SERVICE=" 2 "diskvet: found 2 ClickHouse containers: langfuse-clickhouse-1, signoz-clickhouse. Pass --docker <container name> with one of them." --docker auto
# the compose service wins over the image search, even with two servers running
dv "DFAKE_PS=two DFAKE_SERVICE=5f60718293a4" report --docker auto >"$W/r.md" 2>"$W/r.err"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$W/r.err" ] && grep -qF " · container signoz-clickhouse" "$W/r.md"; then ok "two servers and a compose service: the compose one, no note"; else fail "two servers + compose: exit $rc: $(cat "$W/r.err")"; fi

echo "== the login inside the container (\$inner, as with --k8s)"
bn=f9a0b1c2d3e4
printf 'container %s bitnami/clickhouse:25.3.3 clickhouse running CLICKHOUSE_ADMIN_USER=admin CLICKHOUSE_ADMIN_PASSWORD=s3cret-pw\n' "$bn" >"$W/ps/bitnami"
dv "DFAKE_PS=bitnami" report --docker auto >"$W/r.md" 2>"$W/r.err"; rc_is $? 0 "Bitnami image, found by its image: exit 0"
if [ -s "$CLOG" ] && awk 'index($0, "[--user] [admin] [--password] [s3cret-pw] [--readonly=2] ") != 1 { bad = 1 } END { exit bad }' "$CLOG"; then
    ok "Bitnami env (CLICKHOUSE_ADMIN_USER/PASSWORD): --user admin --password s3cret-pw"
else
    fail "Bitnami login: $(sed -n '1p' "$CLOG" | cut -c1-160)"
fi
hasnt "$DLOG" "s3cret-pw" "Bitnami: the password is in no docker command line"
printf 'container %s bitnami/clickhouse:25.3.3 clickhouse running CLICKHOUSE_ADMIN_USER=admin CLICKHOUSE_ADMIN_PASSWORD_FILE=%s\n' \
    "$bn" "$PWD/tests/fixtures/k8s/bitnami-admin-password" >"$W/ps/bitnami-file"
fpw=$(cat tests/fixtures/k8s/bitnami-admin-password)
dv "DFAKE_PS=bitnami-file" report --docker "$bn" >/dev/null 2>&1; rc_is $? 0 "Bitnami CLICKHOUSE_ADMIN_PASSWORD_FILE: exit 0"
if [ -s "$CLOG" ] && awk -v p="[--user] [admin] [--password] [$fpw] " 'index($0, p) != 1 { bad = 1 } END { exit bad }' "$CLOG"; then
    ok "Bitnami CLICKHOUSE_ADMIN_PASSWORD_FILE: the password is read from the file inside the container"
else
    fail "Bitnami _FILE: $(sed -n '1p' "$CLOG" | cut -c1-160)"
fi
hasnt "$DLOG" "$fpw" "Bitnami _FILE: the password is in no docker command line"
# an image with only the clickhouse binary: `clickhouse client`
mkdir "$W/nocli"
cat >"$W/nocli/clickhouse" <<EOF
#!/bin/sh
[ "\${1:-}" = client ] || exec "$W/bin/clickhouse" "\$@"
shift
exec "$W/bin/clickhouse-client" "\$@"
EOF
chmod +x "$W/nocli/clickhouse"
if (PATH=$host_path; command -v clickhouse-client) >/dev/null 2>&1; then
    ok "no clickhouse-client in the container: skipped (this machine has a real one)"
else
    DFAKE_CTRPATH=$W/nocli:$host_path; export DFAKE_CTRPATH
    dv "" report --docker langfuse-clickhouse-1 >"$W/r.md" 2>"$W/r.err"; rc=$?
    unset DFAKE_CTRPATH
    if [ "$rc" = 0 ] && [ -s "$CLOG" ] && grep -q '^| 7 | ' "$W/r.md"; then ok "no clickhouse-client in the container: \`clickhouse client\` runs the checks"; else fail "clickhouse client fallback: exit $rc: $(cat "$W/r.err")"; fi
fi

echo "== --docker NAME: docker inspect --type container"
dv "" report --docker langfuse-clickhouse-1 >"$W/r.md" 2>"$W/r.err"; rc_is $? 0 "--docker langfuse-clickhouse-1: exit 0"
if [ "$(calls_of compose)$(calls_of ps)" = 00 ] && [ ! -s "$W/r.err" ]; then ok "--docker NAME: no compose or ps call, no note"; else fail "--docker NAME: $(cut -c1-80 "$DLOG" | tr '\n' ' ')"; fi
every_exec langfuse-clickhouse-1 "--docker NAME: every exec into that name"
dv "" report --docker "$lf" >"$W/r.md" 2>/dev/null; rc_is $? 0 "--docker ID: exit 0"
has "$W/r.md" " · container langfuse-clickhouse-1" "--docker ID: the report has the name"
refused "DFAKE_PS=same-name" 2 "diskvet: container 'clickhouse' not found (docker inspect failed)" --docker clickhouse
has "$DLOG" "[inspect] [--type] [container] [--format] [{{.Name}}] [clickhouse] " "... docker inspect --type container: the image and the volume named clickhouse don't count"
refused "DFAKE_DAEMON=down" 2 "diskvet: cannot inspect container 'langfuse-clickhouse-1': Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" --docker langfuse-clickhouse-1
refused "DFAKE_DAEMON=down" 2 "diskvet: cannot list containers: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" --docker auto
dv "DFAKE_PS=stopped" report --docker langfuse-clickhouse-1 >"$W/r.md" 2>"$W/r.err"; rc=$?
if [ "$rc" = 3 ] && grep -qxF "diskvet: cannot run queries: Error response from daemon: container $lf is not running" "$W/r.err" && [ ! -s "$W/r.md" ]; then
    ok "a stopped container: exit 3, docker's error"
else
    fail "a stopped container: exit $rc: $(cat "$W/r.err")"
fi
dv "DFAKE_PS=stopped" --print-payload --docker langfuse-clickhouse-1 >"$W/p.json" 2>/dev/null; rc=$?
if [ "$rc" = 3 ]; then unreachable "$W/p.json" "a stopped container, --print-payload: one ch_unreachable line, exit 3"; else fail "a stopped container, --print-payload: exit $rc"; fi

echo "== no docker"
# a PATH without any docker: the host's folders that have none, plus links to
# the few tools diskvet needs before it stops from a folder that has one (/usr/bin)
mkdir "$W/nod"
nopath=$W/nod
_ifs=$IFS; IFS=:
for d in $host_path; do
    if [ -z "$d" ] || [ -e "$d/docker" ] || [ -e "$d/docker.exe" ] || [ -e "$d/docker-compose" ] || [ -e "$d/docker-compose.exe" ]; then continue; fi
    nopath=$nopath:$d
done
IFS=$_ifs
for t in sh env awk sed tr cut grep od date mktemp mkdir rm cat cp; do
    PATH=$nopath; p=$(command -v "$t"); PATH=$W/bin:$host_path
    [ -z "$p" ] || continue
    p=$(command -v "$t") && ln -s "$p" "$W/nod/$t"
done
PATH=$nopath; p=$(command -v docker); PATH=$W/bin:$host_path
if [ -n "$p" ]; then
    fail "cannot make a PATH without docker ($p)"
else
    fresh
    env PATH="$nopath" sh diskvet.sh report --docker auto </dev/null >"$W/r.md" 2>"$W/r.err"; rc=$?
    if [ "$rc" = 2 ] && grep -qxF "diskvet: docker is not installed or not in PATH" "$W/r.err" && [ ! -s "$W/r.md" ]; then ok "no docker: exit 2 and the message"; else fail "no docker: exit $rc: $(cat "$W/r.err")"; fi
    env PATH="$nopath" sh diskvet.sh --print-payload --docker langfuse-clickhouse-1 </dev/null >"$W/p.json" 2>/dev/null; rc=$?
    if [ "$rc" = 2 ]; then unreachable "$W/p.json" "no docker, --print-payload: one ch_unreachable line, exit 2"; else fail "no docker, --print-payload: exit $rc"; fi
    if [ ! -s "$DLOG" ]; then ok "no docker: the fake was not called either"; else fail "no docker: $(sed -n '1p' "$DLOG")"; fi
fi

echo "== timeouts: DISKVET_EXEC_TIMEOUT, as with --k8s"
for t in 4 5s abc; do
    fresh
    env DISKVET_EXEC_TIMEOUT="$t" DFAKE_PS="$W/ps/langfuse" sh diskvet.sh report --docker auto </dev/null >"$W/r.md" 2>"$W/r.err"; rc=$?
    if [ "$rc" = 2 ] && [ ! -s "$DLOG" ] && grep -qxF "diskvet: DISKVET_EXEC_TIMEOUT must be a whole number of seconds (5 or more)" "$W/r.err"; then
        ok "DISKVET_EXEC_TIMEOUT='$t' with --docker: exit 2 before any docker call"
    else
        fail "DISKVET_EXEC_TIMEOUT='$t': exit $rc, $(grep -c . "$DLOG") docker calls: $(cat "$W/r.err")"
    fi
done
# pgrep is not in every busybox; ps -o args is. Git Bash has neither (its ps has
# no -o): there these checks say skipped, as they can't see anything.
if command -v pgrep >/dev/null 2>&1; then plist=pgrep
elif ps -o args >/dev/null 2>&1; then plist="ps -o"
else plist=""; fi
# shellcheck disable=SC2009
left() {  # CMDLINE: is a process with exactly this command line still running?
    if [ "$plist" = pgrep ]; then pgrep -f "^$1\$" >/dev/null 2>&1
    else ps -o args 2>/dev/null | grep -q "^$1\$"; fi
}
# shellcheck disable=SC2009
sleeps() { ps -o pid,args 2>/dev/null | grep '[s]leep' | tr '\n' ' '; }
noleft() {  # DESC CMDLINE...: ok when none of these command lines is still running
    _d=$1; shift
    if [ -z "$plist" ]; then ok "$_d: skipped (no pgrep, and ps has no -o here)"; return; fi
    for _c in "$@"; do
        if left "$_c"; then fail "$_d: '$_c' is still running: $(sleeps)"; return; fi
    done
    ok "$_d"
}
t0=$(date +%s)
{ dv "DFAKE_EXEC=hang DISKVET_EXEC_TIMEOUT=5" report --docker auto 2>"$W/r.err"; echo $? >"$W/rc"; } | cat >/dev/null
t1=$(date +%s)
rc=$(cat "$W/rc")
if [ "$rc" = 3 ] && [ $((t1 - t0)) -le 15 ] \
    && grep -qxF "diskvet: cannot run queries: docker exec timed out after 5 s (Docker or the container did not answer. Set DISKVET_EXEC_TIMEOUT to wait longer.)" "$W/r.err"; then
    ok "a hanging docker exec: exit 3 'timed out after 5 s' and the hint in $((t1 - t0)) s, through | cat"
else
    fail "a hanging docker exec: exit $rc in $((t1 - t0)) s: $(cat "$W/r.err")"
fi
rc_is "$(execs)" 1 "a hanging docker exec: nothing after the probe"
dv "DFAKE_EXEC=hang DISKVET_EXEC_TIMEOUT=5" --print-payload --docker auto >"$W/p.json" 2>/dev/null; rc=$?
if [ "$rc" = 3 ]; then unreachable "$W/p.json" "a hanging docker exec, --print-payload: one ch_unreachable line, exit 3"; else fail "a hanging docker exec, --print-payload: exit $rc"; fi
for h in "inspect|--docker langfuse-clickhouse-1|cannot inspect container 'langfuse-clickhouse-1': docker inspect timed out after 5 s" \
        "ps|--docker auto|cannot list containers: docker ps timed out after 5 s" \
        "compose|--docker auto|cannot list the compose services here: docker compose timed out after 5 s"; do
    what=${h%%|*}; r=${h#*|}; args=${r%%|*}; msg=${r#*|}
    t0=$(date +%s)
    # $args is a list of words on purpose
    # shellcheck disable=SC2086
    dv "DFAKE_HANG=$what DISKVET_EXEC_TIMEOUT=5" report $args >"$W/r.md" 2>"$W/r.err"; rc=$?
    t1=$(date +%s)
    if [ "$rc" = 2 ] && [ $((t1 - t0)) -le 15 ] && grep -qxF "diskvet: $msg" "$W/r.err" && [ "$(execs)" = 0 ]; then
        ok "a hanging docker $what: exit 2 in $((t1 - t0)) s, '$msg'"
    else
        fail "a hanging docker $what: exit $rc in $((t1 - t0)) s: $(cat "$W/r.err")"
    fi
done
sleep 1
noleft "no sleep left over (neither the watchdog's nor the hanging docker)" 'sleep 5' 'sleep 600'

fresh
DISKVET_EXEC_TIMEOUT=30 DFAKE_PS="$W/ps/langfuse" DFAKE_EXEC=hang sh diskvet.sh report --docker auto </dev/null >/dev/null 2>&1 &
bg=$!
i=0
while [ "$i" -lt 20 ] && ! grep -q '^\[exec\]' "$DLOG"; do sleep 1; i=$((i + 1)); done
sleep 1
kill -TERM "$bg"
wait "$bg"; rc=$?
sleep 1
rc_is "$rc" 130 "TERM during a docker exec: exit 130"
noleft "TERM kills the docker exec and the watchdog" 'sleep 30' 'sleep 600'

echo "== the connection lost partway: the report so far, and exit 4"
# the order of the execs: 1 the probe, 2 passport, 3 drop_limit, 4 system_logs, ...
skipped() {  # RAW FAILED-ERROR SKIP-REASON DESC: passport and drop_limit ok, system_logs failed, every later one skipped
    if awk -F '\t' -v e="$2" -v s="skipped: $3" '
            $1 != "@@" { next }
            { k++ }
            k <= 2 { if ($3 != "ok") bad = 1; next }
            k == 3 { if ($2 != "system_logs" || $3 != "fail" || $5 != e) bad = 1; next }
            $3 != "fail" || $5 != s { bad = 1 }
            END { exit bad || k < 10 }' "$1"; then
        ok "$4"
    else
        fail "$4: $(grep '^@@' "$1" | cut -c1-100 | tr '\n' ' ')"
    fi
}
gone="Error response from daemon: container $lf is not running"
dv "DFAKE_SERVICE=$lf DFAKE_EXEC=gone_at=4" report --docker auto --save-raw "$W/raw" >"$W/r.md" 2>"$W/r.err"; rc_is $? 4 "the container stops at the 4th exec: exit 4"
rc_is "$(execs)" 5 "... one more probe after the failed check, then no exec"
skipped "$W/raw" "$gone" "the connection to ClickHouse was lost" "... passport and drop_limit ran, system_logs has docker's error, every later check 'skipped: the connection to ClickHouse was lost'"
if grep -q '^## 7\. ' "$W/r.md" && [ "$(status_of "$W/r.md" 1)" = NOT_RUN ]; then ok "... the report is still printed, its checks NOT_RUN"; else fail "... no report: $(sed -n '1,3p' "$W/r.md")"; fi
has "$W/r.md" "Could not run: skipped: the connection to ClickHouse was lost" "... the report says why"
if grep -qxF "diskvet: lost the connection partway: $gone. The checks left are skipped, so this report is incomplete (exit code 4)." "$W/r.err" && [ "$(grep -c . "$W/r.err")" = 1 ]; then
    ok "... one note on stderr"
else
    fail "... stderr: $(cat "$W/r.err")"
fi
dv "DFAKE_SERVICE=$lf DFAKE_EXEC=refused_at=4" report --docker auto --save-raw "$W/raw" >"$W/r.md" 2>"$W/r.err"; rc_is $? 4 "ClickHouse refuses connections from the 4th exec on (Code 210): exit 4"
skipped "$W/raw" "Code: 210. DB::NetException: Connection refused (localhost:9000). (NETWORK_ERROR)" "the connection to ClickHouse was lost" "... system_logs has Code 210, every later check skipped"
rc_is "$(execs)" 5 "... one more probe, then no exec"
dv "DFAKE_SERVICE=$lf DFAKE_EXEC=hang_at=4 DISKVET_EXEC_TIMEOUT=5" report --docker auto --save-raw "$W/raw" >"$W/r.md" 2>"$W/r.err"; rc_is $? 4 "the 4th exec hangs: exit 4"
skipped "$W/raw" "docker exec timed out after 5 s" "an earlier docker exec timed out" "... system_logs timed out, every later check 'skipped: an earlier docker exec timed out'"
rc_is "$(execs)" 4 "... no exec after the one that timed out"
has "$W/r.err" "diskvet: lost the connection partway: docker exec timed out after 5 s. The checks left are skipped, so this report is incomplete (exit code 4)." "... the note"
sleep 1
noleft "no sleep left over after hang_at" 'sleep 5' 'sleep 600'
dv "DFAKE_SERVICE=$lf DFAKE_EXEC=refused_once=4" report --docker auto --save-raw "$W/raw" >"$W/r.md" 2>"$W/r.err"; rc_is $? 0 "Code 210 once, and the probe after it works: exit 0"
if grep -qxF "@@	system_logs	fail	required	Code: 210. DB::NetException: Connection refused (localhost:9000). (NETWORK_ERROR)" "$W/raw" \
    && ! grep -q 'skipped:' "$W/raw" && [ "$(execs)" = $((nexec + 1)) ] && [ ! -s "$W/r.err" ]; then
    ok "... only system_logs failed, every other check ran ($nexec + 1 execs), no note"
else
    fail "... $(execs) execs (want $((nexec + 1))): $(grep '^@@' "$W/raw" | grep -v '	ok' | cut -c1-80 | tr '\n' ' ') $(cat "$W/r.err")"
fi
# ClickHouse's own answer (alex.tsv has disk_history_kv fail with Code 47) costs no probe
if grep -q '^@@	disk_history_kv	fail' "$W/raw" && [ "$nexec" = $((1 + $(grep -c '^-- @query' checks.sql) - 1)) ]; then
    ok "a check that ClickHouse refused (disk_history_kv, a Code) costs no extra probe: $nexec execs, the probe and one per report query"
else
    fail "execs of a clean run: $nexec"
fi
dv "DFAKE_SERVICE=$lf DFAKE_EXEC=gone_at=4" --print-payload --docker auto --env tests/fixtures/test.env >"$W/p.json" 2>"$W/p.err"; rc_is $? 4 "--print-payload, the container stops at the 4th exec: exit 4"
if sh tests/check_payload.sh "$W/p.json" langfuse-clickhouse-1 "$lf" >"$W/p.txt" 2>&1 && grep -q '"status": "ok"' "$W/p.json" \
    && grep -qF '"not_run": ["system_logs", "not_in_parts", "disk_now", "growth_24h", "too_many_parts", "inactive_parts", "deleted_rows", "mutations", "tables"]' "$W/p.json"; then
    ok "... the payload has what ran, and not_run lists the rest"
else
    fail "... payload: $(cat "$W/p.txt"; grep not_run "$W/p.json")"
fi
has "$W/p.err" "so this payload is incomplete (exit code 4)." "... the note says payload"

echo "== --print-payload: names hashed in the container, no container name"
salt=$(sed -n 's/^SALT=//p' tests/fixtures/test.env)
dv "DFAKE_SERVICE=$lf" --print-payload --docker auto --env tests/fixtures/test.env >"$W/p.json" 2>"$W/p.err"; rc_is $? 0 "--print-payload --docker auto: exit 0"
has "$DLOG" "[exec] [-i] [-w] [/tmp] [$lf] [clickhouse] [local] [--input-format] [TSV]" "the names went to clickhouse local in the container (docker exec -i -w /tmp)"
has "$W/p.err" "cannot hash table names, so the payload has no tables: Code: 1001." "the fake clickhouse local fails: the note"
has "$W/p.json" '"not_run": ["tables"]' "... and the tables are left out"
if sh tests/check_payload.sh "$W/p.json" langfuse-clickhouse-1 "$lf" customer_acme payments_eu "$salt" >"$W/p.txt" 2>&1; then
    ok "check_payload.sh passes with the container name, its ID and the salt forbidden"
else
    fail "payload: $(cat "$W/p.txt")"
fi
hasnt "$DLOG" "$salt" "the salt is in no docker command line"
hasnt "$CLOG" "$salt" "... nor in clickhouse-client's"

echo "== every docker call of this test run"
fresh
sed 's/^\[docker-compose\] /[compose] /' "$W/dlog.all" | awk '{ print $1 }' | sort -u >"$W/verbs"
if grep -qvxE '\[(compose|ps|inspect|exec)\]' "$W/verbs"; then fail "commands: $(tr '\n' ' ' <"$W/verbs")"; else ok "commands: only $(tr '\n' ' ' <"$W/verbs")($(grep -c . "$W/dlog.all") calls)"; fi
if grep '^\[exec\]' "$W/dlog.all" | grep -qvF '[exec] [-i] '; then fail "an exec without -i first"; else ok "every exec starts with docker exec -i (never a TTY)"; fi
hasnt "$W/dlog.all" "s3cret-pw" "no password in any docker command line"
hasnt "$W/dlog.all" "[--password]" "no --password in any docker command line"
if [ -s "$DLOG.bad" ]; then fail "the fake docker refused: $(sed -n 1p "$DLOG.bad")"; else ok "the fake docker and docker-compose refused no call"; fi

echo
echo "docker_offline: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
