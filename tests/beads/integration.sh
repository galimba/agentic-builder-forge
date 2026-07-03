#!/usr/bin/env bash
# Integration tests for run-task.sh + kill-switch.sh (deployed harness/; the
# FORGE_RUNTASK_SRC seam below selects a candidate overlay instead).
#
# Builds a throwaway harness layout from the candidates + the real .claude/hooks/lib.sh, puts a fake
# `bd` + `gh` on PATH, and drives start/finish/status/ready/board/sync + kill-switch end to end against
# a throwaway git repo (origin = a local bare repo). No real bd, no network, no touching the real repo.
#
#   bash tests/beads/integration.sh                                       # tests the DEPLOYED harness/ (GREEN after splice)
#   FORGE_RUNTASK_SRC=$PWD/path/to/candidates bash tests/beads/integration.sh  # tests candidate overlays (GREEN pre-splice)
set -u
REPOROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${FORGE_RUNTASK_SRC:-$REPOROOT/harness}" # which run-task.sh/kill-switch.sh/beads-lib.sh/beads.config to test
PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s]\n' "$1"
}
skip() { SKIP=$((SKIP + 1)); printf 'SKIP [%s]\n' "$1"; }

# ---- build the throwaway harness layout + fakes --------------------------------------------------
T="$(mktemp -d)"
BARE="$(mktemp -d)"
mkdir -p "$T/harness" "$T/.claude/hooks" "$T/bin" "$T/sandbox/src" "$T/.beads"
# work_root confinement: the throwaway forge's own logical name — run-task reads it (package.json name) so a
# bead whose target_repo equals it classifies SELF, not a target. ("agentic-builder-forge" mirrors the real forge.)
printf '{"name":"agentic-builder-forge","private":true}\n' >"$T/package.json"
cp "$SRC/run-task.sh" "$T/harness/run-task.sh"
cp "$SRC/kill-switch.sh" "$T/harness/kill-switch.sh"
cp "$SRC/sandbox-lib.sh" "$T/harness/sandbox-lib.sh"
# The target build no longer fails closed at :166 — a FORGE_SANDBOX=1 target now brings up a
# real container, which reads harness/sandbox/devcontainer.json. The fixture must carry it (mirror
# tests/integration/run.sh), so the target path tests the REAL bring-up, not an artificial missing-manifest path.
mkdir -p "$T/harness/sandbox"
cp "$SRC/sandbox/devcontainer.json" "$T/harness/sandbox/devcontainer.json" 2>/dev/null ||
  cp "$REPOROOT/harness/sandbox/devcontainer.json" "$T/harness/sandbox/devcontainer.json" 2>/dev/null || true
# beads-lib.sh + beads.config come from the SAME source; tolerated-missing so the bd-less current
# harness still runs (RED), while the candidate / post-splice harness has them (GREEN).
cp "$SRC/beads-lib.sh" "$T/harness/beads-lib.sh" 2>/dev/null || true
cp "$SRC/beads.config" "$T/harness/beads.config" 2>/dev/null || true
cp "$REPOROOT/.claude/hooks/lib.sh" "$T/.claude/hooks/lib.sh"
# Tolerated-missing forward-compat — the POST-SPLICE cmd_finish invokes
# harness/accept-gate.sh at its hardcoded path, so the throwaway layout must carry it. Pre-splice
# (no gate anywhere) both copies miss and finish never calls it. The fake-bd beads carry no
# metadata.accept, so finish runs under the R-C legacy knob — exactly its intended use.
cp "$SRC/accept-gate.sh" "$T/harness/accept-gate.sh" 2>/dev/null ||
  cp "$REPOROOT/harness/accept-gate.sh" "$T/harness/accept-gate.sh" 2>/dev/null || true
