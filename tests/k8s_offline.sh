#!/bin/sh
# Offline tests of --k8s. A fake kubectl (tests/fixtures/fake-kubectl/) lists
# the pods of tests/fixtures/k8s/pods.* and runs every exec right here, where
# the fake clickhouse-client answers from tests/fixtures/alex.tsv. No cluster
# is ever contacted: KUBECONFIG=/dev/null, and the fake is first on PATH.
# Called at the end of tests/replay.sh; also on its own:
#   sh tests/k8s_offline.sh
#   busybox sh tests/k8s_offline.sh
# The pod fixtures, in kubectl's custom-columns layout. Recorded on kind by
# tests/k8s.sh (tests/out/pods.*: Kubernetes 1.37, kubectl 1.37):
#   one-official         Langfuse chart 2.1.2 with the ClickHouse operator 0.0.7 (dv-op): the
#                        server, its Keeper, the finished version-probe Job pod, and the operator
#                        (0.0.7 sets no clickhouse.com/cluster label, so the group is empty)
#   one-bitnami8         the Bitnami chart 8.0.5 on its own (dv-bn8): the line of its first replica
#   plain-sidecar-first  a plain StatefulSet (dv-plain) with a busybox sidecar listed first
#   version-probe        the operator's version-probe pod: Succeeded, no role label
#   none                 kube-system and local-path-storage of kind: no ClickHouse at all
#   keeper-only, operator-only: the recorded Keeper, operator and cert-manager lines, with
#                        hand-written ones for other charts
#   kind-bitnami9        the Bitnami chart 9.4.4 on its own (dv-bn9, phase 2 of the job)
#   kind-altinity        the Altinity operator 0.27.4 and a ClickHouseInstallation whose
#                        clickhouse-backup sidecar is listed first (dv-alt, phase 2)
# Hand-written, for installs the kind job does not have:
#   one-bitnami9         trigger.dev up to 4.5.9 (Bitnami chart 9.4.7)
#   many-bitnami         Langfuse 1.x: 3 ClickHouse replicas
#   altinity-sidecars    SigNoz (Altinity operator): clickhouse-log and clickhouse-backup listed first
#   plain-digest         a busybox sidecar first, the image by digest, two PVCs
#   backup-job           backup Job pods that run the server image: no ClickHouse server to pick
#   pending              a ClickHouse pod that is not Running
#   custom-image         no ClickHouse image: needs --container
#   nopvc                Sentry's bundled ClickHouse without persistence
# tests/fixtures/k8s/target.* are the _target rows of a --save-raw file, one per
# flavor (plain-nopvc: no PVC); put in front of alex.tsv, they render the fixes
# of each chart without kubectl (the flavor replays).
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
    W=${TMPDIR:-/tmp}/chd-k8s.$$
    mkdir -p "$W" || exit 2
fi
trap 'rm -rf "$W"' EXIT
mkdir "$W/bin" "$W/pods" || exit 2
# a copied checkout may have lost the +x bits
cp tests/fixtures/fake-kubectl/* "$W/bin/" && chmod +x "$W/bin/"* || exit 2
cp tests/fixtures/k8s/pods.* "$W/pods/" || exit 2
# two outputs kubectl should never print: wrong column count, names without images
printf 'lf   web-1   Running   web   nginx:1.29\n' >"$W/pods/pods.badcols"
printf 'lf   ch-0   Running   a,clickhouse   clickhouse/clickhouse-server:25.8   <none>   <none>   <none>   <none>   <none>   StatefulSet\n' >"$W/pods/pods.badlists"
# names that are not Kubernetes names never reach a printed command: the row is
# skipped, a label value or a PVC name is dropped
{
    printf 'obs   CH-0   Running   clickhouse   clickhouse/clickhouse-server:25.8   data-ch-0   <none>   <none>   <none>   <none>   StatefulSet\n'
    printf 'obs   chi-obs-ch-0-0-0   Running   clickhouse   clickhouse/clickhouse-server:25.8   Data_0,data-chi-obs-ch-0-0-0   <none>   <none>   Obs.CH   <none>   StatefulSet\n'
} >"$W/pods/pods.badnames"
# a Bitnami image outside the Bitnami chart
printf 'bn   clickhouse-0   Running   clickhouse   docker.io/bitnamilegacy/clickhouse:25.3.3   data-clickhouse-0   <none>   <none>   <none>   <none>   StatefulSet\n' >"$W/pods/pods.bitnami-other"

host_path=$PATH
PATH=$W/bin:$PATH
KUBECONFIG=/dev/null
KLOG=$W/klog
CLOG=$W/clog
KFAKE_PODS=$W/pods
KFAKE_STREAM=$PWD/tests/fixtures/alex.tsv
export PATH KUBECONFIG KLOG CLOG KFAKE_PODS KFAKE_STREAM
unset KFAKE KFAKE_CTX KFAKE_NS KFAKE_FORBID_ALL KFAKE_CRLF KFAKE_EXEC KFAKE_ENV KFAKE_PODPATH \
    KFAKE_AUTH KFAKE_PROFILE_RO KFAKE_DOCKER KFAKE_DOCKER_USER KFAKE_PRINTED DISKVET_EXEC_TIMEOUT
if [ "$(command -v kubectl)" != "$W/bin/kubectl" ]; then
    echo "k8s_offline: the fake kubectl is not first on PATH ($(command -v kubectl)); stopping"
    exit 2
fi

# before each run: empty kubectl and client logs (every call is kept in klog.all)
fresh() { cat "$KLOG" >>"$W/klog.all" 2>/dev/null; : >"$KLOG"; : >"$CLOG"; rm -f "$KLOG.n"; }
# dv "VAR=value ..." ARGS...: diskvet with fresh logs. The words set the fake's
# environment for this run only (values without spaces); $kenv is the pod's env.
kenv=""
# shellcheck disable=SC2086
dv() { _e=$1; shift; fresh; env $_e KFAKE_ENV="$kenv" sh diskvet.sh "$@" </dev/null; }
execs() { grep -c '\[exec\]' "$KLOG"; }
# the _target row of a --save-raw file: NS|POD|CTR|FLAVOR|PVCS|GROUP|CTX
tgt() { awk -F '\t' '$1 == "_target" { print $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8 "|" $9 }' "$1"; }
pinned() {  # PREFIX DESC: there are execs, and every one starts with PREFIX
    if awk -v p="$1" 'index($0, "[exec]") { n++; if (index($0, p) != 1) bad++ } END { exit !(n > 0 && !bad) }' "$KLOG"; then
        ok "$2"
    else
        fail "$2: $(grep '\[exec\]' "$KLOG" | grep -vF -- "$1" | sed -n '1p' | cut -c1-200)"
    fi
}
unreachable() {  # FILE DESC: FILE is exactly one ch_unreachable line that passes check_payload.sh
    if [ "$(grep -c . "$1")" = 1 ] && grep -q '"status": "ch_unreachable"' "$1" && sh tests/check_payload.sh "$1" >/dev/null 2>&1; then
        ok "$2"
    else
        fail "$2: $(sed -n '1,3p' "$1")"
    fi
}
nodocker() {  # FILE DESC: no Docker or host advice in a Kubernetes report
    if grep -nE 'docker|daemon\.json|systemctl|sudo|json-file' "$1" >"$W/nodocker"; then fail "$2: $(sed -n '1p' "$W/nodocker" | cut -c1-160)"; else ok "$2"; fi
}
official_target="dv-op|lf-langfuse-clickhouse-0-0-0|clickhouse-server|official|clickhouse-storage-volume-lf-langfuse-clickhouse-0-0-0|"

echo "== diskvet.sh runs kubectl only through kc() and kx()"
# The shell part of diskvet.sh as code only: no comments, no quoted strings, no
# quoted here-documents (the report text is awk, after the render.awk line, and
# only prints commands). $( ) and ` ` are code wherever they are, inside "..."
# and unquoted here-documents too. A stack of frames: D "...", H an unquoted
# here-document, C $( ), B ` `; sq is a '...' string.
cat >"$W/calls.awk" <<'EOF'
/^cat >"\$tmp\/render\.awk"/ { exit }
hd != "" && $0 == hd { if (!hq) d--; hd = ""; next }
hd != "" && hq { next }
{
    code = ""; s = $0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1); top = st[d]
        if (sq) { if (c == q) sq = 0; continue }
        if (top == "D" || top == "H") {
            if (c == "\\") { i++; continue }
            if (top == "D" && c == "\"") { d--; continue }
            if (c == "$" && substr(s, i + 1, 1) == "(") { st[++d] = "C"; pc[d] = 0; i++; code = code "$("; continue }
            if (c == "`") { st[++d] = "B"; code = code c }
            continue
        }
        if (c == q) { sq = 1; continue }
        if (c == "\"") { st[++d] = "D"; continue }
        if (c == "\\") { i++; continue }
        if (c == "`") { if (top == "B") d--; else st[++d] = "B"; code = code c; continue }
        if (c == "$" && substr(s, i + 1, 1) == "(") { st[++d] = "C"; pc[d] = 0; i++; code = code "$("; continue }
        if (top == "C" && c == "(") pc[d]++
        if (top == "C" && c == ")") { if (pc[d] == 0) { d--; code = code c; continue } pc[d]-- }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;(]/)) break
        code = code c
    }
    if (index(code, "<<") && match(s, "<<-?[ ]*[\"" q "]?[A-Za-z_]+")) {
        hd = substr(s, RSTART, RLENGTH); hq = (hd ~ "[\"" q "]"); gsub("[<\" " q "-]", "", hd)
        if (!hq) st[++d] = "H"
    }
    if (s ~ /^kx\(\) \{/) inkx = 1
    gsub(/command -v kubectl/, "", code)
    if (code ~ /(^|[^A-Za-z0-9_.-])kubectl([^A-Za-z0-9_.-]|$)/) {
        if (inkx || s ~ /^kc\(\) \{/) allowed++
        else { print NR ": " s; bad++ }
    }
    if (inkx && s ~ /^}/) inkx = 0
}
END {
    # a quote or a $( left open means this scan lost track: fail rather than pass
    if (d != 0 || sq) print "the scan ended inside a quote or a $( ) (depth " d ")"
    exit (bad || allowed != 2 || d != 0 || sq)
}
EOF
calls() { awk -v q="'" -f "$W/calls.awk" "$1" >"$W/calls"; }
if calls diskvet.sh; then
    ok "the only kubectl commands are in kc() and kx() (and the command -v check)"
else
    fail "kubectl outside kc()/kx(): $(sed -n '1p' "$W/calls")"
fi
# the check itself: each of these lines, added to a copy of diskvet.sh, is caught
# shellcheck disable=SC2016
for m in 'kubectl get secret x' '_v=$(kubectl get secret x)' '_v="$(kubectl get secret x)"' \
        '_v="a $(printf x | tr -d "\r") b $(kubectl get secret x)"' '_v=`kubectl get secret x`' \
        '_v="`kubectl get secret x`"' 'cat <<EOF~$(kubectl get secret x)~EOF' \
        '_v=$(echo "$(kubectl get secret x)")'; do
    printf '%s\n' "$m" | tr '~' '\n' >"$W/mut"
    { sed -n '1p' diskvet.sh; cat "$W/mut"; sed '1d' diskvet.sh; } >"$W/mut.sh"
    if calls "$W/mut.sh"; then fail "the kubectl check misses: $m"; else ok "the kubectl check catches: $m"; fi
done
# shellcheck disable=SC2016
for m in 'note "kubectl get secret x is never run"' "cat <<'EOF'~\$(kubectl get secret x)~EOF" \
        'cat <<EOF~kubectl get secret x (text)~EOF' "_v='\$(kubectl get secret x)'"; do
    printf '%s\n' "$m" | tr '~' '\n' >"$W/mut"
    { sed -n '1p' diskvet.sh; cat "$W/mut"; sed '1d' diskvet.sh; } >"$W/mut.sh"
    if calls "$W/mut.sh"; then ok "the kubectl check lets text through: $m"; else fail "the kubectl check flags text: $m: $(sed -n '1p' "$W/calls")"; fi
done

echo "== discovery: the right namespace, pod and container (also with CR LF from kubectl.exe)"
# FIXTURE|KFAKE_NS|--k8s ARGS|NS|POD|CTR|FLAVOR|PVCS|GROUP (the _target row diskvet writes).
# A named pod is used even when a Job owns it, and a named pod with one container
# uses that container whatever its image.
cat >"$W/found" <<EOF
one-official|default|auto|$official_target
one-official|default|auto -n dv-op|$official_target
one-official|default|dv-op/lf-langfuse-clickhouse-0-0-0|$official_target
one-official|dv-op|pod/lf-langfuse-clickhouse-0-0-0|$official_target
one-bitnami8|default|auto|dv-bn8|bn8-clickhouse-shard0-0|clickhouse|bitnami8|data-bn8-clickhouse-shard0-0|
one-bitnami9|default|auto|trigger|trigger-clickhouse-shard0-0|clickhouse|bitnami9|data-trigger-clickhouse-shard0-0|
kind-bitnami9|default|auto|dv-bn9|bn9-clickhouse-shard0-0|clickhouse|bitnami9|data-bn9-clickhouse-shard0-0|
many-bitnami|default|langfuse/langfuse-clickhouse-shard0-1|langfuse|langfuse-clickhouse-shard0-1|clickhouse|bitnami8|data-langfuse-clickhouse-shard0-1|
altinity-sidecars|default|auto|signoz|chi-signoz-clickhouse-cluster-0-0-0|clickhouse|altinity|data-volumeclaim-template-chi-signoz-clickhouse-cluster-0-0-0|signoz-clickhouse
altinity-sidecars|default|auto -n signoz|signoz|chi-signoz-clickhouse-cluster-0-0-0|clickhouse|altinity|data-volumeclaim-template-chi-signoz-clickhouse-cluster-0-0-0|signoz-clickhouse
kind-altinity|default|auto|dv-alt|chi-dv-alt-c1-0-0-0|clickhouse|altinity|data-chi-dv-alt-c1-0-0-0|dv-alt
plain-sidecar-first|default|auto|dv-plain|dv-plain-0|clickhouse|plain|data-dv-plain-0|
plain-digest|default|auto|dv-plain|ch-0|clickhouse|plain|data-ch-0,logs-ch-0|
custom-image|default|dv-custom/analytics-db-0 --container db|dv-custom|analytics-db-0|db|plain|data-analytics-db-0|
nopvc|default|auto|sentry|sentry-clickhouse-0|sentry-clickhouse|plain||
backup-job|default|ops/ch-backup-29310420-7xk2p|ops|ch-backup-29310420-7xk2p|clickhouse|plain||
backup-job|default|ops/clickhouse-backup-cron-29310420-q8w4z|ops|clickhouse-backup-cron-29310420-q8w4z|clickhouse-backup|plain||
bitnami-other|default|auto|bn|clickhouse-0|clickhouse|bitnami|data-clickhouse-0|
badnames|default|auto|obs|chi-obs-ch-0-0-0|clickhouse|altinity|data-chi-obs-ch-0-0-0|
EOF
for crlf in 0 1; do
    lbl=""
    [ "$crlf" = 1 ] && lbl=", CR LF"
    while IFS='|' read -r fx cns args want; do
        wns=${want%%|*}; r=${want#*|}; wpod=${r%%|*}; r=${r#*|}; wctr=${r%%|*}
        # $args is a list of words on purpose
        # shellcheck disable=SC2086
        dv "KFAKE=$fx KFAKE_NS=$cns KFAKE_CRLF=$crlf" report --k8s $args --save-raw "$W/raw" >"$W/r.md" 2>"$W/r.err"
        rc=$?
        got=$(tgt "$W/raw")
        d="$fx, --k8s $args$lbl"
        if [ "$rc" = 0 ] && [ "$got" = "$want|" ] \
            && grep -qF "kubectl context fake-ctx · pod $wns/$wpod · container $wctr" "$W/r.err" \
            && grep -qF " · pod $wns/$wpod" "$W/r.md"; then
            ok "$d: $wns/$wpod, container $wctr, $(echo "$want" | cut -d'|' -f4)"
        else
            fail "$d: exit $rc, _target '$got', want '$want|'; $(tail -n 1 "$W/r.err")"
        fi
        pinned "[--context] [fake-ctx] [exec] [-i] [-n] [$wns] [$wpod] [-c] [$wctr] [--] [sh] [-c] " "$d: every exec pinned to fake-ctx $wns/$wpod -c $wctr ($(execs) execs)"
        [ "$crlf" = 1 ] || nodocker "$W/r.md" "$d: no docker, daemon.json, systemctl, sudo or json-file in the report"
    done <"$W/found"
done

echo "== discovery: nothing to pick, or more than one"
refused() {  # "VAR=value ..." MESSAGE ARGS...: exit 2 with MESSAGE, no exec; with --print-payload one ch_unreachable line
    _e=$1 _msg=$2; shift 2
    dv "$_e" report "$@" >"$W/r.md" 2>"$W/r.err"; _rc=$?
    if [ "$_rc" = 2 ] && grep -qF -- "$_msg" "$W/r.err" && [ ! -s "$W/r.md" ] && [ "$(execs)" = 0 ]; then
        ok "$_e $*: $_msg"
    else
        fail "$_e $*: exit $_rc, $(execs) execs: $(cat "$W/r.err")"
    fi
    dv "$_e" --print-payload "$@" >"$W/p.json" 2>/dev/null; _rc=$?
    if [ "$_rc" = 2 ]; then unreachable "$W/p.json" "  ... and with --print-payload: one ch_unreachable line"; else fail "  ... --print-payload: exit $_rc"; fi
}
nopod="no running ClickHouse pod found in any namespace you can list (looked for a container with image clickhouse-server, clickhouse or bitnami*/clickhouse; keeper, operator, backup and job pods are skipped). Pass --k8s NAMESPACE/POD, and --container NAME for a custom image."
for fx in keeper-only operator-only version-probe backup-job none pending custom-image; do
    refused "KFAKE=$fx" "$nopod" --k8s auto
