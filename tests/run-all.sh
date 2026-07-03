#!/usr/bin/env bash
# tests/run-all.sh — the canonical gate (with the SKIP protocol).
#
# ONE command, ALL suites, non-zero on any failure, no suite silently dropped.
# Suites are discovered from package.json itself: every script key matching
# ^test: joins the gate automatically, so a newly registered suite can never
# sit orphaned outside the gate again (the silent-rot lesson).
#
# Verdicts: three states, never conflated.
#   rc 0   -> PASS
#   rc 75  -> SKIP  (EX_TEMPFAIL: the suite could not run its subject — e.g. docker
#                    absent — and says so honestly instead of passing vacuously)
#   other  -> FAIL
# Knob precedence (documented here, enforced where named):
#   FORGE_REQUIRE_DOCKER=1  SUITE-level: a docker-dependent suite treats runtime
#                           absence as a hard FAIL (exit 1) — it never reaches rc 75,
#                           so FORGE_GATE_STRICT is moot for that suite.
#   FORGE_GATE_STRICT=1     GATE-level: any SKIP (rc 75) makes the gate RED. This is
#                           the knob unattended/CI sets: a gate that silently skipped
#                           a confinement suite must not read as "covered everything".
#   FORGE_UNATTENDED=1      implies FORGE_GATE_STRICT=1 when strict is UNSET: an
#                           unattended docker-less box must not green-wash skipped
#                           confinement suites at the canonical gate. An EXPLICIT
#                           FORGE_GATE_STRICT=0 still wins (documented escape hatch).
#   default                 SKIPs do not redden the gate, but are counted and printed
#                           distinctly — never folded into PASS.
# Precedence: FORGE_REQUIRE_DOCKER (suite-level) > explicit FORGE_GATE_STRICT >
#             unattended-implied strict > default tolerant.
#
# Discipline:
#   - collect-and-report, not fail-fast: every suite runs even when an earlier
#     one is RED, then a per-suite verdict table prints and the gate exits
#     non-zero iff any suite failed — one run shows the whole board.
#   - each suite runs with stdin from /dev/null: nothing in the gate can block
#     on interactive/TTY input under CI — a future prompt reads EOF
#     and fails instead of wedging the gate forever.
#   - suites run via `pnpm run --loglevel=error`, NEVER `-s`/--silent: pnpm's
#     silent reporter SWALLOWS the child's exit code (rc 75 becomes 1 — verified
#     on pnpm 10.4.1), which would turn every SKIP into FAIL. --loglevel=error
#     propagates the child rc faithfully. tests/gate/run.sh pins this: a
#     regression to -s turns its fake rc-75 suite into FAIL and the gate RED.
#   - fail-closed: zero discovered suites is an error, not a green gate.
#   - pure mechanism: bash + jq + exit codes. No LLM, no network of its own.
set -u

# Unattended implies strict: := defaults only when FORGE_GATE_STRICT is unset, so an
# explicitly exported FORGE_GATE_STRICT=0 still wins (the documented escape hatch).
if [ "${FORGE_UNATTENDED:-0}" = "1" ]; then
  : "${FORGE_GATE_STRICT:=1}"
fi

cd "$(dirname "$0")/.." || exit 1

command -v jq >/dev/null 2>&1 || {
  echo "run-all: jq is required" >&2
  exit 1
}
command -v pnpm >/dev/null 2>&1 || {
  echo "run-all: pnpm is required" >&2
  exit 1
}

mapfile -t SUITES < <(jq -r '.scripts | keys[] | select(startswith("test:"))' package.json | sort)
if [ "${#SUITES[@]}" -eq 0 ]; then
  echo "run-all: no test:* scripts discovered in package.json — failing closed" >&2
  exit 1
fi

declare -A RESULT
FAILED=0
SKIPPED=0
for s in "${SUITES[@]}"; do
  echo
  echo "==== gate: $s ===="
  pnpm run --loglevel=error "$s" </dev/null
  rc=$?
  case "$rc" in
    0)
      RESULT[$s]=PASS
      ;;
    75)
      RESULT[$s]=SKIP
      SKIPPED=$((SKIPPED + 1))
      ;;
    *)
      RESULT[$s]=FAIL
      FAILED=$((FAILED + 1))
      ;;
  esac
done

echo
echo "==== canonical gate summary ===="
for s in "${SUITES[@]}"; do
  printf '%-22s %s\n' "$s" "${RESULT[$s]}"
done
echo "================================"
if [ "$FAILED" -ne 0 ]; then
  echo "gate: RED — $FAILED suite(s) failed"
  exit 1
fi
if [ "$SKIPPED" -ne 0 ]; then
  if [ "${FORGE_GATE_STRICT:-0}" = "1" ]; then
    echo "gate: RED — $SKIPPED suite(s) SKIPPED (rc 75) and FORGE_GATE_STRICT=1 (a skipped suite is not a covered suite)"
    exit 1
  fi
  echo "gate: GREEN — $((${#SUITES[@]} - SKIPPED)) suite(s) passed, $SKIPPED SKIPPED (rc 75; set FORGE_GATE_STRICT=1 to make SKIPs RED)"
  exit 0
fi
echo "gate: GREEN — all ${#SUITES[@]} suites passed"
