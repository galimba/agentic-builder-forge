#!/usr/bin/env bash
# FOLD #14 — the eval-INDIRECTION selector validator (cardinal lib.sh / deny-floor change, same
# family as the witness-fsmonitor vector). Three sites flow an ATTACKER-INFLUENCEABLE selector into an
# `eval "<X>=\${${SEL}_<KEY>:-}"` indirection (and, for TARGET, into `eval "$TEST_CMD"` host-side at
# run-task.sh): forge_load_target (.claude/hooks/lib.sh) honours an inherited TARGET; review-task.sh
# honours REVIEWER_BACKEND (config-load) and DISPOSITION_BACKEND (the 2b tail). A metacharacter selector
# (e.g. `x:-$(cmd)`) command-SUBSTITUTES at the eval; a benign selector + a poisoned `<sel>_<KEY>` injects
# the value. The fix validates the selector against an allowlist BEFORE the eval (forge_validate_selector
# in lib.sh for TARGET; an inline membership guard in review-task.sh for the backends, which stays self-
# contained against the reviewer test harness's DEPLOYED lib.sh copy).
#
# SEAMS (default = the DEPLOYED tree -> RED-until-splice pin; point them at the candidate to prove GREEN):
#   FORGE_BOUNDARY_LIB      the lib.sh under test (forge_load_target + forge_validate_selector)
#   FORGE_BOUNDARY_REVIEW   the review-task.sh under test (the inline backend guard)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
LIB="${FORGE_BOUNDARY_LIB:-$LIVE_ROOT/.claude/hooks/lib.sh}"
REVIEW="${FORGE_BOUNDARY_REVIEW:-$LIVE_ROOT/harness/review-task.sh}"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"

# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || { echo "fold14: cannot source $LIB" >&2; exit 1; }

echo "== FOLD #14: forge_load_target — the TARGET selector (lib.sh) =="
# 1a — the *_TEST_CMD sink: an agent-exported foreign TARGET selecting an agent-defined command.
out="$( export TARGET=pwned; export pwned_TEST_CMD="AGENT_PAYLOAD_MARKER"
        . "$LIB" >/dev/null 2>&1
        forge_load_target >/dev/null 2>&1
        printf '%s' "${TEST_CMD:-}" )"
if [ "$out" = "AGENT_PAYLOAD_MARKER" ]; then
  bad "1a *_TEST_CMD sink OPEN: forge_load_target eval'd the agent-injected pwned_TEST_CMD into TEST_CMD" "fix = validate TARGET against the targets.config allowlist before the evals"
else
  ok "1a foreign TARGET 'pwned' rejected before the eval (TEST_CMD=[$out])"
fi

# 1b — the metacharacter-TARGET SUBSTITUTION sink (lib.sh:50 itself): a `$(...)` in TARGET must NOT run.
SUB="$(mktemp -d)"; MARK="$SUB/FIRED"
( export TARGET='x:-$(touch '"$MARK"')'
  . "$LIB" >/dev/null 2>&1
  forge_load_target >/dev/null 2>&1 ) >/dev/null 2>&1
if [ -e "$MARK" ]; then
  bad "1b SUBSTITUTION sink OPEN: a metacharacter TARGET command-substituted at the eval (lib.sh:50)" "fix = reject the non-allowlisted TARGET before any eval"
else
  ok "1b metacharacter TARGET 'x:-\$(touch …)' did NOT command-substitute"
fi
rm -rf "$SUB"

# 1e — OVER-BLOCK guard: forge_load_target must STILL ACCEPT every legit config-declared TARGET via the
# sed-parsed allowlist. A broken sed that emptied the allowlist would refuse EVERY target (total task-run
# over-block) yet still pass 1a/1b/1c/1d — this guard turns that regression RED.
_lt(){ ( export TARGET="$1"; . "$LIB" >/dev/null 2>&1; forge_load_target >/dev/null 2>&1; printf '%s' "${TEST_CMD:-}" ); }
[ "$(_lt typescript)" = "pnpm test" ] && ok "1e legit TARGET 'typescript' still loads (TEST_CMD=pnpm test)" || bad "1e legit TARGET 'typescript' over-blocked by the validator" ""
[ "$(_lt python)" = "pytest -q" ] && ok "1e legit TARGET 'python' still loads (TEST_CMD=pytest -q)" || bad "1e legit TARGET 'python' over-blocked" ""
[ "$(_lt static)" = "bash tests/dod/run.sh" ] && ok "1e legit TARGET 'static' still loads" || bad "1e legit TARGET 'static' over-blocked" ""

