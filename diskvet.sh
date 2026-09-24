#!/bin/sh
# diskvet: a read-only check-up for the ClickHouse inside your
# Langfuse, SigNoz or ClickStack. Apache-2.0.
#
# What it does: runs the SELECT queries from checks.sql (system.* only) with
# readonly=2 and resource limits, then prints a Markdown report with ready fix
# commands. It never changes anything and never sends anything anywhere.
#
# Plain POSIX sh (dash, busybox ash, bash). Needs awk, sed, od, date, and either
# docker (for --docker) or clickhouse-client / `clickhouse client`.
#
#   sh diskvet.sh report --docker auto > report.md
#   sh diskvet.sh --print-payload --docker auto     # the JSON a future cloud would get
#   sh diskvet.sh --help

NAME=diskvet
VERSION=0.2.1
BETA_URL='https://github.com/Protemir/diskvet#early-access'

# Git Bash on Windows rewrites arguments that look like /paths before they
# reach docker.exe; this turns that off. It has no effect anywhere else.
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

usage() {
    cat <<EOF
$NAME $VERSION: read-only check-up for ClickHouse (system tables only)

Usage:
  sh diskvet.sh report         [connection] [--ttl-days N]   Markdown report to stdout
  sh diskvet.sh --print-payload [connection] [--env FILE]    the exact JSON a snapshot would contain
  sh diskvet.sh push                                         not available yet

Connection (pick one):
  --docker auto               find the ClickHouse container (docker compose service
                              "clickhouse" in this folder, else by image clickhouse-server)
  --docker NAME               run clickhouse-client inside this container (docker exec -i)
  (nothing)                   use clickhouse-client on this machine
  --host H --port P           server address (inside the container when --docker is used)
  --user U --password P       ClickHouse user; with --docker and no --user, the container's
                              CLICKHOUSE_USER / CLICKHOUSE_PASSWORD are used if set

Other options:
  --ttl-days N                days of logs to keep in the generated TTL config (default 7)
  --env FILE                  file with SALT=... for name hashing (default /etc/$NAME.env)
  --checks FILE               checks.sql to use (default: next to this script)
  --save-raw FILE             also save the raw query results (for bug reports; local names inside)
  --replay FILE               render from a file saved with --save-raw, without a server
  --version, --help

Every query is in checks.sql: SELECT only, FROM system.* only (plus one probe,
SELECT getSetting('readonly')). Queries run with --readonly=2 and limits (30 s,
10000 rows, 2 threads, 500 MB). If the user's profile refuses the limits, they
run with --readonly=1 only; if the session can't be made read-only, nothing runs.
EOF
}

die() { printf '%s: %s\n' "$NAME" "$*" >&2; exit 2; }
note() { printf '%s: %s\n' "$NAME" "$*" >&2; }

# ---------------------------------------------------------------- arguments
cmd=report
docker_arg=""
host=""
port=""
user=""
password=""
env_file="/etc/$NAME.env"
ttl_days=7
checks_file=""
save_raw=""
replay=""

need_value() { [ "$2" -ge 2 ] || die "$1 needs a value (see --help)"; }

while [ $# -gt 0 ]; do
    case $1 in
        report) cmd=report ;;
        --print-payload|print-payload) cmd=payload ;;
        push|--push) cmd=push ;;
        --docker)   need_value "$1" $#; docker_arg=$2; shift ;;
        --docker=*) docker_arg=${1#*=} ;;
        --host)     need_value "$1" $#; host=$2; shift ;;
        --host=*)   host=${1#*=} ;;
        --port)     need_value "$1" $#; port=$2; shift ;;
        --port=*)   port=${1#*=} ;;
        --user)     need_value "$1" $#; user=$2; shift ;;
        --user=*)   user=${1#*=} ;;
        --password) need_value "$1" $#; password=$2; shift ;;
        --password=*) password=${1#*=} ;;
        --env)      need_value "$1" $#; env_file=$2; shift ;;
        --env=*)    env_file=${1#*=} ;;
        --ttl-days) need_value "$1" $#; ttl_days=$2; shift ;;
        --ttl-days=*) ttl_days=${1#*=} ;;
        --checks)   need_value "$1" $#; checks_file=$2; shift ;;
        --checks=*) checks_file=${1#*=} ;;
        --save-raw) need_value "$1" $#; save_raw=$2; shift ;;
        --save-raw=*) save_raw=${1#*=} ;;
        --replay)   need_value "$1" $#; replay=$2; shift ;;
        --replay=*) replay=${1#*=} ;;
        -h|--help|help) usage; exit 0 ;;
        -V|--version|version) printf '%s %s\n' "$NAME" "$VERSION"; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

if [ "$cmd" = push ]; then
    note "push is not available yet. Use 'report' for the local report or '--print-payload' to see what a snapshot would contain."
    exit 2
fi

case $ttl_days in
    ''|*[!0-9]*) die "--ttl-days must be a whole number of days" ;;
esac
[ "$ttl_days" -ge 1 ] || die "--ttl-days must be at least 1"

