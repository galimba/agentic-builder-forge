#!/usr/bin/env bash
# fold29 — forge_hookspath_ok guard-PRESENT canary (lib-function, RED-first, FLOOR-MOVING).
#
# forge_hookspath_ok verified core.hooksPath POINTS at harness/githooks but NOT that an executable pre-commit
# is actually PRESENT there — an EMPTY harness/githooks passed, so the witness minted while the git pre-commit
# tier was inert (live-demonstrated in review). The fix adds `[ -x <hooksdir>/pre-commit ]`. This exercises
# the lib function directly (mirrors fold10). DEFAULT = the DEPLOYED lib (RED: empty-githooks PASSES until the
# splice); FORGE_BOUNDARY_LIB=<candidate> proves GREEN (empty-githooks FAILS).
#
# FLOOR NOTE: FLOOR-MOVING splice; this test asserts only FLOOR_PRE == FLOOR_POST for its own run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
LIB="${FORGE_BOUNDARY_LIB:-$LIVE_ROOT/.claude/hooks/lib.sh}"
. "$LIB"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkrepo() { local r="$TMP/$1"; mkdir -p "$r/harness/githooks"; git -C "$r" init -q -b main >/dev/null 2>&1; git -C "$r" config core.hooksPath harness/githooks; printf '%s' "$r"; }
mkhook() { printf '#!/bin/sh\nexit 0\n' > "$1/harness/githooks/pre-commit"; chmod +x "$1/harness/githooks/pre-commit"; }

# EMPTY githooks (pointed-at, NO pre-commit) — the gap. RED on deployed (PASSES), GREEN on candidate (FAILS).
R="$(mkrepo empty)"
if forge_hookspath_ok "$R"; then bad "empty-githooks still PASSES (guard-present gap open)" "expected FAIL on candidate"; else ok "empty-githooks -> FAIL (guard-present enforced)"; fi

# Executable pre-commit present -> PASS (both deployed and candidate; over-tighten guard).
R="$(mkrepo good)"; mkhook "$R"
forge_hookspath_ok "$R" && ok "executable pre-commit present -> PASS (no over-tighten)" || bad "real pre-commit should PASS" ""

# Present but NON-executable -> FAIL (a chmod-less hook cannot run; candidate closes this too).
R="$(mkrepo nonexec)"; mkhook "$R"; chmod -x "$R/harness/githooks/pre-commit"
if forge_hookspath_ok "$R"; then bad "non-executable pre-commit PASSES (candidate should FAIL)" ""; else ok "non-executable pre-commit -> FAIL"; fi

# Pointer UNSET / WRONG still fail-closed (unchanged by the fix).
R="$TMP/unset"; mkdir -p "$R/harness/githooks"; git -C "$R" init -q -b main >/dev/null 2>&1; mkhook "$R"
forge_hookspath_ok "$R" && bad "unset hooksPath should FAIL" "" || ok "unset hooksPath -> fail-closed (unchanged)"

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "floor unmoved by this run" || bad "this run moved the floor" "$FLOOR_PRE -> $FLOOR_POST"
echo "==== fold29: $P passed, $F failed ===="
[ "$F" = 0 ]