chmod +x "$T/harness/accept-gate.sh" 2>/dev/null || true
export FORGE_MECHGATE_ALLOW_LEGACY=1
# The post-splice gate pins PATH (dropping $T/bin) and unsets BD_BIN, then reads bd
# ONLY from beads.config. Point that config at the absolute FAKE bd so the gate stays hermetic — it
# reads the same fake ledger as run-task.sh, finds the no-metadata.accept beads, and PASS-LEGACYs
# under the knob above. Without this, the gate would fall through to a real bd and FAIL bead-not-found.
# (An unconditional trailing assignment overrides beads.config's `:-` default when the gate sources it;
# inert pre-splice, since finish does not call the gate until run-task-finish.md is spliced.)
[ -f "$T/harness/beads.config" ] && printf 'BD_BIN=%s\n' "$T/bin/bd" >>"$T/harness/beads.config"
printf 'TARGET=t\nt_TEST_CMD="true"\nt_LINT_CMD="true"\nt_FORMAT_CMD="true"\nt_SANDBOX_GLOB="sandbox/**"\n' >"$T/harness/targets.config"
chmod +x "$T/harness/run-task.sh" "$T/harness/kill-switch.sh"

cp "$REPOROOT/tests/beads/fakes/bd" "$T/bin/bd" && chmod +x "$T/bin/bd"
cp "$REPOROOT/tests/beads/fakes/gh" "$T/bin/gh" && chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export BD_BIN=bd FORGE_SKIP_INSTALL=1 CLAUDE_PROJECT_DIR="$T"
export BD_FAKE_STATE="$T/.beads-state.json" && echo '[]' >"$BD_FAKE_STATE"
# FOLD #5/#7: run-task runs bd under forge_clean_env (env -i), which STRIPS BD_FAKE_CALLS — the
# fake bd then derives the calls log from its `-C <root>` arg as <root>/.bd-calls.log (mirrors how
# BD_FAKE_STATE above is pinned to <root>/.beads-state.json). Point BD_FAKE_CALLS at that SAME dotted path
# so the direct bd_fake calls and run-task's env-i bd calls both log to ONE file the assertions read.
export BD_FAKE_CALLS="$T/.bd-calls.log" && : >"$BD_FAKE_CALLS"
export GH_FAKE_CALLS="$T/gh-calls.log" && : >"$GH_FAKE_CALLS"
export GH_FAKE_MERGED="$T/gh-merged.txt" && : >"$GH_FAKE_MERGED"
# NB: the fake gh on $T/bin is now UNREACHED by this offline suite — the reconcile gh probe runs under
# forge_clean_env (env -i + the pinned system PATH, FOLD #5/#7) and resolves the REAL gh, and finish dies at
# the offline push before any `gh pr create`. The merge-close oracle is exercised LIVE against the real gh +
# a real merged PR in tests/boundary/fold13-reconcile-trustmodel.sh; here we assert only the gh-free fail-closed skip.

# FOLD #3: the forge is github-only by design (gh pr create). `run-task.sh start` now CAPTURES +
# VALIDATES remote.origin.url and REFUSES any non-github origin — local-bare offline push is no longer a
# supported path. So we establish `main`'s upstream against a local bare (offline-friendly setup push) and
# THEN repoint origin at a github-shaped URL so START's capture passes. The real push at FINISH then targets
# github and DIES offline (no network) — that is EXPECTED + CORRECT; the commit/export/stage work that
# precedes the push is what this suite pins (the push→PR→in_review chain is covered by the LIVE path).
FORGE_ORIGIN="https://github.com/example-org/agentic-builder-forge.git"
(
  cd "$T" || exit 1
  git init -q
  git config user.email t@t
  git config user.name t
  git symbolic-ref HEAD refs/heads/main
  echo '[]' >.beads/issues.jsonl
  git add -A
  git commit -q -m init
  git -C "$BARE" init -q --bare
  git remote add origin "$BARE"
  git push -q -u origin main
  git remote set-url origin "$FORGE_ORIGIN" # FOLD #3: origin must be a github URL for START's capture
)
trap 'rm -rf "$T" "$BARE" 2>/dev/null' EXIT

