#!/usr/bin/env bash
# Unit tests for the agentic-builder-forge hooks. Pipes fixture JSON to each hook and asserts
# allow vs block/deny — runs the scripts DIRECTLY (no Claude, no registration needed), so the
# enforcement logic is proven correct BEFORE the hooks ever go live.
#
# Run: bash tests/hooks/run.sh   (or: pnpm test:hooks)
set -u
# Hermetic: only the explicit `FORGE_ALLOW_HOOK_EDIT=1` assertion below may exercise the logged-bypass
# branch. Clear any ambient value so an open maintenance door in the session cannot turn the
# enforcement-edit DENY cases into bypass ALLOWs (which would silently mask a real regression).
unset FORGE_ALLOW_HOOK_EDIT
# Same class: an unattended/CI environment exports FORGE_UNATTENDED=1 (and may tune the
# cap) — the Stop-gate mode matrix below sets each mode EXPLICITLY per case, so ambient values must
# not leak into the attended-legacy fixtures.
unset FORGE_UNATTENDED FORGE_STOP_BLOCK_CAP
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# FORGE_DENY_HOOK overrides the deny hook under test (pre-splice candidate verification); default = deployed.
DENY="${FORGE_DENY_HOOK:-$ROOT/.claude/hooks/pre-tool-use-deny.sh}"
POST="$ROOT/.claude/hooks/post-tool-use-format.sh"
STOP="$ROOT/.claude/hooks/stop-gate-tests.sh"
# Intake hooks (FORGE_*_HOOK override = pre-splice candidate under sandbox/; default = deployed).
STOP_INTAKE="${FORGE_STOP_INTAKE_HOOK:-$ROOT/.claude/hooks/stop-gate-intake.sh}"
CLARIFY_GATE="${FORGE_CLARIFY_GATE_HOOK:-$ROOT/.claude/hooks/pre-tool-use-clarify-gate.sh}"
DENY_SHIM="${FORGE_DENY_SHIM:-$DENY}" # deny hook carrying the ratify rule (shim pre-splice; the real deny hook once spliced)
# The fail-closed Stop gate + root-anchored lib under test. FORGE_STOP_HOOK is the
# override seam (the FORGE_*_HOOK pattern); default = the DEPLOYED artifact (the fail-closed flip has
# landed; the candidate fallback was retired — deployed is canonical).
STOP_FC="${FORGE_STOP_HOOK:-$ROOT/.claude/hooks/stop-gate-tests.sh}"
LIB_FC="$ROOT/.claude/hooks/lib.sh"
# Sentinel ISOLATION: the suite's task sentinels live in THROWAWAY harness dirs,
# NEVER the real .harness. Under Ruling A the Stop gate runs this suite while a REAL task is armed —
# the old real-path SENTINEL (with_task writes + the EXIT-trap delete) clobbered the live claim and
# reset the real stop-blocks counter (a PROVEN DEFECT of the pre-isolation suite). NOTASK_HD is the hermetic
# "no task armed" default every helper pins (caller env still overrides — env last-wins), so an armed
# real session cannot flip the no-task fixtures either. The real-sentinel integrity guard at the end
# of this file pins the isolation permanently.
THD="$(mktemp -d)"
NOTASK_HD="$(mktemp -d)"
STOPFIX_TMP="$(mktemp -d)" # per-case Stop-gate fixture repos + harness dirs (see the Stop section)
SENTINEL="$THD/active-task.json"
# Fresh checkout: .harness/ holds no tracked files, so on a clean clone the directory would not
# exist. Suite fixtures no longer live there (THD/NOTASK_HD above), but the deployed hooks resolve
# it on their no-override path — keep it present so suite behavior matches a worked-in checkout.
mkdir -p "$ROOT/.harness"
# Real-sentinel integrity guard: snapshot the REAL .harness task state now; the suite
# must leave it byte-identical (checked before the summary).
REAL_SENTINEL="$ROOT/.harness/active-task.json"
real_task_state() { { cat "$REAL_SENTINEL" 2>/dev/null || printf ABSENT; cat "$ROOT/.harness/stop-blocks" 2>/dev/null || printf ABSENT; } | sha256sum | cut -d' ' -f1; }
REAL_TASK_BEFORE="$(real_task_state)"
PASS=0
FAIL=0
ERRFILE="$(mktemp)"
# #10: a throwaway git repo so the bypass-LOGGING test cases write to ITS .harness, never the real
# audit log — forge_log_bypass derives the log path from the git root of the cwd.
BYPASSREPO="$(mktemp -d)"
git -C "$BYPASSREPO" init -q 2>/dev/null
INTAKE_TMP="$(mktemp -d)" # per-run scratch for intake-hook fixtures (active-intake.json + spec.md)
# Hermetic task-branch repo for the two push-allow fixtures. The branch-state guard
# (lib.sh forge_check_push_seg) reads CLAUDE_PROJECT_DIR, so pinning it here makes the push-allow path
# deterministic on ANY host branch — the "2 red on main" footgun closes. Same recipe as _mkrepo below
# (git init -b, >=2.28; symbolic-ref fallback for older git). NO commit is needed — symbolic-ref
# resolves an unborn branch — so there is no user.email/name portability edge. Torn down by the trap
# below; the teardown touches ONLY this mktemp dir, never the host repo's branches/HEAD.
HPUSH="$(mktemp -d)"
git -C "$HPUSH" init -q -b task/hermetic-push 2>/dev/null || { git -C "$HPUSH" init -q; git -C "$HPUSH" symbolic-ref HEAD refs/heads/task/hermetic-push; }
# Teardown touches ONLY this run's mktemp dirs — never the real .harness.
trap 'rm -f "$ERRFILE" 2>/dev/null; rm -rf "$THD" "$NOTASK_HD" "$BYPASSREPO" "$INTAKE_TMP" "$HPUSH" "$STOPFIX_TMP" 2>/dev/null' EXIT

# assert <desc> <allow|deny> <json> [env KEY=VAL ...]   (deny == blocked, by any mechanism)
assert() {
  local desc="$1" expect="$2" json="$3"
  shift 3
  local out rc got
  # FORGE_HARNESS_DIR default = the empty no-task fixture (hermetic vs a REAL armed task); the
  # caller's "$@" comes later, so an explicit FORGE_HARNESS_DIR wins (env last-wins).
  out="$(printf '%s' "$json" | env FORGE_HARNESS_DIR="$NOTASK_HD" "$@" CLAUDE_PROJECT_DIR="$ROOT" bash "${TARGET_HOOK:-$DENY}" 2>"$ERRFILE")"
  rc=$?
  got="allow"
  if [ "$rc" = "2" ] || printf '%s' "$out" | grep -Eq '"permissionDecision":"deny"|"decision":"block"'; then got="deny"; fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s]\n  expected=%s got=%s rc=%s\n  json=%s\n  stderr=%s\n  stdout=%s\n' \
      "$desc" "$expect" "$got" "$rc" "$json" "$(cat "$ERRFILE")" "$out"
  fi
}
with_task() { printf '{"task":"t","branch":"task/x"}' >"$SENTINEL"; assert "$@" FORGE_HARNESS_DIR="$THD"; rm -f "$SENTINEL"; }
# hpush_assert / with_task_hpush: assert with the branch-state guard pinned to the
# hermetic task-branch repo (HPUSH) instead of the host repo — the ONLY difference vs assert. The
# with_task sentinel is discovered via FORGE_HARNESS_DIR=$THD (never the real .harness).
hpush_assert() {
  local desc="$1" expect="$2" json="$3"
  shift 3
  local out rc got
  out="$(printf '%s' "$json" | env FORGE_HARNESS_DIR="$NOTASK_HD" "$@" CLAUDE_PROJECT_DIR="$HPUSH" bash "${TARGET_HOOK:-$DENY}" 2>"$ERRFILE")"
  rc=$?
  got="allow"
  if [ "$rc" = "2" ] || printf '%s' "$out" | grep -Eq '"permissionDecision":"deny"|"decision":"block"'; then got="deny"; fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s]\n  expected=%s got=%s rc=%s\n  json=%s\n  stderr=%s\n  stdout=%s\n' \
      "$desc" "$expect" "$got" "$rc" "$json" "$(cat "$ERRFILE")" "$out"
  fi
}
with_task_hpush() { printf '{"task":"t","branch":"task/x"}' >"$SENTINEL"; hpush_assert "$@" FORGE_HARNESS_DIR="$THD"; rm -f "$SENTINEL"; }
# bypass_assert: like assert, but runs the hook from a throwaway git repo so a logged bypass
# (forge_log_bypass) writes to THAT repo's .harness, never the real audit log (#10). The harness dir
# is pinned EXPLICITLY to the throwaway repo's .harness (forge_harness_dir honors the override), so
# the #10 log-isolation check below keeps observing the path it asserts.
bypass_assert() {
  local desc="$1" expect="$2" json="$3"
  shift 3
  local out rc got
  out="$(cd "$BYPASSREPO" && printf '%s' "$json" | env FORGE_HARNESS_DIR="$BYPASSREPO/.harness" "$@" CLAUDE_PROJECT_DIR="$BYPASSREPO" bash "$DENY" 2>"$ERRFILE")"
  rc=$?
  got="allow"
  if [ "$rc" = "2" ] || printf '%s' "$out" | grep -Eq '"permissionDecision":"deny"|"decision":"block"'; then got="deny"; fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s]\n  expected=%s got=%s rc=%s\n  json=%s\n  stderr=%s\n  stdout=%s\n' \
      "$desc" "$expect" "$got" "$rc" "$json" "$(cat "$ERRFILE")" "$out"
  fi
}

