#!/usr/bin/env bash
# tests/reaper/concurrency.sh — DETERMINISTIC proof of the concurrent double-reap fix.
#
# The real bug is a RACE (two --reap passes enumerate the same container; the loser's `docker rm -f`
# hits "No such container"). A real two-process race is nondeterministic, so this suite reproduces
# the exact loser/winner conditions with a FAKE `docker` on PATH — no daemon, always runs, never
# flakes. It pins the reaper's docker-inspect DISAMBIGUATION branch:
#
#   benign  : rm fails  +  `docker inspect <cid>` fails (gone)  -> rc 0, no WARNING, no log  (idempotent)
#   refuses : rm fails  +  `docker inspect <cid>` succeeds       -> rc 1, WARNING            (F7b preserved)
#   winner  : rm succeeds                                        -> rc 0, "reaped", 1 log    (control)
#
# Seam-honest (FORGE_REAPER_SRC, the run.sh pattern): the deployed harness/reaper.sh if present, else
# the sandbox candidate. RED against the pre-fix candidate; GREEN against the fixed reaper.
set -u
ROOT_REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL [%s]\n' "$1"; }

# ── resolve the reaper under test (seam-honesty; identical to tests/reaper/run.sh) ──
if [ -n "${FORGE_REAPER_SRC:-}" ]; then
  REAPER="$FORGE_REAPER_SRC/reaper.sh"
elif [ -x "$ROOT_REPO/harness/reaper.sh" ]; then
  REAPER="$ROOT_REPO/harness/reaper.sh"
else
  REAPER="$ROOT_REPO/harness/reaper.sh"
fi
[ -f "$REAPER" ] || { echo "FAIL: no reaper.sh found at $REAPER"; exit 1; }
echo "== reaper under test: $REAPER =="

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required for this suite"; exit 1; }

# ── hermetic fixture ──
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
HDIR="$T/hdir"; mkdir -p "$HDIR"          # FORGE_HARNESS_DIR — sentinel ABSENT -> container is STALE by (b)
SCOPE="$T/wt"; mkdir -p "$SCOPE"          # FORGE_REAPER_SCOPE — the confinement base
FAKE_WT="$SCOPE/wt-stale"                 # in-scope, not sentinel-named -> STALE
LBL="forge.test.k0e.$$"

# ── fake docker: simulates enumerate/classify + a configurable rm/inspect outcome ──
FAKEDIR="$T/bin"; mkdir -p "$FAKEDIR"
cat >"$FAKEDIR/docker" <<'DOCKER'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  ps)   printf '%s\n' "${FAKE_CID:-deadcafe0001}" ;;   # docker ps -aq --filter label=...
  inspect)
    if [ "${1:-}" = "-f" ]; then                       # classification: inspect -f <fmt> <cid>
      case "$2" in
        *Labels*)  printf '%s\n' "$FAKE_WT" ;;
        *Created*) printf '%s\n' "2020-01-01T00:00:00Z" ;;
        *)         printf '\n' ;;
      esac
      exit 0
    fi
    # Disambiguation: bare inspect <cid>. docker writes its error to STDERR and the reaper
    # keys on that TEXT (not the exit code — docker returns 1 for both not-found AND daemon errors).
    [ -n "${FAKE_INSPECT_ERR:-}" ] && printf '%s\n' "$FAKE_INSPECT_ERR" >&2
    exit "${FAKE_INSPECT_RC:-1}"
    ;;
  rm)   exit "${FAKE_RM_RC:-1}" ;;                      # docker rm -f <cid>
  info) exit 0 ;;
  *)    exit 0 ;;
esac
DOCKER
chmod +x "$FAKEDIR/docker"

run_reaper() {
  PATH="$FAKEDIR:$PATH" \
  FORGE_REAPER_LABEL="$LBL" FORGE_REAPER_SCOPE="$SCOPE" FORGE_HARNESS_DIR="$HDIR" \
  FAKE_WT="$FAKE_WT" \
    bash "$REAPER" "$@"
}
logcount() { [ -f "$HDIR/reaper.log" ] && wc -l <"$HDIR/reaper.log" | tr -d ' ' || echo 0; }
resetlog() { rm -f "$HDIR/reaper.log"; }

