#!/usr/bin/env bash
# The commit-to-main guard, ALL tiers. main/master advances ONLY by PR-merge; a DIRECT
# authored commit on main is the failure this closes (it happened, twice). Three install-axes, all here:
#   1. DENY-HOOK TIER     forge_check_commit in pre-tool-use-deny.sh — the agent's tool-path commit,
#                         refused early + named, install-free (this is what guards H2's imminent commit).
#   2. GIT pre-commit     harness/githooks/pre-commit — the ALL-ACTORS backstop (agent AND human), fires
#                         at git-exec time regardless of vector. Installed via core.hooksPath.
#   3. WITNESS install    session-start-witness.sh refuses to witness when the resolved hooks dir is not
#                         harness/githooks (forge_hookspath_ok) -> privileged ops fail-closed on absence,
#                         making the git-hook install mechanically guaranteed (not honor-based).
#
# SEAMS (pre-splice candidate verification). Default = DEPLOYED, so this suite is RED until the splice
# lands and GREEN after — the test-first shape. Point each at /tmp/forge-guard-cand to prove the candidate.
#   FORGE_GUARD_DENY          deny hook under test            (default .claude/hooks/pre-tool-use-deny.sh)
#   FORGE_GUARD_GITHOOK       git pre-commit hook under test  (default harness/githooks/pre-commit)
#   FORGE_GUARD_LIB           lib.sh providing forge_hookspath_ok (default .claude/hooks/lib.sh)
#   FORGE_GUARD_WITNESS_HOOK  SessionStart hook under test    (default .claude/hooks/session-start-witness.sh)
#
# The deny-hook tier for the deny-tier cases lives in tests/commitguard (NOT tests/hooks) so the new suite
# is conflict-free with the in-flight H2 work (which also edits tests/hooks). All work in throwaway repos;
# the real repo is never touched.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DENY="${FORGE_GUARD_DENY:-$ROOT/.claude/hooks/pre-tool-use-deny.sh}"
GHOOK="${FORGE_GUARD_GITHOOK:-$ROOT/harness/githooks/pre-commit}"
GLIB="${FORGE_GUARD_LIB:-$ROOT/.claude/hooks/lib.sh}"
GWITNESS="${FORGE_GUARD_WITNESS_HOOK:-$ROOT/.claude/hooks/session-start-witness.sh}"

