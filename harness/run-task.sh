#!/usr/bin/env bash
# agentic-builder-forge — task loop runner + Beads integration.
#
#   start <bead-id>             claim an existing READY bead, open its worktree+branch (slug from title)
#   start --new "<desc>"        mint a bead then claim it (the only create path)
#   finish                      GREEN tests -> commit, push, open PR, bead -> in_review (+PR ref); NO merge
#   status                      show the active task + its bead
#   ready                       list claimable beads (bd ready --json)
#   board                       emit the stable 7-key board contract projection (Agent B reads this)
#   sync                        reconcile: close in_review beads whose PR merged (mechanical, event-derived)
#
# Deployed enforcement-protected file: agent edits are floor-denied; changes are authored as sandbox/ candidates and human-spliced under FORGE_ALLOW_HOOK_EDIT=1 (audit-logged).
# One task at a time. The worktree is branched from HEAD so it carries the LIVE hooks. TRUSTED harness:
# only ever pushes the task branch / opens a PR — never main, never --merge. bd runs ALWAYS against the
# single DB in the MAIN checkout (forge_bd -> bd -C "$ROOT"). Set FORGE_SKIP_INSTALL=1 to skip install.
set -uo pipefail
# Defense-in-depth: clear-all-but-allowlist the loader env (the within-script half of the boundary)
# BEFORE any tool resolves, so a sandbox/-shimmed git/jq/bd/env or an LD_PRELOAD/LD_AUDIT/
# GCONV_PATH/LOCPATH/GLIBC_TUNABLES .so cannot run on the finish/start/abort path. The
# LAUNCH-TIME interpreter/loader firing (shim bash / preloaded env via the shebang) is the
# deny-hook env-prefix classifier + container boundary's job, NOT this fix.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
IFS=$' \t\n'
for _fv in $(compgen -e 2>/dev/null); do
  case "$_fv" in
    PATH|HOME|SHELL|PWD|OLDPWD|TERM|USER|LOGNAME|HOSTNAME|TMPDIR|TZ|LANG|LANGUAGE|LC_ALL|SSH_AUTH_SOCK|GH_TOKEN|GITHUB_TOKEN) : ;;
    LC_*|FORGE_*|CLAUDE_*|XDG_*|NODE_*|npm_*|PNPM_*|COREPACK_*) : ;;
    *) unset "$_fv" 2>/dev/null || true ;;
  esac
