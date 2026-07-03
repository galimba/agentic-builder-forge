#!/usr/bin/env bash
# fold26 — redirect fd-dup glued-separator canary (JSON-stdin, RED-first, FLOOR-MOVING).
#
# forge_redir_target extracted an fd-dup descriptor with `${t##*>&}`, which SWALLOWED a shell separator
# glued to the token (`2>&1;next` -> "FD:1;next"), so the standard-fd allowlist rejected it and a legit
# `cmd 2>&1;next` was denied "non-standard descriptor". The fix peels only the fd digit run (or `-` close)
# and treats a glued separator as the next command. Driven through the hook's JSON-stdin contract. RED
# pre-splice (deployed denies the glued forms), GREEN post-splice. FORGE_GUARD_DENY / FORGE_LIVE_ROOT
# override the hook + root to prove GREEN against the candidate overlay before the splice.
#
# FLOOR NOTE: FLOOR-MOVING splice; this test asserts only FLOOR_PRE == FLOOR_POST for its own run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
HOOK="${FORGE_GUARD_DENY:-$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh}"
command -v jq >/dev/null 2>&1 || { echo "fold26: SKIP — jq required to drive the hook"; exit 75; }
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"

verdict() {
  local out
  out="$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | ( cd "$LIVE_ROOT" && bash "$HOOK" 2>/dev/null ))"
  printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && printf DENY || printf ALLOW
}

# ALLOW: standard fd-dup (2>&1 / 1>&2 / >&1 / >&-) with a GLUED separator — the fd-dup relax. RED-first.
allow=(
  'make 2>&1;true'
  'make 2>&1; true'
  'make 2>&1;'
  'cmd 1>&2;next'
  'pnpm test 2>&1|tee /tmp/log'
  'pnpm test 2>&1|cat'
  'make 2>&1&& echo ok'
  'echo hi >&2;echo bye'
  'make 2>&1'
  'make 2>&1 | tee /tmp/log'
  'ls >&-;true'
  'ls >&-'
  'echo hi>&2'
  'make 2>&1;echo done'
  'cat <> /tmp/f'
  'exec 3<>/dev/tcp/host/80'
)
# DENY: a genuinely non-standard fd stays denied; a .git-write redirect (the load-bearing floor-path
# protection) stays denied even when glued.
deny=(
  'cmd 2>&5'
  'cmd 2>&5;next'
  'cmd >&9'
  'echo x > .git/config'
  'echo x >.git/hooks/pre-commit'
  'echo x >.git/config;true'
  'echo x > .claude/hooks/lib.sh'
  # CRITICAL review regression locks: a standard fd-dup GLUED to a separator glued to a bare floor-path
  # redirect must STAY denied — the fd-dup relax must not drop the trailing redirect scan.
  'ls 2>&1;>.git/config'
  'ls 2>&1;>>.git/config'
  'ls 2>&1;>|.git/config'
  'ls 2>&1|>.git/config'
  'ls 2>&1&&>.git/config'
  'ls 1>&2;>.git/config'
  'ls 2>&1;>.claude/hooks/lib.sh'
  'ls 2>&1;>.claude/settings.json'
  'ls 2>&1;>harness/x'
  'cat x 2>&1;>.beads/issues.jsonl'
  # the >&- CLOSE form glued to a redirect must ALSO stay denied (the close-arm parity of the CRITICAL).
  'ls >&-;>.git/config'
  'ls >&-;>.claude/hooks/lib.sh'
  'ls 0>&-;>.git/config'
  'cat x >&-|>.git/config'
  # review r2: a LEADING write-redirect masked by a trailing fd-dup (the per-segment split now catches it —
  # a TIGHTEN that closes a pre-existing floor-write hole the old command-wide scan missed).
  '>.git/config;2>&1'
  '>harness/x;2>&1'
  '>.beads/issues.jsonl;2>&1'
  '>.claude/hooks/lib.sh;2>&1;cp'
  # review r3: `<>` (O_RDWR|O_CREAT) into a floor path is a WRITE (recognizer now classifies it).
  'cat x 1<> .git/config'
  'cat x 1<> harness/targets.config'
  'cat x <>.claude/settings.json'
  'cat x 1<> .beads/issues.jsonl'
)
echo "== fold26: glued-separator fd-dups ALLOWED (RED-first), non-std fd + .git write DENIED =="
for c in "${allow[@]}"; do v="$(verdict "$c")"; [ "$v" = ALLOW ] && ok "ALLOW  $c" || bad "expected ALLOW got $v" "$c"; done
for c in "${deny[@]}";  do v="$(verdict "$c")"; [ "$v" = DENY  ] && ok "DENY   $c" || bad "expected DENY got $v"  "$c"; done

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "floor unmoved by this run" || bad "this run moved the floor" "$FLOOR_PRE -> $FLOOR_POST"
echo "==== fold26: $P passed, $F failed ===="
[ "$F" = 0 ]