# assert_exec <path> [desc] — the script MUST carry its +x bit. settings.json invokes the PreToolUse/
# PostToolUse/Stop hooks by BARE PATH (not `bash <script>`), so a dropped +x bit (lost in an editor
# save or a splice) silently disables enforcement via the deployed path while THIS suite — which runs
# the hooks via `bash` — stays green. These checks close that structural blind spot.
assert_exec() {
  local path="$1" desc="${2:-$1}"
  if [ -x "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s]\n  expected=executable got=NOT-executable (bare-path invocation in settings.json fails)\n  path=%s mode=%s\n' \
      "$desc" "$path" "$(ls -ld "$path" 2>/dev/null | awk '{print $1}')"
  fi
}

echo "== hooks carry +x (deployed bare-path invocation, not bash <script>) =="
assert_exec "$DENY" "pre-tool-use-deny.sh executable"
assert_exec "$POST" "post-tool-use-format.sh executable"
assert_exec "$STOP" "stop-gate-tests.sh executable"
# The intake hooks are invoked by BARE PATH in settings.json, so a dropped +x at splice fails OPEN.
# Guarded on the DEPLOYED path: skipped pre-splice (candidate run via bash), asserted post-splice (gate-2).
[ -f "$ROOT/.claude/hooks/stop-gate-intake.sh" ] && assert_exec "$ROOT/.claude/hooks/stop-gate-intake.sh" "stop-gate-intake.sh executable"
[ -f "$ROOT/.claude/hooks/pre-tool-use-clarify-gate.sh" ] && assert_exec "$ROOT/.claude/hooks/pre-tool-use-clarify-gate.sh" "pre-tool-use-clarify-gate.sh executable"
# prove the deny hook actually enforces THROUGH the bare-path channel (sources lib.sh, emits deny) —
# the exact regression that hit us: +x lost -> bare-path exec returns 126 -> enforcement silently off.
_bp_out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo x > .git/config"}}' | FORGE_HARNESS_DIR="$NOTASK_HD" CLAUDE_PROJECT_DIR="$ROOT" "$DENY" 2>/dev/null)"
_bp_rc=$?
if [ "$_bp_rc" != "126" ] && printf '%s' "$_bp_out" | grep -Eq '"permissionDecision":"deny"'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL [deny hook enforces via bare-path exec]\n  rc=%s (126=not executable) out=%s\n' "$_bp_rc" "$_bp_out"
fi

# .beads/ integrity proven on the DEPLOYED BARE-PATH channel (not `bash <script>`): raw writes DENY, bd ALLOWS.
bp_assert() {
  local desc="$1" expect="$2" json="$3" out rc got
  out="$(printf '%s' "$json" | FORGE_HARNESS_DIR="$NOTASK_HD" CLAUDE_PROJECT_DIR="$ROOT" "$DENY" 2>/dev/null)"
  rc=$?
  got=allow
  { [ "$rc" = 2 ] || printf '%s' "$out" | grep -Eq '"permissionDecision":"deny"'; } && got=deny
  [ "$rc" = 126 ] && got=NOTEXEC
  if [ "$got" = "$expect" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    printf 'FAIL [bare-path %s] exp=%s got=%s\n  out=%s\n' "$desc" "$expect" "$got" "$out"
  fi
}
bp_assert ".beads echo>redirect" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > .beads/x"}}'
bp_assert ".beads Write"         deny '{"tool_name":"Write","tool_input":{"file_path":".beads/issues.jsonl","content":"x"}}'
bp_assert ".beads sed -i"        deny '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ .beads/x"}}'
bp_assert "bd update"            allow '{"tool_name":"Bash","tool_input":{"command":"bd update fx-1 --status open --assignee x"}}'
bp_assert "bd export -o .beads"  allow '{"tool_name":"Bash","tool_input":{"command":"bd export -o .beads/issues.jsonl"}}'

echo "== PreToolUse deny: ALLOW cases =="
assert "edit add.ts (no task)"        allow '{"tool_name":"Edit","tool_input":{"file_path":"sandbox/src/add.ts","old_string":"a","new_string":"b"}}'
assert "write new sandbox file"       allow '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/sub.ts","content":"export const sub=1"}}'
assert "rm -rf within sandbox"        allow '{"tool_name":"Bash","tool_input":{"command":"rm -rf sandbox/tmp"}}'
hpush_assert "push task branch"       allow '{"tool_name":"Bash","tool_input":{"command":"git push -u origin task/add"}}' # hermetic: HEAD=task/* via HPUSH
hpush_assert "normal commit"          allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg"}}' # hermetic: HEAD=task/* via HPUSH — git commit is branch-sensitive under the commit guard (bare assert denies on main)
assert "run tests"                    allow '{"tool_name":"Bash","tool_input":{"command":"pnpm vitest run"}}'
assert "edit README when NO task"     allow '{"tool_name":"Write","tool_input":{"file_path":"README.md","content":"hi"}}'
assert "git status"                   allow '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
assert "ls"                           allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert "gh pr create"                 allow '{"tool_name":"Bash","tool_input":{"command":"gh pr create --base main --head task/add"}}'

echo "== PreToolUse deny: destructive deletes =="
assert "rm -rf /tmp/x"                deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}'
assert "rm -rf .."                    deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf .."}}'
assert "rm -rf /"                     deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
assert "sudo rm -rf /etc"             deny  '{"tool_name":"Bash","tool_input":{"command":"sudo rm -rf /etc"}}'
assert "rm -fr ../foo"                deny  '{"tool_name":"Bash","tool_input":{"command":"rm -fr ../foo"}}'

echo "== PreToolUse deny: git push / branch protection =="
assert "force push"                   deny  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin task/x"}}'
assert "push -f"                      deny  '{"tool_name":"Bash","tool_input":{"command":"git push -f origin x"}}'
assert "push origin main"             deny  '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
assert "push HEAD:main"               deny  '{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD:main"}}'
assert "push my:master"               deny  '{"tool_name":"Bash","tool_input":{"command":"git push origin my:master"}}'
assert "push --mirror"                deny  '{"tool_name":"Bash","tool_input":{"command":"git push --mirror origin"}}'
assert "push --all"                   deny  '{"tool_name":"Bash","tool_input":{"command":"git push --all origin"}}'
assert "symbolic-ref main"            deny  '{"tool_name":"Bash","tool_input":{"command":"git symbolic-ref HEAD refs/heads/main"}}'

echo "== PreToolUse deny: --no-verify and sneak-arounds =="
assert "commit --no-verify"           deny  '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m x"}}'
assert "commit -n"                    deny  '{"tool_name":"Bash","tool_input":{"command":"git commit -n -m x"}}'
assert "core.hooksPath"               deny  '{"tool_name":"Bash","tool_input":{"command":"git -c core.hooksPath=/dev/null commit -m x"}}'
assert "HUSKY=0"                      deny  '{"tool_name":"Bash","tool_input":{"command":"HUSKY=0 git commit -m x"}}'

echo "== PreToolUse deny: secrets (command or content) =="
assert "ghp_ in command"              deny  '{"tool_name":"Bash","tool_input":{"command":"echo ghp_0000000000000000000000000000000000000000"}}'
assert "AKIA in content"              deny  '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/x.ts","content":"const k=\"AKIA0000000000000000\""}}'
assert "sk- in content"               deny  '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/x.ts","content":"sk-abcdefghijklmnopqrstuvwxyz0123"}}'
assert "PEM private key"              deny  '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/x.ts","content":"-----BEGIN RSA PRIVATE KEY-----"}}'
assert "JWT warns but ALLOWS"         allow '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/x.ts","content":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.SflKxwRJSMeKKF2QT4fwpM"}}'

echo "== PreToolUse deny: ..-traversal / .git / self-protection =="
# Vault RE-SCOPE: the vault (../my-vault) is an EXTERNAL target, NOT a forge component — the floor makes
# NO vault claim (see fold28-vault-out-of-scope). A RELATIVE `..`-bearing write still
# denies, but via the GENERAL `..`-unverifiable rule (below), NOT a vault rule — asserted here with a neutral
# non-vault path so this suite makes no false vault-protection claim.
assert "..-traversal write (path)"    deny  '{"tool_name":"Write","tool_input":{"file_path":"../elsewhere/x.md","content":"hi"}}'
assert "..-traversal bash redirect"   deny  '{"tool_name":"Bash","tool_input":{"command":"echo hi > ../elsewhere/x"}}'
assert ".git write (path)"            deny  '{"tool_name":"Write","tool_input":{"file_path":".git/config","content":"x"}}'
assert "self-protect hook write"      deny  '{"tool_name":"Write","tool_input":{"file_path":".claude/hooks/pre-tool-use-deny.sh","content":"x"}}'
assert "self-protect settings edit"   deny  '{"tool_name":"Edit","tool_input":{"file_path":".claude/settings.json","old_string":"a","new_string":"b"}}'
assert "self-protect harness write"   deny  '{"tool_name":"Write","tool_input":{"file_path":"harness/run-task.sh","content":"x"}}'
assert "self-protect harness/repos.config (work_root confinement input)" deny '{"tool_name":"Write","tool_input":{"file_path":"harness/repos.config","content":"evil=/tmp/x"}}'
assert "self-protect harness/repos.config via bash redirect" deny '{"tool_name":"Bash","tool_input":{"command":"echo evil=/tmp/x > harness/repos.config"}}'
assert "self-protect review-task.sh"  deny  '{"tool_name":"Write","tool_input":{"file_path":"harness/review-task.sh","content":"x"}}'
assert "self-protect reviewers.config" deny '{"tool_name":"Edit","tool_input":{"file_path":"harness/reviewers.config","old_string":"a","new_string":"b"}}'
assert "self-protect settings.local"  deny  '{"tool_name":"Write","tool_input":{"file_path":".claude/settings.local.json","content":"x"}}'
assert "self-protect .harness write"  deny  '{"tool_name":"Write","tool_input":{"file_path":".harness/active-task.json","content":"x"}}'
assert ".git mutate via redirect"     deny  '{"tool_name":"Bash","tool_input":{"command":"echo x > .git/config"}}'
assert "shell-mutate a hook"          deny  '{"tool_name":"Bash","tool_input":{"command":"rm .claude/hooks/x.sh"}}'
assert "redirect into harness"        deny  '{"tool_name":"Bash","tool_input":{"command":"echo x > harness/y.sh"}}'
assert "worktree sandbox NOT protected" allow "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$ROOT/.claude/worktrees/demo/sandbox/src/x.ts\",\"content\":\"export const x=1\"}}"
assert "worktree OWN hook IS protected"  deny  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$ROOT/.claude/worktrees/demo/.claude/hooks/x.sh\",\"content\":\"x\"}}"

echo "== .beads/ integrity: bd is the SOLE mutator (raw writes deny; bd + reads allow) =="
assert ".beads Write denied"              deny  '{"tool_name":"Write","tool_input":{"file_path":".beads/issues.jsonl","content":"x"}}'
assert ".beads Edit denied"               deny  '{"tool_name":"Edit","tool_input":{"file_path":".beads/config.yaml","old_string":"a","new_string":"b"}}'
assert ".beads abs-path Write denied"     deny  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$ROOT/.beads/issues.jsonl\",\"content\":\"x\"}}"
assert ".beads echo redirect denied"      deny  '{"tool_name":"Bash","tool_input":{"command":"echo x > .beads/issues.jsonl"}}'
assert ".beads append redirect denied"    deny  '{"tool_name":"Bash","tool_input":{"command":"echo x >> .beads/issues.jsonl"}}'
assert ".beads sed -i denied"             deny  '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ .beads/issues.jsonl"}}'
assert ".beads tee denied"                deny  '{"tool_name":"Bash","tool_input":{"command":"tee .beads/issues.jsonl"}}'
assert ".beads cp-into denied"            deny  '{"tool_name":"Bash","tool_input":{"command":"cp evil .beads/issues.jsonl"}}'
assert ".beads rm (non-recursive) denied" deny  '{"tool_name":"Bash","tool_input":{"command":"rm .beads/issues.jsonl"}}'
assert "bd update allowed"                allow '{"tool_name":"Bash","tool_input":{"command":"bd update fx-1 --status open --assignee x"}}'
assert "bd export -o .beads allowed"      allow '{"tool_name":"Bash","tool_input":{"command":"bd export -o .beads/issues.jsonl"}}'
assert "bd create allowed"                allow '{"tool_name":"Bash","tool_input":{"command":"bd create title -p 2 --silent"}}'
assert "read .beads via cat allowed"      allow '{"tool_name":"Bash","tool_input":{"command":"cat .beads/issues.jsonl"}}'
assert "read .beads via jq allowed"       allow '{"tool_name":"Bash","tool_input":{"command":"jq . .beads/issues.jsonl"}}'

echo "== bypass: FORGE_ALLOW_HOOK_EDIT=1 (logged) allows hook edit =="
bypass_assert "hook write w/ bypass"         allow '{"tool_name":"Write","tool_input":{"file_path":".claude/hooks/x.sh","content":"x"}}' FORGE_ALLOW_HOOK_EDIT=1

echo "== TASK-SCOPED: sandbox confinement (sentinel present) =="
with_task "task: write outside sandbox denied" deny  '{"tool_name":"Write","tool_input":{"file_path":"README.md","content":"x"}}'
with_task "task: write in sandbox allowed"     allow '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/x.ts","content":"x"}}'
with_task_hpush "task: bash push not confined" allow '{"tool_name":"Bash","tool_input":{"command":"git push -u origin task/x"}}' # hermetic

echo "== PostToolUse format/lint: no-op cases =="
TARGET_HOOK="$POST"
assert "post: non-sandbox file no-op"  allow '{"tool_name":"Write","tool_input":{"file_path":"README.md"}}'
assert "post: absent sandbox file no-op" allow '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/does-not-exist.ts"}}'
TARGET_HOOK=""

echo "== Stop gate: scoping (hermetic fixtures) + fail-closed matrix (R-16 / cap) =="
# Every Stop-gate case runs against a HERMETIC fixture — its own git repo with
# its own harness/targets.config, its own harness dir with its own sentinel/counter — and the hook
# is exec'd from INSIDE the fixture, so both resolvers (the deployed CLAUDE_PROJECT_DIR-first probe
# and the candidate forge_main_root anchor) stay inside the fixture. This kills two Ruling-A hazards
# the old fixtures carried: the suite no longer evals the REAL targets.config (post-Ruling-A that is
# `pnpm test` — the old "GREEN tests" fixture would have recursed the whole gate inside test:hooks),
# and it never touches the real .harness sentinel or stop-blocks counter.
SFREPO=""
SFHD=""
stop_fix() { # stop_fix <none|empty|green|red> — fixture repo (targets.config flavor) + ARMED task
  SFREPO="$(mktemp -d -p "$STOPFIX_TMP")"
  git -C "$SFREPO" init -q 2>/dev/null
  case "$1" in
    none) : ;; # no harness/targets.config at all -> forge_load_target fails
    empty)
      mkdir -p "$SFREPO/harness"
      printf 'TARGET=demo\ndemo_TEST_CMD=""\n' >"$SFREPO/harness/targets.config"
      ;;
    green)
      mkdir -p "$SFREPO/harness"
      printf 'TARGET=demo\ndemo_TEST_CMD="true"\n' >"$SFREPO/harness/targets.config"
      ;;
    red)
      mkdir -p "$SFREPO/harness"
      printf 'TARGET=demo\ndemo_TEST_CMD="false"\n' >"$SFREPO/harness/targets.config"
      ;;
  esac
  SFHD="$(mktemp -d -p "$STOPFIX_TMP")"
  printf '{"task":"t","branch":"task/x"}' >"$SFHD/active-task.json"
}
stop_assert() { # stop_assert <desc> <allow|deny> <hook> <stop_hook_active:true|false> [env KEY=VAL ...]
  local desc="$1" expect="$2" hook="$3" sha="$4"
  shift 4
  local out rc got
  out="$(cd "$SFREPO" && printf '{"hook_event_name":"Stop","stop_hook_active":%s,"cwd":"%s"}' "$sha" "$SFREPO" |
    env FORGE_HARNESS_DIR="$SFHD" "$@" CLAUDE_PROJECT_DIR="$SFREPO" bash "$hook" 2>"$ERRFILE")"
  rc=$?
  got="allow"
  if [ "$rc" = "2" ] || printf '%s' "$out" | grep -Eq '"permissionDecision":"deny"|"decision":"block"'; then got="deny"; fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s]\n  expected=%s got=%s rc=%s\n  stdout=%s\n  stderr=%s\n' \
      "$desc" "$expect" "$got" "$rc" "$out" "$(cat "$ERRFILE")"
  fi
}
# scoping — semantics shared by deployed and candidate (run against the DEPLOYED hook)
stop_fix green
rm -f "$SFHD/active-task.json"
stop_assert "stop: no task -> allow" allow "$STOP" false
stop_fix green
stop_assert "stop: stop_hook_active -> allow" allow "$STOP" true
stop_fix green
stop_assert "stop: active + GREEN tests -> allow" allow "$STOP" false
stop_fix red
stop_assert "stop: active + RED tests -> block" deny "$STOP" false

