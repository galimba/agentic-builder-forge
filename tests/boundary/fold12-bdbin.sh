#!/usr/bin/env bash
# FOLD #12 RED-first: an agent-exported BD_BIN (or PATH-shim) must NOT be honored on the finish path.
# run-task.sh must `unset BD_BIN` (matching the accept-gate's own unset) so beads.config's absolute default wins and the
# finish/reconcile bd channel cannot run a shimmed binary. RED control: WITHOUT the unset, beads-lib pins the
# exported shim. FIX: with the unset + beads.config, the absolute default wins. Plus a deployed-grep canary.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
TMP="$(mktemp -d)"; cleanup(){ rm -rf "$TMP" 2>/dev/null; }; trap cleanup EXIT
SHIM="$TMP/evil-bd"; printf '#!/bin/sh\necho SHIM\n' > "$SHIM"; chmod +x "$SHIM"

# RED CONTROL: an exported BD_BIN shim, sourced WITHOUT a prior unset, is captured by beads-lib:14.
red="$(export BD_BIN="$SHIM"; . "$LIVE_ROOT/harness/beads-lib.sh" >/dev/null 2>&1; printf '%s' "${BD_BIN:-}")"
[ "$red" = "$SHIM" ] && ok "RED CONTROL: without unset, an exported BD_BIN shim is honored ($red)" || bad "control: shim not honored (cannot show the trap)" "red=$red"

# FIX: unset BD_BIN before sourcing beads-lib AND before loading beads.config -> the absolute config default wins.
green="$(export BD_BIN="$SHIM"; unset BD_BIN; . "$LIVE_ROOT/harness/beads-lib.sh" >/dev/null 2>&1; unset BD_BIN; . "$LIVE_ROOT/harness/beads.config" >/dev/null 2>&1; printf '%s' "${BD_BIN:-}")"
[ "$green" != "$SHIM" ] && [ -n "$green" ] && ok "FIX: with the double-unset, beads.config's absolute default wins, NOT the shim ($green)" || bad "FIX: shim still honored after unset" "green=$green"

# CANARY: the DEPLOYED run-task must carry the two FOLD #12 unsets (RED pre-door, GREEN post-door).
n="$(grep -c '^unset BD_BIN$' "$LIVE_ROOT/harness/run-task.sh" 2>/dev/null || echo 0)"
[ "$n" -ge 2 ] && ok "CANARY: deployed run-task.sh carries the FOLD #12 double-unset BD_BIN ($n)" || bad "CANARY: run-task.sh missing the FOLD #12 unset (RED until the door lands)" "count=$n"

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact" || bad "LIVE FLOOR CHANGED" ""
echo "==== fold12-bdbin: $P passed, $F failed ===="
[ "$F" -eq 0 ]
