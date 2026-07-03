#!/usr/bin/env bash
# Contract unit tests for the Beads integration.
#
# Pins the pure functions in harness/beads-lib.sh against REAL captured bd v1.0.4 JSON shapes
# (tests/beads/fixtures/*). These encode the now-verified contract:
#   - forge_beads_project        : list+ready JSON -> the stable 7-key board projection
#   - forge_beads_claimable      : fail-closed claim decision (ready ∧ unassigned)
#   - forge_beads_reconcile_decision : in_review + merged -> close (mechanical, event-derived)
#   - forge_beads_release_args   : kill-switch unclaim args
#   - forge_beads_check_version  : BD_VERSION_PIN guard (a bd upgrade can drift the JSON shape)
#   - forge_beads_status_declared: custom in_review declared at setup (sequencing guard)
#
# RED until harness/beads-lib.sh is implemented + spliced (TDD). Then GREEN, unchanged.
# Run: bash tests/beads/run.sh   (or: pnpm test:beads)
# Pre-splice check vs a candidate: FORGE_BEADS_LIB=path/to/candidate/beads-lib.sh bash tests/beads/run.sh
#
# NOTE the directory is tests/beads/ — NOT tests/harness/: the deny hook's ENFORCE_RE matches the
# substring '/harness/', so a tests/harness/ path would be (correctly) treated as a protected file.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${FORGE_BEADS_LIB:-$ROOT/harness/beads-lib.sh}"
FIX="$ROOT/tests/beads/fixtures"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s]\n' "$1"
}
have() { declare -F "$1" >/dev/null 2>&1; }

# Source the (future) lib. Absent now -> functions undefined -> the groups below fail RED.
# shellcheck disable=SC1090
[ -f "$LIB" ] && . "$LIB" 2>/dev/null
# Unit defaults so the projection's blocking-type filter is self-contained without beads.config.
: "${BD_BLOCKING_TYPES:=blocks}"

echo "== forge_beads_project: the 7-key board contract (real bd shapes) =="
if have forge_beads_project; then
  got="$(forge_beads_project "$FIX/list.json" "$FIX/ready.json" 2>/dev/null | jq -S -c '.' 2>/dev/null)"
  exp="$(jq -S -c '.' "$FIX/expected-board.json")"
  if [ -n "$got" ] && [ "$got" = "$exp" ]; then
    pass
  else
    fail "projection mismatch"
    printf '  expected: %s\n  got:      %s\n' "$exp" "${got:-<empty>}"
  fi
else
  fail "forge_beads_project not defined (beads-lib.sh not implemented yet)"
fi

echo "== forge_beads_project: closed beads project to the Done lane (D12) =="
if have forge_beads_project; then
  # A closed bead (not in the ready set) must project with status:closed, ready:false. The 7-key
  # contract is unchanged — closed_at is bd's window filter, not a board field.
  got="$(forge_beads_project "$FIX/list-closed.json" "$FIX/ready.json" 2>/dev/null)"
  if echo "$got" | jq -e 'any(.[]; .id=="fx-d04" and .status=="closed" and .ready==false)' >/dev/null 2>&1; then pass; else fail "closed bead must project status:closed, ready:false"; fi
else
  fail "forge_beads_project not defined (D12 closed projection)"
fi

echo "== forge_beads_claimable: fail-closed claim decision =="
if have forge_beads_claimable; then
  if forge_beads_claimable "$FIX/show-c03.json" "$FIX/ready.json" 2>/dev/null; then pass; else fail "C (ready, unassigned) SHOULD be claimable"; fi
  if forge_beads_claimable "$FIX/show-a01.json" "$FIX/ready.json" 2>/dev/null; then fail "A (in_review, assigned) must NOT be claimable"; else pass; fi
  if forge_beads_claimable "$FIX/show-b02.json" "$FIX/ready.json" 2>/dev/null; then fail "B (blocked, not ready) must NOT be claimable"; else pass; fi
  if forge_beads_claimable "$FIX/empty.json" "$FIX/ready.json" 2>/dev/null; then fail "missing bead must NOT be claimable (fail closed)"; else pass; fi
else
  fail "forge_beads_claimable not defined (x4)"
fi

echo "== forge_beads_reconcile_decision: merge -> close (event-derived) =="
if have forge_beads_reconcile_decision; then
  [ "$(forge_beads_reconcile_decision in_review true 2>/dev/null)" = "close" ] && pass || fail "in_review + merged -> close"
  [ "$(forge_beads_reconcile_decision in_review false 2>/dev/null)" = "skip" ] && pass || fail "in_review + open PR -> skip"
else
  fail "forge_beads_reconcile_decision not defined (x2)"
fi

echo "== forge_beads_release_args: kill-switch unclaim =="
if have forge_beads_release_args; then
  out="$(forge_beads_release_args fx-a01 2>/dev/null)"
  case "$out" in *fx-a01*) pass ;; *) fail "release args must name the bead" ;; esac
  case "$out" in *"--status open"*) pass ;; *) fail "release must set status open" ;; esac
  case "$out" in *"--assignee"*) pass ;; *) fail "release must clear assignee" ;; esac
else
  fail "forge_beads_release_args not defined (x3)"
fi

echo "== forge_beads_check_version: BD_VERSION_PIN is load-bearing (catch JSON-shape drift) =="
if have forge_beads_check_version; then
  if forge_beads_check_version "1.0.4" "1.0.4"; then pass; else fail "matching version SHOULD pass"; fi
  if forge_beads_check_version "1.0.5" "1.0.4"; then fail "mismatched version must FAIL (shape may have drifted)"; else pass; fi
  if forge_beads_check_version "" "1.0.4"; then fail "empty version must FAIL closed"; else pass; fi
else
  fail "forge_beads_check_version not defined (x3)"
fi

echo "== forge_beads_status_declared: custom in_review must be declared at setup =="
if have forge_beads_status_declared; then
  printf 'Custom statuses:\n  in_review      [wip]\n' | forge_beads_status_declared in_review && pass || fail "declared in_review SHOULD be detected"
  printf 'Built-in statuses:\n  open\n  closed\n' | forge_beads_status_declared in_review && fail "undeclared in_review must NOT be detected" || pass
else
  fail "forge_beads_status_declared not defined (x2)"
fi

echo "== R-13 permanence gate: host-side pnpm install stays hardened =="
# Comment lines are filtered (a flag-mentioning comment must not satisfy the guard), and EVERY
# remaining `pnpm install` line must carry both flags — one hardened line cannot excuse a second
# unhardened install. ≥1 install line must exist (fail-closed if the line vanishes).
# Permanence gate: a future edit
# dropping either flag from the host-side `pnpm install` in harness/run-task.sh turns this gate RED.
r13_installs="$(grep 'pnpm install' "$ROOT/harness/run-task.sh" | grep -v -E '^[[:space:]]*#')"
if [ -n "$r13_installs" ] && ! printf '%s\n' "$r13_installs" | grep -qv -- '--ignore-scripts'; then pass; else fail "run-task.sh host install missing --ignore-scripts (R-13 hardening regressed)"; fi
if [ -n "$r13_installs" ] && ! printf '%s\n' "$r13_installs" | grep -qv -- '--frozen-lockfile'; then pass; else fail "run-task.sh host install missing --frozen-lockfile (R-13 hardening regressed)"; fi

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
