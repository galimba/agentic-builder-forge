#!/usr/bin/env bash
# Integration tests for harness/board-sync.sh against a stateful fake `gh` + board --json fixtures.
# Proves: fail-loud schema validation, six-lane upsert (Bead ID first), idempotent zero-write re-run,
# Beads-wins overwrite, archive-on-absence (A), refuse-loud on dup Bead ID, and check drift detection.
#
#   bash tests/board-sync/run.sh                                  # tests the DEPLOYED harness/board-sync.sh
#   FORGE_BOARD_SRC=$PWD/sandbox/board bash tests/board-sync/run.sh  # tests a candidate copy
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SRC="${FORGE_BOARD_SRC:-$ROOT/harness}"
FIX="$ROOT/tests/board-sync"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s]\n' "$1"
}
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cp "$FIX/fakes/gh" "$T/bin/gh" && chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_STATE="$T/state.json" GH_CALLS="$T/calls.log"
export BOARD_GH_KEEP_TOKEN=1 BOARD_CONFIG="$FIX/board.config" BOARD_SYNC_STATE="$T/sync-state.json"
SYNC() { bash "$SRC/board-sync.sh" "$@"; }
reset() { printf '{"items":[],"seq":0}' >"$GH_STATE"; : >"$GH_CALLS"; rm -f "$BOARD_SYNC_STATE"; }
istatus() { jq -r --arg b "$1" '.items[]|select(.fields["Bead ID"]==$b)|.fields["Status"]//""' "$GH_STATE"; }
ifield() { jq -r --arg b "$1" --arg k "$2" '.items[]|select(.fields["Bead ID"]==$b)|.fields[$k]//""' "$GH_STATE"; }
icount() { jq '.items|length' "$GH_STATE"; }
MAIN="$FIX/fixtures/contract-main.json"; DROP="$FIX/fixtures/contract-drop.json"

echo "== dry-run (empty board, 4-bead contract): plans 4 CREATE, NO writes =="
reset
out="$(BOARD_JSON_FILE="$MAIN" SYNC dry-run 2>&1)"
echo "$out" | grep -qE "create:4 update:0 archive:0" && pass || fail "dry-run plans 4 creates"
[ "$(icount)" -eq 0 ] && pass || fail "dry-run made NO writes"
echo "$out" | grep -q "DRY-RUN" && pass || fail "dry-run banner"

echo "== sync (empty board): create 4 items, correct lanes + fields =="
reset
BOARD_JSON_FILE="$MAIN" SYNC sync >/dev/null 2>&1 && pass || fail "sync exit 0"
[ "$(icount)" -eq 4 ] && pass || fail "4 items created (got $(icount))"
[ "$(istatus fx-a01)" = "In review" ] && pass || fail "fx-a01 in_review -> In review (got '$(istatus fx-a01)')"
[ "$(istatus fx-b02)" = "Blocked" ] && pass || fail "fx-b02 open+blocker -> Blocked (got '$(istatus fx-b02)')"
[ "$(istatus fx-c03)" = "Ready" ] && pass || fail "fx-c03 ready -> Ready (got '$(istatus fx-c03)')"
[ "$(istatus fx-d04)" = "Done" ] && pass || fail "fx-d04 closed -> Done (got '$(istatus fx-d04)')"
[ "$(ifield fx-d04 Priority)" = "P0" ] && pass || fail "fx-d04 priority 0 -> P0"
[ "$(ifield fx-c03 Priority)" = "P3" ] && pass || fail "fx-c03 priority 3 -> P3"
[ "$(ifield fx-b02 Blocked-by)" = "fx-a01" ] && pass || fail "fx-b02 Blocked-by fx-a01 (got '$(ifield fx-b02 Blocked-by)')"
[ "$(ifield fx-a01 'Bead Assignee')" = "forge-local" ] && pass || fail "fx-a01 assignee verbatim"
[ "$(ifield fx-c03 'Bead Assignee')" = "" ] && pass || fail "fx-c03 null assignee -> empty"

echo "== idempotent re-run: ZERO writes =="
: >"$GH_CALLS"
out="$(BOARD_JSON_FILE="$MAIN" SYNC sync 2>&1)"
echo "$out" | grep -qE "create:0 update:0 archive:0 unchanged:4" && pass || fail "idempotent counts ($out)"
grep -qE "item-create|item-edit|item-archive|project edit" "$GH_CALLS" && fail "re-run must make ZERO writes" || pass

echo "== Beads-wins: hand-edit a board field -> re-run overwrites it back =="
jq '(.items[]|select(.fields["Bead ID"]=="fx-c03")|.fields["Status"])="Backlog"' "$GH_STATE" >"$T/x" && mv "$T/x" "$GH_STATE"
out="$(BOARD_JSON_FILE="$MAIN" SYNC sync 2>&1)"
echo "$out" | grep -q "UPDATE  fx-c03" && pass || fail "detects the hand-edit on fx-c03"
[ "$(istatus fx-c03)" = "Ready" ] && pass || fail "Beads-wins: fx-c03 restored to Ready (got '$(istatus fx-c03)')"

echo "== archive-on-absence (A): bead drops from contract -> item archived =="
out="$(BOARD_JSON_FILE="$DROP" SYNC sync 2>&1)"
echo "$out" | grep -q "ARCHIVE fx-c03" && pass || fail "archives fx-c03 on absence"
[ -z "$(istatus fx-c03)" ] && pass || fail "fx-c03 removed from board"
[ "$(icount)" -eq 3 ] && pass || fail "3 items remain (got $(icount))"

echo "== refuse-loud on duplicate Bead ID on the board =="
reset
printf '{"items":[{"id":"PVTI_1","fields":{"Bead ID":"fx-x","Title":"a"}},{"id":"PVTI_2","fields":{"Bead ID":"fx-x","Title":"b"}}],"seq":2}' >"$GH_STATE"
BOARD_JSON_FILE="$MAIN" SYNC sync >/dev/null 2>&1 && fail "must refuse on dup Bead ID" || pass

echo "== fail-loud schema validation =="
reset
echo '[{"id":"fx-z","title":"x","status":"open","ready":false,"priority":1,"blockers":[]}]' >"$T/bad-missing.json"
BOARD_JSON_FILE="$T/bad-missing.json" SYNC dry-run >/dev/null 2>&1 && fail "must fail on missing key (assignee)" || pass
echo '[{"id":"fx-z","title":"x","status":"frozen","ready":false,"priority":1,"blockers":[],"assignee":null}]' >"$T/bad-status.json"
BOARD_JSON_FILE="$T/bad-status.json" SYNC dry-run >/dev/null 2>&1 && fail "must fail on unknown status" || pass
echo '[{"id":"fx-z","title":"x","status":"open","ready":"yes","priority":1,"blockers":[],"assignee":null}]' >"$T/bad-type.json"
BOARD_JSON_FILE="$T/bad-type.json" SYNC dry-run >/dev/null 2>&1 && fail "must fail on bad ready type" || pass

echo "== check: FRESH after sync, DRIFT after contract change =="
reset
BOARD_JSON_FILE="$MAIN" SYNC sync >/dev/null 2>&1
BOARD_JSON_FILE="$MAIN" SYNC check >/dev/null 2>&1 && pass || fail "check FRESH right after sync"
BOARD_JSON_FILE="$DROP" SYNC check >/dev/null 2>&1 && fail "check must report DRIFT (exit 1) on contract change" || pass

echo
echo "==== $PASS passed, $FAIL failed (src: $SRC) ===="
[ "$FAIL" = 0 ]
