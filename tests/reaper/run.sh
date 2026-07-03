#!/usr/bin/env bash
# tests/reaper/run.sh — proof suite for the stale-container reaper.
#
# Real docker, throwaway busybox containers on a TEST-ONLY label key (FORGE_REAPER_LABEL) and a
# test-only scope (FORGE_REAPER_SCOPE) — the suite can NEVER enumerate, let alone reap, a real
# devcontainer. Sentinel + log live in an isolated FORGE_HARNESS_DIR.
#
# Seam-honesty: probes harness/reaper.sh if installed, else the sandbox candidate;
# FORGE_REAPER_SRC=<dir> overrides (the FORGE_RUNTASK_SRC pattern) — GREEN pre- and post-splice.
#
# Docker absent: SKIP + exit 75 (EX_TEMPFAIL — the wave's canonical SKIP code, the rc-75 gate
# protocol in tests/run-all.sh; reaper.sh itself also exits 75 on docker-absent). COORDINATION:
# this flip merges AFTER the rc-75 gate lands in run-all.sh, so merged main always interprets
# 75 as SKIP. FORGE_REQUIRE_DOCKER=1 turns the skip into a hard FAIL (exit 1).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s]\n' "$1"
}

command -v docker >/dev/null 2>&1 || {
  [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ] && { echo "FAIL: docker REQUIRED (FORGE_REQUIRE_DOCKER=1) but absent"; exit 1; }
  echo "SKIP: docker absent (runtime not present; rc=75)"
  exit 75
}
docker info >/dev/null 2>&1 || {
  [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ] && { echo "FAIL: docker REQUIRED (FORGE_REQUIRE_DOCKER=1) but daemon unreachable"; exit 1; }
  echo "SKIP: docker daemon unreachable (runtime not present; rc=75)"
  exit 75
}

# ── resolve the reaper under test (seam-honesty) ──
if [ -n "${FORGE_REAPER_SRC:-}" ]; then
  REAPER="$FORGE_REAPER_SRC/reaper.sh"
elif [ -x "$ROOT/harness/reaper.sh" ]; then
  REAPER="$ROOT/harness/reaper.sh"
else
  REAPER="$ROOT/harness/reaper.sh"
fi
[ -f "$REAPER" ] || { echo "FAIL: no reaper.sh found at $REAPER"; exit 1; }
echo "== reaper under test: $REAPER =="

# ── hermetic fixture ──
T="$(mktemp -d)"
HDIR="$T/hdir"
LBL="forge.test.reaper.$$" # test-only label KEY — never devcontainer.local_folder
WT_LIVE="$T/wt-live"       # exists + named by the sentinel  -> LIVE
WT_STALE="$T/wt-stale"     # exists, NOT in the sentinel     -> STALE by (b)
WT_GONE="$T/wt-gone"       # never created                   -> STALE by (a)+(b)
WT_FOREIGN="/nonexistent/forge-foreign-$$/x" # outside FORGE_REAPER_SCOPE -> FOREIGN, untouchable
mkdir -p "$WT_LIVE" "$WT_STALE" "$HDIR"

CIDS=()
cleanup() {
  [ "${#CIDS[@]}" -gt 0 ] && docker rm -f "${CIDS[@]}" >/dev/null 2>&1
  rm -rf "$T" 2>/dev/null
  return 0
}
trap cleanup EXIT

launch() { docker run -d --label "$LBL=$1" busybox sleep 300 2>/dev/null; }
C1="$(launch "$WT_LIVE")" || { echo "FAIL: could not launch busybox fixture (image pull?)"; exit 1; }
CIDS+=("$C1")
C2="$(launch "$WT_STALE")" && CIDS+=("$C2") || { echo "FAIL: fixture C2"; exit 1; }
C3="$(launch "$WT_GONE")" && CIDS+=("$C3") || { echo "FAIL: fixture C3"; exit 1; }
C4="$(launch "$WT_FOREIGN")" && CIDS+=("$C4") || { echo "FAIL: fixture C4"; exit 1; }
S1="${C1:0:12}" S2="${C2:0:12}" S3="${C3:0:12}" S4="${C4:0:12}"