if [ -z "$checks_file" ]; then
    case $0 in
        */*) checks_file=${0%/*}/checks.sql ;;
        *)   checks_file=./checks.sql ;;
    esac
fi

# ---------------------------------------------------------------- temp dir
tmp=$(mktemp -d 2>/dev/null) || tmp=""
if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
    tmp=${TMPDIR:-/tmp}/$NAME.$$
    (umask 077 && mkdir "$tmp") || die "cannot create a temporary directory"
fi
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- helpers
# First useful line of a clickhouse-client / docker error, without noise.
err_line() {
    _l=$(sed -n '/Code: [0-9]/{s/.*\(Code: [0-9]\)/\1/;p;q;}' "$1" 2>/dev/null)
    [ -n "$_l" ] || _l=$(sed -n '/[^[:space:]]/{p;q;}' "$1" 2>/dev/null)
    printf '%s' "$_l" \
        | sed 's/DB::Exception: Received from [^ ]* //; s/DB::Exception: //g' \
        | tr '\t\r' '  ' | cut -c1-240
}

now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
now_human=$(date -u '+%Y-%m-%d %H:%M UTC')

unreachable_json() {
    printf '{"schema": 1, "agent": "%s/%s", "sent_at": "%s", "status": "ch_unreachable"}\n' \
        "$NAME" "$VERSION" "$now_iso"
}

# Inside the container: use the image's CLICKHOUSE_USER / CLICKHOUSE_PASSWORD
# when no user was given. The password stays inside the container.
# Single quotes on purpose: this runs inside the container, not here.
# shellcheck disable=SC2016
inner='m=$1; shift; if [ "$m" = env ]; then if [ -n "${CLICKHOUSE_PASSWORD:-}" ]; then set -- --password "$CLICKHOUSE_PASSWORD" "$@"; fi; if [ -n "${CLICKHOUSE_USER:-}" ]; then set -- --user "$CLICKHOUSE_USER" "$@"; fi; fi; exec clickhouse-client "$@"'

safe_flags="--readonly=2 --max_execution_time=30 --max_result_rows=10000 --result_overflow_mode=break --max_threads=2 --max_memory_usage=500000000 --log_comment=$NAME"
run_mode="Queries ran with readonly=2 and resource limits."
container=""
client=""

# run_query SQL_FILE OUT_FILE ERR_FILE [extra clickhouse-client args...]
run_query() {
    _in=$1; _out=$2; _err=$3; shift 3
    if [ -n "$password" ]; then set -- --password "$password" "$@"; fi
    if [ -n "$user" ]; then set -- --user "$user" "$@"; fi
    if [ -n "$port" ]; then set -- --port "$port" "$@"; fi
    if [ -n "$host" ]; then set -- --host "$host" "$@"; fi
    # $safe_flags is a list of --name=value words without spaces: split on purpose.
    # shellcheck disable=SC2086
    set -- $safe_flags --format=TSV "$@"
    if [ -n "$container" ]; then
        if [ -n "$user" ] || [ -n "$password" ]; then _m='explicit'; else _m='env'; fi
        docker exec -i "$container" sh -c "$inner" sh "$_m" "$@" <"$_in" >"$_out" 2>"$_err"
    else
        # $client may be "clickhouse client": split on purpose.
        # shellcheck disable=SC2086
        $client "$@" <"$_in" >"$_out" 2>"$_err"
    fi
}

find_container() {
    _id=""
    if docker compose version >/dev/null 2>&1; then
        _id=$(docker compose ps -q clickhouse 2>/dev/null | tr -d '\r' | sed -n '1p')
    fi
    if [ -z "$_id" ]; then
        _list=$(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null | tr -d '\r' \
            | awk '$2 ~ /(^|\/)clickhouse-server([:@]|$)/ { print $1, $3 }')
        _n=$(printf '%s\n' "$_list" | grep -c .)
        if [ "$_n" -eq 0 ]; then
            die "no running ClickHouse container found (looked for compose service 'clickhouse' here and for images named clickhouse-server). Pass --docker <container name>."
        fi
        if [ "$_n" -gt 1 ]; then
            die "found $_n ClickHouse containers: $(printf '%s\n' "$_list" | awk '{print $2}' | tr '\n' ' ')- pass --docker <container name>"
        fi
        _id=$(printf '%s\n' "$_list" | awk '{print $1}')
    fi
    container=$_id
}

# Salted hashes of your own database and table names, for --print-payload.
# The rows of the "tables" query go through `clickhouse local` (inside the
# container with --docker, else on this machine): the salt travels only on
# stdin, so it never reaches the server's query_log, text_log or log files,
# and never shows up in the process list. Columns 4 and 5 of each row come in
# as "keep this name" flags and go out as the name or its hash:
# db_ / t_ + 16 hex of sipHash64(salt, db) / sipHash64(salt, db, table).
hash_names() {
    _st='salt String, c1 String, db String, tbl String, keep_db UInt8, keep_tbl UInt8, c6 String, c7 String, c8 String, c9 String, c10 String, c11 String'
    _sql="SELECT c1, db, tbl,
        if(keep_db = 1, db, concat('db_', leftPad(lower(hex(sipHash64(salt, db))), 16, '0'))),
        if(keep_tbl = 1, tbl, concat('t_', leftPad(lower(hex(sipHash64(salt, db, tbl))), 16, '0'))),
        c6, c7, c8, c9, c10, c11
    FROM table"
    tr -d '\r' <"$tmp/o.tables" | while IFS= read -r _line; do printf '%s\t%s\n' "$salt" "$_line"; done >"$tmp/h.in"
    : >"$tmp/h.out"
    [ -s "$tmp/h.in" ] || return 0
    if [ -n "$container" ]; then
        docker exec -i -w /tmp "$container" clickhouse local --input-format TSV --output-format TSV \
            --structure "$_st" --query "$_sql" <"$tmp/h.in" >"$tmp/h.out" 2>"$tmp/h.err" || return 1
    else
        if command -v clickhouse-local >/dev/null 2>&1; then _local=clickhouse-local
        elif command -v clickhouse >/dev/null 2>&1; then _local="clickhouse local"
        else printf 'clickhouse-local not found (needed to hash names on this machine)\n' >"$tmp/h.err"; return 1
        fi
        # From the temp dir, so a config.xml in the current folder is not picked up.
        # $_local may be "clickhouse local": split on purpose.
        # shellcheck disable=SC2086
        (cd "$tmp" && $_local --input-format TSV --output-format TSV \
            --structure "$_st" --query "$_sql" <"$tmp/h.in" >"$tmp/h.out" 2>"$tmp/h.err") || return 1
    fi
    # every row must come back, with the names replaced
    [ "$(grep -c . "$tmp/h.in")" = "$(tr -d '\r' <"$tmp/h.out" | grep -c .)" ] || {
        printf 'clickhouse local returned a different number of rows\n' >>"$tmp/h.err"; return 1; }
}

# ---------------------------------------------------------------- run the checks
stream=$tmp/stream.tsv
container_name=""

if [ -n "$replay" ]; then
    [ -r "$replay" ] || die "cannot read $replay"
    cp "$replay" "$stream" || die "cannot read $replay"
    container_name=$docker_arg
    [ "$container_name" = auto ] && container_name=clickhouse
    run_mode="Rendered from saved query results (--replay)."
else
    [ -r "$checks_file" ] || die "cannot read $checks_file (keep checks.sql next to the script or pass --checks FILE)"

    if [ -n "$docker_arg" ]; then
        command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
        if [ "$docker_arg" = auto ]; then find_container; else container=$docker_arg; fi
        container_name=$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null | tr -d '\r' | sed 's|^/||')
        [ -n "$container_name" ] || {
            [ "$cmd" = payload ] && unreachable_json
            die "container '$container' not found (docker inspect failed)"
        }
    else
        if command -v clickhouse-client >/dev/null 2>&1; then
            client=clickhouse-client
        elif command -v clickhouse >/dev/null 2>&1; then
            client="clickhouse client"
        else
            die "clickhouse-client not found. Use --docker auto, or install clickhouse-client."
        fi
    fi

    # Split checks.sql into one file per query; the index keeps the order.
    awk -v dir="$tmp" '
        { sub(/\r$/, "") }
        /^-- @query / {
            if (f != "") close(f)
            if ($3 !~ /^[a-z0-9_]+$/) { bad = 1; exit 1 }
            f = dir "/q." $3
            print $3, $4 > (dir "/index")
            next
        }
        f != "" { print > f }
        END { if (bad) exit 1 }
    ' "$checks_file" || die "cannot parse $checks_file"
    [ -s "$tmp/index" ] || die "no queries found in $checks_file"

    # Probe (the only query that is not in checks.sql): can we connect, and is
    # the session really read-only? Try readonly=2 with the limits; if the
    # user's profile refuses extra settings (readonly=1 profile, or constraints
    # on the limits), readonly=1 alone; else no flags, but only if the profile
    # itself is read-only.
    printf "SELECT getSetting('readonly')\n" >"$tmp/probe.sql"
    probe() {
        ro=""
        run_query "$tmp/probe.sql" "$tmp/probe.out" "$tmp/probe.err" || return 1
        ro=$(tr -d '\r\n\t ' <"$tmp/probe.out")
    }
    refused() { grep -Eq 'Code: (164|452)|READONLY|SETTING_CONSTRAINT_VIOLATION' "$tmp/probe.err"; }
    cannot_run() {
        [ "$cmd" = payload ] && unreachable_json
        note "cannot run queries: $*"
        exit 3
    }
    if probe; then
        [ "$ro" = 2 ] || cannot_run "readonly=2 did not take effect (the server reports readonly=$ro), so nothing was run"
    elif refused; then
        safe_flags="--readonly=1"
        if probe; then
            [ "$ro" = 1 ] || cannot_run "readonly=1 did not take effect (the server reports readonly=$ro), so nothing was run"
            run_mode="Queries ran with readonly=1. The server refused the limit flags for this user (read-only profile or setting constraints), so the user's own limits apply."
            note "the server refused the limit flags for this user: running with --readonly=1 only, the user's own limits apply"
        elif refused; then
            safe_flags=""
            if probe; then
                case $ro in
                    1|2) run_mode="Queries ran under the user's read-only profile (readonly=$ro). The server refused extra settings, so the profile's own limits apply."
                         note "the server refused all extra settings for this user: running under its read-only profile (readonly=$ro)" ;;
                    *)   cannot_run "the server refuses readonly=2 and readonly=1 for this user, and the user is not read-only, so nothing was run. Use a read-only user (README, variant B)." ;;
                esac
            else
                cannot_run "$(err_line "$tmp/probe.err")"
            fi
        else
            cannot_run "$(err_line "$tmp/probe.err")"
        fi
    else
        cannot_run "$(err_line "$tmp/probe.err")"
    fi

    salt=""
    if [ "$cmd" = payload ]; then
        if [ -r "$env_file" ]; then
            salt=$(sed -n 's/^[[:space:]]*SALT[[:space:]]*=[[:space:]]*//p' "$env_file" | sed -n '1p' | tr -d "\"' \r")
        fi
        if [ -n "$salt" ]; then
            case $salt in
                *[!0-9A-Za-z_-]*) die "SALT in $env_file may contain only letters, digits, '_' and '-'" ;;
            esac
            [ "${#salt}" -ge 32 ] || die "SALT in $env_file is too short (${#salt} characters, need at least 32; 64 random hex characters are best, see README)"
        else
            salt=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
            [ -n "$salt" ] || die "cannot read /dev/urandom for a salt"
            note "no SALT= in $env_file: using a one-time random salt. Hashed names (db_..., t_...) will differ on every run."
        fi
    fi

    : >"$stream"
    while read -r qid qtag; do
        [ -n "$qid" ] || continue
        if [ "$qtag" = payload ] && [ "$cmd" != payload ]; then continue; fi
        if run_query "$tmp/q.$qid" "$tmp/o.$qid" "$tmp/e.$qid"; then
            if [ "$qid" = tables ]; then
                # never let a real name through: without hashes the rows are dropped
                if hash_names; then
                    printf '@@\t%s\tok\n' "$qid" >>"$stream"
                    tr -d '\r' <"$tmp/h.out" >>"$stream"
                else
                    printf '@@\t%s\tfail\t%s\t%s\n' "$qid" "${qtag:-required}" "cannot hash table names: $(err_line "$tmp/h.err")" >>"$stream"
                    note "cannot hash table names, so the payload has no tables: $(err_line "$tmp/h.err")"
                fi
                continue
            fi
            printf '@@\t%s\tok\n' "$qid" >>"$stream"
            tr -d '\r' <"$tmp/o.$qid" >>"$stream"
        else
            printf '@@\t%s\tfail\t%s\t%s\n' "$qid" "${qtag:-required}" "$(err_line "$tmp/e.$qid")" >>"$stream"
        fi
    done <"$tmp/index"
