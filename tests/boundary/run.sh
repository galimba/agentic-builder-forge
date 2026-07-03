#!/usr/bin/env bash
# CONTAINER BOUNDARY PROOF (standing suite: package.json "test:boundary").
#
# ISOLATION INVARIANT (motivated by a live near-miss during development):
#   NO test here (RED/GREEN/control) may EVER name a live enforce path ($ROOT/.claude, $ROOT/harness) as
#   a write target under ANY mount config. The ENTIRE harness runs against a THROWAWAY git clone under
#   /tmp (OUTSIDE the live repo); FORGE_MAIN_ROOT=clone, so every ${localEnv:FORGE_MAIN_ROOT} mount — RO,
#   RW, correct or buggy — resolves under the clone. `assert_isolated` fail-closes before any container
#   if FORGE_MAIN_ROOT is inside the live repo OR the manifest names a non-FORGE_MAIN_ROOT-relative
#   source. The live floor is UNREACHABLE by construction, the way the RO mount makes it unwritable.
#
# Proves — inside the REAL container, as the harness's own bash op — the property the
# self-authored-wrapper ruling left as an assertion: the OS container is the within-session write boundary.
#   H4a  self-authored `exec "$@"` wrapper write to an enforce-shaped path -> EROFS (RO mount in force)
#   H4b/H4c/EGRESS/TOOLCHAIN/GATE                                                 [later tasks]
#
# Differential control: FORGE_SANDBOX_MANIFEST=<rw-control> mounts the CLONE's harness/.claude RW, so the
# EROFS assertion flips to SUCCESS (RED) against the COPY — non-vacuous, zero live exposure.
#
# Modes: FORGE_ISO_DRYRUN=1 builds the clone, runs assert_isolated, prints the guarantee, and EXITS
#   before any container (used to SHOW isolation is in place). Otherwise runs the full boundary proof.
#   SKIP=75 only on genuine runtime-absence; FORGE_REQUIRE_DOCKER=1 turns absence into a hard FAIL.
set -u
_gcd="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "$_gcd" ]; then LIVE_ROOT="$(dirname "$_gcd")"; else LIVE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; fi
unset _gcd
SANDBOX_LIB="${FORGE_SANDBOX_LIB:-$LIVE_ROOT/harness/sandbox-lib.sh}"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  PASS [%s]\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP [%s] %s\n' "$1" "${2:-}"; }

# ---- isolation guard (load-bearing; resolves final targets, defeats symlink/realpath escapes) ----
# shellcheck disable=SC1090
. "$(dirname "$0")/isolation-lib.sh"

command -v docker >/dev/null 2>&1 || { [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ] && { echo "FAIL: docker REQUIRED (FORGE_REQUIRE_DOCKER=1)"; exit 1; }; echo "SKIP: docker absent — rc 75"; exit 75; }
command -v devcontainer >/dev/null 2>&1 || { [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ] && { echo "FAIL: devcontainer REQUIRED (FORGE_REQUIRE_DOCKER=1)"; exit 1; }; echo "SKIP: devcontainer CLI absent — rc 75"; exit 75; }

# ---- build the THROWAWAY isolated clone OUTSIDE the live repo ----
HARNESS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/forge-cp99p-iso.XXXXXX")/clone"
git clone --quiet --no-hardlinks "$LIVE_ROOT" "$HARNESS_ROOT" || { echo "FATAL: clone failed"; exit 1; }
export FORGE_MAIN_ROOT="$HARNESS_ROOT"
ENFORCE="$HARNESS_ROOT/.claude/hooks/lib.sh"           # the COPY in the clone — NEVER the live floor
DENY="$HARNESS_ROOT/.claude/hooks/pre-tool-use-deny.sh" # clone's hook (read-only use)
MANIFEST="${FORGE_SANDBOX_MANIFEST:-$HARNESS_ROOT/harness/sandbox/devcontainer.json}"
export FORGE_SANDBOX_MANIFEST="$MANIFEST"

