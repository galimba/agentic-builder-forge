#!/usr/bin/env bash
# tests/gate/run.sh — the gate's own verdict-protocol test.
#
# Proves the rc-75 SKIP protocol end to end against a COPY of tests/run-all.sh in a
# throwaway tree whose package.json carries only fake suites (so nothing recurses
# into the real gate):
#
#   G1  PASS+SKIP, default mode  -> gate exits 0; table shows a distinct SKIP row;
#       summary names the skip (a SKIP is never folded into PASS, and never reddens
#       the default gate).
#   G2  PASS+SKIP, FORGE_GATE_STRICT=1 -> gate exits non-zero and names the strict
#       knob (unattended/CI mode: a skipped suite is not a covered suite).
#   G3  PASS+SKIP+FAIL, default mode -> gate exits non-zero (FAIL reddens in EVERY
#       mode) and the table shows all three verdict states at once.
#
# G1 doubles as the pnpm rc-propagation pin: run-all must invoke suites via
# `pnpm run --loglevel=error` (NEVER -s/--silent — pnpm's silent reporter swallows
# the child's exit code, turning rc 75 into 1; verified on pnpm 10.4.1). If anyone
# regresses run-all to -s, the fake rc-75 suite reads as FAIL and G1 goes RED here.
set -u
# Hermetic: this suite sets the strict knob EXPLICITLY per case — an ambient FORGE_GATE_STRICT=1
# (the unattended/CI default) must not leak into the default-mode assertions. The OUTER gate still
# honors the ambient knob; only these fixtures pin their own. FORGE_UNATTENDED is unset too:
# it implies strict (G4), so an ambient value would redden the default-mode cases.
unset FORGE_GATE_STRICT FORGE_REQUIRE_DOCKER FORGE_UNATTENDED
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS [%s]\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }

T="$(mktemp -d)"
trap 'rm -rf "$T" 2>/dev/null' EXIT
mkdir -p "$T/tests"
cp "$ROOT/tests/run-all.sh" "$T/tests/run-all.sh"

fake_pkg() { # fake_pkg <with_fail:0|1>
  if [ "$1" = "1" ]; then
    printf '{"name":"gate-fixture","version":"0.0.0","private":true,"scripts":{"test:fakepass":"true","test:fakeskip":"exit 75","test:fakefail":"false"}}'
  else
    printf '{"name":"gate-fixture","version":"0.0.0","private":true,"scripts":{"test:fakepass":"true","test:fakeskip":"exit 75"}}'
  fi >"$T/package.json"
}

echo "== gate protocol: rc-75 SKIP verdict (against a hermetic run-all copy) =="

# G1 — default mode: SKIP is visible and does not redden.
fake_pkg 0
out="$(bash "$T/tests/run-all.sh" </dev/null 2>&1)"
rc=$?
if [ "$rc" = "0" ]; then ok "G1 default: PASS+SKIP gate exits 0 (SKIP does not redden)"; else no "G1 default: expected rc 0" "rc=$rc"; fi
if printf '%s' "$out" | grep -E '^test:fakeskip[[:space:]]+SKIP$' >/dev/null; then ok "G1 table: test:fakeskip shown as SKIP (distinct third verdict)"; else no "G1 table: SKIP row missing" "$(printf '%s' "$out" | tail -8)"; fi
if printf '%s' "$out" | grep -E '^test:fakepass[[:space:]]+PASS$' >/dev/null; then ok "G1 table: test:fakepass shown as PASS"; else no "G1 table: PASS row missing"; fi
if printf '%s' "$out" | grep -q '1 SKIPPED'; then ok "G1 summary: names the SKIP count (never folded into PASS)"; else no "G1 summary: skip count not named" "$(printf '%s' "$out" | tail -3)"; fi

# G2 — strict mode: any SKIP is RED.
out="$(FORGE_GATE_STRICT=1 bash "$T/tests/run-all.sh" </dev/null 2>&1)"
rc=$?
if [ "$rc" != "0" ]; then ok "G2 strict: FORGE_GATE_STRICT=1 makes the SKIP RED (rc=$rc)"; else no "G2 strict: expected non-zero rc with a SKIP present"; fi
if printf '%s' "$out" | grep -q 'FORGE_GATE_STRICT'; then ok "G2 strict: RED message names the strict knob"; else no "G2 strict: knob not named" "$(printf '%s' "$out" | tail -3)"; fi

# G3 — FAIL reddens in every mode; all three verdicts visible at once.
fake_pkg 1
out="$(bash "$T/tests/run-all.sh" </dev/null 2>&1)"
rc=$?
if [ "$rc" != "0" ]; then ok "G3 fail: a FAIL suite reddens the default gate (rc=$rc)"; else no "G3 fail: expected non-zero rc"; fi
if printf '%s' "$out" | grep -E '^test:fakefail[[:space:]]+FAIL$' >/dev/null \
  && printf '%s' "$out" | grep -E '^test:fakeskip[[:space:]]+SKIP$' >/dev/null \
  && printf '%s' "$out" | grep -E '^test:fakepass[[:space:]]+PASS$' >/dev/null; then
  ok "G3 table: PASS / SKIP / FAIL all three verdict states shown"
else
  no "G3 table: three-state table incomplete" "$(printf '%s' "$out" | tail -8)"
fi

# G4 — unattended implies strict: FORGE_UNATTENDED=1 with strict UNSET must redden a SKIP
# (an unattended docker-less box must not green-wash a skipped confinement suite).
fake_pkg 0
out="$(FORGE_UNATTENDED=1 bash "$T/tests/run-all.sh" </dev/null 2>&1)"
rc=$?
if [ "$rc" != "0" ]; then ok "G4 unattended: FORGE_UNATTENDED=1 (strict unset) makes the SKIP RED (rc=$rc)"; else no "G4 unattended: expected non-zero rc with a SKIP present"; fi
if printf '%s' "$out" | grep -q 'SKIPPED'; then ok "G4 unattended: RED message names the SKIP"; else no "G4 unattended: SKIP not named" "$(printf '%s' "$out" | tail -3)"; fi

# G5 — escape hatch: an EXPLICIT FORGE_GATE_STRICT=0 beats the unattended-implied strict.
out="$(FORGE_UNATTENDED=1 FORGE_GATE_STRICT=0 bash "$T/tests/run-all.sh" </dev/null 2>&1)"
rc=$?
if [ "$rc" = "0" ]; then ok "G5 escape hatch: explicit FORGE_GATE_STRICT=0 wins over FORGE_UNATTENDED=1 (rc 0)"; else no "G5 escape hatch: expected rc 0" "rc=$rc"; fi
if printf '%s' "$out" | grep -q '1 SKIPPED'; then ok "G5 escape hatch: SKIP still counted and named (tolerated, not hidden)"; else no "G5 escape hatch: skip count not named" "$(printf '%s' "$out" | tail -3)"; fi

# G6 — regression: with FORGE_UNATTENDED unset (and strict unset), the default gate is
# unchanged — SKIP tolerated, exits 0 (same contract G1 pins; pinned here explicitly
# against the unattended coupling).
out="$(bash "$T/tests/run-all.sh" </dev/null 2>&1)"
rc=$?
if [ "$rc" = "0" ]; then ok "G6 regression: FORGE_UNATTENDED unset keeps the default tolerant gate (rc 0)"; else no "G6 regression: expected rc 0" "rc=$rc"; fi

echo "==== gate-protocol: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
