#!/bin/sh
# shellcheck disable=SC2016
# (SC2016: in single quotes, backticks are the Markdown of the reports, and $ the
# variables of the pod, never of this script.)
# diskvet --k8s on a real Kubernetes cluster: kind, in the "kubernetes" job of
# .github/workflows/ci.yml only. The job creates the cluster from
# tests/k8s/kind.yaml (with the API server's audit log on) and runs this
# script. It installs charts into the current kubectl context, so it stops
# unless DISKVET_KIND=1, the context is kind-diskvet and the API server is local.
#
# Phase 1, ClickHouse installed three ways, each with test-only seed data:
#   (a) dv-plain  tests/k8s/plain.yaml: a StatefulSet of the official image as
#                 uid 101, the login from a Secret (CLICKHOUSE_USER /
#                 CLICKHOUSE_PASSWORD), a busybox sidecar first, a 2Gi PVC;
#   (b) dv-op     cert-manager, the ClickHouse operator (chart 0.0.7), and the
#                 ClickHouseCluster, KeeperCluster and Secret of the Langfuse
#                 chart 2.1.2 (helm template, tests/k8s/langfuse-values.yaml);
#   (c) dv-bn8    the Bitnami ClickHouse chart 8.0.5 (Langfuse chart 1.x uses
#                 it) with the bitnamilegacy image, 2 replicas
#                 (tests/k8s/bn8-values.yaml).
# Checks:
#   - --k8s auto over all namespaces refuses and names exactly the 4 server
#     pods (no Keeper, operator, cert-manager or version-probe pod); with
#     --print-payload stdout is one ch_unreachable line;
#   - a report per install: exit 0, all 7 checks run, the login of the pod's
#     env in the header (clickhouse; default; Bitnami's admin user, default),
#     the Fix B of its chart; in query_log only SELECTs with readonly=2 and
#     log_comment=diskvet, as that user;
#   - payloads: names hashed inside the pod; no namespace, pod, node, context,
#     PVC, resource or ServiceAccount name and no salt;
#   - ServiceAccount tokens: the README's Role (a named pod, and auto with its
#     fallback note), get only, and no pods/exec (exit 3 with the hint);
#   - no password and no salt in the audit log, query_log or text_log; the
#     audit log has diskvet's exec command lines; the pods' specs unchanged;
#   - the printed fixes, run as printed: Fix A through the printed
#     clickhouse-client command, with the force_drop_table flag line (uid 101
#     in a and b, 1001 in c); on the operator pod the server log files are on
#     the data volume (df) and the printed rm line deletes only rotated ones;
#     Fix B through the chart (b: helm template -f fixb.yaml | kubectl apply;
#     c: helm upgrade --reuse-values -f fixb.yaml), then a TTL on every log it
#     lists, their <log>_0 copies in Fix C, and none left after Fix C;
#   - the real "kubectl get pods -o custom-columns" output goes to
#     tests/out/pods.* (the offline fixtures are recorded from it).
# Phase 2, only when phase 1 passed, after deleting its namespaces:
#   (d) dv-bn9    the Bitnami chart 9.4.4 (tests/k8s/bn9-values.yaml): the login
#                 from CLICKHOUSE_ADMIN_PASSWORD_FILE, and a 00- file in
#                 configdFiles loading before the chart's 08-sampling.xml (a log
#                 the chart turns off stays off; a zz- file turns it back on);
#   (e) dv-alt    the Altinity operator (chart 0.27.4) with a minimal
#                 ClickHouseInstallation (tests/k8s/altinity.yaml): the
#                 passwordless default user, a sidecar listed first, Fix B
#                 through spec.configuration.files, then Fix C.
# Results: tests/out/k8s-*; diagnostics: tests/out/k8s-diag.txt.
set -u
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV
cd "$(dirname "$0")/.." || exit 2

CTX=kind-diskvet
NODE=diskvet-control-plane
if [ "${DISKVET_KIND:-}" != 1 ]; then
    echo "k8s: this test installs charts into the current kubectl context, so it runs only in the kubernetes CI job (DISKVET_KIND=1); stopping"
    exit 2
fi
x=$(kubectl config current-context 2>/dev/null)
if [ "$x" != "$CTX" ]; then
    echo "k8s: the kubectl context is '$x', not $CTX (the kind cluster of the CI job); stopping"
    exit 2
fi
SERVER=$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)
case $SERVER in
    https://127.0.0.1:*) ;;
    *) echo "k8s: the API server is '$SERVER', not a local kind cluster; stopping"; exit 2 ;;
esac
if [ "$(docker inspect -f '{{.State.Running}}' "$NODE" 2>/dev/null)" != true ]; then
    echo "k8s: no running kind node container $NODE; stopping"
    exit 2
fi

OUT=tests/out
mkdir -p "$OUT" || exit 2
F=$OUT/k8s
W=$(mktemp -d 2>/dev/null) || W=""
if [ -z "$W" ] || [ ! -d "$W" ]; then
    W=${TMPDIR:-/tmp}/diskvet-k8s.$$
    mkdir -p "$W" || exit 2
fi
trap 'rm -rf "$W"' EXIT
T0=$(date +%s)
tab=$(printf '\t')
SALT=$(sed -n 's/^SALT=//p' tests/fixtures/test.env)
rnd() { od -An -tx1 -N12 /dev/urandom | tr -d ' \n'; }
PW_A=pa$(rnd)
PW_B=pb$(rnd)
PW_C=pc$(rnd)
PW_D=pd$(rnd)
K8S_COLS=$(sed -n "s/^K8S_COLS='\(.*\)'\$/\1/p" diskvet.sh)
CERT_MANAGER=https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml
LANGFUSE_REPO=https://langfuse.github.io/langfuse-k8s
IMAGES="docker.io/clickhouse/clickhouse-server:25.12 docker.io/clickhouse/clickhouse-server:26.4 docker.io/clickhouse/clickhouse-keeper:26.4 docker.io/bitnamilegacy/clickhouse:25.2.1-debian-12-r0 docker.io/bitnamilegacy/clickhouse:25.7.5-debian-12-r0 docker.io/library/busybox:1.37"

# the installs: namespace, pod, container, and the pod's own login for
# clickhouse-client (variable names only: the values never leave the pod)
A_NS=dv-plain A_POD=dv-plain-0 A_CTR=clickhouse A_UID=101 A_UP=0
B_NS=dv-op B_POD="" B_CTR=clickhouse-server B_UID=101 B_UP=0
C_NS=dv-bn8 C_POD=bn8-clickhouse-shard0-0 C_CTR=clickhouse C_UID=1001 C_UP=0
# phase 2
D_NS=dv-bn9 D_POD=bn9-clickhouse-shard0-0 D_CTR=clickhouse D_UID=1001 D_UP=0
E_NS=dv-alt E_POD=chi-dv-alt-c1-0-0-0 E_CTR=clickhouse E_UID=101 E_UP=0
A_LOGIN='exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"'
B_LOGIN='exec clickhouse-client "$@"'
C_LOGIN='exec clickhouse-client --user "$CLICKHOUSE_ADMIN_USER" --password "$CLICKHOUSE_ADMIN_PASSWORD" "$@"'
# Bitnami chart 9.x: the password only in a file
D_LOGIN='exec clickhouse-client --user "$CLICKHOUSE_ADMIN_USER" --password "$(cat "$CLICKHOUSE_ADMIN_PASSWORD_FILE")" "$@"'
# Altinity: the default user without a password, from inside the pod
E_LOGIN='exec clickhouse-client "$@"'

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
note() { printf '  note  %s\n' "$*"; }
has()  { if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then fail "$3 (found: $2)"; else ok "$3"; fi; }
section() { printf '== %s (%s s)\n' "$*" "$(( $(date +%s) - T0 ))"; }
oneline() { tr '\n\t' '  ' | cut -c1-300; }
summary() { sed -n '/^| # | Check | Status |$/,/^$/p' "$1"; }
status_of() { sed -n "s/^| $2 | [^|]* | \([A-Z_]*\) |\$/\1/p" "$1"; }

