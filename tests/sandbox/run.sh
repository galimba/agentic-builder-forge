#!/usr/bin/env bash
# Symlink-portal DIFFERENTIAL RED-PROOF (standing suite: package.json "test:sandbox").
#
# Proves HIGH-2 (the symlink portal) CLOSED — not narrowed — by Layer B, on the WIRED sandbox (a real
# git worktree of THIS repo, the real harness/ RO-mounted via the deployed devcontainer.json), with
# a positive control ruling out a permissions false-positive. Four assertions:
#
#   A1 (enforcement blind spot, the hole on main): the TEXTUAL deny hook ALLOWS a Bash write to
#      sandbox/portal/poc — it classifies the literal path, blind to the symlink that points it OUT
#      into harness/. The textual layer cannot close HIGH-2.
#   A2 (OS permits write-through on main): on the host, a write through a symlink whose target is a
#      WRITABLE dir SUCCEEDS — i.e. on main, where harness/ is writable on disk, the portal write lands.
#   A3 (Layer B closes at the MOUNT LAYER): in the wired sandbox, the same write through a symlink to
#      the RO-mounted harness/ returns EROFS ("Read-only file system"), regardless of textual class.
#   A4 (positive control): in the wired sandbox, a legitimate write to the RW worktree SUCCEEDS — the
#      denial in A3 is the mount layer, not a blanket permission failure.
#
# PASS iff A1=allow AND A2=success AND A3=EROFS AND A4=success.
#
# Runs via `bash proof-high2.sh` so its docker/devcontainer/worktree calls are the harness's own
# operations (not agent tool-calls). A confinement proof must RUN, not skip-green: it SKIPs — exit 75
# (EX_TEMPFAIL, the canonical SKIP protocol; run-all.sh records a distinct SKIP verdict, and
# FORGE_GATE_STRICT=1 makes it RED) — ONLY on genuine runtime-absence (docker/devcontainer not
# installed). FORGE_REQUIRE_DOCKER=1 turns that absence into a hard FAIL instead (suite-level knob;
# it never reaches rc 75, so the gate-level strict knob is moot for this suite). A missing image is
# FETCHABLE, so it is PULLED; a failed pull FAILS LOUD. The image is the lib's real default (the
# harness's own base), so the proof exercises the same base — never a divergent stand-in.
set -u
# ROOT must be the MAIN checkout, never a worktree: run-task finish runs this gate from inside the task
# worktree, whose .git is a FILE (gitdir: pointer) — the devcontainer .git/hooks bind-mount needs the
# real main .git directory. Resolve via the git common dir (forge_main_root semantics); fall
# back to the script-relative path outside a git repo.
_gcd="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "$_gcd" ]; then ROOT="$(dirname "$_gcd")"; else ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; fi
unset _gcd
DENY="$ROOT/.claude/hooks/pre-tool-use-deny.sh"
MANIFEST="${FORGE_SANDBOX_MANIFEST:-$ROOT/harness/sandbox/devcontainer.json}"
SANDBOX_LIB="${FORGE_SANDBOX_LIB:-$ROOT/harness/sandbox-lib.sh}"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  PASS [%s]\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP [%s] %s\n' "$1" "${2:-}"; }

# LEGIT SKIP = genuine runtime-absence (not a fetchable condition). These are the ONLY skip-greens.
command -v docker >/dev/null 2>&1 || { [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ] && { echo "FAIL: docker REQUIRED on this gate (FORGE_REQUIRE_DOCKER=1 — a SKIP is a hard fail, F4)"; exit 1; }; echo "SKIP: docker absent (runtime not present) — rc 75 (EX_TEMPFAIL)"; exit 75; }
command -v devcontainer >/dev/null 2>&1 || { [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ] && { echo "FAIL: devcontainer REQUIRED on this gate (FORGE_REQUIRE_DOCKER=1 — a SKIP is a hard fail, F4)"; exit 1; }; echo "SKIP: devcontainer CLI absent (runtime not present) — rc 75 (EX_TEMPFAIL)"; exit 75; }

# Single source of truth for the image: the lib's real default (the base the harness runs), overridable via
# FORGE_SANDBOX_IMAGE. The proof exercises the SAME base — not a divergent stand-in.
# shellcheck disable=SC1090
. "$SANDBOX_LIB"
IMG="$(forge_sandbox_image)"

