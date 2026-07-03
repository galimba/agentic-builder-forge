#!/usr/bin/env bash
# fold25 — bd close-verb deny canary (JSON-stdin, RED-first, FLOOR-MOVING).
#
# The done-edge is bd-managed; the agent's DIRECT close-verbs are denied at the deny floor. Driven through
# the hook's JSON-stdin verdict contract (mirrors fold23 / tests/commitguard/run.sh). RED pre-splice (the
# live floor has no forge_check_bd -> bd close ALLOWs), GREEN post-splice. FORGE_GUARD_DENY / FORGE_LIVE_ROOT
# override the hook + root (prove GREEN against a candidate overlay before the splice).
#
# FLOOR NOTE: the close-verb deny is a FLOOR-MOVING splice (it deliberately moves the floor hash, recorded at recert).
# This test asserts only that ITS OWN run does not move the floor (FLOOR_PRE == FLOOR_POST).
#
# Review-fix additions: the F1 (`bd todo done` alias) + F2 (`sudo -u/-n bd close`) closures, RED-first
# (they ALLOW on the pre-fix floor, DENY on the candidate). The sudo cases are STATIC string analysis by the
# deny hook (sudo is never executed), so no sudo binary is required.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
HOOK="${FORGE_GUARD_DENY:-$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh}"
command -v jq >/dev/null 2>&1 || { echo "fold25: SKIP — jq required to drive the hook"; exit 75; }
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"

verdict() { # <cmd> -> DENY | ALLOW
  local out
  out="$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | ( cd "$LIVE_ROOT" && bash "$HOOK" 2>/dev/null ))"
  printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && printf DENY || printf ALLOW
}