# ---- fail-closed matrix (the resolved fail-closed hook: candidate pre-splice, deployed post-splice) ----
# R-16 — config-resolution failure / empty TEST_CMD while a task is active:
#   FORGE_UNATTENDED=1 -> BLOCK with a named reason (fail closed); unset -> today's allow (attended legacy).
stop_fix none
stop_assert "R-16: config missing + task + UNATTENDED -> block" deny "$STOP_FC" false FORGE_UNATTENDED=1
stop_fix none
stop_assert "R-16: config missing + task + attended -> allow (legacy)" allow "$STOP_FC" false
stop_fix empty
stop_assert "R-16: empty TEST_CMD + task + UNATTENDED -> block" deny "$STOP_FC" false FORGE_UNATTENDED=1
stop_fix empty
stop_assert "R-16: empty TEST_CMD + task + attended -> allow (legacy)" allow "$STOP_FC" false
# R-16 scope guard: NO task active -> no-op allow in EVERY mode (the gate only gates a build).
stop_fix none
rm -f "$SFHD/active-task.json"
stop_assert "R-16: config missing + NO task + UNATTENDED -> allow (no-op)" allow "$STOP_FC" false FORGE_UNATTENDED=1
# cap-release — persistent red at the loop cap:
#   FORGE_UNATTENDED=1 -> NEVER release (block; counter keeps counting); unset -> today's release.
stop_fix red
printf '1' >"$SFHD/stop-blocks"
stop_assert "cap: red at cap + UNATTENDED -> still block (never release)" deny "$STOP_FC" false FORGE_UNATTENDED=1 FORGE_STOP_BLOCK_CAP=2
if [ "$(cat "$SFHD/stop-blocks" 2>/dev/null)" = "2" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL [cap unattended: counter must SURVIVE and count (expected 2, got %s)]\n' "$(cat "$SFHD/stop-blocks" 2>/dev/null || printf ABSENT)"
fi
stop_fix red
printf '1' >"$SFHD/stop-blocks"
stop_assert "cap: red at cap + attended -> release (legacy human-intervention)" allow "$STOP_FC" false FORGE_STOP_BLOCK_CAP=2
if [ ! -f "$SFHD/stop-blocks" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL [cap attended: release must reset the counter file]\n'
fi
# red UNDER the cap blocks in both modes (the gate's core promise is mode-independent)
stop_fix red
stop_assert "stop_fc: red under cap + UNATTENDED -> block" deny "$STOP_FC" false FORGE_UNATTENDED=1
stop_fix red
stop_assert "stop_fc: red under cap + attended -> block" deny "$STOP_FC" false
# green resets the counter and allows in both modes
stop_fix green
printf '3' >"$SFHD/stop-blocks"
stop_assert "stop_fc: green + UNATTENDED -> allow + counter reset" allow "$STOP_FC" false FORGE_UNATTENDED=1
if [ ! -f "$SFHD/stop-blocks" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL [green must reset the stop-blocks counter]\n'
fi

echo "== anchor: forge_load_target resolves the ROOT targets.config from a worktree =="
# The worktree-divergence demo, inverted to green: a worktree carries a DIVERGENT targets.config; the resolved
# lib (candidate shim pre-splice, deployed lib post-splice — marker-gated above) must load the ROOT
# copy even when cwd AND CLAUDE_PROJECT_DIR point at the worktree.
ANC="$(mktemp -d -p "$STOPFIX_TMP")"
git -C "$ANC" init -q 2>/dev/null
mkdir -p "$ANC/harness"
printf 'TARGET=demo\ndemo_TEST_CMD="echo ROOT-COPY"\n' >"$ANC/harness/targets.config"
git -C "$ANC" add -A 2>/dev/null
git -C "$ANC" -c user.email=t@t -c user.name=t commit -q -m base 2>/dev/null
git -C "$ANC" worktree add -q "$ANC/wt" -b probe/anchor HEAD 2>/dev/null
printf 'TARGET=demo\ndemo_TEST_CMD="echo WORKTREE-COPY"\n' >"$ANC/wt/harness/targets.config"
# negative control: the divergent worktree copy really is in place (the test cannot pass vacuously)
if grep -q 'WORKTREE-COPY' "$ANC/wt/harness/targets.config" 2>/dev/null; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL [anchor precondition: divergent worktree targets.config missing]\n'
fi
anchor_out="$(cd "$ANC/wt" && CLAUDE_PROJECT_DIR="$ANC/wt" bash -c '. "'"$LIB_FC"'" && TARGET=demo && forge_load_target && printf %s "$TEST_CMD"' 2>"$ERRFILE")"
if [ "$anchor_out" = "echo ROOT-COPY" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL [anchor: forge_load_target must resolve the ROOT copy from a worktree]\n  got=%s stderr=%s\n' "$anchor_out" "$(cat "$ERRFILE")"
fi

echo "== forge_check_rm: argv-aware (#6 fix + Bucket-C gap-closures + command-identity) =="
# the #6 fix: a filename fragment is no longer misread as -r/-f
assert "rm flag-named file (#6 fix)"      allow '{"tool_name":"Bash","tool_input":{"command":"rm agentic-builder-forge-README-CANDIDATE.md"}}'
assert "rm -f a sandbox file"             allow '{"tool_name":"Bash","tool_input":{"command":"rm -f sandbox/a.txt"}}'
assert "rm -rf ./sandbox/ subdir"         allow '{"tool_name":"Bash","tool_input":{"command":"rm -rf ./sandbox/x"}}'
hpush_assert "commit msg mentioning rm -rf"  allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix rm -rf handling\""}}' # hermetic: HEAD=task/* via HPUSH (git commit branch-sensitive under the commit guard); tests the destructive-delete check does NOT misread rm -rf in a commit MESSAGE
assert "cp -rf is not a delete"           allow '{"tool_name":"Bash","tool_input":{"command":"cp -rf a b"}}'
assert "grep -rf is not a delete"         allow '{"tool_name":"Bash","tool_input":{"command":"grep -rf pat dir"}}'
# Bucket-C: previously-LEAKED recursive-force deletes now DENY (security improvement, not regression)
assert "rm -Rf (capital R)"               deny  '{"tool_name":"Bash","tool_input":{"command":"rm -Rf /etc"}}'
assert "rm -fR (capital R)"               deny  '{"tool_name":"Bash","tool_input":{"command":"rm -fR /etc"}}'
assert "rm -R -f (separate flags)"        deny  '{"tool_name":"Bash","tool_input":{"command":"rm -R -f /etc"}}'
assert "rm -vRf (clustered)"              deny  '{"tool_name":"Bash","tool_input":{"command":"rm -vRf /etc"}}'
assert "backslash-rm -rf /"               deny  '{"tool_name":"Bash","tool_input":{"command":"\\rm -rf /"}}'
assert "absolute /bin/rm -rf /"           deny  '{"tool_name":"Bash","tool_input":{"command":"/bin/rm -rf /"}}'
assert "find / -delete"                   deny  '{"tool_name":"Bash","tool_input":{"command":"find / -delete"}}'
assert "find / -exec rm -rf"              deny  '{"tool_name":"Bash","tool_input":{"command":"find / -exec rm -rf {} +"}}'
assert "rm -rf -- -r (post-endopts)"      deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf -- -r"}}'
assert "rm -rf mixed sandbox + escape"    deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf sandbox/a ../x"}}'
assert "shred a system file"              deny  '{"tool_name":"Bash","tool_input":{"command":"shred /etc/passwd"}}'
# command-identity fail-closed (the one fail-open path the ambiguity table did not cover)
assert "opaque cmd word \$CMD -rf /"       deny  '{"tool_name":"Bash","tool_input":{"command":"$CMD -rf /"}}'
assert "subst cmd word \$(which rm) -rf"   deny  '{"tool_name":"Bash","tool_input":{"command":"$(which rm) -rf /"}}'
assert "unknown wrapper around rm"        deny  '{"tool_name":"Bash","tool_input":{"command":"myrunner rm -rf /etc"}}'
# ambiguity -> fail closed
assert "delete via eval"                  deny  '{"tool_name":"Bash","tool_input":{"command":"eval \"rm -rf /\""}}'
assert "delete piped to xargs"            deny  '{"tool_name":"Bash","tool_input":{"command":"echo /etc | xargs rm -rf"}}'
assert "delete inside sh -c"              deny  '{"tool_name":"Bash","tool_input":{"command":"sh -c \"rm -rf /\""}}'
assert "rm -rf variable target"           deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf $TARGET"}}'
assert "rm -rf glob target"               deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf *"}}'
# pipe inside $(...) / backticks: the bare-| splitter must not yield a clean-parsing segment
assert "rm -rf subst-with-pipe"           deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf \"$(cat foo | bar)\""}}'
assert "rm -rf \$(ls | tail)"              deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf $(ls | tail)"}}'
assert "rm -rf backtick echo"             deny  '{"tool_name":"Bash","tool_input":{"command":"rm -rf `echo /etc`"}}'
# quoted target with a space -> broken tokens -> DENY. KNOWN fail-closed false-positive: a legit
# in-sandbox path with a space also denies (see COVERAGE.md). Pinned so the direction is intentional.
assert "quoted-space in sandbox (FP deny)" deny "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf 'sandbox/my dir'\"}}"
assert "quoted-space non-sandbox"         deny  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf 'my dir'\"}}"