fi

if [ -n "$save_raw" ]; then
    cp "$stream" "$save_raw" || note "cannot write $save_raw"
fi

# ---------------------------------------------------------------- render
cat >"$tmp/render.awk" <<'__RENDER_AWK__'
# Renders the query results (one stream, "@@" lines mark each query) into the
# Markdown report or the JSON payload. POSIX awk: works in gawk, mawk, busybox.
BEGIN {
    FS = "\t"
    KiB = 1024; MiB = 1048576; GiB = 1073741824; TiB = 1099511627776
    RANK["NOT_RUN"] = 0; RANK["OK"] = 1; RANK["INFO"] = 2; RANK["WARN"] = 3; RANK["CRITICAL"] = 4
    T[1] = "System logs without TTL"
    T[2] = "Disk space not in ClickHouse table parts"
    T[3] = "Disk usage and rough forecast"
    T[4] = "Growth per day"
    T[5] = "Too many parts"
    T[6] = "Inactive and detached parts"
    T[7] = "Deleted rows and stuck mutations"
}
{ sub(/\r$/, "") }
/^@@\t/ {
    q = $2
    qstat[q] = $3
    if ($3 == "fail") { qtag[q] = $4; qerr[q] = $5 }
    if (!(q in seen)) { seen[q] = 1; qorder[++nq] = q }
    next
}
$0 != "" { q = $1; n[q]++; row[q, n[q]] = $0 }
END {
    context()
    if (mode == "payload") payload(); else report()
}

# ---------------------------------------------------------------- helpers
function isnum(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/ }
function isint(x) { return x ~ /^[0-9]+$/ }
function num(x) { return isnum(x) ? x + 0 : 0 }
function ok(q) { return qstat[q] == "ok" }
function worse(a, b) { return (RANK[b] > RANK[a]) ? b : a }
function pct(a, b) { return (b > 0) ? 100 * a / b : 0 }
function fpct(p) { return (p >= 10 || p == 0) ? sprintf("%.0f%%", p) : sprintf("%.1f%%", p) }
function i0(x) { return sprintf("%.0f", x) }
function hs(b) {
    b = b + 0
    if (b >= TiB) return sprintf("%.1f TiB", b / TiB)
    if (b >= GiB) return sprintf("%.1f GiB", b / GiB)
    if (b >= MiB) return sprintf("%.1f MiB", b / MiB)
    if (b >= KiB) return sprintf("%.1f KiB", b / KiB)
    return sprintf("%.0f B", b)
}
function hn(x) {
    x = x + 0
    if (x >= 1e9) return sprintf("%.1fB", x / 1e9)
    if (x >= 1e6) return sprintf("%.1fM", x / 1e6)
    if (x >= 1e4) return sprintf("%.1fk", x / 1e3)
    return sprintf("%.0f", x)
}
function hage(m) {
    m = m + 0
    if (m >= 2880) return sprintf("%.0f d", m / 1440)
    if (m >= 120) return sprintf("%.0f h", m / 60)
    return sprintf("%.0f min", m)
}
function cell(s) { gsub(/\|/, "\\|", s); return s }
function notrun(q) { return "Could not run: " qerr[q] "\n" }
# Values arrive TSV-escaped (\\ \' \t \n ...). ClickHouse reads the same escapes
# inside 'strings' and `identifiers`, so they are kept as they are; only a
# character TSV does not escape needs it: ' (never raw in TSV) and `.
function bsq(s, q,   out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") { out = out substr(s, i, 2); i++; continue }   # an escape: keep both characters
        if (c == q) out = out "\\"
        out = out c
    }
    return out
}
function sq(s) { return bsq(s, "'") }
function ident(s) {
    # quote a database/table name for SQL when it is not a plain identifier
    if (s ~ /^[A-Za-z_][A-Za-z0-9_]*$/) return s
    return "`" bsq(s, "`") "`"
}
function fq(db, t) { return ident(db) "." ident(t) }
function shcmd(s) {
    if (ctr != "") return "docker exec " ctr " sh -c '" s "'"
    return "sudo sh -c '" s "'"
}
function jstr(s) { gsub(/[^A-Za-z0-9_.:\/+-]/, "_", s); return "\"" s "\"" }
function jint(x) { return isint(x) ? x : "0" }

# Data disk, drop limit, version, product: used by several checks.
function context(   i, f, best) {
    ver = ""; product = "other"; product_bytes = 0; syslog_bytes = 0; y9999 = 0
    if (ok("passport") && n["passport"] > 0) {
        split(row["passport", 1], f, "\t")
        ver = f[2]; uptime = f[3]; product = f[4]; replicated = f[5]
        product_bytes = num(f[6]); syslog_bytes = num(f[7]); y9999 = num(f[8])
    }
    split(ver, vp, ".")
    vmaj = vp[1] + 0; vmin = vp[2] + 0
    PRODUCT_LABEL["langfuse"] = "Langfuse"; PRODUCT_LABEL["signoz"] = "SigNoz"
    PRODUCT_LABEL["clickstack"] = "ClickStack"; PRODUCT_LABEL["other"] = "other"
    plabel = (product in PRODUCT_LABEL) ? PRODUCT_LABEL[product] : "other"
    dlabel = (product == "other") ? "your" : plabel

    drop_limit = 50000000000; drop_known = 0
    if (ok("drop_limit") && n["drop_limit"] > 0) {
        split(row["drop_limit", 1], f, "\t")
        if (isint(f[3])) { drop_limit = f[3] + 0; drop_known = 1 }
    }
    dd_name = ""; dd_total = 0; dd_free = 0; dd_path = "/var/lib/clickhouse/"
    if (ok("disk_now")) {
        best = 0
        for (i = 1; i <= n["disk_now"]; i++) {
            split(row["disk_now", i], f, "\t")
            if (f[2] == "default" || best == 0) {
                best = i; dd_name = f[2]; dd_path = f[3]; dd_total = num(f[4]); dd_free = num(f[5])
                if (f[2] == "default") break
            }
        }
    }
    if (dd_path !~ /\/$/) dd_path = dd_path "/"
    flag_path = dd_path "flags/force_drop_table"
}