done
unset _fv
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../.claude/hooks/lib.sh
. "$HERE/../.claude/hooks/lib.sh"
# shellcheck source=beads-lib.sh
# FOLD #12: drop any inherited BD_BIN BEFORE sourcing beads-lib (matches accept-gate PD-2) so an
# agent-exported BD_BIN/PATH-shim is not even present when the lib pins it; beads.config's absolute default wins.
unset BD_BIN
. "$HERE/beads-lib.sh"
# shellcheck source=sandbox-lib.sh
. "$HERE/sandbox-lib.sh"   # forge_sandbox_up/exec/down — per-task confinement sandbox
# Toolchain-restore: append the trusted Node toolchain dir (devcontainer) — system dirs stay first
if ! command -v devcontainer >/dev/null 2>&1; then
  _fth="$(forge_trusted_home)"
  for _ftd in "$_fth"/.nvm/versions/node/*/bin; do
    [ -x "$_ftd/devcontainer" ] && { export PATH="$PATH:$_ftd"; break; }
  done
  unset _fth _ftd
fi

# DOC-1: strip every agent-exported git-env that can redirect root/index/objects/config BEFORE
# resolving ROOT — forge_main_root runs a bare `git rev-parse` (the one unsanitized git call FOLD #5
# missed); without this an exported GIT_DIR/GIT_COMMON_DIR points it at an agent-chosen gitdir. Makes
# the env-i invariant TOTAL across root resolution. (forge_safe_env re-sets the config masks per call.)
unset GIT_DIR GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE GIT_WORK_TREE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
ROOT="$(forge_main_root)" || {
  echo "run-task: not inside a git repo" >&2
  exit 1
}
# FOLD #12 (load-bearing): unset BD_BIN again immediately before forge_beads_load so beads.config's
# absolute `:-` default authoritatively wins — the finish/reconcile bd channel cannot run a shimmed binary.
unset BD_BIN
forge_beads_load "$ROOT"
HARNESS="$ROOT/.harness"
SENTINEL="$HARNESS/active-task.json"
WTBASE="$ROOT/.claude/worktrees"

die() {
  printf 'run-task: %s\n' "$1" >&2
  exit 1
}
slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40; }

# cp-workroot (H1): resolve a bead's logical target_repo NAME to an absolute git-repo path via the
# enforce-protected harness/repos.config (`name=abs-path` lines). FORGE_REPOS_CONFIG is a CONTROL-PLANE
# test seam (like FORGE_DENY_HOOK / FORGE_ACCEPT_GATE): run-task's launch env is trusted — set by the
# human/launcher control-plane-side, never agent-derived in model (c).
# This mapping DEFINES a confinement target — its realpath becomes the work_root the deny hook anchors on —
# so resolution is FAIL-CLOSED: an unlisted name, a non-absolute value, a missing path, or a non-git-repo
# all die. Prints the realpath-canonical path (no trailing slash) for the hook's absolute-prefix match.
# (die inside the $(...) subshell exits it non-zero; the caller's `|| exit 1` propagates the refusal.)
forge_resolve_target_repo() {
  local name="$1" cfg val k v rp
  cfg="${FORGE_REPOS_CONFIG:-$ROOT/harness/repos.config}"
  [ -f "$cfg" ] || die "target_repo '$name' requested but $cfg is missing — cannot resolve a confinement target (fail closed)"
  val=""
  # `|| [ -n "$k" ]` keeps a final line lacking a trailing newline from being silently dropped (a listed
  # target must never resolve as "unlisted"); `${v%$'\r'}` tolerates a CRLF-edited config.
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in '' | \#*) continue ;; esac
    [ "$k" = "$name" ] && val="${v%$'\r'}"
  done <"$cfg"
  [ -n "$val" ] || die "target_repo '$name' is not listed in $cfg — refusing (fail closed; add an entry through the door)"
  case "$val" in
    /*) : ;;
    *) die "target_repo '$name' maps to a non-absolute path '$val' — refusing (fail closed)" ;;
  esac
  rp="$(realpath -e "$val" 2>/dev/null)" || die "target_repo '$name' path '$val' does not exist — refusing (fail closed)"
  git -C "$rp" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "target_repo '$name' path '$rp' is not a git repository — refusing (fail closed)"
  printf '%s' "$rp"
}

# Warn — or, with FORGE_REQUIRE_ROOT=1, refuse — when not at the repo root. Claude Code loads .claude/
# hooks from the LAUNCH cwd only (no parent fallback, claude-code#12962), so a session started outside
# the root runs WITHOUT the deny hooks. $PWD != ROOT is a heuristic (can't read the actual launch dir;
# subdir-launch-then-cd slips past) — it catches the common mistake loudly without blocking on it.
require_root() {
  [ "$PWD" = "$ROOT" ] && return 0
  printf '\n  ⚠  NOT AT REPO ROOT\n     cwd:  %s\n     root: %s\n' "$PWD" "$ROOT" >&2
  printf '     Claude Code loads .claude/ hooks from the launch cwd only (claude-code#12962). If this\n' >&2
  printf '     session was launched outside the root, the deny hooks are NOT loaded and this run is\n' >&2
  printf '     UNPROTECTED. Re-launch Claude Code from the repo root above.\n' >&2
  if [ "${FORGE_REQUIRE_ROOT:-0}" = "1" ]; then
    printf '     FORGE_REQUIRE_ROOT=1 -> refusing.\n\n' >&2
    exit 1
  fi
  printf '     (set FORGE_REQUIRE_ROOT=1 to make this a hard refusal)\n\n' >&2
}

cmd_start() {
  require_root
  local a1="${1:-}" desc id title slug branch wt base showf readyf basesha trepo repo work_root tpath forge_self source_spec="" feat_branch="" integration_base="" _claim_ok=""
  [ -n "$a1" ] || die 'usage: run-task.sh start <bead-id> | start --new "<desc>"'
  [ -f "$SENTINEL" ] && die "a task is already active ($(jq -r .branch "$SENTINEL" 2>/dev/null)); finish or kill-switch first"
  forge_beads_preflight || die "bd preflight failed (see message above)"

  # Item 4: a non-attended self-build must not start without the confinement boundary — refuse
  # BEFORE any side effect (no mint, no worktree, no claim). Attended (TTY + FORGE_UNATTENDED unset) is
  # exempt. Reuses the witness discriminator; fail-closed on ambiguity (absence-of-signal => mandatory).
  forge_require_boundary_or_attended_preclaim || exit 1

  if [ "$a1" = "--new" ]; then
    desc="${2:-}"
    [ -n "$desc" ] || die 'usage: run-task.sh start --new "<desc>"'
    id="$(forge_bd create "$desc" -p "${BD_DEFAULT_PRIORITY:-2}" --silent 2>/dev/null | tr -d '[:space:]')"
    [ -n "$id" ] || die "bd create returned no id"
  else
    id="$a1"
  fi

  # Fail-closed claimability: the bead must EXIST, be in `bd ready`, and be unassigned. No mint, no re-claim.
  # T1/T2: the NATIVE check (forge_beads_claimable) is the pin and runs UNCHANGED. On a native MISS
  # we DEFER the die instead of dying here, so the Q0 overlay (claimable := native OR forge_intra_feature_ready)
  # can be evaluated below, AFTER feat/F + repo are known (the overlay needs both). title + source_spec are
  # read from the LIVE showf before it is removed (source_spec is the feature-grouping key + the gate flag).
  showf="$(mktemp)"
  readyf="$(mktemp)"
  forge_bd show "$id" --json >"$showf" 2>/dev/null
  forge_bd ready --json >"$readyf" 2>/dev/null
  title="$(jq -r '.[0].title // empty' "$showf")"
  source_spec="$(jq -r '.[0].metadata.source_spec // empty' "$showf")"
  # F4: canonicalize $id to the bead's full .id from the SAME bd-show resolution ($showf is still live
  # here), BEFORE the branch (task/$id-$slug), sentinel (.bead), and record (.harness/pr/$id.json via
  # beads-lib.sh forge_finish_record_pr) are built from it. An id-PREFIX start (`start fx-im` when `fx-imd` is
  # ready) would otherwise diverge those from the canonical .id the reconcile oracle drives off (bd list .id),
  # so the merged PR lingers in_review and never auto-closes (fail-closed, never a wrong-close). A full-id
  # start is a no-op (.[0].id == $id). Empty .id (bead not found) leaves $id untouched -> the existing
  # claimability failure below still fires. This also makes the task/<id>-<slug> naming prefix-robust.
  local _cid; _cid="$(jq -r '.[0].id // empty' "$showf")"; [ -n "$_cid" ] && id="$_cid"
  if forge_beads_claimable "$showf" "$readyf"; then _claim_ok=1; else _claim_ok=0; fi
  rm -f "$showf" "$readyf"
  # T2 back-compat: route the missing/unclaimable NON-feature case back to the ORIGINAL claimability
  # failure. Such a bead can never reach the intra-feature overlay (no source_spec = no grouping key), so it
  # must fail closed HERE with the claimability message — byte-identical to the pre-assembly path; the early
  # title-read must NOT pre-empt it with 'has no title'. A natively-claimable bead keeps the original title
  # sanity check; a feature bead (source_spec present) that missed the native claim defers to the overlay
  # verdict below (which re-checks existence/unassigned and fail-closes on every unresolved input).
  if [ "$_claim_ok" = "1" ]; then
    [ -n "$title" ] || die "bead '$id' has no title"
  elif [ -z "$source_spec" ]; then
    die "bead '$id' is not claimable (missing, not ready, or already claimed) — no silent mint, no re-claim"
  fi

  desc="$title"
  slug="$(slugify "$desc")"
  [ -n "$slug" ] || slug="task"
  # Bind the single-task head ref to THIS bead's id (task/<id>-<slug>) so the reconcile oracle can
  # match on the gh-VOUCHED head ref (beads-lib.sh forge_reconcile_id_bound ARM 1), never on the agent-
  # writable record.branch. Ids are fx-[a-z0-9]{3} (hyphen-free) and slugify emits [a-z0-9-] — delimiter-safe
  # with zero prefix collisions. The worktree dir stays $slug; only the branch/head-ref carries the id.
  branch="task/$id-$slug"
  wt="$WTBASE/$slug"

  # cp-workroot (H1): self-vs-target discrimination. A bead with NO metadata.target_repo, or one that
  # resolves to the forge ITSELF, is a SELF build — worktree of the forge, NO work_root (the deny hook
  # falls to legacy sandbox/ confinement, byte-identical). An EXTERNAL target_repo is a TARGET build —
  # worktree of the TARGET repo, work_root=realpath(worktree). The name->path map is the enforce-protected
  # repos.config (fail-closed). bd/ledger/floor stay FORGE-SIDE throughout (forge_bd is bd -C "$ROOT").
  trepo="$(forge_bd show "$id" --json 2>/dev/null | jq -r '.[0].metadata.target_repo // empty' 2>/dev/null)"
  repo="$ROOT"
  work_root=""
  tpath=""
  # cp-workroot (H1): CLASSIFY before resolving. convert mints target_repo on EVERY bead, so a spec
  # targeting the forge ITSELF yields target_repo=<the forge's own name>, which has NO repos.config entry
  # by design. Recognize the forge's own logical name (its package.json name; FORGE_SELF_REPO overrides)
  # as SELF *before* resolution — the forge-as-target case must never enter (or fail closed against)
  # repos.config; resolution then stays strictly fail-closed for genuine EXTERNAL names. (Empty
  # target_repo, i.e. start --new, is self too.)
  forge_self="${FORGE_SELF_REPO:-$(jq -r '.name // empty' "$ROOT/package.json" 2>/dev/null)}"
  if [ -n "$trepo" ] && [ "$trepo" != "$forge_self" ]; then
    tpath="$(forge_resolve_target_repo "$trepo")" || exit 1
    # SELF iff the resolved repo shares the FORGE's git store (the forge root, a forge subdir, or a forge
    # worktree all report the forge's common .git) — robust against an in-forge path that a bare path
    # compare would miscall a target. A DISTINCT git store => a genuine TARGET build.
    _fc="$(realpath "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" 2>/dev/null)"
    _tc="$(realpath "$(git -C "$tpath" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" 2>/dev/null)"
    if [ -z "$_tc" ] || [ "$_tc" != "$_fc" ]; then
      repo="$tpath" # TARGET build (distinct git store)
      # T1: target builds are CONTAINER-WIRED. OS confinement comes from the bring-up + liveness
      # block below (FORGE_SANDBOX=1; or FORGE_TARGET_REQUIRE_CONTAINER=1 forces it on an attended target). A
      # non-attended target without FORGE_SANDBOX=1 is already refused at the preclaim gate above — both layers
      # are now active, not one silently inactive. FORGE_MAIN_ROOT stays $ROOT so the RO enforce mounts are the
      # forge's (model (c): work_root RW, the whole forge tree RO/absent).
    fi
  fi

  # T2: feat/F lifecycle. integration_base = the repo's current HEAD branch (= today's base for a
  # self / non-feature build). A bead WITH a metadata.source_spec is a FEATURE build: feat/F is the
  # integration base its siblings merge onto. no-side-effect: compute the feat/F
  # NAME here but DEFER its creation until AFTER the claim is granted, so a blocked refusal leaves no orphan
  # branch. A bead WITHOUT a source_spec (start --new, non-feature) falls through to today's
  # base=symbolic-ref behavior byte-for-byte.
  integration_base="$(git -C "$repo" symbolic-ref --short HEAD)"
  if [ -n "$source_spec" ]; then
    # Q1: the reconcile dispatch reserves the `task/` prefix for single-task head refs (ARM 1/2). A
    # feature override that starts with `task/` would land folded beads in ARM 2 (skip) -> they linger
    # in_review, never closing (fail-closed, never a wrong-close, but confusing). Reject it up front. Scoped
    # to the feature path — FORGE_FEATURE_BRANCH is ignored for non-feature builds, so no over-block there.
    case "${FORGE_FEATURE_BRANCH:-}" in
      task/*) die "FORGE_FEATURE_BRANCH must not start with 'task/' (reserved for single-task head refs; a task/-prefixed override would misroute assembly-folded beads into the reconcile skip-arm): ${FORGE_FEATURE_BRANCH}" ;;
    esac
    feat_branch="${FORGE_FEATURE_BRANCH:-feat/$(slugify "$(basename "$source_spec" .md)")}"
    base="$feat_branch"
  else
    base="$integration_base"
  fi
  # T1/T7: the DEFERRED claim verdict — runs BEFORE any side effect. The native pin already
  # ran (forge_beads_claimable). On a miss, the ONLY relaxation is the intra-feature overlay (needs the
  # feat_branch NAME + repo, now known; the overlay's grant path requires feat/F to ALREADY exist, so no
  # branch creation is needed to evaluate it). Fail closed otherwise, naming the unsatisfied blocker(s). For
  # a non-feature bead source_spec is empty so the overlay is short-circuited and the die text is byte-identical.
  if [ "$_claim_ok" != "1" ]; then
    if [ -n "$source_spec" ] && forge_intra_feature_ready "$id" "$source_spec" "$feat_branch" "$repo"; then
      echo "→ claim via the intra-feature overlay (a blocks-dep is an in_review sibling merged onto $feat_branch)"
    else
      die "bead '$id' is not claimable (missing, not ready, or already claimed) — no silent mint, no re-claim${FORGE_UNSAT_BLOCKERS:+; unsatisfied intra-feature blocker(s): $FORGE_UNSAT_BLOCKERS}"
    fi
  fi
  # FINDING-1: claim GRANTED — NOW materialize feat/F if absent (the first task of this feature).
  # Deferred to here so a blocked refusal above leaves no orphan branch (fail-closed cases
  # leave no side effect). The overlay-grant path never reaches creation: feat/F already exists by then.
  if [ -n "$source_spec" ] && ! git -C "$repo" show-ref --verify --quiet "refs/heads/$feat_branch"; then
    [ -n "$integration_base" ] || die "cannot create $feat_branch: $repo HEAD is detached (not on the integration base) — refusing (fail closed)"
    git -C "$repo" branch "$feat_branch" "refs/heads/$integration_base" >/dev/null 2>&1 || die "could not create $feat_branch from $integration_base in $repo — refusing (fail closed)"
    echo "→ created feature branch $feat_branch from $integration_base (first task of this feature)"
  fi
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" && die "branch $branch already exists in $repo"
  [ -e "$wt" ] && die "worktree path $wt already exists"

  mkdir -p "$WTBASE"
  # cp-mechgate (D1): record the fork commit BEFORE worktree add (same HEAD — the order
  # documents intent); the acceptance gate diffs the task index against this recorded fact at finish.
  basesha="$(git -C "$repo" rev-parse "$base")"
  echo "→ creating worktree $wt on $branch (from $base — carries the live hooks)"
  forge_git -C "$repo" worktree add "$wt" -b "$branch" "$base" >/dev/null
  # cp-workroot (H1): a TARGET build's work_root is the RESOLVED-ABSOLUTE worktree path — the exact
  # string the deny hook anchors its target-mode confinement on (realpath => no trailing slash, no alias).
  # Fail CLOSED if it cannot be resolved: never silently fall to the self sentinel (that would leave a
  # target build with no work_root + no target_path, mis-routing the deny hook AND kill-switch teardown).
  if [ "$repo" != "$ROOT" ]; then
    work_root="$(realpath "$wt")" || die "could not resolve the target worktree path (realpath failed) — refusing (fail closed)"
    [ -n "$work_root" ] || die "target worktree resolved to an empty work_root — refusing (fail closed)"
  fi
  if [ "${FORGE_SKIP_INSTALL:-0}" != "1" ]; then
    echo "→ installing deps in the worktree (worktrees do not share node_modules)"
    (cd "$wt" && pnpm install --silent --ignore-scripts --frozen-lockfile) || die "pnpm install failed in worktree"
  fi
  # FOLD #3: capture the push remote URL NOW (before the agent runs) + validate its scheme/host,
  # so finish pushes to this LITERAL url — a later agent-planted url.insteadOf/remote.origin.url cannot
  # redirect it, and a poisoned-checkout (ext::/non-github origin) is refused here, not pushed to.
  push_url="$(forge_capture_push_url "$repo")" || die "could not capture/validate the push remote URL (FOLD #3): origin must be an https/ssh github URL"
  mkdir -p "$HARNESS"
  # T2: source_spec + feature_branch are the assembly single-source-of-truth read back by cmd_finish
  # (the feature-vs-non-feature switch + the feat/F to merge onto). Empty for a non-feature/self build
  # (cmd_finish then takes today's task-PR tail byte-for-byte).
  if [ -z "$work_root" ]; then
    # self build — no work_root => the deny hook uses legacy sandbox/ confinement; +source_spec/feature_branch
    jq -nc --arg t "$desc" --arg s "$slug" --arg b "$branch" --arg w "$wt" --arg base "$base" --arg basesha "$basesha" --arg bead "$id" --arg ts "$(date -u +%FT%TZ)" --arg purl "$push_url" --arg ss "$source_spec" --arg fb "$feat_branch" \
      '{task:$t,slug:$s,branch:$b,worktree:$w,base:$base,base_sha:$basesha,bead:$bead,started:$ts,pid:null,push_url:$purl,source_spec:$ss,feature_branch:$fb}' >"$SENTINEL"
  else
    # target build — record work_root (the deny hook's target-mode anchor) + the target repo name/path
    jq -nc --arg t "$desc" --arg s "$slug" --arg b "$branch" --arg w "$wt" --arg base "$base" --arg basesha "$basesha" --arg bead "$id" --arg ts "$(date -u +%FT%TZ)" --arg wr "$work_root" --arg tr "$trepo" --arg tp "$tpath" --arg purl "$push_url" --arg ss "$source_spec" --arg fb "$feat_branch" \
      '{task:$t,slug:$s,branch:$b,worktree:$w,base:$base,base_sha:$basesha,bead:$bead,started:$ts,pid:null,work_root:$wr,target_repo:$tr,target_path:$tp,push_url:$purl,source_spec:$ss,feature_branch:$fb}' >"$SENTINEL"
  fi

  # Claim is the critical path — atomic, AFTER the sentinel records the bead so kill-switch can release it.
  forge_bd update "$id" --claim --assignee "${BD_ACTOR:-forge-local}" >/dev/null 2>&1 ||
    die "bd claim failed for $id (kill-switch to clean up)"

  # Sandbox seam: bring the per-task confinement sandbox up around the provisioned worktree.
  # Placed after sentinel+claim so kill-switch.sh can release the bead on a bring-up failure. Crosses
  # INTO the sandbox: worktree path, bead id, targets. Stays RUNNER-SIDE: all bd, the PR, reconcile,
  # kill-switch. FORGE_SANDBOX=1 activates it; the automated execution flow sets it.
  if [ "${FORGE_SANDBOX:-0}" = "1" ] || { [ -n "$work_root" ] && [ "${FORGE_TARGET_REQUIRE_CONTAINER:-0}" = "1" ]; }; then
    export FORGE_MAIN_ROOT="$ROOT"
    echo "→ bringing up the confinement sandbox for the worktree"
    forge_sandbox_up "$wt" || die "sandbox bring-up failed for $id (kill-switch to release the bead)"
    # Item 4 (liveness): the boundary must DEMONSTRABLY deny a write (EROFS), not merely be "up".
    forge_require_boundary_or_attended_postup "$wt" || { forge_sandbox_down "$wt" 2>/dev/null; die "boundary liveness check failed for $id (kill-switch to release the bead)"; }
    # F7c: FAILURE-path teardown — if start dies/interrupts AFTER bring-up, tear the container
    # down so an abandoned bring-up does not leave a container + RW .git mount (amplifies F1). Fires on
    # a NON-ZERO run-task exit; a SUCCESSFUL start leaves the container up by design. RESIDUAL (named,
    # NOT closed): an abandoned-after-SUCCESSFUL-start session (no finish/kill-switch ever runs) keeps
    # the container — the out-of-band stale-container reaper (harness/reaper.sh) covers that case.
    trap 'rc=$?; [ "$rc" = 0 ] || { echo "→ start failed after sandbox bring-up — tearing it down" >&2; forge_sandbox_down "$wt" 2>/dev/null || true; }' EXIT
    echo "  sandbox up — the TDD loop runs INSIDE it (teardown wired at finish/kill-switch)"
  fi

  cat <<EOF

✓ task started: $desc
  bead:     $id   (claimed by ${BD_ACTOR:-forge-local} → in_progress)
  branch:   $branch   (base: $base)
  worktree: $wt
  Work ONLY under: ${work_root:-$wt/sandbox/}   (writes outside are DENIED while a task is active)
  TDD: write a failing test, then code. The Stop gate blocks "done" until tests are GREEN.
  When green:  ./harness/run-task.sh finish
  To abort:    ./harness/kill-switch.sh   (releases the bead back to ready)
EOF
}

cmd_finish() {
  require_root
  [ -f "$SENTINEL" ] || die "no active task"
  local branch wt base task bead prurl base_sha work_root source_spec feat_branch target_path _repo_root integration_base _feat_before="" _merge_commit="" _asm_out _asm_rc
  branch="$(jq -r .branch "$SENTINEL")"
  wt="$(jq -r .worktree "$SENTINEL")"
  base="$(jq -r .base "$SENTINEL")"
  task="$(jq -r .task "$SENTINEL")"
  bead="$(jq -r '.bead // empty' "$SENTINEL")"
  # cp-workroot (H1): a TARGET build records work_root; its presence switches finish to the pristine-
  # target path (no ledger injected into the target commit; gh runs from the worktree -> target remote).
  work_root="$(jq -r '.work_root // empty' "$SENTINEL")"
  # The assembly switch (source_spec) + the feat/F to merge onto; empty => the byte-for-byte task-PR
  # tail. _repo_root locates the repo the merge + feature PR live in (TARGET for a target build, forge for
  # self). The integration base (feature-PR target) is re-derived at PR time from _repo_root's HEAD.
  source_spec="$(jq -r '.source_spec // empty' "$SENTINEL")"
  feat_branch="$(jq -r '.feature_branch // empty' "$SENTINEL")"
  target_path="$(jq -r '.target_path // empty' "$SENTINEL")"
  if [ -n "$work_root" ]; then _repo_root="$target_path"; else _repo_root="$ROOT"; fi
  # A gate/test RED on a FEATURE build that ALREADY merged >=1 sibling onto feat/F is a PARTIAL
  # (surface state:partial in the enforce-protected assembly log, leave the feature PR open, no rollback,
  # bead stays claimed); a FIRST-task failure (no merges yet) is a NORMAL gate failure (no partial write).
  _finish_red_die() {
    local fpr frepo
    if [ -n "$source_spec" ] && [ -n "$feat_branch" ] && [ "$(forge_assembly_merge_count "$feat_branch")" -gt 0 ]; then
      forge_assembly_set "$feat_branch" last_error "post-sibling-failure: bead $bead — $1"
      forge_assembly_set "$feat_branch" state "partial"
      fpr="$(jq -r '.feature_pr // empty' "$ROOT/.harness/assembly/$(basename "$feat_branch").json" 2>/dev/null)"
      frepo="$(forge_repo_from_url "$(jq -r '.push_url // empty' "$SENTINEL")" 2>/dev/null)"
      if [ -n "$fpr" ] && [ -n "$frepo" ] && command -v gh >/dev/null 2>&1; then
        forge_clean_env timeout 15 gh pr comment "$fpr" --repo "$frepo" --body "Assembly PARTIAL: bead $bead failed after sibling(s) merged onto $feat_branch — $1. Merged siblings kept; this bead stays claimed (no rollback)." >/dev/null 2>&1 || true
      fi
      die "PARTIAL: $1 — $feat_branch keeps its merged sibling(s) (feature PR left open); bead $bead stays claimed (no rollback). Rebase/fix and re-finish."
    fi
    die "$1"
  }
  [ -d "$wt" ] || die "worktree $wt is missing"
  forge_load_target || die "cannot load targets.config"
  forge_beads_preflight || die "bd preflight failed (see message above)"
  # cp-witness: prove the deny floor LOADED in THIS session before the privileged
  # finish path (commit/push/PR/bead mutation) runs. HARD under FORGE_UNATTENDED=1, AND HARD attended
  # on a clean witnessed session; warn-only attended ONLY while the floor is under active edit (an
  # uncommitted enforce-file diff) or the checkout never minted a witness (see forge_witness_gate in lib.sh).
  # declare -F guard (see intake.sh convert_preflight): degrade to the mechanical floor checks when
  # forge_witness_gate is not loaded (lib.sh predates the cp-witness splice); when loaded, its
  # two-mode logic decides hard-vs-warn.
  if declare -F forge_witness_gate >/dev/null 2>&1; then
    forge_witness_gate "$ROOT" ||
      die "finish: session-floor witness FAILED — the deny floor is not proven loaded in this session (fx-v0w; FORGE_UNATTENDED=1)"
  fi

  # cp-workroot (H1): TEST_CMD is the LANGUAGE-keyed command from targets.config, run IN the worktree — for
  # a TARGET build that runs the TARGET's own tests (e.g. typescript -> `pnpm test` -> the target's
  # package.json), keeping the target pristine (no forge test config in it). The per-bead dod_tests
  # (accept-gate C2) are the precise contract; a per-target LANGUAGE override (heterogeneous targets) is a
  # follow-on, not this slice.
  echo "→ verifying tests are GREEN ($TEST_CMD) before finishing"
  (cd "$wt" && eval "$TEST_CMD") || _finish_red_die "tests are RED — cannot finish (fix until green)"

  # cp-mechgate: stage FIRST, then run the deterministic per-bead acceptance gate on the
  # PURE agent diff (index vs the recorded fork commit — no harness-injected .beads churn, no
  # exemption constant). base_sha was recorded by cmd_start (D1); a sentinel without it predates
  # cp-mechgate and fails CLOSED (D3) — the gate consumes recorded facts, never merge-base
  # reconstructions. The gate READS and verdicts; on FAIL we die BEFORE any commit exists, so the
  # worktree is preserved for diagnosis and a re-run of finish is idempotent. The gate path is
  # HARDCODED (amendment A4) — no env indirection can substitute the gate at finish-time.
  echo "→ staging the task's changes (the acceptance gate verdicts the staged diff)"
  # FOLD #1: stage through a pristine gitdir so a planted clean filter / fsmonitor cannot execute
  # host-side. forge_safe_git_stage keeps the REAL index + objects (GIT_INDEX_FILE/GIT_OBJECT_DIRECTORY).
  _sf99p_gd="$(forge_safe_gitdir "$wt")" || die "could not build a pristine gitdir for staging (FOLD #1)"
  forge_safe_git_stage "$wt" "$_sf99p_gd" add -A
  # cp-mechgate (A4): drop any agent-staged .beads churn BEFORE the staged gate. bd auto-stages
  # .beads/issues.jsonl into the cwd's index; if the agent (or a dod_test) ran bd from the worktree it
  # would land in the pure-agent diff and trip C1 (staged mode grants NO .beads exemption — rescope-only).
  # The harness re-injects the authoritative snapshot post-gate (below), which rescope exempts; this keeps
  # the staged gate's no-exemption invariant intact for GENUINE offenders.
  forge_safe_git_stage "$wt" "$_sf99p_gd" restore --staged .beads 2>/dev/null || true
  rm -rf "$_sf99p_gd"
  base_sha="$(jq -r '.base_sha // empty' "$SENTINEL")"
  [ -n "$base_sha" ] || die "sentinel predates cp-mechgate — kill-switch and restart the task"
  echo "→ acceptance gate: diff⊆scope, dod_tests, sc_evidence (bead $bead)"
  /usr/bin/bash "$ROOT/harness/accept-gate.sh" --bead "$bead" --worktree "$wt" --base-sha "$base_sha" --mode staged ||
    _finish_red_die "acceptance gate FAILED (see .harness/acceptance/) — bead not finished"

  # Force-flush the AUTHORITATIVE ledger snapshot at $ROOT/.beads (the DB's home), then stage a COPY
  # into the task commit so the snapshot reaches main only via the human-merged PR. The $ROOT-vs-worktree
  # split lives here: bd writes $ROOT/.beads; we commit $wt/.beads/issues.jsonl. Staged EXPLICITLY,
  # post-gate: the ledger copy is harness-injected and is never part of the gated agent diff.
  # cp-workroot (H1, #2 PRISTINE TARGET): stage the ledger snapshot into the task commit ONLY for a SELF
  # build (the forge's own .beads reaching main via the PR). A TARGET build is PRISTINE — injecting a
  # .beads/ snapshot would put a FORGE artifact into the target's PR, the embedding model (c) forbids,
  # sneaking in at the finish seam. So skip entirely for a target build: the ledger stays forge-side and
  # the target commit carries PRODUCT ONLY. (This harness-injection is separate from the agent's gated
  # diff; both controls must hold — the accept-gate confines the agent's writes, this skip keeps finish
  # from injecting the ledger.)
  if [ -z "$work_root" ]; then
    echo "→ exporting the bead ledger snapshot ($ROOT/.beads/issues.jsonl)"
    forge_bd export -o "$ROOT/.beads/issues.jsonl" >/dev/null 2>&1 || true
    if [ -f "$ROOT/.beads/issues.jsonl" ]; then
      mkdir -p "$wt/.beads"
      cp "$ROOT/.beads/issues.jsonl" "$wt/.beads/issues.jsonl"
      _sf99p_lgd="$(forge_safe_gitdir "$wt")" && { forge_safe_git_stage "$wt" "$_sf99p_lgd" add .beads/issues.jsonl; rm -rf "$_sf99p_lgd"; }  # FOLD #3 (pristine stage)
    fi
  fi

  # cp-mechgate PD-1: re-verify scope ⊆ contract against the CURRENT index immediately before
  # the commit — closes the post-gate TOCTOU (the staged gate verdicted an earlier index; the commit
  # commits a LATER one in a separate process). rescope runs the FULL C0+C1+C2+C3+integrity re-verify and
  # exempts the harness-staged .beads/issues.jsonl. This MUST be the last statement before git commit —
  # nothing agent-reachable runs between it and the commit (the commit block below is a pure git read +
  # commit). The gate path stays HARDCODED (A4); the gate is the SOLE scope authority, re-asked here.
  echo "→ rescope gate: re-verifying diff⊆scope vs the staged index before commit (bead $bead)"
  /usr/bin/bash "$ROOT/harness/accept-gate.sh" --bead "$bead" --worktree "$wt" --base-sha "$base_sha" --mode rescope ||
    _finish_red_die "rescope acceptance gate FAILED (index changed after the staged gate; see .harness/acceptance/) — bead not finished"

  # H3: target-build PR purity — strip forge artifacts, then PROVE the staged index is pure BEFORE the
  # commit (after rescope, the last scope authority; the commit is a pure index read, so there is no post-assert
  # TOCTOU window). Target-only ([ -n "$work_root" ]); self builds are byte-identical untouched. The assert is
  # the guarantee — a remaining forge artifact dies HERE: no commit, no PR (model (c): pure product).
  if [ -n "$work_root" ]; then
    _sf_dmf_gd="$(forge_safe_gitdir "$wt")" || die "H3: could not build a pristine gitdir for the target purity check"
    forge_strip_forge_artifacts "$wt" "$_sf_dmf_gd" || { rm -rf "$_sf_dmf_gd"; die "H3: stripping forge artifacts from the staged index failed (git error) — refusing (fail closed)"; }
    forge_assert_target_pure "$wt" "$_sf_dmf_gd" || { rm -rf "$_sf_dmf_gd"; die "H3: target PR purity check FAILED — refusing to publish a polluted product PR (see stderr; fail closed)"; }
    rm -rf "$_sf_dmf_gd"
  fi

  # FOLD #3: route commit + push through pristine discipline (no agent-planted gpg.program/
  # filter/sshCommand/credential.helper/url.insteadOf fires host-side). commit via plumbing; push to the
  # captured-at-start LITERAL url with the new commit SHA + forced transport.
  echo "→ committing the task's sandbox changes + ledger snapshot in the worktree"
  _sf99p_fgd="$(forge_safe_gitdir "$wt")" || die "could not build a pristine gitdir for finish (FOLD #3)"
  if forge_safe_git "$wt" "$_sf99p_fgd" diff --cached --quiet; then
    echo "  (no changes to commit)"
    _sf99p_sha="$(forge_safe_git "$wt" "$_sf99p_fgd" rev-parse HEAD)"
  else
    _sf99p_sha="$(forge_safe_git_commit "$wt" "$_sf99p_fgd" "feat(sandbox): $task

Co-Authored-By: Claude <noreply@anthropic.com>")" || die "commit failed (FOLD #3)"
  fi

  # T3: a FEATURE build merges the task tip onto feat/F (LOCAL, --no-ff, abort-on-conflict, NEVER
  # force) and LOGS it BEFORE any push — so the integration + the unforgeable merge record exist even if a
  # later push fails. A conflict HALTS (merge --abort already ran in forge_safe_git_merge; feat/F unchanged).
  # A non-feature build skips this entirely (the task-PR tail below is byte-for-byte today's).
  if [ -n "$source_spec" ]; then
    forge_assembly_init "$feat_branch" "$source_spec" || die "assembly: could not initialize the merge log for $feat_branch (fail closed)"
    echo "→ assembling: merging $branch onto $feat_branch (--no-ff, abort-on-conflict, never force)"
    _asm_out="$(forge_safe_git_merge "$_repo_root" "$feat_branch" "$_sf99p_sha")"; _asm_rc=$?
    if [ "$_asm_rc" -eq 1 ]; then
      forge_assembly_set "$feat_branch" last_error "conflict merging $branch ($bead) onto $feat_branch"
      forge_assembly_set "$feat_branch" state "conflict"
      die "assembly CONFLICT merging $branch onto $feat_branch — merge --abort ran ($feat_branch unchanged); rebase the task branch on $feat_branch and re-finish (NEVER force). Bead $bead stays claimed."
    elif [ "$_asm_rc" -ne 0 ]; then
      die "assembly: git merge of $branch onto $feat_branch failed (rc $_asm_rc) — refusing (fail closed). Bead $bead stays claimed."
    fi
    _feat_before="$(printf '%s' "$_asm_out" | cut -f1)"
    _merge_commit="$(printf '%s' "$_asm_out" | cut -f2)"
    forge_assembly_append "$feat_branch" "$bead" "$branch" "$_sf99p_sha" "$_feat_before" "$_merge_commit" || die "assembly: could not append the merge record (fail closed)"
    echo "  merged onto $feat_branch: $_feat_before -> $_merge_commit"
  fi

  echo "→ pushing the task branch (never main, never --force)"
  _sf99p_purl="$(jq -r '.push_url // empty' "$SENTINEL")"
  [ -n "$_sf99p_purl" ] || die "no captured push URL in the sentinel (FOLD #3)"
  forge_safe_git_push "$wt" "$_sf99p_fgd" "$_sf99p_purl" "$branch" "$_sf99p_sha" || { rm -rf "$_sf99p_fgd"; die "push failed (FOLD #3)"; }
  # FOLD #4: derive --repo from the captured/validated URL (not gh config-resolution -> no
  # url.insteadOf redirect). Needed by BOTH the task-PR (non-feature) and the feature-PR (feature) tails.
  _sf99p_repo="$(forge_repo_from_url "$_sf99p_purl")" || { rm -rf "$_sf99p_fgd"; die "could not derive owner/repo from the captured push URL (FOLD #4) — refusing (no gh config-resolution fallback)"; }
  if [ -z "$source_spec" ]; then
    # ── non-feature build: one task -> one task PR (the pre-assembly tail; behavior unchanged) ──
    echo "→ opening a pull request ($branch → $base) — NOT merging"
    # FOLD #5: gh through forge_safe_env (env -i strips agent GIT_*); GITHUB_TOKEN explicit; GIT_DIR
    # = pristine so gh's git calls read no agent config (the FOLD #4 redirect-close, env-safe).
    prurl="$( forge_safe_env GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_DIR="$_sf99p_fgd" GIT_SSH_COMMAND="ssh -o BatchMode=yes" -- gh pr create --repo "$_sf99p_repo" \
      --base "$base" --head "$branch" --title "$task" \
      --body "Automated task branch from the agentic-builder-forge harness. Tests green; format/lint enforced. A human reviews and merges — never auto-merged.")" ||
      { rm -rf "$_sf99p_fgd"; die "gh pr create failed (is the base branch '$base' pushed to origin?)"; }
    rm -rf "$_sf99p_fgd"
    echo "  PR: $prurl"
    # Hold-until-merge (FOLD #13): set in_review + record the HARNESS-CAPTURED PR identity in the
    # enforce-protected .harness/pr/<bead>.json; reconcile (sync) closes it on the human merge.
    forge_finish_record_pr "$bead" "$_sf99p_repo" "$branch" "$prurl" "$HARNESS"
  else
    # ── T3/T4/T6 FEATURE build: push feat/F, ensure ONE feature PR, advisory review, record feat/F ──
    echo "→ pushing $feat_branch (the assembled feature branch) — never main, never --force"
    forge_safe_git_push "$wt" "$_sf99p_fgd" "$_sf99p_purl" "$feat_branch" "$_merge_commit" || { rm -rf "$_sf99p_fgd"; die "push of $feat_branch failed (FOLD #3)"; }
    rm -rf "$_sf99p_fgd"
    # The feature PR target is the integration base (main), re-derived from the still-on-main checkout HEAD.
    integration_base="$(git -C "$_repo_root" symbolic-ref --short HEAD 2>/dev/null)"
    [ -n "$integration_base" ] || die "could not resolve the integration base for the feature PR ($_repo_root HEAD detached) — refusing (fail closed)"
    echo "→ ensuring ONE feature PR ($feat_branch → $integration_base) — NOT merging"
    prurl="$(forge_ensure_feature_pr "$_sf99p_repo" "$feat_branch" "$integration_base" "$(basename "$source_spec" .md): assembled feature" "Assembled feature PR (agentic-builder-forge harness): task branches merged onto $feat_branch — topo-ordered, each green-gated by cp-mechgate; merges logged in .harness/assembly/$(basename "$feat_branch").json. A human reviews and merges $feat_branch → $integration_base — never auto-merged.")" || die "could not ensure the feature PR for $feat_branch (fail closed)"
    forge_assembly_set "$feat_branch" feature_pr "$prurl"
    echo "  feature PR: $prurl"
    # Record the FEATURE PR on THIS bead (branch=feat/F): every feature bead shares the same feat/F + PR
    # record, so reconcile (sync, UNCHANGED) closes the WHOLE feature together at the human's feat/F->main merge.
    forge_finish_record_pr "$bead" "$_sf99p_repo" "$feat_branch" "$prurl" "$HARNESS"
    # cutover: state=complete iff no bead with this source_spec is still open/in_progress.
    if forge_feature_complete "$source_spec"; then forge_assembly_set "$feat_branch" state "complete"; else forge_assembly_set "$feat_branch" state "assembling"; fi
    # AGGREGATE REVIEW: the advisory reviewer fires ONCE per feature — on COMPLETION, against
    # the ASSEMBLED feature PR, NON-gating. forge_review_feature_if_complete self-gates on forge_feature_complete,
    # so the per-task range fires are GONE (N finishes -> ONE review on the whole feat/F). It sets NO
    # FORGE_REVIEW_DIFF_MODE, so review-task.sh uses `gh pr diff "$prurl"` (the full feature diff) + repoints its
    # read-context worktree to the feature tip; the ratified spec + ledger are fed via FORGE_REVIEW_SOURCE_SPEC.
    forge_review_feature_if_complete "$source_spec" "$prurl" "$_sf99p_repo" "$ROOT/harness/review-task.sh"
  fi

  # Per-task lifecycle: tear the confinement sandbox down at finish. Unconditional
  # best-effort: forge_sandbox_down is label-scoped to THIS worktree and a no-op when no container
  # exists (so unsandboxed runs are untouched); not FORGE_SANDBOX-gated — env may differ at finish-time.
  forge_sandbox_down "$wt" 2>/dev/null || true
  rm -f "$SENTINEL"
  echo "✓ done — PR opened, bead in review, sentinel cleared. A human reviews and merges; sync closes the bead."
}

cmd_status() {
  if [ -f "$SENTINEL" ]; then
    jq . "$SENTINEL"
    local bead
    bead="$(jq -r '.bead // empty' "$SENTINEL")"
    if [ -n "$bead" ]; then
      echo "--- bead ---"
      forge_bd show "$bead" 2>/dev/null || true
    fi
  else
    echo "no active task"
  fi
  forge_reconcile_best_effort
}

cmd_ready() {
  forge_bd ready --json 2>/dev/null
  forge_reconcile_best_effort
}

cmd_board() {
  local lf rf cf af cutoff
  lf="$(mktemp)"
  rf="$(mktemp)"
  cf="$(mktemp)"
  af="$(mktemp)"
  forge_bd list --json >"$lf" 2>/dev/null
  forge_bd ready --json >"$rf" 2>/dev/null
  # Recently-closed (Done lane): excluded from `list`, so add a bounded closed query. Query shape is
  # config-pinned (BD_CLOSED_LIST_JSON — version-coupled flag); window is BD_CLOSED_WINDOW. Cutoff is
  # absolute (bd --closed-after = YYYY-MM-DD/RFC3339 only; GNU date).
  cutoff="$(date -u -d "-${BD_CLOSED_WINDOW:-30} days" +%F)"
  # shellcheck disable=SC2086  # intentional word-split of the config template; cutoff is a bare date
  forge_bd $(printf "$BD_CLOSED_LIST_JSON" "$cutoff") >"$cf" 2>/dev/null
  jq -s '(.[0] // []) + (.[1] // [])' "$lf" "$cf" >"$af"
  forge_beads_project "$af" "$rf"
  rm -f "$lf" "$rf" "$cf" "$af"
  # board is a PURE read (Agent B's snapshot source) — no reconcile side effects here.
}

cmd_sync() {
  echo "→ reconciling in_review beads against merged PRs"
  forge_reconcile_run blocking
  echo "✓ sync complete"
}

# Out-of-band stale-container reaper trigger. A wedged/abandoned autonomous session cannot
# reap its OWN container; instead the NEXT `start` sweeps the containers leaked by PRIOR sessions
# BEFORE bringing up its own. This lives in the DISPATCHER (never inside cmd_start's body), so it
# touches none of cmd_start's claim/sentinel/bring-up lines. Gated to the UNATTENDED run path:
# an interactive human runs `harness/reaper.sh
# --reap` by hand; only the unattended loop auto-sweeps. Because it fires BEFORE this session writes
# its own sentinel, it reaps containers orphaned by prior (finished/abandoned) sessions; the current
# sentinel's container is ABSOLUTELY guarded by the reaper and is never touched (kill-switch handles a
# still-live wedge). Best-effort + non-fatal: a reaper failure or SKIP (docker absent -> rc 75) NEVER
# blocks the task. Seams (test-only, FORGE_SANDBOX_MANIFEST-style): FORGE_REAPER_BIN pins the reaper
# path; FORGE_REAPER_MAX_AGE adds the wall-clock criterion (--max-age).
forge_reaper_sweep() {
  [ "${FORGE_UNATTENDED:-0}" = "1" ] || return 0
  local reaper="${FORGE_REAPER_BIN:-$ROOT/harness/reaper.sh}"
  [ -x "$reaper" ] || return 0
  local args=(--reap)
  [ -n "${FORGE_REAPER_MAX_AGE:-}" ] && args+=("--max-age=${FORGE_REAPER_MAX_AGE}")
  echo "→ out-of-band reaper sweep (unattended run path)" >&2
  "$reaper" "${args[@]}"
  local rc=$?
  case "$rc" in
    0) : ;;
    75) echo "  reaper: SKIP — docker absent (nothing to reap)" >&2 ;;
    *) echo "  reaper: sweep exited $rc (non-fatal; the task continues)" >&2 ;;
  esac
  return 0
}

case "${1:-}" in
  start)
    shift
    forge_reaper_sweep
    cmd_start "$@"
    ;;
  finish) cmd_finish ;;
  status) cmd_status ;;
  ready) cmd_ready ;;
  board) cmd_board ;;
  sync) cmd_sync ;;
  *) die 'usage: run-task.sh {start <bead-id> | start --new "<desc>" | finish | status | ready | board | sync}' ;;
esac
