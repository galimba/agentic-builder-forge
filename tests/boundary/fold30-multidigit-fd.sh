#!/usr/bin/env bash
# fold30 — MULTI-digit fd forge-own-path TIGHTEN canary (JSON-stdin, RED-first, FLOOR-MOVING).
#
# bash allows a MULTI-digit fd before a redirect operator (`echo x 12> file`, `10>> file`, `12<> file`).
# forge_redir_target's case-globs matched only a SINGLE `[0-9]`, so a 2+-digit fd redirect into a FORGE-OWN
# path (`echo x 12> .git/config`, `cat x 12> harness/x`) slipped past the write-walker ENTIRELY and was ALLOW
# — a pre-existing hole in the paths the forge DOES own (.git / .beads / harness / .claude/hooks / settings).
# The fix peels a LEADING fd digit-RUN (1+ digits) when followed by a write operator, so multi-digit fds are
# classified like single-digit ones. This canary locks: multi-digit-fd writes into forge-own paths DENY;
# a NON-floor multi-digit fd (`cmd 12> /tmp/log`) stays ALLOW (no over-block); single-digit is unchanged.
# RED pre-splice (deployed ALLOWs the forge-own multi-digit writes), GREEN post-splice. FORGE_GUARD_DENY /
# FORGE_LIVE_ROOT override the hook + root to prove GREEN against the candidate overlay before the splice.
#
# FLOOR NOTE: FLOOR-MOVING splice; this test asserts only FLOOR_PRE == FLOOR_POST for its own run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
HOOK="${FORGE_GUARD_DENY:-$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh}"
command -v jq >/dev/null 2>&1 || { echo "fold30: SKIP — jq required to drive the hook"; exit 75; }
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"

verdict() {
  local out
  out="$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | ( cd "$LIVE_ROOT" && bash "$HOOK" 2>/dev/null ))"
  printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && printf DENY || printf ALLOW
}

# DENY: a MULTI-digit fd redirect (>, >>, >|, <>) into a FORGE-OWN path. RED-first (deployed ALLOWs these).
deny=(
  'echo x 12> .git/config'
  'echo x 12>.git/config'
  'echo x 10>> .git/config'
  'echo x 12>| .git/config'
  'cat x 12> harness/x'
  'cat x 34>> harness/targets.config'
  'echo x 10>> .beads/issues.jsonl'
  'cat x 12<> .claude/hooks/lib.sh'
  'echo x 255> .claude/settings.json'
  'echo x 99> .claude/settings.local.json'
  'cat x 12<> .beads/issues.jsonl'
)
# ALLOW: a multi-digit fd to a NON-floor target must NOT be over-blocked; and non-redirect multi-digit tokens.
allow=(
  'cmd 12> /tmp/log'
  'cmd 99>> /tmp/out'
  'pnpm test 12> sandbox/log'
  'cmd 12>&1'
  'echo 12'
  'cat 12< harness/run-task.sh'
  'cmd 10<> /dev/tcp/host/80'
)
echo "== fold30: multi-digit-fd writes into FORGE-OWN paths DENIED (RED-first); non-floor multi-digit ALLOW =="
for c in "${deny[@]}";  do v="$(verdict "$c")"; [ "$v" = DENY  ] && ok "DENY   $c" || bad "expected DENY got $v"  "$c"; done
for c in "${allow[@]}"; do v="$(verdict "$c")"; [ "$v" = ALLOW ] && ok "ALLOW  $c" || bad "expected ALLOW got $v" "$c"; done
# single-digit + bare forms are UNCHANGED (they already denied) — regression parity.
sd="$(verdict 'echo x 2> .git/config')"; [ "$sd" = DENY ] && ok "DENY   single-digit 2> .git/config (unchanged)" || bad "expected DENY got $sd" "single-digit"
bd="$(verdict 'echo x > .git/config')";  [ "$bd" = DENY ] && ok "DENY   bare > .git/config (unchanged)"          || bad "expected DENY got $bd" "bare"

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "floor unmoved by this run" || bad "this run moved the floor" "$FLOOR_PRE -> $FLOOR_POST"
echo "==== fold30: $P passed, $F failed ===="
[ "$F" = 0 ]