RT="$T/harness/run-task.sh"
KS="$T/harness/kill-switch.sh"
SENT="$T/.harness/active-task.json"
run() { (cd "$T" && "$@"); } # run with cwd = repo root
# Item-4 gate: `start`/`finish` REFUSE a non-attended self-build unless FORGE_SANDBOX=1. The
# attendance check is `[ "${FORGE_UNATTENDED:-0}" != "1" ] && [ -t 0 ]` (a real TTY on stdin). A TTY-less
# test reads as unattended → refused. run_pty runs the command through a pty (`script -qec`) so `[ -t 0 ]`
# is true → attended → Item-4 exempt → NO container needed. Used ONLY for the run-task start/finish
# invocations that traverse Item-4 (NOT board/sync/ready/kill-switch — those never reach it). Env-var
# prefixes (e.g. FORGE_REPOS_CONFIG=...) pass straight through as a shell command-prefix inside the pty.
# `script` propagates the child's exit status; `tr -d '\r'` strips the pty's CR so message greps match.
run_pty() { (set -o pipefail; script -qec "cd '$T' && $*" /dev/null 2>&1 | tr -d '\r'); }
bd_fake() { BD_FAKE_STATE="$BD_FAKE_STATE" "$T/bin/bd" -C "$T" "$@"; }
sf_status() { jq -r --arg id "$1" '.[] | select(.id==$id) | .status' "$BD_FAKE_STATE"; }
sf_assignee() { jq -r --arg id "$1" '.[] | select(.id==$id) | (.assignee // "")' "$BD_FAKE_STATE"; }
calls_has() { grep -qF "$1" "$BD_FAKE_CALLS"; }

echo "== start --new: mint + claim (ATTENDED via pty so Item-4 exempts the self-build) =="
out="$(run_pty "$RT" start --new "integration alpha")"
rc=$?
[ "$rc" -eq 0 ] || fail "start --new exit 0 (rc=$rc): $out"
[ "$rc" -eq 0 ] && pass
bead="$(jq -r '.bead // empty' "$SENT" 2>/dev/null)"
[ -n "$bead" ] && pass || fail "sentinel records the bead id"
[ "$(sf_status "$bead")" = "in_progress" ] && pass || fail "bead -> in_progress after claim"
[ -n "$(sf_assignee "$bead")" ] && pass || fail "bead assigned after claim"
calls_has "update $bead --claim" && pass || fail "bd update --claim invoked"

echo "== finish: export to \$ROOT/.beads + stage the ledger copy into the task commit (pre-push, offline) =="
# FOLD #3 consequence: the github-only push at finish DIES offline. finish reaches stage→export→commit
# BEFORE the push, so the COMMIT-side facts (ledger exported to $ROOT/.beads, ledger staged into the task
# commit, the pure-product task commit exists) ARE testable here — but finish exits NON-ZERO at the push,
# so we do NOT assert `finish exit 0`. The push→PR→in_review→external_ref chain cannot complete offline.
# ATTENDED via pty (Item-4 exempts the self-build).
out="$(run_pty "$RT" finish)"
grep -qF "EXPORT_PATH=$T/.beads/issues.jsonl" "$BD_FAKE_CALLS" && pass || fail "export -o \$ROOT/.beads/issues.jsonl (authoritative path)"
tbr="$(git -C "$T" for-each-ref --format='%(refname:short)' 'refs/heads/task/*' | head -1)"
git -C "$T" ls-tree -r --name-only "$tbr" 2>/dev/null | grep -qx ".beads/issues.jsonl" && pass || fail "issues.jsonl staged into the task commit ($tbr)"
# MOVED OUT (FOLD #3): `finish exit 0`, `bead -> in_review`, `PR recorded (external_ref)`, `sentinel cleared
# after finish` happen AFTER the github push, which dies offline — finish cannot reach them here. The push
# MECHANISM is pinned by fold3; the record CONSUME (reconcile close) by fold13. The finish WRITE side itself
# (in_review/external_ref + the FOLD #13 .harness/pr record-write) has NO offline integration coverage
# post-FOLD #3 (it runs on every real github finish); the write<->read record-SHAPE contract is pinned
# structurally by fold13's WRITE/READ-contract cells. KNOWN RESIDUAL — not claimed fully-covered.
# finish died at the push, so the alpha task is still active (sentinel present, bead in_progress); release
# it via the kill-switch so the next section starts clean (also re-exercises kill-switch teardown).
run "$KS" >/dev/null 2>&1
[ ! -f "$SENT" ] && pass || fail "kill-switch cleared the alpha task after the offline-failed finish"