function limit_text(   s) {
    s = (drop_limit == 50000000000) ? "50 GB" : hs(drop_limit)
    if (!drop_known) s = s ", the default: this user can't read system.server_settings"
    return s
}

# SQL (and the one-time flag when needed) to TRUNCATE or DROP one table.
function drop_block(verb, fqname, bytes,   s) {
    if (drop_limit > 0 && bytes > 0.95 * drop_limit) {
        if (bytes > drop_limit) {
            s = fqname " (" hs(bytes) ") is over the drop limit (max_table_size_to_drop = " limit_text() ")"
            s = s ", so ClickHouse refuses a plain " verb "."
        } else {
            s = fqname " (" hs(bytes) ") is close to the drop limit (max_table_size_to_drop = " limit_text() ")"
            s = s " and may pass it by the time you run " verb "."
        }
        s = s " Create the one-time flag right before it"
        s = s " (the first " verb " that needs the flag uses it up; create it again before the next big table):\n"
        s = s "```sh\n" shcmd("touch " flag_path " && chmod 666 " flag_path) "\n```\n"
        s = s "```sql\n" verb " TABLE " fqname ";\n```\n"
        if (vmaj == 0 || vmaj >= 24)
            s = s "Or, on ClickHouse 24.1 and newer, without the flag: `" verb " TABLE " fqname " SETTINGS max_table_size_to_drop = 0;`\n"
        return s
    }
    return ""
}

# ---------------------------------------------------------------- check 1
function check1(   i, f, name, is_old, has_ttl, tdays, b, rows, od, dcol, pexpr, sexpr, dtot,
                   p, rs, why, shown, hidden, hidden_b, tbl, nottl_n, nottl_b, copies_n, copies_b,
                   small, big, xml, drops, dropbig, oldttl, s, total_b, biggest, ttlcell, agecell) {
    if (!ok("system_logs")) { st[1] = "NOT_RUN"; body[1] = notrun("system_logs"); return }
    st[1] = "OK"
    tbl = "| Table | Size | Rows | TTL | Oldest row | Status |\n|---|---|---|---|---|---|\n"
    shown = 0; hidden = 0; hidden_b = 0; nottl_n = 0; nottl_b = 0; copies_n = 0; copies_b = 0
    small = ""; big = ""; xml = ""; drops = ""; dropbig = ""; oldttl = ""; total_b = 0; biggest = ""
    for (i = 1; i <= n["system_logs"]; i++) {
        split(row["system_logs", i], f, "\t")
        name = f[2]; is_old = f[3] + 0; has_ttl = f[4] + 0; tdays = f[5] + 0; b = num(f[6])
        rows = num(f[7]); od = f[8] + 0; dcol = f[9]; pexpr = f[10]; sexpr = f[11]; dtot = num(f[12])
        if (dtot == 0) dtot = dd_total
        p = pct(b, dtot); rs = "OK"; why = ""
        total_b += b
        if (biggest == "" && b > 0 && !is_old) biggest = name
        if (is_old) {
            copies_n++; copies_b += b
            rs = (b >= GiB) ? "WARN" : "INFO"
            # a copy over the drop limit gets its own block with the flag, not a plain DROP
            if (drop_limit > 0 && b > 0.95 * drop_limit) dropbig = dropbig drop_block("DROP", "system." name, b)
            else drops = drops "DROP TABLE system." name ";\n"
        } else if (!has_ttl) {
            nottl_n++; nottl_b += b
            if (b >= 10 * GiB || p >= 15) rs = "CRITICAL"
            else if (b >= GiB || p >= 5) rs = "WARN"
            else if (b >= 100 * MiB) rs = "INFO"
            if (rs != "OK") {
                if (drop_limit > 0 && b > 0.95 * drop_limit) big = big drop_block("TRUNCATE", "system." name, b)
                else small = small "TRUNCATE TABLE system." name ";\n"
            }
            if (name == "opentelemetry_span_log") {
                xml = xml "    <" name ">\n"
                xml = xml "        <!-- the default config sets an engine for this log, so its TTL goes inside the engine -->\n"
                xml = xml "        <engine>ENGINE = MergeTree"
                if (pexpr != "") xml = xml " PARTITION BY " pexpr
                xml = xml " ORDER BY (" sexpr ") TTL " dcol " + INTERVAL " ttl_days " DAY DELETE</engine>\n"
                xml = xml "    </" name ">\n"
            } else {
                xml = xml "    <" name ">\n        <ttl>" dcol " + INTERVAL " ttl_days " DAY DELETE</ttl>\n    </" name ">\n"
            }
        } else if (tdays > 0 && od > tdays + 2) {
            rs = "WARN"
            oldttl = oldttl "- system." name ": TTL " tdays " d, but the oldest row is " od " d old.\n"
        }
        st[1] = worse(st[1], rs)
        ttlcell = has_ttl ? ((tdays > 0) ? tdays " d" : "yes") : "none"
        if (is_old) ttlcell = "old copy"
        agecell = (od > 0) ? od " d" : ((b > 0 && dcol != "" && pexpr != "") ? "today" : "-")
        if ((rs != "OK" || b >= MiB) && shown < 12) {
            shown++
            tbl = tbl "| system." cell(name) " | " hs(b) " | " hn(rows) " | " ttlcell " | " agecell " | " rs " |\n"
        } else { hidden++; hidden_b += b }
    }
    s = hs(syslog_bytes) " of ClickHouse's own logs vs " hs(product_bytes) " of " dlabel " data. "
    s = s nottl_n " logs have no TTL (" hs(nottl_b) " together)."
    if (copies_n > 0) s = s " " copies_n "" ((copies_n == 1) ? " old copy" : " old copies") " (*_log_N, left after upgrades or config changes): " hs(copies_b) "."
    s = s "\n\n" tbl
    if (hidden > 0) s = s "\nAnd " hidden " smaller logs, " hs(hidden_b) " together.\n"
    if (small != "" || big != "") {
        s = s "\n**Fix A: free space now.** Safe for your data, no restart: it deletes only ClickHouse's own log rows.\n"
        if (small != "") s = s "```sql\n" small "```\n"
        s = s big
        if (!drop_known) {
            s = s "The drop limit is unknown (max_table_size_to_drop: " limit_text() "). If a TRUNCATE fails with Code 359,"
            s = s " add `SETTINGS max_table_size_to_drop = 0` to it (ClickHouse 24.1+), or create the one-time flag first: `"
            s = s shcmd("touch " flag_path " && chmod 666 " flag_path) "`\n"
        }
    }
    if (xml != "") {
        s = s "\n**Fix B: stop it coming back.** Safe; needs a ClickHouse restart (about 10 s). Keeps " ttl_days " days of each log (change with --ttl-days).\n"
        s = s "Save as `clickhouse-ttl.xml` (only logs without TTL are listed):\n"
        s = s "```xml\n<clickhouse>\n    <!-- " name_ver ": TTL for system logs that had none -->\n" xml "</clickhouse>\n```\n"
        s = s "Docker compose: mount it into the ClickHouse service, then recreate it with `docker compose up -d clickhouse`:\n"
        s = s "```yaml\n    volumes:\n      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro\n```\n"
        s = s "Without Docker: copy it to `/etc/clickhouse-server/config.d/` and run `sudo systemctl restart clickhouse-server`.\n\n"
        s = s "On restart ClickHouse renames every changed log to `<name>_0` (its old rows stay there) and starts a new table with the TTL."
        s = s " Do Fix A first so these copies are small, then run this report again: it lists the copies to drop.\n"
        s = s "If ClickHouse does not start and its log says `TTL parameters should be specified directly inside 'engine'`,"
        s = s " your config defines that log with `<engine>`: put the TTL inside that `<engine>` (like opentelemetry_span_log above) or remove the log from this file.\n"
    }
    if (drops != "" || dropbig != "") {
        s = s "\n**Fix C: drop old copies.** Irreversible, safe for your data: ClickHouse no longer writes to these tables.\n"
        if (drops != "") s = s "```sql\n" drops "```\n"
        s = s dropbig
    }
    if (oldttl != "") {
        s = s "\n**TTL is set but old rows are still there.** ClickHouse removes expired rows during merges (by default at most every 4 h, merge_with_ttl_timeout).\n"
        s = s oldttl "If it stays like this for a day, force it (heavy: rewrites the table): `ALTER TABLE system.<log> MATERIALIZE TTL;`\n"
    }
    body[1] = s
    top_log = biggest
}

