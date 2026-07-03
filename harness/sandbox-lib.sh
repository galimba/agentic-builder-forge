#!/usr/bin/env bash
# agentic-builder-forge — the per-task confinement sandbox driver (deployed at harness/sandbox-lib.sh,
# enforce-protected; sourced by run-task.sh like beads-lib.sh). Provider-neutral: drives the
# Dev Container spec (containers.dev / OCI) via the `devcontainer` CLI so the agent CLI stays
# pluggable. Layers A (hardened container) + B (RO mount discipline) + C (egress default-deny) come
# from harness/sandbox/devcontainer.json; this file only resolves paths/image and brings the sandbox
# up/exec/down for one worktree.
#
# Boundary (what crosses the seam vs what stays runner-side):
#   crosses INTO the sandbox: the worktree path, the bead id, the targets (TEST/LINT/FORMAT cmds).
#   stays RUNNER-SIDE (never in the sandbox): ALL bd (claim/export/in_review/close), the PR
#   (gh pr create), reconcile, kill-switch. The sandbox confines the AGENT's edits/tests only.

# F1b: neutralize git's hook-exec axes on EVERY host-side git op against a sandbox worktree.
# The RW .git mount lets an in-container agent plant .git/hooks/* OR a core.hooksPath redirect in
# .git/config (which MUST stay RW for push) — either would run HOST-side at the next git op. Setting
# core.hooksPath=/dev/null on the op closes BOTH axes (a -c flag overrides both the hooks dir AND any
# config redirect), and core.fsmonitor= disables the fsmonitor-program vector. So forge_git ALONE
# closes both axes for every harness host-side git op; the .git/hooks RO mount (F1a) is mount-layer
# defense-in-depth on the dir axis (blocks the plant regardless of forge_git — covering a future host
# op added without it, or a non-harness git invocation), proven LIVE by tests/sandbox A5b. The forge
# relies on NO git hook (audited: 0 non-.sample hooks), so this is cost-free. A5: red before this fix, green after.
forge_git() { git -c core.hooksPath=/dev/null -c core.fsmonitor= "$@"; }

# forge_sandbox_manifest — the devcontainer.json that defines the confinement (enforce-protected).
# FORGE_SANDBOX_MANIFEST overrides it (tests point it at throwaway/differential manifests).
forge_sandbox_manifest() {
  if [ -n "${FORGE_SANDBOX_MANIFEST:-}" ]; then printf '%s' "$FORGE_SANDBOX_MANIFEST"; return 0; fi
  printf '%s/harness/sandbox/devcontainer.json' "${FORGE_MAIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
}

# forge_sandbox_image — the task image. Overridable (FORGE_SANDBOX_IMAGE); default is a standard
# node devcontainer base (git + node + corepack/pnpm). The proof overrides it to a local image.
forge_sandbox_image() {
  printf '%s' "${FORGE_SANDBOX_IMAGE:-mcr.microsoft.com/devcontainers/javascript-node:20}"
}

# Common env every devcontainer invocation needs (paths the manifest expands).
_forge_sandbox_env() {
  : "${FORGE_MAIN_ROOT:?sandbox-lib: FORGE_MAIN_ROOT must be set (the main checkout root)}"
  export FORGE_MAIN_ROOT
  FORGE_SANDBOX_IMAGE="$(forge_sandbox_image)"; export FORGE_SANDBOX_IMAGE
}

# forge_sandbox_up <worktree-abs-path> — bring up the confined sandbox for a worktree. Idempotent
# (devcontainer up reuses an existing container for the same workspace folder).
forge_sandbox_up() {
  local wt="$1"
  [ -n "$wt" ] || { echo "sandbox-lib: forge_sandbox_up needs a worktree path" >&2; return 2; }
  command -v devcontainer >/dev/null 2>&1 || { echo "sandbox-lib: devcontainer CLI not found" >&2; return 3; }
  _forge_sandbox_env
  devcontainer up --config "$(forge_sandbox_manifest)" --workspace-folder "$wt"
}

# forge_sandbox_exec <worktree-abs-path> -- <cmd...> — run a command INSIDE the sandbox as the
# confined remoteUser (uid 1000). This is the channel the automated TDD loop runs through.
forge_sandbox_exec() {
  local wt="$1"; shift
  [ "${1:-}" = "--" ] && shift
  _forge_sandbox_env
  devcontainer exec --config "$(forge_sandbox_manifest)" --workspace-folder "$wt" "$@"
}