# A confinement proof must NEVER pass without running. A missing image is FETCHABLE: PULL it; if the
# pull fails, FAIL LOUD rather than skip-green (the wrong-reason-green hazard).
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "   image $IMG not cached — pulling (a confinement proof runs; it does not skip-green)..."
  if ! docker pull "$IMG" >/tmp/forge-cp1-pull.log 2>&1; then
    echo "FAIL: cannot obtain $IMG — the four assertions cannot run; refusing to pass vacuously"
    tail -8 /tmp/forge-cp1-pull.log | sed 's/^/    /'
    exit 1
  fi
fi

export FORGE_MAIN_ROOT="$ROOT"
export FORGE_SANDBOX_IMAGE="$IMG"
export FORGE_SANDBOX_MANIFEST="$MANIFEST"

WT="$ROOT/.claude/worktrees/cp1-proof"
BR="probe/cp1-proof"
RED_TARGET="$(mktemp -d)"   # a writable dir modelling main's writable harness/ for A2
cleanup() {
  forge_sandbox_down "$WT" 2>/dev/null
  git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null
  git -C "$ROOT" branch -D "$BR" 2>/dev/null
  rm -rf "$RED_TARGET" 2>/dev/null   # inside the script: not an agent tool-call
}
trap cleanup EXIT

echo "== symlink-portal differential red-proof (wired sandbox) =="
echo "   ROOT=$ROOT  IMG=$IMG"

# ---- A1: textual deny hook ALLOWS the portal path (the enforcement blind spot) ----
# Run the deny hook with a throwaway .harness so a task looks active, against the REAL repo paths.
A1H="$(mktemp -d)"; printf '{"task":"proof","branch":"task/x"}' > "$A1H/active-task.json"
a1_out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo x > sandbox/portal/poc"}}' \
  | env FORGE_HARNESS_DIR="$A1H" CLAUDE_PROJECT_DIR="$ROOT" bash "$DENY" 2>/dev/null)"
a1_rc=$?
rm -rf "$A1H" 2>/dev/null
if [ "$a1_rc" != "2" ] && ! printf '%s' "$a1_out" | grep -Eq '"permissionDecision":"deny"|"decision":"block"'; then
  ok "A1 textual deny hook ALLOWS sandbox/portal/poc (cannot see the symlink portal)"
else
  bad "A1 expected ALLOW (the textual hole) but the hook blocked it" "rc=$a1_rc out=$a1_out"
fi

# ---- A2: on the host, write THROUGH a symlink to a WRITABLE target SUCCEEDS (models main) ----
mkdir -p "$RED_TARGET/dir"
ln -sfn "$RED_TARGET/dir" "$(mktemp -d)/portal" 2>/dev/null
A2P="$(mktemp -d)/portal"; ln -sfn "$RED_TARGET/dir" "$A2P"
if echo poc > "$A2P/poc" 2>/dev/null && [ -f "$RED_TARGET/dir/poc" ]; then
  ok "A2 host write-through a symlink to a writable target SUCCEEDS (the portal lands on main)"
else
  bad "A2 expected the write-through to succeed on a writable target"
fi

# ---- bring up the WIRED sandbox on a real worktree ----
git -C "$ROOT" worktree add -q "$WT" -b "$BR" HEAD 2>/dev/null || { echo "FATAL: worktree add failed"; exit 1; }
mkdir -p "$WT/sandbox"
if ! forge_sandbox_up "$WT" >/tmp/forge-cp1-up.log 2>&1; then
  echo "FATAL: forge_sandbox_up failed:"; sed 's/^/    /' /tmp/forge-cp1-up.log; exit 1
fi

# ---- A3: write THROUGH a symlink to the RO-mounted harness/ -> EROFS (Layer B, mount layer) ----
a3="$(forge_sandbox_exec "$WT" bash -lc '
  set +e
  ln -sfn "'"$ROOT"'/harness" "'"$WT"'/sandbox/portal"
  echo x > "'"$WT"'/sandbox/portal/poc" 2>&1   # F6: SAME operand A1 feeds the deny hook
  echo "RC=$?"
