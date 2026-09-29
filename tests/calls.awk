# Which lines of diskvet.sh run a command outside the functions allowed to run
# it: kubectl only in kc() and kx() (tests/k8s_offline.sh), docker and
# docker-compose only in dk() and dx() (tests/docker_offline.sh).
#   awk -v q="'" -v cmd='docker|docker-compose' -v fns='dk dx' -v want=2 -f tests/calls.awk diskvet.sh
# cmd: a regex of command names; fns: the functions allowed to run them; want:
# how many lines in them do (so a renamed function can't make the check pass).
# Prints each line that runs one elsewhere; exit 1 for any, or for another count.
#
# The shell part of diskvet.sh as code only: no comments, no quoted strings, no
# quoted here-documents (the report text is awk, after the render.awk line, and
# only prints commands). $( ) and ` ` are code wherever they are, inside "..."
# and unquoted here-documents too. A stack of frames: D "...", H an unquoted
# here-document, C $( ), B ` `; sq is a '...' string.
BEGIN {
    k = split(fns, fa, " ")
    for (i = 1; i <= k; i++) allow[fa[i]] = 1
    word = "(^|[^A-Za-z0-9_.-])(" cmd ")([^A-Za-z0-9_.-]|$)"
}
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
    # an allowed function: its body up to a "}" line, or this line if it ends in }
    if (match(s, /^[A-Za-z_][A-Za-z0-9_]*\(\) \{/)) {
        fname = substr(s, 1, index(s, "(") - 1)
        if (fname in allow) { infn = 1; one = (code ~ /[}][ \t]*$/) }
    }
    # not a call: "command -v docker", and a word compared or assigned
    # (transport=docker, [ "$transport" = docker ])
    gsub("command -v (" cmd ")", "", code)
    gsub("=[ \t]*(" cmd ")", "=", code)
    if (code ~ word) {
        if (infn) allowed++
        else { print NR ": " s; bad++ }
    }
    if (infn && (one || s ~ /^}/)) infn = 0
}
END {
    # a quote or a $( left open means this scan lost track: fail rather than pass
    if (d != 0 || sq) print "the scan ended inside a quote or a $( ) (depth " d ")"
    if (allowed != want) print allowed " lines run " cmd " in " fns ", not " want
    exit (bad || allowed != want || d != 0 || sq)
}
