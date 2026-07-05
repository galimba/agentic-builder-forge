#!/usr/bin/env bash
# The thin execution-integration suite. Standing suite at
# tests/integration/run.sh (package.json: "test:integration": "bash tests/integration/run.sh").
#
# Part 1 — the END-TO-END chain, walked as ONE test: real convert → bd ready
#          (blocks-gated) → forge_beads_claimable → the topo order survives to execution time.
# Part 2 — the SANDBOX ACTIVATION proof: the Layer B close holds in the LIVE convert→run-task
#          path (portal write → EROFS), and the per-task container is torn down at finish/kill-switch
#          (the lifecycle completes).
#
# HARD real-ledger byte-unchanged guard around everything (convert-class). Skips Part 2 cleanly when
# docker/devcontainer are absent (genuine runtime-absence; NOT a fetchable condition — the image is
# pulled, mirroring tests/sandbox/run.sh) — and reports that skip honestly: any FAIL exits 1; a clean
# run whose Part 2 was docker-skipped exits 75 (EX_TEMPFAIL, the canonical SKIP protocol — the
# gate shows SKIP, not a vacuous PASS; FORGE_GATE_STRICT=1 makes it RED). FORGE_REQUIRE_DOCKER=1 turns
# the absence into a hard FAIL instead (suite-level knob; precedence over the rc-75 path). All work in
# throwaway dirs; the real repo's HEAD/branches are never touched. Container teardown is label-scoped
# to THIS suite's worktrees only.
set -u
# This suite mints real beads in throwaway clones — bd is a hard prerequisite. SKIP honestly
# (rc 75, the gate's SKIP protocol) instead of failing on boxes without beads installed.
command -v bd >/dev/null 2>&1 || { echo "integration: SKIP — bd (beads) required"; exit 75; }
# Fixtures must never prompt — on a TTY stdin, plain `bd init` blocks on the contributor
# wizard. Per-call flags are primary; this env is the backstop for future fixtures.
export BD_NON_INTERACTIVE=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INTAKE="${FORGE_INTAKE:-$ROOT/harness/intake.sh}"
# Part 2 clones THIS repo and runs ITS OWN harness/run-task.sh + harness/kill-switch.sh (so $HERE-relative
# lib/sandbox-lib/devcontainer.json all resolve). Post-splice the real repo carries the sandbox
# lifecycle; the proof points FORGE_E2E_REPO at a spliced clone.
E2E_REPO="${FORGE_E2E_REPO:-$ROOT}"
IMG="${FORGE_SANDBOX_IMAGE:-mcr.microsoft.com/devcontainers/javascript-node:20}"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  PASS [%s]\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP [%s] %s\n' "$1" "${2:-}"; }

