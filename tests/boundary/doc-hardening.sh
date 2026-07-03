#!/usr/bin/env bash
# Convergence-sweep hardenings (RED-first):
#  DOC-1: an exported GIT_DIR/GIT_COMMON_DIR must NOT redirect ROOT — the harness unset (run-task/accept-gate
#         head) strips it before forge_main_root (a bare git rev-parse). RED control: WITHOUT the unset, it redirects.
#  DOC-2: forge_clean_env strips a poisoned bd-env (the accept-gate:302 third bd call site routes through it).
#  DOC-3: the commit/stage helpers resolve the index ABSOLUTELY (CWD-independent), so a primary checkout's
#         relative `.git/index` can't make write-tree read the wrong index from a foreign CWD.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
. "$LIVE_ROOT/.claude/hooks/lib.sh"          # forge_main_root (DOC-1)
. "$LIVE_ROOT/harness/sandbox-lib.sh"        # DEPLOYED helpers (DOC-3 absolute idx) + forge_safe_env
forge_clean_env() { env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" "$@"; }
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
TMP="$(mktemp -d)"; cleanup(){ rm -rf "$TMP" 2>/dev/null; }; trap cleanup EXIT

# ---- DOC-1: GIT_DIR redirect of forge_main_root ----
CL="$TMP/clone"; git clone -q --no-hardlinks "$LIVE_ROOT" "$CL"
EVIL="$TMP/evil.git"; git init -q --bare "$EVIL"
real="$(cd "$CL" && forge_main_root)"
red="$(cd "$CL" && GIT_DIR="$EVIL" forge_main_root 2>/dev/null)"
[ "$red" != "$real" ] && ok "DOC-1 RED CONTROL: an exported GIT_DIR redirects forge_main_root (got $red, real $real)" || bad "DOC-1 control: GIT_DIR did not redirect (cannot prove the fix)" "red=$red"
green="$(cd "$CL" && export GIT_DIR="$EVIL"; unset GIT_DIR GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE GIT_WORK_TREE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM; forge_main_root 2>/dev/null)"
[ "$green" = "$real" ] && ok "DOC-1 FIX: after the harness unset, forge_main_root resolves the REAL root despite an exported GIT_DIR" || bad "DOC-1: unset did not restore real root" "green=$green real=$real"

# ---- DOC-2: forge_clean_env strips a poisoned bd-env (the :302 routing) ----
for v in GIT_DIR GIT_CONFIG_COUNT GH_CONFIG_DIR; do
  got="$(export $v=/tmp/poison; forge_clean_env printenv "$v" 2>/dev/null)"
  [ -z "$got" ] && ok "DOC-2: forge_clean_env strips poisoned $v before bd/timeout" || bad "DOC-2 leaked $v" "got=$got"
done
grep -q 'forge_clean_env timeout 30 "$BD_BIN"' "$LIVE_ROOT/harness/accept-gate.sh" && ok "DOC-2: deployed accept-gate:302 bead read routes through forge_clean_env timeout" || bad "DOC-2: accept-gate:302 not routed through forge_clean_env" ""

# ---- DOC-3: absolute index on a PRIMARY checkout, write-tree from a foreign CWD ----
PC="$TMP/primary"; git clone -q --no-hardlinks "$LIVE_ROOT" "$PC"
git -C "$PC" config user.email t@t; git -C "$PC" config user.name t
idx_rel="$(cd "$PC" && git rev-parse --git-path index)"
idx_abs="$(forge_safe_env -- git -C "$PC" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
case "$idx_rel" in /*) bad "DOC-3 control: index path already absolute on this git (cannot show the trap)" "$idx_rel";; *) ok "DOC-3 RED CONTROL: bare --git-path index is RELATIVE ($idx_rel) — resolved against CWD, the wrong-index trap";; esac
case "$idx_abs" in /*) ok "DOC-3: --path-format=absolute yields an ABSOLUTE index ($idx_abs)";; *) bad "DOC-3: absolute flag did not yield absolute path" "$idx_abs";; esac
# end-to-end from a FOREIGN cwd (TMP, not PC): stage+commit must capture the real staged content
printf 'doc3 payload\n' > "$PC/d3.txt"
( cd "$TMP" && GD="$(forge_safe_gitdir "$PC")"; forge_safe_git_stage "$PC" "$GD" add -- d3.txt
  CSHA="$(forge_safe_git_commit "$PC" "$GD" "doc3 commit")"; rm -rf "$GD"
  git -C "$PC" cat-file -p "$CSHA^{tree}" 2>/dev/null | grep -q 'd3.txt' && exit 0 || exit 1 )
[ $? -eq 0 ] && ok "DOC-3 FIX: commit from a FOREIGN cwd captured the real staged file (absolute index, not a wrong/empty tree)" || bad "DOC-3: commit tree missing the staged file (wrong index)" ""

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact" || bad "LIVE FLOOR CHANGED" "$FLOOR_PRE -> $FLOOR_POST"
echo "==== doc-hardening: $P passed, $F failed ===="
[ "$F" -eq 0 ]