echo "== start <id>: claim an existing READY bead, then kill-switch RELEASES it =="
gamma="$(bd_fake create "integration gamma" -p 3 --silent)"
out="$(run_pty "$RT" start "$gamma")" # ATTENDED via pty (Item-4 exempts the self-build)
rc=$?
[ "$rc" -eq 0 ] && pass || fail "start <ready id> exit 0 (rc=$rc): $out"
[ "$(sf_status "$gamma")" = "in_progress" ] && pass || fail "start <id> claims the bead"
out="$(run "$KS" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && pass || fail "kill-switch exit 0 (rc=$rc): $out"
[ "$(sf_status "$gamma")" = "open" ] && pass || fail "kill-switch releases bead -> open"
[ -z "$(sf_assignee "$gamma")" ] && pass || fail "kill-switch clears the assignee"
[ ! -f "$SENT" ] && pass || fail "kill-switch clears the sentinel"

echo "== start fail-closed: missing / already-claimed (ATTENDED so the CLAIMABILITY reason fires, not Item-4) =="
# Run ATTENDED via pty: Item-4 is checked BEFORE the claimability check, so an unattended run would mask
# the intended "not claimable" refusal with the Item-4 message. Attended exempts Item-4 → the claimability
# check fires → we assert the refusal is for the RIGHT reason (not claimable), not the boundary message.
out="$(run_pty "$RT" start fx-does-not-exist)"
rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "is not claimable"; } && pass || fail "start <missing> must fail closed for the claimability reason: $out"
[ ! -f "$SENT" ] && pass || fail "no sentinel after failed start"
claimed="$(bd_fake create "already claimed" -p 2 --silent)"
bd_fake update "$claimed" --claim --assignee someone-else >/dev/null
out="$(run_pty "$RT" start "$claimed")"
rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "is not claimable"; } && pass || fail "start <already-claimed> must fail closed for the claimability reason (no re-claim): $out"

echo "== board: stable 7-key projection, native in_review =="
# The board's in_review projection is the contract under test (NOT how a bead reaches in_review — that
# transition is the finish push path, covered by the LIVE path). Offline, finish dies at the push, so set
# a bead in_review DIRECTLY (the same native status real finish would set) and assert the projection.
ireview="$(bd_fake create "in review one" -p 2 --silent)"
bd_fake update "$ireview" --status in_review >/dev/null
board="$(run "$RT" board 2>/dev/null)"
echo "$board" | jq -e 'type=="array"' >/dev/null 2>&1 && pass || fail "board emits a JSON array"
echo "$board" | jq -e 'all(.[]; has("id") and has("title") and has("status") and has("ready") and has("priority") and has("blockers") and has("assignee"))' >/dev/null 2>&1 && pass || fail "every board object has the 7 contract keys"
echo "$board" | jq -e --arg b "$ireview" 'any(.[]; .id==$b and .status=="in_review")' >/dev/null 2>&1 && pass || fail "board surfaces native status==in_review"

echo "== board: recently-closed window (D12) — in-window shown, out-of-window excluded, merge guarded =="
# Inject two closed beads with controlled closed_at (real bd populates it on close). cmd_board computes
# an absolute cutoff = today - BD_CLOSED_WINDOW days; the fake bd filters the closed query by closed_at.
recent="$(date -u -d '-2 days' +%FT%TZ 2>/dev/null || date -u +%FT%TZ)"
old="$(date -u -d '-60 days' +%FT%TZ 2>/dev/null || echo '2000-01-01T00:00:00Z')"
jq --arg r "$recent" --arg o "$old" \
  '. + [{id:"fx-cin",title:"closed in window",status:"closed",priority:2,issue_type:"task",closed_at:$r,close_reason:"merged",external_ref:"https://x/pull/777"},
        {id:"fx-cout",title:"closed out of window",status:"closed",priority:2,issue_type:"task",closed_at:$o,close_reason:"merged"}]' \
  "$BD_FAKE_STATE" >"$BD_FAKE_STATE.tmp" && mv "$BD_FAKE_STATE.tmp" "$BD_FAKE_STATE"
