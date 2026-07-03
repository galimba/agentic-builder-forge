#!/usr/bin/env bash
# H3 target-build PR purity: the index-logic unit suite (NO docker). Proves the finish-local
# SUPERSET classifier + strip + the PROOF (forge_assert_target_pure is the GUARANTEE). RED-first: the helpers
# live in sandbox-lib.sh; against the DEPLOYED lib they are ABSENT (RED), against the candidate they are present
# (GREEN). Override the sourced sandbox-lib with FORGE_DMF_SANDBOXLIB to prove GREEN before the door splice.
#
#   bash tests/pristine/run.sh                                   # vs deployed (RED until the splice lands)
#   FORGE_DMF_SANDBOXLIB=<candidate-lib> bash tests/pristine/run.sh   # prove a door candidate before its splice
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; ROOT="$(dirname "$_gcd")"; unset _gcd
# F-C: test the DEPLOYED harness/sandbox-lib.sh by default — a test must verify what SHIPS,
# never an untracked candidate. Override with FORGE_DMF_SANDBOXLIB to prove a door candidate before its splice
# (the RED proof points it at the deployed pre-fix lib; this default is GREEN only once the fix is spliced).
SBLIB="${FORGE_DMF_SANDBOXLIB:-$ROOT/harness/sandbox-lib.sh}"
case "$SBLIB" in /*) : ;; *) SBLIB="$ROOT/$SBLIB" ;; esac
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh)"

# the H3 helpers reuse the read-only forge_norm_path/forge_enforce_class (lib.sh) + the safe-git primitives
# (sandbox-lib); source BOTH (lib.sh first), exactly as run-task does.
. "$ROOT/.claude/hooks/lib.sh"
. "$SBLIB"

if ! type forge_is_forge_path >/dev/null 2>&1; then
  bad "forge_is_forge_path ABSENT (RED until the sandbox-lib H3 door splice lands; re-run with FORGE_DMF_SANDBOXLIB=...cand.sh to prove GREEN)" ""
  echo "==== pristine (H3 unit): $P passed, $F failed ===="; exit 1
fi

echo "== A1: forge_is_forge_path — the D2 SUPERSET classifier =="
# IMPURE (forge artifacts) — incl. the SUPERSET case .claude/agents/* (forge_enforce_class alone calls it 'ok')
# + F-A: NESTED .claude at any depth (apps/web/.claude/agents/x — the website-E2E case the
#   first-segment check missed; forge_enforce_class only catches nested .claude/hooks + .claude/settings*).
for p in ".claude/agents/evil.md" ".claude/hooks/lib.sh" ".claude/settings.json" ".beads/issues.jsonl" \
         "harness/run-task.sh" ".harness/pr/x.json" ".git/config" "sub/.harness/x" "deep/harness/x.sh" "a/.git/y" \
         "apps/web/.claude/agents/evil.md" "src/.claude/commands/x.md" "a/.claude/skills/y/SKILL.md"; do
  forge_is_forge_path "$p" && ok "IMPURE: $p" || bad "should be IMPURE (forge artifact): $p" ""
done
# PURE (legitimate product) — incl. the over-match GUARD: a path that merely CONTAINS "claude" is NOT a .claude
# segment (src/claudefile.txt, myclaude/x, foo/bar.claude/x, .claudeX/y, claude/agents/x without the dot) -> PURE.
for p in "index.html" "src/app.js" "about.html" "README.md" "assets/logo.png" "claudefile.txt" "harnesses/x" ".clauderc" \
         "src/claudefile.txt" "myclaude/x" "foo/bar.claude/x" ".claudeX/y" "claude/agents/x"; do
  forge_is_forge_path "$p" && bad "should be PURE (product): $p" "" || ok "PURE: $p"
done

echo "== A2: forge_strip_forge_artifacts — index-only unstage of forge paths (worktree file kept) =="
T="$(mktemp -d)"; trap 'rm -rf "$T" "${T4:-}" 2>/dev/null' EXIT
( cd "$T" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base )
mkdir -p "$T/src" "$T/.claude/agents" "$T/.beads" "$T/harness" "$T/.harness/pr"
printf 'x\n' > "$T/index.html"; printf 'x\n' > "$T/src/app.js"
printf 'x\n' > "$T/.claude/agents/evil.md"; printf 'x\n' > "$T/.beads/x.json"
printf 'x\n' > "$T/harness/evil.sh"; printf 'x\n' > "$T/.harness/pr/x.json"
GD="$(forge_safe_gitdir "$T")"
forge_safe_git_stage "$T" "$GD" add index.html src/app.js .claude .beads harness .harness 2>/dev/null
before="$(forge_safe_git "$T" "$GD" diff --cached --name-only | sort | tr '\n' ' ')"
forge_strip_forge_artifacts "$T" "$GD" && ok "strip rc0" || bad "strip rc!=0" ""
after="$(forge_safe_git "$T" "$GD" diff --cached --name-only | sort | tr '\n' ' ')"
[ "$after" = "index.html src/app.js " ] && ok "after strip: ONLY product staged ($after)" || bad "strip left/dropped wrong set" "before=[$before] after=[$after]"
{ [ -f "$T/.claude/agents/evil.md" ] && [ -f "$T/harness/evil.sh" ]; } && ok "stripped worktree files KEPT for diagnosis (index-only)" || bad "strip deleted worktree files (should be index-only)" ""

echo "== A3: forge_assert_target_pure — the GUARANTEE (pure->0, impure->1+reason, unverifiable->1) =="
forge_assert_target_pure "$T" "$GD" >/dev/null 2>&1 && ok "pure staged index -> rc0 (proceed)" || bad "pure index wrongly refused" ""
# IMPURE: stage a forge artifact directly (bypassing the strip) — the assert MUST refuse, no matter how it got staged
forge_safe_git_stage "$T" "$GD" add .beads/x.json 2>/dev/null
out="$(forge_assert_target_pure "$T" "$GD" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "purity check FAILED"; } && ok "IMPURE index (forge artifact survived strip) -> die (rc$rc, named the artifact)" || bad "assert did NOT fail-closed on an impure index" "rc=$rc out=$out"
# the named offender is the actual path
printf '%s' "$out" | grep -qF ".beads/x.json" && ok "the refusal NAMES the surviving artifact (.beads/x.json)" || bad "refusal did not name the offender" "$out"
# unverifiable: a broken gitdir -> enumeration fails -> fail-closed
forge_assert_target_pure "$T" "/nonexistent/gitdir" >/dev/null 2>&1 && bad "unverifiable (broken gitdir) wrongly passed" "" || ok "unverifiable (enumeration error) -> rc1 (fail closed)"

echo "== A4: the survival vectors — F-A nested .claude + F-B git-quoted special chars (REAL strip+assert) =="
# RED on the deployed pre-fix lib (nested .claude rides in; the quoted tab/non-ASCII path defeats the classifier
# via the leading "); GREEN once apply-sandboxlib-h3-v2 lands (nested arm + -z NUL enumeration).
T4="$(mktemp -d)"
( cd "$T4" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base )
mkdir -p "$T4/src" "$T4/.claude/agents" "$T4/apps/web/.claude/agents" "$T4/apps/web/.claude/commands"
printf 'x\n' > "$T4/index.html"; printf 'x\n' > "$T4/src/app.js"
printf 'r\n' > "$T4/.claude/agents/evil.md"                  # root .claude (already caught)
printf 'a\n' > "$T4/apps/web/.claude/agents/evil.md"         # F-A nested
printf 'a\n' > "$T4/apps/web/.claude/commands/x.md"          # F-A nested
printf 'b\n' > "$T4/.claude/agents/$(printf 'ev\til').md"    # F-B: git QUOTES a tab path (core.quotePath)
printf 'b\n' > "$T4/.claude/agents/évil.md"                  # F-B: git QUOTES a non-ASCII path
GD4="$(forge_safe_gitdir "$T4")"
forge_safe_git_stage "$T4" "$GD4" add -A 2>/dev/null
forge_strip_forge_artifacts "$T4" "$GD4" >/dev/null 2>&1
after4="$(forge_safe_git "$T4" "$GD4" diff --cached --name-only -z | tr '\0' '\n')"
printf '%s\n' "$after4" | grep -q '\.claude' && bad "A4: strip LEFT a .claude artifact (F-A/F-B survival)" "$after4" || ok "A4: strip removed ALL .claude (nested + tab + non-ASCII + root)"
{ printf '%s\n' "$after4" | grep -qx "index.html" && printf '%s\n' "$after4" | grep -qx "src/app.js"; } && ok "A4: product files survived the strip" || bad "A4: strip dropped product" "$after4"
forge_assert_target_pure "$T4" "$GD4" >/dev/null 2>&1 && ok "A4: assert rc0 on the cleaned index" || bad "A4: assert wrongly refused the cleaned index" ""
forge_safe_git_stage "$T4" "$GD4" add apps/web/.claude/agents/evil.md 2>/dev/null
forge_assert_target_pure "$T4" "$GD4" >/dev/null 2>&1 && bad "A4: assert PASSED a residual NESTED .claude (F-A guarantee defeated)" "" || ok "A4: assert fail-closes on a residual nested .claude"

FLOOR_POST="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact (lib.sh untouched)" || bad "LIVE FLOOR CHANGED" ""
echo "==== pristine (H3 unit): $P passed, $F failed ===="
[ "$F" -eq 0 ]