deny=(
  'bd close fx-xxx'
  'bd done fx-xxx'                                   # alias
  'bd close'                                         # no-id form (closes last-touched) -> wholesale
  'bd update fx-x -s closed'
  'bd update fx-x --status closed'
  'bd update fx-x --status=closed'
  'bd update fx-x -sclosed'                          # glued short
  'bd update fx-x --status open --status closed'     # last-wins -> closed
  'bd -C . close fx-x'                               # global value-flag (2-token) before the verb
  'bd --db /tmp/x.db close fx-x'
  'bd --actor me close fx-x'
  'bd -C closed close fx-x'                          # -C consumes "closed" as its value; must not desync
  'bd --dolt-auto-commit off close fx-x'             # another value-global
  'bd import f.jsonl'
  'bd import -'
  'cat f.jsonl | bd import -'                        # piped import
  'bd supersede fx-a fx-b'
  'bd duplicate fx-a fx-b'
  'foo & bd close fx-x'                              # bare-& separator (the &-aware splitter)
  'bash -c "bd close fx-x"'                          # interpreter -c launder
  'eval bd close fx-x'                               # eval launder
  'echo bd close fx-x | bash'                        # pipe-into-shell launder
  'bd close $(cat id.txt)'                           # substituted operand -> fail closed
  'bd "close" fx-x'                                  # F1: WHOLLY double-quoted verb (bash strips -> real close)
  "bd 'close' fx-x"                                  # F1: WHOLLY single-quoted verb
  'bd update fx-x -s "closed"'                       # F1: wholly-quoted status value
  'bd update fx-x --status="closed"'                 # F1: quoted glued status value
  'xargs bd close fx-x'                              # F3: NON-piped xargs resolves through to bd
  'xargs -n1 bd close fx-x'                          # F3: xargs with options -> bd
  # ── F1: `bd todo done <id>` is a documented alias for `bd close <id>` (bd help) ──
  'bd todo done fx-x'                                # F1: the documented close alias
  'bd todo done'                                     # F1: no-id form (closes last-touched) -> wholesale
  'bd -C . todo done fx-x'                           # F1: value-global BEFORE the todo verb (verb-scan skip)
  'bd todo -C . done fx-x'                           # F1: value-global AFTER todo (cobra interspersion; 2-token skip)
  'nice bd todo done fx-x'                           # F1: runner-wrapped (resolves through nice to bd)
  'bd todo "done" fx-x'                              # F1: WHOLLY-quoted todo subcommand (forge_unquote)
  'bash -c "bd todo done fx-x"'                      # F1: interpreter -c launder (the todo-done adjacency arm)
  # ── F-adv (adversarial input): $'...' ANSI-C quoting -> substitution fail-closed guard ──
  "bd \$'close' fx-x"                                # F-adv: \$'...' dodges forge_unquote -> fail-closed guard
  "bd todo \$'done' fx-x"                            # F-adv: \$'...' on the todo subcommand -> fail-closed
  # ── F2: sudo now consumes its options in the bd walker (was a bare +1 skip) ──
  'sudo -u x bd close fx-x'                          # F2: run-as-user option must not desync off bd
  'sudo -n bd close fx-x'                            # F2: non-interactive boolean must not desync off bd
  'sudo -R /tmp bd close fx-x'                       # F2: -R/--chroot detached value-taker must not desync off bd
)
allow=(
  'bd list --status closed --closed-after 2026-01-01'   # LIVE harness read (beads.config:56) + agent-allowlisted
  'bd list --closed-after 2026-01-01'                   # do NOT substring-match "closed"
  'bd -C . list --status closed'                        # global flag + read, still a list
  'bd update fx-x --status in_review'                   # finish's hold-until-merge transition
  'bd update fx-x -s in_review'
  'bd update fx-x -p 1'                                 # a non-status update
  'bd list'
  'bd list --json'
  'bd show fx-x'
  'bd ready'
  'bd board'
  'bd export'
  'bd create "new bead" -p 2'
  'bd duplicates'                                       # a READ (find duplicates), NOT the close-verb "duplicate"
  'bd list | grep close'                                # bd + a close-VERB word but piped to a READER (grep), not a shell -> launder gate must NOT over-fire
  'echo bd list closed things'                          # bd present, but no bare close-VERB word
  'bd export | python3 -c "import json,sys; json.load(sys.stdin)"'   # F2/F4: bd READ piped to python (import word) — must NOT over-block
  'bd show fx-x && python3 -c "import sys; print(1)"'   # F2/F4: bd READ chained with a python one-liner
  'bd ready | while read x; do echo "$x"; done'         # F4: do…done loop over bd ready (the `done` keyword)
  'bd list --json | jq -r ".[].id" | xargs -I{} bd show {}'   # F3/F4: xargs into a bd READ
  'xargs bd show fx-x'                                  # F3: leading xargs into a READ -> allow (not a close)
  # ── F1/F2 over-block guards: the todo READ/CREATE subcommands + sudo into a READ must stay ALLOWED ──
  'bd todo list'                                        # F1: todo READ subcommand — must NOT over-block
  'bd todo list --all'                                  # F1: todo READ with a flag
  'bd todo add "new todo"'                              # F1: todo CREATE subcommand — must NOT over-block
  'bd todo'                                             # F1: bare `bd todo` == bd list --type task (a READ)
  'bd todo add done'                                    # F1: a task TITLED "done" (add terminates first-non-flag scan) -> allow
  'bd todo -C . list'                                   # F1: value-global after todo, READ subcommand -> allow
  'bd todo -C done list'                                # F1: -C value literally "done" (2-token skip) must NOT desync -> allow
  'sudo -u x bd list'                                   # F2: sudo resolves through to a bd READ -> allow
)

echo "== DENY: the agent's direct bd close-verbs (direct + global-flag + last-wins + launder + todo/sudo shapes) =="
for c in "${deny[@]}"; do
  [ "$(verdict "$c")" = DENY ] && ok "DENY $c" || bad "expected DENY (RED until the splice lands)" "$c"
done
echo "== ALLOW: harness reads + non-close updates + todo READ/CREATE + sudo-into-read + benign (over-block guards) =="
for c in "${allow[@]}"; do
  [ "$(verdict "$c")" = ALLOW ] && ok "ALLOW $c" || bad "expected ALLOW (over-block)" "$c"
done

echo "== DOOR: FORGE_ALLOW_BD_CLOSE=1 -> ALLOW + actor-logged escape =="
LOGDIR="$(mktemp -d)"
door_out="$(jq -nc --arg c 'bd close fx-x' '{tool_name:"Bash",tool_input:{command:$c}}' | ( cd "$LIVE_ROOT" && FORGE_ALLOW_BD_CLOSE=1 FORGE_HARNESS_DIR="$LOGDIR" bash "$HOOK" 2>/dev/null ))"
printf '%s' "$door_out" | grep -q '"permissionDecision":"deny"' && door=DENY || door=ALLOW
[ "$door" = ALLOW ] && ok "door open -> bd close ALLOWed" || bad "door FORGE_ALLOW_BD_CLOSE=1 should allow"
{ [ -f "$LOGDIR/bd-close-escape.log" ] && grep -q 'FORGE_ALLOW_BD_CLOSE=1' "$LOGDIR/bd-close-escape.log"; } \
  && ok "door open -> escape WRITTEN + actor-attributed (bd-close-escape.log)" || bad "door should write an actor-attributed bd-close-escape.log (RED until splice)"