' 2>&1)"
if printf '%s' "$a3" | grep -qi 'read-only file system' && printf '%s' "$a3" | grep -q 'RC=[1-9]'; then
  ok "A3 portal write-through the RO harness mount is DENIED at the mount layer (EROFS)"
else
  bad "A3 expected EROFS (Read-only file system); HIGH-2 not closed" "out=$a3"
fi

# ---- A4: positive control — a legitimate write to the RW worktree SUCCEEDS ----
a4="$(forge_sandbox_exec "$WT" bash -lc '
  set +e
  echo ok > "'"$WT"'/sandbox/legit.txt" 2>&1
  echo "RC=$? CONTENT=$(cat "'"$WT"'/sandbox/legit.txt" 2>/dev/null)"
' 2>&1)"
if printf '%s' "$a4" | grep -q 'RC=0' && printf '%s' "$a4" | grep -q 'CONTENT=ok'; then
  ok "A4 positive control: legitimate write to the RW worktree SUCCEEDS (denial is the mount, not perms)"
else
  bad "A4 expected the legitimate worktree write to succeed" "out=$a4"
fi


# ---- A5 (F1): in-container plants of BOTH host-exec axes cannot cause host execution ----
# The load-bearing F1 differential, in TWO assertions so each closer is proven INDEPENDENTLY live:
#   A5a (no host-exec, both axes): neither planted hook runs HOST-side at the harness git op -> forge_git
#       (core.hooksPath=/dev/null) neutralizes the config-redirect axis (and masks the dir axis too).
#   A5b (RO mount LIVE, dir axis): the in-container .git/hooks plant is EROFS-denied AT THE MOUNT, the way
#       A3 asserts EROFS directly (capture the write's output + RC, grep "read-only file system" + RC!=0).
#       This is INDEPENDENT of forge_git — without it a silently-dead .git/hooks RO mount would still pass
#       (forge_git masks the dir), hiding a mount regression. Manifest-gated so the expected outcome tracks
#       the tree under test: mount declared -> EROFS; no mount -> plant SUCCEEDS (RC=0).
# SELF-CONTAINED throwaway clone — the core.hooksPath plant writes the RW .git/config, which must NEVER
# touch the real repo. Overlays the working-tree harness so it tests the SPLICED manifest + forge_git.
# a5git mirrors cmd_finish's path: forge_git if defined (neutralized), else bare git (legacy tree).
# Each axis gets its OWN host commit (core.hooksPath masks .git/hooks, so one commit can only show one).
# RED on a mount-less tree (A5a: BOTH markers fire), GREEN with the mount (A5a: none fire + A5b: mount EROFS-live).
A5_REPO="${FORGE_E2E_REPO:-$ROOT}"
A5C="$(mktemp -d)"; A5M="$(mktemp -d)"
git clone --no-hardlinks -q "$A5_REPO" "$A5C/c" 2>/dev/null
for f in sandbox/devcontainer.json sandbox-lib.sh run-task.sh kill-switch.sh; do
  [ -f "$A5_REPO/harness/$f" ] && { mkdir -p "$(dirname "$A5C/c/harness/$f")"; cp "$A5_REPO/harness/$f" "$A5C/c/harness/$f"; }