# tgt T: _n _p _c _l _u = namespace, pod, container, login, uid of install T (A to E)
tgt() {
    case $1 in
        A) _n=$A_NS _p=$A_POD _c=$A_CTR _l=$A_LOGIN _u=$A_UID ;;
        B) _n=$B_NS _p=$B_POD _c=$B_CTR _l=$B_LOGIN _u=$B_UID ;;
        C) _n=$C_NS _p=$C_POD _c=$C_CTR _l=$C_LOGIN _u=$C_UID ;;
        D) _n=$D_NS _p=$D_POD _c=$D_CTR _l=$D_LOGIN _u=$D_UID ;;
        E) _n=$E_NS _p=$E_POD _c=$E_CTR _l=$E_LOGIN _u=$E_UID ;;
    esac
}
up() { case $1 in A) [ "$A_UP" = 1 ] ;; B) [ "$B_UP" = 1 ] ;; C) [ "$C_UP" = 1 ] ;; D) [ "$D_UP" = 1 ] ;; E) [ "$E_UP" = 1 ] ;; *) return 1 ;; esac; }
# kxp T CMD...: a command in the ClickHouse container of install T (test only; no stdin)
kxp() { tgt "$1"; shift; kubectl exec -n "$_n" "$_p" -c "$_c" -- "$@" </dev/null; }
# chx T [ARGS]: clickhouse-client in the pod of T with the pod's own login; the
# SQL comes on stdin, so it is not in the exec URL (and not in the audit log)
chx() { tgt "$1"; shift; kubectl exec -i -n "$_n" "$_p" -c "$_c" -- sh -c "$_l" sh "$@"; }
chq() { printf '%s\n' "$2" | chx "$1" 2>&1; }
# retry N CMD...: up to N tries, 10 s apart
retry() {
    _rn=$1; shift; _ri=1
    until "$@"; do
        [ "$_ri" -lt "$_rn" ] || return 1
        _ri=$((_ri + 1)); sleep 10
    done
}
# wait_pods NS SELECTOR N SECONDS: until N pods of SELECTOR are Ready
wait_pods() {
    _end=$(( $(date +%s) + $4 ))
    while :; do
        _r=$(kubectl get pods -n "$1" -l "$2" -o 'jsonpath={range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c '^True$')
        [ "$_r" -ge "$3" ] && return 0
        [ "$(date +%s)" -lt "$_end" ] || return 1
        sleep 5
    done
}
# wait_ch T SECONDS: until ClickHouse in the pod of T answers
wait_ch() {
    _end=$(( $(date +%s) + $2 ))
    while [ "$(chq "$1" 'SELECT 1')" != 1 ]; do
        [ "$(date +%s)" -lt "$_end" ] || return 1
        sleep 3
    done
}
uid_of() { kubectl get pod "$2" -n "$1" -o 'jsonpath={.metadata.uid}' 2>/dev/null; }
# wait_new NS POD OLD_UID SECONDS: until POD is a new pod (another UID) and Ready
wait_new() {
    _end=$(( $(date +%s) + $4 ))
    while :; do
        _x=$(uid_of "$1" "$2")
        if [ -n "$_x" ] && [ "$_x" != "$3" ] \
            && kubectl wait --for=condition=Ready "pod/$2" -n "$1" --timeout=10s >/dev/null 2>&1; then
            return 0
        fi
        [ "$(date +%s)" -lt "$_end" ] || return 1
        sleep 5
    done
}
pvcs_of() { kubectl get pod "$2" -n "$1" -o 'jsonpath={.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null; }

# ---------------------------------------------------------------- reading the reports
# the clickhouse-client command of "How to run the fixes"
client_of() { sed -n 's/^SQL goes into clickhouse-client inside the pod, as a user that may change tables (a read-only user can.t): `\([^`]*\)`\..*/\1/p' "$1"; }
# fix_steps FILE SECTION MARK: the lines of the ```sh and ```sql blocks of one
# fix (from the line that starts with MARK to the next bold line), in order,
# as "sh<TAB>line" or "sql<TAB>line"
fix_steps() {
    awk -v n="$2" -v mark="$3" '
        /^## [0-9]\. / { sec = substr($2, 1, 1) + 0; on = 0; next }
        sec != n { next }
        index($0, mark) == 1 { on = 1; next }
        on && lang == "" && /^\*\*/ { on = 0 }
        !on { next }
        /^```(sh|sql)$/ { lang = substr($0, 4); next }
        /^```/ { lang = ""; next }
        lang != "" && !/^--/ && NF > 0 { print lang "\t" $0 }
    ' "$1"
}
# the ```yaml block of Fix B in check 1
yaml_of() {
    awk '/^## [0-9]\. / { sec = substr($2, 1, 1) + 0 }
        sec == 1 && /^\*\*Fix B/ { b = 1 }
        b && /^```yaml$/ { y = 1; next }
        y && /^```$/ { exit }
        y' "$1"
}
# kubectl lines of one report section that contain TEXT
section_cmd() { awk -v n="$2" '/^## [0-9]\. / { sec = substr($2, 1, 1) + 0 } sec == n && /^kubectl /' "$1" | grep -F -m 1 -- "$3"; }

# run_fix T FILE SECTION MARK: runs one fix as printed: the shell lines as they
# are, each SQL line through the report's clickhouse-client command (the -it
# of that command gets no terminal here, so kubectl says so and goes on).
# After a force_drop_table line: the owner of the flag must be the pod's uid.
run_fix() {
    _t=$1 _f=$2
    _cl=$(client_of "$_f")
    if [ -z "$_cl" ]; then fail "$_t: no clickhouse-client command in $_f"; return 1; fi
    fix_steps "$_f" "$3" "$4" >"$W/steps"
    if [ ! -s "$W/steps" ]; then fail "$_t: no commands under '$4' in $_f"; return 1; fi
    _bad=0
    while IFS=$tab read -r _lang _line; do
        printf '$ %s\n' "$_line" >>"$_f.fix.txt"
        if [ "$_lang" = sh ]; then
            sh -c "$_line" </dev/null >>"$_f.fix.txt" 2>&1 || { _bad=1; echo "(exit $?)" >>"$_f.fix.txt"; }
            case $_line in
                *'touch '*force_drop_table*)
                    _fl=$(printf '%s\n' "$_line" | sed -n 's/.*touch \([^ ]*force_drop_table\) .*/\1/p')
                    tgt "$_t"
                    _o=$(kxp "$_t" stat -c %u "$_fl" 2>&1)
                    if [ "$_o" = "$_u" ]; then ok "$_t: the printed flag line creates $_fl as uid $_u, the pod's user"; else fail "$_t: owner of $_fl: '$_o', want $_u"; fi ;;
            esac
        else
            printf '%s\n' "$_line" | sh -c "$_cl" >>"$_f.fix.txt" 2>&1 || { _bad=1; echo "(exit $?)" >>"$_f.fix.txt"; }
        fi
    done <"$W/steps"
    return $_bad
}

# check_report NAME T USER: exit status in $rc; all 7 checks ran, the pod and
# the login in the header, no Docker text, no context name (not typed)
check_report() {
    _nm=$1; tgt "$2"
    if [ "$rc" = 0 ]; then ok "$_nm: exit 0"; else fail "$_nm: exit $rc: $(tail -3 "$F-$_nm.err" | oneline)"; return 1; fi
    if [ "$(summary "$F-$_nm.md" | grep -c '^| [1-7] | ')" = 7 ] && ! summary "$F-$_nm.md" | grep -q ' NOT_RUN |$'; then
        ok "$_nm: all 7 checks ran ($(summary "$F-$_nm.md" | sed -n 's/^| [1-7] | [^|]* | \([A-Z_]*\) |$/\1/p' | tr '\n' ' '))"
    else
        fail "$_nm: $(summary "$F-$_nm.md" | oneline) $(grep -m 2 'Could not run' "$F-$_nm.md" | oneline)"
    fi
    if grep -q "· pod $_n/$_p · user $3\$" "$F-$_nm.md"; then ok "$_nm: header: pod $_n/$_p, ran as $3"; else fail "$_nm: header $(grep -m 1 '^diskvet ' "$F-$_nm.md")"; fi
    if grep -Eiq 'docker|daemon\.json|systemctl|sudo' "$F-$_nm.md"; then fail "$_nm: Docker or systemd text: $(grep -Ei -m 2 'docker|daemon\.json|systemctl|sudo' "$F-$_nm.md" | oneline)"; else ok "$_nm: no Docker or systemd text"; fi
    hasnt "$F-$_nm.md" "$CTX" "$_nm: the context (not typed) is not in the report"
}
# report NAME T USER ARGS...: a report of install T with --save-raw, checked
report() {
    _rpn=$1 _rpt=$2 _rpu=$3; shift 3
    sh diskvet.sh report --save-raw "$F-$_rpn.raw" "$@" >"$F-$_rpn.md" 2>"$F-$_rpn.err" </dev/null
    rc=$?
    check_report "$_rpn" "$_rpt" "$_rpu"
}
# dv ARGS...: diskvet, with the kubeconfig DV_KUBECONFIG when it is set
DV_KUBECONFIG=""
dv() { if [ -n "$DV_KUBECONFIG" ]; then KUBECONFIG=$DV_KUBECONFIG sh diskvet.sh "$@"; else sh diskvet.sh "$@"; fi; }
# payload NAME T ARGS...: --print-payload, checked with every name forbidden
payload() {
    _pn=$1 _pt=$2; shift 2
    dv --print-payload --env tests/fixtures/test.env "$@" >"$F-$_pn.json" 2>"$F-$_pn.err" </dev/null
    rc=$?
    if [ "$rc" = 0 ]; then ok "$_pn: exit 0"; else fail "$_pn: exit $rc: $(tail -3 "$F-$_pn.err" | oneline)"; fi
    # shellcheck disable=SC2086
    if sh tests/check_payload.sh "$F-$_pn.json" $FORBID "$SALT" >"$W/cp" 2>&1; then
        ok "$_pn: check_payload.sh passes with namespaces, pods, node, context, PVCs, resources, ServiceAccounts and the salt forbidden"
    else
        fail "$_pn: $(oneline <"$W/cp")"
    fi
    if grep -q '"db": "db_[0-9a-f]\{16\}", "table": "t_[0-9a-f]\{16\}"' "$F-$_pn.json"; then ok "$_pn: own names hashed inside the pod ($_pt)"; else fail "$_pn: no hashed table in the payload: $(grep -m 1 -i 'hash' "$F-$_pn.err" | oneline)"; fi
}

diag() {
    {
        echo "== kubectl get pods -A -o wide"; kubectl get pods -A -o wide
        echo "== kubectl get pvc -A"; kubectl get pvc -A
        echo "== events"; kubectl get events -A --sort-by=.lastTimestamp | tail -120
        for ns in "$A_NS" "$B_NS" "$C_NS" "$D_NS" "$E_NS" clickhouse-operator-system cert-manager; do
            echo "== describe pods -n $ns"; kubectl describe pods -n "$ns" | tail -150
        done
        echo "== ClickHouseCluster / KeeperCluster"; kubectl get clickhouseclusters,keeperclusters -n "$B_NS" -o yaml | head -300
        for d in $(kubectl get deployments -n clickhouse-operator-system -o name); do
            echo "== log $d"; kubectl logs -n clickhouse-operator-system "$d" --tail=150 --all-containers
        done
        for t in A B C D E; do
            tgt "$t"
            [ -n "$_p" ] || continue
            echo "== log $_n/$_p -c $_c"; kubectl logs -n "$_n" "$_p" -c "$_c" --tail=80
            echo "== previous log $_n/$_p -c $_c"; kubectl logs -n "$_n" "$_p" -c "$_c" --previous --tail=60
        done
    } >"$F-diag.txt" 2>&1
}

# ---------------------------------------------------------------- 1. setup
section "setup: dv-plain, the ClickHouse operator with the Langfuse chart's resources, Bitnami"
# kubelet pulls one image at a time: pull the big ones in parallel first
for img in $IMAGES; do
    timeout 900 docker exec "$NODE" crictl pull "$img" >/dev/null 2>&1 &
done
setup_a() {
    kubectl create namespace "$A_NS" &&
    printf 'CLICKHOUSE_USER=clickhouse\nCLICKHOUSE_PASSWORD=%s\n' "$PW_A" >"$W/a.env" &&
    kubectl create secret generic dv-plain-login -n "$A_NS" --from-env-file="$W/a.env" &&
    kubectl create configmap dv-plain-test-config -n "$A_NS" --from-file=zz-diskvet-test.xml=tests/fixtures/ch-test.xml &&
    kubectl apply -f tests/k8s/plain.yaml
}
setup_c() {
    kubectl create namespace "$C_NS" &&
    kubectl create secret generic bn8-test-config -n "$C_NS" --from-file=zz-diskvet-test.xml=tests/fixtures/ch-test.xml &&
    mkdir -p "$W/bn8" &&
    retry 3 timeout 300 helm pull oci://registry-1.docker.io/bitnamicharts/clickhouse --version 8.0.5 -d "$W/bn8" &&
    printf 'auth:\n  password: %s\n' "$PW_C" >"$W/c-auth.yaml" &&
    timeout 300 helm install bn8 "$W"/bn8/clickhouse-*.tgz -n "$C_NS" -f tests/k8s/bn8-values.yaml -f "$W/c-auth.yaml"
}
render_b() {
    helm template lf "$W"/langfuse/langfuse-*.tgz -n "$B_NS" -f tests/k8s/langfuse-values.yaml -f "$W/b-auth.yaml" "$@" \
        --show-only templates/clickhouse/cluster.yaml --show-only templates/clickhouse/keeper.yaml --show-only templates/clickhouse/secret.yaml
}
# cert-manager answers: its webhook accepts an Issuer (server-side dry run, nothing is created)
cm_ready() {
    printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata:\n  name: dv-check\n  namespace: default\nspec:\n  selfSigned: {}\n' \
        | kubectl create --dry-run=server -f - >/dev/null 2>&1
}
op_install() {
    timeout 300 helm install clickhouse-operator "$W"/op/clickhouse-operator-helm-*.tgz -n clickhouse-operator-system --create-namespace && return 0
    helm uninstall clickhouse-operator -n clickhouse-operator-system
    sleep 20
    timeout 300 helm install clickhouse-operator "$W"/op/clickhouse-operator-helm-*.tgz -n clickhouse-operator-system --create-namespace
}
setup_b() {
    retry 3 timeout 300 kubectl apply -f "$CERT_MANAGER" &&
    kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s &&
    retry 30 cm_ready &&
    mkdir -p "$W/op" "$W/langfuse" &&
    { retry 3 timeout 300 helm pull oci://ghcr.io/clickhouse/clickhouse-operator-helm --version 0.0.7 -d "$W/op" ||
      curl -fsSL -o "$W/op/clickhouse-operator-helm-0.0.7.tgz" https://github.com/ClickHouse/clickhouse-operator/releases/download/v0.0.7/clickhouse-operator-helm-0.0.7.tgz; } &&
    op_install &&
    kubectl wait --for=condition=Available deployment --all -n clickhouse-operator-system --timeout=300s &&
    kubectl create namespace "$B_NS" &&
    retry 3 timeout 300 helm pull langfuse --repo "$LANGFUSE_REPO" --version 2.1.2 -d "$W/langfuse" &&
    printf 'clickhouse:\n  auth:\n    password: %s\n' "$PW_B" >"$W/b-auth.yaml" &&
    render_b >"$W/b.yaml" &&
    grep '^kind: ' "$W/b.yaml" &&
    retry 12 kubectl apply -n "$B_NS" -f "$W/b.yaml"
}
( setup_a >"$F-setup-a.txt" 2>&1; echo $? >"$W/rc-a" ) &
( setup_c >"$F-setup-c.txt" 2>&1; echo $? >"$W/rc-c" ) &
setup_b >"$F-setup-b.txt" 2>&1
echo $? >"$W/rc-b"
wait
for t in a b c; do
    if [ "$(cat "$W/rc-$t" 2>/dev/null)" = 0 ]; then ok "setup ($t)"; else fail "setup ($t): $(tail -6 "$F-setup-$t.txt" | oneline)"; fi
done

section "waiting for the ClickHouse pods"
if [ "$(cat "$W/rc-a")" = 0 ] && wait_pods "$A_NS" app=dv-plain 1 600 && wait_ch A 120; then A_UP=1; ok "(a) $A_NS/$A_POD is ready"; else fail "(a) $A_NS/$A_POD is not ready"; fi
if [ "$(cat "$W/rc-b")" = 0 ] && wait_pods "$B_NS" clickhouse.com/role=clickhouse-server 1 900; then
    B_POD=$(kubectl get pods -n "$B_NS" -l clickhouse.com/role=clickhouse-server -o 'jsonpath={.items[0].metadata.name}')
    if wait_ch B 180; then B_UP=1; ok "(b) $B_NS/$B_POD is ready"; else fail "(b) $B_NS/$B_POD does not answer"; fi
else
    fail "(b) no ready ClickHouse pod in $B_NS"
fi
if [ "$(cat "$W/rc-c")" = 0 ] && wait_pods "$C_NS" app.kubernetes.io/instance=bn8,app.kubernetes.io/name=clickhouse 2 600 && wait_ch C 120; then C_UP=1; ok "(c) $C_NS/$C_POD and shard0-1 are ready"; else fail "(c) the Bitnami pods are not ready"; fi
[ "$A_UP$B_UP$C_UP" = 111 ] || diag
A_PVCS=$(pvcs_of "$A_NS" "$A_POD")
B_PVCS=$(pvcs_of "$B_NS" "$B_POD")
C_PVCS=$(pvcs_of "$C_NS" "$C_POD")
B_GROUP=$(kubectl get pod "$B_POD" -n "$B_NS" -o 'jsonpath={.metadata.labels.clickhouse\.com/cluster}' 2>/dev/null)
note "pods: $A_NS/$A_POD ($A_PVCS), $B_NS/$B_POD ($B_PVCS, clickhouse.com/cluster=$B_GROUP), $C_NS/$C_POD ($C_PVCS)"
# every name diskvet must keep out of a payload
FORBID="$A_NS $B_NS $C_NS $A_POD ${B_POD:-dv-no-pod} bn8-clickhouse bn8-clickhouse-shard0-1 $NODE $CTX $A_PVCS $B_PVCS $C_PVCS lf-langfuse dv-sa-full dv-sa-get dv-sa-noexec dv-sa-create customer_acme payments_eu"

# ---------------------------------------------------------------- 2. seed and record
section "test-only seed data"
seed_small() {
    chx "$1" --multiquery <<'EOF'
CREATE TABLE IF NOT EXISTS default.traces (id String, timestamp DateTime64(3), project_id String) ENGINE = MergeTree PARTITION BY toYYYYMM(timestamp) ORDER BY (project_id, id);
CREATE TABLE IF NOT EXISTS default.observations (id String, start_time DateTime64(3), project_id String) ENGINE = MergeTree PARTITION BY toYYYYMM(start_time) ORDER BY (project_id, id);
CREATE TABLE IF NOT EXISTS default.scores (id String, timestamp DateTime64(3), project_id String) ENGINE = MergeTree PARTITION BY toYYYYMM(timestamp) ORDER BY (project_id, id);
INSERT INTO default.observations SELECT toString(number), now64(3) - number, 'p1' FROM numbers(50000);
CREATE DATABASE IF NOT EXISTS customer_acme;
CREATE TABLE IF NOT EXISTS customer_acme.payments_eu (id UInt64, email String) ENGINE = MergeTree ORDER BY id;
INSERT INTO customer_acme.payments_eu SELECT number, concat('user', toString(number), '@example.com') FROM numbers(10000);
EOF
}
# about 200 MB in the first of trace_log / text_log (no TTL): over the 10 MiB
# test drop limit, so Fix A prints the flag line. text_log rows start with
# "dvseed " (left out when the logs are searched for secrets).
seed_log() {
    chq "$1" 'SYSTEM FLUSH LOGS' >/dev/null
    _lt=$(chq "$1" "SELECT name FROM system.tables WHERE database = 'system' AND name IN ('trace_log', 'text_log') ORDER BY name = 'trace_log' DESC LIMIT 1")
    case $_lt in
        trace_log) _x=$(chq "$1" 'INSERT INTO system.trace_log (event_date, event_time, trace) SELECT today(), now(), arrayMap(x -> rand64(number + x), range(100)) FROM numbers(250000)') ;;
        text_log) _x=$(chq "$1" "INSERT INTO system.text_log (event_date, event_time, message) SELECT today(), now(), concat('dvseed ', randomPrintableASCII(1000)) FROM numbers(200000)") ;;
        *) fail "$1: neither system.trace_log nor system.text_log: $_lt"; return 1 ;;
    esac
    chq "$1" 'SYSTEM FLUSH LOGS' >/dev/null
    _b=$(chq "$1" "SELECT total_bytes FROM system.tables WHERE database = 'system' AND name = '$_lt'")
    case $_b in [0-9]*) if [ "$_b" -gt 104857600 ]; then ok "$1: system.$_lt seeded ($_b bytes)"; else fail "$1: system.$_lt is only '$_b' bytes after the seed ($_x)"; fi ;; *) fail "$1: system.$_lt: $_b $_x" ;; esac
}
if up A; then
    # tests/seed.sql without its logins (those are for tests/k8s_shim.sh)
    if sed '/^-- Logins for tests\/k8s_shim.sh/,$d' tests/seed.sql | chx A --multiquery >"$F-seed-a.txt" 2>&1; then ok "A: tests/seed.sql"; else fail "A: tests/seed.sql: $(tail -3 "$F-seed-a.txt" | oneline)"; fi
    i=0; while [ $i -lt 310 ]; do echo "INSERT INTO customer_acme.events_eu (id) VALUES ($i);"; i=$((i + 1)); done | chx A --multiquery >>"$F-seed-a.txt" 2>&1
    i=0; while [ $i -lt 25 ]; do echo "INSERT INTO customer_acme.hot_eu VALUES ($i);"; i=$((i + 1)); done | chx A --multiquery >>"$F-seed-a.txt" 2>&1
    seed_log A