echo "== forge_check_rm: fuzz (flag permutations x targets) =="
for _f in "-rf" "-fr" "-Rf" "-fR" "-rfv" "-vrf" "-r -f" "-R -f" "-f -R" "--recursive --force"; do
  assert "fuzz DENY  rm $_f /etc"        deny  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm $_f /etc\"}}"
  assert "fuzz ALLOW rm $_f sandbox/x"   allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm $_f sandbox/x\"}}"
done

echo "== forge_check_writes: write-target resolution (#2) — writes DENY, reads ALLOW =="
assert "redirect into harness"            deny  '{"tool_name":"Bash","tool_input":{"command":"echo x > harness/run-task.sh"}}'
assert "append into a hook"               deny  '{"tool_name":"Bash","tool_input":{"command":"echo x >> .claude/hooks/lib.sh"}}'
assert "tee into harness"                 deny  '{"tool_name":"Bash","tool_input":{"command":"tee harness/x"}}'
assert "dd of= into harness"              deny  '{"tool_name":"Bash","tool_input":{"command":"dd of=harness/x"}}'
assert "sed -i a hook config"             deny  '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ harness/targets.config"}}'
assert "ln replace a hook"                deny  '{"tool_name":"Bash","tool_input":{"command":"ln -sf evil .claude/hooks/x"}}'
assert "chmod a hook"                     deny  '{"tool_name":"Bash","tool_input":{"command":"chmod 777 harness/x"}}'
assert "rm a hook (non-recursive) (#2)"   deny  '{"tool_name":"Bash","tool_input":{"command":"rm .claude/hooks/x.sh"}}'
assert ".git write via redirect"          deny  '{"tool_name":"Bash","tool_input":{"command":"echo x > .git/config"}}'
assert ".git write still denies w/ door"  deny  '{"tool_name":"Bash","tool_input":{"command":"echo x > .git/config"}}' FORGE_ALLOW_HOOK_EDIT=1
bypass_assert "harness write w/ door (logged)"   allow '{"tool_name":"Bash","tool_input":{"command":"echo x > harness/run-task.sh"}}' FORGE_ALLOW_HOOK_EDIT=1
assert "read: ls hooks 2>/dev/null"       allow '{"tool_name":"Bash","tool_input":{"command":"ls .claude/hooks/ 2>/dev/null"}}'
assert "read: sed -n a hook config"       allow '{"tool_name":"Bash","tool_input":{"command":"sed -n 1p harness/targets.config"}}'
assert "read: grep a hook"                allow '{"tool_name":"Bash","tool_input":{"command":"grep x .claude/hooks/lib.sh"}}'
assert "read: cat a hook to /tmp"         allow '{"tool_name":"Bash","tool_input":{"command":"cat harness/run-task.sh > /tmp/y"}}'
assert "path only in message text"        allow '{"tool_name":"Bash","tool_input":{"command":"echo \"see harness/run-task.sh\" > sandbox/notes.md"}}'
assert "fc: redirect to a var target"     deny  '{"tool_name":"Bash","tool_input":{"command":"echo x > $OUT"}}'
assert "fc: redirect to a subst target"   deny  '{"tool_name":"Bash","tool_input":{"command":"echo x > $(d)"}}'
assert "fc: fd dup to non-std descriptor" deny  '{"tool_name":"Bash","tool_input":{"command":"echo x >&3"}}'
assert "fc: redirect into process subst"  deny  '{"tool_name":"Bash","tool_input":{"command":"echo x > >(tee harness/x)"}}'
assert "fc: cp dest behind a var"         deny  '{"tool_name":"Bash","tool_input":{"command":"cp evil $DST"}}'
assert "fc: enforce-adjacent pipe to sh"  deny  '{"tool_name":"Bash","tool_input":{"command":"cat harness/run-task.sh | bash"}}'
assert "v3: cp multi-source into hooks"   deny  '{"tool_name":"Bash","tool_input":{"command":"cp a b .claude/hooks/"}}'
assert "v3: cp -r into harness dir"       deny  '{"tool_name":"Bash","tool_input":{"command":"cp -r sandbox/x harness/"}}'
assert "v3: cp sources from harness OK"   allow '{"tool_name":"Bash","tool_input":{"command":"cp harness/x harness/y sandbox/"}}'
assert "v3: tee harness > /dev/null"      deny  '{"tool_name":"Bash","tool_input":{"command":"tee harness/x > /dev/null"}}'
assert "v3: cp w/ 2>/dev/null operand"    allow '{"tool_name":"Bash","tool_input":{"command":"cp sandbox/a sandbox/b 2>/dev/null"}}'
assert "v3: dd redirect not of="          deny  '{"tool_name":"Bash","tool_input":{"command":"dd if=/dev/zero > harness/x"}}'
assert "v3: mv source removal (all ops)"  deny  '{"tool_name":"Bash","tool_input":{"command":"mv harness/x /tmp/y"}}'

echo "== forge_check_writes: fuzz (redirect operator x target class) =="
for _op in ">" ">>" "2>" "&>" ">|" "1>"; do
  assert "fuzz DENY  $_op harness"   deny  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x $_op harness/k\"}}"
  assert "fuzz ALLOW $_op /dev/null" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x $_op /dev/null\"}}"
done

echo "== forge_check_push: push-to-main scoping (#7) =="
# Hermetic: pin CLAUDE_PROJECT_DIR to throwaway repos so the branch-state guard is deterministic
# regardless of the suite's actual branch (same class as the FORGE_ALLOW_HOOK_EDIT unset above). The
# on-main / detached / non-git cases exercise the LIVE symbolic-ref path the bash-fixture form can't.
_mkrepo() {
  local d
  d="$(mktemp -d)"
  case "$1" in
    --detach) git -C "$d" init -q; git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x; git -C "$d" checkout -q --detach ;;
    --nogit) : ;;
    *) git -C "$d" init -q -b "$1" 2>/dev/null || { git -C "$d" init -q; git -C "$d" symbolic-ref HEAD "refs/heads/$1"; } ;;
  esac
  printf '%s' "$d"
}
PFEAT="$(_mkrepo task/x)"
PMAIN="$(_mkrepo main)"
PDET="$(_mkrepo --detach)"
PNOGIT="$(_mkrepo --nogit)"
# passert <desc> <allow|deny> <cmd> [repo]   (default repo = PFEAT, a non-main branch)
passert() {
  local desc="$1" expect="$2" cmd="$3" repo="${4:-$PFEAT}" out got
  out="$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | env -u FORGE_ALLOW_HOOK_EDIT FORGE_HARNESS_DIR="$NOTASK_HD" CLAUDE_PROJECT_DIR="$repo" bash "$DENY" 2>/dev/null)"
  got=allow
  printf '%s' "$out" | grep -Eq '"permissionDecision":"deny"' && got=deny
  if [ "$got" = "$expect" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s] exp=%s got=%s\n  cmd=%s\n' "$desc" "$expect" "$got" "$cmd"
  fi
}
# A: true-positives stay DENY
passert "push origin main" deny 'git push origin main'
passert "push HEAD:main" deny 'git push origin HEAD:main'
passert "push my:master" deny 'git push origin my:master'
passert "push --mirror" deny 'git push --mirror origin'
passert "push --all" deny 'git push --all origin'
passert "force push" deny 'git push --force origin task/x'
passert "push -f" deny 'git push -f origin x'
passert "push refs/heads/main" deny 'git push origin refs/heads/main'
passert "delete :main" deny 'git push origin :main'
# B: false-positives now ALLOW (per-segment scoping; exact-match dst)
passert "push task/x && gh --base main" allow 'git push origin task/x && gh pr create --base main'
passert "push task/x && git log --all" allow 'git push origin task/x && git log --all'
passert "push task/x && echo --force" allow 'git push origin task/x && echo --force'
passert "push main:dev (dst=dev)" allow 'git push origin main:dev'
passert "push -u origin task/add" allow 'git push -u origin task/add'
passert "echo mentions push main" allow 'echo "git push origin main"'
passert "push maintenance (exact)" allow 'git push origin maintenance'
# C: gap-closures now DENY (intended hardening, named in the PR)
passert "quoted main" deny 'git push origin "main"'
passert "quoted refs/heads/master" deny "git push origin 'refs/heads/master'"
passert "var refspec" deny 'git push origin $BRANCH'
passert "subst refspec" deny 'git push origin $(echo main)'
passert "backtick refspec" deny 'git push origin `echo main`'
passert "+force refspec" deny 'git push origin +main'
passert "+force feature refspec" deny 'git push origin +task/x:task/x'
passert "sh -c hides push" deny 'sh -c "git push origin main"'
passert "eval hides push" deny 'eval "git push origin main"'
passert "xargs git push" deny 'echo x | xargs git push origin main'
passert "opaque \$GIT push" deny '$GIT push origin main'
# bare / no-refspec -> hard-deny (D4)
passert "bare git push" deny 'git push'
passert "remote-only push" deny 'git push origin'
# value-taker fail-open guard (#1): a skipped flag VALUE must not let a real dst=main slip through
passert "-o skips value; main judged" deny 'git push -o ci.skip origin main'
passert "--push-option= ; main judged" deny 'git push --push-option=ci origin main'
passert "-o value-named-main denied" deny 'git push -o main origin task/x'
passert "-o ci.skip task/x allowed" allow 'git push -o ci.skip origin task/x'
# branch-state via LIVE symbolic-ref against real temp repos
passert "on main -> deny (:78-79)" deny 'git push origin task/x' "$PMAIN"
passert "detached HEAD -> deny" deny 'git push origin task/x' "$PDET"
passert "non-git dir -> deny" deny 'git push origin task/x' "$PNOGIT"
passert "on feature -> allow" allow 'git push origin task/x' "$PFEAT"
# fuzz: {main,master} x refspec-forms -> DENY
for _r in main master; do
  for _f in "$_r" ":$_r" "dev:$_r" "+$_r" "refs/heads/$_r"; do
    passert "fuzz $_f" deny "git push origin $_f"
  done
done
rm -rf "$PFEAT" "$PMAIN" "$PDET" "$PNOGIT"