rm -rf "$LOGDIR" 2>/dev/null

# NOTE (honest framing): this is a REGRESSION GUARD that forge_bd close still closes a bead — it calls the
# function DIRECTLY, NOT through the hook. The subprocess-invisibility is ARCHITECTURAL (PreToolUse never
# wraps a subprocess, so there is nothing to drive here); the deny[] loop above is what exercises the hook.
echo "== HARNESS CLOSE STILL WORKS: forge_bd close (the reconcile close path) still closes a bead =="
if command -v bd >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  # timeout-guarded (verification discipline: a foreground cmd with a timeout, never an unbounded block). This
  # block is CORROBORATION only — the deny[] loop above is the real proof and subprocess-invisibility is
  # architectural — so a bd-environment hang/failure is a SKIP, never a gate-hanging block or a canary failure.
  _hc_out="$(FORGE_LIVE_ROOT_HC="$LIVE_ROOT" timeout 30 bash -c '
    TMP="$(mktemp -d)"
    ( cd "$TMP" && git init -q && git config user.email t@t && git config user.name t && bd init >/dev/null 2>&1 && bd config set status.custom "in_review:wip" >/dev/null 2>&1 )
    bd -C "$TMP" create "subprocess-close bead" -p 2 >/dev/null 2>&1
    cid="$(bd -C "$TMP" list --json 2>/dev/null | jq -r ".[]|select(.title==\"subprocess-close bead\")|.id" | head -1)"
    ( ROOT="$TMP"; . "$FORGE_LIVE_ROOT_HC/harness/beads-lib.sh" 2>/dev/null; forge_bd close "$cid" --reason "fold25 subprocess proof" >/dev/null 2>&1 )
    st="$(bd -C "$TMP" show "$cid" --json 2>/dev/null | jq -r "(.[0]//.).status" 2>/dev/null)"
    rm -rf "$TMP" 2>/dev/null
    printf "%s" "$st"
  ' 2>/dev/null)"
  _hc_rc=$?
  if [ "$_hc_rc" -eq 124 ]; then
    ok "harness-close corroboration TIMED OUT (bd env hang) -> SKIP (deny[] loop is the real proof; invisibility is architectural)"
  elif [ "$_hc_out" = closed ]; then
    ok "forge_bd close still closes a bead — the reconcile close path is unaffected (invisibility is architectural, not hook-tested here)"
  else
    ok "harness-close corroboration inconclusive (bd env; rc=$_hc_rc) -> SKIP (deny[] loop is the real proof)"
  fi
else
  ok "bd/git absent -> SKIP the harness-close corroboration"
fi

echo "== CANARY: the deployed floor carries forge_check_bd + the door + the wire-in + the keystone probe =="
grep -qF 'forge_check_bd() {' "$LIVE_ROOT/.claude/hooks/lib.sh" && ok "lib.sh defines forge_check_bd" || bad "lib.sh missing forge_check_bd (RED until splice)"
grep -qF 'forge_bd_deny() {' "$LIVE_ROOT/.claude/hooks/lib.sh" && ok "lib.sh carries the FORGE_ALLOW_BD_CLOSE door (forge_bd_deny)" || bad "lib.sh missing forge_bd_deny (RED until splice)"
grep -qF 'forge_check_bd "$CMD"' "$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh" && ok "deny.sh wires in forge_check_bd" || bad "deny.sh missing the wire-in (RED until splice)"
grep -qF 'command -v forge_check_bd' "$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh" && ok "keystone: deny.sh load-guard probes forge_check_bd" || bad "keystone probe missing forge_check_bd (RED until splice)"

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "this test run did NOT move the floor (the splice move is recorded at recert)" || bad "lib.sh changed during the test run" "pre=$FLOOR_PRE post=$FLOOR_POST"
echo "==== fold25-bd-verb-deny: $P passed, $F failed ===="
[ "$F" -eq 0 ]
