#!/usr/bin/env bash
# Integration tests for harness/board-bootstrap.sh — drives ensure -> idempotent re-run -> verify against
# a stateful fake `gh`. Asserts: create-path mutates + emits config; a re-run makes ZERO create/reshape
# calls (idempotency); verify exits 0 on a complete board and FAILS CLOSED on a missing one.
#
#   bash tests/board/run.sh                                  # tests the DEPLOYED harness/board-bootstrap.sh
#   FORGE_BOARD_SRC=$PWD/sandbox/board bash tests/board/run.sh # tests a candidate copy
#
# NOTE the directory is tests/board/ — NOT tests/harness/: the deny hook's ENFORCE_RE matches '/harness/',
# so a tests/harness/ path would be (correctly) treated as a protected file.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SRC="${FORGE_BOARD_SRC:-$ROOT/harness}"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s]\n' "$1"
}
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cp "$ROOT/tests/board/fakes/gh" "$T/bin/gh" && chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_STATE="$T/state.json" GH_CALLS="$T/calls.log"
export BOARD_OWNER="t-owner" BOARD_CONFIG="$T/board.config" BOARD_GH_KEEP_TOKEN=1

# A fresh org project: not yet created, with the built-in Title + Status(Todo/In Progress/Done).
fresh() {
  printf '%s' '{"created":false,"number":3,"node":"PVT_fake","title":"","fields":[{"id":"PVTF_title","name":"Title","options":[]},{"id":"PVTSSF_status","name":"Status","options":[{"id":"t","name":"Todo"},{"id":"p","name":"In Progress"},{"id":"d","name":"Done"}]}]}' >"$GH_STATE"
  : >"$GH_CALLS"
}
cfg() { grep -E "^$1=" "$BOARD_CONFIG" | head -1 | cut -d= -f2- | tr -d '"'; }

echo "== ensure (fresh): create project + 4 fields + reshape Status; emit config =="
fresh
bash "$SRC/board-bootstrap.sh" ensure >/dev/null 2>&1 && pass || fail "ensure exit 0"
grep -qF "project create" "$GH_CALLS" && pass || fail "project created"
for n in "Bead ID" "Bead Assignee" "Blocked-by" "Priority"; do
  { grep -qF "field-create" "$GH_CALLS" && grep -qF "$n" "$GH_CALLS"; } && pass || fail "field-create $n"
done
grep -qF "api graphql" "$GH_CALLS" && pass || fail "Status reshaped via graphql"
[ -n "$(cfg BOARD_PROJECT_NODE_ID)" ] && pass || fail "config has project node id"
[ -n "$(cfg BOARD_OPT_STATUS_IN_REVIEW)" ] && pass || fail "config has 'In review' option id"
[ -n "$(cfg BOARD_OPT_PRIORITY_UNSPECIFIED)" ] && pass || fail "config has Priority 'Unspecified' option id (UPPER_CASE key)"

echo "== ensure (idempotent re-run): ZERO create/reshape mutations =="
: >"$GH_CALLS"
bash "$SRC/board-bootstrap.sh" ensure >/dev/null 2>&1 && pass || fail "re-ensure exit 0"
grep -qE "project create|field-create|api graphql" "$GH_CALLS" && fail "re-run must make no create/reshape calls" || pass

echo "== verify (complete board): exit 0, re-emits config =="
bash "$SRC/board-bootstrap.sh" verify >/dev/null 2>&1 && pass || fail "verify exit 0 on complete board"
[ -n "$(cfg BOARD_FIELD_BEAD_ASSIGNEE)" ] && pass || fail "verify emits Bead Assignee field id"

echo "== verify (fresh/missing board): fail-closed =="
fresh
bash "$SRC/board-bootstrap.sh" verify >/dev/null 2>&1 && fail "verify must FAIL on a missing project" || pass

echo
echo "==== $PASS passed, $FAIL failed (src: $SRC) ===="
[ "$FAIL" = 0 ]
