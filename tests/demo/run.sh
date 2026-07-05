#!/usr/bin/env bash
# First-run demo canary (Phase 5c). Proves `.forge/scripts/demo.sh` drives the FULL governed
# target-repo loop OFFLINE — a throwaway forge (fresh ledger) + a throwaway target — to a pristine
# commit that carries the product and ZERO forge artifacts, and leaves the LIVE tree/ledger untouched.
#
# The demo is an ATTENDED host-side run (FORGE_TARGET_CONTAINER=0 → the container boundary is off, so
# the loop requires a TTY), so this canary drives it under a pty via script(1). Needs git, bd, jq, and
# script(1); SKIPs honestly if any is absent. This suite does NOT move the floor.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
DEMO="$ROOT/.forge/scripts/demo.sh"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
skip(){ echo "  SKIP ($1)"; echo "==== demo: SKIP ===="; exit 75; }

[ -f "$DEMO" ] || skip "demo.sh absent"
for t in git bd jq script; do command -v "$t" >/dev/null 2>&1 || skip "needs '$t' on PATH"; done

FLOOR_PRE="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
STAT_PRE="$(git -C "$ROOT" status --porcelain 2>/dev/null)"   # live-tree pollution baseline

# Drive the demo under a pty (the attended host-side gate reads a TTY). script -e returns the child's
# exit code; bound it well above the demo's internal 60s finish-push timeout.
LOG="$(mktemp)"
timeout 180 script -qec "bash '$DEMO'" "$LOG" >/dev/null 2>&1; rc=$?
out="$(tr -d '\r' < "$LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"; rm -f "$LOG"

echo "== the governed loop reached a pristine product commit, offline =="
[ "$rc" -eq 0 ] && ok "demo exits 0 (the whole loop ran end-to-end)" || { bad "demo exited rc=$rc" "$(printf '%s' "$out" | tail -3)"; }
printf '%s\n' "$out" | grep -q 'about.html IS in the commit' && ok "product committed (scope + sc_evidence passed the acceptance gate)" || bad "product not in the commit"
printf '%s\n' "$out" | grep -q 'ZERO forge/.claude/.beads/harness artifacts' && ok "commit is pristine (no forge artifacts leaked to the target)" || bad "pristine assertion not shown"
printf '%s\n' "$out" | grep -q 'stopped offline' && ok "push stopped offline (the human-merge boundary)" || bad "offline push boundary not shown"
printf '%s\n' "$out" | grep -q 'Demo complete' && ok "demo cleaned up its temp tree" || bad "demo did not reach completion"

echo "== the demo left the LIVE forge untouched =="
STAT_POST="$(git -C "$ROOT" status --porcelain 2>/dev/null)"
[ "$STAT_PRE" = "$STAT_POST" ] && ok "live working tree unchanged by the demo" || bad "the demo mutated the live tree" "$(diff <(printf '%s' "$STAT_PRE") <(printf '%s' "$STAT_POST") | head -4)"
git -C "$ROOT" worktree list 2>/dev/null | grep -q 'add-an-about-page' && bad "a demo worktree leaked into the live forge" || ok "no demo worktree leaked into the live forge"

FLOOR_POST="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
{ [ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ]; } && ok "this run did not move the floor" || bad "lib.sh changed during the run"

echo "==== demo: $P passed, $F failed ===="
[ "$F" -eq 0 ]