echo "== #4 cwd-robustness: the deny hook SCRIPT enforces from a SUBDIRECTORY cwd =="
# Scenario (b): hooks loaded at a root launch, runtime cwd is a subdir. Proves the SCRIPT self-anchors
# (forge_main_root + CLAUDE_PROJECT_DIR), so a non-root cwd mid-session still enforces. It does NOT test
# Claude Code's settings DISCOVERY from a subdir LAUNCH — that is the cwd-load limitation
# (claude-code#12962), mitigated by docs + the user-scope backstop + run-task.sh's warning, never closed
# in-repo.
SUBDIR="$ROOT/harness"
cwd_assert() { # cwd_assert <desc> <allow|deny> <json> [env KEY=VAL | -u KEY ...]
  local desc="$1" expect="$2" json="$3"
  shift 3
  local out got
  # "$@" may carry env OPTIONS (-u KEY), which must precede assignments — so the hermetic
  # FORGE_HARNESS_DIR default goes AFTER "$@" here (no cwd_assert caller passes its own).
  out="$(cd "$SUBDIR" && printf '%s' "$json" | env "$@" FORGE_HARNESS_DIR="$NOTASK_HD" bash "$DENY" 2>/dev/null)"
  got=allow
  printf '%s' "$out" | grep -Eq '"permissionDecision":"deny"' && got=deny
  if [ "$got" = "$expect" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s] exp=%s got=%s\n' "$desc" "$expect" "$got"
  fi
}
cwd_assert "subdir push-to-main (CPD=root)" deny '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' CLAUDE_PROJECT_DIR="$ROOT"
cwd_assert "subdir push-to-main (CPD unset)" deny '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' -u CLAUDE_PROJECT_DIR
cwd_assert "subdir enforce-write (CPD=root)" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > harness/run-task.sh"}}' CLAUDE_PROJECT_DIR="$ROOT"
cwd_assert "subdir enforce-write (CPD unset)" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > harness/run-task.sh"}}' -u CLAUDE_PROJECT_DIR

echo "== #10: bypass logging isolated to a throwaway repo (real audit log undiluted) =="
[ -s "$BYPASSREPO/.harness/hook-edit-bypass.log" ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); printf 'FAIL [bypass writes must land in the throwaway repo, not the real log]\n'; }

# --- INTAKE hooks — a SEPARATE active-intake.json lifecycle from the build sentinel ---
# isetup <phase> <mode> <clarify_rounds> <spec-body> : fresh tmp harness with active-intake.json + spec.md.
# The candidate hooks source "$DIR/lib.sh" (the sandbox test-shim, which adds forge_intake_* + the
# FORGE_HARNESS_DIR override); FORGE_HARNESS_DIR="$IHD" points them at this fixture, never the real .harness.
IHD=""
isetup() { # <phase> <mode> <clarify_rounds> <spec-body> [understanding-body] [restatement-body]
  IHD="$(mktemp -d -p "$INTAKE_TMP")"
  printf '%s' "$4" >"$IHD/spec.md"
  jq -nc --arg s "$IHD/spec.md" --arg m "$2" --argjson cr "$3" --arg p "$1" \
    '{spec:$s,mode:$m,phase:$p,clarify_rounds:$cr,restate_rounds:3,clarify_max_q:4}' >"$IHD/active-intake.json"
  [ "$#" -ge 5 ] && printf '%s' "$5" >"$IHD/understanding.md"
  [ "$#" -ge 6 ] && printf '%s' "$6" >"$IHD/restatement.md"
  # Stage E: stage a captured spec-review record DERIVED from the restatement body, so the consensus open-count
  # is identical whether the floor reads restatement.md (deployed) or the record (candidate). Trap-proof
  # fixtures OVERRIDE this file with a DIVERGING record to prove the record is the oracle. No restatement arg =>
  # no record (record-absent => open=0 => allow, the same as the rst-absent path).
  if [ "$#" -ge 6 ]; then
    _no="$(printf '%s' "$6" | grep -cE '^- \[(DISAGREE|ESCALATE)\]' 2>/dev/null)"; case "$_no" in '' | *[!0-9]*) _no=0 ;; esac
    _ssha="$(sha256sum "$IHD/spec.md" | cut -d' ' -f1)"  # Stage E anti-TOCTOU: bind the record to the spec
    if [ "$_no" -gt 0 ]; then
      jq -nc --arg ssha "$_ssha" --argjson n "$_no" '{verdict:"DISAGREE",spec_sha256:$ssha,findings:[range($n)|{id:("f"+(.+1|tostring)),category:"misc-placeholders",location:"FR-001",finding:"open"}]}' >"$IHD/intake-spec-review.json"
    else
      jq -nc --arg ssha "$_ssha" '{verdict:"AGREE",spec_sha256:$ssha,findings:[]}' >"$IHD/intake-spec-review.json"
    fi
  fi
}
istop() { assert "$1" "$2" '{"hook_event_name":"Stop","stop_hook_active":false}' FORGE_HARNESS_DIR="$IHD"; }
# B+C (trap #3): the per-category visibility floor requires EVERY canonical category to carry a disposition
# in the ## Deferrals ledger, so OK_SPEC (and the Gate-A fixtures built on it) must disposition them ALL or the
# sweep blocks and the protected Gate-A logic stops being reached. Generate the full ledger from the SAME enum
# the candidate hook reads (candidate via FORGE_INTAKE_CATEGORIES, else the deployed harness/ copy), one
# content-free `deliberately N/A` line per category (presence, not adequacy). On the deployed PRE-SPLICE run
# (no enum) FULL_LEDGER is empty -> the heading-only ## Deferrals still satisfies the deployed hook's lean
# check (which has no per-category sweep), so OK_SPEC behaves exactly as before there.
CATS="${FORGE_INTAKE_CATEGORIES:-$ROOT/harness/intake-categories.json}"
# by-default catastrophic categories must be COVERED (not N/A) or the catastrophic Stop nudge blocks; the rest
# get a content-free `deliberately N/A`. Keeps OK_SPEC clean for BOTH the visibility sweep and the nudge.
FULL_LEDGER="$(jq -r '.categories[]? | if .risk_default=="by-default" then "- `\(.id)` — covered by FR-001" else "- `\(.id)` — deliberately N/A — fixture default" end' "$CATS" 2>/dev/null)"
F7=$'## Deferrals / Out of scope\n'"$FULL_LEDGER"
OK_SPEC=$'## User Scenarios\n### US1 (P1) — leave a comment\n## Requirements\n- FR-001: System MUST persist a comment. (US1)\n## Success Criteria\n- SC-001: 95% of saves complete in under 2 seconds.\n'"$F7"
R6=$'## Clarifications\n### Round 1 — d\n### Round 2 — d\n### Round 3 — d\n### Round 4 — d\n### Round 5 — d\n### Round 6 — d'
R5=$'## Clarifications\n### Round 1 — d\n### Round 2 — d\n### Round 3 — d\n### Round 4 — d\n### Round 5 — d'

echo "== INTAKE Stop gate (stop-gate-intake.sh): F1 floor — CARRIER-INDEPENDENT (clarify-gate ABSENT) =="
# Decoupling proof: the F1 guarantee must hold on the Stop floor ALONE — no clarify-gate is registered here.
TARGET_HOOK="$STOP_INTAKE"
isetup open interactive 5 "$OK_SPEC" $'# Understanding\n## What the FRs will build\nThe spec projection.'; istop "stop-intake: F1 floor clean + Gate-A consensus -> allow" allow
isetup open interactive 5 "$OK_SPEC"$'\n- FR-002: MUST y [NEEDS CLARIFICATION: how?].';      istop "stop-intake: residual [NEEDS CLARIFICATION] -> block" deny
isetup open autonomous 5 "$OK_SPEC"$'\n## Clarifications\n### Round 1 — 2026-06-09\n- Q->A';  istop "stop-intake: autonomous + an asked round -> block" deny
isetup open interactive 5 "$OK_SPEC"$'\n'"$R6";                                              istop "stop-intake: rounds(6) over budget(5) -> block" deny
# V1 grant-asymmetry fix: the Stop floor must honor a human clarify grant EXACTLY as the
# clarify-gate does (pre-tool-use-clarify-gate.sh:54-57). A granted round at budget+grant must NOT wedge the
# floor — and the F1.3 message advertises `intake.sh clarify` as a remedy, so ignoring the grant is a live bug.
# RED on the deployed hook (no grant read -> rounds(6) > budget(5) -> block), GREEN on the candidate.
isetup open interactive 5 "$OK_SPEC"$'\n'"$R6" $'# Understanding\n## What the FRs will build\nThe spec projection.'; printf '1' >"$IHD/intake-clarify-grant"; istop "stop-intake: rounds(6) within budget(5)+grant(1) -> allow (V1 grant honored)" allow
# Guard: a grant lifts the ceiling by the GRANTED amount only — it is not unbounded. grant(0) still blocks.
isetup open interactive 5 "$OK_SPEC"$'\n'"$R6";                                              printf '0' >"$IHD/intake-clarify-grant"; istop "stop-intake: rounds(6) over budget(5)+grant(0) -> block (grant is exact, not unbounded)" deny
isetup open interactive 5 $'## User Scenarios\n### US1 (P1) — x\n## Requirements\n- FR-001: MUST x. (US1)\n## Success Criteria\n- SC-001: 95%.'; istop "stop-intake: missing F7 ## Deferrals -> block" deny
isetup open interactive 5 $'## User Scenarios\n### US1 (P1) — x\n## Requirements\nnone yet\n## Success Criteria\n- SC-001: 95%.\n'"$F7"; istop "stop-intake: no FR-NNN coverage gap -> block" deny
isetup open interactive 5 $'## User Scenarios\nno stories\n## Requirements\n- FR-001: MUST x. (US1)\n## Success Criteria\n- SC-001: 95%.\n'"$F7"; istop "stop-intake: no US story coverage gap -> block" deny
# B+C — the F1 per-category VISIBILITY floor (G1/G2): every canonical category must carry an F2 disposition in
# the ## Deferrals ledger (presence, never adequacy). RED on the deployed hook (no sweep -> an
# under-dispositioned spec with a projection ALLOWS), GREEN on the candidate + FORGE_INTAKE_CATEGORIES.
UND_INLINE=$'# Understanding\n## What the FRs will build\nThe projection.'
UNDERDISP=$'## User Scenarios\n### US1 (P1) — x\n## Requirements\n- FR-001: MUST x. (US1)\n## Success Criteria\n- SC-001: 95%.\n## Deferrals / Out of scope\n- `functional-scope-behaviour` — covered by FR-001'
isetup open interactive 5 "$UNDERDISP" "$UND_INLINE";       istop "stop-intake: ledger disposes 1 of N canonical categories -> block (B+C visibility floor)" deny
# reverse/dangling direction: a full ledger PLUS a slug that is not a canonical id -> block (catches typos).
BOGUSDISP=$'## User Scenarios\n### US1 (P1) — x\n## Requirements\n- FR-001: MUST x. (US1)\n## Success Criteria\n- SC-001: 95%.\n'"$F7"$'\n- `not-a-real-category` — deliberately N/A — typo'
isetup open interactive 5 "$BOGUSDISP" "$UND_INLINE";       istop "stop-intake: ledger slug not a canonical id -> block (B+C reverse/dangling direction)" deny
# over-block guard: a FULLY-dispositioned ledger (every canonical category present) must ALLOW (fixtures 624 +
# the Gate-A block below also exercise this path now that OK_SPEC carries the full ledger).
isetup open interactive 5 "$OK_SPEC" "$UND_INLINE";         istop "stop-intake: fully-dispositioned ledger -> allow (visibility floor does not over-block)" allow
# B+C — the CATASTROPHIC-tier Stop nudge: a by-default catastrophic category (the registry tier, applied when
# no risk assignment exists) waved off as `deliberately N/A` must BLOCK. RED on deployed (no catastrophic
# check), GREEN on candidate + enum. The over-block guard above (OK_SPEC has by-default cats `covered`) proves
# the nudge does not false-block a properly-covered ledger.
CATAS_NA_LEDGER="$(jq -r '.categories[]? | if .id=="data-migration-schema-evolution" then "- `\(.id)` — deliberately N/A — waved off" elif .risk_default=="by-default" then "- `\(.id)` — covered by FR-001" else "- `\(.id)` — deliberately N/A — fixture default" end' "$CATS" 2>/dev/null)"
CATAS_NA=$'## User Scenarios\n### US1 (P1) — x\n## Requirements\n- FR-001: MUST x. (US1)\n## Success Criteria\n- SC-001: 95%.\n## Deferrals / Out of scope\n'"$CATAS_NA_LEDGER"
isetup open interactive 5 "$CATAS_NA" "$UND_INLINE";       istop "stop-intake: by-default catastrophic category waved off as N/A -> block (B+C catastrophic nudge)" deny
# B+C catastrophic LEAK guard: a `deliberately N/A` whose free-text REASON contains the
# keyword 'covered by'/'surfaced' must STILL block — the token-TYPE check anchors on the disposition token (field
# 2 after the id+em-dash), not the whole line. RED on the deployed hook (line-level grep ALLOWS); GREEN on candidate.
CATAS_LEAK_LEDGER="$(jq -r '.categories[]? | if .id=="data-migration-schema-evolution" then "- `\(.id)` — deliberately N/A — will be covered by a later phase" elif .risk_default=="by-default" then "- `\(.id)` — covered by FR-001" else "- `\(.id)` — deliberately N/A — fixture default" end' "$CATS" 2>/dev/null)"
CATAS_LEAK=$'## User Scenarios\n### US1 (P1) — x\n## Requirements\n- FR-001: MUST x. (US1)\n## Success Criteria\n- SC-001: 95%.\n## Deferrals / Out of scope\n'"$CATAS_LEAK_LEDGER"
isetup open interactive 5 "$CATAS_LEAK" "$UND_INLINE";     istop "stop-intake: catastrophic N/A whose reason says 'covered by' -> STILL block (token-anchored, not line-level)" deny
# over-block guard (the other direction): a genuine `surfaced — <ref>` whose REF text contains 'covered' must
# ALLOW — the disposition token is 'surfaced', so the anchored check must not false-block it.
CATAS_SURF_LEDGER="$(jq -r '.categories[]? | if .id=="data-migration-schema-evolution" then "- `\(.id)` — surfaced — covered in the design doc" elif .risk_default=="by-default" then "- `\(.id)` — covered by FR-001" else "- `\(.id)` — deliberately N/A — fixture default" end' "$CATS" 2>/dev/null)"
CATAS_SURF=$'## User Scenarios\n### US1 (P1) — x\n## Requirements\n- FR-001: MUST x. (US1)\n## Success Criteria\n- SC-001: 95%.\n## Deferrals / Out of scope\n'"$CATAS_SURF_LEDGER"
isetup open interactive 5 "$CATAS_SURF" "$UND_INLINE";     istop "stop-intake: catastrophic 'surfaced — <ref>' whose ref says 'covered' -> allow (token is 'surfaced'; no over-block)" allow
# Stage D (fork 3) — AUTONOMOUS surface-and-release: the SAME catastrophic-N/A spec in AUTONOMOUS mode must
# RELEASE (allow) — a catastrophic gap cannot be fixed by an absent human and there is no intake reaper, so the
# floor surfaces loudly and releases; the human-ratify bookend (cmd_ratify G3) is the gate. RED on deployed
# (B+C nudge blocks, no Stage-D arm), GREEN on candidate. Keyed on risk_halt (set only by the catastrophic sweep).
isetup open autonomous 5 "$CATAS_NA" "$UND_INLINE";       istop "stop-intake: AUTONOMOUS + catastrophic N/A -> RELEASE (surface-and-release; never wedge, never never-release)" allow
# trap #2 guard: AUTONOMOUS + a Gate-A fail (catastrophic CLEAN, so risk_halt UNSET) must STILL block —
# the autonomous arm is risk_halt-scoped and must NOT convert a protected Gate-A failure into a release.
# (Inline understanding/restatement: UND_OK/RST_OPEN are defined later, in the Gate-A section; set -u forbids
# a forward reference here in the F1 section.)
isetup open autonomous 5 "$OK_SPEC" "$UND_INLINE" $'# Restatement\n## Open findings\n- [ESCALATE] FR-007 — uncovered\n## History\n### Restatement round 1\nx'; istop "stop-intake: AUTONOMOUS + Gate-A open finding (risk_halt unset) -> still block (trap #2: arm is risk_halt-scoped, not [ -n fail ])" deny
isetup ratified interactive 5 "$OK_SPEC"$'\n[NEEDS CLARIFICATION: still dirty]';             istop "stop-intake: phase=ratified -> inert allow" allow
isetup open interactive 5 "$OK_SPEC"; rm -f "$IHD/active-intake.json";                       istop "stop-intake: no sentinel -> inert allow" allow
isetup open interactive 5 "$OK_SPEC"$'\n[NEEDS CLARIFICATION: x]'; assert "stop-intake: stop_hook_active backstop -> allow" allow '{"hook_event_name":"Stop","stop_hook_active":true}' FORGE_HARNESS_DIR="$IHD"
TARGET_HOOK=""