done
refused "KFAKE=backup-job" "no running ClickHouse pod found in namespace ops (" --k8s auto -n ops
refused "KFAKE=one-official KFAKE_FORBID_ALL=1" "no running ClickHouse pod found in your current namespace (" --k8s auto
refused "KFAKE=pending" "pod dv-plain/ch-0 is Pending, not Running" --k8s dv-plain/ch-0
refused "KFAKE=custom-image" "pod dv-custom/analytics-db-0 has containers metrics db, and not exactly one with a ClickHouse image; pass --container NAME" --k8s dv-custom/analytics-db-0
refused "KFAKE=custom-image" "pod dv-custom/analytics-db-0 has no container 'nope' (it has: metrics db)" --k8s dv-custom/analytics-db-0 --container nope
refused "KFAKE=version-probe" "pod dv-op/lf-langfuse-clickhouse-version-probe-270acf95-wls47 is Succeeded, not Running" --k8s dv-op/lf-langfuse-clickhouse-version-probe-270acf95-wls47
refused "KFAKE=keeper-only" "pod lf/langfuse-keeper-1-0-0 is not a ClickHouse server: its clickhouse.com/role is clickhouse-keeper" --k8s lf/langfuse-keeper-1-0-0
refused "KFAKE=one-official" 'cannot find pod lf/nope: Error from server (NotFound): pods "nope" not found' --k8s lf/nope
refused "KFAKE=badcols" "cannot read kubectl's output (unexpected columns); please report this with kubectl version" --k8s auto
refused "KFAKE=badlists" "cannot read kubectl's output (unexpected columns); please report this with kubectl version" --k8s lf/ch-0

dv "KFAKE=many-bitnami" report --k8s auto >"$W/r.md" 2>"$W/r.err"; rc=$?
n=$(grep -c '^  sh diskvet\.sh report --k8s langfuse/langfuse-clickhouse-shard0-[0-2] > report-langfuse-clickhouse-shard0-[0-2]\.md$' "$W/r.err")
if [ "$rc" = 2 ] && [ "$n" = 3 ] && [ ! -s "$W/r.md" ] && [ "$(execs)" = 0 ] \
    && grep -qF "found 3 ClickHouse pods. Each has its own disk and system logs, so diskvet checks one pod per run:" "$W/r.err"; then
    ok "many-bitnami: exit 2 and one ready --k8s langfuse/POD command per pod ($n), no exec"
else
    fail "many-bitnami: exit $rc, $n commands: $(cat "$W/r.err")"
fi
dv "KFAKE=many-bitnami" --print-payload --k8s auto --context prod-ctx >"$W/p.json" 2>"$W/r.err"; rc=$?
rc_is "$rc" 2 "many-bitnami --print-payload: exit 2"
unreachable "$W/p.json" "many-bitnami --print-payload: stdout is one ch_unreachable line"
has "$W/r.err" "  sh diskvet.sh --print-payload --k8s langfuse/langfuse-clickhouse-shard0-2 --context prod-ctx > payload-langfuse-clickhouse-shard0-2.json" "many-bitnami --print-payload: the commands keep --print-payload and the typed context"
# the other typed options that change the run go into each command too, quoted
# where the shell needs it, and the printed command, pasted, runs with them
dv "KFAKE=many-bitnami" --print-payload --k8s auto -n langfuse --env tests/fixtures/test.env --ttl-days 14 --user ro --host 'my host' \
    >/dev/null 2>"$W/r.err"; rc_is $? 2 "many-bitnami with --env, --ttl-days, --user and --host: exit 2"
has "$W/r.err" "  sh diskvet.sh --print-payload --k8s langfuse/langfuse-clickhouse-shard0-1 --host 'my host' --user ro --ttl-days 14 --env tests/fixtures/test.env > payload-langfuse-clickhouse-shard0-1.json" \
    "many-bitnami: the commands keep --host (quoted), --user, --ttl-days and --env"
# pasted in a copy of the checkout, so its output file lands there
line=$(sed -n 's/^  \(sh .* --k8s langfuse\/langfuse-clickhouse-shard0-1 .*\)$/\1/p' "$W/r.err")
mkdir -p "$W/pp/tests/fixtures" && cp diskvet.sh checks.sql "$W/pp/" && cp tests/fixtures/test.env "$W/pp/tests/fixtures/"
fresh
(cd "$W/pp" && KFAKE=many-bitnami sh -c "$line" </dev/null 2>/dev/null); rc=$?
if [ -n "$line" ] && [ "$rc" = 0 ] && [ -s "$W/pp/payload-langfuse-clickhouse-shard0-1.json" ] \
    && grep -qF '[--host] [my host] [--user] [ro] ' "$CLOG" && grep -qF '[langfuse-clickhouse-shard0-1]' "$KLOG"; then
    ok "many-bitnami: the printed command, pasted into sh, runs on that pod with --host 'my host' --user ro"
else
    fail "many-bitnami: the pasted command '$line': exit $rc, $(sed -n '1p' "$CLOG" | cut -c1-160)"
fi
# a script path with a space (C:/Users/John Doe/Downloads) is quoted
mkdir "$W/my tools" && cp diskvet.sh checks.sql "$W/my tools/"
fresh
env KFAKE=many-bitnami sh "$W/my tools/diskvet.sh" report --k8s auto </dev/null >/dev/null 2>"$W/r.err"
has "$W/r.err" "  sh '$W/my tools/diskvet.sh' report --k8s langfuse/langfuse-clickhouse-shard0-0 > report-langfuse-clickhouse-shard0-0.md" \
    "many-bitnami: a script path with a space is quoted in the commands"