# the live sentinel names WT_LIVE (run-task.sh schema)
jq -nc --arg w "$WT_LIVE" \
  '{task:"reaper-suite",slug:"reaper-suite",branch:"task/reaper-suite",worktree:$w,base:"main",bead:"",started:"2026-06-11T00:00:00Z",pid:null}' \
  >"$HDIR/active-task.json"

run_reaper() {
  FORGE_REAPER_LABEL="$LBL" FORGE_REAPER_SCOPE="$T" FORGE_HARNESS_DIR="$HDIR" bash "$REAPER" "$@"
}
alive() { docker inspect "$1" >/dev/null 2>&1; }

row() { printf '%s\n' "$1" | grep "$2"; } # row <table> <cid-short> -> that container's line

echo
echo "== 1. dry-run (default): verdicts right, NOTHING removed, no log =="
OUT="$(run_reaper 2>/dev/null)"
RC=$?
printf '%s\n' "$OUT"
[ "$RC" = 0 ] && pass || fail "dry-run exits 0 (got $RC)"
row "$OUT" "$S1" | grep -q 'LIVE$' && pass || fail "C1 (sentinel-named) is LIVE"
row "$OUT" "$S2" | grep -q 'STALE$' && pass || fail "C2 is STALE"
row "$OUT" "$S2" | grep -q 'no-live-sentinel' && pass || fail "C2 reason no-live-sentinel"
row "$OUT" "$S3" | grep -q 'STALE$' && pass || fail "C3 is STALE"
row "$OUT" "$S3" | grep -q 'worktree-missing' && pass || fail "C3 reason worktree-missing"
row "$OUT" "$S4" | grep -q 'FOREIGN$' && pass || fail "C4 (outside scope) is FOREIGN"
alive "$C1" && alive "$C2" && alive "$C3" && alive "$C4" && pass || fail "dry-run removed nothing"
[ ! -e "$HDIR/reaper.log" ] && pass || fail "dry-run wrote no log"

echo
echo "== 2. --max-age wiring (dry-run) — the live guard is ABSOLUTE =="
OUT="$(run_reaper --max-age=1d 2>/dev/null)"
row "$OUT" "$S1" | grep -q 'LIVE$' && pass || fail "fresh container LIVE under --max-age=1d"
sleep 2
OUT="$(run_reaper --max-age=1s 2>/dev/null)"
row "$OUT" "$S2" | grep -q 'older-than-max-age' && pass || fail "old container aged out under --max-age=1s (max-age knob wired)"
row "$OUT" "$S1" | grep -q 'LIVE$' && pass || fail "ABSOLUTE guard: sentinel-named container LIVE even under --max-age=1s"
run_reaper --max-age=bogus >/dev/null 2>&1
[ $? = 2 ] && pass || fail "malformed --max-age is usage error (rc 2)"

echo
echo "== 3. CORRUPT-SENTINEL: sentinel exists but untrustworthy -> REFUSE to reap anything =="
cp "$HDIR/active-task.json" "$T/sentinel.bak"
echo 'NOT { JSON' >"$HDIR/active-task.json"

# --reap refuses: loud named error, non-zero exit, NOTHING removed, no log
ERR="$(run_reaper --reap 2>&1 >/dev/null)"
RC=$?
[ "$RC" != 0 ] && pass || fail "corrupt sentinel: --reap refuses with non-zero exit (got $RC)"
printf '%s\n' "$ERR" | grep -q 'CORRUPT-SENTINEL' && pass || fail "corrupt sentinel: --reap error names CORRUPT-SENTINEL"
alive "$C1" && alive "$C2" && alive "$C3" && alive "$C4" && pass || fail "corrupt sentinel: --reap removed NOTHING"
[ ! -e "$HDIR/reaper.log" ] && pass || fail "corrupt sentinel: --reap wrote no log"

