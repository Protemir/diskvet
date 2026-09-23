#!/bin/sh
# Privacy test for the --print-payload JSON. No server needed.
#   sh tests/check_payload.sh payload.json [forbidden-string ...]
# Fails when:
#   - a key is not in tests/payload_keys.txt;
#   - schema / status / sent_at / agent look wrong;
#   - clickhouse_version is not a version number (checked on its own: a
#     version like 25.12.1.649 looks like an IPv4 address, so the IP check
#     below runs only on name fields);
#   - a name field (db, table, disk) is neither a public name nor a salted hash
#     (db_ / t_ + 16 hex), or contains an email, IP, UUID or phone number;
#   - any string from the command line (real database/table names, the
#     container name, the host name) appears anywhere in the payload.
set -u
p=${1:?usage: check_payload.sh payload.json [forbidden-string ...]}
shift
dir=$(dirname "$0")
keys=$dir/payload_keys.txt
[ -r "$p" ] || { echo "cannot read $p"; exit 2; }
fail=0
bad() { printf 'FAIL: %s\n' "$*"; fail=1; }

# 1. keys
grep -oE '"[A-Za-z0-9_]+"[[:space:]]*:' "$p" | sed -E 's/[":[:space:]]//g' | sort -u | while read -r k; do
    grep -qx "$k" "$keys" || echo "$k"
done >"${TMPDIR:-/tmp}/chk_pk.$$"
if [ -s "${TMPDIR:-/tmp}/chk_pk.$$" ]; then bad "keys not in payload_keys.txt: $(tr '\n' ' ' <"${TMPDIR:-/tmp}/chk_pk.$$")"; fi
rm -f "${TMPDIR:-/tmp}/chk_pk.$$"

# 2. envelope
grep -qE '"schema": 1,' "$p" || bad "schema is not 1"
grep -qE '"status": "(ok|ch_unreachable)"' "$p" || bad "status is not ok / ch_unreachable"
grep -qE '"sent_at": "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$p" || bad "sent_at is not UTC ISO-8601"
grep -qE '"agent": "clickhouse-doctor/[0-9]+\.[0-9]+\.[0-9]+"' "$p" || bad "agent is not name/version"

# 3. version on its own
if grep -q '"clickhouse_version"' "$p"; then
    grep -qE '"clickhouse_version": "[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?"' "$p" || bad "clickhouse_version is not a version number"
fi

# 4. name fields
grep -oE '"(db|table|disk)": "[^"]*"' "$p" | sed -E 's/^"[a-z]+": "//; s/"$//' | sort -u >"${TMPDIR:-/tmp}/chk_pn.$$"
while read -r v; do
    if printf '%s\n' "$v" | grep -qE '^(db|t)_[0-9a-f]{16}$'; then continue; fi
    if printf '%s\n' "$v" | grep -qE '^(db|t)_[0-9a-f]+$'; then bad "bad hash format (need 16 hex digits): $v"; continue; fi
    printf '%s\n' "$v" | grep -qE '^[a-z0-9_]{1,64}$' || bad "name is neither a public name nor a hash: $v"
    printf '%s\n' "$v" | grep -q '@' && bad "email-like name: $v"
    printf '%s\n' "$v" | grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' && bad "IP-like name: $v"
    printf '%s\n' "$v" | grep -qiE '[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}' && bad "UUID-like name: $v"
    printf '%s\n' "$v" | grep -qE '\+?[0-9][0-9 ()-]{8,}[0-9]' && bad "phone-like name: $v"
done <"${TMPDIR:-/tmp}/chk_pn.$$"
names=$(wc -l <"${TMPDIR:-/tmp}/chk_pn.$$" | tr -d ' ')
rm -f "${TMPDIR:-/tmp}/chk_pn.$$"

# 5. no string values other than the known ones
grep -oE '"[a-z_0-9]+": "[^"]*"' "$p" | sed -E 's/": .*//; s/"//g' | sort -u | while read -r k; do
    case $k in
        agent|sent_at|status|clickhouse_version|product|db|table|disk) ;;
        *) echo "$k" ;;
    esac
done >"${TMPDIR:-/tmp}/chk_ps.$$"
if [ -s "${TMPDIR:-/tmp}/chk_ps.$$" ]; then bad "unexpected string fields: $(tr '\n' ' ' <"${TMPDIR:-/tmp}/chk_ps.$$")"; fi
rm -f "${TMPDIR:-/tmp}/chk_ps.$$"
grep -qE '"product": "(langfuse|signoz|clickstack|other)"' "$p" || { grep -q '"product"' "$p" && bad "unknown product value"; }

# 6. forbidden strings
for w in "$@"; do
    [ -n "$w" ] || continue
    grep -qF -- "$w" "$p" && bad "payload contains a forbidden string: $w"
done

if [ "$fail" -eq 0 ]; then echo "check_payload: OK ($p, $names distinct names)"; else echo "check_payload: FAILED ($p)"; fi
exit "$fail"