echo "== INTAKE Gate-A floor: understanding.md + consensus(open-DISAGREE==0) OR ## UNRECONCILED =="
TARGET_HOOK="$STOP_INTAKE"
UND_OK=$'# Understanding\n## What the FRs will build\nThe system persists a comment; failures surface a typed error.'
UND_NOPROJ=$'# Understanding\njust a stub — no projection header'
UND_UNREC=$'# Understanding\n## What the FRs will build\nThe projection.\n## UNRECONCILED — human input needed\n- FR-007 failure path: reviewer and I did not converge; the human must decide.'
RST_OPEN=$'# Restatement\n## Open findings\n- [ESCALATE] FR-007 — upstream-failure handling is uncovered\n## History\n### Restatement round 1\nreviewer flagged it'
RST_DONE=$'# Restatement\n## Open findings\n## History\n### Restatement round 1\nreviewer: AGREE'
RST_EXHAUSTED=$'# Restatement\n## Open findings\n- [ESCALATE] FR-007 — still uncovered\n## History\n### Restatement round 1\nx\n### Restatement round 2\nx\n### Restatement round 3\nx'
isetup open interactive 5 "$OK_SPEC";                              istop "gate-A: F1 clean but understanding.md MISSING -> block" deny
isetup open interactive 5 "$OK_SPEC" "$UND_NOPROJ";                istop "gate-A: understanding.md lacks projection header -> block" deny
isetup open interactive 5 "$OK_SPEC" "$UND_OK";                    istop "gate-A: understanding.md + no restatement (0 open) consensus -> allow" allow
isetup open interactive 5 "$OK_SPEC" "$UND_OK" "$RST_DONE";        istop "gate-A: understanding.md + restatement 0 open (consensus) -> allow" allow
isetup open interactive 5 "$OK_SPEC" "$UND_OK" "$RST_OPEN";        istop "gate-A: 1 open ESCALATE, under budget, no UNRECONCILED -> block" deny
isetup open interactive 5 "$OK_SPEC" "$UND_OK" "$RST_EXHAUSTED";   istop "gate-A: rounds exhausted + open + no UNRECONCILED -> block (forces ## UNRECONCILED)" deny
isetup open interactive 5 "$OK_SPEC" "$UND_UNREC" "$RST_EXHAUSTED"; istop "gate-A: open finding BUT non-empty ## UNRECONCILED -> allow (fail-closed; consensus not faked)" allow
# Stage E — the transcription trap CLOSED. An UNDER-TRANSCRIBED restatement.md (0 [DISAGREE] lines, but the
# loop ran) PLUS a HARNESS-CAPTURED record with open findings: deployed reads restatement.md (0 -> false
# consensus -> ALLOW = the trap); candidate reads the record (open -> BLOCK = closed). The isetup-derived
# record is OVERRIDDEN here with a DIVERGING one to prove the record — not the Architect's pen — is the oracle.
isetup open interactive 5 "$OK_SPEC" "$UND_OK" $'# Restatement\n### Restatement round 1\nreviewer ran; findings NOT transcribed'
jq -nc --arg ssha "$(sha256sum "$IHD/spec.md" | cut -d' ' -f1)" '{verdict:"DISAGREE",spec_sha256:$ssha,findings:[{id:"f1",category:"security-privacy",location:"FR-001",finding:"uncovered"}]}' >"$IHD/intake-spec-review.json"
istop "gate-A (Stage E): under-transcribed restatement but captured record has open findings -> block (record is the oracle)" deny
# over-block guard: a captured record (current spec) with verdict AGREE -> consensus -> allow (record drives it).
isetup open interactive 5 "$OK_SPEC" "$UND_OK" $'# Restatement\n### Restatement round 1\nreviewer: AGREE'
jq -nc --arg ssha "$(sha256sum "$IHD/spec.md" | cut -d' ' -f1)" '{verdict:"AGREE",spec_sha256:$ssha,findings:[]}' >"$IHD/intake-spec-review.json"
istop "gate-A (Stage E): captured record verdict AGREE -> allow (record consensus; no over-block)" allow
# Stage E STALENESS trap: a clean AGREE record whose spec_sha256 is STALE (reviewed an older spec). Deployed
# reads the consensus restatement -> ALLOW (the staleness hole); candidate's anti-TOCTOU sha check -> BLOCK.
isetup open interactive 5 "$OK_SPEC" "$UND_OK" $'# Restatement\n### Restatement round 1\nreviewer: AGREE'
printf '%s' '{"verdict":"AGREE","spec_sha256":"0000staleshaneverthecurrentspec0000","findings":[]}' >"$IHD/intake-spec-review.json"
istop "gate-A (Stage E): spec-review record with a STALE spec_sha256 -> block (anti-TOCTOU; spec changed since the review)" deny
TARGET_HOOK=""

echo "== INTAKE Gate-A: the .harness ratify token is Architect-UNWRITABLE (deny hook / ENFORCE_RE) =="
assert "ratify-token: Write .harness/intake-ratified.json -> deny" deny '{"tool_name":"Write","tool_input":{"file_path":".harness/intake-ratified.json","content":"{\"sha256\":\"forged\"}"}}'
assert "ratify-token: Edit .harness/intake-ratified.json -> deny" deny '{"tool_name":"Edit","tool_input":{"file_path":".harness/intake-ratified.json","old_string":"a","new_string":"b"}}'
assert "ratify-token: bash redirect into the token -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > .harness/intake-ratified.json"}}'

echo "== INTAKE Gate-A: intake.sh ratify is the agent-UN-runnable human sign-off (deny hook) =="
TARGET_HOOK="$DENY_SHIM"
assert "ratify-cmd: bash harness/intake.sh ratify -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"bash harness/intake.sh ratify"}}'
assert "ratify-cmd: intake.sh ratify <spec> -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"bash harness/intake.sh ratify specs/001-x/spec.md"}}'
assert "ratify-cmd: NARROW — intake.sh start allowed" allow '{"tool_name":"Bash","tool_input":{"command":"bash harness/intake.sh start obj --target r"}}'
assert "ratify-cmd: NARROW — intake.sh clarify allowed" allow '{"tool_name":"Bash","tool_input":{"command":"bash harness/intake.sh clarify"}}'
assert "ratify-cmd: NARROW — intake.sh convert allowed (gated by the human token)" allow '{"tool_name":"Bash","tool_input":{"command":"bash harness/intake.sh convert"}}'
TARGET_HOOK=""