line=$(sed -n 's/^  \(sh .* --k8s langfuse\/langfuse-clickhouse-shard0-0 .*\)$/\1/p' "$W/r.err")
mkdir "$W/paste" && (cd "$W/paste" && KFAKE=many-bitnami sh -c "$line" </dev/null 2>/dev/null); rc=$?
if [ -n "$line" ] && [ "$rc" = 0 ] && grep -qF "· pod langfuse/langfuse-clickhouse-shard0-0" "$W/paste/report-langfuse-clickhouse-shard0-0.md"; then
    ok "many-bitnami: that command, pasted into sh, writes the report of that pod"
else
    fail "many-bitnami: the pasted command '$line' (a space in the path): exit $rc"
fi

dv "KFAKE=one-official KFAKE_FORBID_ALL=1 KFAKE_NS=dv-op" report --k8s auto --save-raw "$W/raw" >"$W/r.md" 2>"$W/r.err"; rc=$?
if [ "$rc" = 0 ] && [ "$(tgt "$W/raw")" = "$official_target|" ] \
    && grep -qF "not allowed to list pods in all namespaces; looking in your current namespace only (pass -n NAMESPACE to choose)" "$W/r.err"; then
    ok "Forbidden -A: the note, then the current namespace, then the run"
else
    fail "Forbidden -A: exit $rc, _target '$(tgt "$W/raw")': $(cat "$W/r.err")"
fi
if grep '\[get\] \[pods\]' "$KLOG" | sed -n '1p' | grep -qF '[-A]' && ! grep '\[get\] \[pods\]' "$KLOG" | sed -n '2p' | grep -qE '\[-(A|n)\]'; then
    ok "Forbidden -A: the second list has neither -A nor -n"
else
    fail "Forbidden -A: $(grep '\[get\]' "$KLOG" | cut -c1-120)"
fi

dv "KFAKE=one-official KFAKE_CTX=none" report --k8s auto >"$W/r.md" 2>"$W/r.err"; rc=$?
if [ "$rc" = 0 ] && grep -qF "kubectl context (none) · pod dv-op/lf-langfuse-clickhouse-0-0-0 · container clickhouse-server" "$W/r.err" \
    && ! grep -qF '[--context]' "$KLOG"; then
    ok "no current context (in-cluster): nothing is pinned, and the note says (none)"
else
    fail "no current context: exit $rc: $(cat "$W/r.err")"
fi

echo "== credentials: expanded inside the pod, never on the kubectl command line"
login() {  # PREFIX DESC: every clickhouse-client call in the pod starts with PREFIX ("": neither --user nor --password)
    if [ -n "$1" ]; then
        if [ -s "$CLOG" ] && awk -v p="$1" 'index($0, p) != 1 { bad = 1 } END { exit bad }' "$CLOG"; then ok "$2"; else fail "$2: $(sed -n '1p' "$CLOG" | cut -c1-160)"; fi
    else
        if [ -s "$CLOG" ] && ! grep -qE '\[--(user|password)\]' "$CLOG"; then ok "$2"; else fail "$2: $(sed -n '1p' "$CLOG" | cut -c1-160)"; fi
    fi
}
kenv="CLICKHOUSE_USER=u CLICKHOUSE_PASSWORD=p"
dv "KFAKE=one-official" report --k8s auto >/dev/null 2>"$W/r.err"; rc_is $? 0 "official image env: exit 0"
login "[--user] [u] [--password] [p] [--readonly=2] " "official image env (CLICKHOUSE_USER/PASSWORD): --user u --password p"
kenv="CLICKHOUSE_USER=u CLICKHOUSE_PASSWORD=p CLICKHOUSE_ADMIN_USER=admin CLICKHOUSE_ADMIN_PASSWORD=s3cret-pw"
dv "KFAKE=one-official" report --k8s auto >/dev/null 2>&1
login "[--user] [u] [--password] [p] [--readonly=2] " "official env wins over Bitnami's CLICKHOUSE_ADMIN_*"
kenv="CLICKHOUSE_ADMIN_USER=admin CLICKHOUSE_ADMIN_PASSWORD=s3cret-pw"
dv "KFAKE=one-bitnami8" report --k8s auto >/dev/null 2>"$W/r.err"; rc_is $? 0 "Bitnami 8 env: exit 0"
login "[--user] [admin] [--password] [s3cret-pw] [--readonly=2] " "Bitnami 8 env (CLICKHOUSE_ADMIN_USER/PASSWORD): --user admin --password s3cret-pw"
hasnt "$KLOG" "s3cret-pw" "Bitnami 8: the password is not in any kubectl command line"
fpw=$(cat tests/fixtures/k8s/bitnami-admin-password)
kenv="CLICKHOUSE_ADMIN_USER=admin CLICKHOUSE_ADMIN_PASSWORD_FILE=tests/fixtures/k8s/bitnami-admin-password"
dv "KFAKE=one-bitnami9" report --k8s auto >/dev/null 2>"$W/r.err"; rc_is $? 0 "Bitnami 9 _FILE: exit 0"
login "[--user] [admin] [--password] [$fpw] [--readonly=2] " "Bitnami 9 CLICKHOUSE_ADMIN_PASSWORD_FILE: the password is read from the file inside the pod"
hasnt "$KLOG" "$fpw" "Bitnami 9: the password is not in any kubectl command line"
kenv=""
dv "KFAKE=one-official" report --k8s auto >/dev/null 2>&1
login "" "no login in the pod's env: neither --user nor --password (clickhouse-client's own config)"
kenv="CLICKHOUSE_USER=u CLICKHOUSE_PASSWORD=p"
dv "KFAKE=one-official" report --k8s auto --user ro >/dev/null 2>"$W/r.err"; rc_is $? 0 "--user ro: exit 0"
kenv=""
if [ -s "$CLOG" ] && ! grep -vqF '[--user] [ro] ' "$CLOG" && ! grep -qE '\[--password\]|\[u\]' "$CLOG"; then
    ok "--user ro: only --user ro, the pod's env is not used"
else
    fail "--user ro: $(sed -n '1p' "$CLOG" | cut -c1-200)"
fi
if grep '\[exec\]' "$KLOG" | grep -F '[sh] [explicit]' | grep -qF '[--user] [ro]'; then ok "--user ro: exec passes 'explicit' and the user name only"; else fail "--user ro: $(grep '\[exec\]' "$KLOG" | sed -n '1p' | cut -c1-200)"; fi

echo "== argument errors: exit 2 before any kubectl call"
ae=""
argerr() {  # MESSAGE ARGS...
    _msg=$1; shift
    fresh
    # shellcheck disable=SC2086
    env KFAKE=one-official $ae sh diskvet.sh report "$@" </dev/null >"$W/r.md" 2>"$W/r.err"; _rc=$?
    if [ "$_rc" = 2 ] && [ ! -s "$KLOG" ] && [ ! -s "$W/r.md" ] && grep -qF -- "diskvet: $_msg" "$W/r.err"; then
        ok "${ae:+$ae }$*: $_msg"
    else
        fail "${ae:+$ae }$*: exit $_rc, $(grep -c . "$KLOG") kubectl calls: $(cat "$W/r.err")"
    fi
}
argerr "--password is not accepted with --k8s: kubectl puts the command line into the exec request URL, and the API server can keep it in its audit log." --password x --k8s dv-op/lf-langfuse-clickhouse-0-0-0
argerr "--password is not accepted with --k8s" --password= --k8s auto
argerr "use either --docker or --k8s, not both" --k8s a --docker b
argerr "-n/--namespace, --container and --context only work with --k8s" -n x
argerr "-n/--namespace, --container and --context only work with --k8s" --container c
argerr "-n/--namespace, --container and --context only work with --k8s" --context c
argerr "--container needs a pod: --k8s NAMESPACE/POD --container NAME" --k8s auto --container c
argerr "not a valid Kubernetes name: A" --k8s A/B
argerr "--k8s takes auto, POD or NAMESPACE/POD" --k8s a/b/c/d
argerr "--k8s takes auto, POD or NAMESPACE/POD" --k8s=
argerr "namespace given twice: -n other and --k8s lf/x" --k8s lf/x -n other
argerr "not a valid Kubernetes name: Bad_NS" --k8s auto -n Bad_NS
long=$(printf '%064d' 0 | tr 0 x)
argerr "not a valid Kubernetes name: $long" --k8s auto -n "$long"
argerr "--context: diskvet prints this name into the fix commands, so it accepts only letters, digits and . _ : / @ -" --k8s auto --context "a b"
argerr "with --replay, name the pod: --k8s NAMESPACE/POD" --replay tests/fixtures/alex.tsv --k8s auto
ae="DISKVET_EXEC_TIMEOUT=4"
argerr "DISKVET_EXEC_TIMEOUT must be a whole number of seconds (5 or more)" --k8s auto
ae="DISKVET_EXEC_TIMEOUT=5s"
argerr "DISKVET_EXEC_TIMEOUT must be a whole number of seconds (5 or more)" --k8s auto
ae=""

echo "== kubectl command lines: the context pinned, only config/get/exec, never a TTY"
dv "KFAKE=one-official" report --k8s auto --save-raw "$W/raw.untyped" >"$W/untyped.md" 2>"$W/r.err"; rc_is $? 0 "--k8s auto on one-official: exit 0"
nexec=$(execs)
statuses "$W/untyped.md" "CRITICAL WARN WARN WARN OK OK WARN" "the fake pod gives the same statuses as the alex.tsv replay"
if [ "$(sed -n '1p' "$KLOG")" = "[config] [current-context] " ] && sed '1d' "$KLOG" | awk 'index($0, "[--context] [fake-ctx] ") != 1 { bad = 1 } END { exit bad }'; then
    ok "the context is read once, then passed on every call (--context fake-ctx)"
else
    fail "context pinning: $(cut -c1-120 "$KLOG")"
fi
pinned "[--context] [fake-ctx] [exec] [-i] [-n] [dv-op] [lf-langfuse-clickhouse-0-0-0] [-c] [clickhouse-server] [--] [sh] [-c] " "every exec starts with [--context] [fake-ctx] [exec] [-i] [-n] [NS] [POD] [-c] [CTR] [--] [sh] [-c]"
if awk 'index($0, "[--readonly=2] [--max_execution_time=30] [--max_result_rows=10000] [--result_overflow_mode=break] [--max_threads=2] [--max_memory_usage=500000000] [--log_comment=diskvet] [--format=TSV]") == 0 { bad = 1 } END { exit bad || NR == 0 }' "$CLOG"; then
    ok "every query in the pod ran with --readonly=2 and the limits ($(grep -c . "$CLOG") calls)"
else
    fail "limits: $(sed -n '1p' "$CLOG" | cut -c1-200)"
fi
hasnt "$W/untyped.md" "fake-ctx" "a context the user did not type is not in the report"
hasnt "$W/raw.untyped" "fake-ctx" "... nor in the --save-raw file"
has "$W/untyped.md" "complete kubectl lines for your current kubectl context (check it with \`kubectl config current-context\` before you paste)." "the report says which context its commands use"
dv "KFAKE=one-official" report --k8s dv-op/lf-langfuse-clickhouse-0-0-0 --context prod-ctx --save-raw "$W/raw.typed" >"$W/typed.md" 2>"$W/r.err"; rc_is $? 0 "--context prod-ctx: exit 0"
if awk 'index($0, "[--context] [prod-ctx] ") != 1 { bad = 1 } END { exit bad || NR == 0 }' "$KLOG"; then
    ok "--context prod-ctx: no current-context call, prod-ctx on every call"
else
    fail "--context prod-ctx: $(cut -c1-120 "$KLOG")"
fi
grep -o 'kubectl [^ `]*' "$W/typed.md" | sort | uniq -c >"$W/kwords"
if ! awk '{ print $3 }' "$W/kwords" | grep -qvxE -- '--context|lines' && grep -qF 'kubectl --context prod-ctx exec' "$W/typed.md"; then
    ok "--context prod-ctx: every kubectl command in the report has --context prod-ctx ($(grep -o 'kubectl --context prod-ctx ' "$W/typed.md" | grep -c .) of them)"
else
    fail "--context prod-ctx: $(tr '\n' ' ' <"$W/kwords")"