# forge_sandbox_down <worktree-abs-path> — stop+remove the per-task container (per-task lifecycle:
# PROBE-4 measured cold start ~215-300ms, so a fresh container per task is the recommendation).
forge_sandbox_down() {
  local wt="$1" cids
  cids="$(docker ps -aq --filter "label=devcontainer.local_folder=$wt" 2>/dev/null)"
  [ -n "$cids" ] || return 0
  # F7b: surface an rm failure instead of swallowing it — a container that will not die keeps a
  # RW .git mount alive (amplifies F1). Best-effort for the caller, but warn + non-zero.
  if ! docker rm -f $cids >/dev/null 2>&1; then
    printf 'sandbox-lib: WARNING — could not remove sandbox container(s) for %s: %s\n' "$wt" "$cids" >&2
    return 1
  fi
  return 0
}

# ---- Item 4: fail-closed-MANDATORY confinement boundary for non-attended self-build ----------
# Reuses the witness discriminator FORGE_UNATTENDED (NO second flag). Attended is a POSITIVE assertion
# (FORGE_UNATTENDED unset AND a TTY) so absence-of-signal => mandatory (fail-closed on ambiguity). Liveness
# = the WHOLE enforce mount set DEMONSTRABLY denies a write (EROFS), not "the container is up".

# forge_provably_attended — rc 0 iff a human is provably at the controls (positive assertion).
forge_provably_attended() {
  [ "${FORGE_UNATTENDED:-0}" != "1" ] && [ -t 0 ]
}

# forge_boundary_live <worktree> — rc 0 IFF a write to EVERY enforce mount (.claude, harness, .git/hooks)
# inside the container is DENIED (EROFS). Probes the whole enforce set, not one .claude sentinel (FOLD #2):
# a degraded manifest that leaves any enforce mount RW must read as NOT live. Disposable sentinel per mount
# (never an existing enforce file) so a degraded RW mount only makes a harmless dotfile (removed + warned).
forge_boundary_live() {
  local wt="$1" pf out sub writable=""
  for sub in .claude harness .git/hooks; do
    pf="${FORGE_MAIN_ROOT}/${sub}/.forge-liveness-$$"
    out="$(forge_sandbox_exec "$wt" bash -lc 'touch "'"$pf"'" 2>&1; echo "RC=$?"' 2>&1)"
    if ! printf '%s' "$out" | grep -qi 'read-only file system'; then
      forge_sandbox_exec "$wt" bash -lc 'rm -f "'"$pf"'" 2>/dev/null' >/dev/null 2>&1 || true
      writable="${writable:+$writable }$sub"
    fi
  done
  [ -z "$writable" ] && return 0
  printf 'sandbox-lib: WARNING — boundary liveness FAILED — enforce mount(s) writable: %s\n' "$writable" >&2
  return 1
}

# forge_require_boundary_or_attended_preclaim — call BEFORE any side effect (no mint/worktree/claim).
forge_require_boundary_or_attended_preclaim() {
  if ! forge_provably_attended; then
    [ "${FORGE_SANDBOX:-0}" = "1" ] || {
      echo "agentic-builder-forge: REFUSING — a non-attended self-build requires the confinement boundary (set FORGE_SANDBOX=1). A boundary you can forget to turn on is not a boundary (Item 4)." >&2
      return 1
    }
  fi
  return 0
}

# forge_require_boundary_or_attended_postup <worktree> — call AFTER forge_sandbox_up (liveness gate).
forge_require_boundary_or_attended_postup() {
  forge_provably_attended && return 0
  forge_boundary_live "$1" || {
    echo "agentic-builder-forge: REFUSING — confinement boundary not in force (an enforce mount did not deny a write). Refusing a non-attended self-build against a degraded boundary (Item 4 liveness)." >&2
    return 1
  }
  return 0
}

