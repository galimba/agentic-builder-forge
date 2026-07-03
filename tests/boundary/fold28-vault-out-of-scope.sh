#!/usr/bin/env bash
# fold28 — vault RE-SCOPE canary (JSON-stdin, RED-first, FLOOR-MOVING).
#
# POLICY (human-ratified): a sibling vault (e.g. ../my-vault) is an EXTERNAL target repo, NOT a forge component. The
# floor protects the forge's OWN load-bearing paths — it makes NO vault claim. The old blunt whole-command /
# file_path `grep <vault-path> -> deny` (a) OVER-BLOCKED vault READS (`cat ../my-vault/x` was denied — DX
# friction) and (b) made a false "vault writes all DENY, fail closed" claim that leaked (F1 multi-digit-fd, F2
# funsub). The re-scope DROPS both greps. This canary regression-LOCKS the re-scope: the floor must NOT
# deny vault READS or ABSOLUTE vault WRITES (they are out of forge scope; the target's / OS container's
# concern). A RELATIVE `../my-vault/...` write STILL denies, but via the GENERAL
# `..`-unverifiable rule (NOT a vault claim) — asserted here so the re-scope is not mistaken for "vault writes
# are now unprotected on every path". RED pre-splice (deployed denies the reads/abs-writes via the grep),
# GREEN post-splice. FORGE_GUARD_DENY / FORGE_LIVE_ROOT override the hook + root to prove GREEN against the
# candidate overlay before the splice.
#
# FLOOR NOTE: FLOOR-MOVING splice; this test asserts only FLOOR_PRE == FLOOR_POST for its own run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
HOOK="${FORGE_GUARD_DENY:-$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh}"
command -v jq >/dev/null 2>&1 || { echo "fold28: SKIP — jq required to drive the hook"; exit 75; }
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
V="my-""vault"
ABS="/home/user/repos/$V"   # an absolute path naming the vault dir

verdict() { # <cmd> -> DENY | ALLOW  (Bash tier)
  local out
  out="$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | ( cd "$LIVE_ROOT" && bash "$HOOK" 2>/dev/null ))"
  printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && printf DENY || printf ALLOW
}
wverdict() { # <file_path> -> DENY | ALLOW  (Write/Edit file_path tier)
  local out
  out="$(jq -nc --arg p "$1" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}' | ( cd "$LIVE_ROOT" && bash "$HOOK" 2>/dev/null ))"
  printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && printf DENY || printf ALLOW
}

# ALLOW: vault READS — the floor makes no vault claim; the over-block is gone. RED on the deployed floor.
allow_read=(
  "cat ../$V/wiki/x.md"
  "ls ../$V/"
  "ls -la ../$V/memory"
  "grep -r foo ../$V/wiki"
  "head -20 ../$V/README.md"
  "tail -n 5 ../$V/log"
  "wc -l ../$V/wiki/x.md"
  "diff ../$V/a ../$V/b"
  "stat ../$V/wiki/x.md"
  "cat ../$V/a && cat ../$V/b"
  "cat ../$V/a | grep foo"
  "cat ../$V/a & echo done"
  "cat ../$V/\${SUBDIR}/x.md"
  "cat ../$V/x.md 2>/dev/null"
  "cat ../$V/x.md 2>&1"
  "cat ../$V/x.md >/tmp/out"
)
# ALLOW: ABSOLUTE vault WRITES / edits / cd-into-vault — OUT OF FORGE SCOPE (the floor makes no vault claim;
# the OS container / the target repo is the boundary). RED on the deployed floor (the grep denied these).
allow_write=(
  "echo x > $ABS/wiki/f.md"
  "cp evil $ABS/wiki/f.md"
  "sed -i s/a/b/ $ABS/wiki/f.md"
  "tee $ABS/f"
  "cd ../$V && echo x > wiki/f.md"
  "xxd -r payload.hex $ABS/evil"
)
# DENY: a RELATIVE `..`-bearing vault write STAYS denied — but via the GENERAL `..`-unverifiable rule, NOT a
# vault claim (the SAME rule denies any `..`-bearing write target). This documents that the re-scope did not
# make every vault path writable.
deny_rel=(
  "echo x > ../$V/f"
  "printf z >> ../$V/wiki/f"
)
echo "== fold28 RE-SCOPE: vault reads + ABS writes are OUT OF SCOPE (ALLOW, RED-first); rel-.. writes deny via general rule =="
for c in "${allow_read[@]}";  do v="$(verdict "$c")"; [ "$v" = ALLOW ] && ok "ALLOW read  $c" || bad "expected ALLOW got $v" "$c"; done
for c in "${allow_write[@]}"; do v="$(verdict "$c")"; [ "$v" = ALLOW ] && ok "ALLOW write $c (out of scope)" || bad "expected ALLOW got $v" "$c"; done
for c in "${deny_rel[@]}";    do v="$(verdict "$c")"; [ "$v" = DENY  ] && ok "DENY  rel   $c (general .. rule)" || bad "expected DENY got $v" "$c"; done
# Write/Edit file_path tier: an ABSOLUTE vault path is OUT OF SCOPE (ALLOW); a '..'-bearing one denies via the
# general traversal rule; a sandbox file merely NAMED with the vault string is a normal sandbox write (ALLOW).
wa="$(wverdict "$ABS/wiki/z.md")";     [ "$wa" = ALLOW ] && ok "ALLOW  Write abs vault (out of forge scope)" || bad "expected ALLOW got $wa" "Write abs vault"
wr="$(wverdict "../$V/wiki/z.md")";    [ "$wr" = DENY  ] && ok "DENY   Write ../vault (general .. rule)"      || bad "expected DENY got $wr"  "Write rel vault"
wb="$(wverdict "sandbox/${V}-notes.md")"; [ "$wb" = ALLOW ] && ok "ALLOW  Write sandbox/${V}-notes.md (normal sandbox file)" || bad "expected ALLOW got $wb" "Write vault-named sandbox file"

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "floor unmoved by this run" || bad "this run moved the floor" "$FLOOR_PRE -> $FLOOR_POST"
echo "==== fold28: $P passed, $F failed ===="
[ "$F" = 0 ]