# shellcheck disable=SC1090
. "$SANDBOX_LIB"
IMG="$(forge_sandbox_image)"
export FORGE_SANDBOX_IMAGE="$IMG"

WT="$HARNESS_ROOT/.claude/worktrees/cp99p-proof"
BR="probe/cp99p-proof"
cleanup() {
  forge_sandbox_down "$WT" 2>/dev/null
  rm -rf "$(dirname "$HARNESS_ROOT")" 2>/dev/null   # script's own op (not an agent tool-call); the whole temp tree
}
trap cleanup EXIT

echo "== container boundary proof (ISOLATED clone) =="
echo "   LIVE_ROOT=$LIVE_ROOT"
echo "   HARNESS_ROOT=$HARNESS_ROOT"
echo "   MANIFEST=$MANIFEST  IMG=$IMG"
forge_assert_isolated "$LIVE_ROOT" "$FORGE_MAIN_ROOT" "$MANIFEST" || exit 3

if [ "${FORGE_ISO_DRYRUN:-0}" = "1" ]; then
  echo "   FORGE_ISO_DRYRUN=1 — isolation demonstrated; exiting before any container."
  exit 0
fi

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "   image $IMG not cached — pulling (a boundary proof runs; it does not skip-green)..."
  docker pull "$IMG" >/tmp/forge-cp99p-pull.log 2>&1 || { echo "FAIL: cannot obtain $IMG"; tail -8 /tmp/forge-cp99p-pull.log | sed 's/^/    /'; exit 1; }
fi