echo "== FOLD #14: forge_validate_selector — the shared allowlist mechanism (TARGET + *_BACKEND) =="
if declare -F forge_validate_selector >/dev/null 2>&1; then
  forge_validate_selector typescript typescript python static && ok "1c legit TARGET 'typescript' accepted" || bad "1c legit TARGET rejected (over-block)" ""
  forge_validate_selector python typescript python static && ok "1c legit TARGET 'python' accepted" || bad "1c legit TARGET 'python' rejected (over-block)" ""
  forge_validate_selector 'x:-$(id)' typescript python static && bad "1c metacharacter TARGET ACCEPTED (validator bypass)" "" || ok "1c metacharacter TARGET rejected"
  # the SAME validator applied to the backend allowlist {ollama, claude-fresh, codex}:
  forge_validate_selector ollama ollama claude-fresh codex && ok "1d legit backend 'ollama' accepted" || bad "1d legit backend rejected (over-block)" ""
  forge_validate_selector claude-fresh ollama claude-fresh codex && ok "1d legit backend 'claude-fresh' accepted" || bad "1d legit backend 'claude-fresh' rejected" ""
  forge_validate_selector codex ollama claude-fresh codex && ok "1d legit backend 'codex' accepted" || bad "1d legit backend 'codex' rejected" ""
  forge_validate_selector 'x:-$(touch /tmp/forge-fold14-x)' ollama claude-fresh codex && bad "1d metacharacter backend ACCEPTED (bypass)" "" || ok "1d metacharacter backend rejected"
  # the glob guard: a '*' must NOT match — proves the validator uses string EQUALITY, not a case-pattern.
  forge_validate_selector '*' ollama claude-fresh codex && bad "1d glob '*' backend ACCEPTED (case-pattern bypass)" "" || ok "1d glob '*' backend rejected (equality, not pattern)"
else
  bad "1c forge_validate_selector ABSENT in \$LIB — the shared validator is not present (vector open)" "$LIB"
fi

echo "== FOLD #14: review-task.sh refuses a metacharacter REVIEWER_BACKEND before the eval (:45) =="
# Run the REAL review-task.sh under test inside a minimal root: it sources <root>/.claude/hooks/lib.sh and
# reaches the config-load + eval BEFORE any gh op. A metacharacter REVIEWER_BACKEND must be refused WITHOUT
# the eval command-substituting (no SUBST marker) and WITHOUT reaching gh; a legit backend must pass through.
if [ -f "$REVIEW" ]; then
  RT="$(mktemp -d)"
  mkdir -p "$RT/harness" "$RT/.claude/hooks" "$RT/bin"
  cp "$REVIEW" "$RT/harness/review-task.sh"
  cp "$LIB" "$RT/.claude/hooks/lib.sh"
  printf 'ollama_MODEL="m"\n' > "$RT/harness/reviewers.config"
  RTMARK="$RT/GH_REACHED"
  printf '#!/usr/bin/env bash\ntouch "%s"\nprintf "o/r\\n"\nexit 0\n' "$RTMARK" > "$RT/bin/gh"; chmod +x "$RT/bin/gh"
  ( cd "$RT" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m b ) >/dev/null 2>&1
  # the metacharacter-backend attack: the `$(touch SUBST)` must NOT run; gh must NOT be reached.
  # Payload uses `:=` (assign-default), NOT `:-`: review-task.sh maps BACKEND->PREFIX via `tr '-' '_'`,
  # which mangles a `:-` into `:_` (a bad substitution that errors BEFORE the $() runs); `:=` survives the
  # tr, so `${x:=$(cmd)_MODEL:-}` genuinely command-substitutes at the :45 eval on the unvalidated floor.
  SUBST="$RT/SUBST_FIRED"
  ( cd "$RT"; export PATH="$RT/bin:$PATH"; export REVIEWER_BACKEND='x:=$(touch '"$SUBST"')'
    bash harness/review-task.sh 1 --repo o/r ) >/dev/null 2>&1
  if [ -e "$SUBST" ]; then
    bad "2a REVIEWER_BACKEND SUBSTITUTION sink OPEN: review-task.sh:45 eval ran the \$() (no input validation)" ""
  else
    ok "2a metacharacter REVIEWER_BACKEND did NOT command-substitute"
  fi
  if [ -e "$RTMARK" ]; then
    bad "2a review-task.sh REACHED gh with a metacharacter backend (not refused before the eval/gh)" ""
  else
    ok "2a review-task.sh refused the metacharacter backend before any gh op"
  fi
  # over-block guard: a LEGIT backend (ollama) must still pass validation and REACH gh.
  rm -f "$RTMARK"
  ( cd "$RT"; export PATH="$RT/bin:$PATH"; export REVIEWER_BACKEND='ollama'
    bash harness/review-task.sh 1 --repo o/r ) >/dev/null 2>&1
  if [ -e "$RTMARK" ]; then
    ok "2b legit backend 'ollama' passed validation and reached gh (no over-block)"
  else
    bad "2b legit backend 'ollama' was BLOCKED before gh (over-block — the validation is too strict)" ""
  fi
  rm -rf "$RT"
else
  bad "2 review-task.sh not found at \$REVIEW" "$REVIEW"
fi

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact" || bad "LIVE FLOOR CHANGED" "$FLOOR_PRE -> $FLOOR_POST"
echo "==== fold14-target-selector (RED until the floor-hardening splice): $P passed, $F failed ===="
[ "$F" -eq 0 ]
