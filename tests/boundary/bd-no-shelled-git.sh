#!/usr/bin/env bash
# bd-no-shelled-git PIN (monitored residual). The finish-path bd ops (export/update) must shell NO
# `git` subprocess — bd v1.0.4 stages in-process via go-git, so the repo-local-config exec primitive never
# fires. A recording `git` shim on PATH catches a FUTURE bd that shells `git add` (which would read
# $ROOT/.git/config repo-local = the one version-coupled residual forge_safe_env cannot mask). RED-first:
# the positive control (`bd create`, which DOES shell git) MUST trip the shim, proving the pin can detect it.
set -u
BD="$(command -v bd)"; REAL_GIT="$(command -v git)"
[ -n "$BD" ] || { echo "SKIP: bd not found — rc 75"; exit 75; }
SHIMDIR="$(mktemp -d)"; LOG="$SHIMDIR/git-calls.log"; : > "$LOG"
printf '#!/bin/sh\necho "$@" >> "%s"\nexec "%s" "$@"\n' "$LOG" "$REAL_GIT" > "$SHIMDIR/git"; chmod +x "$SHIMDIR/git"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
calls(){ grep -c . "$LOG" 2>/dev/null | tr -d ' '; }
# harmless DISCOVERY git subcommands (no index-refresh / hooks / transport / filters => no exec-knob fires);
# anything OUTSIDE this set (add/commit/status/diff/fetch/push/checkout/...) is the exec primitive -> FAIL.
# harmless DISCOVERY subcommands. 'remote' is NOT here — it's a MULTIPLEXER: remote show/update/prune fire
# TRANSPORT (sshCommand), so it gets a SECOND-VERB check (FOLD #8 — the pin's own blind spot).
SAFE='rev-parse|config|cat-file|var|symbolic-ref|hash-object|for-each-ref|show-ref|ls-tree|version'
SAFE_REMOTE='remote-(list|get-url|-v|add|rename|remove|set-url|set-branches)'
# extract the git subcommand per logged invocation (skip value-taking global options + their value + any
# -flag). For 'remote', also capture the second-level verb as 'remote-<verb>' ('remote-list' when bare).
subcmds(){ awk '{i=1; sc="";
  while(i<=NF){t=$i;
    if(t=="-C"||t=="-c"||t=="--git-dir"||t=="--work-tree"||t=="--namespace"||t=="--super-prefix"){i+=2;continue}
    if(t ~ /^-/){i++;continue}
    if(sc==""){ sc=t; if(t!="remote"){print sc; break} else {i++; continue} }
    else { print "remote-" t; break } }
  if(sc=="remote" && i>NF) print "remote-list" }' "$LOG"; }
unsafe_subcmds(){ subcmds | grep -vE "^($SAFE)$|^$SAFE_REMOTE$" | sort -u | tr '\n' ' '; }

D="$(mktemp -d)"; ( cd "$D" && "$REAL_GIT" init -q && "$REAL_GIT" config user.email t@t && "$REAL_GIT" config user.name t && "$BD" init >/dev/null 2>&1 )

# POSITIVE CONTROL: bd create shells `git add` (the exec primitive) -> shim records it
: > "$LOG"
( cd "$D" && PATH="$SHIMDIR:$PATH" "$BD" create "pin-control" -p 2 >/dev/null 2>&1 )
[ "$(calls)" -ge 1 ] && ok "CONTROL: bd create shells git (shim logged $(calls) call(s)) — the pin detects shelled git" || bad "CONTROL: bd create shelled no git (pin blind)" "log=[$(cat "$LOG")]"
bid="$( cd "$D" && "$BD" list --json 2>/dev/null | jq -r '.[0].id // empty' )"

# THE PIN: the finish-path ops (export -o, update --status) must shell ZERO git on v1.0.4
: > "$LOG"
( cd "$D" && PATH="$SHIMDIR:$PATH" "$BD" export -o "$D/issues.jsonl" >/dev/null 2>&1 )
u="$(unsafe_subcmds)"; [ -z "$u" ] && ok "PIN: bd export -o shells only harmless discovery git, NO exec-knob subcommand (v1.0.4: $(subcmds|sort -u|tr '\n' ' '))" || bad "bd export shelled an exec-knob git subcommand (residual LIVE — fix-first): $u" "log=[$(cat "$LOG")]"
: > "$LOG"
[ -n "$bid" ] && ( cd "$D" && PATH="$SHIMDIR:$PATH" "$BD" update "$bid" --status in_review >/dev/null 2>&1 )
u="$(unsafe_subcmds)"; [ -z "$u" ] && ok "PIN: bd update --status shells only harmless discovery git, NO exec-knob subcommand" || bad "bd update shelled an exec-knob git subcommand: $u" "log=[$(cat "$LOG")]"

# meta-check: prove the pin would FAIL on a shelled-git bd — simulate via a bd-shim that shells git add
BDSHIM="$SHIMDIR/bd-shells-git"; printf '#!/bin/sh\nexec git add -A\n' > "$BDSHIM"; chmod +x "$BDSHIM"
: > "$LOG"
( cd "$D" && PATH="$SHIMDIR:$PATH" "$BDSHIM" >/dev/null 2>&1 )
[ -n "$(unsafe_subcmds)" ] && ok "META: a shelled-git-add bd WOULD trip the pin (caught: $(unsafe_subcmds)) — early-warning works" || bad "META: pin would NOT catch a shelled-git-add bd" ""

# META2 (FOLD #8): a bd that shells `git remote show origin` (TRANSPORT — fires sshCommand) WOULD trip the pin
BDSHIM2="$SHIMDIR/bd-remote-show"; printf '#!/bin/sh\nexec git remote show origin\n' > "$BDSHIM2"; chmod +x "$BDSHIM2"
: > "$LOG"
( cd "$D" && PATH="$SHIMDIR:$PATH" "$BDSHIM2" >/dev/null 2>&1 )
[ -n "$(unsafe_subcmds)" ] && ok "META2: a bd shelling 'git remote show' (transport) WOULD trip the pin (caught: $(unsafe_subcmds))" || bad "META2: pin BLIND to remote show/update (transport second-verb)" "subcmds=[$(subcmds | tr '\n' ' ')]"
# and confirm the INERT remote forms (bare / -v / get-url) do NOT false-trip
BDSHIM3="$SHIMDIR/bd-remote-v"; printf '#!/bin/sh\ngit remote -v; git config --get remote.origin.url\n' > "$BDSHIM3"; chmod +x "$BDSHIM3"
: > "$LOG"; ( cd "$D" && PATH="$SHIMDIR:$PATH" "$BDSHIM3" >/dev/null 2>&1 )
[ -z "$(unsafe_subcmds)" ] && ok "META3: inert remote forms (remote -v / config --get) do NOT false-trip the pin" || bad "META3: pin false-trips on inert remote" "caught=[$(unsafe_subcmds)]"

echo "==== bd-no-shelled-git: $P passed, $F failed ===="
[ "$F" -eq 0 ]