TMPROOT="$(mktemp -d)"
SWEEP_LABELS="$TMPROOT"   # scope container teardown to worktrees under TMPROOT
cleanup() {
  # label-scoped: remove ONLY containers whose local_folder is under THIS suite's TMPROOT
  local c lf
  for c in $(docker ps -aq --filter "label=devcontainer.local_folder" 2>/dev/null); do
    lf="$(docker inspect -f '{{ index .Config.Labels "devcontainer.local_folder" }}' "$c" 2>/dev/null)"
    case "$lf" in "$TMPROOT"/*) docker rm -f "$c" >/dev/null 2>&1 ;; esac
  done
  rm -rf "$TMPROOT" 2>/dev/null
}
trap cleanup EXIT

# ---- HARD real-ledger byte-unchanged guard (convert-class) ----
REAL_LEDGER="$ROOT/.beads/issues.jsonl"
ledger_state() { if [ -f "$REAL_LEDGER" ]; then sha256sum "$REAL_LEDGER" | cut -d' ' -f1; else printf 'ABSENT'; fi; }
BEADS_BEFORE="$(ledger_state)"

# shared fixture bodies (mirror tests/intake/run.sh)
# B+C/G3: cmd_ratify's catastrophic floor reads the ## Deferrals ledger, so every spec this suite
# build-and-ratifies must cover the by-default catastrophic categories — else ratify dies at G3, phase stays
# open, and convert fails. Generate the by-default-covered ledger from the deployed enum (cmd_ratify reads the
# same), exactly as tests/intake/run.sh does. (The breaking-change-splice discipline: migrate EVERY suite.)
CATS="${FORGE_INTAKE_CATEGORIES:-$ROOT/harness/intake-categories.json}"
LBC="$(jq -r '.categories[]? | if .risk_default=="by-default" then "- `\(.id)` — covered by FR-001" else "- `\(.id)` — deliberately N/A — fixture default" end' "$CATS" 2>/dev/null)"
A_PROSE=$'## User Scenarios\n### US1 (P1) — Comments\nstory prose\n## Requirements\n- **FR-001:** System **MUST** persist a comment. _(US1)_\n- **FR-002:** System **MUST** reject an empty comment. _(US1)_\n## Success Criteria\n- **SC-001:** visible within 2 seconds.\n## Deferrals / Out of scope\n'"$LBC"
AVALID='{"spec_version":"forge/v1","target_repos":["agentic-builder-forge"],"tasks":[{"id":"T001","title":"persist a comment","satisfies":["FR-001","US1"],"priority":"P1","depends_on":[],"target_repo":"agentic-builder-forge","definition_of_done":["a failing test passes"],"success_criteria":["SC-001"],"scope":["sandbox/e2e/**","tests/e2e/**"],"dod_tests":["tests/e2e/run.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/e2e/evidence/sc1-persist.txt"}]},{"id":"T002","title":"reject empty comments","satisfies":["FR-002"],"priority":"P1","depends_on":["T001"],"target_repo":"agentic-builder-forge","definition_of_done":["a failing test passes"],"success_criteria":["100% rejected"],"scope":["sandbox/e2e/**"],"dod_tests":["tests/e2e/run.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/e2e/evidence/sc1-reject.txt"}]}]}'
U_BODY=$'# Understanding\n## What the FRs will build\nThe thing the FRs describe.'
RST_CONSENSUS=$'# Restatement\n## Open findings\n## History\n### Restatement round 1\nreviewer: AGREE'
mk_aspec() { local f="$1" tj="$2" prose="${3:-$A_PROSE}"; { printf '%s\n\n' "$prose"; printf '%s\n' '<!-- forge:tasks:begin v1 -->'; printf '%s\n' '```json'; printf '%s\n' "$tj"; printf '%s\n' '```'; printf '%s\n' '<!-- forge:tasks:end -->'; } >"$f"; }
cfloor() { mkdir -p "$1/.claude/hooks"; printf '#!/usr/bin/env bash\nexit 0\n' >"$1/.claude/hooks/pre-tool-use-deny.sh"; chmod +x "$1/.claude/hooks/pre-tool-use-deny.sh"; printf '# stub\n' >"$1/.claude/hooks/lib.sh"; printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"pre-tool-use-deny.sh"}]}]}}\n' >"$1/.claude/settings.json"; }
cspec() { mk_aspec "$1/spec.md" "$2"; printf '%s' "$U_BODY" >"$1/understanding.md"; printf '%s' "$RST_CONSENSUS" >"$1/restatement.md"; }
csent() { jq -nc --arg s "$2" '{spec:$s,mode:"interactive",phase:"open",clarify_rounds:5,restate_rounds:3,clarify_max_q:4}' >"$1/active-intake.json"
  # Stage E: cmd_ratify requires a captured spec-review record (the re-expressed C7 evidence), reads its
  # open-count as the consensus oracle, AND verifies its spec_sha256 == the current spec (anti-TOCTOU). Stage
  # an AGREE record bound to the spec sha so the integration ratify/convert flow passes the candidate gate.
  jq -nc --arg ssha "$(sha256sum "$2" | cut -d' ' -f1)" '{verdict:"AGREE",spec_sha256:$ssha,findings:[]}' >"$1/intake-spec-review.json"; }
command -v script >/dev/null 2>&1 || { echo "FATAL: util-linux 'script' needed for the PTY ratify helper"; exit 1; }
ratify_human() { local hd="$1"; shift; FORGE_HARNESS_DIR="$hd" script -qec "bash '$INTAKE' ratify $*" /dev/null >/dev/null 2>&1; }
# Gate A′: convert now REQUIRES BOTH Gate-A tokens — the spec ratify AND the breakdown sign-off
# (Gate A′, binding the Task Breakdown block by hash). Mirrors tests/intake/run.sh:261-268. The integration
# ratify_* helpers self-silence (the def carries >/dev/null 2>&1), so gate_a_full needs no caller redirect.
ratify_breakdown_human() { local hd="$1"; shift; FORGE_HARNESS_DIR="$hd" script -qec "bash '$INTAKE' ratify-breakdown $*" /dev/null >/dev/null 2>&1; }
gate_a_full() { ratify_human "$1" && ratify_breakdown_human "$1"; }

. "$ROOT/harness/beads-lib.sh"

echo "== Part 1 — END-TO-END: convert → bd ready (blocks-gated) → forge_beads_claimable =="
CL="$(mktemp -d -p "$TMPROOT")"
(cd "$CL" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix e2e >/dev/null 2>&1 && bd config set status.custom "in_review:wip" >/dev/null 2>&1)
cfloor "$CL"; mkdir -p "$CL/s"; cspec "$CL/s" "$AVALID"
CH="$(mktemp -d -p "$TMPROOT")"; csent "$CH" "$CL/s/spec.md"
gate_a_full "$CH"
cv="$(cd "$CL" && FORGE_HARNESS_DIR="$CH" bash "$INTAKE" convert 2>&1)"; cvrc=$?
[ "$cvrc" -eq 0 ] && ok "convert mints the 2-task spec (the real converter, end to end)" || no "convert failed (rc=$cvrc)" "$cv"
T1="$(jq -r '.T001 // empty' "$CL/s/crosswalk.json" 2>/dev/null)"   # blocker
T2="$(jq -r '.T002 // empty' "$CL/s/crosswalk.json" 2>/dev/null)"   # dependent (depends_on T001)
{ [ -n "$T1" ] && [ -n "$T2" ]; } && ok "crosswalk maps both tasks (blocker=$T1 dependent=$T2)" || no "crosswalk incomplete (T1=$T1 T2=$T2)"

# the chain, blocked state: dependent ABSENT from bd ready; forge_beads_claimable REFUSES it.
(cd "$CL" && bd ready --json 2>/dev/null) >"$CH/ready1.json"
(cd "$CL" && bd show "$T2" --json 2>/dev/null) >"$CH/show2.json"
grep -q "\"$T2\"" "$CH/ready1.json" && no "dependent should be ABSENT from bd ready while blocked" || ok "dependent $T2 ABSENT from bd ready while blocker open (topo respected)"
if forge_beads_claimable "$CH/show2.json" "$CH/ready1.json"; then no "forge_beads_claimable should REFUSE the blocked dependent"; else ok "forge_beads_claimable REFUSES the blocked dependent (start would fail-closed)"; fi
grep -q "\"$T1\"" "$CH/ready1.json" && ok "blocker $T1 IS in bd ready (claimable head of the chain)" || no "blocker should be in bd ready"

# close the blocker → dependent APPEARS → claimable.
(cd "$CL" && bd close "$T1" --reason "e2e" >/dev/null 2>&1)
(cd "$CL" && bd ready --json 2>/dev/null) >"$CH/ready2.json"
(cd "$CL" && bd show "$T2" --json 2>/dev/null) >"$CH/show2b.json"
grep -q "\"$T2\"" "$CH/ready2.json" && ok "after closing the blocker, dependent $T2 APPEARS in bd ready" || no "dependent should appear after the blocker closes"
if forge_beads_claimable "$CH/show2b.json" "$CH/ready2.json"; then ok "forge_beads_claimable now ACCEPTS the dependent (start would claim it) — chain walked end to end"; else no "dependent should be claimable after the blocker closes"; fi

echo "== Part 2 — SANDBOX ACTIVATION: Layer B holds in the LIVE run-task path + teardown wired =="
DOCKER_SKIPPED=0
if ! command -v docker >/dev/null 2>&1; then { [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ] && no "Part 2 — docker REQUIRED on this gate (FORGE_REQUIRE_DOCKER=1; a SKIP is a hard fail — F4)" || { skip "Part 2 — docker absent (runtime not present)"; DOCKER_SKIPPED=1; }; };
elif ! command -v devcontainer >/dev/null 2>&1; then { [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ] && no "Part 2 — devcontainer REQUIRED on this gate (FORGE_REQUIRE_DOCKER=1; a SKIP is a hard fail — F4)" || { skip "Part 2 — devcontainer CLI absent (runtime not present)"; DOCKER_SKIPPED=1; }; };
else
  if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    echo "   image $IMG not cached — pulling (the activation proof must RUN, not skip-green)..."
    docker pull "$IMG" >/dev/null 2>&1 || { no "Part 2 — cannot obtain $IMG; refusing to pass vacuously"; }
  fi
  if docker image inspect "$IMG" >/dev/null 2>&1; then
    CLV="$(mktemp -d -p "$TMPROOT")"
    git clone --no-hardlinks -q "$E2E_REPO" "$CLV" 2>/dev/null
    # git clone copies the COMMITTED state; overlay the WORKING-TREE harness so gate-2 tests the
    # SPLICED tree before it is committed (post-commit this is a no-op — working == committed).
    # accept-gate.sh + intake.sh carry the marker namespace: on an initialized-but-uncommitted
    # instance whose SENTINEL_NS was renamed, the committed clone still parses the old namespace
    # while the working-tree fixtures emit the new one — overlay them so the split cannot appear.
    # Phase 3: run-task.sh calls forge_target_branch_ns (in beads-lib.sh) + reads branches.config, so both
    # MUST be overlaid alongside run-task.sh — else the working-tree run-task calls a helper absent from the
    # committed beads-lib. (The [ -f ] guard skips branches.config gracefully on a pre-Phase-3 E2E_REPO.)
    for f in run-task.sh kill-switch.sh beads-lib.sh branches.config sandbox-lib.sh accept-gate.sh intake.sh sandbox/devcontainer.json; do
      [ -f "$E2E_REPO/harness/$f" ] && { mkdir -p "$(dirname "$CLV/harness/$f")"; cp "$E2E_REPO/harness/$f" "$CLV/harness/$f"; }
    done
    # FOLD #3: start captures+validates a github-shaped push origin (the forge is github-only via gh
    # pr create); the clone's local origin is a test artifact — give it a github URL so start gets past capture.
    (cd "$CLV" && (git remote add origin https://github.com/example-org/agentic-builder-forge.git 2>/dev/null || git remote set-url origin https://github.com/example-org/agentic-builder-forge.git); git config beads.role maintainer 2>/dev/null; bd init --skip-agents --skip-hooks --non-interactive --prefix lvi >/dev/null 2>&1; bd config set status.custom "in_review:wip" >/dev/null 2>&1)
    # pin bd for the clone (same idiom as A1/A4): run-task pins PATH before sourcing beads.config,
    # so the template's PATH-resolved default cannot see a non-system bd — init pins this in real use.
    printf 'BD_BIN=%s\n' "$(command -v bd)" >>"$CLV/harness/beads.config"
    lid="$(cd "$CLV" && bd create "live activation task" --silent 2>/dev/null | tr -d '[:space:]')"
    # LIVE path: run-task start with FORGE_SANDBOX=1 stands up the per-task sandbox (the seam, activated).
    (cd "$CLV" && FORGE_SANDBOX=1 FORGE_SKIP_INSTALL=1 FORGE_SANDBOX_IMAGE="$IMG" bash harness/run-task.sh start "$lid" >/dev/null 2>&1)
    wt="$(jq -r .worktree "$CLV/.harness/active-task.json" 2>/dev/null)"
    if [ -n "$wt" ] && [ "$(docker ps -q --filter "label=devcontainer.local_folder=$wt" | wc -l)" = "1" ]; then
      ok "run-task start (FORGE_SANDBOX=1) brings up the per-task sandbox (LIVE path activated)"
      # the LIVE-path confinement proof: portal write through the RO harness mount → EROFS.
      . "$CLV/harness/sandbox-lib.sh"; export FORGE_MAIN_ROOT="$CLV"
      mkdir -p "$wt/sandbox"
      pout="$(forge_sandbox_exec "$wt" bash -c "ln -sfn '$CLV/harness' '$wt/sandbox/portal'; echo x > '$wt/sandbox/portal/EVIL' 2>&1; echo rc=\$?" 2>&1)"
      if printf '%s' "$pout" | grep -qi 'read-only file system' && printf '%s' "$pout" | grep -q 'rc=[1-9]'; then
        ok "LIVE PATH: portal write through the RO harness mount is DENIED (EROFS) — HIGH-2 closed where execution runs"
      else no "LIVE PATH: expected EROFS through the activated sandbox" "$pout"; fi
      lout="$(forge_sandbox_exec "$wt" bash -c "echo ok > '$wt/sandbox/legit' && cat '$wt/sandbox/legit'" 2>&1)"
      printf '%s' "$lout" | grep -q '^ok' && ok "LIVE PATH positive control: legit worktree write SUCCEEDS (denial is the mount, not perms)" || no "positive control failed" "$lout"
      # teardown wired: kill-switch must release the bead AND tear the container down.
      (cd "$CLV" && bash harness/kill-switch.sh >/dev/null 2>&1)
      [ "$(docker ps -aq --filter "label=devcontainer.local_folder=$wt" | wc -l)" = "0" ] && ok "kill-switch tears the per-task container DOWN (lifecycle — no leak; F7a: -aq counts stopped too)" || no "container LEAKED after kill-switch (teardown did not fire — container survived)"
    else
      no "run-task start (FORGE_SANDBOX=1) did not bring up the sandbox" "wt=$wt"
    fi
  fi
fi

# ============================================================================
# A1 — END-TO-END: the REAL cmd_convert → accept-gate C0.
# Closes the fixture gap: every mechgate mint is a relative STUB, so the seam
# "what convert actually mints into metadata.source_spec" vs "what the gate's C0
# resolves" was never crossed. This drives the REAL converter, then runs the
# DEPLOYED gate against the minted bead. RED before the source_spec relativization
# fix (convert minted an ABSOLUTE path → C0 source-spec-invalid); GREEN after.
# All work in a throwaway $A1T; the real ledger is never touched (guard below).
# ============================================================================
echo "== accept-gate A1 — real convert → accept-gate C0 (source_spec must be repo-relative) =="
A1_GATE="${FORGE_ACCEPT_GATE:-}"
if [ -z "$A1_GATE" ]; then
  A1_GATE="$ROOT/harness/accept-gate.sh"
fi
A1_LEDGER_BEFORE="$(ledger_state)"
if ! { [ -n "$A1_GATE" ] && [ -f "$A1_GATE" ]; }; then
  no "A1 precondition: no accept-gate.sh to test (set FORGE_ACCEPT_GATE)"
else
  A1T="$(mktemp -d -p "$TMPROOT")"
  A1CH="$(mktemp -d -p "$TMPROOT")"
  A1_PROSE=$'## User Scenarios\n### US1 (P1) — Proof\nThe gate verdicts a real contract-bearing bead.\n## Requirements\n- **FR-001:** System **MUST** verdict a contract-bearing bead. _(US1)_\n## Success Criteria\n- **SC-001:** the gate emits a PASS audit.\n## Deferrals / Out of scope\n'"$LBC"
  A1_TASK='{"spec_version":"forge/v1","target_repos":["agentic-builder-forge"],"tasks":[{"id":"T001","title":"proof task","satisfies":["FR-001","US1"],"priority":"P1","depends_on":[],"target_repo":"agentic-builder-forge","definition_of_done":["a failing test then passes"],"success_criteria":["SC-001"],"scope":["sandbox/mechgate-proof/**"],"dod_tests":["sandbox/mechgate-proof/test.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/mechgate-proof/evidence/sc1.txt"}]}]}'
  # self-contained throwaway with the REAL enforcement floor (the gate needs forge_main_root from lib.sh).
  mkdir -p "$A1T/.claude/hooks" "$A1T/harness" "$A1T/specs/001-mechgate-proof"
  cp "$ROOT/.claude/hooks/lib.sh" "$A1T/.claude/hooks/lib.sh"
  cp "$ROOT/.claude/hooks/pre-tool-use-deny.sh" "$A1T/.claude/hooks/pre-tool-use-deny.sh"; chmod +x "$A1T/.claude/hooks/pre-tool-use-deny.sh"
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"pre-tool-use-deny.sh"}]}]}}\n' >"$A1T/.claude/settings.json"
  cp "$A1_GATE" "$A1T/harness/accept-gate.sh"; chmod +x "$A1T/harness/accept-gate.sh"
  cp "$ROOT/harness/beads-lib.sh" "$A1T/harness/beads-lib.sh"
  cp "$ROOT/harness/sandbox-lib.sh" "$A1T/harness/sandbox-lib.sh"   # FOLD #1: accept-gate sources sandbox-lib (forge_safe_gitdir)
  cp "$ROOT/harness/beads.config" "$A1T/harness/beads.config" 2>/dev/null || true
  # B+C/G3: cmd_ratify runs with cwd=$A1T, so its $ROOT resolves to $A1T (git root) and its catastrophic floor
  # reads $A1T/harness/intake-categories.json — stage the enum here too (like the other harness/ files), else
  # G3 fail-closes "taxonomy not found". The A1_PROSE ledger (LBC, above) covers the by-default tier.
  cp "$ROOT/harness/intake-categories.json" "$A1T/harness/intake-categories.json"
  printf 'BD_BIN=%s\n' "$(command -v bd)" >>"$A1T/harness/beads.config"
  mk_aspec "$A1T/specs/001-mechgate-proof/spec.md" "$A1_TASK" "$A1_PROSE"
  printf '%s' "$U_BODY" >"$A1T/specs/001-mechgate-proof/understanding.md"
  printf '%s' "$RST_CONSENSUS" >"$A1T/specs/001-mechgate-proof/restatement.md"
  ( cd "$A1T" && git init -q . && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main && printf '.harness/\n.beads/\n' >.gitignore && git add .gitignore && git commit -q -m a1-base && bd init --skip-agents --skip-hooks --non-interactive --prefix a1g >/dev/null 2>&1 )
  csent "$A1CH" "$A1T/specs/001-mechgate-proof/spec.md"
  ( cd "$A1T" && gate_a_full "$A1CH" )
  a1cv="$(cd "$A1T" && FORGE_HARNESS_DIR="$A1CH" bash "$INTAKE" convert 2>&1)"; a1rc=$?
  [ "$a1rc" -eq 0 ] && ok "A1 real convert mints the proof bead" || no "A1 convert failed (rc=$a1rc)" "$a1cv"
  A1MID="$(jq -r '.T001 // empty' "$A1T/specs/001-mechgate-proof/crosswalk.json" 2>/dev/null)"
  [ -n "$A1MID" ] && ok "A1 crosswalk maps T001 → $A1MID" || no "A1 crosswalk missing T001" "$a1cv"
  # (1) the fix, directly: the minted metadata.source_spec is repo-RELATIVE (^specs/…md, no leading /).
  A1SRC="$(bd -C "$A1T" show "$A1MID" --json 2>/dev/null | jq -r '.[0].metadata.source_spec // empty')"
  printf '%s' "$A1SRC" | grep -Eq '^specs/[A-Za-z0-9._/-]+\.md$' \
    && ok "A1 minted source_spec is repo-relative ($A1SRC)" \
    || no "A1 minted source_spec NOT repo-relative — gate C0 will reject it (source-spec-invalid)" "got: '$A1SRC'"
  # (2) the seam: the DEPLOYED gate resolves that bead end-to-end. Worktree forked from base, in-scope diff.
  A1BASE="$(git -C "$A1T" rev-parse HEAD)"
  A1WT="$A1T-wt"
  git -C "$A1T" worktree add -q "$A1WT" "$A1BASE" 2>/dev/null
  mkdir -p "$A1WT/sandbox/mechgate-proof/evidence"
  printf 'exit 0\n' >"$A1WT/sandbox/mechgate-proof/test.sh"
  printf 'evidence\n' >"$A1WT/sandbox/mechgate-proof/evidence/sc1.txt"
  git -C "$A1WT" add -A
  a1g="$( (cd "$A1T" && bash "$A1T/harness/accept-gate.sh" --bead "$A1MID" --worktree "$A1WT" --base-sha "$A1BASE" --mode staged) 2>&1 )"
  a1aud="$(printf '%s\n' "$a1g" | sed -n 's/^accept-gate: .* (bead .*; audit \(.*\))$/\1/p' | tail -1)"
  if [ -n "$a1aud" ] && [ -f "$a1aud" ]; then
    [ "$(jq -r '.checks[]|select(.name=="contract")|.result' "$a1aud" 2>/dev/null)" = "pass" ] \
      && ok "A1 gate C0 contract resolves the REAL convert bead (anchor==cache)" \
      || no "A1 gate C0 did NOT pass on real convert output" "contract=$(jq -c '.checks[]|select(.name=="contract")' "$a1aud" 2>/dev/null)"
    [ "$(jq -r '.verdict' "$a1aud" 2>/dev/null)" = "PASS" ] \
      && ok "A1 gate FULL verdict PASS on the real convert bead (C0..C3+integrity)" \
      || no "A1 gate verdict not PASS" "verdict=$(jq -r '.verdict' "$a1aud" 2>/dev/null) reasons=$(jq -c '.reasons' "$a1aud" 2>/dev/null)"
  else
    no "A1 gate wrote no audit" "$a1g"
  fi
  git -C "$A1T" worktree remove --force "$A1WT" 2>/dev/null || true
  # (3) reconcile-idempotency (H2): the relativized reconcile KEY (line 627) must still match the
  # relativized STORED source_spec (line 646) byte-for-byte. Remove the crosswalk to force the
  # crash-recovery LEDGER-reconcile path (not the crosswalk-skip path), re-arm + re-ratify, and convert
  # again — it MUST adopt the existing bead, never re-mint a duplicate. Without H2 in lockstep with H4,
  # an absolute key vs a relative stored value would miss and duplicate.
  A1_N1="$(bd -C "$A1T" list --json 2>/dev/null | jq 'length')"
  rm -f "$A1T/specs/001-mechgate-proof/crosswalk.json"
  csent "$A1CH" "$A1T/specs/001-mechgate-proof/spec.md"
  ( cd "$A1T" && gate_a_full "$A1CH" )
  a1cv2="$(cd "$A1T" && FORGE_HARNESS_DIR="$A1CH" bash "$INTAKE" convert 2>&1)"
  printf '%s' "$a1cv2" | grep -q 'found in ledger' \
    && ok "A1 re-convert ADOPTS via the relativized reconcile key (H2 matches H4 byte-for-byte)" \
    || no "A1 re-convert did NOT hit the ledger-reconcile branch — relativized key may not match stored source_spec" "$a1cv2"
  A1_N2="$(bd -C "$A1T" list --json 2>/dev/null | jq 'length')"
  [ "$A1_N1" = "$A1_N2" ] && ok "A1 re-convert minted NO duplicate (bead count stable at $A1_N2)" || no "A1 re-convert DUPLICATED a bead ($A1_N1 → $A1_N2)"
  A1MID2="$(jq -r '.T001 // empty' "$A1T/specs/001-mechgate-proof/crosswalk.json" 2>/dev/null)"
  [ "$A1MID2" = "$A1MID" ] && ok "A1 re-convert re-maps T001 to the SAME bead ($A1MID)" || no "A1 re-convert remapped T001 ($A1MID → $A1MID2)"
  [ "$(ledger_state)" = "$A1_LEDGER_BEFORE" ] && ok "A1 left the real .beads byte-unchanged" || no "A1 mutated the real ledger"
fi

# ============================================================================
# A4 — run-task finish drops agent-staged .beads churn before the staged gate.
# bd auto-stages .beads/issues.jsonl into the cwd's index; if the agent (or a dod_test) ran bd from the
# worktree, `git add -A` would put it in the pure-agent diff and trip C1 (staged mode grants NO .beads
# exemption — that is rescope-only). A4 restores --staged .beads before the staged gate. Drives the
# DEPLOYED run-task.sh + accept-gate.sh end to end with a CONTRACT bead (NOT the legacy path). RED before
# the A4 fix (staged gate FAILs C1 on .beads); GREEN after. Throwaway repo; real ledger never touched.
# ============================================================================
echo "== accept-gate A4 — finish drops agent-staged .beads churn before the staged gate =="
A4_GATE="${FORGE_ACCEPT_GATE:-$ROOT/harness/accept-gate.sh}"
A4_LEDGER_BEFORE="$(ledger_state)"
if ! { [ -f "$A4_GATE" ] && [ -f "$ROOT/harness/run-task.sh" ]; }; then
  no "A4 precondition: run-task.sh + accept-gate.sh present"
else
  A4T="$(mktemp -d -p "$TMPROOT")"
  A4ACC='{"scope":["sandbox/a4/**"],"dod_tests":["sandbox/a4/t.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/a4/evidence/sc1.txt"}]}'
  mkdir -p "$A4T/.claude/hooks" "$A4T/harness" "$A4T/specs/001-a4"
  cp "$ROOT/.claude/hooks/lib.sh" "$A4T/.claude/hooks/lib.sh"
  cp "$ROOT/.claude/hooks/pre-tool-use-deny.sh" "$A4T/.claude/hooks/pre-tool-use-deny.sh"; chmod +x "$A4T/.claude/hooks/pre-tool-use-deny.sh"
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"pre-tool-use-deny.sh"}]}]}}\n' >"$A4T/.claude/settings.json"
  cp "$A4_GATE" "$A4T/harness/accept-gate.sh"
  for h in run-task.sh beads-lib.sh sandbox-lib.sh; do cp "$ROOT/harness/$h" "$A4T/harness/$h"; done
  # work_root confinement: the forge's self-name — run-task classifies a bead whose target_repo equals it
  # (here "agentic-builder-forge") as a SELF build, NOT a target needing a repos.config entry. Hermetic
  # fixture identity: always write it (an initialized instance renames its package — that must not skew this).
  printf '{"name":"agentic-builder-forge"}\n' >"$A4T/package.json"
  chmod +x "$A4T/harness/run-task.sh" "$A4T/harness/accept-gate.sh"
  cp "$ROOT/harness/beads.config" "$A4T/harness/beads.config" 2>/dev/null || true
  printf 'BD_BIN=%s\n' "$(command -v bd)" >>"$A4T/harness/beads.config"
  printf 'TARGET=t\nt_TEST_CMD="true"\nt_LINT_CMD="true"\nt_FORMAT_CMD="true"\nt_SANDBOX_GLOB="sandbox/**"\n' >"$A4T/harness/targets.config"
  { printf '# A4 spec\n\n- **FR-001:** x. _(US1)_\n\n### US1 (P1) — x\n\n<!-- forge:tasks:begin v1 -->\n'
    printf '```json\n{"spec_version":"forge/v1","target_repos":["agentic-builder-forge"],"tasks":[{"id":"T001","title":"a4","satisfies":["FR-001","US1"],"priority":"P1","depends_on":[],"target_repo":"agentic-builder-forge","definition_of_done":["x"],"success_criteria":["SC-001"],"scope":["sandbox/a4/**"],"dod_tests":["sandbox/a4/t.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/a4/evidence/sc1.txt"}]}]}\n```\n'
    printf '<!-- forge:tasks:end -->\n'; } >"$A4T/specs/001-a4/spec.md"
  # FOLD #3: github-shaped origin so start gets past push-URL capture (the local clone origin is a test artifact).
  ( cd "$A4T" && git init -q . && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main && git remote add origin https://github.com/example-org/agentic-builder-forge.git && printf '.harness/\n' >.gitignore && bd init --skip-agents --skip-hooks --non-interactive --prefix a4 >/dev/null 2>&1 && bd config set status.custom "in_review:wip" >/dev/null 2>&1 && git add .gitignore specs && git commit -q -m a4-base )
  a4meta="$(jq -nc --argjson a "$A4ACC" '{target_repo:"agentic-builder-forge",source_spec:"specs/001-a4/spec.md",task_id:"T001",accept:$a}')"
  a4bid="$( (cd "$A4T" && bd create "a4 task" --metadata "$a4meta" -p 1 2>&1) | grep -oE '[a-z][a-z0-9]*-[a-z0-9]{2,}' | head -1)"
  [ -n "$a4bid" ] && ok "A4 minted a contract bead ($a4bid)" || no "A4 could not mint the contract bead"
  # Item-4: run start ATTENDED (a pty → [ -t 0 ] true → preclaim exempt, no container). A4 verifies the
  # gate's .beads handling, NOT the boundary (tests/boundary + the LIVE-path above cover the container), and its
  # fake/real-bd setup has no devcontainer.json — so the attended path is the correct, container-free fixture.
  a4startout="$(script -qec "cd '$A4T' && FORGE_SKIP_INSTALL=1 bash harness/run-task.sh start '$a4bid'" /dev/null 2>&1 | tr -d '\r' || true)"
  a4wt="$(jq -r '.worktree // empty' "$A4T/.harness/active-task.json" 2>/dev/null)"
  if [ -n "$a4wt" ] && [ -d "$a4wt" ]; then
    ok "A4 run-task start created the worktree"
    mkdir -p "$a4wt/sandbox/a4/evidence"
    printf 'exit 0\n' >"$a4wt/sandbox/a4/t.sh"
    printf 'ev\n' >"$a4wt/sandbox/a4/evidence/sc1.txt"
    # SIMULATE agent bd churn in the worktree: a modified .beads/issues.jsonl git add -A will stage
    mkdir -p "$a4wt/.beads"; printf '{"agent_churn":"%s"}\n' "$a4bid" >>"$a4wt/.beads/issues.jsonl"
    a4out="$(script -qec "cd '$A4T' && FORGE_SKIP_INSTALL=1 bash harness/run-task.sh finish" /dev/null 2>&1 | tr -d '\r' || true)"
    # the STAGED-mode gate audit (finish runs staged FIRST; pre-A4 it dies there, post-A4 rescope follows)
    a4aud=""; for f in $(ls -t "$A4T/.harness/acceptance/"*.json 2>/dev/null); do [ "$(jq -r '.mode // empty' "$f" 2>/dev/null)" = "staged" ] && { a4aud="$f"; break; }; done
    if [ -n "$a4aud" ]; then
      a4scope="$(jq -r '.checks[]|select(.name=="scope")|.result' "$a4aud" 2>/dev/null)"
      [ "$a4scope" = "pass" ] && ok "A4 staged gate scope PASS — agent .beads churn dropped before the gate" \
        || no "A4 staged gate scope=$a4scope — .beads churn tripped C1 (A4 restore missing)" "off=$(jq -c '.checks[]|select(.name=="scope")|.offenders' "$a4aud" 2>/dev/null)"
    else
      no "A4 no staged-mode gate audit written" "$a4out"
    fi
    printf '%s' "$a4out" | grep -qF "acceptance gate FAILED" && no "A4 finish died at the acceptance gate (A4 restore missing)" || ok "A4 finish passed the staged gate (no 'acceptance gate FAILED')"
  else
    no "A4 run-task start did not create a worktree (wt=$a4wt)" "$a4startout"
  fi
  [ "$(ledger_state)" = "$A4_LEDGER_BEFORE" ] && ok "A4 left the real .beads byte-unchanged" || no "A4 mutated the real ledger"
fi

# ============================================================================
# TARGET-build container: container-open + A6 portal +
# H3 live pure-product + push_url fold. Overlays the DEPLOYED working-tree harness
# onto a clone — the Part-2 pattern. RED-first was
# proven during development (deployed dies at :166 / drops push_url; GREEN spliced).
# Throwaway dirs; push target is a FAKE
# non-existent github url (never a real origin — the push-accident guard).
# ============================================================================
echo "== target-container — open + A6 portal + H3 pure-product + push_url fold =="
if [ "$DOCKER_SKIPPED" = 1 ]; then
  skip "target-container target-container arms — docker absent (covered above)"
elif ! docker image inspect "$IMG" >/dev/null 2>&1; then
  { [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ] && no "target-container — image $IMG REQUIRED (FORGE_REQUIRE_DOCKER=1)" || skip "target-container — image $IMG absent"; }
else
  # F-C: overlay the DEPLOYED working-tree harness, never an
  # untracked candidate. The clone is of HEAD (pre-splice); this overlays the spliced harness
  # so the arms test what ships (Part-2 pattern). Post-merge (working == committed) it is a no-op.
  DMF_RT="$ROOT/harness/run-task.sh"; DMF_SL="$ROOT/harness/sandbox-lib.sh"
  DTGT="$(mktemp -d -p "$TMPROOT")"
  ( cd "$DTGT" && git init -q && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main
    printf '<h1>home</h1>\n' > index.html
    printf '{"name":"synthtarget","private":true,"scripts":{"test":"exit 0"}}\n' > package.json
    mkdir -p tests && printf '#!/usr/bin/env bash\nexit 0\n' > tests/dod.sh && chmod +x tests/dod.sh
    git add -A && git commit -q -m base
    git remote add origin https://github.com/dmf-t4-fixture-noexist/synthtarget.git )
  DCLD="$(mktemp -d -p "$TMPROOT")"
  git clone --no-hardlinks -q "$E2E_REPO" "$DCLD" 2>/dev/null
  cp "$DMF_RT" "$DCLD/harness/run-task.sh"; cp "$DMF_SL" "$DCLD/harness/sandbox-lib.sh"
  # Phase 3: the working-tree run-task calls forge_target_branch_ns (beads-lib) + reads branches.config for
  # the TARGET-build branch name — overlay both, else run-task calls a helper absent from the committed lib.
  cp "$ROOT/harness/beads-lib.sh" "$DCLD/harness/beads-lib.sh"
  [ -f "$ROOT/harness/branches.config" ] && cp "$ROOT/harness/branches.config" "$DCLD/harness/branches.config"
  # overlay the marker-parsing harness too (accept-gate/intake), so a renamed-but-uncommitted
  # SENTINEL_NS does not split the cloned parser (committed) from the working-tree fixture.
  for f in accept-gate.sh intake.sh; do [ -f "$E2E_REPO/harness/$f" ] && cp "$E2E_REPO/harness/$f" "$DCLD/harness/$f"; done
  ( cd "$DCLD" && git config user.email t@t && git config user.name t
    git remote set-url origin https://github.com/example-org/agentic-builder-forge.git 2>/dev/null
    bd init --skip-agents --skip-hooks --non-interactive --prefix dmf >/dev/null 2>&1
    bd config set status.custom "in_review:wip" >/dev/null 2>&1 )
  # pin bd for the clone (same idiom as A1/A4 — see the CLV note above)
  printf 'BD_BIN=%s\n' "$(command -v bd)" >>"$DCLD/harness/beads.config"
  printf 'synthtarget=%s\n' "$DTGT" > "$DCLD/harness/repos.config"
  dslice='{"scope":["**",".claude/**",".beads/**","harness/**",".harness/**","about.html","tests/dod.sh"],"dod_tests":["tests/dod.sh"],"sc_evidence":[{"sc":1,"path":"about.html"}]}'
  mkdir -p "$DCLD/specs"
  { printf '# dmf target spec\n\n<!-- forge:tasks:begin v1 -->\n```json\n'
    printf '{"target_repos":["synthtarget"],"tasks":[%s]}\n' "$(jq -nc --argjson s "$dslice" '{id:"T001",title:"dmf landing",target_repo:"synthtarget"}+$s')"
    printf '```\n<!-- forge:tasks:end -->\n'; } > "$DCLD/specs/dmf.md"
  dmeta="$(jq -nc --argjson s "$dslice" '{target_repo:"synthtarget",source_spec:"specs/dmf.md",task_id:"T001",accept:$s}')"
  did="$(cd "$DCLD" && bd create "dmf landing" --metadata "$dmeta" --silent 2>/dev/null | tr -d '[:space:]')"
  dso="$(cd "$DCLD" && FORGE_SANDBOX=1 FORGE_SKIP_INSTALL=1 FORGE_SANDBOX_IMAGE="$IMG" bash harness/run-task.sh start "$did" 2>&1)"; dsrc=$?
  DWT="$(jq -r '.worktree // empty' "$DCLD/.harness/active-task.json" 2>/dev/null)"
  if [ "$dsrc" -eq 0 ] && [ -n "$DWT" ] && [ "$(docker ps -q --filter "label=devcontainer.local_folder=$DWT" | wc -l)" = "1" ]; then
    ok "target-container container-open: FORGE_SANDBOX=1 target start brings up a container on the TARGET worktree (no :166 die)"
    [ "$(jq -r '.work_root // empty' "$DCLD/.harness/active-task.json")" = "$(realpath "$DWT")" ] && ok "target-container: sentinel work_root == realpath(target worktree)" || no "target-container work_root mismatch"
    [ -n "$(jq -r '.push_url // empty' "$DCLD/.harness/active-task.json")" ] && ok "target-container push_url fold: TARGET sentinel stores push_url (dropped pre-fold -> finish dead-ended at :349)" || no "target-container: target sentinel missing push_url (the fold)"
    . "$DCLD/harness/sandbox-lib.sh"; export FORGE_MAIN_ROOT="$DCLD"
    mkdir -p "$DWT/sub"
    dpo="$(forge_sandbox_exec "$DWT" bash -c "ln -sfn '$DCLD/harness' '$DWT/sub/portal'; echo x > '$DWT/sub/portal/poc' 2>&1; echo rc=\$?" 2>&1)"
    { printf '%s' "$dpo" | grep -qi 'read-only file system' && printf '%s' "$dpo" | grep -q 'rc=[1-9]'; } && ok "target-container A6: target-container portal write -> EROFS + rc!=0" || no "target-container A6 portal not denied" "$dpo"
    forge_sandbox_exec "$DWT" bash -c "echo ok > '$DWT/sub/legit'" >/dev/null 2>&1 && ok "target-container A6 positive control: legit worktree write succeeds" || no "target-container A6 positive control failed"
    printf '<p>about</p>\n' > "$DWT/about.html"
    mkdir -p "$DWT/.claude/agents" "$DWT/.beads" "$DWT/harness"
    printf 'e\n' > "$DWT/.claude/agents/evil.md"; printf 'x\n' > "$DWT/.beads/x.json"; printf '#!/bin/sh\n' > "$DWT/harness/evil.sh"
    dfo="$(cd "$DCLD" && FORGE_SANDBOX=1 FORGE_SKIP_INSTALL=1 FORGE_SANDBOX_IMAGE="$IMG" bash harness/run-task.sh finish 2>&1)"
    dtbr="forge/agent/builder/$did-$(basename "$DWT")"   # Phase 3: TARGET-build branch is forge/agent/builder/<id>-<slug>; $did is the bead id from :349
    dfiles="$(git -C "$DTGT" ls-tree -r --name-only "$dtbr" 2>/dev/null)"
    printf '%s\n' "$dfiles" | grep -qx "about.html" && ok "target-container H3 live: committed target diff CARRIES the product (about.html)" || no "target-container H3: product missing from target commit" "$dfiles"
    printf '%s\n' "$dfiles" | grep -qE '(^|/)\.claude/|(^|/)\.beads/|(^|/)harness/|(^|/)\.harness/' && no "target-container H3: PURITY VIOLATION — forge path in target commit" "$(printf '%s\n' "$dfiles"|grep -E '\.claude|\.beads|harness')" || ok "target-container H3 live: committed target diff has ZERO forge paths (H3 stripped them)"
    printf '%s' "$dfo" | grep -qF "no captured push URL" && no "target-container push_url: finish STILL died at :349 (fold not effective)" || ok "target-container push_url: target finish reaches the push (past :349; push to the FAKE remote fails harmlessly, never real origin)"
    (cd "$DCLD" && bash harness/kill-switch.sh >/dev/null 2>&1)
    docker ps -aq --filter "label=devcontainer.local_folder=$DWT" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1
  else
    no "target-container container-open: FORGE_SANDBOX=1 target start did not bring up a container (deployed dies at :166 — RED until splice)" "rc=$dsrc wt=$DWT"
  fi
fi

echo "== real-ledger byte-unchanged guard verdict =="
BEADS_AFTER="$(ledger_state)"
[ "$BEADS_BEFORE" = "$BEADS_AFTER" ] && ok "REAL .beads/issues.jsonl byte-unchanged across the integration suite (before=$BEADS_BEFORE)" || no "REAL ledger CHANGED — UNRECOVERABLE GUARD TRIPPED (before=$BEADS_BEFORE after=$BEADS_AFTER)"

echo "==== integration: $PASS passed, $FAIL failed, $SKIP skipped ===="
# Honest verdict: FAIL wins; a docker-skipped Part 2 is a SKIP (rc 75), never a vacuous PASS.
[ "$FAIL" = 0 ] || exit 1
[ "$DOCKER_SKIPPED" = 1 ] && exit 75
exit 0