fi
has "$W/typed.md" "Shell commands below are complete kubectl lines for context prod-ctx." "--context prod-ctx: named in how to run the fixes"
has "$W/typed.md" 'helm list -n dv-op --kube-context prod-ctx' "--context prod-ctx: helm gets --kube-context"
hasnt "$W/typed.md" "fake-ctx" "--context prod-ctx: the current context is not in the report"
# Git Bash: KUBECONFIG=/c/... reaches kubectl.exe unconverted under MSYS_NO_PATHCONV,
# so diskvet converts it with cygpath. A fake cygpath, and a kubectl in front of
# the fake one that notes the KUBECONFIG it gets (still /dev/null in this test).
mkdir "$W/cyg"
cat >"$W/cyg/cygpath" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$W/cyglog"
[ "\$*" = "-w -p /dev/null" ] && printf '%s\r\n' '\\\\.\\NUL'
EOF
cat >"$W/cyg/kubectl" <<EOF
#!/bin/sh
printf '%s\n' "\$KUBECONFIG" >>"$W/kcenv"
exec "$W/bin/kubectl" "\$@"
EOF
chmod +x "$W/cyg/cygpath" "$W/cyg/kubectl"
opath=$PATH; PATH=$W/cyg:$PATH
dv "KFAKE=one-official" report --k8s auto >/dev/null 2>"$W/r.err"; rc=$?
PATH=$opath
if [ "$rc" = 0 ] && [ "$(cat "$W/cyglog")" = "-w -p /dev/null" ] && [ -s "$W/kcenv" ] && ! grep -vqxF '\\.\NUL' "$W/kcenv"; then
    ok "KUBECONFIG=/dev/null with cygpath (Git Bash): kubectl gets \\\\.\\NUL on every call ($(grep -c . "$W/kcenv"))"
else
    fail "KUBECONFIG with cygpath: exit $rc, cygpath '$(cat "$W/cyglog" 2>/dev/null)', kubectl got '$(sort -u "$W/kcenv" 2>/dev/null | tr '\n' ' ')'"
fi
rm -f "$W/cyglog" "$W/kcenv" "$W/cyg/cygpath"
if command -v cygpath >/dev/null 2>&1; then
    ok "no cygpath: skipped (this machine has a real one)"
else
    PATH=$W/cyg:$PATH
    dv "KFAKE=one-official" report --k8s auto >/dev/null 2>&1; rc=$?
    PATH=$opath
    if [ "$rc" = 0 ] && [ -s "$W/kcenv" ] && ! grep -vqxF /dev/null "$W/kcenv"; then ok "no cygpath: KUBECONFIG is passed on as it is"; else fail "no cygpath: exit $rc, kubectl got '$(sort -u "$W/kcenv" | tr '\n' ' ')'"; fi
fi

echo "== exec errors: exit 3 with a hint, ch_unreachable with --print-payload"
execerr() {  # "VAR=value ..." HINT DESC
    dv "KFAKE=one-official $1" report --k8s auto >"$W/r.md" 2>"$W/r.err"; _rc=$?
    if [ "$_rc" = 3 ] && grep -qF -- "$2" "$W/r.err" && [ ! -s "$W/r.md" ]; then ok "$3: exit 3 and the hint"; else fail "$3: exit $_rc: $(cat "$W/r.err")"; fi
    cp "$W/r.err" "$W/execerr.err"
    dv "KFAKE=one-official $1" --print-payload --k8s auto >"$W/p.json" 2>/dev/null; _rc=$?
    if [ "$_rc" = 3 ]; then unreachable "$W/p.json" "$3: --print-payload prints one ch_unreachable line"; else fail "$3: --print-payload exit $_rc"; fi
}
execerr "KFAKE_EXEC=forbidden" "(kubectl exec needs the create verb on pods/exec in namespace dv-op: README, Kubernetes, Permissions. Without it, use kubectl port-forward and --host 127.0.0.1 with a read-only user.)" "pods/exec forbidden"
execerr "KFAKE_EXEC=nosh" "(the container has no sh, for example a distroless image: use kubectl port-forward and --host 127.0.0.1 instead)" "no sh in the container"
execerr "KFAKE_AUTH=1" "(diskvet used the pod's own login: its clickhouse-client config, CLICKHOUSE_USER or CLICKHOUSE_ADMIN_USER. ClickHouse refused it." "login refused (Code 516)"
has "$W/execerr.err" "cannot run queries: Code: 516. default: Authentication failed" "login refused: ClickHouse's Code line wins over kubectl's own line"
hasnt "$W/execerr.err" "command terminated with exit code" "login refused: no 'command terminated' line"
if (PATH=$host_path; command -v clickhouse-client || command -v clickhouse) >/dev/null 2>&1; then
    ok "no clickhouse-client in the pod: skipped (this machine has a real one)"
else
    KFAKE_PODPATH=$host_path; export KFAKE_PODPATH
    dv "KFAKE=one-official" report --k8s auto >/dev/null 2>"$W/r.err"; rc=$?
    unset KFAKE_PODPATH
    if [ "$rc" = 3 ] && grep -qF "(container clickhouse-server has no clickhouse-client; pass --container NAME for the ClickHouse container)" "$W/r.err"; then
        ok "no clickhouse-client in the container: exit 3 and the hint"
    else
        fail "no clickhouse-client: exit $rc: $(cat "$W/r.err")"
    fi
fi
# kubectl exec passes on the status of the command in the pod, and clickhouse-client
# exits with its error code mod 256: Code 380 gives status 124, the status of a
# timeout. That is one failed check, and the others still run.
mkdir "$W/pod124"
cat >"$W/pod124/clickhouse-client" <<EOF
#!/bin/sh
sql=\$(cat)
case \$sql in *"'system_logs'"*"AS check_id"*) echo 'Code: 380. DB::Exception: x' >&2; exit 124 ;; esac
printf '%s\n' "\$sql" | exec "$W/bin/clickhouse-client" "\$@"
EOF
chmod +x "$W/pod124/clickhouse-client"
KFAKE_PODPATH=$W/pod124:$W/bin:$host_path; export KFAKE_PODPATH
dv "KFAKE=one-official" report --k8s auto --save-raw "$W/raw124" >"$W/r.md" 2>"$W/r.err"; rc=$?
unset KFAKE_PODPATH
if [ "$rc" = 0 ] && grep -qxF "@@	system_logs	fail	required	Code: 380. x" "$W/raw124" \
    && ! grep -qF "skipped: an earlier kubectl exec timed out" "$W/raw124" && [ "$(execs)" = "$nexec" ]; then
    ok "Code 380 in the pod (status 124): system_logs fails, every other check still runs ($nexec execs)"
else
    fail "Code 380 (status 124): exit $rc, $(execs) execs (want $nexec): $(grep '^@@' "$W/raw124" | grep fail | cut -c1-80 | tr '\n' ' ')"
fi
has "$W/r.md" "Could not run: Code: 380. x" "Code 380: the report gives ClickHouse's error"

echo "== timeouts: DISKVET_EXEC_TIMEOUT, no exec after a timeout, nothing left running"
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
{ dv "KFAKE=one-official KFAKE_EXEC=hang DISKVET_EXEC_TIMEOUT=5" report --k8s auto 2>"$W/r.err"; echo $? >"$W/rc"; } | cat >/dev/null
t1=$(date +%s)
rc=$(cat "$W/rc")
if [ "$rc" = 3 ] && [ $((t1 - t0)) -le 15 ] && grep -qF "cannot run queries: kubectl exec timed out after 5 s" "$W/r.err"; then
    ok "a hanging exec: exit 3 'timed out after 5 s' in $((t1 - t0)) s, through | cat"
else
    fail "a hanging exec: exit $rc in $((t1 - t0)) s: $(cat "$W/r.err")"
fi
has "$W/r.err" "(the API server or the pod did not answer. Set DISKVET_EXEC_TIMEOUT to wait longer; if your API server is older than your kubectl, try KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false.)" "a hanging exec: the hint"
rc_is "$(execs)" 1 "a hanging exec: nothing after the probe"
sleep 1
noleft "no sleep left over (neither the watchdog's nor the hanging kubectl)" 'sleep 5' 'sleep 600'

dv "KFAKE=one-official KFAKE_EXEC=hang_at=3 DISKVET_EXEC_TIMEOUT=5" report --k8s auto --save-raw "$W/raw" >"$W/r.md" 2>"$W/r.err"; rc_is $? 0 "hang_at=3: exit 0"
rc_is "$(execs)" 3 "hang_at=3: no exec after the 3rd"
statuses "$W/r.md" "NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN" "hang_at=3 (the probe, passport, then drop_limit hangs): every check after it NOT_RUN"
if awk -F '\t' '
        $1 != "@@" || $2 == "_target" { next }
        { k++ }
        k == 1 { if ($2 != "passport" || $3 != "ok") bad = 1; next }
        k == 2 { if ($2 != "drop_limit" || $5 != "kubectl exec timed out after 5 s") bad = 1; next }
        $3 != "fail" || $5 != "skipped: an earlier kubectl exec timed out" { bad = 1 }
        END { exit bad || k < 10 }' "$W/raw"; then
    ok "hang_at=3: passport ok, drop_limit timed out, every later query 'skipped: an earlier kubectl exec timed out'"
else
    fail "hang_at=3: $(grep '^@@' "$W/raw" | cut -c1-100 | tr '\n' ' ')"
fi
has "$W/r.md" "Could not run: skipped: an earlier kubectl exec timed out" "hang_at=3: the report says why"
dv "KFAKE=one-official KFAKE_EXEC=hang_at=6 DISKVET_EXEC_TIMEOUT=5" report --k8s auto >"$W/r.md" 2>"$W/r.err"; rc_is $? 0 "hang_at=6: exit 0"
s1=$(status_of "$W/r.md" 1); s2=$(status_of "$W/r.md" 2); got=""
for i in 3 4 5 6 7; do got="$got $(status_of "$W/r.md" "$i")"; done
if [ -n "$s1" ] && [ "$s1" != NOT_RUN ] && [ -n "$s2" ] && [ "$s2" != NOT_RUN ] \
    && [ "$got" = " NOT_RUN NOT_RUN NOT_RUN NOT_RUN NOT_RUN" ] && [ "$(execs)" = 6 ]; then
    ok "hang_at=6 (disk_now hangs): checks 1 and 2 ran ($s1 $s2), the 3rd check and all later ones NOT_RUN"
else
    fail "hang_at=6: $s1 $s2$got, $(execs) execs"
fi
sleep 1
noleft "no sleep left over after hang_at" 'sleep 5' 'sleep 600'

fresh
DISKVET_EXEC_TIMEOUT=30 KFAKE=one-official KFAKE_EXEC=hang sh diskvet.sh report --k8s auto </dev/null >/dev/null 2>&1 &
bg=$!
i=0
while [ "$i" -lt 20 ] && ! grep -q '\[exec\]' "$KLOG"; do sleep 1; i=$((i + 1)); done
sleep 1
kill -TERM "$bg"
wait "$bg"; rc=$?
sleep 1
rc_is "$rc" 130 "TERM during an exec: exit 130"
noleft "TERM kills the kubectl exec and the watchdog" 'sleep 30' 'sleep 600'

echo "== payload: no cluster names, and hashing fails closed"
salt=$(sed -n 's/^SALT=//p' tests/fixtures/test.env)
dv "KFAKE=one-official" --print-payload --k8s auto --env tests/fixtures/test.env >"$W/p.json" 2>"$W/p.err"; rc_is $? 0 "--print-payload --k8s auto: exit 0"
has "$W/p.err" "cannot hash table names, so the payload has no tables: Code: 1001." "the fake clickhouse local fails: the note"
has "$W/p.json" '"tables": [ ],' "... and the tables are dropped"
has "$W/p.json" '"not_run": ["tables"]' "... and listed as not run"
if grep '\[exec\]' "$KLOG" | grep -qF '[cd /tmp && exec clickhouse local "$@"] [sh] [--input-format] [TSV]'; then ok "the names were sent to clickhouse local inside the pod"; else fail "no clickhouse local exec"; fi
if sh tests/check_payload.sh "$W/p.json" dv-op lf-langfuse-clickhouse-0-0-0 clickhouse-server fake-ctx \
        clickhouse-storage-volume-lf-langfuse-clickhouse-0-0-0 lf-langfuse customer_acme payments_eu "$salt" >"$W/p.txt" 2>&1; then
    ok "check_payload.sh passes with the namespace, pod, container, context, PVC, group and salt forbidden"