boardc="$(run "$RT" board 2>/dev/null)"
echo "$boardc" | jq -e 'any(.[]; .id=="fx-cin" and .status=="closed" and .ready==false)' >/dev/null 2>&1 && pass || fail "in-window closed bead surfaces (status:closed, ready:false)"
echo "$boardc" | jq -e 'any(.[]; .id=="fx-cout")' >/dev/null 2>&1 && fail "out-of-window closed bead must be excluded" || pass
echo "$boardc" | jq -e '(map(.id) | length) == (map(.id) | unique | length)' >/dev/null 2>&1 && pass || fail "board ids unique (open + closed reads must not duplicate)"
# Explicit empty-closed merge: drop the in-window closed bead -> the closed query returns [] -> the
# guarded `(.[0] // []) + (.[1] // [])` still yields a valid open-only projection.
jq '[.[] | select(.id!="fx-cin")]' "$BD_FAKE_STATE" >"$BD_FAKE_STATE.tmp" && mv "$BD_FAKE_STATE.tmp" "$BD_FAKE_STATE"
boarde="$(run "$RT" board 2>/dev/null)"
echo "$boarde" | jq -e 'type=="array" and (all(.[]; .status!="closed")) and (length >= 1)' >/dev/null 2>&1 && pass || fail "empty closed-window -> valid open-only board (guarded merge)"

echo "== sync: FOLD #13 fail-closed — an in_review bead with NO captured record is NEVER closed (offline) =="
# FOLD #13 reconcile closes an in_review bead ONLY when its HARNESS-CAPTURED record
# $ROOT/.harness/pr/<bead>.json (repo+branch+pr) names a PR that gh reports state==MERGED AND
# headRefName==branch — it IGNORES external_ref. The actual close-on-merge gh probe runs under
# forge_clean_env (env -i + the PINNED system PATH, FOLD #5/#7) and so resolves the REAL `gh`, NOT the
# fake on $T/bin (no GH_BIN seam exists, by design — the pin defeats a shimmed binary). The MERGE-CLOSE
# CORRECTNESS path therefore cannot be exercised against a fake gh offline; it is covered LIVE (real gh +
# a real merged PR) in tests/boundary/fold13-reconcile-trustmodel.sh (correctness b1) +
# tests/boundary/fold11-reconcile-oracle.sh.
#
# What IS deterministically testable offline is the FAIL-CLOSED skip: a bead in_review with NO captured
# record short-circuits (`[ -f "$rec" ] || continue`) BEFORE any gh call, so it can NEVER be closed by a
# missing/agent-supplied oracle. We assert exactly that here.
norec="$(bd_fake create "in_review no captured record" -p 2 --silent)"
bd_fake update "$norec" --status in_review --external-ref "https://github.com/example-org/agentic-builder-forge/pull/44" >/dev/null
mkdir -p "$T/.harness/pr"
rm -f "$T/.harness/pr/$norec.json" 2>/dev/null # ensure NO captured record exists for this bead
run "$RT" sync >/dev/null 2>&1
[ "$(sf_status "$norec")" = "in_review" ] && pass || fail "sync does NOT close an in_review bead lacking a captured .harness/pr record (FOLD #13 fail-closed; external_ref is ignored)"
# MOVED OUT (FOLD #13): the merge-CLOSE correctness (`sync closes the merged-PR in_review bead`), the
# stays-open case, and the headRefName-mismatch guard all require gh to report state/headRefName for a real
# PR — the reconcile gh probe is env-i + system-PATH-pinned (FOLD #5/#7), so the fake gh is unreachable and
# these cannot run offline against a fake. Coverage lives in tests/boundary/fold13-reconcile-trustmodel.sh
# (b1 correctness / b3 branch-bind / b4 no-record) + tests/boundary/fold11-reconcile-oracle.sh, using the
# REAL gh against a real merged PR.

echo "== ready: JSON array of claimable beads =="
run "$RT" ready 2>/dev/null | jq -e 'type=="array"' >/dev/null 2>&1 && pass || fail "ready emits a JSON array"