command -v jq >/dev/null 2>&1 || { echo "commitguard: jq required" >&2; exit 1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS [%s]\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
TMPS=()
trap '[ "${#TMPS[@]}" -gt 0 ] && rm -rf "${TMPS[@]}"' EXIT
mktmp() { local t; t="$(mktemp -d)"; TMPS+=("$t"); printf '%s' "$t"; }

# forge_hookspath_ok (and friends) from the lib under test. The function may be ABSENT pre-splice — that
# is the RED signal; calls then fail (command not found) and the && ok || no records the failure.
# shellcheck source=/dev/null
. "$GLIB" 2>/dev/null || true

# ── 1. DENY-HOOK TIER — git commit on main denied; task branch allowed; argv-aware; escape ───────────
echo "== commit guard: deny-hook tier — direct git commit on main denied, task branch allowed =="
mkrepo() { local b="$1" r; r="$(mktmp)"; git -C "$r" init -q -b "$b" >/dev/null 2>&1; git -C "$r" config user.email t@t; git -C "$r" config user.name t; echo s >"$r/f"; git -C "$r" add f; git -C "$r" commit -qm s >/dev/null 2>&1; printf '%s' "$r"; }
RMAIN="$(mkrepo main)"; RTASK="$(mkrepo task/x)"
RDET="$(mkrepo main)"; git -C "$RDET" checkout -q --detach >/dev/null 2>&1
deny_verdict() { # <repo> <command> [env...] -> ALLOW|DENY (DENY = blocked by any mechanism)
  local repo="$1" cmd="$2"; shift 2
  local json out
  json="$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  out="$(printf '%s' "$json" | env "$@" CLAUDE_PROJECT_DIR="$repo" bash "$DENY" 2>&1)"
  if printf '%s' "$out" | grep -q '"deny"'; then printf DENY; else printf ALLOW; fi
}
chkd() { [ "$2" = "$3" ] && ok "$1 ($3)" || no "$1" "expected=$2 got=$3"; }
chkd "git commit on main -> DENY"                 DENY  "$(deny_verdict "$RMAIN" 'git commit -m x')"
chkd "git commit on task branch -> ALLOW"         ALLOW "$(deny_verdict "$RTASK" 'git commit -m x')"
chkd "git add -A && git commit on main -> DENY"   DENY  "$(deny_verdict "$RMAIN" 'git add -A && git commit -m x')"
chkd "git commit --amend on main -> DENY"         DENY  "$(deny_verdict "$RMAIN" 'git commit --amend --no-edit')"
chkd "git -c k=v commit on main -> DENY (flag before subcmd)" DENY "$(deny_verdict "$RMAIN" 'git -c user.name=z commit -m x')"
chkd "git -C . commit on main -> DENY (-C before subcmd)"     DENY "$(deny_verdict "$RMAIN" 'git -C . commit -m x')"
chkd "git log on main -> ALLOW (not a commit)"    ALLOW "$(deny_verdict "$RMAIN" 'git log --oneline')"
chkd "git commit-graph write on main -> ALLOW (not 'commit' subcmd)" ALLOW "$(deny_verdict "$RMAIN" 'git commit-graph write')"
chkd "echo committing | bash on main -> ALLOW (FP guard: common word)" ALLOW "$(deny_verdict "$RMAIN" 'echo committing | bash')"
chkd "git commit -m 'fix commit logic' on task -> ALLOW" ALLOW "$(deny_verdict "$RTASK" 'git commit -m "fix the commit logic"')"
chkd "commit on DETACHED HEAD -> DENY (fail-closed)" DENY "$(deny_verdict "$RDET" 'git commit -m x')"
chkd "commit on main + FORGE_ALLOW_MAIN_MERGE=1 -> ALLOW (escape)" ALLOW "$(deny_verdict "$RMAIN" 'git commit -m x' FORGE_ALLOW_MAIN_MERGE=1)"

# ── 2. GIT pre-commit hook — all-actors backstop ─────────────────────────────────────────────────────
echo "== commit guard: git pre-commit hook — refuse on main/master, allow task branch, logged escape =="
gh_repo() { local b="$1" r; r="$(mktmp)"; git -C "$r" init -q -b "$b" >/dev/null 2>&1; git -C "$r" config user.email t@t; git -C "$r" config user.name t; mkdir -p "$r/harness/githooks"; cat "$GHOOK" >"$r/harness/githooks/pre-commit" 2>/dev/null; chmod +x "$r/harness/githooks/pre-commit" 2>/dev/null; git -C "$r" config core.hooksPath harness/githooks; printf '%s' "$r"; }
gh_commit() { local r="$1"; shift; echo x >>"$r/f"; git -C "$r" add f harness >/dev/null 2>&1; ( cd "$r" && env "$@" git commit -m c >/dev/null 2>&1 ); }
R="$(gh_repo main)";  gh_commit "$R"; [ $? -ne 0 ] && ok "git-hook REFUSES commit on main" || no "git-hook should refuse on main"
R="$(gh_repo master)"; gh_commit "$R"; [ $? -ne 0 ] && ok "git-hook REFUSES commit on master" || no "git-hook should refuse on master"
R="$(gh_repo task/y)"; gh_commit "$R"; [ $? -eq 0 ] && ok "git-hook ALLOWS commit on a task branch (no over-block)" || no "git-hook should allow on a task branch"
R="$(gh_repo main)"; gh_commit "$R" FORGE_ALLOW_MAIN_MERGE=1; rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$R/.harness/main-commit-escape.log" ]; } && ok "git-hook escape (FORGE_ALLOW_MAIN_MERGE=1) ALLOWS + LOGS (ISO-42001)" || no "escape should allow+log" "rc=$rc log=$([ -f "$R/.harness/main-commit-escape.log" ] && echo yes || echo no)"
R="$(gh_repo main)"; git -C "$R" checkout -q --detach >/dev/null 2>&1; gh_commit "$R"; [ $? -ne 0 ] && ok "git-hook REFUSES on detached HEAD (fail-closed)" || no "git-hook should fail-closed on detached"

# ── 3. forge_hookspath_ok — realpath-canonical, fail-closed ──────────────────────────────────────────
echo "== commit guard: forge_hookspath_ok — realpath-canonical (not string), fail-closed =="
hp_repo() { local r; r="$(mktmp)"; git -C "$r" init -q -b main >/dev/null 2>&1; mkdir -p "$r/harness/githooks"; printf '#!/bin/sh\nexit 0\n' >"$r/harness/githooks/pre-commit"; chmod +x "$r/harness/githooks/pre-commit" 2>/dev/null; printf '%s' "$r"; }
R="$(hp_repo)"; git -C "$R" config core.hooksPath harness/githooks; forge_hookspath_ok "$R" 2>/dev/null && ok "hookspath_ok: relative harness/githooks -> OK" || no "relative harness/githooks should pass"
R="$(hp_repo)"; git -C "$R" config core.hooksPath "$R/harness/githooks"; forge_hookspath_ok "$R" 2>/dev/null && ok "hookspath_ok: ABSOLUTE-but-correct -> OK (canonical, not raw string)" || no "absolute-correct should pass"
R="$(hp_repo)"; forge_hookspath_ok "$R" 2>/dev/null && no "unset hooksPath should FAIL" || ok "hookspath_ok: unset -> fail-closed"
R="$(hp_repo)"; mkdir -p "$R/other/githooks"; git -C "$R" config core.hooksPath other/githooks; forge_hookspath_ok "$R" 2>/dev/null && no "suffix-matching-but-wrong should FAIL" || ok "hookspath_ok: other/githooks (wrong, same basename) -> fail-closed"
R="$(mktmp)"; forge_hookspath_ok "$R" 2>/dev/null && no "non-git root should FAIL" || ok "hookspath_ok: non-git root -> fail-closed"

# ── 4. SessionStart witness — refuse-to-witness when the git-hook is not installed ───────────────────
echo "== commit guard: SessionStart witness refuses to write when hooks path != harness/githooks =="
wt_tree() { local r; r="$(mktmp)"; mkdir -p "$r/.claude/hooks" "$r/.harness" "$r/harness/githooks"; cp "$ROOT/.claude/hooks/pre-tool-use-deny.sh" "$r/.claude/hooks/"; cp "$GLIB" "$r/.claude/hooks/lib.sh"; cp "$GWITNESS" "$r/.claude/hooks/session-start-witness.sh"; cp "$ROOT/.claude/settings.json" "$r/.claude/settings.json"; printf '#!/bin/sh\nexit 0\n' >"$r/harness/githooks/pre-commit"; chmod +x "$r/harness/githooks/pre-commit" 2>/dev/null; git -C "$r" init -q -b main >/dev/null 2>&1; printf '%s' "$r"; }
run_witness() { local tree="$1" sid="$2"; shift 2; jq -nc --arg sid "$sid" --arg cwd "$tree" '{session_id:$sid,source:"startup",cwd:$cwd}' | env "$@" CLAUDE_PROJECT_DIR="$tree" FORGE_HARNESS_DIR="$tree/.harness" bash "$GWITNESS" 2>"$tree/.err"; }
T="$(wt_tree)"; git -C "$T" config core.hooksPath harness/githooks; run_witness "$T" sid-ok
[ -f "$T/.harness/session-floor.sid-ok.json" ] && ok "witness WRITTEN when hooks path installed (happy path holds)" || no "witness should write when installed" "$(cat "$T/.err" 2>/dev/null)"
T="$(wt_tree)"; run_witness "$T" sid-bad; rc=$?
{ [ "$rc" -eq 0 ] && [ ! -f "$T/.harness/session-floor.sid-bad.json" ] && grep -qF witness-not-written-hookspath-uninstalled "$T/.err"; } && ok "witness REFUSED (exit 0, NO file, named) when hooks path uninstalled" || no "should refuse-to-witness on uninstalled hooks path" "rc=$rc $(cat "$T/.err" 2>/dev/null)"

echo "==== commitguard: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