else
    fail "payload: $(cat "$W/p.txt")"
fi
hasnt "$KLOG" "$salt" "the salt is not in any kubectl command line"
hasnt "$CLOG" "$salt" "... nor in clickhouse-client's"
dv "KFAKE=one-official KFAKE_EXEC=forbidden" --print-payload --k8s auto --env tests/fixtures/test.env >"$W/p.json" 2>/dev/null
unreachable "$W/p.json" "exec forbidden with --env: one ch_unreachable line"

echo "== --save-raw and --replay"
norm() { sed -e '/^# ClickHouse check-up /d' -e 's/ Rendered from saved query results (--replay)\./ Queries ran with readonly=2 and resource limits./' "$1"; }
if [ "$(sed -n '1p' "$W/raw.untyped")" = "@@	_target	ok" ] && [ "$(tgt "$W/raw.untyped")" = "$official_target|" ]; then
    ok "--save-raw starts with the _target row (no context: it was not typed)"
else
    fail "--save-raw: $(sed -n '1,2p' "$W/raw.untyped")"
fi
fresh
sh diskvet.sh report --replay "$W/raw.untyped" </dev/null >"$W/rep.md" 2>"$W/r.err"; rc_is $? 0 "--replay of a --k8s --save-raw file: exit 0"
norm "$W/untyped.md" >"$W/a"; norm "$W/rep.md" >"$W/b"
if cmp -s "$W/a" "$W/b"; then ok "round trip: the replay is the live report (without the date line)"; else fail "round trip: $(diff "$W/a" "$W/b" | sed -n '1,6p')"; fi
if [ -s "$KLOG" ]; then fail "--replay called kubectl: $(sed -n '1p' "$KLOG")"; else ok "--replay calls no kubectl"; fi
sh diskvet.sh report --replay "$W/raw.typed" </dev/null >"$W/rep.md" 2>/dev/null
norm "$W/typed.md" >"$W/a"; norm "$W/rep.md" >"$W/b"
if cmp -s "$W/a" "$W/b"; then ok "round trip with a typed --context: same report, --context prod-ctx kept"; else fail "round trip (typed): $(diff "$W/a" "$W/b" | sed -n '1,6p')"; fi
sh diskvet.sh report --replay "$W/raw.untyped" --docker x </dev/null >/dev/null 2>"$W/r.err"; rc=$?
if [ "$rc" = 2 ] && grep -qF "was saved from a --k8s run; leave out --docker" "$W/r.err"; then ok "--replay of a --k8s file with --docker: refused"; else fail "--replay + --docker: exit $rc: $(cat "$W/r.err")"; fi
sh diskvet.sh report --replay "$W/raw.untyped" --k8s lf/other-0 </dev/null >/dev/null 2>"$W/r.err"; rc=$?
if [ "$rc" = 2 ] && grep -qF "was saved from a --k8s run and already names its pod; leave out --k8s" "$W/r.err"; then ok "--replay of a --k8s file with --k8s: refused"; else fail "--replay + --k8s: exit $rc: $(cat "$W/r.err")"; fi
awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "_target" { $3 = "l;f" } 1' "$W/raw.untyped" >"$W/bad.tsv"
sh diskvet.sh report --replay "$W/bad.tsv" </dev/null >/dev/null 2>"$W/r.err"; rc=$?
if [ "$rc" = 2 ] && grep -qF "its _target line is not what diskvet writes" "$W/r.err"; then ok "--replay with a damaged _target row: refused"; else fail "damaged _target: exit $rc: $(cat "$W/r.err")"; fi
# a CR inside a name: checked and rendered from the same bytes, so none reaches a
# printed command (a CR there would run the rest of the line as a new command)
awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "_target" { $5 = "clickhouse-ser\rver"; $9 = "prod\r/tmp/x" } 1' "$W/raw.untyped" >"$W/cr.tsv"
sh diskvet.sh report --replay "$W/cr.tsv" </dev/null >"$W/rep.md" 2>"$W/r.err"; rc=$?
cr=$(printf '\r')
if [ "$rc" = 0 ] && ! grep -q "$cr" "$W/rep.md" && grep -qF "kubectl --context prod/tmp/x exec -n dv-op lf-langfuse-clickhouse-0-0-0 -c clickhouse-server -- sh -c 'touch " "$W/rep.md"; then
    ok "--replay with a CR inside the container and the context: no CR in the report"
else
    fail "CR inside _target: exit $rc, $(grep -c "$cr" "$W/rep.md") lines with a CR: $(cat "$W/r.err")"
fi
awk '{ printf "%s\r\n", $0 }' "$W/raw.untyped" >"$W/crlf.tsv"
sh diskvet.sh report --replay "$W/crlf.tsv" </dev/null >"$W/rep.md" 2>/dev/null
norm "$W/untyped.md" >"$W/a"; norm "$W/rep.md" >"$W/b"
if cmp -s "$W/a" "$W/b"; then ok "--replay of the --save-raw file with CR LF (Windows): the same report"; else fail "CR LF replay: $(diff "$W/a" "$W/b" | sed -n '1,6p')"; fi
# a disk path with a quote (TSV sends ' as \'): printed sh -c '...' commands get a
# placeholder, never the path
qpath="/var/lib/clickhouse/\\\\'\$(id>/tmp/pwned)\\\\'/"   # awk -v makes each \\ one \
awk -F '\t' -v p="$qpath" 'BEGIN { OFS = "\t" } $1 == "disk_now" && $2 == "default" { $3 = p } 1' "$W/raw.untyped" >"$W/quote.tsv"
sh diskvet.sh report --replay "$W/quote.tsv" </dev/null >"$W/rep.md" 2>"$W/r.err"; rc=$?
if [ "$rc" = 0 ] && grep -qF "/var/lib/clickhouse/\\'\$(id>/tmp/pwned)" "$W/quote.tsv"; then ok "a disk path with a quote: the replay file has it, exit 0"; else fail "quote path: exit $rc: $(grep '^disk_now' "$W/quote.tsv")"; fi
hasnt "$W/rep.md" "pwned" "a disk path with a quote: not in any printed command"
has "$W/rep.md" "kubectl exec -n dv-op lf-langfuse-clickhouse-0-0-0 -c clickhouse-server -- sh -c 'touch <data path>/flags/force_drop_table && chmod 666 <data path>/flags/force_drop_table'" "... the flag line gets <data path>"
# a pod without an operator gets the du line of check 2 and the volume line of check 3
{ cat tests/fixtures/k8s/target.plain; sed '1,2d' "$W/quote.tsv"; } >"$W/quote-plain.tsv"
sh diskvet.sh report --replay "$W/quote-plain.tsv" </dev/null >"$W/rep.md" 2>"$W/r.err"; rc_is $? 0 "a disk path with a quote, plain pod: exit 0"
hasnt "$W/rep.md" "pwned" "... not in any printed command"
has "$W/rep.md" "sh -c 'du -xk -d 2 <data path>/ 2>/dev/null" "... the du line of check 2 gets <data path>"
has "$W/rep.md" "Grow the one mounted at <data path>/ with \`kubectl patch pvc -n dv-plain <pvc> -p " "... and so does the volume line of check 3"
fresh
sh diskvet.sh report --replay tests/fixtures/alex.tsv --k8s lf/ch-0 --container ch --context ctx-x </dev/null >"$W/rep.md" 2>/dev/null; rc_is $? 0 "--replay alex.tsv --k8s lf/ch-0: exit 0"
has "$W/rep.md" "kubectl --context ctx-x exec -n lf ch-0 -c ch -- sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'" "... rendered as a report about that pod"
hasnt "$W/rep.md" "Heads-up for Kubernetes" "... its volumes are unknown: no volume heads-up"
has "$W/rep.md" "**Fix B: stop it coming back.** Safe if the pod keeps its data on a PersistentVolumeClaim (on an emptyDir or in the container, the restart deletes it);" "... its volumes are unknown: Fix B is safe only with a PVC"
has "$W/rep.md" "A pod without a PersistentVolumeClaim loses its data this way." "... and so is the delete pod line"
if [ -s "$KLOG" ]; then fail "--replay --k8s called kubectl: $(sed -n '1p' "$KLOG")"; else ok "... and no kubectl call"; fi
sh diskvet.sh --print-payload --replay "$W/raw.untyped" </dev/null >"$W/p.json" 2>/dev/null
if sh tests/check_payload.sh "$W/p.json" dv-op lf-langfuse-clickhouse-0-0-0 clickhouse-server clickhouse-storage-volume-lf-langfuse-clickhouse-0-0-0 lf-langfuse >"$W/p.txt" 2>&1; then
    ok "the payload of a --k8s --save-raw file ignores the _target row"
else
    fail "payload from raw: $(cat "$W/p.txt")"
fi

echo "== the report of a --k8s run"
has "$W/untyped.md" "detected: Langfuse · pod dv-op/lf-langfuse-clickhouse-0-0-0" "header: the pod"
awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "passport" { $0 = $0 OFS "bn_admin" } 1' tests/fixtures/alex.tsv >"$W/ranas.tsv"
dv "KFAKE=one-bitnami8 KFAKE_STREAM=$W/ranas.tsv" report --k8s auto >"$W/r.md" 2>/dev/null
has "$W/r.md" "· pod dv-bn8/bn8-clickhouse-shard0-0 · user bn_admin" "header: the user the checks ran as (passport ran_as)"
has "$W/r.md" "\`kubectl exec -it -n dv-bn8 bn8-clickhouse-shard0-0 -c clickhouse -- sh -c 'exec clickhouse-client --user \"\$CLICKHOUSE_ADMIN_USER\" --password \"\${CLICKHOUSE_ADMIN_PASSWORD:-\$(cat \"\$CLICKHOUSE_ADMIN_PASSWORD_FILE\")}\"'\`" "Bitnami: the client command logs in from the pod's env"
has "$W/untyped.md" "\`kubectl exec -it -n dv-op lf-langfuse-clickhouse-0-0-0 -c clickhouse-server -- clickhouse-client\`. Inside the pod it logs in as \`default\`" "operator: the plain client command"
dv "KFAKE=nopvc" report --k8s auto >"$W/r.md" 2>/dev/null
has "$W/r.md" "- This pod mounts no PersistentVolumeClaim: ClickHouse data is on the node's disk" "no PVC: the heads-up"
has "$W/r.md" "sh -c 'exec clickhouse-client \${CLICKHOUSE_USER:+--user \"\$CLICKHOUSE_USER\"} \${CLICKHOUSE_PASSWORD:+--password \"\$CLICKHOUSE_PASSWORD\"}'" "plain: the client command uses the pod's env when set"