echo "== work_root: TARGET build — worktree of the target, work_root, PRISTINE finish, PR on target, fail-closed =="
# A throwaway TARGET repo (pristine product + a committed dod test for C2 + its origin bare) and a
# repos.config mapping a logical name. The deny-hook confinement of the worktree is proven in tests/hooks;
# here we prove the PRODUCER: cmd_start worktrees the TARGET + records work_root=realpath(wt); cmd_finish
# produces a PURE-PRODUCT commit (zero .beads/, zero forge paths) and opens the PR on the TARGET remote.
TGT="$(mktemp -d)"
TGT_BARE="$(mktemp -d)"
# FOLD #3: the TARGET's origin is captured + validated at target start too, so give the throwaway target a
# github-shaped origin (distinct from the forge's, so the line-265 assertion still proves "the target's
# remote, not the forge's"). Establish main against the local bare (offline setup push), then repoint.
TGT_ORIGIN="https://github.com/example-org/synthtarget.git"
(
  cd "$TGT" || exit 1
  git init -q && git config user.email t@t && git config user.name t
  git symbolic-ref HEAD refs/heads/main
  printf '<h1>landing</h1>\n' >index.html
  mkdir -p tests && printf '#!/usr/bin/env bash\nexit 0\n' >tests/dod.sh && chmod +x tests/dod.sh
  git add -A && git commit -q -m init
  git -C "$TGT_BARE" init -q --bare
  git remote add origin "$TGT_BARE" && git push -q -u origin main
  git remote set-url origin "$TGT_ORIGIN" # FOLD #3: target origin must be a github URL for START's capture
)
TGT_RP="$(realpath "$TGT")"
REPOSCFG="$T/repos.config"
printf 'synthtarget=%s\n' "$TGT" >"$REPOSCFG"
# A spec in the FORGE (source_spec is forge-relative; the gate re-reads its Task Breakdown anchor T001).
mkdir -p "$T/specs"
tslice="$(jq -nc '{scope:["about.html"], dod_tests:["tests/dod.sh"], sc_evidence:[{sc:1, path:"about.html"}]}')"
ttask="$(jq -nc --argjson a "$tslice" '{id:"T001", title:"landing about page", target_repo:"synthtarget"} + $a')"
{
  printf '# landing spec\n\n<!-- forge:tasks:begin v1 -->\n```json\n'
  printf '{"target_repos":["synthtarget"],"tasks":[%s]}\n' "$ttask"
  printf '```\n<!-- forge:tasks:end -->\n'
} >"$T/specs/landing.md"
# inject a bead with the convert-minted contract (fake-bd create sets no metadata, so inject directly)
tmeta="$(jq -nc --argjson a "$tslice" '{target_repo:"synthtarget", source_spec:"specs/landing.md", task_id:"T001", accept:$a}')"
jq --argjson m "$tmeta" '. + [{id:"fx-tgt", title:"landing about page", status:"open", priority:2, issue_type:"task", metadata:$m}]' "$BD_FAKE_STATE" >"$BD_FAKE_STATE.t" && mv "$BD_FAKE_STATE.t" "$BD_FAKE_STATE"
tinj() { jq --arg id "$1" --arg tr "$2" '. + [{id:$id, title:$id, status:"open", priority:2, issue_type:"task", metadata:{target_repo:$tr}}]' "$BD_FAKE_STATE" >"$BD_FAKE_STATE.t" && mv "$BD_FAKE_STATE.t" "$BD_FAKE_STATE"; }

# --- target START: worktree of the TARGET, work_root recorded ---
# ATTENDED via pty: Item-4's preclaim gate runs BEFORE the self/target classification, so it gates EVERY
# start (self AND target). The pty exempts it; FORGE_REPOS_CONFIG passes through as a shell prefix.
out="$(run_pty "FORGE_REPOS_CONFIG='$REPOSCFG' '$RT' start fx-tgt")"
rc=$?
[ "$rc" -eq 0 ] && pass || fail "target start exit 0 (rc=$rc): $out"
twt="$(jq -r '.worktree // empty' "$SENT" 2>/dev/null)"
{ [ -n "$twt" ] && [ "$(jq -r '.work_root // empty' "$SENT")" = "$(realpath "$twt")" ]; } && pass || fail "sentinel.work_root == realpath(worktree)"
[ "$(jq -r '.target_path // empty' "$SENT")" = "$TGT_RP" ] && pass || fail "sentinel.target_path == realpath(target)"
# FOLD #3: the worktree shares the TARGET's .git, so its origin is the TARGET's captured github URL —
# distinct from the forge's, still proving "the target's remote, not the forge's" (substance preserved).
[ "$(git -C "$twt" config --get remote.origin.url 2>/dev/null)" = "$TGT_ORIGIN" ] && pass || fail "worktree origin is the TARGET remote ($TGT_ORIGIN), not the forge"
git -C "$TGT" worktree list 2>/dev/null | grep -qF "$twt" && pass || fail "worktree registered in the TARGET git, not the forge"
[ "$(sf_status fx-tgt)" = "in_progress" ] && pass || fail "target bead claimed forge-side"