fi
for t in B C; do
    up "$t" || continue
    if seed_small "$t" >"$F-seed-$t.txt" 2>&1; then ok "$t: Langfuse-like tables and customer_acme.payments_eu"; else fail "$t: seed: $(tail -3 "$F-seed-$t.txt" | oneline)"; fi
    seed_log "$t"
done

section "recording kubectl's custom-columns output (tests/out/pods.*)"
kubectl get pods -A --no-headers -o "$K8S_COLS" >"$OUT/pods.all" 2>&1
kubectl get pods -A --field-selector=status.phase=Running --no-headers -o "$K8S_COLS" >"$OUT/pods.running" 2>&1
for ns in "$A_NS" "$B_NS" "$C_NS" clickhouse-operator-system cert-manager kube-system; do
    kubectl get pods -n "$ns" --no-headers -o "$K8S_COLS" >"$OUT/pods.$ns" 2>&1
done
{ kubectl version; helm version; docker exec "$NODE" crictl images; } >"$F-versions.txt" 2>&1
if [ "$(awk 'NF != 11' "$OUT/pods.all" | wc -l)" = 0 ] && [ -s "$OUT/pods.all" ]; then ok "pods.all: 11 columns on every line ($(wc -l <"$OUT/pods.all" | tr -d ' ') pods)"; else fail "pods.all: lines without 11 columns: $(awk 'NF != 11' "$OUT/pods.all" | head -3 | oneline)"; fi

