#!/usr/bin/env bash
# agentic-builder-forge — kill-switch + Beads release.
#
# Terminates the active task cleanly AND releases its claimed bead back to ready:
#   - release the claimed bead (in_progress/in_review -> open, unassigned) so it re-enters `bd ready`
#   - SIGTERM the recorded task process if one is alive (headless mode; interactive records none)
#   - remove the task worktree (--force discards its uncommitted changes)
#   - delete the LOCAL task/* branch (refuses anything not under task/*)
#   - clear the sentinel
# Never touches main/base. One documented command: ./harness/kill-switch.sh
# Deployed enforcement-protected file: agent edits are floor-denied; changes are authored as sandbox/ candidates and human-spliced under FORGE_ALLOW_HOOK_EDIT=1 (audit-logged).
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
. "$HERE/beads-lib.sh"
# shellcheck source=sandbox-lib.sh
. "$HERE/sandbox-lib.sh" # forge_sandbox_down — per-task container teardown

ROOT="$(forge_main_root)" || {
  echo "kill-switch: not inside a git repo" >&2
  exit 1
}
forge_beads_load "$ROOT"
SENTINEL="$ROOT/.harness/active-task.json"
[ -f "$SENTINEL" ] || {
  echo "kill-switch: no active task — nothing to do"
  exit 0
}

branch="$(jq -r .branch "$SENTINEL")"
wt="$(jq -r .worktree "$SENTINEL")"
pid="$(jq -r '.pid // empty' "$SENTINEL")"
bead="$(jq -r '.bead // empty' "$SENTINEL")"
# cp-workroot (H1): a TARGET build's worktree lives in the TARGET repo's git, not the forge's — so
# worktree remove/prune/branch-delete must run against the TARGET. target_path is empty for a SELF build
# (repo stays $ROOT, byte-identical). The bead release below stays FORGE-SIDE (forge_bd) regardless.
target_path="$(jq -r '.target_path // empty' "$SENTINEL")"
repo="${target_path:-$ROOT}"
case "$branch" in
  task/*) : ;;
  *)
    echo "kill-switch: refusing — '$branch' is not a task/* branch" >&2
    exit 1
    ;;
esac

echo "→ aborting task on $branch (worktree: $wt)"

# Release the claimed bead BACK to ready before teardown so the work is reclaimable. forge_beads_release_args
# documents the canonical shape; we invoke it explicitly here so the empty assignee is passed correctly.
# Fail-soft: a release hiccup must not block the abort.
if [ -n "$bead" ]; then
  if forge_bd update "$bead" --status open --assignee "" >/dev/null 2>&1; then
    echo "→ released bead $bead → open (re-enters bd ready)"
  else
    echo "  WARNING: could not release bead $bead — release manually: bd update $bead --status open --assignee \"\"" >&2
  fi
fi

if [ -n "$pid" ] && [ "$pid" != "null" ] && kill -0 "$pid" 2>/dev/null; then
  echo "→ SIGTERM $pid"
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
fi
# Tear the confinement sandbox down BEFORE removing its worktree (the container label
# keys on the worktree path). Unconditional best-effort — see run-task.sh finish for the rationale.
forge_sandbox_down "$wt" 2>/dev/null || true
[ -d "$wt" ] && forge_git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
forge_git -C "$repo" worktree prune 2>/dev/null || true
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
fi
rm -f "$SENTINEL"
# FOLD #15: invalidate the merge-oracle record on release so a re-claimed bead (same id -> same
# branch) cannot inherit a PRIOR claim's merged-PR record and be auto-closed by reconcile without its own
# finish. kill-switch is harness-side (enforce-protected); the agent cannot run this cleanup itself.
[ -n "$bead" ] && rm -f "$ROOT/.harness/pr/$bead.json" 2>/dev/null || true

echo "✓ task aborted — bead released, worktree removed, branch $branch deleted, sentinel cleared."
echo "  Shared branches untouched. Current worktrees:"
forge_git -C "$repo" worktree list