done
git -C "$A5C/c" worktree add -q "$A5C/c/.claude/worktrees/a5" -b task/a5 HEAD 2>/dev/null
a5wt="$A5C/c/.claude/worktrees/a5"; mkdir -p "$a5wt/sandbox"
(
  . "$A5C/c/harness/sandbox-lib.sh"
  export FORGE_MAIN_ROOT="$A5C/c" FORGE_SANDBOX_IMAGE="${FORGE_SANDBOX_IMAGE:-mcr.microsoft.com/devcontainers/javascript-node:20}"
  forge_sandbox_up "$a5wt" >/dev/null 2>&1
  a5git() { if command -v forge_git >/dev/null 2>&1; then forge_git "$@"; else git "$@"; fi; }
  # axis-1: plant .git/hooks/pre-commit. Capture the write's output + RC to a host file (A3-idiom) for
  # A5b's direct mount-liveness check; on a mount-less (RW) tree the plant lands and the host commit RUNS it.
  forge_sandbox_exec "$a5wt" bash -lc '
    set +e
    printf "#!/bin/sh\ntouch '"$A5M"'/HOOKSDIR\n" > "'"$A5C"'/c/.git/hooks/pre-commit" 2>&1
    echo "RC=$?"
    chmod +x "'"$A5C"'/c/.git/hooks/pre-commit" 2>/dev/null
  ' > "$A5M/axis1.out" 2>&1
  echo c1 > "$a5wt/sandbox/f"; a5git -C "$a5wt" add -A 2>/dev/null
  a5git -C "$a5wt" -c user.email=t@t -c user.name=t commit -q -m a5hooksdir 2>/dev/null || true
  # axis-2: plant a hook in the RW worktree + redirect via .git/config (RW) -> host commit
  forge_sandbox_exec "$a5wt" bash -c 'mkdir -p "'"$a5wt"'/sandbox/eh"; printf "#!/bin/sh\ntouch '"$A5M"'/CONFIG\n" > "'"$a5wt"'/sandbox/eh/pre-commit"; chmod +x "'"$a5wt"'/sandbox/eh/pre-commit"; printf "\n[core]\n\thooksPath = '"$a5wt"'/sandbox/eh\n" >> "'"$A5C"'/c/.git/config"' >/dev/null 2>&1
  echo c2 > "$a5wt/sandbox/f"; a5git -C "$a5wt" add -A 2>/dev/null
  a5git -C "$a5wt" -c user.email=t@t -c user.name=t commit -q -m a5config 2>/dev/null || true
  forge_sandbox_down "$a5wt" 2>/dev/null
)
a5_axis1="$(cat "$A5M/axis1.out" 2>/dev/null)"
a5_ro=0; grep -q '\.git/hooks,type=bind,readonly' "$A5C/c/harness/sandbox/devcontainer.json" 2>/dev/null && a5_ro=1
# A5a — NO host execution from EITHER axis (forge_git neutralizes the config redirect; the dir is masked).
if [ ! -f "$A5M/HOOKSDIR" ] && [ ! -f "$A5M/CONFIG" ]; then
  ok "A5a in-container .git/hooks + core.hooksPath plants cause NO host execution (F1: forge_git neutralizes both axes for host ops)"
else
  bad "A5a host-exec FIRED — F1 NOT closed" "axis-1(.git/hooks)=$([ -f "$A5M/HOOKSDIR" ] && echo FIRED || echo blocked) axis-2(core.hooksPath)=$([ -f "$A5M/CONFIG" ] && echo FIRED || echo blocked)"
fi
# A5b — the .git/hooks RO mount is independently LIVE (EROFS at the mount, NOT just masked by forge_git).
# Manifest-gated: mount declared -> the plant MUST be EROFS-denied; no mount -> the plant SUCCEEDS (RC=0).
if [ "$a5_ro" = 1 ]; then
  if printf '%s' "$a5_axis1" | grep -qi 'read-only file system' && printf '%s' "$a5_axis1" | grep -q 'RC=[1-9]'; then
    ok "A5b in-container .git/hooks/pre-commit plant is DENIED at the mount (EROFS) — RO mount LIVE, not masked by forge_git"
  else
    bad "A5b .git/hooks RO mount NOT live — in-container plant was not EROFS-denied (forge_git would MASK this)" "out=$a5_axis1"
  fi
else
  if printf '%s' "$a5_axis1" | grep -q 'RC=0'; then
    ok "A5b (mount-less baseline) in-container .git/hooks plant SUCCEEDS with no RO mount — the EROFS is a real differential"
  else
    bad "A5b baseline expected the mount-less plant to succeed" "out=$a5_axis1"
  fi
fi
for c in $(docker ps -aq --filter "label=devcontainer.local_folder" 2>/dev/null); do
  lf="$(docker inspect -f '{{ index .Config.Labels "devcontainer.local_folder" }}' "$c" 2>/dev/null)"
  case "$lf" in "$A5C"/*) docker rm -f "$c" >/dev/null 2>&1 ;; esac
done
rm -rf "$A5C" "$A5M" 2>/dev/null

echo "== proof: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
[ "$FAIL" = 0 ]