echo "== INTAKE Gate-A: ratify-deny evasions closed (word boundary + narrow opaque-vector fail-closed) =="
TARGET_HOOK="$DENY_SHIM"
# Layer (a): every suffix/indirection/opaque-vector form the review demonstrated ALLOWED pre-fix -> DENY.
assert "ratify-cmd evasion: trailing ; -> deny"            deny  '{"tool_name":"Bash","tool_input":{"command":"harness/intake.sh ratify;"}}'
assert "ratify-cmd evasion: trailing & -> deny"            deny  '{"tool_name":"Bash","tool_input":{"command":"harness/intake.sh ratify&"}}'
assert "ratify-cmd evasion: || true suffix -> deny"        deny  '{"tool_name":"Bash","tool_input":{"command":"harness/intake.sh ratify||true"}}'
assert "ratify-cmd evasion: bash -c wrapper string -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"bash -c \"harness/intake.sh ratify\""}}'
assert "ratify-cmd evasion: variable indirection -> deny"  deny  '{"tool_name":"Bash","tool_input":{"command":"Q=harness/intake.sh; $Q ratify"}}'
assert "ratify-cmd evasion: eval+subshell -> deny"         deny  '{"tool_name":"Bash","tool_input":{"command":"eval \"$(printf %s '\''harness/intake.sh ratify'\'')\""}}'
# The narrow fail-closed must NOT over-deny: a $-bearing intake command WITHOUT ratify stays allowed.
assert "ratify-cmd evasion: intake.sh start \$OBJ (no ratify) -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"harness/intake.sh start \"$OBJ\""}}'
assert "ratify-cmd evasion: intake.sh analyze \$(…) (no ratify) -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"harness/intake.sh analyze \"$(cat p)\""}}'
assert "ratify-cmd evasion: intake.sh ratifyx (word boundary) -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"harness/intake.sh ratifyx"}}'
# `bash wrapper.sh` (the call hidden in a file) has no ratify/intake.sh substring -> the hook CANNOT catch
# it; closure is cmd_ratify's TTY gate, proven in tests/intake/run.sh. Confirm the hook allows it (honest).
assert "ratify-cmd evasion: bash wrapper.sh -> allow at hook (closed by the TTY gate, not the string matcher)" allow '{"tool_name":"Bash","tool_input":{"command":"bash specs/001-x/wrapper.sh"}}'

# ratify-breakdown is the human's Gate-A′ sign-off — DEFENSE-IN-DEPTH alongside ratify
# (the real guarantee is cmd_ratify_breakdown's own TTY gate). The deny rule extends the reserved token to
# `ratify(-breakdown)?`, so the SAME word-boundary + opaque-vector closure now covers the breakdown gate.
# RED vs the deployed hook (token is bare `ratify`; the `-` boundary means deployed does NOT match
# `ratify-breakdown`), GREEN vs the candidate — the deny rule must land WITH the intake.sh command.
echo "== INTAKE Gate-A′: intake.sh ratify-breakdown is the agent-UN-runnable human sign-off (deny hook) =="
assert "ratify-breakdown-cmd: bash harness/intake.sh ratify-breakdown -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"bash harness/intake.sh ratify-breakdown"}}'
assert "ratify-breakdown-cmd: intake.sh ratify-breakdown <spec> -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"bash harness/intake.sh ratify-breakdown specs/001-x/spec.md"}}'
assert "ratify-breakdown-cmd evasion: trailing ; -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"harness/intake.sh ratify-breakdown;"}}'
assert "ratify-breakdown-cmd evasion: bash -c wrapper string -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"bash -c \"harness/intake.sh ratify-breakdown\""}}'
# Word boundary stays honest: ratify-breakdownx is not the command -> allow (mirrors ratifyx at line ~680).
assert "ratify-breakdown-cmd evasion: intake.sh ratify-breakdownx (word boundary) -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"harness/intake.sh ratify-breakdownx"}}'
TARGET_HOOK=""

echo "== deny hook: jq-presence guard — fail CLOSED when jq is absent =="
# A PATH carrying the tools the hook reaches BEFORE the jq check (dirname/pwd via the shebangless `bash
# <hook>` entry) but NOT jq -> the entry guard must exit non-zero (deny), never fall through to allow.
JQSTUB="$(mktemp -d -p "$INTAKE_TMP")"
# Mirror the current PATH minus jq, so the ONLY missing tool is jq — every other tool the hook reaches
# (grep/sed/dirname/…) stays available, or the deployed hook would error for the wrong reason and the
# differential would be muddy (an incomplete stub does NOT prove the guard).
for d in $(printf '%s' "$PATH" | tr ':' '\n'); do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    [ "$b" = jq ] && continue
    [ -e "$JQSTUB/$b" ] || ln -s "$f" "$JQSTUB/$b" 2>/dev/null
  done
done
# (this suite scores with inline PASS/FAIL — it has no ok/no helpers; those live in tests/intake/run.sh.)
if PATH="$JQSTUB" command -v jq >/dev/null 2>&1; then FAIL=$((FAIL + 1)); printf 'FAIL [jq stub must NOT expose jq (precondition)]\n'; else PASS=$((PASS + 1)); fi
jqguard_out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | PATH="$JQSTUB" bash "${DENY}" 2>&1)"; jqguard_rc=$?
if [ "$jqguard_rc" -ne 0 ] && printf '%s' "$jqguard_out" | grep -qF "jq not found"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL [deny hook fail-closes when jq absent (rc=%s; got: %s)]\n' "$jqguard_rc" "$jqguard_out"; fi

echo "== INTAKE clarify-gate (pre-tool-use-clarify-gate.sh): real-time enhancement (canary-PASS) =="
TARGET_HOOK="$CLARIFY_GATE"
AUQ='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"q1"}]}}'
AUQ5='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"a"},{"question":"b"},{"question":"c"},{"question":"d"},{"question":"e"}]}}'
isetup open interactive 5 "$OK_SPEC";                       assert "clarify-gate: within budget -> allow" allow "$AUQ" FORGE_HARNESS_DIR="$IHD"
isetup open autonomous 5 "$OK_SPEC";                        assert "clarify-gate: autonomous -> deny" deny "$AUQ" FORGE_HARNESS_DIR="$IHD"
isetup open interactive 5 "$OK_SPEC";                       assert "clarify-gate: >4 questions/call -> deny" deny "$AUQ5" FORGE_HARNESS_DIR="$IHD"
isetup open interactive 5 "$OK_SPEC"$'\n'"$R5"; printf '5' >"$IHD/intake-clarify-rounds";                            assert "clarify-gate: budget exhausted -> deny" deny "$AUQ" FORGE_HARNESS_DIR="$IHD"
isetup open interactive 5 "$OK_SPEC"$'\n## Clarifications\n### Round 1 — d'; printf '2' >"$IHD/intake-clarify-rounds"; assert "clarify-gate: ask>record coupling -> deny" deny "$AUQ" FORGE_HARNESS_DIR="$IHD"
isetup open interactive 5 "$OK_SPEC"$'\n'"$R5"; printf '5' >"$IHD/intake-clarify-rounds"; printf '1' >"$IHD/intake-clarify-grant"; assert "clarify-gate: human grant lifts budget -> allow" allow "$AUQ" FORGE_HARNESS_DIR="$IHD"
NOI="$(mktemp -d -p "$INTAKE_TMP")";                        assert "clarify-gate: no active intake -> passthrough allow" allow "$AUQ" FORGE_HARNESS_DIR="$NOI"
isetup open interactive 5 "$OK_SPEC";                       assert "clarify-gate: non-AskUserQuestion tool -> passthrough allow" allow '{"tool_name":"Bash","tool_input":{"command":"ls"}}' FORGE_HARNESS_DIR="$IHD"
TARGET_HOOK=""

