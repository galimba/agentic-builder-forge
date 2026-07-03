#!/usr/bin/env bash
# tests/reaper/trigger.sh — proof suite for the OUT-OF-BAND reaper trigger (run-task.sh).
#
# DOCKER-FREE + deterministic: it never launches a container. It proves two things:
#   (A) the forge_reaper_sweep CONTRACT — unattended-gated, best-effort/non-fatal, passes --reap
#       (+ --max-age when configured), resolves FORGE_REAPER_BIN — exercised via a MOCK reaper.
#   (B) the DISPATCH WIRING — the `start)` arm actually calls forge_reaper_sweep (a defined-but-
#       uncalled function is a silent no-op). This assertion is RED before the run-task.sh splice
#       and GREEN after — the RED-first signal for the wiring.
#
# Seam-honesty (FORGE_RUNTASK_SRC, the FORGE_REAPER_SRC pattern): resolves run-task.sh from
# FORGE_RUNTASK_SRC if set, else the deployed harness/run-task.sh. The function body is extracted
# from that same file when it defines forge_reaper_sweep, else from the sandbox snippet — so the
# contract tests are GREEN pre- and post-splice while the wiring assertion tracks the real file.
set -u
ROOT_REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL [%s]\n' "$1"; }

RT="${FORGE_RUNTASK_SRC:-$ROOT_REPO/harness/run-task.sh}"
SNIP="${FORGE_REAPER_SWEEP_SNIPPET:-$ROOT_REPO/sandbox/reaper-chain/reaper-sweep.snippet.sh}"
[ -f "$RT" ] || { echo "FAIL: run-task.sh not found at $RT"; exit 1; }

# ── resolve + load the function under test (seam-honest) ──
if grep -q '^forge_reaper_sweep()' "$RT"; then
  FN_SRC="$RT"
elif [ -f "$SNIP" ]; then
  FN_SRC="$SNIP"
else
  echo "FAIL: forge_reaper_sweep defined nowhere (not in $RT, no snippet at $SNIP)"; exit 1
fi
echo "== trigger under test: dispatch=$RT  function=$FN_SRC =="
# extract just the function definition (def line .. column-0 closing brace) and load it
FN_TEXT="$(awk '/^forge_reaper_sweep\(\) \{/,/^\}/' "$FN_SRC")"
[ -n "$FN_TEXT" ] || { echo "FAIL: could not extract forge_reaper_sweep from $FN_SRC"; exit 1; }
# shellcheck disable=SC1090
eval "$FN_TEXT"
type forge_reaper_sweep >/dev/null 2>&1 || { echo "FAIL: forge_reaper_sweep did not load"; exit 1; }

# ── hermetic fixture: a mock reaper that records its args + exit code ──
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
MARK="$T/ran"; ARGS="$T/args"
make_mock() { # make_mock <exit-code>
  cat >"$T/reaper.sh" <<EOF
#!/usr/bin/env bash
echo ran >"$MARK"
printf '%s\n' "\$@" >"$ARGS"
exit ${1:-0}
EOF
  chmod +x "$T/reaper.sh"
}
reset() { rm -f "$MARK" "$ARGS"; }
ROOT="$T" # forge_reaper_sweep resolves $ROOT/harness/reaper.sh when FORGE_REAPER_BIN is unset

echo
echo "== A. contract: unattended-gated, best-effort, passes --reap, honors seams =="

# 1. unattended + mock present -> the sweep FIRES with --reap
make_mock 0; reset
FORGE_UNATTENDED=1 FORGE_REAPER_BIN="$T/reaper.sh" forge_reaper_sweep >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && pass || fail "unattended sweep returns 0 (got $rc)"
[ -f "$MARK" ] && pass || fail "unattended sweep INVOKES the reaper"
grep -qx -- '--reap' "$ARGS" && pass || fail "sweep passes --reap"

# 2. interactive (FORGE_UNATTENDED unset) -> the sweep is a NO-OP (never auto-reaps under a human)
make_mock 0; reset
FORGE_REAPER_BIN="$T/reaper.sh" forge_reaper_sweep >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && pass || fail "interactive sweep returns 0 (got $rc)"
[ ! -f "$MARK" ] && pass || fail "interactive sweep does NOT invoke the reaper (unattended-only)"

# 3. best-effort: reaper SKIP (docker absent, rc 75) is NON-FATAL
make_mock 75; reset
FORGE_UNATTENDED=1 FORGE_REAPER_BIN="$T/reaper.sh" forge_reaper_sweep >/dev/null 2>&1
[ "$?" = 0 ] && pass || fail "reaper rc 75 (docker absent) is non-fatal (sweep still returns 0)"

# 4. best-effort: a hard reaper failure (rc 1) is NON-FATAL (never blocks the task)
make_mock 1; reset
FORGE_UNATTENDED=1 FORGE_REAPER_BIN="$T/reaper.sh" forge_reaper_sweep >/dev/null 2>&1
[ "$?" = 0 ] && pass || fail "reaper rc 1 is non-fatal (sweep still returns 0)"

# 5. resolution guard: no reaper binary present -> quiet no-op, rc 0
reset
FORGE_UNATTENDED=1 FORGE_REAPER_BIN="$T/does-not-exist" forge_reaper_sweep >/dev/null 2>&1
rc=$?
{ [ "$rc" = 0 ] && [ ! -f "$MARK" ]; } && pass || fail "absent reaper binary -> quiet no-op rc 0 (got $rc)"

# 6. wall-clock seam: FORGE_REAPER_MAX_AGE adds --max-age=<dur>
make_mock 0; reset
FORGE_UNATTENDED=1 FORGE_REAPER_MAX_AGE=2h FORGE_REAPER_BIN="$T/reaper.sh" forge_reaper_sweep >/dev/null 2>&1
{ grep -qx -- '--reap' "$ARGS" && grep -qx -- '--max-age=2h' "$ARGS"; } && pass || fail "FORGE_REAPER_MAX_AGE wires --max-age=2h"

# 7. DEFAULT resolution (PR-1 review F2): with FORGE_REAPER_BIN UNSET, the sweep must resolve the
# production path $ROOT/harness/reaper.sh — so a typo/rename in that default turns this RED instead
# of silently no-oping. ROOT is $T; plant the mock at $T/harness/reaper.sh.
make_mock 0; reset
mkdir -p "$T/harness"; cp "$T/reaper.sh" "$T/harness/reaper.sh"; chmod +x "$T/harness/reaper.sh"
( unset FORGE_REAPER_BIN; FORGE_UNATTENDED=1 forge_reaper_sweep >/dev/null 2>&1 )
[ -f "$MARK" ] && pass || fail "default resolves \$ROOT/harness/reaper.sh when FORGE_REAPER_BIN is unset"

echo
echo "== B. dispatch wiring: the start) arm calls forge_reaper_sweep (RED pre-splice) =="
# the function must be DEFINED and CALLED in the start) arm of the dispatch file
if grep -q '^forge_reaper_sweep()' "$RT"; then pass; else fail "run-task.sh DEFINES forge_reaper_sweep ($RT)"; fi
if awk '
     $0=="  start)" {s=1}
     s==1 && /forge_reaper_sweep/ {found=1}
     $0=="  finish) cmd_finish ;;" {s=0}
     END{exit !found}
   ' "$RT"; then pass; else fail "the start) arm CALLS forge_reaper_sweep ($RT) — wiring not deployed"; fi

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