echo
echo "== 1. BENIGN race: rm fails + inspect CONFIRMS gone (No such) -> idempotent (rc 0, no WARNING, no log) =="
resetlog
OUT="$(FAKE_RM_RC=1 FAKE_INSPECT_RC=1 FAKE_INSPECT_ERR='Error: No such object: deadcafe0001' run_reaper --reap 2>"$T/err")"; rc=$?
[ "$rc" = 0 ] && pass || fail "benign double-reap exits 0 (got $rc) — the false-rc=1 regression"
! grep -q 'WARNING' "$T/err" && pass || fail "benign double-reap emits NO WARNING (spurious-failure line)"
grep -q 'already reaped' "$T/err" && pass || fail "benign double-reap notes 'already reaped' (concurrent pass)"
[ "$(logcount)" = 0 ] && pass || fail "benign double-reap writes NO log line (winner logs; loser must not dup)"

echo
echo "== 2. GENUINE refusal: rm fails + container still exists -> WARN + rc 1 (F7b preserved) =="
resetlog
OUT="$(FAKE_RM_RC=1 FAKE_INSPECT_RC=0 run_reaper --reap 2>"$T/err")"; rc=$?
[ "$rc" = 1 ] && pass || fail "a container that refuses to die still fails loudly (rc 1; got $rc)"
grep -q 'WARNING' "$T/err" && pass || fail "genuine refusal emits WARNING (never swallow a live RW .git mount)"
! grep -q 'already reaped' "$T/err" && pass || fail "genuine refusal is NOT mislabeled 'already reaped'"

echo
echo "== 3. WINNER (control): rm succeeds -> rc 0, 'reaped', exactly 1 log line =="
resetlog
OUT="$(FAKE_RM_RC=0 run_reaper --reap 2>"$T/err")"; rc=$?
[ "$rc" = 0 ] && pass || fail "successful reap exits 0 (got $rc)"
printf '%s\n' "$OUT" | grep -q '^reaped' && pass || fail "successful reap prints 'reaped'"
[ "$(logcount)" = 1 ] && pass || fail "successful reap writes exactly 1 log line (got $(logcount))"

echo
echo "== 4. DAEMON FLAP: rm fails + inspect ERRORS (not not-found) -> fail closed, WARN + rc 1 (PR-1 review F1) =="
resetlog
OUT="$(FAKE_RM_RC=1 FAKE_INSPECT_RC=1 FAKE_INSPECT_ERR='Cannot connect to the Docker daemon at unix:///var/run/docker.sock' run_reaper --reap 2>"$T/err")"; rc=$?
[ "$rc" = 1 ] && pass || fail "unconfirmed removal (daemon error) fails CLOSED with rc 1 (got $rc) — F1: never swallow a live mount"
grep -q 'WARNING' "$T/err" && pass || fail "daemon-flap emits WARNING (could not confirm removal)"
! grep -q 'already reaped' "$T/err" && pass || fail "daemon-flap is NOT misclassified 'already reaped' (the F1 bug)"
[ "$(logcount)" = 0 ] && pass || fail "daemon-flap writes no log line"

echo
echo "== 5. ABSOLUTE guard (deterministic): the sentinel-named container is LIVE, never reaped =="
resetlog
jq -nc --arg w "$FAKE_WT" '{task:"k0e",slug:"k0e",branch:"task/k0e",worktree:$w,base:"main",bead:"",started:"2026-06-11T00:00:00Z",pid:null}' >"$HDIR/active-task.json"
OUT="$(FAKE_RM_RC=0 run_reaper --reap 2>"$T/err")"; rc=$?
[ "$rc" = 0 ] && pass || fail "guarded sweep exits 0 (got $rc)"
printf '%s\n' "$OUT" | grep -q 'LIVE$' && pass || fail "sentinel-named container verdict is LIVE"
[ "$(logcount)" = 0 ] && pass || fail "ABSOLUTE guard: sentinel-named container is NOT reaped (no log)"
rm -f "$HDIR/active-task.json"

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