# ---------------------------------------------------------------- check 2
function check2(   i, f, s, total, free, parts, inact, det, used, inparts, notin, p, freep, rs, tbl, one) {
    if (!ok("not_in_parts")) { st[2] = "NOT_RUN"; body[2] = notrun("not_in_parts"); return }
    st[2] = "OK"; s = ""
    tbl = "| Disk | Size | Used | In table parts | Not in table parts | Status |\n|---|---|---|---|---|---|\n"
    for (i = 1; i <= n["not_in_parts"]; i++) {
        split(row["not_in_parts", i], f, "\t")
        total = num(f[3]); free = num(f[4]); parts = num(f[5]); inact = num(f[6]); det = num(f[7])
        used = total - free; inparts = parts + det; notin = used - inparts
        if (notin < 0) notin = 0
        p = pct(notin, total); freep = pct(free, total); rs = "OK"
        if (p >= 30 && freep < 20) rs = "CRITICAL"
        else if (p >= 20 && notin >= 10 * GiB) rs = "WARN"
        st[2] = worse(st[2], rs)
        tbl = tbl "| " cell(f[2]) " | " hs(total) " | " hs(used) " | " hs(inparts) " | " hs(notin) " (" fpct(p) ") | " rs " |\n"
        one = "Disk " f[2] ": " hs(total) ", used " hs(used) ". ClickHouse table parts: " hs(inparts)
        one = one " (inactive " hs(inact) ", detached " hs(det) ").\n"
        one = one "Not in table parts: " hs(notin) " (" fpct(p) " of the disk): Docker logs and images, other services (MinIO, Postgres), OS files,"
        one = one " and the blocks the file system reserves for root (often 5% on ext4). The script can't see which.\n"
    }
    if (n["not_in_parts"] == 1) s = one; else s = tbl
    if (RANK[st[2]] >= RANK["WARN"]) {
        s = s "\nMost common cause: Docker container logs without rotation (langfuse#16339: 89.1 GiB)."
        s = s " See what takes the space (on the server):\n"
        s = s "```sh\nsudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'\nsudo du -xh --max-depth=2 / 2>/dev/null | sort -h | tail -15\n```\n"
        s = s "\n**Fix: rotate Docker logs.** Safe; recreates the containers (about 30 s of downtime).\n"
        s = s "In `docker-compose.yml`, for every service (or once in the Docker daemon config `/etc/docker/daemon.json`: `{\"log-driver\": \"json-file\", \"log-opts\": {\"max-size\": \"50m\", \"max-file\": \"3\"}}` and `sudo systemctl restart docker`):\n"
        s = s "```yaml\n    logging:\n      driver: json-file\n      options:\n        max-size: \"50m\"\n        max-file: \"3\"\n```\n"
        s = s "Then `docker compose up -d --force-recreate`: log settings apply only to recreated containers."
        s = s " Recreating a container also removes its old log file and frees the space (in langfuse#16339 this gave back 81 GiB)."
        s = s " Don't truncate or rotate Docker's `*-json.log` files with outside tools: Docker owns them (Langfuse's self-hosting README says the same).\n"
    } else {
        s = s "\nIf this part grows, the usual cause is Docker container logs without rotation (langfuse#16339).\n"
    }
    body[2] = s
}

# ---------------------------------------------------------------- check 3
function check3(   i, f, src, hdisk, hspan, hgrow, total, free, used, up, rs, fc, dl, fctext, s, tbl, note) {
    if (!ok("disk_now")) { st[3] = "NOT_RUN"; body[3] = notrun("disk_now"); return }
    src = ""
    if (ok("disk_history_kv") && n["disk_history_kv"] > 0) src = "disk_history_kv"
    else if (ok("disk_history") && n["disk_history"] > 0) src = "disk_history"
    if (src != "") {
        for (i = 1; i <= n[src]; i++) {
            split(row[src, i], f, "\t")
            hspan[f[2]] = f[4] + 0; hgrow[f[2]] = f[5]
        }
    }
    st[3] = "OK"; note = ""
    tbl = "| Disk | Size | Used | Free | Rough forecast | Status |\n|---|---|---|---|---|---|\n"
    for (i = 1; i <= n["disk_now"]; i++) {
        split(row["disk_now", i], f, "\t")
        total = num(f[4]); free = num(f[5]); used = total - free; up = pct(used, total)
        fc = 0; fctext = "-"
        if (f[2] in hspan) {
            if (hspan[f[2]] < 72) {
                fctext = "needs 72 h of history, has " hspan[f[2]] " h"
            } else if (!isnum(hgrow[f[2]]) || hgrow[f[2]] + 0 <= 0) {
                fctext = "not growing (last " sprintf("%.1f", hspan[f[2]] / 24) " days)"
            } else {
                fc = 1; dl = (0.95 * total - used) / (hgrow[f[2]] + 0)
                if (dl < 0) dl = 0
                fctext = "+" hs(hgrow[f[2]]) "/day: 95% full in ~" sprintf("%.0f", dl) " days"
                note = "Forecast: straight line through the hourly maximum of ClickHouse's own disk metric (system.asynchronous_metric_log) over the last " sprintf("%.1f", hspan[f[2]] / 24) " days. A spike or a cleanup in that window skews it."
            }
        } else if (src == "" && !(ok("disk_history") || ok("disk_history_kv"))) {
            fctext = "no data (system.asynchronous_metric_log not readable)"
        } else {
            fctext = "no disk metrics in system.asynchronous_metric_log"
        }
        rs = "OK"
        if (up >= 90 || free < 5 * GiB || (fc && dl <= 7)) rs = "CRITICAL"
        else if (up >= 80 || (fc && dl <= 14)) rs = "WARN"
        st[3] = worse(st[3], rs)
        tbl = tbl "| " cell(f[2]) " | " hs(total) " | " fpct(up) " | " hs(free) " | " fctext " | " rs " |\n"
    }
    s = tbl
    if (note != "") s = s "\n" note "\n"
    s = s "\nA real forecast needs hourly history: one run of this script sees only one moment.\n"
    if (RANK[st[3]] >= RANK["WARN"]) {
        s = s "\nWhere to get space back fastest: check 1 (system logs), check 2 (Docker logs), check 7 (deleted rows).\n"
    }
    body[3] = s
}