echo "== flavor replays: the fixes per chart (tests/fixtures/k8s/target.* + alex.tsv)"
# stream TARGET PRODUCT [REPLICATED [ALLTTL [DISK FREE]]]: the _target row of
# tests/fixtures/k8s/target.TARGET (or of the file TARGET, a path with a /), then
# alex.tsv with this product and replicated in the passport, with ALLTTL=1 every
# system log has a TTL, and DISK/FREE (bytes) for the default disk
stream() {
    case $1 in */*) cat "$1" ;; *) cat "tests/fixtures/k8s/target.$1" ;; esac
    awk -F '\t' -v p="$2" -v r="${3:-0}" -v a="${4:-0}" -v t="${5:-}" -v f="${6:-}" 'BEGIN { OFS = "\t" }
        $1 == "passport" { $4 = p; $5 = r }
        $1 == "system_logs" && a == 1 { $4 = 1; $5 = 30 }
        $1 == "disk_now" && t != "" { $4 = t; $5 = f; $6 = f }
        1' tests/fixtures/alex.tsv
}
flavor() {  # NAME TARGET PRODUCT [...]: $W/f.NAME.md, the report of that stream (no kubectl)
    _n=$1; shift
    stream "$@" >"$W/f.$_n.tsv"
    fresh
    sh diskvet.sh report --replay "$W/f.$_n.tsv" </dev/null >"$W/f.$_n.md" 2>"$W/f.$_n.err"; _rc=$?
    if [ "$_rc" = 0 ] && [ ! -s "$KLOG" ] && grep -q '^## 7\. ' "$W/f.$_n.md"; then ok "$_n: rendered, no kubectl call"; else fail "$_n: exit $_rc: $(cat "$W/f.$_n.err")"; fi
    nodocker "$W/f.$_n.md" "$_n: no docker, docker compose, daemon.json, systemctl, sudo or json-file"
}
lines() {  # FILE DESC LINE...: FILE has these lines, one right after the other
    _f=$1 _d=$2; shift 2
    printf '%s\n' "$@" >"$W/want"
    if awk 'NR == FNR { w[++k] = $0; next } { l[++n] = $0 }
            END { for (i = 1; i + k - 1 <= n; i++) { for (j = 1; j <= k; j++) if (l[i + j - 1] != w[j]) break; if (j > k) exit 0 } exit 1 }' "$W/want" "$_f"; then
        ok "$_d"
    else
        fail "$_d (missing: $(tr '\n' '|' <"$W/want"))"
    fi
}
# The YAML of every ```yaml block: 2-space indents, no tabs, a key without a value
# has children exactly 2 deeper, a value never has children, a block scalar
# (key: |) is not empty and deeper than its key, "..." values are closed, and
# plain values are words. First problem to stdout, exit 1; else the block count.
cat >"$W/yamllint.awk" <<'EOF'
function bad(m) { printf "line %d: %s: %s\n", FNR, m, $0; err = 1; exit 1 }
/^```yaml$/ { if (iny) bad("a fence inside a yaml block"); iny = 1; nb++; prev = -1; kids = 0; bs = -1; bsneed = 0; next }
iny && /^```$/ {
    if (kids) bad("a key without a value or children at the end")
    if (bsneed) bad("an empty block scalar at the end")
    if (prev < 0) bad("an empty yaml block")
    iny = 0; next
}
!iny { next }
{
    if (index($0, "\t")) bad("a tab")
    if ($0 == "") { if (bs >= 0) next; bad("an empty line outside a block scalar") }
    match($0, /^ */); d = RLENGTH
    if (d % 2) bad("an indent that is not a multiple of 2")
    if (bs >= 0) {
        if (d > bs) { bsneed = 0; next }
        if (bsneed) bad("a block scalar that is not deeper than its key")
        bs = -1
    }
    if (prev < 0 && d != 0) bad("the first line is indented")
    if (kids && d != prev + 2) bad("the first child of a key is not 2 deeper")
    if (!kids && prev >= 0 && d > prev) bad("deeper than a line with a value")
    line = substr($0, d + 1)
    if (!match(line, /^[A-Za-z0-9_.\/-]+:/)) bad("not a key")
    v = substr(line, RLENGTH + 1)
    kids = 0
    if (v == "") kids = 1
    else if (v == " |") { bs = d; bsneed = 1 }
    else if (v ~ /^ "/) { if (substr(v, 2) !~ /^"([^"\\]|\\.)*"$/) bad("a double-quoted value that is not closed") }
    else if (v !~ /^ [A-Za-z0-9_.-]+$/) bad("a plain value that is not one word")
    prev = d
}
END { if (err) exit 1; if (iny) { print "a yaml block without its closing fence"; exit 1 } print nb + 0 }
EOF
yamlok() {  # FILE DESC: every ```yaml block in FILE passes the lint, and there is one at least
    if _y=$(awk -f "$W/yamllint.awk" "$1") && [ "$_y" -gt 0 ]; then ok "$2: the YAML passes the lint ($_y block(s))"; else fail "$2: YAML lint: $_y"; fi
}
# the lint itself: each of these blocks is refused (~ is a newline, @ a tab)
for m in 'a:~@b: 1' 'a:~   b: 1' 'a:~    b: 1' 'a: 1~  b: 1' 'a:~  f: |~  <x/>' 'a:~  f: |' 'a:~  b: "x' 'a:~  b: "x\"' \
        'a:~  b: x y' 'a:' '  a: 1' 'a b: 1' 'a:~~  b: 1'; do
    { echo '```yaml'; printf '%s\n' "$m" | tr '~@' '\n\t'; echo '```'; } >"$W/lint.md"
    if awk -f "$W/yamllint.awk" "$W/lint.md" >/dev/null; then fail "the YAML lint misses: $m"; else ok "the YAML lint catches: $m"; fi
done
{ echo '```yaml'; printf '%s\n' 'a:' '  b:' '    c: "x \"y\" \\ z"' '    f.xml: |' '        <x>' '' '          <y/>' '        </x>' '  d: 10' 'e: word'; echo '```'; } >"$W/lint.md"
if [ "$(awk -f "$W/yamllint.awk" "$W/lint.md")" = 1 ]; then ok "the YAML lint passes good YAML"; else fail "the YAML lint refuses good YAML: $(awk -f "$W/yamllint.awk" "$W/lint.md")"; fi

flag_line() { printf '%s' "kubectl exec -n $1 -- sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'"; }
fixb_end="Then run your usual \`helm upgrade\`: \`helm list -n"
flavor official-langfuse official langfuse
f=$W/f.official-langfuse.md
yamlok "$f" "official+langfuse"
lines "$f" "official+langfuse: the logger and the logs in clickhouse.cluster.settings (the operator's extraConfig)" '```yaml' 'clickhouse:' '  cluster:' '    settings:' '      logger:' \
    '        level: information' '        size: "100M"' '        count: 10' '      trace_log:' '        ttl: "event_date + INTERVAL 7 DAY DELETE"'
# Langfuse chart 2.1.2 has no clickhouse.cluster.logger value (it would be ignored)
if grep -qx '    logger:' "$f"; then fail "official+langfuse: a clickhouse.cluster.logger key"; else ok "official+langfuse: no clickhouse.cluster.logger key"; fi
has "$f" '        engine: "ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE"' "official+langfuse: opentelemetry_span_log gets its TTL inside engine"
has "$f" "This pod is run by the ClickHouse operator (Langfuse chart 2.x). Add this to the values you deploy Langfuse with. These keys take YAML, not XML" "official+langfuse: the text"
hasnt "$f" '```xml' "official+langfuse: no XML block"
# the YAML lists the logs of the XML (the same stream, rendered as a plain pod)
sed -n '/^      logger:$/d; s/^      \([a-z_]*\):$/\1/p' "$f" >"$W/yaml.logs"
flavor xml-ref plain other
sed -n 's/^    <\([a-z_]*\)>$/\1/p' "$W/f.xml-ref.md" >"$W/xml.logs"
if [ -s "$W/xml.logs" ] && cmp -s "$W/yaml.logs" "$W/xml.logs"; then ok "official+langfuse: the YAML has the logs of the XML, in order ($(tr '\n' ' ' <"$W/yaml.logs"))"; else fail "official+langfuse: YAML logs '$(tr '\n' ' ' <"$W/yaml.logs")', XML logs '$(tr '\n' ' ' <"$W/xml.logs")'"; fi
has "$f" "$(flag_line "lf langfuse-clickhouse-0-0-0 -c clickhouse-server")" "official+langfuse: the kubectl flag line"
has "$f" "Most likely: ClickHouse's own server log files. With the ClickHouse operator they are on this volume (/var/log/clickhouse-server)" "official: check 2 names the server log files"
lines "$f" "official: check 2 prints the du line" '```sh' 'kubectl exec -n lf langfuse-clickhouse-0-0-0 -c clickhouse-server -- du -sh /var/log/clickhouse-server' '```'
has "$f" "**Fix: free space now.** Irreversible, safe for your data, no restart: it deletes only rotated server log files; the current ones stay." "official: the rm fix says it is irreversible"
lines "$f" "official: the rm-rotated-logs line" '```sh' "kubectl exec -n lf langfuse-clickhouse-0-0-0 -c clickhouse-server -- sh -c 'rm -f /var/log/clickhouse-server/*.log.*'" '```'
has "$f" "**Fix: keep them small.** The logger lines in check 1's Fix B do this (level information, 10 files of 100 MB); they apply with the same helm upgrade." "official: check 2 points to the logger lines of Fix B"
hasnt "$f" "See what takes the space (read-only, inside the pod)" "official: not the generic check 2 text"
hasnt "$f" "patch pvc" "official: no patch pvc (the operator owns the volume)"
has "$f" "Or give the volume more room: it belongs to the operator, so grow it through the operator's resource, not the PVC (keys per chart: the Kubernetes page linked above). \`kubectl get pvc -n lf clickhouse-storage-volume-langfuse-clickhouse-0-0-0\` shows its size and StorageClass." "official: check 3 grows the volume through the operator"
has "$f" "$fixb_end lf\` shows the release" "official+langfuse: the common ending"
has "$f" "The chart or the operator restarts the pod. If the pod has not restarted within 5 minutes (the AGE column of \`kubectl get pod -n lf langfuse-clickhouse-0-0-0\`), restart it yourself: \`kubectl delete pod -n lf langfuse-clickhouse-0-0-0\` (its StatefulSet recreates it with the same volume; about a minute of downtime)." "official: the operator restarts the pod; the delete line as the last resort"
has "$f" "**Fix B: stop it coming back.** Safe; the ClickHouse pod restarts" "official, with a PVC: Fix B is safe"
has "$f" "If the pod crash-loops and \`kubectl logs -n lf langfuse-clickhouse-0-0-0 -c clickhouse-server --previous\` says" "official+langfuse: the crash hint"

flavor official-clickstack official clickstack
f=$W/f.official-clickstack.md
yamlok "$f" "official+clickstack"
lines "$f" "official+clickstack: clickhouse.cluster.spec.settings logger and extraConfig" 'clickhouse:' '  cluster:' '    spec:' '      settings:' '        logger:' \
    '          level: information' '          size: "100M"' '          count: 10' '        extraConfig:' '          trace_log:' '            ttl: "event_date + INTERVAL 7 DAY DELETE"'
has "$f" "ClickStack chart 3.4.0 and later already sets a 7-day TTL on these logs and this logger, so upgrading the chart is the simplest fix." "official+clickstack: upgrading to 3.4.0 is the simplest fix"

flavor official-other official other
f=$W/f.official-other.md
yamlok "$f" "official+other"
lines "$f" "official+other: spec.settings logger and extraConfig" '```yaml' 'spec:' '  settings:' '    logger:' '      level: information' '      size: "100M"' '      count: 10' '    extraConfig:' '      trace_log:'
has "$f" "This pod is run by the ClickHouse operator (ClickHouseCluster langfuse-clickhouse in namespace lf). Add this under \`spec\` of that resource (YAML, not XML): in the Helm values that render it, or with \`kubectl edit clickhousecluster -n lf langfuse-clickhouse\` (a helm upgrade overwrites manual edits):" "official+other: the ClickHouseCluster and kubectl edit"
# a group name that was not a Kubernetes name was dropped: how to find the resource
awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "_target" { $8 = "" } 1' tests/fixtures/k8s/target.official >"$W/target.nogroup"
flavor official-nogroup "$W/target.nogroup" other
f=$W/f.official-nogroup.md
has "$f" "(the ClickHouseCluster of this pod (\`kubectl get clickhousecluster -n lf\`)). Add this under \`spec\`" "official, no group: how to find the ClickHouseCluster"
has "$f" "\`kubectl edit clickhousecluster -n lf <name>\`" "official, no group: kubectl edit with <name>"