spec_sums() {
    for t in A B C; do
        up "$t" || continue
        tgt "$t"
        printf '%s/%s %s %s\n' "$_n" "$_p" \
            "$(kubectl get pod "$_p" -n "$_n" -o 'jsonpath={.metadata.uid} {.spec}' | cksum | tr ' ' '-')" \
            "$(kubectl get pod "$_p" -n "$_n" -o 'jsonpath=ephemeral=[{.spec.ephemeralContainers}] restarts={.status.containerStatuses[*].restartCount}')"
    done
}
spec_sums >"$F-spec-before.txt"

# ---------------------------------------------------------------- 3. discovery
section "--k8s auto over all namespaces"
if [ "$A_UP$B_UP$C_UP" = 111 ]; then
    sh diskvet.sh report --k8s auto >"$F-auto.md" 2>"$F-auto.err" </dev/null
    rc=$?
    if [ "$rc" = 2 ]; then ok "auto: exit 2 (several pods)"; else fail "auto: exit $rc: $(oneline <"$F-auto.err")"; fi
    has "$F-auto.err" "found 4 ClickHouse pods. Each has its own disk and system logs, so diskvet checks one pod per run:" "auto: found 4 ClickHouse pods"
    sed -n 's/^  sh .* report --k8s \([^ ]*\) > report-[^ ]*\.md$/\1/p' "$F-auto.err" | sort >"$W/auto.got"
    printf '%s\n' "$A_NS/$A_POD" "$B_NS/$B_POD" "$C_NS/bn8-clickhouse-shard0-0" "$C_NS/bn8-clickhouse-shard0-1" | sort >"$W/auto.want"
    if cmp -s "$W/auto.got" "$W/auto.want"; then ok "auto: one command per server pod, exactly: $(tr '\n' ' ' <"$W/auto.got")(no Keeper, operator, cert-manager or version-probe pod)"; else fail "auto: pods $(tr '\n' ' ' <"$W/auto.got"), want $(tr '\n' ' ' <"$W/auto.want")"; fi
    if [ ! -s "$F-auto.md" ]; then ok "auto: nothing on stdout"; else fail "auto: stdout: $(head -3 "$F-auto.md" | oneline)"; fi
    sh diskvet.sh --print-payload --k8s auto >"$F-auto.json" 2>"$F-auto-payload.err" </dev/null
    rc=$?
    if [ "$rc" = 2 ] && [ "$(wc -l <"$F-auto.json" | tr -d ' ')" = 1 ] && grep -q '"status": "ch_unreachable"' "$F-auto.json"; then
        ok "auto --print-payload: exit 2, one ch_unreachable line"
    else
        fail "auto --print-payload: exit $rc: $(oneline <"$F-auto.json")"
    fi
    # shellcheck disable=SC2086
    if sh tests/check_payload.sh "$F-auto.json" $FORBID "$SALT" >"$W/cp" 2>&1; then ok "auto --print-payload passes check_payload.sh"; else fail "auto --print-payload: $(oneline <"$W/cp")"; fi
else
    fail "auto over all namespaces: skipped, not every install is ready"
fi

# ---------------------------------------------------------------- 4. reports
section "reports"
if up A; then
    report a A clickhouse -n "$A_NS" --k8s auto
    has "$F-a.err" "kubectl context $CTX · pod $A_NS/$A_POD · container $A_CTR" "a: -n $A_NS --k8s auto picks the ClickHouse container, not the busybox sidecar listed first"
    has "$F-a.md" 'Save as `clickhouse-ttl.xml` (only logs without TTL are listed):' "a: the plain Fix B"
    has "$F-a.md" "\`kubectl exec -it -n $A_NS $A_POD -c $A_CTR -- sh -c 'exec clickhouse-client \${CLICKHOUSE_USER:+--user \"\$CLICKHOUSE_USER\"} \${CLICKHOUSE_PASSWORD:+--password \"\$CLICKHOUSE_PASSWORD\"}'\`" "a: the plain client command"
    has "$F-a.md" "max_table_size_to_drop = 10.0 MiB" "a: the test drop limit (ch-test.xml by subPath) is read"
    sh diskvet.sh report --k8s "$A_NS/$A_POD" --context "$CTX" >"$F-a-ctx.md" 2>"$F-a-ctx.err" </dev/null
    rc=$?
    if [ "$rc" = 0 ]; then ok "a --context $CTX: exit 0"; else fail "a --context: exit $rc: $(oneline <"$F-a-ctx.err")"; fi
    # every kubectl command (not the word in the text) starts with --context
    kcmds() { grep -oE 'kubectl (--context|config|exec|get|edit|patch|delete|logs|describe|rollout)' "$1"; }
    x=$(kcmds "$F-a-ctx.md" | sort | uniq -c | oneline)
    if [ -n "$x" ] && ! kcmds "$F-a-ctx.md" | grep -qv '^kubectl --context$'; then ok "a --context $CTX: every kubectl command in the report has --context ($x)"; else fail "a --context: kubectl commands without it: $x"; fi
fi
if up B; then
    report b B default --k8s "$B_NS/$B_POD"
    has "$F-b.md" "detected: Langfuse" "b: Langfuse detected"
    has "$F-b.md" "This pod is run by the ClickHouse operator (Langfuse chart 2.x)." "b: the Fix B of the Langfuse chart 2.x"
    has "$F-b.md" "\`kubectl exec -it -n $B_NS $B_POD -c $B_CTR -- clickhouse-client\`. Inside the pod it logs in as \`default\` with the login the operator set up" "b: the operator's client command"
    has "$F-b.md" "max_table_size_to_drop = 10.0 MiB" "b: the test drop limit (clickhouse.cluster.settings) is read"
    note "b: labels of the operator's pod: $(kubectl get pod "$B_POD" -n "$B_NS" -o 'jsonpath={.metadata.labels}' 2>&1)"
    if [ -z "$B_GROUP" ]; then
        # operator 0.0.7 sets no clickhouse.com/cluster label (its main branch does):
        # the report then says how to find the resource
        x=$(kubectl get clickhousecluster -n "$B_NS" -o name 2>&1)
        if [ "$x" = clickhousecluster.clickhouse.com/lf-langfuse ]; then ok "b: no clickhouse.com/cluster label (operator 0.0.7); the report's fallback, kubectl get clickhousecluster -n $B_NS, finds lf-langfuse"; else fail "b: kubectl get clickhousecluster -n $B_NS: $x"; fi
    elif kubectl get clickhousecluster "$B_GROUP" -n "$B_NS" >/dev/null 2>&1; then
        ok "b: the pod's clickhouse.com/cluster label ($B_GROUP) names its ClickHouseCluster"
    else
        fail "b: no ClickHouseCluster '$B_GROUP' in $B_NS: $(kubectl get clickhouseclusters -n "$B_NS" -o name 2>&1 | oneline)"
    fi
    x=$(sed -n 's/.*List them with `\([^`]*\)`.*/\1/p' "$F-b.md")
    if [ -n "$x" ]; then
        if sh -c "$x" </dev/null 2>&1 | grep -q "^$B_POD "; then ok "b: the printed list command finds the pod: $x"; else fail "b: '$x' does not list $B_POD"; fi
    fi
fi
if up C; then
    report c C default --k8s "$C_NS/$C_POD"
    has "$F-c.md" "This pod comes from the Bitnami ClickHouse chart (Langfuse chart 1.x uses it)." "c: the Fix B of the Bitnami chart 8.x"
    hasnt "$F-c.md" "Bitnami chart 9.x uses" "c: recognised as chart 8.x (helm.sh/chart on the pod), not an unknown Bitnami chart"
    has "$F-c.md" "touch /bitnami/clickhouse/data/flags/force_drop_table && chmod 666 /bitnami/clickhouse/data/flags/force_drop_table" "c: the flag path is under /bitnami/clickhouse/data/"
    has "$F-c.md" "max_table_size_to_drop = 10.0 MiB" "c: the test drop limit (extraOverridesSecret) is read"