# ---------------------------------------------------------------- check 4
function check4(   src, i, f, b, p, rs, tbl, shown, total, s, has_sys) {
    src = ""
    if (ok("growth_24h")) src = "growth_24h"
    else if (ok("growth_parts")) src = "growth_parts"
    if (src == "") { st[4] = "NOT_RUN"; body[4] = notrun("growth_24h"); return }
    st[4] = "OK"; total = 0; shown = 0; has_sys = 0
    tbl = "| Table | Written in 24 h | New parts | Share of free space | Status |\n|---|---|---|---|---|\n"
    for (i = 1; i <= n[src]; i++) {
        split(row[src, i], f, "\t")
        b = num(f[4]); total += b
        if (f[2] == "system") has_sys = 1
        rs = "OK"
        if (dd_total > 0) {
            p = pct(b, dd_free)
            if (p >= 15) rs = "CRITICAL"
            else if (p >= 5) rs = "WARN"
        }
        st[4] = worse(st[4], rs)
        if (shown < 8) {
            shown++
            tbl = tbl "| " cell(f[2] "." f[3]) " | " hs(b) " | " hn(f[5]) " | " ((dd_total > 0) ? fpct(p) : "?") " | " rs " |\n"
        }
    }
    if (src == "growth_24h") s = "Written in the last 24 h: " hs(total) " (new parts before merges, from system.part_log)."
    else s = "system.part_log is not available, so this is a rough estimate: active parts changed in the last 24 h, " hs(total) " (merges count too, so it overestimates)."
    if (dd_total > 0) s = s " Free on disk " dd_name ": " hs(dd_free) "."
    s = s "\n\n"
    if (n[src] > 0) s = s tbl; else s = s "Nothing was written in the last 24 h.\n"
    if (src == "growth_24h" && !has_sys && vmaj > 0 && vmaj < 25)
        s = s "\nClickHouse " vmaj "." vmin " does not record system tables in part_log, so ClickHouse's own logs are missing here (see check 1).\n"
    if (RANK[st[4]] >= RANK["WARN"])
        s = s "\nIf the top tables are system.* logs, check 1 fixes it. If they are " dlabel " tables, check the retention settings of " dlabel " itself.\n"
    body[4] = s
}

# ---------------------------------------------------------------- check 5
function check5(   i, f, parts, delay, thr, rs, tbl, shown, maxp, maxw, s, sdelay, sthrow, delayed, rejected, fixes, opt, pids) {
    if (!ok("too_many_parts")) { st[5] = "NOT_RUN"; body[5] = notrun("too_many_parts"); return }
    st[5] = "OK"; shown = 0; maxp = 0; maxw = ""; sdelay = 0; sthrow = 0; delayed = 0; rejected = 0; fixes = ""; opt = ""
    tbl = "| Table | Partition | Active parts | Slow down at | Fail at | Status |\n|---|---|---|---|---|---|\n"
    for (i = 1; i <= n["too_many_parts"]; i++) {
        split(row["too_many_parts", i], f, "\t")
        if (f[2] == "server") {
            srv_maxpc = num(f[6]); sdelay = num(f[7]); sthrow = num(f[8]); delayed = num(f[9]); rejected = num(f[10])
            continue
        }
        parts = num(f[6]); delay = num(f[7]); thr = num(f[8])
        rs = "OK"
        if (delay > 0 && parts >= delay) rs = "CRITICAL"
        else if (parts >= 300) rs = "WARN"
        st[5] = worse(st[5], rs)
        if (parts > maxp) { maxp = parts; maxw = f[3] "." f[4] ", partition " f[5] }
        if ((rs != "OK" || shown < 3) && shown < 10) {
            shown++
            tbl = tbl "| " cell(f[3] "." f[4]) " | " cell(f[5]) " | " parts " | " delay " | " thr " | " rs " |\n"
        }
        if (rs != "OK" && !((f[3] SUBSEP f[4]) in pids)) {
            pids[f[3], f[4]] = 1
            fixes = fixes "SYSTEM START MERGES " fq(f[3], f[4]) ";\n"
            opt = opt "OPTIMIZE TABLE " fq(f[3], f[4]) " PARTITION ID '" sq(f[5]) "' FINAL;\n"
        }
    }
    if (rejected > 0) st[5] = worse(st[5], "WARN")
    # busybox awk reads "name (" as a function call, so no "(" right after a variable
    s = "Most active parts in one partition: " maxp
    if (maxw != "") s = s " (" maxw ")"
    s = s "."
    s = s " By default inserts slow down at " sdelay " parts per partition and fail at " sthrow " (table SETTINGS can change this).\n"
    s = s "Since the server started: " delayed " inserts delayed, " rejected " rejected (Too many parts).\n\n" tbl
    if (fixes != "") {
        s = s "\n**What to do.** See whether merges run: `SELECT database, table, round(elapsed) AS sec, round(progress, 2) AS progress, num_parts FROM system.merges;`\n"
        s = s "If someone stopped merges (SYSTEM STOP MERGES), start them again. Safe:\n```sql\n" fixes "```\n"
        s = s "Many small inserts are the usual cause: send fewer, bigger INSERTs, or turn on `async_insert=1` for the writer.\n"
        s = s "To merge a partition now (heavy: rewrites it and needs free space about its size; avoid busy hours):\n```sql\n" opt "```\n"
    }
    body[5] = s
}

# ---------------------------------------------------------------- check 6
function check6(   i, f, s, tbl, ip, ib, sp, sb, dp, db, rs, cmds, nm, k, j, names, stuckinfo) {
    if (!ok("inactive_parts")) { st[6] = "NOT_RUN"; body[6] = notrun("inactive_parts"); return }
    st[6] = "OK"; ip = 0; ib = 0; sp = 0; sb = 0; dp = 0; db = 0; cmds = ""; stuckinfo = ""
    tbl = "| Table | Kind | Parts | Size | Details | Status |\n|---|---|---|---|---|---|\n"
    for (i = 1; i <= n["inactive_parts"]; i++) {
        split(row["inactive_parts", i], f, "\t")
        if (f[2] == "inactive") {
            ip += num(f[5]); ib += num(f[6]); sp += num(f[7]); sb += num(f[8])
            if (num(f[7]) > 0) {
                rs = (num(f[8]) >= 10 * GiB) ? "CRITICAL" : "WARN"
                tbl = tbl "| " cell(f[3] "." f[4]) " | inactive, stuck > 1 h | " f[7] " | " hs(f[8]) " | " cell(f[10]) " | " rs " |\n"
                stuckinfo = stuckinfo "SELECT name, refcount, removal_state FROM system.parts WHERE NOT active AND database = '" sq(f[3]) "' AND table = '" sq(f[4]) "' LIMIT 20;\n"
            }
        } else {
            dp += num(f[5]); db += num(f[6])
            rs = (num(f[6]) >= GiB) ? "WARN" : "INFO"
            tbl = tbl "| " cell(f[3] "." f[4]) " | detached | " f[5] " | " hs(f[6]) " | " cell(f[10]) " | " rs " |\n"
            k = split(f[11], names, " ")
            for (j = 1; j <= k; j++) {
                cmds = cmds "-- ALTER TABLE " fq(f[3], f[4]) " ATTACH PART '" sq(names[j]) "';\n"
                cmds = cmds "ALTER TABLE " fq(f[3], f[4]) " DROP DETACHED PART '" sq(names[j]) "' SETTINGS allow_drop_detached = 1;\n"
            }
            if (num(f[5]) > k) cmds = cmds "-- ...and " (num(f[5]) - k) " more parts of this table: see system.detached_parts\n"
        }
    }
    if (sp > 0) st[6] = worse(st[6], (sb >= 10 * GiB) ? "CRITICAL" : "WARN")
    if (dp > 0) st[6] = worse(st[6], (db >= GiB) ? "WARN" : "INFO")
    s = "Inactive parts (already merged, waiting to be deleted): " ip " parts, " hs(ib) ". Stuck for more than 1 hour: "
    s = s "" ((sp > 0) ? sp " parts, " hs(sb) : "none") ". ClickHouse normally deletes them within minutes (old_parts_lifetime, 8 min by default).\n"
    s = s "Detached parts (not used by queries, still on disk): " ((dp > 0) ? dp " parts, " hs(db) : "none") ".\n"
    if (sp > 0 || dp > 0) s = s "\n" tbl
    if (sp > 0) {
        s = s "\n**Stuck inactive parts.** Usually a long query or a backup holds them. Look:\n```sql\n"
        s = s "SELECT query_id, user, round(elapsed) AS sec FROM system.processes ORDER BY elapsed DESC LIMIT 5;\n" stuckinfo "```\n"
        s = s "When nothing holds them any more, ClickHouse deletes them; a ClickHouse restart also does.\n"
    }
    if (dp > 0) {
        s = s "\n**Detached parts.** ClickHouse detaches broken parts itself (reason broken, unexpected, noquorum, ...); \"detached by user\" came from ALTER TABLE ... DETACH."
        s = s " Look first: `SELECT database, table, name, reason, formatReadableSize(bytes_on_disk) FROM system.detached_parts;`\n"
        s = s "Bring a part back only if you know it is valid (the commented ATTACH lines). The DROP lines delete it from disk. Irreversible:\n"
        s = s "```sql\n" cmds "```\n"
    }
    body[6] = s
}