git -C "$HARNESS_ROOT" worktree add -q "$WT" -b "$BR" HEAD 2>/dev/null || { echo "FATAL: worktree add failed"; exit 1; }
mkdir -p "$WT/sandbox"
# the workspace (worktree) is mounted RW — it too must realpath INSIDE the isolated root.
case "$(realpath "$WT")/" in "$(realpath "$HARNESS_ROOT")"/*) : ;; *) echo "FATAL ISOLATION BREACH: worktree $WT outside HARNESS_ROOT"; exit 3;; esac
if ! forge_sandbox_up "$WT" >/tmp/forge-cp99p-up.log 2>&1; then
  echo "FATAL: forge_sandbox_up failed:"; sed 's/^/    /' /tmp/forge-cp99p-up.log; exit 1
fi

# ---- H4c: composition on ONE end-to-end invocation (opaque agent-authored script — the floor ALLOWs it) ----
# Runs FIRST so its floor-ALLOW premise is evaluated on an intact clone (a later destructive write must
# not corrupt the hook the premise depends on). The agent-realistic attack at one indirection: the agent
# authors payload.sh in the worktree whose BODY writes the enforce path, then runs `bash payload.sh`. The
# textual floor cannot read the file -> ALLOWs; the container -> EROFS. hook_allows=1 (the gating premise)
# proves the container is LOAD-BEARING — the floor genuinely permits what the container denies.
forge_sandbox_exec "$WT" bash -lc '
  printf "#!/bin/sh\ncp /etc/hostname \"%s\"\n" "'"$ENFORCE"'" > "'"$WT"'/payload.sh"; chmod +x "'"$WT"'/payload.sh"
' >/dev/null 2>&1
WCMD="bash $WT/payload.sh"
A1H="$(mktemp -d)"; printf '{"task":"proof","branch":"task/x"}' > "$A1H/active-task.json"
hjson="$(jq -cn --arg c "$WCMD" '{tool_name:"Bash",tool_input:{command:$c}}')"
hook_out="$(printf '%s' "$hjson" | env FORGE_HARNESS_DIR="$A1H" CLAUDE_PROJECT_DIR="$HARNESS_ROOT" bash "$DENY" 2>/dev/null)"; hook_rc=$?
rm -rf "$A1H" 2>/dev/null
hook_allows=1
{ [ "$hook_rc" = 2 ] || printf '%s' "$hook_out" | grep -Eq '"permissionDecision":"deny"|"decision":"block"'; } && hook_allows=0
execc="$(forge_sandbox_exec "$WT" bash -lc "$WCMD 2>&1; echo RC=\$?" 2>&1)"
kernel_denies=0
printf '%s' "$execc" | grep -qi 'read-only file system' && kernel_denies=1
if [ "$hook_allows" = 1 ]; then
  ok "H4c premise: the textual floor ALLOWs the opaque agent-authored payload (bash payload.sh)"
else
  bad "H4c premise FAILED: floor DENIED the payload — form is floor-closed, not a real composition" "hook=$hook_out"
fi
if [ "$hook_allows" = 1 ] && [ "$kernel_denies" = 1 ]; then
  ok "H4c composition: floor-ALLOWs AND container-EROFS-denies -> net-denied (container is load-bearing)"
else
  bad "H4c composition broke" "hook_allows=$hook_allows kernel_denies=$kernel_denies exec=$execc"
fi

# ---- H4a: the EXACT self-authored-wrapper escape, authored INSIDE the container, must hit the RO mount (the COPY) ----
h4a="$(forge_sandbox_exec "$WT" bash -lc '
  set +e
  printf "#!/bin/sh\nexec \"\$@\"\n" > "'"$WT"'/w"; chmod +x "'"$WT"'/w"
  "'"$WT"'/w" cp /etc/hostname "'"$ENFORCE"'" 2>&1
  echo "RC=$?"
' 2>&1)"
if printf '%s' "$h4a" | grep -qi 'read-only file system' && printf '%s' "$h4a" | grep -q 'RC=[1-9]'; then
  ok "H4a self-authored wrapper write to the enforce path -> EROFS (RO mount in force)"
else
  bad "H4a expected EROFS via the wrapper; the boundary did not deny the write" "out=$h4a"
fi

# ---- H4b: hardlink portal — in-bounds name hardlinked to a RO-mounted enforce inode (the COPY) ----
# Across the worktree(RW) <-> .claude(RO) mount boundary a hardlink cannot be created (EXDEV); if it ever
# is, the through-write must hit EROFS. Either way NO portal write may land on the enforce file.
MARK="cp99p-portal-$$"
h4b="$(forge_sandbox_exec "$WT" bash -lc '
  set +e
  link "'"$ENFORCE"'" "'"$WT"'/hl" 2>&1
  echo "LINKRC=$?"
  echo "'"$MARK"'" > "'"$WT"'/hl" 2>&1
  echo "WRITERC=$?"
' 2>&1)"
if printf '%s' "$h4b" | grep -qiE 'invalid cross-device link|read-only file system|operation not permitted'; then
  ok "H4b hardlink portal DENIED (observed: $(printf '%s' "$h4b" | grep -ioE 'invalid cross-device link|read-only file system|operation not permitted' | head -1))"
else
  bad "H4b hardlink portal was NOT denied — a write may have landed on the enforce inode" "out=$h4b"
fi
if grep -q "$MARK" "$ENFORCE" 2>/dev/null; then
  bad "H4b CONTENT BREACH — enforce copy shows the portal write landed" ""
else
  ok "H4b enforce-copy content intact (no portal write landed)"
fi

# ---- EGRESS: --network none is the recorded decision; PROVE it (outbound from inside must fail) ----
# Fixture staged host-side into the RW worktree (clean quoting); node is always present in the base image.
printf 'const h=require("https");const r=h.get("https://example.com",()=>process.exit(0));r.on("error",()=>process.exit(7));setTimeout(()=>process.exit(7),5000);\n' > "$WT/sandbox/egress.js"
egr="$(forge_sandbox_exec "$WT" bash -lc 'node "'"$WT"'/sandbox/egress.js" >/dev/null 2>&1; echo "RC=$?"' 2>&1)"
if printf '%s' "$egr" | grep -q 'RC=0'; then
  bad "EGRESS outbound network SUCCEEDED inside the container — egress NOT denied" "out=$egr"
else
  ok "EGRESS outbound network denied inside the container (--network none in force)"
fi

# ---- TOOLCHAIN: a real red->green cycle runs INSIDE the container under --network none ----
# Proves the confinement (RO mounts + --network none + cap-drop/no-new-privileges/uid-1000) does not break
# the build it protects: node executes, RW worktree writes work, the test runner goes red->green with no
# network. Uses node's BUILT-IN runner (no dep install needed under --network none); the production runner
# is vitest (config-driven, exercised by the standing suite at finish).
# .cjs forces CommonJS regardless of the worktree's package.json "type":"module" (the forge is ESM); the
# test file is passed explicitly to avoid any discovery-glob ambiguity.
TCD="$WT/sandbox/tctest"; mkdir -p "$TCD"
printf 'const t=require("node:test");const a=require("node:assert");const{add}=require("./impl.cjs");t("add",()=>a.strictEqual(add(1,2),3));\n' > "$TCD/t.test.cjs"
p1="$(forge_sandbox_exec "$WT" bash -lc 'cd "'"$TCD"'" && node --test t.test.cjs >/dev/null 2>&1; echo "RC=$?"' 2>&1)"   # RED: impl.cjs absent
printf 'exports.add=(x,y)=>x+y;\n' > "$TCD/impl.cjs"
p2="$(forge_sandbox_exec "$WT" bash -lc 'cd "'"$TCD"'" && node --test t.test.cjs >/dev/null 2>&1; echo "RC=$?"' 2>&1)"   # GREEN: impl.cjs present
if printf '%s' "$p1" | grep -q 'RC=0'; then
  bad "TOOLCHAIN expected RED (test must fail before impl exists) but it passed" "p1=$p1"
elif printf '%s' "$p2" | grep -q 'RC=0'; then
  ok "TOOLCHAIN red->green completes inside the container under --network none (node test runner)"
else
  bad "TOOLCHAIN GREEN phase did not pass inside the container" "p1=$p1 p2=$p2"
fi

# ---- GATE: Item 4 helpers — fail-closed-on-ambiguity + liveness-EROFS (not "up") ----
# The helpers (forge_provably_attended / forge_boundary_live) are exercised AS DEPLOYED — they come from
# harness/sandbox-lib.sh, already sourced above as $SANDBOX_LIB (the lib door splice). This suite tests the
# real shipped gate, not a candidate scaffold.
# forge_provably_attended truth table. The suite runs non-interactively (no TTY), so BOTH the explicit
# unattended signal AND mere absence-of-signal must resolve to NOT-attended (=> mandatory boundary).
if ( FORGE_UNATTENDED=1; forge_provably_attended ); then bad "GATE unattended=1 should NOT be provably attended" ""; else ok "GATE unattended=1 -> not provably attended (mandatory boundary)"; fi
if ( unset FORGE_UNATTENDED; forge_provably_attended ); then bad "GATE no-TTY + unset should NOT be provably attended" ""; else ok "GATE no-TTY + unset -> not provably attended (fail-closed on ambiguity)"; fi
# liveness probe against THIS run's manifest: same container-UP state in GREEN and RED, but the verdict
# tracks actual write-DENIAL — RO mount -> live; RW control -> not live (proves it's liveness, not "up").
if forge_boundary_live "$WT"; then
  ok "GATE liveness probe: boundary DENIES a write (EROFS) -> live"
else
  bad "GATE liveness probe: boundary did NOT deny a write (degraded / not-live under this manifest)" ""
fi

echo "==== container boundary: $PASS passed, $FAIL failed, $SKIP skipped ===="
[ "$FAIL" -eq 0 ]