fi
for t in a:A:plain b:B:official c:C:bitnami8; do
    n=${t%%:*}; x=${t#*:}; T=${x%%:*}; want=${x#*:}
    up "$T" || continue
    tgt "$T"
    awk -F '\t' '$1 == "_target"' "$F-$n.raw" >"$F-$n.target"
    got=$(awk -F '\t' '{ print $6 " " $7 " " $8 }' "$F-$n.target")
    case $got in
        "$want "*) ok "$n: _target row: flavor, PVCs, group: $got" ;;
        *) fail "$n: _target row '$(oneline <"$F-$n.target")', want flavor $want" ;;
    esac
done

# ---------------------------------------------------------------- 5. query_log
section "query_log: what diskvet ran, as which user"
for t in A:clickhouse B:default C:default; do
    T=${t%%:*}
    up "$T" || continue
    chq "$T" 'SYSTEM FLUSH LOGS' >/dev/null
    x=$(chq "$T" "SELECT toString(countIf(query_kind != 'Select' OR Settings['readonly'] != '2')) || ' ' || toString(count()) || ' ' || arrayStringConcat(arraySort(groupUniqArray(user)), ',') FROM system.query_log WHERE log_comment = 'diskvet'")
    case $x in
        "0 "[1-9]*" ${t#*:}") ok "$T: query_log: every row of diskvet is a Select with readonly=2, as ${t#*:} ($(echo "$x" | cut -d' ' -f2) rows)" ;;
        *) fail "$T: query_log of diskvet: '$x' (want 0 non-Select rows, as ${t#*:})" ;;
    esac
done

# ---------------------------------------------------------------- 6. payloads
section "payloads"
up A && payload payload-a A --k8s "$A_NS/$A_POD"
up B && payload payload-b B --k8s "$B_NS/$B_POD"
up C && payload payload-c C --k8s "$C_NS/$C_POD"

# ---------------------------------------------------------------- 7. permissions
section "permissions: ServiceAccount tokens"
mk_kubeconfig() {  # SA FILE
    _tok=$(kubectl create token "$1" -n "$A_NS" --duration=2h) || return 1
    KUBECONFIG=$2 kubectl config set-cluster kind --server="$SERVER" --certificate-authority="$W/ca.crt" --embed-certs=true >/dev/null &&
    KUBECONFIG=$2 kubectl config set-credentials "$1" --token="$_tok" >/dev/null &&
    KUBECONFIG=$2 kubectl config set-context "$1" --cluster=kind --user="$1" --namespace="$A_NS" >/dev/null &&
    KUBECONFIG=$2 kubectl config use-context "$1" >/dev/null
}
if up A; then
    # the Role of the README, as printed there
    awk '/^### Permissions$/ { p = 1 } p && /^```yaml$/ { y = 1; next } y && /^```$/ { exit } y' README.md \
        | sed "s/namespace: NS}/namespace: $A_NS}/" >"$F-readme-role.yaml"
    if grep -q '^kind: Role$' "$F-readme-role.yaml" && kubectl apply -f "$F-readme-role.yaml" >"$W/rbac.txt" 2>&1 \
        && kubectl create rolebinding diskvet --role=diskvet --serviceaccount="$A_NS:dv-sa-full" -n "$A_NS" >>"$W/rbac.txt" 2>&1 \
        && kubectl apply -f tests/k8s/rbac.yaml >>"$W/rbac.txt" 2>&1; then
        ok "the README's Role and rolebinding command, and tests/k8s/rbac.yaml"
    else
        fail "RBAC setup: $(oneline <"$W/rbac.txt")"
    fi
    kubectl config view --minify --raw -o 'jsonpath={.clusters[0].cluster.certificate-authority-data}' | base64 -d >"$W/ca.crt"
    for sa in dv-sa-full dv-sa-get dv-sa-noexec dv-sa-create; do
        mk_kubeconfig "$sa" "$W/kc-$sa" || fail "kubeconfig for $sa"
    done
    KUBECONFIG=$W/kc-dv-sa-full sh diskvet.sh report --k8s "$A_NS/$A_POD" >"$F-rbac-full.md" 2>"$F-rbac-full.err" </dev/null
    rc=$?
    check_report rbac-full A clickhouse
    KUBECONFIG=$W/kc-dv-sa-full sh diskvet.sh report --k8s auto >"$F-rbac-auto.md" 2>"$F-rbac-auto.err" </dev/null
    rc=$?
    check_report rbac-auto A clickhouse
    has "$F-rbac-auto.err" "not allowed to list pods in all namespaces; looking in your current namespace only (pass -n NAMESPACE to choose)" "README Role, auto without -n: the fallback note"
    KUBECONFIG=$W/kc-dv-sa-get sh diskvet.sh report --k8s "$A_NS/$A_POD" >"$F-rbac-get.md" 2>"$F-rbac-get.err" </dev/null
    rc=$?
    check_report rbac-get A clickhouse
    KUBECONFIG=$W/kc-dv-sa-get sh diskvet.sh report -n "$A_NS" --k8s auto >"$F-rbac-get-auto.md" 2>"$F-rbac-get-auto.err" </dev/null
    rc=$?
    if [ "$rc" = 2 ] && grep -q 'cannot list pods: ' "$F-rbac-get-auto.err"; then ok "get only: -n $A_NS --k8s auto needs list: exit 2, cannot list pods"; else fail "get only, auto: exit $rc: $(oneline <"$F-rbac-get-auto.err")"; fi
    KUBECONFIG=$W/kc-dv-sa-noexec sh diskvet.sh report --k8s "$A_NS/$A_POD" >"$F-rbac-noexec.md" 2>"$F-rbac-noexec.err" </dev/null
    rc=$?
    if [ "$rc" = 3 ]; then ok "no pods/exec: exit 3"; else fail "no pods/exec: exit $rc: $(oneline <"$F-rbac-noexec.err")"; fi
    has "$F-rbac-noexec.err" "(kubectl exec needs the create verb on pods/exec in namespace $A_NS: README, Kubernetes, Permissions." "no pods/exec: the hint"
    KUBECONFIG=$W/kc-dv-sa-noexec sh diskvet.sh --print-payload --k8s "$A_NS/$A_POD" --env tests/fixtures/test.env >"$F-rbac-noexec.json" 2>"$F-rbac-noexec-payload.err" </dev/null
    rc=$?
    if [ "$rc" = 3 ] && [ "$(wc -l <"$F-rbac-noexec.json" | tr -d ' ')" = 1 ] && grep -q '"status": "ch_unreachable"' "$F-rbac-noexec.json"; then ok "no pods/exec, --print-payload: exit 3, one ch_unreachable line"; else fail "no pods/exec, --print-payload: exit $rc: $(oneline <"$F-rbac-noexec.json")"; fi
    DV_KUBECONFIG=$W/kc-dv-sa-full
    payload payload-rbac A --k8s "$A_NS/$A_POD"
    DV_KUBECONFIG=""
    # the README Role has get on pods/exec for API servers that authorize
    # kubectl's WebSocket exec as a GET: what happens with create only
    KUBECONFIG=$W/kc-dv-sa-create sh diskvet.sh report --k8s "$A_NS/$A_POD" >"$F-rbac-create.md" 2>"$F-rbac-create.err" </dev/null
    note "pods/exec with create only (no get): exit $?: $(grep -m 1 -v '^diskvet: kubectl context' "$F-rbac-create.err" | cut -c1-240)"
fi

