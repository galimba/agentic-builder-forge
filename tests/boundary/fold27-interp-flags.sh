#!/usr/bin/env bash
# fold27 — interpreter eval-body family-split canary (JSON-stdin, RED-first, FLOOR-MOVING).
#
# The interp -c/-e launder guard used ONE regex `-[A-Za-z]*(c|e)` for shell AND script interpreters, so a
# shell ERREXIT flag (`bash -e run-task.sh`) was denied as if it were an inline eval body. The fix splits the
# detector by family: shell (sh/bash/dash/zsh/ksh) denies a cluster CONTAINING c (eval); a no-c errexit
# cluster is ALLOWED. Script langs (python/node/perl/ruby) still deny -c OR -e (perl -c runs BEGIN). Driven
# through the hook's JSON-stdin contract (mirrors fold23/fold25). RED pre-splice (deployed floor denies the
# errexit shapes), GREEN post-splice. FORGE_GUARD_DENY / FORGE_LIVE_ROOT override the hook + root to prove
# GREEN against the candidate overlay before the splice.
#
# FLOOR NOTE: this is a FLOOR-MOVING splice. This test asserts only that ITS OWN run does not move the
# floor (FLOOR_PRE == FLOOR_POST); the deliberate move is recorded at recert.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
HOOK="${FORGE_GUARD_DENY:-$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh}"
command -v jq >/dev/null 2>&1 || { echo "fold27: SKIP — jq required to drive the hook"; exit 75; }
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"

verdict() { # <cmd> -> DENY | ALLOW
  local out
  out="$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | ( cd "$LIVE_ROOT" && bash "$HOOK" 2>/dev/null ))"
  printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && printf DENY || printf ALLOW
}

# ALLOW: shell errexit / option-only clusters (no eval flag) — the family-split relax. RED on the deployed floor.
# Each fixture isolates ONE of the four gates that carry the interp-evalbody check (enforce / rm / push),
# and is independently valid (no other rule denies it): the ONLY reason for the deployed DENY is the errexit
# over-block. (The bd-gate check is only reachable when `bd <close-verb>` is present, which the bd close-verb
# deny (fold25) denies on its own — so a bd-gate errexit RELAX is untestable; its keep-deny direction is covered below.)
allow=(
  # enforce-adjacent gate (a harness/ path is present)
  'bash -e harness/run-task.sh'
  'bash -e harness/run-task.sh sync'
  'sh -e harness/x.sh'
  'bash -xe harness/run-task.sh'
  'bash -eu harness/run-task.sh'
  'dash -e harness/run-task.sh'
  # rm-gate (a deleter word is present) — all-sandbox paths, so nothing else denies
  'rm sandbox/x && bash -e sandbox/cleanup.sh'
  'find sandbox -name x && bash -e sandbox/y.sh'
  # push-gate ('push' token present) — no enforcement path, no real push-to-main
  'echo push && bash -e sandbox/x.sh'
)
# DENY: real eval bodies (shell -c incl. clustered -ce/-ec, script -c/-e). Must STAY denied (no hole opened).
deny=(
  "bash -c 'rm harness/x'"
  "bash -ce 'rm harness/x'"
  "bash -ec 'rm harness/x'"
  "bash -e -c 'rm harness/x'"
  "sh -c 'rm harness/x'"
  'perl -c harness/foo.pl'
  "perl -e 'unlink \"harness/x\"'"
  'node -e 1 harness'
  'ruby -e 1 harness'
  'python3 -c 1 harness'
  'find . -exec node -e 1 {} +'
  "bash -c 'bd close fx-x'"
)
echo "== fold27: shell errexit ALLOWED (RED-first), eval bodies still DENIED =="
for c in "${allow[@]}"; do v="$(verdict "$c")"; [ "$v" = ALLOW ] && ok "ALLOW  $c" || bad "expected ALLOW got $v" "$c"; done
for c in "${deny[@]}";  do v="$(verdict "$c")"; [ "$v" = DENY  ] && ok "DENY   $c" || bad "expected DENY got $v"  "$c"; done

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "floor unmoved by this run" || bad "this run moved the floor" "$FLOOR_PRE -> $FLOOR_POST"
echo "==== fold27: $P passed, $F failed ===="
[ "$F" = 0 ]