# dry-run ALSO refuses (same posture — a corrupt sentinel means verdicts cannot be trusted)
ERR="$(run_reaper 2>&1 >/dev/null)"
RC=$?
[ "$RC" != 0 ] && pass || fail "corrupt sentinel: dry-run refuses with non-zero exit (got $RC)"
printf '%s\n' "$ERR" | grep -q 'CORRUPT-SENTINEL' && pass || fail "corrupt sentinel: dry-run error names CORRUPT-SENTINEL"

# parseable JSON that lacks .worktree is equally corrupt
echo '{"task":"reaper-suite"}' >"$HDIR/active-task.json"
ERR="$(run_reaper 2>&1 >/dev/null)"
RC=$?
{ [ "$RC" != 0 ] && printf '%s\n' "$ERR" | grep -q 'CORRUPT-SENTINEL'; } && pass || fail "sentinel without .worktree refuses (rc $RC)"

cp "$T/sentinel.bak" "$HDIR/active-task.json" # restore

echo
echo "== 4. --reap: removes exactly the stale set; the live-sentinel GUARD holds =="
OUT="$(run_reaper --reap 2>/dev/null)"
RC=$?
printf '%s\n' "$OUT"
[ "$RC" = 0 ] && pass || fail "--reap exits 0 (got $RC)"
alive "$C1" && pass || fail "GUARD: sentinel-named worktree's container SURVIVES --reap"
alive "$C4" && pass || fail "FOREIGN container survives --reap"
! alive "$C2" && pass || fail "C2 reaped"
! alive "$C3" && pass || fail "C3 reaped"
[ -f "$HDIR/reaper.log" ] && pass || fail "reaper.log written"
[ "$(wc -l <"$HDIR/reaper.log")" = 2 ] && pass || fail "log has exactly 2 entries"
ok=1
while IFS= read -r line; do
  printf '%s' "$line" | jq -e '.container and .worktree and .reason and .ts' >/dev/null 2>&1 || ok=0
done <"$HDIR/reaper.log"
[ "$ok" = 1 ] && pass || fail "every log entry is {container,worktree,reason,ts} JSON"
grep -q "$S2" "$HDIR/reaper.log" && grep -q "$S3" "$HDIR/reaper.log" && pass || fail "log names C2 and C3"

echo
echo "== 5. second --reap is a no-op (idempotent) =="
OUT="$(run_reaper --reap 2>/dev/null)"
RC=$?
[ "$RC" = 0 ] && pass || fail "second --reap exits 0 (got $RC)"
printf '%s\n' "$OUT" | grep -q '^reaped' && fail "second --reap removed something" || pass
alive "$C1" && pass || fail "C1 still alive after second --reap"
[ "$(wc -l <"$HDIR/reaper.log")" = 2 ] && pass || fail "log unchanged after second --reap"

echo
echo "== 6. ABSOLUTE guard under --reap: sentinel-named container survives --reap --max-age=1s =="
OUT="$(run_reaper --reap --max-age=1s 2>/dev/null)"
RC=$?
printf '%s\n' "$OUT"
[ "$RC" = 0 ] && pass || fail "--reap --max-age=1s exits 0 (got $RC)"
row "$OUT" "$S1" | grep -q 'LIVE$' && pass || fail "sentinel-named container is LIVE under --reap --max-age=1s"
alive "$C1" && pass || fail "GUARD ABSOLUTE: sentinel-named container SURVIVES --reap --max-age=1s"
[ "$(wc -l <"$HDIR/reaper.log")" = 2 ] && pass || fail "log unchanged by guarded --reap --max-age=1s"

echo
echo "== 7. docker absent: reaper.sh itself exits 75 (the wave's SKIP code) =="
FB="$T/fakebin"
mkdir -p "$FB"
for t in bash dirname; do ln -s "$(command -v "$t")" "$FB/$t"; done
BASHBIN="$(command -v bash)"
PATH="$FB" "$BASHBIN" "$REAPER" >/dev/null 2>&1
[ $? = 75 ] && pass || fail "docker-absent exit code is 75"

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