# every log has a TTL: no Fix B, so check 2 prints the logger block itself
flavor official-ttl official langfuse 0 1
f=$W/f.official-ttl.md
hasnt "$f" "**Fix B" "official, every log has a TTL: no Fix B"
yamlok "$f" "official, every log has a TTL"
lines "$f" "official+langfuse, no Fix B: check 2 prints clickhouse.cluster.settings.logger" "**Fix: keep them small.** Set the logger in your values and run your usual helm upgrade (the pod restarts):" \
    '```yaml' 'clickhouse:' '  cluster:' '    settings:' '      logger:' '        level: information' '        size: "100M"' '        count: 10' '```'
flavor official-ttl-cs official clickstack 0 1
lines "$W/f.official-ttl-cs.md" "official+clickstack, no Fix B: check 2 prints clickhouse.cluster.spec.settings.logger" \
    '```yaml' 'clickhouse:' '  cluster:' '    spec:' '      settings:' '        logger:' '          level: information'
flavor official-ttl-other official other 0 1
f=$W/f.official-ttl-other.md
yamlok "$f" "official+other, no Fix B"
lines "$f" "official+other, no Fix B: check 2 prints spec.settings.logger of the ClickHouseCluster" \
    "**Fix: keep them small.** Set the logger in your values and run your usual helm upgrade (the pod restarts). It is \`spec.settings.logger\` of ClickHouseCluster langfuse-clickhouse in namespace lf:" \
    '```yaml' 'spec:' '  settings:' '    logger:' '      level: information'

flavor altinity-signoz altinity signoz
f=$W/f.altinity-signoz.md
yamlok "$f" "altinity+signoz"
lines "$f" "altinity+signoz: config.d/zz-diskvet-ttl.xml under clickhouse.files" '```yaml' 'clickhouse:' '  files:' '    config.d/zz-diskvet-ttl.xml: |' '        <clickhouse>'
has "$f" "never here: a second definition of those logs stops ClickHouse from starting." "altinity+signoz: the text"
# SigNoz's clickhouse chart: clickhouseOperator.queryLog.ttl, .partLog.ttl, ...
has "$f" "are changed with \`clickhouse.clickhouseOperator.<logName>.ttl\` (days; the log name in camelCase, such as \`queryLog\` for query_log)," "altinity+signoz: the chart's TTL keys are camelCase"
altinity_restart="The Altinity operator may not restart the pod for a changed file (release 0.27.4 does not), and system logs change only on restart. Once \`kubectl exec -n signoz chi-signoz-clickhouse-cluster-0-0-0 -c clickhouse -- ls /etc/clickhouse-server/config.d\` lists zz-diskvet-ttl.xml and the pod has not restarted (the AGE column of \`kubectl get pod -n signoz chi-signoz-clickhouse-cluster-0-0-0\`), restart it yourself: \`kubectl delete pod -n signoz chi-signoz-clickhouse-cluster-0-0-0\` (its StatefulSet recreates it with the same volume; about a minute of downtime)."
has "$f" "$altinity_restart" "altinity+signoz: the operator does not restart the pod; restart it once the file is in the pod"
hasnt "$f" "The chart or the operator restarts the pod." "altinity+signoz: no wait for a restart that does not come"
# the block scalar holds exactly the XML a plain pod gets, indented
awk '/^    config.d\/zz-diskvet-ttl.xml: [|]$/ { on = 1; next } on && /^```$/ { exit }
     on { if (substr($0, 1, 8) != "        ") print "NOT INDENTED BY 8: " $0; else print substr($0, 9) }' "$f" >"$W/signoz.xml"
awk '/^```xml$/ { on = 1; next } on && /^```$/ { exit } on' "$W/f.xml-ref.md" >"$W/plain.xml"
if [ -s "$W/plain.xml" ] && cmp -s "$W/signoz.xml" "$W/plain.xml"; then
    ok "altinity+signoz: the block scalar is the plain XML, every line indented by 8"
else
    fail "altinity+signoz: the XML differs from the plain one: $(diff "$W/plain.xml" "$W/signoz.xml" | sed -n '1,4p' | tr '\n' ' ')"
fi
has "$f" "See what takes the space (read-only, inside the pod)" "altinity: the generic check 2 text"
hasnt "$f" "rm -f /var/log/clickhouse-server" "altinity: no rm line (that is the ClickHouse operator's volume)"
hasnt "$f" "patch pvc" "altinity: no patch pvc (the operator owns the volume)"
has "$f" "it belongs to the operator, so grow it through the operator's resource, not the PVC (keys per chart: the Kubernetes page linked above). \`kubectl get pvc -n signoz data-volumeclaim-template-chi-signoz-clickhouse-cluster-0-0-0\` shows its size" "altinity: check 3 grows the volume through the operator"

flavor altinity-other altinity other
f=$W/f.altinity-other.md
yamlok "$f" "altinity+other"
lines "$f" "altinity+other: config.d/zz-diskvet-ttl.xml under spec.configuration.files" '```yaml' 'spec:' '  configuration:' '    files:' '      config.d/zz-diskvet-ttl.xml: |' '          <clickhouse>'
has "$f" "This pod is run by the Altinity operator (ClickHouseInstallation signoz-clickhouse in namespace signoz)." "altinity+other: the ClickHouseInstallation"
has "$f" "To change the resource directly: \`kubectl edit chi -n signoz signoz-clickhouse\` (a helm upgrade overwrites manual edits)." "altinity+other: kubectl edit chi"
has "$f" "$altinity_restart" "altinity+other: the operator does not restart the pod; restart it once the file is in the pod"
hasnt "$f" "The chart or the operator restarts the pod." "altinity+other: no wait for a restart that does not come"

# Langfuse 1.x on the Bitnami chart's default 8Gi volume
flavor bitnami8 bitnami8 langfuse 0 0 8589934592 1073741824
f=$W/f.bitnami8.md
yamlok "$f" "bitnami8"
lines "$f" "bitnami8: extraOverrides under clickhouse" '```yaml' 'clickhouse:' '  extraOverrides: |' '    <clickhouse>'
has "$f" "This pod comes from the Bitnami ClickHouse chart (Langfuse chart 1.x uses it). Add this to your values. \`extraOverrides\` is one string" "bitnami8: the text"
hasnt "$f" "Bitnami chart 9.x uses \`configdFiles\` instead" "bitnami8: no 9.x sentence (only for an unknown Bitnami chart)"
has "$f" "| default | 8.0 GiB | " "bitnami8: an 8 GiB disk"
lines "$f" "bitnami8: get pvc, get storageclass and the patch pvc line with 20Gi for an 8 GiB disk" "Or give the volume more room, if its StorageClass allows it:" '```sh' \
    'kubectl get pvc -n langfuse data-langfuse-clickhouse-shard0-0' "kubectl get storageclass    # the PVC's class needs ALLOWVOLUMEEXPANSION true" \
    "kubectl patch pvc -n langfuse data-langfuse-clickhouse-shard0-0 -p '{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"20Gi\"}}}}'" '```'
has "$f" "20Gi is about twice the current size. The patch can't be undone (a volume never shrinks). Leave the size in your Helm values as it is: helm upgrade can't change a StatefulSet's volumeClaimTemplates." "bitnami8: the patch says it can't be undone"
bitnami_client="kubectl exec -it -n langfuse langfuse-clickhouse-shard0-0 -c clickhouse -- sh -c 'exec clickhouse-client --user \"\$CLICKHOUSE_ADMIN_USER\" --password \"\${CLICKHOUSE_ADMIN_PASSWORD:-\$(cat \"\$CLICKHOUSE_ADMIN_PASSWORD_FILE\")}\"'"
has "$f" "\`$bitnami_client\`" "bitnami8: the Bitnami client wrapper"
flavor bitnami8-150 bitnami8 langfuse
has "$W/f.bitnami8-150.md" "\"storage\":\"300Gi\"" "bitnami8: 300Gi for a 150 GiB disk"
flavor bitnami8-3 bitnami8 langfuse 0 0 3221225472 1073741824
has "$W/f.bitnami8-3.md" "\"storage\":\"10Gi\"" "bitnami8: at least 10Gi (a 3 GiB disk)"

flavor bitnami bitnami other
f=$W/f.bitnami.md
yamlok "$f" "bitnami (chart unknown)"
has "$f" "If you installed the Bitnami chart on its own, leave out the \`clickhouse:\` level. Bitnami chart 9.x uses \`configdFiles\` instead: see the Kubernetes page linked above." "bitnami: the 9.x sentence"

# bitnami9: the 00- file in configdFiles (the kind job shows it loads before the
# chart's 08-sampling.xml)
flavor bitnami9 bitnami9 other
f=$W/f.bitnami9.md
yamlok "$f" "bitnami9"
lines "$f" "bitnami9: 00-diskvet-ttl.xml under configdFiles" '```yaml' 'configdFiles:' '  00-diskvet-ttl.xml: |' '    <clickhouse>'
has "$f" "The name starts with 00- so it loads before the chart's 08-sampling.xml: logs the chart turned off stay off." "bitnami9: the text"
has "$f" "and DROP those instead (irreversible, safe for your data: ClickHouse no longer writes to them)." "bitnami9: the DROP of old log tables says it is irreversible"
has "$f" "\`SELECT table, max(modification_time) AS last_write FROM system.parts WHERE database = 'system' AND active GROUP BY table ORDER BY last_write;\`" "bitnami9: the SELECT for logs no longer written"
hasnt "$f" "- trigger.dev chart 4.5.10 and later: values" "bitnami9: not the plain Fix B"
has "$f" "kubectl patch pvc -n trigger data-trigger-clickhouse-shard0-0 -p " "bitnami9: the patch pvc line"
nodocker "$f" "bitnami9: no docker"
flavor bitnami9-clickstack bitnami9 clickstack
hasnt "$W/f.bitnami9-clickstack.md" "ClickStack chart 1.x" "bitnami9 with ClickStack tables: the Bitnami 9.x text, not the ClickStack 1.x one"
has "$W/f.bitnami9-clickstack.md" "  00-diskvet-ttl.xml: |" "bitnami9 with ClickStack tables: the 00- file"