# ---------------------------------------------------------------- 8. secrets in the server logs
section "no password and no salt in query_log and text_log"
for T in A B C; do
    up "$T" || continue
    chq "$T" 'SYSTEM FLUSH LOGS' >/dev/null
    # searched here, not by a query: a WHERE on a secret would put it in the logs
    printf '%s\n' "SELECT query FROM system.query_log FORMAT TSVRaw" | chx "$T" >"$W/logs.$T" 2>&1
    printf '%s\n' "SELECT message FROM system.text_log WHERE NOT startsWith(message, 'dvseed ') FORMAT TSVRaw" | chx "$T" >>"$W/logs.$T" 2>&1
    n=$(wc -l <"$W/logs.$T" | tr -d ' ')
    bad=""
    for s in "$PW_A" "$PW_B" "$PW_C" "$SALT"; do
        if grep -qF -- "$s" "$W/logs.$T"; then bad="$bad ${s%"${s#??}"}..."; fi
    done
    if [ "$n" -gt 10 ] && [ -z "$bad" ]; then ok "$T: no password and no salt in query_log and text_log ($n lines)"; else fail "$T: in the server logs ($n lines):$bad"; fi
done

spec_sums >"$F-spec-after.txt"
if [ -s "$F-spec-before.txt" ] && cmp -s "$F-spec-before.txt" "$F-spec-after.txt"; then
    ok "no mutation: every pod's UID, spec, ephemeral containers and restart counts are unchanged after the diskvet runs"
else
    fail "pods changed: $(diff "$F-spec-before.txt" "$F-spec-after.txt" | oneline)"
fi

# ---------------------------------------------------------------- 9. the operator's server log files
section "(b) server log files on the data volume, and the printed rm line"
if up B; then
    kxp B df -P /var/lib/clickhouse /var/log/clickhouse-server >"$F-b-df.txt" 2>&1
    if [ "$(awk 'NR > 1' "$F-b-df.txt" | wc -l)" = 2 ] && [ "$(awk 'NR > 1 { print $1 }' "$F-b-df.txt" | sort -u | wc -l)" = 1 ]; then
        ok "b: df: /var/lib/clickhouse and /var/log/clickhouse-server are on one file system ($(awk 'NR == 2 { print $1 }' "$F-b-df.txt"))"
    else
        fail "b: df: $(oneline <"$F-b-df.txt")"
    fi
    kubectl get pod "$B_POD" -n "$B_NS" -o 'jsonpath={range .spec.containers[?(@.name=="clickhouse-server")].volumeMounts[*]}{.mountPath} {.name} {.subPath}{"\n"}{end}' >"$F-b-mounts.txt" 2>&1
    kubectl get pod "$B_POD" -n "$B_NS" -o 'jsonpath={range .spec.volumes[*]}{.name} {.persistentVolumeClaim.claimName}{"\n"}{end}' >"$F-b-volumes.txt" 2>&1
    vd=$(awk '$1 == "/var/lib/clickhouse" { print $2 }' "$F-b-mounts.txt")
    vl=$(awk '$1 == "/var/log/clickhouse-server" { print $2 }' "$F-b-mounts.txt")
    claim=$(awk -v v="$vd" '$1 == v { print $2 }' "$F-b-volumes.txt")
    if [ -n "$vd" ] && [ "$vd" = "$vl" ] && [ -n "$claim" ]; then ok "b: both paths are subPaths of volume $vd, the PVC $claim"; else fail "b: mounts $(oneline <"$F-b-mounts.txt"), volumes $(oneline <"$F-b-volumes.txt")"; fi
    kxp B cat /etc/clickhouse-server/config.yaml 2>&1 | awk '/^logger:/ { p = 1; print; next } p && /^[^ ]/ { exit } p' >"$F-b-logger-before.txt"
    if grep -q 'level: trace' "$F-b-logger-before.txt"; then ok "b: the operator's own logger is at level trace ($(oneline <"$F-b-logger-before.txt"))"; else fail "b: the operator's logger: $(oneline <"$F-b-logger-before.txt")"; fi
    chq B 'SYSTEM FLUSH LOGS' >/dev/null
    x=$(chq B "SELECT count() FROM system.text_log WHERE level = 'Trace' AND event_time > now() - INTERVAL 10 MINUTE")
    case $x in [1-9]*) ok "b: text_log has Trace rows before Fix B ($x in 10 min)" ;; *) fail "b: Trace rows before Fix B: '$x'" ;; esac
    du=$(section_cmd "$F-b.md" 2 "-- du -sh /var/log/clickhouse-server")
    # at OK, check 2 has the du line inline
    [ -n "$du" ] || du=$(grep -o '`kubectl exec [^`]* -- du -sh /var/log/clickhouse-server`' "$F-b.md" | head -1 | tr -d '`')
    if [ -n "$du" ] && sh -c "$du" </dev/null >"$F-b-du.txt" 2>&1; then ok "b: the printed du line runs: $(oneline <"$F-b-du.txt")"; else fail "b: du line '$du': $(oneline <"$F-b-du.txt" 2>/dev/null)"; fi
    rmline=$(section_cmd "$F-b.md" 2 "sh -c 'rm -f /var/log/clickhouse-server/*.log.*'")
    if [ -z "$rmline" ]; then
        case $(status_of "$F-b.md" 2) in
            WARN|CRITICAL) fail "b: check 2 is $(status_of "$F-b.md" 2) but prints no rm line" ;;
            *) note "b: check 2 is $(status_of "$F-b.md" 2) on this runner, so the report prints no rm line; testing the line the report prints at WARN" ;;
        esac
        rmline="kubectl exec -n $B_NS $B_POD -c $B_CTR -- sh -c 'rm -f /var/log/clickhouse-server/*.log.*'"
    fi
    # a rotated file as ClickHouse names them (test-only write)
    kxp B sh -c 'printf x >/var/log/clickhouse-server/clickhouse-server.log.0.gz && ls -la /var/log/clickhouse-server' >"$F-b-logs-before.txt" 2>&1
    if sh -c "$rmline" </dev/null >"$F-b-rm.txt" 2>&1; then ok "b: the printed rm line runs: $rmline"; else fail "b: rm line: $(oneline <"$F-b-rm.txt")"; fi
    kxp B ls -la /var/log/clickhouse-server >"$F-b-logs-after.txt" 2>&1
    if kxp B test -e /var/log/clickhouse-server/clickhouse-server.log.0.gz; then fail "b: the rotated file is still there"; else ok "b: the rotated clickhouse-server.log.0.gz is gone"; fi
    if kxp B test -s /var/log/clickhouse-server/clickhouse-server.log && kxp B test -e /var/log/clickhouse-server/clickhouse-server.err.log; then
        ok "b: the current clickhouse-server.log and clickhouse-server.err.log stay"
    else
        fail "b: current log files: $(oneline <"$F-b-logs-after.txt")"
    fi
fi

# ---------------------------------------------------------------- 10. Fix A as printed
section "Fix A through the printed clickhouse-client command, with the flag line"
fix_a() {  # T NAME
    if run_fix "$1" "$F-$2.md" 1 '**Fix A:'; then ok "$1: Fix A ran as printed"; else fail "$1: Fix A: $(tail -4 "$F-$2.md.fix.txt" | oneline)"; fi
    sed -n "s/^sql${tab}TRUNCATE TABLE system\.\([a-z0-9_]*\);\$/\1/p" "$W/steps" >"$W/truncated"
    while IFS= read -r tb; do
        x=$(chq "$1" "SELECT total_bytes FROM system.tables WHERE database = 'system' AND name = '$tb'")
        case $x in [0-9]*) if [ "$x" -lt 10485760 ]; then ok "$1: system.$tb is truncated ($x bytes)"; else fail "$1: system.$tb still has $x bytes"; fi ;; *) fail "$1: system.$tb: $x" ;; esac
    done <"$W/truncated"
    if grep -q 'force_drop_table' "$W/steps"; then
        tgt "$1"
        if kxp "$1" test -e "$(sed -n 's/.*touch \([^ ]*force_drop_table\) .*/\1/p' "$W/steps" | head -1)"; then fail "$1: the flag is still there"; else ok "$1: the flag was used up by the TRUNCATE"; fi
    else
        fail "$1: Fix A has no flag line (a log over the 10 MiB test drop limit was seeded)"
    fi
}
up A && fix_a A a
up B && fix_a B b
up C && fix_a C c

# ---------------------------------------------------------------- 11. Fix B through the chart
section "Fix B through the chart: (b) helm template | kubectl apply, (c) helm upgrade --reuse-values"
B_FIXED=0 C_FIXED=0
if up B; then
    yaml_of "$F-b.md" >"$F-b-fixb.yaml"
    sed -n '/^      logger:$/d; s/^      \([a-z_]*\):$/\1/p' "$F-b-fixb.yaml" >"$F-b-fixb.logs"
    if [ "$(sed -n 1p "$F-b-fixb.yaml")" = "clickhouse:" ] && [ -s "$F-b-fixb.logs" ]; then ok "b: Fix B YAML for the logs $(tr '\n' ' ' <"$F-b-fixb.logs")"; else fail "b: Fix B YAML: $(head -5 "$F-b-fixb.yaml" | oneline)"; fi
    b_uid=$(uid_of "$B_NS" "$B_POD")
    if render_b -f "$F-b-fixb.yaml" >"$W/b2.yaml" 2>"$W/b2.err" && kubectl apply -n "$B_NS" -f "$W/b2.yaml" >"$F-b-apply.txt" 2>&1; then
        ok "b: helm template ... -f fixb.yaml | kubectl apply: $(oneline <"$F-b-apply.txt")"
        B_FIXED=1
        kubectl get clickhousecluster "$B_GROUP" -n "$B_NS" -o 'jsonpath={.spec.settings.extraConfig}' >"$F-b-extraconfig.json" 2>&1
    else
        fail "b: re-render with Fix B: $(oneline <"$W/b2.err") $(oneline <"$F-b-apply.txt" 2>/dev/null)"
    fi
fi
if up C; then
    yaml_of "$F-c.md" >"$F-c-fixb-values.yaml"
    # the report: "If you installed the Bitnami chart on its own, leave out the clickhouse: level"
    if [ "$(sed -n 1p "$F-c-fixb-values.yaml")" = "clickhouse:" ]; then
        sed '1d; s/^  //' "$F-c-fixb-values.yaml" >"$F-c-fixb.yaml"
    else
        fail "c: Fix B YAML does not start with clickhouse: $(head -3 "$F-c-fixb-values.yaml" | oneline)"
        cp "$F-c-fixb-values.yaml" "$F-c-fixb.yaml"
    fi
    sed -n 's/^      <\([a-z_]*\)>$/\1/p' "$F-c-fixb.yaml" >"$F-c-fixb.logs"
    if [ -s "$F-c-fixb.logs" ]; then ok "c: Fix B extraOverrides for the logs $(tr '\n' ' ' <"$F-c-fixb.logs")"; else fail "c: no logs in the Fix B XML: $(head -8 "$F-c-fixb.yaml" | oneline)"; fi
    c_uid=$(uid_of "$C_NS" "$C_POD")
    if timeout 300 helm upgrade bn8 "$W"/bn8/clickhouse-*.tgz -n "$C_NS" --reuse-values -f "$F-c-fixb.yaml" >"$F-c-upgrade.txt" 2>&1; then
        ok "c: helm upgrade --reuse-values -f fixb.yaml"
        C_FIXED=1
    else
        fail "c: helm upgrade: $(tail -4 "$F-c-upgrade.txt" | oneline)"
    fi
