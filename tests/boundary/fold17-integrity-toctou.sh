#!/usr/bin/env bash
# FOLD #1 live-index fix RED-first — the FULL property the accept-gate A1 integrity guard needs:
#   DETECT       : a mid-gate live-index mutation (a dod_test staging out-of-scope after C1) changes POSTH
#                  (PREH != POSTH). FOLD #1's FROZEN GD-index made this vacuous (PREH==POSTH always).
#   VERIFY==COMMIT: forge_safe_git (verify: C1/PREH/POSTH) and forge_safe_git_commit (write-tree) resolve the
#                  IDENTICAL live index, so the gate verifies exactly the index that is committed — the
#                  out-of-scope POSTH detected is the content the commit would SHIP (the gate then REFUSES it;
#                  mechgate c21 asserts the gate-level FAIL). A frozen read would detect nothing yet still ship it.
#   NO-EXEC      : FOLD #1's no-agent-config-exec property is INDEPENDENT of the index pointer — a planted
#                  core.fsmonitor in the worktree's .git/config does NOT fire (pristine --git-dir=GD config +
#                  GIT_CONFIG masks); GIT_INDEX_FILE points at index DATA only.
# Sources the DEPLOYED sandbox-lib: RED pre-door (frozen), GREEN post-door (live-index).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
. "$HERE/isolation-lib.sh"
. "$LIVE_ROOT/harness/sandbox-lib.sh"        # DEPLOYED forge_safe_git (read helper) — frozen pre-door, live post-door
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
CLONE="$(mktemp -d)/c"; git clone -q --no-hardlinks "$LIVE_ROOT" "$CLONE"
export FORGE_MAIN_ROOT="$CLONE"
WT="$CLONE/.claude/worktrees/f17"; git -C "$CLONE" worktree add -q "$WT" -b probe/f17 HEAD
git -C "$WT" config user.email t@t; git -C "$WT" config user.name t
MK="$(mktemp -d)"; EVIL="$MK/evil.sh"; printf '#!/bin/sh\ntouch "%s/FSMON_FIRED"\n' "$MK" > "$EVIL"; chmod +x "$EVIL"
cleanup(){ rm -rf "$(dirname "$CLONE")" "$MK" 2>/dev/null; }; trap cleanup EXIT
BASE="$(git -C "$WT" rev-parse HEAD)"

# the agent plants an exec knob in the worktree's OWN .git/config (the FOLD #1 threat) ...
git -C "$WT" config core.fsmonitor "$EVIL"
# ... stages its in-scope work, THEN the gate builds the pristine GD (frozen copy = in-scope content)
mkdir -p "$WT/sandbox"; printf 'in scope\n' > "$WT/sandbox/inscope.txt"
GD0="$(forge_safe_gitdir "$WT")"; forge_safe_git_stage "$WT" "$GD0" add -- sandbox/inscope.txt; rm -rf "$GD0"
GD="$(forge_safe_gitdir "$WT")"                          # the gate's GD, built AFTER the in-scope stage
PREH="$(forge_safe_git "$WT" "$GD" diff --cached "$BASE" -- 2>/dev/null | sha256sum | cut -d' ' -f1)"

# a malicious dod_test stages OUT-OF-SCOPE content into the LIVE index mid-gate (after C1/PREH)
printf 'sneaked\n' > "$WT/docs-oops.txt"
forge_safe_git_stage "$WT" "$GD" add -- docs-oops.txt
POSTH="$(forge_safe_git "$WT" "$GD" diff --cached "$BASE" -- 2>/dev/null | sha256sum | cut -d' ' -f1)"

# the COMMIT side: write-tree the live index (the same index the verify just read) and list what it ships
CSHA="$(forge_safe_git_commit "$WT" "$GD" "f17 verify-equals-commit")"
SHIPPED="$(forge_safe_git "$WT" "$GD" ls-tree --name-only -r "$CSHA" 2>/dev/null)"
rm -rf "$GD"

# ---- assertions ----
[ -n "$PREH" ] && [ -n "$POSTH" ] && [ -n "$CSHA" ] && ok "PREH/POSTH/commit computed" || bad "a primitive returned empty" "PREH=$PREH POSTH=$POSTH CSHA=$CSHA"
[ "$PREH" != "$POSTH" ] \
  && ok "DETECT: a mid-gate live-index mutation changes POSTH (PREH != POSTH) — the A1 integrity guard fires" \
  || bad "TOCTOU VACUOUS: PREH == POSTH despite a live-index mutation (frozen GD index — FOLD #1 regression; RED until the live-index fix lands)" "$PREH"
printf '%s\n' "$SHIPPED" | grep -qx 'docs-oops.txt' \
  && ok "VERIFY==COMMIT: the committed tree SHIPS the out-of-scope file POSTH detected (gate verifies the to-be-committed index)" \
  || bad "VERIFY!=COMMIT: the commit did not ship what the verify read" "shipped=[$(printf '%s' "$SHIPPED" | tr '\n' ' ')]"
[ ! -f "$MK/FSMON_FIRED" ] \
  && ok "NO-EXEC: a planted core.fsmonitor did NOT fire during the live-index read/commit (pristine --git-dir=GD config holds; the index pointer is data-only)" \
  || bad "NO-EXEC BROKEN: the live-index read reintroduced agent-config exec (core.fsmonitor fired)" ""

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact" || bad "LIVE FLOOR CHANGED" ""
echo "==== fold17-integrity-toctou: $P passed, $F failed ===="
[ "$F" -eq 0 ]