# ---- FOLD #5: the ENVIRONMENT-axis force-p0. The pristine-gitdir (FOLD #1-4) closed the config-FILE
# axis; git ALSO injects config + exec via the process ENVIRONMENT (GIT_CONFIG_COUNT/KEY_N/VALUE_N,
# GIT_EXTERNAL_DIFF, GIT_PROXY_COMMAND, GIT_SSH, GIT_PAGER, GIT_ALTERNATE_OBJECT_DIRECTORIES, …). Every helper
# below runs git/tools through forge_safe_env (env -i + pinned system PATH + ONLY the vars the gate sets), so
# NO agent-set env (found or unfound) survives. Curated env per op determined EMPIRICALLY (ssh-auth needs
# PATH+trusted-HOME; gh needs PATH+GITHUB_TOKEN).

forge_safe_env() {   # VAR=val ... -- cmd...
  local kv=(); while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do kv+=("$1"); shift; done; shift
  unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH GCONV_PATH LOCPATH NLSPATH GLIBC_TUNABLES   # DiD: strip loader env before env -i
  env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "${kv[@]}" "$@"
}

# forge_trusted_home — the runner's home from /etc/passwd, NOT $HOME (an agent-controlled finish env could
# poison $HOME -> ssh reads a planted ~/.ssh/config ProxyCommand = exec). Fail-closed to /home/<user>.
forge_trusted_home() {
  local u h; u="$(id -un 2>/dev/null)"; h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
  [ -n "$h" ] && [ -d "$h" ] && { printf '%s' "$h"; return 0; }
  printf '/home/%s' "$u"
}

# forge_safe_gitdir <worktree> -> prints a temp pristine gitdir (FOLD #1: alternates->real objects RO, index
# = COPY of the worktree index, minimal config the gate authors). Internal git reads route through forge_safe_env.
forge_safe_gitdir() {
  local wt="$1" gd cd idx tmp
  gd="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  cd="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cd" in /*) : ;; *) cd="$(cd "$wt" && cd "$cd" && pwd)" ;; esac
  idx="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/forge-safegd.XXXXXX")" || return 1
  mkdir -p "$tmp/objects/info" "$tmp/refs"
  printf '%s\n' "$cd/objects" > "$tmp/objects/info/alternates"
  [ -f "$idx" ] && cp "$idx" "$tmp/index" 2>/dev/null
  cp "$gd/HEAD" "$tmp/HEAD" 2>/dev/null || printf 'ref: refs/heads/_safe\n' > "$tmp/HEAD"
  [ -f "$cd/packed-refs" ] && cp "$cd/packed-refs" "$tmp/packed-refs" 2>/dev/null
  cp -a "$cd/refs/." "$tmp/refs/" 2>/dev/null
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n' > "$tmp/config"
  printf '%s' "$tmp"
}

# forge_safe_git <worktree> <safe-gitdir> [--] <git args...> -> host git READ op (pristine config + sanitized env).
# FOLD #1 live-index fix: read against the LIVE worktree index (GIT_INDEX_FILE), NOT the pristine GD's
# FROZEN index copy. FOLD #1 conflated "don't exec agent config" (keep) with "freeze the index" (the unintended
# side-effect): the frozen copy made the accept-gate's A1 TOCTOU integrity check vacuous (PREH==POSTH always, so
# a dod_test staging out-of-scope mid-gate after C1 committed invisibly) AND decoupled verify from commit (the
# gate verdicted the frozen index while write-tree/commit use the LIVE one). Reading the live index restores
# both: the gate VERIFIES the same staged index it COMMITS, and PREH/POSTH detect a mid-gate mutation. The index
# is DATA (reading it execs nothing); pristine config (--git-dir=GD + GIT_CONFIG masks) keeps the no-agent-config-exec property.
forge_safe_git() {
  local wt="$1" gd="$2" idx; shift 2; [ "${1:-}" = "--" ] && shift
  idx="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
  forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null ${idx:+GIT_INDEX_FILE="$idx"} -- git --git-dir="$gd" --work-tree="$wt" "$@"
}