fi
# restart_wait T NAME OLD_UID: the chart or the operator restarts the pod; if
# not within 5 minutes, the report's own "restart it yourself" line
restart_wait() {
    tgt "$1"
    if wait_new "$_n" "$_p" "$3" 300; then
        ok "$1: the pod restarted by itself after Fix B"
    else
        fail "$1: the pod did not restart within 5 minutes of Fix B"
        x=$(sed -n 's/.*restart it yourself: `\([^`]*\)`.*/\1/p' "$F-$2.md")
        note "$1: running the report's line: $x"
        sh -c "$x" </dev/null >>"$F-$2-restart.txt" 2>&1
        wait_new "$_n" "$_p" "$3" 300 || { fail "$1: no new pod after $x"; return 1; }
    fi
    wait_ch "$1" 180 || { fail "$1: ClickHouse does not answer after the restart"; return 1; }
    chq "$1" 'SYSTEM FLUSH LOGS' >/dev/null
}
# ttl_check T LOGS: every log of Fix B has a TTL now
ttl_check() {
    _in=$(sed "s/.*/'&'/" "$2" | paste -s -d, -)
    x=$(chq "$1" "SELECT toString(count()) || ' ' || arrayStringConcat(arraySort(groupArrayIf(name, position(engine_full, ' TTL ') = 0)), ',') FROM system.tables WHERE database = 'system' AND name IN ($_in)")
    if [ "$x" = "$(grep -c . "$2") " ]; then ok "$1: every log of Fix B has a TTL now ($(tr '\n' ' ' <"$2"))"; else fail "$1: logs without TTL after Fix B (count, names): '$x'"; fi
}
after_fixb() {  # T NAME USER
    tgt "$1"
    ttl_check "$1" "$F-$2-fixb.logs"
    report "$2-fixb" "$1" "$3" --k8s "$_n/$_p"
    fix_steps "$F-$2-fixb.md" 1 '**Fix C:' >"$W/fixc"
    while IFS= read -r lg; do
        if grep -q "DROP TABLE system\.${lg}_0;" "$W/fixc"; then ok "$1: Fix C lists the old copy system.${lg}_0"; else fail "$1: no system.${lg}_0 in Fix C"; fi
    done <"$F-$2-fixb.logs"
    if run_fix "$1" "$F-$2-fixb.md" 1 '**Fix C:'; then ok "$1: Fix C ran as printed"; else fail "$1: Fix C: $(tail -4 "$F-$2-fixb.md.fix.txt" | oneline)"; fi
    report "$2-fixc" "$1" "$3" --k8s "$_n/$_p"
    if grep -q '| old copy |' "$F-$2-fixc.md" || grep -q '^\*\*Fix C:' "$F-$2-fixc.md"; then fail "$1: old copies left after Fix C: $(grep '| old copy |' "$F-$2-fixc.md" | oneline)"; else ok "$1: no old copies left after Fix C"; fi
}
if [ "$B_FIXED" = 1 ] && restart_wait B b "$b_uid"; then
    after_fixb B b default
    # the logger lines of Fix B (in clickhouse.cluster.settings, the operator's extraConfig)
    kxp B cat /etc/clickhouse-server/config.d/99-extra-config.yaml >"$F-b-99-extra-config.yaml" 2>&1
    # the operator writes the file as JSON (valid YAML) on one line
    if grep -q '"logger":{[^}]*"level":"information"' "$F-b-99-extra-config.yaml"; then ok "b: the logger of Fix B is in config.d/99-extra-config.yaml: $(grep -o '"logger":{[^}]*}' "$F-b-99-extra-config.yaml")"; else fail "b: no logger in 99-extra-config.yaml: $(oneline <"$F-b-99-extra-config.yaml")"; fi
    chq B 'SYSTEM FLUSH LOGS' >/dev/null
    x=$(chq B "SELECT toString(countIf(level = 'Trace')) || ' ' || toString(count()) FROM system.text_log")
    case $x in "0 "[1-9]*) ok "b: after Fix B the server logs at level information: no Trace rows in the new text_log (${x#0 } rows)" ;; *) fail "b: Trace rows and rows in text_log after Fix B: '$x'" ;; esac
fi
if [ "$C_FIXED" = 1 ]; then
    if kubectl rollout status statefulset/bn8-clickhouse-shard0 -n "$C_NS" --timeout=480s >"$F-c-rollout.txt" 2>&1; then ok "c: the StatefulSet rolled out Fix B"; else fail "c: rollout: $(tail -3 "$F-c-rollout.txt" | oneline)"; fi
    if restart_wait C c "$c_uid"; then after_fixb C c default; fi
fi

# ---------------------------------------------------------------- phase 2
# (d) Bitnami chart 9.x: the login from CLICKHOUSE_ADMIN_PASSWORD_FILE, and
#     whether a config file named 00- loads before the chart's
#     08-sampling.xml, so that logs the chart turns off stay off (the bitnami9
#     variant of Fix B depends on it);
# (e) the Altinity operator: the passwordless default user, a sidecar listed
#     first, and Fix B through spec.configuration.files of the resource.
section "phase 2: the Bitnami chart 9.x and an Altinity ClickHouseInstallation"
if [ "$FAIL" -ne 0 ]; then
    note "phase 2 skipped: phase 1 has $FAIL failures"