# ---------------------------------------------------------------- check 7
function check7(   i, f, key, s, tbl, lt, tb, lp, pl, np, order, no, share, rs, fixes, mt, m, mrs, kills, anyok, partial, j) {
    if (!ok("deleted_rows") && !ok("mutations")) {
        st[7] = "NOT_RUN"; body[7] = notrun("deleted_rows"); return
    }
    st[7] = "OK"; s = ""; fixes = ""; kills = ""; no = 0; partial = ""
    if (ok("deleted_rows")) {
        for (i = 1; i <= n["deleted_rows"]; i++) {
            split(row["deleted_rows", i], f, "\t")
            key = f[2] SUBSEP f[3]
            if (!(key in lt)) { order[++no] = key; lt[key] = 0; lp[key] = 0; np[key] = 0; tdb[key] = f[2]; ttb[key] = f[3] }
            lt[key] += num(f[6]); lp[key] += num(f[5]); tb[key] = num(f[7])
            if (np[key] < 10) { np[key]++; pl[key, np[key]] = f[4] }
        }
        if (no > 0) {
            tbl = "| Table | Parts with deleted rows | Their size | Share of table | Status |\n|---|---|---|---|---|\n"
            for (i = 1; i <= no; i++) {
                key = order[i]; share = pct(lt[key], tb[key]); rs = "OK"
                if (share >= 30 && lt[key] >= 10 * GiB) rs = "CRITICAL"
                else if (share >= 10) rs = "WARN"
                st[7] = worse(st[7], rs)
                if (i <= 15) tbl = tbl "| " cell(tdb[key] "." ttb[key]) " | " lp[key] " | " hs(lt[key]) " | " fpct(share) " | " rs " |\n"
                if (rs != "OK")
                    for (j = 1; j <= np[key]; j++)
                        fixes = fixes "ALTER TABLE " fq(tdb[key], ttb[key]) " APPLY DELETED MASK IN PARTITION ID '" sq(pl[key, j]) "';\n"
            }
            s = s "Parts that still hold rows removed with DELETE FROM (lightweight delete). The script can't count deleted rows without reading your data,"
            s = s " so \"share\" is the share of the table in such parts: the upper bound of what can come back.\n\n" tbl
            if (fixes != "") {
                s = s "\n**Fix: apply the delete mask.** Rewrites these parts in the background (a mutation) and needs free space about the size of each partition. Safe for rows that were not deleted.\n"
                s = s "```sql\n" fixes "```\n"
                s = s "Heavier alternative: `OPTIMIZE TABLE <table> PARTITION ID '<id>' FINAL` rewrites and merges the whole partition. Avoid it on big partitions in busy hours.\n"
                if (product == "langfuse")
                    s = s "Newer Langfuse workers can do this themselves: `LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` (off by default; check your version's .env.prod.example).\n"
            }
        } else s = s "No parts with lightweight-deleted rows.\n"
    } else partial = partial "Deleted rows: " notrun("deleted_rows")
    if (ok("mutations")) {
        if (n["mutations"] > 0) {
            mt = "| Table | Mutation | Age | Parts left | Last attempt | Status |\n|---|---|---|---|---|---|\n"
            for (i = 1; i <= n["mutations"]; i++) {
                split(row["mutations", i], f, "\t")
                m = f[5] + 0; mrs = "OK"
                if (f[7] + 0 == 1 || m > 1440) mrs = "CRITICAL"
                else if (m > 60) mrs = "WARN"
                st[7] = worse(st[7], mrs)
                if (i <= 15) mt = mt "| " cell(f[2] "." f[3]) " | " cell(f[4]) " | " hage(m) " | " f[6] " | " ((f[7] + 0 == 1) ? "failed" : "running") " | " mrs " |\n"
                if (mrs != "OK")
                    kills = kills "KILL MUTATION WHERE database = '" sq(f[2]) "' AND table = '" sq(f[3]) "' AND mutation_id = '" sq(f[4]) "';\n"
            }
            s = s "\nUnfinished mutations: " n["mutations"] ".\n\n" mt
            if (kills != "") {
                s = s "\nSee the command and the error first: `SELECT database, table, mutation_id, command, latest_fail_reason FROM system.mutations WHERE NOT is_done;`\n"
                s = s "Stop a broken or hanging mutation (parts it already changed stay changed; fix the cause before running it again):\n"
                s = s "```sql\n" kills "```\n"
            }
        } else s = s "\nNo unfinished mutations.\n"
    } else partial = partial "Mutations: " notrun("mutations")
    if (partial != "") s = s "\nPart of this check did not run. " partial
    body[7] = s
}

# ---------------------------------------------------------------- report
function report(   i, s, notes) {
    name_ver = name " " version
    check1(); check2(); check3(); check4(); check5(); check6(); check7()
    printf "# ClickHouse check-up · %s\n", now_human
    s = name_ver " · ClickHouse " ((ver != "") ? ver : "unknown") " · detected: " plabel
    if (ctr != "") s = s " · container " ctr
    print s
    print "Nothing was changed. Nothing was sent anywhere. " run_mode
    print ""
    print "| # | Check | Status |"
    print "|---|---|---|"
    for (i = 1; i <= 7; i++) printf "| %d | %s | %s |\n", i, T[i], st[i]
    print ""
    if (!ok("passport")) print "Server passport could not be read: " qerr["passport"] "\n"
    notes = ""
    if (y9999 > 0)
        notes = notes "- " y9999 "" ((y9999 == 1) ? " active part" : " active parts") " in partitions of year 9999 (partition ID 9999...). Timestamps were stored as 9999-12-31: with Langfuse this is langfuse#16858 (ClickHouse 26.8+ with an older Langfuse). Update Langfuse to a release with PR #16892; the wrong rows need a manual fix.\n"
    if (product == "langfuse" && ver != "") {
        if (vmaj > 26 || (vmaj == 26 && vmin >= 8))
            notes = notes "- ClickHouse " vmaj "." vmin " with Langfuse: make sure your Langfuse includes the DateTime64 fix (langfuse#16858, PR #16892). Older Langfuse releases store timestamps as 9999-12-31 on ClickHouse 26.8+.\n"
        else
            notes = notes "- ClickHouse " vmaj "." vmin " is fine for Langfuse. Before upgrading ClickHouse to 26.8+, update Langfuse first (DateTime64 fix: langfuse#16858, PR #16892).\n"
    }
    if (notes != "") print "### Heads-up for your version\n" notes
    print "### How to run the fixes"
    print "Nothing below runs by itself: read each command, then run it yourself."
    if (ctr != "")
        print "SQL goes into clickhouse-client as a user that may change tables (a read-only user can't): `docker exec -it " ctr " clickhouse-client --user <user> --password`. In Langfuse's docker compose the user is CLICKHOUSE_USER from your .env. Shell commands run on the Docker host."
    else
        print "SQL goes into `clickhouse-client` as a user that may change tables (a read-only user can't). Shell commands run on the ClickHouse server."
    print ""
    for (i = 1; i <= 7; i++) {
        printf "## %d. %s: %s\n\n", i, T[i], st[i]
        printf "%s\n", body[i]
    }
    print "---"
    print "This is a snapshot. It can't tell when the disk will really run out, or whether your " ((top_log != "") ? top_log : "trace_log") " is normal for " ((product == "other") ? "a ClickHouse" : "a " plabel) " of your size."
    print "Want an email before the disk fills? Hourly snapshots, free beta Oct 8 - Nov 7: " beta_url
}