# forge_safe_git_stage <worktree> <safe-gitdir> [--] <git args...> -> WRITE op persisting to the REAL index +
# objects, pristine config, sanitized env (no agent filter/fsmonitor via file OR env).
forge_safe_git_stage() {
  local wt="$1" gd="$2" cd idx; shift 2; [ "${1:-}" = "--" ] && shift
  cd="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cd" in /*) : ;; *) cd="$(cd "$wt" && cd "$cd" && pwd)" ;; esac
  idx="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
  forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_OBJECT_DIRECTORY="$cd/objects" GIT_INDEX_FILE="$idx" -- git --git-dir="$gd" --work-tree="$wt" "$@"
}

# forge_safe_git_commit <worktree> <safe-gitdir> <message> -> PLUMBING commit (write-tree -> commit-tree ->
# update-ref), pristine config + sanitized env (no gpg/hooks/fsmonitor via file OR env). Prints the new SHA.
forge_safe_git_commit() {
  local wt="$1" gd="$2" msg="$3" cd idx an ae tree parent pflag commit realgd
  cd="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cd" in /*) : ;; *) cd="$(cd "$wt" && cd "$cd" && pwd)" ;; esac
  idx="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
  realgd="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  # FOLD #6: DETERMINISTIC forge-bot identity — read NO config. env -i strips global config and the live
  # checkout carries identity only in global => a config read returns empty => commit-tree aborts (every finish
  # dies). An automated commit's author should say "the harness made this", not the ambient runner identity;
  # this is always non-empty by construction and never agent-influenced. (Claude's Co-Authored-By trailer is in $msg.)
  an="agentic-builder-forge harness"; ae="forge-harness@localhost"
  tree="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_OBJECT_DIRECTORY="$cd/objects" GIT_INDEX_FILE="$idx" -- git --git-dir="$gd" write-tree)" || return 1
  parent="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git --git-dir="$gd" rev-parse -q --verify HEAD 2>/dev/null)"
  pflag=""; [ -n "$parent" ] && pflag="-p $parent"
  commit="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_OBJECT_DIRECTORY="$cd/objects" \
            GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_COMMITTER_NAME="$an" GIT_COMMITTER_EMAIL="$ae" \
            -- git --git-dir="$gd" commit-tree "$tree" $pflag -m "$msg")" || return 1
  [ -n "$commit" ] || return 1
  forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git --git-dir="$realgd" -c core.hooksPath=/dev/null -c core.fsmonitor= update-ref HEAD "$commit" || return 1
  printf '%s' "$commit"
}

# forge_validate_push_url <url> -> rc0 iff an expected GitHub origin (https/ssh); rejects whitespace/control
# + ext::/fd::/file/local/non-github (capture-time guard).
forge_validate_push_url() {
  local url="$1"
  case "$url" in *[![:graph:]]*) return 1 ;; esac
  case "$url" in
    https://github.com/*) return 0 ;;
    ssh://git@github.com/*) return 0 ;;
    git@github.com:*) return 0 ;;
    *) return 1 ;;
  esac
}

# forge_capture_push_url <repo> -> print the resolved, VALIDATED remote.origin.url (start sentinel, pre-agent);
# rc2 on a poisoned/non-github origin.
forge_capture_push_url() {
  local repo="$1" url
  url="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$repo" config --get remote.origin.url 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  forge_validate_push_url "$url" || return 2
  printf '%s' "$url"
}

# forge_safe_git_push <worktree> <safe-gitdir> <literal-url> <branch> <commit-sha> -> push the SHA to the
# LITERAL url, pristine config + SANITIZED env (env -i strips agent GIT_*; trusted HOME for ssh key/known_hosts;
# forced GIT_SSH_COMMAND; credential.helper= disabled). Objects reach via the gitdir alternates.
forge_safe_git_push() {
  local wt="$1" gd="$2" url="$3" branch="$4" sha="$5" cd
  forge_validate_push_url "$url" || { echo "forge_safe_git_push: REFUSING — push URL failed the scheme/host allowlist: $url" >&2; return 3; }
  cd="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cd" in /*) : ;; *) cd="$(cd "$wt" && cd "$cd" && pwd)" ;; esac
  forge_safe_env HOME="$(forge_trusted_home)" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_SSH_COMMAND="ssh -o BatchMode=yes" GIT_TERMINAL_PROMPT=0 GIT_OBJECT_DIRECTORY="$cd/objects" \
    -- git --git-dir="$gd" --work-tree="$wt" -c credential.helper= push "$url" "$sha:refs/heads/$branch"
}

# forge_repo_from_url <github-url> -> "owner/repo" (FOLD #4), derived from the CAPTURED/validated URL, FAIL
# CLOSED on any non-(owner/repo)/non-github/whitespace/leading-dash form (no gh config-resolution fallback).
forge_repo_from_url() {
  local s="$1"
  case "$s" in *[![:graph:]]*) return 1 ;; esac
  s="${s#git@github.com:}"; s="${s#https://github.com/}"; s="${s#ssh://git@github.com/}"; s="${s%.git}"
  case "$s" in
    -*|*/-*) return 1 ;;
    */*/* | /* | */) return 1 ;;
    [A-Za-z0-9._-]*/[A-Za-z0-9._-]*) printf '%s' "$s"; return 0 ;;
    *) return 1 ;;
  esac
}