else
    # the phase 1 installs make room (the operators stay)
    kubectl delete namespace "$A_NS" "$B_NS" "$C_NS" --wait=false >/dev/null 2>&1
    setup_d() {
        kubectl create namespace "$D_NS" &&
        mkdir -p "$W/bn9" &&
        retry 3 timeout 300 helm pull oci://registry-1.docker.io/bitnamicharts/clickhouse --version 9.4.4 -d "$W/bn9" &&
        printf 'auth:\n  password: %s\n' "$PW_D" >"$W/d-auth.yaml" &&
        timeout 300 helm install bn9 "$W"/bn9/clickhouse-*.tgz -n "$D_NS" -f tests/k8s/bn9-values.yaml -f "$W/d-auth.yaml"
    }
    setup_e() {
        kubectl create namespace "$E_NS" &&
        mkdir -p "$W/alt" &&
        retry 3 timeout 300 helm pull altinity-clickhouse-operator --repo https://docs.altinity.com/clickhouse-operator/ --version 0.27.4 -d "$W/alt" &&
        timeout 300 helm install altinity-operator "$W"/alt/altinity-clickhouse-operator-*.tgz -n "$E_NS" &&
        kubectl wait --for=condition=Available deployment --all -n "$E_NS" --timeout=300s &&
        retry 12 kubectl apply -f tests/k8s/altinity.yaml
    }
    ( setup_d >"$F-setup-d.txt" 2>&1; echo $? >"$W/rc-d" ) &
    setup_e >"$F-setup-e.txt" 2>&1
    echo $? >"$W/rc-e"
    wait
    for t in d e; do
        if [ "$(cat "$W/rc-$t" 2>/dev/null)" = 0 ]; then ok "setup ($t)"; else fail "setup ($t): $(tail -6 "$F-setup-$t.txt" | oneline)"; fi
    done
    if [ "$(cat "$W/rc-d")" = 0 ] && wait_pods "$D_NS" app.kubernetes.io/instance=bn9,app.kubernetes.io/name=clickhouse 1 600 && wait_ch D 120; then D_UP=1; ok "(d) $D_NS/$D_POD is ready"; else fail "(d) $D_NS/$D_POD is not ready"; fi
    if [ "$(cat "$W/rc-e")" = 0 ] && wait_pods "$E_NS" clickhouse.altinity.com/chi=dv-alt 1 600 && wait_ch E 120; then E_UP=1; ok "(e) $E_NS/$E_POD is ready"; else fail "(e) $E_NS/$E_POD is not ready"; fi
    [ "$D_UP$E_UP" = 11 ] || diag
    for ns in "$D_NS" "$E_NS"; do
        kubectl get pods -n "$ns" --no-headers -o "$K8S_COLS" >"$OUT/pods.$ns" 2>&1
    done
    FORBID="$FORBID $D_NS $E_NS bn9-clickhouse chi-dv-alt $(pvcs_of "$D_NS" "$D_POD") $(pvcs_of "$E_NS" "$E_POD")"
    for t in D E; do
        up "$t" || continue
        if seed_small "$t" >"$F-seed-$t.txt" 2>&1; then ok "$t: Langfuse-like tables and customer_acme.payments_eu"; else fail "$t: seed: $(tail -3 "$F-seed-$t.txt" | oneline)"; fi
        chq "$t" 'SYSTEM FLUSH LOGS' >/dev/null
    done

    if up D; then
        x=$(kxp D sh -c 'if [ -n "${CLICKHOUSE_ADMIN_PASSWORD_FILE:-}" ] && [ -r "$CLICKHOUSE_ADMIN_PASSWORD_FILE" ] && [ -z "${CLICKHOUSE_ADMIN_PASSWORD:-}" ]; then echo file; else echo other; fi' 2>&1)
        if [ "$x" = file ]; then ok "d: chart 9.x gives the pod only CLICKHOUSE_ADMIN_PASSWORD_FILE (usePasswordFiles)"; else fail "d: the pod's password variables: $x"; fi
        report d D default --k8s "$D_NS/$D_POD"
        awk -F '\t' '$1 == "_target"' "$F-d.raw" >"$F-d.target"
        x=$(awk -F '\t' '{ print $6 }' "$F-d.target")
        if [ "$x" = bitnami9 ]; then ok "d: flavor bitnami9 (helm.sh/chart $(kubectl get pod "$D_POD" -n "$D_NS" -o 'jsonpath={.metadata.labels.helm\.sh/chart}'))"; else fail "d: flavor '$x', want bitnami9"; fi
        payload payload-d D --k8s "$D_NS/$D_POD"
        x=$(chq D "SELECT count() FROM system.tables WHERE database = 'system' AND name = 'query_log'")
        if [ "$x" = 0 ]; then ok "d: no system.query_log: the chart's 08-sampling.xml turns it off"; else fail "d: system.query_log before Fix B: '$x'"; fi
        # the bitnami9 Fix B: a 00- file in configdFiles, as the report prints it
        # once the order is proven; until then built from the plain Fix B's XML
        # the same way (ind 4 under the key)
        if grep -q '^  00-diskvet-ttl.xml: |$' "$F-d.md"; then
            yaml_of "$F-d.md" >"$W/d-fixb.yaml"
        else
            awk '/^## [0-9]\. / { sec = substr($2, 1, 1) + 0 }
                sec == 1 && /^\*\*Fix B/ { b = 1 }
                b && /^```xml$/ { x = 1; next }
                x && /^```$/ { exit }
                x { print "    " $0 }' "$F-d.md" | { printf 'configdFiles:\n  00-diskvet-ttl.xml: |\n'; cat; } >"$W/d-fixb.yaml"
        fi
        sed -n 's/^        <\([a-z_]*\)>$/\1/p' "$W/d-fixb.yaml" >"$F-d-fixb.logs"
        # plus a log the chart turns off: with the file loading before 08-sampling.xml it stays off
        awk '$0 == "    </clickhouse>" { print "        <query_log>"; print "            <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>"; print "        </query_log>" } { print }' "$W/d-fixb.yaml" >"$F-d-fixb.yaml"
        if [ -s "$F-d-fixb.logs" ] && grep -q '^        <query_log>$' "$F-d-fixb.yaml"; then ok "d: configdFiles 00-diskvet-ttl.xml for $(tr '\n' ' ' <"$F-d-fixb.logs")and query_log"; else fail "d: Fix B for 9.x: $(head -6 "$F-d-fixb.yaml" | oneline)"; fi
        d_uid=$(uid_of "$D_NS" "$D_POD")
        if timeout 300 helm upgrade bn9 "$W"/bn9/clickhouse-*.tgz -n "$D_NS" --reuse-values -f "$F-d-fixb.yaml" >"$F-d-upgrade.txt" 2>&1 \
            && kubectl rollout status statefulset/bn9-clickhouse-shard0 -n "$D_NS" --timeout=480s >>"$F-d-upgrade.txt" 2>&1 \
            && restart_wait D d "$d_uid"; then
            ok "d: helm upgrade --reuse-values -f fixb.yaml restarted the pod"
            ttl_check D "$F-d-fixb.logs"
            x=$(chq D "SELECT count() FROM system.tables WHERE database = 'system' AND name = 'query_log'")
            if [ "$x" = 0 ]; then ok "d: 00-diskvet-ttl.xml loads before the chart's 08-sampling.xml: query_log, which the chart turns off, stays off"; else fail "d: query_log is back after the 00- file: '$x'"; fi
            # the control: the same log in a file named after 08-sampling.xml comes back
            printf 'configdFiles:\n  zz-diskvet-probe.xml: |\n    <clickhouse>\n        <query_log/>\n    </clickhouse>\n' >"$F-d-probe.yaml"
            d_uid=$(uid_of "$D_NS" "$D_POD")
            if timeout 300 helm upgrade bn9 "$W"/bn9/clickhouse-*.tgz -n "$D_NS" --reuse-values -f "$F-d-probe.yaml" >>"$F-d-upgrade.txt" 2>&1 \
                && kubectl rollout status statefulset/bn9-clickhouse-shard0 -n "$D_NS" --timeout=480s >>"$F-d-upgrade.txt" 2>&1 \
                && restart_wait D d "$d_uid"; then
                x=$(chq D "SELECT count() FROM system.tables WHERE database = 'system' AND name = 'query_log'")
                if [ "$x" = 1 ]; then ok "d: the control: the same log in zz-diskvet-probe.xml, after 08-sampling.xml, turns query_log back on (the files load by name)"; else fail "d: the control: query_log '$x' with a zz- file"; fi
            else
                fail "d: the control upgrade: $(tail -4 "$F-d-upgrade.txt" | oneline)"
            fi
        else
            fail "d: helm upgrade with Fix B: $(tail -4 "$F-d-upgrade.txt" | oneline)"
        fi
    fi

    if up E; then
        report e E default -n "$E_NS" --k8s auto
        has "$F-e.err" "kubectl context $CTX · pod $E_NS/$E_POD · container $E_CTR" "e: -n $E_NS --k8s auto picks the clickhouse container, not the clickhouse-backup sidecar listed first"
        awk -F '\t' '$1 == "_target"' "$F-e.raw" >"$F-e.target"
        x=$(awk -F '\t' '{ print $6 " " $8 }' "$F-e.target")
        if [ "$x" = "altinity dv-alt" ]; then ok "e: flavor altinity, group dv-alt (clickhouse.altinity.com/chi)"; else fail "e: flavor and group '$x', want 'altinity dv-alt'"; fi
        has "$F-e.md" "This pod is run by the Altinity operator (ClickHouseInstallation dv-alt in namespace $E_NS)." "e: the Fix B of an Altinity installation"
        payload payload-e E --k8s "$E_NS/$E_POD"
        yaml_of "$F-e.md" >"$F-e-fixb.yaml"
        sed -n 's/^              <\([a-z_]*\)>$/\1/p' "$F-e-fixb.yaml" >"$F-e-fixb.logs"
        if [ "$(sed -n 1p "$F-e-fixb.yaml")" = "spec:" ] && [ -s "$F-e-fixb.logs" ]; then ok "e: Fix B spec.configuration.files for the logs $(tr '\n' ' ' <"$F-e-fixb.logs")"; else fail "e: Fix B YAML: $(head -6 "$F-e-fixb.yaml" | oneline)"; fi
        e_uid=$(uid_of "$E_NS" "$E_POD")
        # the printed block, merged into the resource's manifest, applied
        if kubectl patch --local -f tests/k8s/altinity.yaml --type merge --patch-file "$F-e-fixb.yaml" -o yaml >"$W/e2.yaml" 2>"$F-e-apply.txt" \
            && kubectl apply -f "$W/e2.yaml" >>"$F-e-apply.txt" 2>&1; then
            ok "e: the printed block applied to the ClickHouseInstallation: $(oneline <"$F-e-apply.txt")"
            if restart_wait E e "$e_uid"; then after_fixb E e default; fi
        else
            fail "e: applying Fix B: $(oneline <"$F-e-apply.txt")"
        fi
    fi
fi

# ---------------------------------------------------------------- 12. the audit log
section "the API server's audit log"
docker exec "$NODE" cat /var/log/kubernetes/kube-apiserver-audit.log >"$W/audit.log" 2>&1
n=$(wc -l <"$W/audit.log" | tr -d ' ')
if [ "$n" -gt 10 ] && grep -q '"kind":"Event"' "$W/audit.log"; then ok "audit log: $n entries"; else fail "audit log: $(head -3 "$W/audit.log" | oneline)"; fi
for s in "password of (a):$PW_A" "password of (b):$PW_B" "password of (c):$PW_C" "password of (d):$PW_D" "salt:$SALT"; do
    if grep -qF -- "${s#*:}" "$W/audit.log"; then fail "audit log: the ${s%%:*} is in it"; else ok "audit log: no ${s%%:*}"; fi
done
grep '"subresource":"exec"' "$W/audit.log" | sed -n 's/.*"requestURI":"\([^"]*\)".*/\1/p' | sort -u >"$F-audit-exec.txt"
for ns in "$A_NS" "$B_NS" "$C_NS"; do
    x=$(grep -c "^/api/v1/namespaces/$ns/pods/.*/exec?command=sh.*log_comment%3Ddiskvet" "$F-audit-exec.txt")
    if [ "$x" -gt 0 ]; then ok "audit log: diskvet's exec command lines in $ns ($x distinct), in the request URL as command= parameters"; else fail "audit log: no exec with --log_comment=diskvet in $ns"; fi
done
if grep -q 'command=--structure' "$F-audit-exec.txt"; then ok "audit log: the hashing exec (clickhouse local) is there, with its constant query"; else fail "audit log: no clickhouse local exec"; fi
x=$(grep -E 'log_comment%3Ddiskvet|command=--structure' "$F-audit-exec.txt" | grep -c 'tty=true')
if [ "$x" = 0 ]; then ok "audit log: no exec of diskvet asks for a TTY"; else fail "audit log: $x execs of diskvet with tty=true"; fi
# every request of the test ServiceAccounts: account, verb, resource, response code
grep '"username":"system:serviceaccount:dv-plain:dv-sa-' "$W/audit.log" | awk '{
    a = ""; v = ""; r = "-"; s = ""; c = ""
    if (match($0, /"username":"system:serviceaccount:dv-plain:[a-z-]*"/)) a = substr($0, RSTART + 43, RLENGTH - 44)
    if (match($0, /"verb":"[a-z]*"/)) v = substr($0, RSTART + 8, RLENGTH - 9)
    if (match($0, /"objectRef":\{"resource":"[a-z]*"/)) r = substr($0, RSTART + 25, RLENGTH - 26)
    if (match($0, /"subresource":"[a-z]*"/)) s = "/" substr($0, RSTART + 15, RLENGTH - 16)
    i = index($0, "\"responseStatus\"")
    if (i && match(substr($0, i), /"code":[0-9]+/)) c = substr(substr($0, i), RSTART + 7, RLENGTH - 7)
    print a " " v " " r s " " c
}' | sort | uniq -c >"$F-audit-sa.txt"
if [ -s "$F-audit-sa.txt" ] && ! awk '{ print $3 " " $4 }' "$F-audit-sa.txt" | grep -Evq '^(get|list) pods$|^(create|get) pods/exec$|^get -$'; then
    ok "audit log: the ServiceAccounts only got and listed pods and created exec: $(oneline <"$F-audit-sa.txt")"
else
    fail "audit log, ServiceAccount requests: $(oneline <"$F-audit-sa.txt")"
fi

# ---------------------------------------------------------------- done
section "done"
diag
# nothing of the uploaded results may hold a password
for s in "$PW_A" "$PW_B" "$PW_C" "$PW_D"; do
    x=$(grep -rlF -- "$s" "$OUT" 2>/dev/null)
    if [ -n "$x" ]; then
        fail "a password is in $(printf '%s\n' "$x" | oneline) (removed)"
        printf '%s\n' "$x" | while IFS= read -r f; do rm -f "$f"; done
    fi
done
echo "k8s: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