# --- target FINISH: gate passes on the target worktree; PURE-PRODUCT commit (pre-push, offline) ---
# Like the self finish, the github-only push DIES offline; the COMMIT-side facts (task branch created in
# the TARGET, the pure-product commit carries about.html + zero forge paths) happen BEFORE the push and ARE
# testable. We do NOT assert `finish exit 0`. ATTENDED via pty (Item-4 gates the finish path too).
printf '<p>about</p>\n' >"$twt/about.html" # the agent's product write, inside work_root
out="$(run_pty "FORGE_REPOS_CONFIG='$REPOSCFG' '$RT' finish")"
ttbr="$(git -C "$TGT" for-each-ref --format='%(refname:short)' 'refs/heads/task/*' | head -1)"
[ -n "$ttbr" ] && pass || fail "target task branch created in the TARGET repo"
tfiles="$(git -C "$TGT" ls-tree -r --name-only "$ttbr" 2>/dev/null)"
printf '%s\n' "$tfiles" | grep -qx "about.html" && pass || fail "target commit carries the product write (about.html)"
printf '%s\n' "$tfiles" | grep -qE '(^|/)\.beads/|(^|/)harness/|(^|/)\.claude/' && fail "PRISTINE VIOLATION: forge path in the target commit" || pass
# MOVED OUT (FOLD #3): `target finish exit 0`, `target bead -> in_review`, `sentinel cleared after target
# finish` happen AFTER the github push, which dies offline — finish cannot reach them here. Push MECHANISM
# pinned by fold3, record CONSUME by fold13; the finish WRITE side has NO offline integration coverage
# post-FOLD #3 (runs on every real github finish), shape contract pinned by fold13. KNOWN RESIDUAL.
# The target finish died at the push, so the fx-tgt task is still active; release it via kill-switch.
run "$KS" >/dev/null 2>&1
[ ! -f "$SENT" ] && pass || fail "kill-switch cleared the fx-tgt task after the offline-failed target finish"

# --- fail-closed: unlisted name / non-git path / non-absolute path — all refuse BEFORE any side effect ---
# ATTENDED via pty so the INTENDED forge_resolve_target_repo refusal fires (it runs AFTER Item-4's preclaim;
# an unattended run would mask the intended reason with the Item-4 message). Assert the right-reason refusal.
tinj fx-unl notlisted
out="$(run_pty "FORGE_REPOS_CONFIG='$REPOSCFG' '$RT' start fx-unl")"
rc=$?
{ [ "$rc" -ne 0 ] && [ ! -f "$SENT" ] && [ "$(sf_status fx-unl)" = "open" ] && printf '%s' "$out" | grep -qF "not listed"; } && pass || fail "unlisted target_repo fails closed for the right reason (no start/sentinel/claim): $out"
NONGIT="$(mktemp -d)"
printf 'nogit=%s\n' "$NONGIT" >>"$REPOSCFG"
tinj fx-ng nogit
out="$(run_pty "FORGE_REPOS_CONFIG='$REPOSCFG' '$RT' start fx-ng")"
rc=$?
{ [ "$rc" -ne 0 ] && [ ! -f "$SENT" ] && printf '%s' "$out" | grep -qF "is not a git repository"; } && pass || fail "non-git target path fails closed for the right reason: $out"
printf 'rel=relative/not/absolute\n' >>"$REPOSCFG"
tinj fx-rel rel
out="$(run_pty "FORGE_REPOS_CONFIG='$REPOSCFG' '$RT' start fx-rel")"
rc=$?
{ [ "$rc" -ne 0 ] && [ ! -f "$SENT" ] && printf '%s' "$out" | grep -qF "non-absolute path"; } && pass || fail "non-absolute target path fails closed for the right reason: $out"

