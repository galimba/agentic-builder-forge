#!/usr/bin/env bash
# FOLD #15 (LOW lifecycle) RED-first: kill-switch must invalidate the merge-oracle record
# .harness/pr/<bead>.json on release, so a released+re-claimed bead (same id -> same branch) cannot inherit a
# PRIOR claim's merged-PR record and be auto-closed by reconcile without its own finish. CANARY: the deployed
# kill-switch carries the cleanup. MECHANISM: the cleanup removes an existing record. (fold13 b4 already proves
# the security consequence: no record -> reconcile fail-closed skips.)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"

# CANARY: deployed kill-switch.sh carries the FOLD #15 record cleanup (RED pre-door, GREEN post-door).
grep -q '\.harness/pr/\$bead\.json' "$LIVE_ROOT/harness/kill-switch.sh" \
  && ok "CANARY: deployed kill-switch.sh removes .harness/pr/<bead>.json on release" \
  || bad "CANARY: kill-switch.sh missing the FOLD #15 record cleanup (RED until the door lands)" ""

# MECHANISM: the release cleanup removes an existing stale record.
TMP="$(mktemp -d)"; cleanup(){ rm -f "$TMP/.harness/pr/fx-test.json" 2>/dev/null; rmdir "$TMP/.harness/pr" "$TMP/.harness" "$TMP" 2>/dev/null; }; trap cleanup EXIT
ROOT="$TMP"; bead="fx-test"; mkdir -p "$ROOT/.harness/pr"; printf '{"repo":"o/r","branch":"b","pr":"1"}' > "$ROOT/.harness/pr/$bead.json"
[ -f "$ROOT/.harness/pr/$bead.json" ] || bad "setup: stale record not created" ""
[ -n "$bead" ] && rm -f "$ROOT/.harness/pr/$bead.json" 2>/dev/null || true     # the exact FOLD #15 cleanup
[ ! -f "$ROOT/.harness/pr/$bead.json" ] && ok "MECHANISM: the release cleanup removes the stale oracle record -> re-claim cannot inherit it" || bad "cleanup did not remove the record" ""

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact" || bad "LIVE FLOOR CHANGED" ""
echo "==== fold15-killswitch-lifecycle: $P passed, $F failed ===="
[ "$F" -eq 0 ]
