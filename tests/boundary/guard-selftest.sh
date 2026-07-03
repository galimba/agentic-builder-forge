#!/usr/bin/env bash
# ISOLATION GUARD self-test — proves forge_assert_isolated resolves the FINAL targets, defeating
# symlink/realpath escapes, not just source= strings. No container; pure guard logic.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/isolation-lib.sh"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE="$(dirname "$_gcd")"
MAN="$LIVE/harness/sandbox/devcontainer.json"            # real (FORGE_MAIN_ROOT-relative) manifest
BADMAN="$HERE/bad-literal/.devcontainer.json"            # literal live source= manifest
PASS=0; FAIL=0
chk() { # <name> <expected-rc> <fmr> <manifest>
  local name="$1" exp="$2" fmr="$3" man="$4" out rc
  out="$(forge_assert_isolated "$LIVE" "$fmr" "$man" 2>&1)"; rc=$?
  if [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); printf '  PASS [%s] rc=%s\n' "$name" "$rc"
  else FAIL=$((FAIL+1)); printf '  FAIL [%s] rc=%s exp=%s :: %s\n' "$name" "$rc" "$exp" "$out"; fi
}

# clean isolated root: a temp dir OUTSIDE live with real (non-symlink) sub-dirs -> rc 0
CLEAN="$(mktemp -d)/clone"; mkdir -p "$CLEAN/harness/sandbox" "$CLEAN/.claude/hooks" "$CLEAN/.git/hooks"
cp "$MAN" "$CLEAN/harness/sandbox/devcontainer.json"
chk "clean isolated clone -> OK" 0 "$CLEAN" "$CLEAN/harness/sandbox/devcontainer.json"

# (string) literal live source= in the manifest -> BREACH
chk "literal live source= manifest -> BREACH" 3 "$CLEAN" "$BADMAN"

# (case i) FORGE_MAIN_ROOT is a symlink that realpaths INTO the live repo -> BREACH
LNK="$(mktemp -d)/fmr-into-live"; ln -s "$LIVE" "$LNK"
chk "FORGE_MAIN_ROOT symlink -> live -> BREACH" 3 "$LNK" "$MAN"

# (case ii) a clone-relative target (.claude) that is itself a SYMLINK into the live tree -> BREACH
ESC="$(mktemp -d)/esc"; mkdir -p "$ESC/harness/sandbox" "$ESC/.git/hooks"; cp "$MAN" "$ESC/harness/sandbox/devcontainer.json"
ln -s "$LIVE/.claude" "$ESC/.claude"                     # the bind mount would FOLLOW this into live
chk "clone .claude symlink -> live .claude -> BREACH" 3 "$ESC" "$ESC/harness/sandbox/devcontainer.json"

# (case ii, dotdot) a target that uses .. to climb back to live -> BREACH
DD="$(mktemp -d)/dd"; mkdir -p "$DD/harness/sandbox" "$DD/.git/hooks"; cp "$MAN" "$DD/harness/sandbox/devcontainer.json"
ln -s "$LIVE/.claude" "$DD/.claude"
chk "clone target climbs to live via symlink -> BREACH" 3 "$DD" "$DD/harness/sandbox/devcontainer.json"

echo "==== guard self-test: $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