# --- FORGE_SANDBOX=1 + target -> container-open: NO LONGER dies at :166. With the manifest + docker it
# brings up a REAL container on the TARGET worktree and PROCEEDS (D1: FORGE_SANDBOX=1 satisfies the :107
# preclaim; container-mandatory under FORGE_UNATTENDED). The container path also lives in
# tests/integration; here we pin the LIFECYCLE change (no :166 fail-close, claim + container proceed). Real bring-up needs
# docker — skip cleanly without it; FORGE_REQUIRE_DOCKER=1 makes the skip a hard fail.
tinj fx-sb synthtarget
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  out="$(FORGE_SANDBOX=1 FORGE_SANDBOX_IMAGE="${FORGE_SANDBOX_IMAGE:-mcr.microsoft.com/devcontainers/javascript-node:20}" FORGE_REPOS_CONFIG="$REPOSCFG" run "$RT" start fx-sb 2>&1)"
  rc=$?
  sbwt="$(jq -r '.worktree // empty' "$SENT" 2>/dev/null)"
  { [ "$rc" -eq 0 ] && [ -n "$sbwt" ] && [ "$(jq -r '.work_root // empty' "$SENT" 2>/dev/null)" = "$(realpath "$sbwt" 2>/dev/null)" ] && [ "$(sf_status fx-sb)" = "in_progress" ]; } && pass || fail "FORGE_SANDBOX=1 target PROCEEDS past :166 (container-open): exit 0, work_root recorded, claimed (rc=$rc): $out"
  printf '%s' "$out" | grep -qF "container sub-slice" && fail "the stale :166 'container sub-slice' refusal is STILL present (it was removed)" || pass
  { [ -n "$sbwt" ] && [ "$(docker ps -q --filter "label=devcontainer.local_folder=$sbwt" | wc -l)" = "1" ]; } && pass || fail "FORGE_SANDBOX=1 target brought up a REAL container on the target worktree"
  run "$KS" >/dev/null 2>&1 # release the bead + tear the container down so the next test starts clean
  docker ps -aq --filter "label=devcontainer.local_folder=$sbwt" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1
elif [ "${FORGE_REQUIRE_DOCKER:-0}" = "1" ]; then
  fail "FORGE_SANDBOX=1 target container-open REQUIRED on this gate (FORGE_REQUIRE_DOCKER=1; docker absent)"
else
  skip "FORGE_SANDBOX=1 target container-open — docker absent (covered in tests/integration)"
fi

# --- forge-named SELF build (target_repo == the forge's OWN name) -> SELF, NOT a target / fail-closed ---
# convert mints target_repo on EVERY bead, so a spec targeting the forge itself yields
# target_repo="agentic-builder-forge" (the forge's package.json name) with NO repos.config entry. This MUST
# classify SELF (worktree of the forge, no work_root), NOT die at resolution — the A4 regression the full
# gate caught (resolve-then-classify). Proves the classify-then-resolve fix.
jq '. + [{id:"fx-self", title:"forge self via convert", status:"open", priority:2, issue_type:"task", metadata:{target_repo:"agentic-builder-forge"}}]' "$BD_FAKE_STATE" >"$BD_FAKE_STATE.t" && mv "$BD_FAKE_STATE.t" "$BD_FAKE_STATE"
# ATTENDED via pty (Item-4 exempts the self-build); this classifies SELF (forge's own name) and must reach
# a successful start, NOT die at repos.config resolution — proves classify-then-resolve.
out="$(run_pty "FORGE_REPOS_CONFIG='$REPOSCFG' '$RT' start fx-self")"
rc=$?
[ "$rc" -eq 0 ] && pass || fail "forge-named self start exits 0 (NOT fail-closed at repos.config): $out"
sswt="$(jq -r '.worktree // empty' "$SENT" 2>/dev/null)"
[ -z "$(jq -r '.work_root // empty' "$SENT" 2>/dev/null)" ] && pass || fail "forge-named self: sentinel has NO work_root (legacy sandbox/ confinement)"
{ [ -n "$sswt" ] && git -C "$T" worktree list 2>/dev/null | grep -qF "$sswt"; } && pass || fail "forge-named self: worktree registered in the FORGE git (self build)"
run "$KS" >/dev/null 2>&1
[ ! -f "$SENT" ] && pass || fail "kill-switch cleared the forge-named self task"

rm -rf "$TGT" "$TGT_BARE" "${NONGIT:-}" 2>/dev/null

echo
echo "==== $PASS passed, $FAIL failed, $SKIP skipped (src: $SRC) ===="
[ "$FAIL" = 0 ]