# ---------------------------------------------------------------- payload
function payload(   i, f, k, key, srv, out, sep, dsep, tsep, x, y, lwd_p, lwd_b, wr, ina_p, ina_b, det_p, det_b,
                    mut, ttl, dout, tout, rowj, notrun_list, maxpp, mpending, mfail, dk, dname, parts_b) {
    # Per-table extras keyed by the real names; real names never reach the output.
    if (ok("system_logs"))
        for (i = 1; i <= n["system_logs"]; i++) { split(row["system_logs", i], f, "\t"); ttl["system" SUBSEP f[2]] = f[5] + 0 }
    if (ok("growth_24h"))
        for (i = 1; i <= n["growth_24h"]; i++) { split(row["growth_24h", i], f, "\t"); wr[f[2], f[3]] += num(f[4]) }
    if (ok("deleted_rows"))
        for (i = 1; i <= n["deleted_rows"]; i++) { split(row["deleted_rows", i], f, "\t"); lwd_p[f[2], f[3]] += num(f[5]); lwd_b[f[2], f[3]] += num(f[6]) }
    if (ok("inactive_parts"))
        for (i = 1; i <= n["inactive_parts"]; i++) {
            split(row["inactive_parts", i], f, "\t")
            if (f[2] == "inactive") { ina_p[f[3], f[4]] += num(f[5]); ina_b[f[3], f[4]] += num(f[6]) }
            else { det_p[f[3], f[4]] += num(f[5]); det_b[f[3], f[4]] += num(f[6]) }
        }
    mpending = 0; mfail = 0
    if (ok("mutations"))
        for (i = 1; i <= n["mutations"]; i++) {
            split(row["mutations", i], f, "\t"); mut[f[2], f[3]]++; mpending++
            if (f[7] + 0 == 1) mfail++
        }

    printf "{\n  \"schema\": 1, \"agent\": %s, \"sent_at\": %s, \"status\": \"ok\",\n", jstr(agent), jstr(now_iso)

    srv = ""; sep = ""
    if (ok("passport") && n["passport"] > 0) {
        split(row["passport", 1], f, "\t")
        if (f[2] ~ /^[0-9]+(\.[0-9]+)+$/) { srv = srv sep "\"clickhouse_version\": \"" f[2] "\""; sep = ", " }
        srv = srv sep "\"uptime_s\": " jint(f[3]); sep = ", "
        srv = srv ", \"product\": " jstr((f[4] ~ /^(langfuse|signoz|clickstack|other)$/) ? f[4] : "other")
        srv = srv ", \"replicated\": " jint(f[5]) ", \"product_bytes\": " jint(f[6]) ", \"system_log_bytes\": " jint(f[7])
        srv = srv ", \"year_9999_parts\": " jint(f[8])
    }
    if (ok("too_many_parts")) {
        maxpp = 0
        for (i = 1; i <= n["too_many_parts"]; i++) {
            split(row["too_many_parts", i], f, "\t")
            if (f[2] == "server") {
                srv = srv sep "\"parts_to_delay_insert\": " jint(f[7]) ", \"parts_to_throw_insert\": " jint(f[8])
                srv = srv ", \"delayed_inserts\": " jint(f[9]) ", \"rejected_inserts\": " jint(f[10]); sep = ", "
                if (num(f[6]) > maxpp) maxpp = num(f[6])
            } else if (num(f[6]) > maxpp) maxpp = num(f[6])
        }
        srv = srv sep "\"max_parts_in_partition\": " i0(maxpp); sep = ", "
    }
    if (ok("mutations")) { srv = srv sep "\"mutations_pending\": " mpending ", \"mutations_failing\": " mfail; sep = ", " }
    printf "  \"server\": { %s },\n", srv

    # Disks: "default" keeps its name, any other disk becomes disk_1, disk_2, ...
    printf "  \"disks\": ["
    dsep = ""; dk = 0
    x = ok("not_in_parts") ? "not_in_parts" : (ok("disk_now") ? "disk_now" : "")
    if (x != "")
        for (i = 1; i <= n[x]; i++) {
            split(row[x, i], f, "\t")
            if (f[2] == "default") dname = "default"; else { dk++; dname = "disk_" dk }
            if (x == "not_in_parts")
                printf "%s\n    { \"disk\": %s, \"total_bytes\": %s, \"free_bytes\": %s, \"parts_bytes\": %s }", dsep, jstr(dname), jint(f[3]), jint(f[4]), i0(num(f[5]) + num(f[7]))
            else
                printf "%s\n    { \"disk\": %s, \"total_bytes\": %s, \"free_bytes\": %s }", dsep, jstr(dname), jint(f[4]), jint(f[5])
            dsep = ","
        }
    printf "%s],\n", (dsep != "") ? "\n  " : " "

    printf "  \"tables\": ["
    tsep = ""
    if (ok("tables"))
        for (i = 1; i <= n["tables"]; i++) {
            split(row["tables", i], f, "\t")
            dout = f[4]; tout = f[5]
            if (dout !~ /^[A-Za-z0-9_]+$/ || tout !~ /^[A-Za-z0-9_]+$/) continue
            key = f[2] SUBSEP f[3]
            rowj = "{ \"db\": \"" dout "\", \"table\": \"" tout "\", \"has_ttl\": " jint(f[6])
            if ((key in ttl) && ttl[key] > 0) rowj = rowj ", \"ttl_days\": " i0(ttl[key])
            rowj = rowj ", \"bytes\": " jint(f[7]) ", \"rows\": " jint(f[8]) ", \"active_parts\": " jint(f[9])
            rowj = rowj ", \"max_parts_in_partition\": " jint(f[10])
            if (num(f[11]) > 0) rowj = rowj ", \"oldest_days\": " jint(f[11])
            if (wr[key] > 0) rowj = rowj ", \"written_bytes_24h\": " i0(wr[key])
            if (lwd_p[key] > 0) rowj = rowj ", \"lwd_parts\": " i0(lwd_p[key]) ", \"lwd_parts_bytes\": " i0(lwd_b[key])
            if (ina_p[key] > 0) rowj = rowj ", \"inactive_parts\": " i0(ina_p[key]) ", \"inactive_bytes\": " i0(ina_b[key])
            if (det_p[key] > 0) rowj = rowj ", \"detached_parts\": " i0(det_p[key]) ", \"detached_bytes\": " i0(det_b[key])
            if (mut[key] > 0) rowj = rowj ", \"mutations_pending\": " i0(mut[key])
            printf "%s\n    %s }", tsep, rowj
            tsep = ","
        }
    printf "%s],\n", (tsep != "") ? "\n  " : " "

    notrun_list = ""; sep = ""
    for (i = 1; i <= nq; i++) {
        x = qorder[i]
        if (qstat[x] == "fail" && qtag[x] != "optional") { notrun_list = notrun_list sep jstr(x); sep = ", " }
    }
    printf "  \"not_run\": [%s]\n}\n", notrun_list
}
__RENDER_AWK__

awk -v mode="$cmd" \
    -v name="$NAME" -v version="$VERSION" -v agent="$NAME/$VERSION" \
    -v now_human="$now_human" -v now_iso="$now_iso" \
    -v ctr="$container_name" -v run_mode="$run_mode" \
    -v ttl_days="$ttl_days" -v beta_url="$BETA_URL" \
    -f "$tmp/render.awk" "$stream"