flavor plain plain other
f=$W/f.plain.md
lines "$f" "plain: the XML" '```xml' '<clickhouse>' "    <!-- diskvet $(sed -n 's/^VERSION=//p' diskvet.sh): TTL for system logs that had none -->" '    <trace_log>' '        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>'
has "$f" "- Sentry chart up to 28 (bundled ClickHouse): \`clickhouse.clickhouse.configmap.configOverride\`" "plain: the chart list"
has "$f" "- other charts: a ConfigMap of your own, mounted with subPath at \`/etc/clickhouse-server/conf.d/clickhouse-ttl.xml\`" "plain: other charts"
hasnt "$f" '```yaml' "plain: no YAML"
has "$f" "Or give the volume more room: this pod mounts several volumes (data-dv-plain-0, logs-dv-plain-0); \`kubectl get pvc -n dv-plain\` shows them. Grow the one mounted at /var/lib/clickhouse/ with \`kubectl patch pvc -n dv-plain <pvc> -p '{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"300Gi\"}}}}'\` if its StorageClass allows expansion. The patch can't be undone (a volume never shrinks)." "plain, two PVCs: the several-volumes line"
has "$f" "See what takes the space (read-only, inside the pod)" "plain: the generic check 2 text"
has "$f" "or \`ALTER TABLE <table> UNFREEZE WITH NAME '<name>'\` for ALTER TABLE ... FREEZE; irreversible: that backup is gone)" "plain: deleting a local backup says it is irreversible"
# a plain pod may have no StatefulSet: nothing recreates a bare pod
has "$f" "restart it yourself: \`kubectl delete pod -n dv-plain dv-plain-0\`, but first check that \`kubectl describe pod -n dv-plain dv-plain-0\` names a StatefulSet under Controlled By: it then recreates the pod with the same name and the same PersistentVolumeClaims (about a minute of downtime). A pod that nothing controls is not recreated." "plain: the delete line only for a pod of a StatefulSet"
hasnt "$f" "its StatefulSet recreates it" "plain: no StatefulSet taken for granted"
flavor plain-clickstack plain clickstack
f=$W/f.plain-clickstack.md
has "$f" "This looks like ClickStack chart 1.x (or hdx-oss-v2), which has no value for extra config files." "plain+clickstack: ClickStack 1.x"
has "$f" "Until then, save this as \`clickhouse-ttl.xml\` and add it with a Kustomize post-renderer (see the Kubernetes page linked above):" "plain+clickstack: the post-renderer"
hasnt "$f" "- trigger.dev chart" "plain+clickstack: not the chart list"
flavor plain-nopvc plain-nopvc other
f=$W/f.plain-nopvc.md
has "$f" "- This pod mounts no PersistentVolumeClaim: ClickHouse data is on the node's disk" "plain-nopvc: the no-PVC heads-up"
hasnt "$f" "Or give the volume more room" "plain-nopvc: no volume line in check 3"
# without a PVC every new pod starts empty: Fix B is not safe, and no delete line
has "$f" "Unless it is a hostPath volume, the data is lost whenever the pod is replaced: a helm upgrade that changes it, \`kubectl delete pod\`, a node drain." "plain-nopvc: the heads-up says any new pod loses the data"
has "$f" "**Fix B: stop it coming back.** Not safe on this pod yet: it mounts no PersistentVolumeClaim, so the restart this fix needs deletes all ClickHouse data (unless the data is on a hostPath volume). Turn persistence on first (Heads-up for Kubernetes, above)." "plain-nopvc: Fix B says it is not safe"
has "$f" "Once the pod keeps its data on a PersistentVolumeClaim, run your usual \`helm upgrade\`" "plain-nopvc: the helm upgrade only after persistence is on"
has "$f" "Until then, replacing this pod (a helm upgrade that changes it, \`kubectl delete pod\`, a node drain) deletes its data." "plain-nopvc: the restart deletes the data"
hasnt "$f" "Safe;" "plain-nopvc: nothing called safe"
hasnt "$f" "same volume" "plain-nopvc: no same volume"
hasnt "$f" "kubectl delete pod -n sentry" "plain-nopvc: no delete pod command"
hasnt "$f" "restart it yourself" "plain-nopvc: no restart it yourself"
for x in "official|kubectl get pods -n lf -l clickhouse.com/cluster=langfuse-clickhouse,clickhouse.com/role=clickhouse-server|lf" \
        "altinity|kubectl get pods -n signoz -l clickhouse.altinity.com/chi=signoz-clickhouse|signoz" \
        "bitnami8|kubectl get pods -n langfuse -l app.kubernetes.io/name=clickhouse,app.kubernetes.io/component=clickhouse|langfuse" \
        "plain|kubectl get pods -n dv-plain\`|dv-plain"; do
    fl=${x%%|*}; r=${x#*|}; sel=${r%|*}; xns=${r#*|}
    flavor "$fl-replicated" "$fl" other 1
    has "$W/f.$fl-replicated.md" "- Replicated tables: this installation may run several ClickHouse pods, and each has its own disk and system logs. List them with \`" "$fl, replicated=1: the heads-up"
    has "$W/f.$fl-replicated.md" "$sel" "$fl, replicated=1: the selector line"
    has "$W/f.$fl-replicated.md" "run diskvet with \`--k8s $xns/<pod>\` on each" "$fl, replicated=1: one run per pod"
done
# operator 0.0.7 pods have no clickhouse.com/cluster label (seen on kind): the role label still lists the servers
flavor official-nogroup-replicated "$W/target.nogroup" other 1
has "$W/f.official-nogroup-replicated.md" "List them with \`kubectl get pods -n lf -l clickhouse.com/role=clickhouse-server\` and run diskvet" "official, no group, replicated=1: the role selector"

echo "== the printed client commands work: pasted into sh and busybox sh, through the fake kubectl"
# "How to run the fixes" of the Bitnami and plain reports, run as a person would
# (KFAKE_PRINTED=1: with -it), with the pod's sh the same shell: they must reach
# the fake clickhouse-client with exactly the login of the pod's env.
# shellcheck disable=SC2016
client_cmd() { sed -n 's/^SQL goes into clickhouse-client inside the pod, as a user that may change tables (a read-only user can.t): `\([^`]*\)`\. .*/\1/p' "$1"; }
shells="sh"
if command -v busybox >/dev/null 2>&1; then
    mkdir "$W/bbsh" && ln -s "$(command -v busybox)" "$W/bbsh/sh" && shells="sh busybox"
fi
wrapper() {  # SHELL FIXTURE CMD "POD ENV" WANT DESC: CMD, pasted into SHELL, gives the client the argv WANT
    _s=$1 _fx=$2 _c=$3 _e=$4 _w=$5 _d=$6
    fresh
    if [ "$_s" = busybox ]; then _pp=$W/bbsh:$W/bin:$host_path; set -- busybox sh; else _pp=""; set -- sh; fi
    printf "SELECT getSetting('readonly')\n" | env KFAKE="$_fx" KFAKE_PRINTED=1 KFAKE_ENV="$_e" KFAKE_PODPATH="$_pp" "$@" -c "$_c" >"$W/w.out" 2>"$W/w.err"; _rc=$?
    if [ "$_rc" = 0 ] && [ "$(cat "$W/w.out")" = 0 ] && [ -s "$CLOG" ] && [ "$(cat "$CLOG")" = "$_w" ] && grep -qF '[exec] [-it] [-n] ' "$KLOG"; then
        ok "$_s: $_d"
    else
        fail "$_s: $_d: exit $_rc, client argv '$(cat "$CLOG")', want '$_w': $(cat "$W/w.err")"
    fi
}
bn8=$(client_cmd "$W/f.bitnami8.md")
bn9=$(client_cmd "$W/f.bitnami9.md")
pl=$(client_cmd "$W/f.plain.md")
if [ "$bn8" = "$bitnami_client" ] && [ -n "$bn9" ] && [ -n "$pl" ]; then ok "the client commands are in the Bitnami and plain reports"; else fail "client commands: '$bn8' '$bn9' '$pl'"; fi
for sh_ in $shells; do
    wrapper "$sh_" many-bitnami "$bn8" "CLICKHOUSE_ADMIN_USER=admin CLICKHOUSE_ADMIN_PASSWORD=s3cret-pw" "[--user] [admin] [--password] [s3cret-pw] " "Bitnami: CLICKHOUSE_ADMIN_USER and CLICKHOUSE_ADMIN_PASSWORD"
    hasnt "$KLOG" "s3cret-pw" "$sh_: Bitnami: the password is not on the kubectl command line"
    wrapper "$sh_" one-bitnami9 "$bn9" "CLICKHOUSE_ADMIN_USER=admin CLICKHOUSE_ADMIN_PASSWORD_FILE=tests/fixtures/k8s/bitnami-admin-password" "[--user] [admin] [--password] [$fpw] " "Bitnami 9: the password from CLICKHOUSE_ADMIN_PASSWORD_FILE"
    wrapper "$sh_" plain-sidecar-first "$pl" "CLICKHOUSE_USER=u CLICKHOUSE_PASSWORD=p" "[--user] [u] [--password] [p] " "plain: CLICKHOUSE_USER and CLICKHOUSE_PASSWORD"
    wrapper "$sh_" plain-sidecar-first "$pl" "CLICKHOUSE_USER=u" "[--user] [u] " "plain: only CLICKHOUSE_USER"
    wrapper "$sh_" plain-sidecar-first "$pl" "CLICKHOUSE_PASSWORD=p" "[--password] [p] " "plain: only CLICKHOUSE_PASSWORD"
    wrapper "$sh_" plain-sidecar-first "$pl" "" "" "plain: no login in the env, no --user and no --password (the default user)"
    # a password with spaces, quotes and a $ stays one argument (the pod's sh -c
    # alone: the fake's env words can't hold a space)
    if [ "$sh_" = busybox ]; then set -- busybox sh; else set -- sh; fi
    # shellcheck disable=SC2016
    for c in "$pl" "$bn8"; do
        b=$(printf '%s' "$c" | sed "s/^.* -- sh -c '\\(.*\\)'\$/\\1/")
        : >"$CLOG"
        printf "SELECT getSetting('readonly')\n" | env -i PATH="$W/bin:$host_path" CLOG="$CLOG" CLICKHOUSE_USER='my user' CLICKHOUSE_PASSWORD='p "w" $x' \
            CLICKHOUSE_ADMIN_USER='my user' CLICKHOUSE_ADMIN_PASSWORD='p "w" $x' "$@" -c "$b" >/dev/null 2>&1
        if [ "$(cat "$CLOG")" = '[--user] [my user] [--password] [p "w" $x] ' ]; then ok "$sh_: $(printf '%s' "$c" | cut -c1-40)...: a user and password with spaces, quotes and \$ stay one argument each"; else fail "$sh_: spaces in the login: '$(cat "$CLOG")' from $b"; fi
    done
done

echo "== the fake kubectl's docker mode (used by tests/k8s_shim.sh)"
DLOG=$W/dlog; export DLOG
cat >"$W/bin/docker" <<'EOF'
#!/bin/sh
# stub docker: docker exec -i [-e K=V]... CONTAINER CMD... runs CMD here with K=V
for a in "$@"; do printf '[%s] ' "$a" | tr '\n' '~'; done >>"$DLOG"; printf '\n' >>"$DLOG"
[ "${1:-} ${2:-}" = "exec -i" ] || exit 99
shift 2
while [ "${1:-}" = -e ]; do export "$2"; shift 2; done
[ "${1:-}" = "$KFAKE_DOCKER" ] || exit 98
shift
exec "$@"
EOF
chmod +x "$W/bin/docker"
: >"$DLOG"
kenv="CLICKHOUSE_USER=u CLICKHOUSE_PASSWORD=p"
dv "KFAKE=one-official KFAKE_EXEC=docker KFAKE_DOCKER=chd-test" report --k8s auto >"$W/r.md" 2>"$W/r.err"; rc_is $? 0 "docker mode: exit 0"
kenv=""
statuses "$W/r.md" "CRITICAL WARN WARN WARN OK OK WARN" "docker mode: the same statuses"
if [ -s "$DLOG" ] && awk 'index($0, "[exec] [-i] [-e] [CLICKHOUSE_USER=u] [-e] [CLICKHOUSE_PASSWORD=p] [chd-test] [sh] [-c] ") != 1 { bad = 1 } END { exit bad }' "$DLOG"; then
    ok "docker mode: docker exec -i -e ... CONTAINER sh -c ... ($(grep -c . "$DLOG") calls)"
else
    fail "docker mode: $(sed -n '1p' "$DLOG" | cut -c1-160)"
fi
login "[--user] [u] [--password] [p] [--readonly=2] " "docker mode: the pod's env reaches clickhouse-client"
rm -f "$W/bin/docker"

echo "== every kubectl call of this test run"
fresh
awk '{ v = $1; if (v == "[--context]") v = $3; print v }' "$W/klog.all" | sort -u >"$W/verbs"
if grep -qvxE '\[(config|get|exec)\]' "$W/verbs"; then fail "verbs: $(tr '\n' ' ' <"$W/verbs")"; else ok "verbs: only $(tr '\n' ' ' <"$W/verbs")($(grep -c . "$W/klog.all") calls)"; fi
if awk '{ v = 1; if ($1 == "[--context]") v = 3 } $v == "[get]" && $(v + 1) != "[pod]" && $(v + 1) != "[pods]" { bad = 1 } END { exit bad }' "$W/klog.all"; then
    ok "get: only pods"
else
    fail "get: something other than pods"
fi
hasnt "$W/klog.all" "s3cret-pw" "no password in any kubectl command line"
hasnt "$W/klog.all" "$fpw" "no password file content in any kubectl command line"
hasnt "$W/klog.all" "$salt" "no salt in any kubectl command line"
hasnt "$W/klog.all" "[--password]" "no --password in any kubectl command line"

echo
echo "k8s_offline: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
