#!/usr/bin/env bash
# Mechanically certify board-sync.sh is READ-ONLY w.r.t. Beads: in executable code (comments + inline
# comments stripped) there is NO raw `bd` command and NO `.beads/` path. The board contract is read ONLY
# via `run-task.sh board --json`. This is the grep gate the read-only invariant is certified by.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SRC="${FORGE_BOARD_SRC:-$ROOT/harness}/board-sync.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s]\n' "$1"
}
[ -f "$SRC" ] || { echo "no board-sync.sh at $SRC"; exit 1; }
code="$(sed 's/#.*$//' "$SRC")"   # strip full-line + inline comments -> executable code only

echo "== no raw 'bd' command in executable code =="
if printf '%s\n' "$code" | grep -nwE 'bd'; then fail "raw 'bd' token in code"; else pass; fi

echo "== no '.beads/' path reference in executable code =="
if printf '%s\n' "$code" | grep -nF '.beads'; then fail "'.beads' path in code"; else pass; fi

echo "== the only Beads-derived read is run-task.sh board --json =="
{ grep -qF 'run-task.sh' "$SRC" && grep -qF 'board --json' "$SRC"; } && pass || fail "expected run-task.sh board --json read path"

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