echo "== fx-w5x: intake specs/** ALLOWLIST + self-rewrite deny + Bash-write confinement =="
# Sentinel fixtures: FORGE_HARNESS_DIR carries which lifecycle is armed (forge_*_active honor it).
WIHD="$(mktemp -d -p "$INTAKE_TMP")" # intake armed, no build task
jq -nc --arg s "$WIHD/spec.md" '{spec:$s,mode:"interactive",phase:"open"}' >"$WIHD/active-intake.json"
WBHD="$(mktemp -d -p "$INTAKE_TMP")" # build task armed, no intake
printf '{"task":"t","branch":"task/x"}' >"$WBHD/active-task.json"
WDHD="$(mktemp -d -p "$INTAKE_TMP")" # BOTH armed (task must win — intake confinement yields)
jq -nc --arg s "$WDHD/spec.md" '{spec:$s,mode:"interactive",phase:"open"}' >"$WDHD/active-intake.json"
printf '{"task":"t","branch":"task/x"}' >"$WDHD/active-task.json"
# Tool-path tier (Write/Edit/NotebookEdit), intake armed:
assert "fx-w5x: intake + Write specs/ spec -> allow" allow '{"tool_name":"Write","tool_input":{"file_path":"specs/001-x/spec.md","content":"x"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: intake + Edit specs/ understanding -> allow" allow '{"tool_name":"Edit","tool_input":{"file_path":"specs/001-x/understanding.md","old_string":"a","new_string":"b"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: intake + Write absolute \$proj/specs -> allow" allow "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$ROOT/specs/001-x/spec.md\",\"content\":\"x\"}}" FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: intake + Write README.md -> deny (allowlist)" deny '{"tool_name":"Write","tool_input":{"file_path":"README.md","content":"x"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: intake + Write NOVEL top-level path -> deny (closed-by-construction)" deny '{"tool_name":"Write","tool_input":{"file_path":"newtopdir/file.ts","content":"x"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: SELF-REWRITE intake + Write .claude/agents -> deny" deny '{"tool_name":"Write","tool_input":{"file_path":".claude/agents/architect.md","content":"x"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: SELF-REWRITE intake + Edit .claude/skills -> deny" deny '{"tool_name":"Edit","tool_input":{"file_path":".claude/skills/clarify/SKILL.md","old_string":"a","new_string":"b"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: SELF-REWRITE intake + Write .claude/commands -> deny" deny '{"tool_name":"Write","tool_input":{"file_path":".claude/commands/go.md","content":"x"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: intake + Write specs/../ traversal -> deny" deny '{"tool_name":"Write","tool_input":{"file_path":"specs/../README.md","content":"x"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: intake + NotebookEdit outside specs -> deny (notebook_path gap closed)" deny '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"notes.ipynb","new_source":"x"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x: intake + NotebookEdit inside specs -> allow" allow '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"specs/001-x/nb.ipynb","new_source":"x"}}' FORGE_HARNESS_DIR="$WIHD"
NOSENT="$(mktemp -d -p "$INTAKE_TMP")"
assert "fx-w5x: NO sentinel + Write README.md -> allow (universal floor only)" allow '{"tool_name":"Write","tool_input":{"file_path":"README.md","content":"x"}}' FORGE_HARNESS_DIR="$NOSENT"
# BUILDER GUARDS — the over-confinement fixtures (a red here = intake confinement broke the build loop):
assert "fx-w5x: BUILDER GUARD task-only + Write sandbox -> allow" allow '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/x.ts","content":"x"}}' FORGE_HARNESS_DIR="$WBHD"
assert "fx-w5x: task-only + Write specs -> deny (build sandbox confinement unchanged)" deny '{"tool_name":"Write","tool_input":{"file_path":"specs/001-x/spec.md","content":"x"}}' FORGE_HARNESS_DIR="$WBHD"
assert "fx-w5x: BUILDER GUARD task-only + bash write into sandbox -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"echo x > sandbox/log.txt"}}' FORGE_HARNESS_DIR="$WBHD"
assert "fx-w5x: BOTH sentinels + Write sandbox -> allow (task wins; not-a-build-task guard)" allow '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/x.ts","content":"x"}}' FORGE_HARNESS_DIR="$WDHD"
assert "fx-w5x: BOTH sentinels + Write README.md -> deny" deny '{"tool_name":"Write","tool_input":{"file_path":"README.md","content":"x"}}' FORGE_HARNESS_DIR="$WDHD"
# Bash-write tier, intake armed (redirects + mutators via the re-run walkers):
assert "fx-w5x bash: intake + redirect into specs -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"echo note > specs/001-x/notes.md"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: intake + append into specs -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"printf x >> specs/001-x/spec.md"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: intake + redirect outside specs -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > README.md"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: intake + cp into .claude/agents -> deny (self-rewrite, bash flavor)" deny '{"tool_name":"Bash","tool_input":{"command":"cp draft.md .claude/agents/architect.md"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: intake + tee outside specs -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"echo x | tee newtopdir/out.log"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: intake + mv within specs -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"mv specs/001-x/a.md specs/001-x/b.md"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: intake + redirect specs/../ traversal -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > specs/../evil.md"}}' FORGE_HARNESS_DIR="$WIHD"
# sed -i's write target is the argv-identifiable FILE operand: in-specs file is a
# legitimate in-allowlist write (consistent with the echo/printf/mv in-specs writes above); out-of-specs
# file still DENYs (the file-operand boundary holds — this is the non-vacuous pin replacing the old
# operand-conservative over-block, which denied via mis-classifying the bare script `s/a/b/` as a path).
# sed's script-embedded w/s///w write (target named inside the script) is program-internal, argv-
# undetectable -> container-deferred; pinned as a residual in tests/escape-classes.
assert "fx-w5x bash: intake + sed -i on an IN-specs file -> allow (file operand argv-identifiable, in allowlist)" allow '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ specs/001-x/spec.md"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: intake + sed -i on an OUT-OF-specs file -> deny (file-operand boundary holds)" deny '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ README.md"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: intake + read-only command -> allow (no write targets)" allow '{"tool_name":"Bash","tool_input":{"command":"grep -n FR- specs/001-x/spec.md"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: intake + harness intake clarify -> allow (harness commands stay runnable)" allow '{"tool_name":"Bash","tool_input":{"command":"bash harness/intake.sh clarify"}}' FORGE_HARNESS_DIR="$WIHD"
assert "fx-w5x bash: NO sentinel + redirect outside specs -> allow (floor only)" allow '{"tool_name":"Bash","tool_input":{"command":"echo x > README.md"}}' FORGE_HARNESS_DIR="$NOSENT"
# Builder-tier traversal fold-in: sandbox/../x matched the sandbox/* glob — a live escape of the
# BUILD confinement until the task-tier '..' arm; the allow-pair guards against over-confinement.
assert "fx-w5x: TASK-tier traversal — task + Write sandbox/../README.md -> deny" deny '{"tool_name":"Write","tool_input":{"file_path":"sandbox/../README.md","content":"x"}}' FORGE_HARNESS_DIR="$WBHD"
assert "fx-w5x: task + Write sandbox/src/ok.ts -> allow (traversal arm does not over-confine)" allow '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/ok.ts","content":"x"}}' FORGE_HARNESS_DIR="$WBHD"
# Layer attribution for Bash '..': with NO sentinel the intake guard is entirely inert, so a deny here
# proves the universal ambiguous class is the LOAD-BEARING layer for Bash traversal (the intake-tier
# '*..*' arm is redundant depth behind it).
assert "fx-w5x bash: NO sentinel + redirect specs/../ -> deny (universal ambiguous layer load-bearing)" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > specs/../evil.md"}}' FORGE_HARNESS_DIR="$NOSENT"
# new_source is NotebookEdit's written-content field — previously unread by the content scan, so a secret
# written into a notebook cell slipped the secret rules. The secret is RUNTIME-ASSEMBLED so this test file
# never carries a secret-shaped literal (the live hook rightly denies edits that do); the hook receives the
# ASSEMBLED literal in new_source and must deny it by STATIC scan. No sentinel: only the universal secret
# scan can be the denier.
SK_RT="sk-$(printf 'a%.0s' {1..28})"
assert "fx-w5x: NotebookEdit new_source secret -> deny (content scan covers new_source)" deny "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"specs/001-x/nb.ipynb\",\"new_source\":\"key = $SK_RT\"}}" FORGE_HARNESS_DIR="$NOSENT"

echo

echo "== work_root: TARGET-build write confinement + task Bash-write gap closure + fail-closed =="
# Fixtures: a forge-managed target worktree (RESOLVED-ABSOLUTE) recorded as work_root in the task
# sentinel. The deny hook matches it as an absolute prefix; existence is irrelevant (textual match).
WT_TGT="$(mktemp -d -p "$INTAKE_TMP")"                          # stands in for the resolved-absolute target worktree
WTGTHD="$(mktemp -d -p "$INTAKE_TMP")"                          # task armed, TARGET mode (sentinel carries work_root)
jq -nc --arg w "$WT_TGT" '{task:"t",branch:"task/x",work_root:$w}' >"$WTGTHD/active-task.json"
WBADHD="$(mktemp -d -p "$INTAKE_TMP")"                          # task armed, MALFORMED sentinel
printf 'not-json{' >"$WBADHD/active-task.json"
WRELHD="$(mktemp -d -p "$INTAKE_TMP")"                          # task armed, NON-ABSOLUTE work_root
jq -nc '{task:"t",branch:"task/x",work_root:"relative/wt"}' >"$WRELHD/active-task.json"

# --- target-build: PERMIT in-worktree (Write/Edit tier) ---
assert "work_root: target + Write abs under worktree -> allow" allow "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WT_TGT/src/index.html\",\"content\":\"<h1>hi</h1>\"}}" FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Write relative -> deny (control-plane-side cwd; require abs under work_root)" deny '{"tool_name":"Write","tool_input":{"file_path":"src/index.html","content":"x"}}' FORGE_HARNESS_DIR="$WTGTHD"
# --- target-build: DENY out-of-worktree (Write/Edit tier) ---
assert "work_root: target + Write abs OUTSIDE worktree (forge file) -> deny" deny "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$ROOT/README.md\",\"content\":\"x\"}}" FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Write abs sibling repo -> deny" deny '{"tool_name":"Write","tool_input":{"file_path":"/tmp/sibling-repo/x","content":"x"}}' FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Write ..-traversal -> deny" deny "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WT_TGT/../escape\",\"content\":\"x\"}}" FORGE_HARNESS_DIR="$WTGTHD"
# --- target-build: universal denies STILL subtract inside/around work_root (guardrail ii) ---
assert "work_root: target + Write .beads ledger -> deny (universal on top)" deny '{"tool_name":"Write","tool_input":{"file_path":".beads/issues.jsonl","content":"x"}}' FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Write relative harness/ -> deny (ENFORCE_RE on top)" deny '{"tool_name":"Write","tool_input":{"file_path":"harness/x.sh","content":"x"}}' FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Write abs .git under worktree -> deny (.git universal)" deny "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WT_TGT/.git/config\",\"content\":\"x\"}}" FORGE_HARNESS_DIR="$WTGTHD"

# --- target-build: PERMIT in-worktree (Bash tier) — the CRITICAL new coverage (was unguarded) ---
assert "work_root: target + Bash redirect under worktree -> allow" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $WT_TGT/src/y\"}}" FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Bash relative redirect -> deny (control-plane-side cwd; require abs under work_root)" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > src/y"}}' FORGE_HARNESS_DIR="$WTGTHD"
# --- target-build: DENY out-of-worktree (Bash tier) — the gap that routed around the path tier ---
assert "work_root: target + Bash cp to abs sibling -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"cp evil /tmp/sibling-repo/x"}}' FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Bash echo to forge file -> deny" deny "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $ROOT/README.md\"}}" FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Bash mv outside worktree -> deny" deny "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv $WT_TGT/a /tmp/elsewhere/b\"}}" FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Bash tee outside worktree -> deny" deny '{"tool_name":"Bash","tool_input":{"command":"echo x | tee /tmp/elsewhere/out"}}' FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Bash redirect ..-traversal -> deny" deny "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $WT_TGT/../escape\"}}" FORGE_HARNESS_DIR="$WTGTHD"
assert "work_root: target + Bash write to harness -> deny (universal on top)" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > harness/run-task.sh"}}' FORGE_HARNESS_DIR="$WTGTHD"
# --- target-build: read-only Bash still allowed (not over-confined) ---
assert "work_root: target + Bash read-only -> allow" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $WT_TGT/src/index.html\"}}" FORGE_HARNESS_DIR="$WTGTHD"

# --- SELF-BUILD gap closure (legacy WBHD: no work_root) — the Bash tier now confines to sandbox/ too ---
assert "work_root: self + Bash write to sandbox -> allow (legacy unchanged)" allow '{"tool_name":"Bash","tool_input":{"command":"echo x > sandbox/log.txt"}}' FORGE_HARNESS_DIR="$WBHD"
assert "work_root: self + Bash cp OUTSIDE sandbox -> deny (GAP CLOSED)" deny '{"tool_name":"Bash","tool_input":{"command":"cp evil /tmp/escape"}}' FORGE_HARNESS_DIR="$WBHD"
assert "work_root: self + Bash echo to forge file -> deny (GAP CLOSED)" deny "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > $ROOT/README.md\"}}" FORGE_HARNESS_DIR="$WBHD"
assert "work_root: self + Write outside sandbox -> deny (legacy path tier unchanged)" deny '{"tool_name":"Write","tool_input":{"file_path":"README.md","content":"x"}}' FORGE_HARNESS_DIR="$WBHD"

# --- FAIL-CLOSED: malformed sentinel denies WRITES (both tiers), NOT reads ---
assert "work_root: malformed sentinel + Write -> deny (fail closed)" deny '{"tool_name":"Write","tool_input":{"file_path":"sandbox/src/x.ts","content":"x"}}' FORGE_HARNESS_DIR="$WBADHD"
assert "work_root: malformed sentinel + Bash write -> deny (fail closed)" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > sandbox/y"}}' FORGE_HARNESS_DIR="$WBADHD"
assert "work_root: malformed sentinel + Bash read -> allow (not over-denied)" allow '{"tool_name":"Bash","tool_input":{"command":"cat sandbox/x"}}' FORGE_HARNESS_DIR="$WBADHD"
# --- FAIL-CLOSED: present-but-non-absolute work_root denies WRITES (both tiers) ---
assert "work_root: non-abs work_root + Write -> deny (fail closed)" deny '{"tool_name":"Write","tool_input":{"file_path":"relative/wt/x","content":"x"}}' FORGE_HARNESS_DIR="$WRELHD"
assert "work_root: non-abs work_root + Bash write -> deny (fail closed)" deny '{"tool_name":"Bash","tool_input":{"command":"echo x > relative/wt/y"}}' FORGE_HARNESS_DIR="$WRELHD"

echo "== F8: cmd_finish's commit trailer is byte-exact =="
F8RT="$ROOT/harness/run-task.sh"
F8CO="$(grep -c 'Co-Authored-By:' "$F8RT" 2>/dev/null || echo 0)"
if [ "$F8CO" = "1" ] && grep -qF 'Co-Authored-By: Claude <noreply@anthropic.com>' "$F8RT"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); printf 'FAIL [F8 commit trailer byte-exact]\n  expected exactly one "Co-Authored-By: Claude <noreply@anthropic.com>"; got %s Co-Authored-By line(s)\n' "$F8CO"
fi

echo "== real-sentinel integrity guard (the suite must not touch the live task state) =="
REAL_TASK_AFTER="$(real_task_state)"
if [ "$REAL_TASK_BEFORE" = "$REAL_TASK_AFTER" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL [real .harness task state CHANGED across the suite — sentinel isolation regressed (before=%s after=%s)]\n' \
    "$REAL_TASK_BEFORE" "$REAL_TASK_AFTER"
fi

echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" = "0" ]