# ── H3: target-build PR purity (finish-time strip + PROOF) ─────────────────────────────────────────────
# Runner-side ONLY — lib.sh is NOT modified (widening the SHARED classifier would change self-build deny
# behavior, a regression near the Form-2 boundary). Reuses the read-only forge_norm_path/forge_enforce_class
# (lib.sh, sourced by run-task BEFORE this file). A target PR must carry ZERO forge/.claude artifacts (model (c)).

# forge_is_forge_path <path> -> rc0 (IMPURE) iff the normalized first segment is a forge dir
# (.claude/.beads/harness/.harness/.git) OR forge_enforce_class(path) in {git,beads,enforce}. The first-segment
# arm is the D2 SUPERSET: forge_enforce_class treats a bare .claude/agents/x as 'ok', but model (c) forbids ANY
# agent-authored .claude/* in a target PR; the enforce_class arm adds the nested forms (a/.harness/x -> enforce).
forge_is_forge_path() {
  local p seg
  p="$(forge_norm_path "${1#./}")"
  seg="${p%%/*}"
  case "$seg" in
    .claude | .beads | harness | .harness | .git) return 0 ;;
  esac
  # FIX-A (F-A): model (c) forbids ANY agent-authored .claude/* — catch NESTED .claude
  # (apps/web/.claude/agents/x, the website-E2E case). forge_enforce_class only matches nested .claude/hooks +
  # .claude/settings*; bare nested .claude/{agents,commands,skills} slips the first-segment check. Mirrors
  # lib.sh's */.git, */.beads, */.harness nested arms. EXACT .claude segment only — src/claudefile.txt /
  # myclaude/x / foo/bar.claude stay PURE.
  case "/$p" in */.claude | */.claude/*) return 0 ;; esac
  case "$(forge_enforce_class "$p" 2>/dev/null)" in
    git | beads | enforce) return 0 ;;
  esac
  return 1
}

# forge_strip_forge_artifacts <worktree> <safe-gitdir> -> CONVENIENCE strip: index-only unstage of every
# forge-classifiable staged path (the proven .beads unstage idiom — restore --staged leaves the worktree file for
# diagnosis, no delete-floor interaction). rc1 on any git error so the caller fail-closes. The GUARANTEE is
# forge_assert_target_pure, NOT this.
forge_strip_forge_artifacts() {
  # FIX-B (F-B): enumerate with -z (NUL-delimited). Default --name-only QUOTES paths with
  # newlines/tabs/non-ASCII (core.quotePath) -> the leading " defeats the classifier and the artifact survives.
  # -z emits raw, unquoted paths. (Strip is convenience; forge_assert_target_pure is the guarantee.)
  local wt="$1" gd="$2" p rc=0
  local -a staged=()
  mapfile -d '' staged < <(forge_safe_git "$wt" "$gd" diff --cached --name-only -z)
  for p in "${staged[@]}"; do
    [ -n "$p" ] || continue
    if forge_is_forge_path "$p"; then
      forge_safe_git_stage "$wt" "$gd" restore --staged -- "$p" || rc=1
    fi
  done
  return "$rc"
}

# forge_assert_target_pure <worktree> <safe-gitdir> -> the H3 GUARANTEE. rc0 iff the staged index carries ZERO
# forge-classifiable paths. rc1 (reason on stderr) if any remaining path is forge-classifiable, the enumeration
# errors, or a path bears '..'. The caller (cmd_finish) dies on rc1 -> no commit, no PR.
forge_assert_target_pure() {
  # FIX-B (F-B): -z NUL-delimited enumeration; the git rc is preserved via a temp file ($()
  # strips NULs, so the rc must be captured off the redirect) -> the caller still fail-closes on an
  # enumeration error. Raw paths -> the classifier sees no leading-quote artifact.
  local wt="$1" gd="$2" p rc tmp
  local -a staged=()
  tmp="$(mktemp)" || return 1
  forge_safe_git "$wt" "$gd" diff --cached --name-only -z > "$tmp"; rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    echo "H3: could not enumerate the staged index for the target purity check — refusing (fail closed)" >&2
    return 1
  fi
  mapfile -d '' staged < "$tmp"; rm -f "$tmp"
  for p in "${staged[@]}"; do
    [ -n "$p" ] || continue
    case "$p" in *..*)
      echo "H3: staged path '$p' contains '..' — refusing (fail closed)" >&2
      return 1
      ;;
    esac
    if forge_is_forge_path "$p"; then
      echo "finish: target PR purity check FAILED — staged index still carries forge artifact $p; refusing to publish a polluted product PR (H3, fail closed)" >&2
      return 1
    fi
  done
  return 0
}

# ── cp-assembly: the harness-side topo merge onto feat/F (abort-on-conflict, NEVER force) ────────────────
# forge_safe_git_merge <repo> <feat_branch> <task_sha> -> merge the task tip onto feat/F in a DEDICATED,
# throwaway worktree (NOT the agent worktree), with the sanitized env + pristine config + deterministic
# forge-bot identity discipline (mirrors forge_safe_git_commit/push; no agent hooks/gpg/fsmonitor fire).
# The ONLY merge flags are `--no-ff --no-edit` — NEVER -X/-s/--strategy/--force/--strategy-option: a green
# merge must be a true 3-way merge, and a real conflict HALTS (it is never papered over by picking a side).
#   success  -> advances refs/heads/<feat_branch>; prints "<feat_before_sha>\t<merge_commit>"; rc 0
#   conflict -> `git merge --abort` (feat/F left at its pre-merge tip), conflicted paths to stderr; rc 1
#   other    -> rc 2 (e.g. feat/F unresolvable, worktree-add failed)
# GIT_TRACE (a read-only diagnostic) is passed through WHEN ALREADY SET so a test canary can observe that
# the merge argv carries no force/strategy flag; it is never synthesized here (unset in production -> absent).
forge_safe_git_merge() {
  local repo="$1" feat="$2" task_sha="$3" before mwt rc merged unmerged
  before="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$repo" rev-parse "refs/heads/$feat" 2>/dev/null)" || return 2
  [ -n "$before" ] || return 2
  mwt="$(mktemp -d "${TMPDIR:-/tmp}/forge-merge.XXXXXX")" || return 2
  if ! forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$repo" worktree add --quiet "$mwt" "$feat" >/dev/null 2>&1; then
    rmdir "$mwt" 2>/dev/null
    return 2
  fi
  forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME="agentic-builder-forge harness" GIT_AUTHOR_EMAIL="forge-harness@localhost" \
    GIT_COMMITTER_NAME="agentic-builder-forge harness" GIT_COMMITTER_EMAIL="forge-harness@localhost" \
    ${GIT_TRACE:+GIT_TRACE="$GIT_TRACE"} \
    -- git -C "$mwt" -c core.hooksPath=/dev/null -c core.fsmonitor= merge --no-ff --no-edit "$task_sha" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    unmerged="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$mwt" diff --name-only --diff-filter=U 2>/dev/null)"
    forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$mwt" merge --abort >/dev/null 2>&1
    forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$repo" worktree remove --force "$mwt" >/dev/null 2>&1
    forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$repo" worktree prune >/dev/null 2>&1
    if [ -n "$unmerged" ]; then printf '%s\n' "$unmerged" >&2; return 1; fi
    return 2
  fi
  merged="$(forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$mwt" rev-parse HEAD 2>/dev/null)"
  forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$repo" worktree remove --force "$mwt" >/dev/null 2>&1
  forge_safe_env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null -- git -C "$repo" worktree prune >/dev/null 2>&1
  [ -n "$merged" ] || return 2
  printf '%s\t%s' "$before" "$merged"
  return 0
}
