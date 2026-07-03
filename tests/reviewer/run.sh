#!/usr/bin/env bash
# tests/reviewer/run.sh — Build 1: Reviewer -> Aggregate-Review (Piece B core).
#
# Proves the three pure-rewire behaviors, each RED-first:
#   Part A  the advisory review fires EXACTLY ONCE per feature, on COMPLETION, against the ASSEMBLED feature
#           PR (aggregate: gh pr diff, NOT a per-task range), via forge_review_feature_if_complete.
#   Part B  the ratified spec + the feature ledger reach the reviewer's backend input (claude-fresh + ollama).
#   Part D  ollama with NO explicit model fails LOUD + instructional (names ollama_MODEL + how to reach ollama),
#           never the silent placeholder; claude-fresh/codex (trust-auth) are unchanged.
#
# RED/GREEN seam (the FORGE_ASSEMBLY_HARNESS analogue): FORGE_REVIEW_CANDIDATE points at the dir holding
# apply-candidate.py; the suite materializes a throwaway harness = DEPLOYED + applier and tests THAT.
#   bash tests/reviewer/run.sh
#       -> deployed, pre-splice: the aggregate fn is ABSENT -> SKIP rc 75 (keeps the canonical gate green;
#          the suite AUTO-ACTIVATES PASS-required once the door splice lands and the fn is in the deployed tree).
#   FORGE_REVIEW_CANDIDATE=sandbox/reviewer-aggregate bash tests/reviewer/run.sh
#       -> candidate applied -> GREEN (every arm passes). "A test verifies what ships."
#   FORGE_REVIEW_PROVE_RED=1 bash tests/reviewer/run.sh
#       -> forces the GREEN arms against the DEPLOYED harness -> they FAIL (the RED proof, run by a human).
#
# THROWAWAY fixtures only; the REAL $ROOT/.beads ledger is byte-guarded. No docker. bd only for the Part A
# real-ledger arm (skipped if bd is absent); the review-task.sh arms use a static issues.jsonl fixture.
set -u
export BD_NON_INTERACTIVE=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  PASS [%s]\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
skp() { SKIP=$((SKIP+1)); printf '  SKIP [%s] %s\n' "$1" "${2:-}"; }

command -v jq  >/dev/null 2>&1 || { echo "FAIL: jq is required";  exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required (applier)"; exit 1; }

TMPROOT="$(mktemp -d)"
cleanup() {
  local d
  for d in "$TMPROOT"/*/; do [ -d "$d/.git" ] && git -C "$d" worktree prune >/dev/null 2>&1; done
  rm -rf "$TMPROOT" 2>/dev/null
}
trap cleanup EXIT

# ---- HARD real-ledger byte-unchanged guard ----
REAL_LEDGER="$ROOT/.beads/issues.jsonl"
ledger_state() { [ -f "$REAL_LEDGER" ] && sha256sum "$REAL_LEDGER" | cut -d' ' -f1 || printf 'ABSENT'; }
BEADS_BEFORE="$(ledger_state)"

# ── materialize the harness-under-test (HUT): DEPLOYED, optionally + the candidate applier ──
HUT="$ROOT/harness"
if [ -n "${FORGE_REVIEW_CANDIDATE:-}" ]; then
  CAND="$FORGE_REVIEW_CANDIDATE"; case "$CAND" in /*) : ;; *) CAND="$ROOT/$CAND" ;; esac
  [ -f "$CAND/apply-candidate.py" ] || { echo "FAIL: no apply-candidate.py at $CAND"; exit 1; }
  HUT="$TMPROOT/hut"; mkdir -p "$HUT"
  cp "$ROOT/harness/"*.sh "$HUT/" 2>/dev/null
  cp "$ROOT/harness/"*.config "$HUT/" 2>/dev/null
  python3 "$CAND/apply-candidate.py" "$HUT" || { echo "FAIL: apply-candidate.py failed against $HUT"; exit 1; }
fi

HAS_AGG=0; grep -q 'forge_review_feature_if_complete' "$HUT/beads-lib.sh" 2>/dev/null && HAS_AGG=1

echo "============================================================"
echo "Build 1 reviewer->aggregate — HUT: $HUT (aggregate-fn present=$HAS_AGG)"
echo "============================================================"

if [ "$HAS_AGG" != 1 ] && [ "${FORGE_REVIEW_PROVE_RED:-0}" != 1 ]; then
  echo "SKIP: Build 1 (aggregate review) is not yet spliced into $HUT."
  echo "      prove GREEN:  FORGE_REVIEW_CANDIDATE=sandbox/reviewer-aggregate bash tests/reviewer/run.sh"
  echo "      prove RED:    FORGE_REVIEW_PROVE_RED=1 bash tests/reviewer/run.sh"
  echo "      This SKIP (rc 75) keeps the canonical gate green pre-splice; the suite auto-activates"
  echo "      (PASS-required) once the door splice lands and the fn is in the deployed harness."
  exit 75
fi
[ "$HAS_AGG" = 1 ] || echo ">> FORGE_REVIEW_PROVE_RED=1 — running the GREEN arms against the UNSPLICED harness; expect FAILs (this IS the RED proof)."

# ── shared fakes ─────────────────────────────────────────────────────────────────────────────────
FAKEREV="$TMPROOT/fake-review.sh"
cat >"$FAKEREV" <<'EOS'
#!/usr/bin/env bash
# logs ONE line per invocation: PR arg + whether range mode leaked + whether the spec was forwarded
printf 'FIRE pr=%s mode=%s src=%s args=[%s]\n' "$1" "${FORGE_REVIEW_DIFF_MODE:-UNSET}" "${FORGE_REVIEW_SOURCE_SPEC:-UNSET}" "$*" >> "$FAKE_REV_LOG"
EOS
chmod +x "$FAKEREV"

MARKER="MARKER_SPEC_TOKEN_ZZZ9"
LEDGER_TOK="LEDGER_TASKTOK_QQQ7"

mk_review_root() {   # a ROOT review-task.sh can run inside: git repo + lib.sh + reviewer.md + bin/ fakes
  local R; R="$(mktemp -d -p "$TMPROOT")"
  mkdir -p "$R/harness" "$R/.claude/hooks" "$R/.claude/agents" "$R/bin" "$R/.beads" "$R/specs/feat" "$R/.cap"
  cp "$HUT/review-task.sh" "$R/harness/review-task.sh"; chmod +x "$R/harness/review-task.sh"
  cp "$ROOT/.claude/hooks/lib.sh" "$R/.claude/hooks/lib.sh"
  cp "$ROOT/.claude/agents/reviewer.md" "$R/.claude/agents/reviewer.md"
  : >"$R/.gh-calls.log"
  cat >"$R/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$R/.gh-calls.log"
case "\$1 \$2" in
  "pr diff")    printf 'diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n+changed\n' ;;
  "pr view")    git -C "$R" rev-parse HEAD 2>/dev/null ;;
  "pr comment") cat > "$R/.cap/comment.body"; printf 'https://github.com/o/r/pull/9#c1\n' ;;
  "repo view")  printf 'o/r\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
  cat >"$R/bin/ollama" <<EOF
#!/usr/bin/env bash
cat > "$R/.cap/ollama.stdin"; printf 'argv: %s\n' "\$*" > "$R/.cap/ollama.argv"
printf '### Reviewer verdict: CLEAN\n(fake ollama)\n'
EOF
  cat >"$R/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\0' "\$@" > "$R/.cap/claude.argv"
printf '### Reviewer verdict: CLEAN\n(fake claude)\n'
EOF
  cat >"$R/bin/codex" <<EOF
#!/usr/bin/env bash
cat > "$R/.cap/codex.stdin"
printf '### Reviewer verdict: CLEAN\n(fake codex)\n'
EOF
  chmod +x "$R/bin/gh" "$R/bin/ollama" "$R/bin/claude" "$R/bin/codex"
  printf '# Spec\n\nFR-001: %s — the system MUST do the thing.\n' "$MARKER" > "$R/specs/feat/spec.md"
  printf '%s\n' "{\"id\":\"rv-1\",\"title\":\"Task One $LEDGER_TOK\",\"status\":\"in_review\",\"metadata\":{\"source_spec\":\"specs/feat/spec.md\",\"task_id\":\"T001\",\"accept\":{\"scope\":[\"sandbox/**\"]}}}" > "$R/.beads/issues.jsonl"
  ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
      && git symbolic-ref HEAD refs/heads/main \
      && printf 'base\n' > README.md && git add README.md && git commit -q -m base ) >/dev/null 2>&1
  printf '%s' "$R"
}
run_review() {  # <root> <backend> [source_spec]   -> sets RRC; stderr in $LASTERR
  local R="$1" be="$2" srcspec="${3:-}"
  LASTERR="$R/.stderr"
  (
    cd "$R" || exit 1
    export PATH="$R/bin:$PATH" REVIEWER_BACKEND="$be"
    [ -n "$srcspec" ] && export FORGE_REVIEW_SOURCE_SPEC="$srcspec"
    bash harness/review-task.sh 9 --repo o/r >/dev/null 2>"$LASTERR"
  )
  RRC=$?
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part A — fires EXACTLY ONCE on completion, aggregate, spec-fed (forge_review_feature_if_complete)
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== Part A: the once-gate (stubbed predicate) — 3 finishes -> EXACTLY 1 fire, aggregate, spec-fed =="
LOG="$TMPROOT/a-stub.log"; : >"$LOG"
(
  set -u
  . "$HUT/beads-lib.sh" 2>/dev/null
  export FAKE_REV_LOG="$LOG"
  _N=0
  forge_feature_complete() { _N=$((_N+1)); [ "$_N" -ge 3 ]; }   # incomplete on finishes 1,2 ; complete on 3
  for _i in 1 2 3; do
    forge_review_feature_if_complete "specs/feat/spec.md" "https://github.com/o/r/pull/9" "o/r" "$FAKEREV" 2>/dev/null
  done
) 2>/dev/null
NF="$(grep -c FIRE "$LOG" 2>/dev/null || echo 0)"
[ "$NF" = "1" ] && ok "fires EXACTLY once across 3 finishes (the once-gate holds until completion)" || no "expected 1 fire, got $NF" "$(cat "$LOG" 2>/dev/null)"
grep -q 'mode=UNSET' "$LOG" 2>/dev/null && ok "AGGREGATE mode: the fire sets NO FORGE_REVIEW_DIFF_MODE=range" || no "range mode leaked into the aggregate fire" "$(cat "$LOG" 2>/dev/null)"
grep -q 'src=specs/feat/spec.md' "$LOG" 2>/dev/null && ok "spec FED: FORGE_REVIEW_SOURCE_SPEC forwarded to review-task.sh" || no "source_spec not forwarded" "$(cat "$LOG" 2>/dev/null)"
grep -q 'pr=https://github.com/o/r/pull/9' "$LOG" 2>/dev/null && ok "fires against the FEATURE PR url" || no "wrong PR target" "$(cat "$LOG" 2>/dev/null)"
grep -q -- '--repo o/r' "$LOG" 2>/dev/null && ok "forwards --repo" || no "repo not forwarded" "$(cat "$LOG" 2>/dev/null)"

echo "== Part A: a SINGLE-task feature fires once on its only finish (complete on finish #1) =="
LOG3="$TMPROOT/a-single.log"; : >"$LOG3"
(
  set -u
  . "$HUT/beads-lib.sh" 2>/dev/null
  export FAKE_REV_LOG="$LOG3"
  forge_feature_complete() { return 0; }   # single-task feature: complete right after its only finish
  forge_review_feature_if_complete "specs/feat/spec.md" "https://github.com/o/r/pull/9" "o/r" "$FAKEREV" 2>/dev/null
) 2>/dev/null
[ "$(grep -c FIRE "$LOG3" 2>/dev/null || echo 0)" = "1" ] && ok "single-task feature -> fires exactly once on its only finish" || no "single-task feature did not fire once" "$(cat "$LOG3" 2>/dev/null)"

echo "== Part A: real-bd predicate — open feature -> NO fire; all in_review/closed -> ONE fire =="
if command -v bd >/dev/null 2>&1; then
  RB="$(mktemp -d -p "$TMPROOT")"
  ( cd "$RB" && git init -q && git config user.email t@t && git config user.name t \
      && git symbolic-ref HEAD refs/heads/main && git config beads.role maintainer \
      && bd init --skip-agents --skip-hooks --non-interactive --prefix rv >/dev/null 2>&1 \
      && bd config set status.custom "in_review:wip" >/dev/null 2>&1 ) >/dev/null 2>&1
  A1="$(bd -C "$RB" create "f1" --metadata '{"source_spec":"specs/feat/spec.md"}' -p 2 --silent </dev/null 2>/dev/null | tr -d '[:space:]')"
  A2="$(bd -C "$RB" create "f2" --metadata '{"source_spec":"specs/feat/spec.md"}' -p 2 --silent </dev/null 2>/dev/null | tr -d '[:space:]')"
  LOG2="$TMPROOT/a-realbd.log"; : >"$LOG2"
  ( set -u; ROOT="$RB"; . "$HUT/beads-lib.sh" 2>/dev/null; export FAKE_REV_LOG="$LOG2"
    forge_review_feature_if_complete "specs/feat/spec.md" "https://github.com/o/r/pull/9" "o/r" "$FAKEREV" 2>/dev/null ) 2>/dev/null
  [ ! -s "$LOG2" ] && ok "real bd: 2 OPEN feature beads -> NO fire (gate holds)" || no "fired while feature incomplete" "$(cat "$LOG2")"
  bd -C "$RB" update "$A1" --status in_review >/dev/null 2>&1
  bd -C "$RB" close  "$A2" --reason done    >/dev/null 2>&1
  ( set -u; ROOT="$RB"; . "$HUT/beads-lib.sh" 2>/dev/null; export FAKE_REV_LOG="$LOG2"
    forge_review_feature_if_complete "specs/feat/spec.md" "https://github.com/o/r/pull/9" "o/r" "$FAKEREV" 2>/dev/null ) 2>/dev/null
  [ "$(grep -c FIRE "$LOG2" 2>/dev/null || echo 0)" = "1" ] && ok "real bd: all feature beads in_review/closed -> fires ONCE" || no "expected 1 fire on completion" "$(cat "$LOG2")"
else
  skp "Part A real-bd" "bd absent — the stubbed-predicate arm above is the load-bearing once-gate proof"
fi

echo "== Part A static: the per-task range fire is GONE from run-task.sh; the aggregate call is wired =="
if grep -q 'FORGE_REVIEW_DIFF_MODE=range' "$HUT/run-task.sh" 2>/dev/null; then
  no "run-task.sh STILL sets FORGE_REVIEW_DIFF_MODE=range (the per-task fire was not removed)"
else
  ok "run-task.sh no longer sets FORGE_REVIEW_DIFF_MODE=range (per-task range fire removed)"
fi
grep -q 'forge_review_feature_if_complete "\$source_spec"' "$HUT/run-task.sh" 2>/dev/null && ok "run-task.sh calls forge_review_feature_if_complete (aggregate fire wired into finish)" || no "aggregate fire not wired into run-task.sh"
# back-compat: review-task.sh KEEPS its range path for standalone/manual review
grep -q 'FORGE_REVIEW_DIFF_MODE.*=.*range\|= "range"' "$HUT/review-task.sh" 2>/dev/null && ok "review-task.sh KEEPS the range path (standalone-CLI back-compat, unchanged)" || no "review-task.sh lost its range back-compat path"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part B — the ratified spec + feature ledger reach the backend input
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== Part B(ollama): spec marker + ledger reach the backend input; aggregate path (gh pr diff) =="
R="$(mk_review_root)"
printf 'ollama_MODEL="fakemodel"\n' > "$R/harness/reviewers.config"
run_review "$R" ollama "specs/feat/spec.md"
grep -q "$MARKER" "$R/.cap/ollama.stdin" 2>/dev/null && ok "Part B(ollama): the ratified spec reaches the backend input" || no "spec marker absent from ollama input" "rc=$RRC $(cat "$LASTERR" 2>/dev/null | tail -1)"
grep -q "$LEDGER_TOK" "$R/.cap/ollama.stdin" 2>/dev/null && ok "Part B(ollama): the feature ledger reaches the backend input" || no "ledger absent from ollama input"
grep -q 'pr diff' "$R/.gh-calls.log" 2>/dev/null && ok "Part B: AGGREGATE path taken (gh pr diff — the full feature diff, not a range)" || no "aggregate gh pr diff not used"
grep -q 'pr view' "$R/.gh-calls.log" 2>/dev/null && ok "Part B: read-context HEAD comes from the feature PR (gh pr view headRefOid)" || no "gh pr view (feature-tip) not consulted"

echo "== Part B(claude-fresh, PRIMARY): spec marker reaches the backend input =="
R="$(mk_review_root)"
printf 'claude_fresh_MODEL="fakemodel"\nclaude_fresh_ALLOWED_TOOLS="Read Grep Glob"\n' > "$R/harness/reviewers.config"
run_review "$R" claude-fresh "specs/feat/spec.md"
grep -qa "$MARKER" "$R/.cap/claude.argv" 2>/dev/null && ok "Part B(claude-fresh): the ratified spec reaches the PRIMARY backend input" || no "spec marker absent from claude-fresh input" "rc=$RRC $(cat "$LASTERR" 2>/dev/null | tail -1)"
grep -qa "$LEDGER_TOK" "$R/.cap/claude.argv" 2>/dev/null && ok "Part B(claude-fresh): the feature ledger reaches the PRIMARY backend input" || no "ledger absent from claude-fresh input"

echo "== Part B(codex): spec marker + ledger reach the backend input (3rd backend) =="
R="$(mk_review_root)"
printf 'codex_MODEL="fakemodel"\n' > "$R/harness/reviewers.config"
run_review "$R" codex "specs/feat/spec.md"
grep -q "$MARKER" "$R/.cap/codex.stdin" 2>/dev/null && ok "Part B(codex): the ratified spec reaches the backend input" || no "spec marker absent from codex input" "rc=$RRC $(cat "$LASTERR" 2>/dev/null | tail -1)"
grep -q "$LEDGER_TOK" "$R/.cap/codex.stdin" 2>/dev/null && ok "Part B(codex): the feature ledger reaches the backend input" || no "ledger absent from codex input"

echo "== Part B negative: NO source_spec (standalone) -> no spec/ledger, ORIGINAL instruction (byte-exact) =="
R="$(mk_review_root)"
printf 'ollama_MODEL="fakemodel"\n' > "$R/harness/reviewers.config"
run_review "$R" ollama    # no FORGE_REVIEW_SOURCE_SPEC
grep -q "$MARKER" "$R/.cap/ollama.stdin" 2>/dev/null && no "spec leaked into a no-source_spec (standalone) ollama run" || ok "no source_spec (ollama) -> no spec/ledger injected"
grep -qE '<ratified-spec|<feature-ledger' "$R/.cap/ollama.stdin" 2>/dev/null && no "context tags leaked into a no-source_spec ollama run" || ok "no source_spec (ollama) -> no <ratified-spec>/<feature-ledger> tags (input byte-exact shape)"
R="$(mk_review_root)"
printf 'claude_fresh_MODEL="fakemodel"\nclaude_fresh_ALLOWED_TOOLS="Read Grep Glob"\n' > "$R/harness/reviewers.config"
run_review "$R" claude-fresh    # no FORGE_REVIEW_SOURCE_SPEC
grep -qa 'Review the PR diff below' "$R/.cap/claude.argv" 2>/dev/null && ok "no source_spec (claude-fresh) -> ORIGINAL instruction preserved" || no "standalone claude instruction is not the original" "$(tr '\0' ' ' < "$R/.cap/claude.argv" 2>/dev/null | head -c 160)"
grep -qa 'ratified spec' "$R/.cap/claude.argv" 2>/dev/null && no "standalone claude prompt references an ABSENT ratified spec (Finding 1 wart)" || ok "no source_spec (claude-fresh) -> prompt does NOT reference an absent spec"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part D — ollama backend preflight (loud + instructional); claude-fresh/codex trust-auth unchanged
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== Part D: ollama with NO explicit model -> LOUD instructional die, NO silent placeholder =="
R="$(mk_review_root)"
printf 'ollama_MODEL=""\n' > "$R/harness/reviewers.config"
run_review "$R" ollama
[ "$RRC" -ne 0 ] && ok "Part D: empty ollama_MODEL -> non-zero exit (loud failure, not silent)" || no "empty ollama_MODEL did NOT fail (silent default)" "rc=$RRC"
grep -q 'ollama_MODEL' "$LASTERR" 2>/dev/null && ok "Part D: the failure NAMES the config key 'ollama_MODEL'" || no "failure does not name ollama_MODEL" "$(cat "$LASTERR" 2>/dev/null)"
grep -qiE 'ollama serve|ollama pull|reachable' "$LASTERR" 2>/dev/null && ok "Part D: the failure is INSTRUCTIONAL (how to point at ollama)" || no "failure not instructional" "$(cat "$LASTERR" 2>/dev/null)"
grep -q 'pr comment' "$R/.gh-calls.log" 2>/dev/null && no "Part D: a placeholder comment was STILL posted (not a clean loud-fail)" || ok "Part D: NO placeholder comment posted (failed before posting)"

echo "== Part D: SET-but-UNREACHABLE ollama (empty output) -> LOUD instructional, NOT the vague placeholder =="
R="$(mk_review_root)"
printf 'ollama_MODEL="fakemodel"\n' > "$R/harness/reviewers.config"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$R/bin/ollama"   # reachable binary, EMPTY output (model not pulled / daemon down)
chmod +x "$R/bin/ollama"
run_review "$R" ollama "specs/feat/spec.md"
grep -q 'REVIEW DID NOT RUN' "$R/.cap/comment.body" 2>/dev/null && ok "Part D(unreachable): empty ollama -> LOUD 'REVIEW DID NOT RUN' posted (honest non-review)" || no "unreachable ollama did not post a loud message" "$(head -c 160 "$R/.cap/comment.body" 2>/dev/null)"
grep -qE 'ollama_MODEL|ollama pull' "$R/.cap/comment.body" 2>/dev/null && ok "Part D(unreachable): the loud message is INSTRUCTIONAL (ollama_MODEL / ollama pull)" || no "unreachable message not instructional" "$(head -c 160 "$R/.cap/comment.body" 2>/dev/null)"
grep -q 'reviewer produced no output' "$R/.cap/comment.body" 2>/dev/null && no "unreachable ollama STILL posted the vague placeholder" || ok "Part D(unreachable): the vague placeholder is NOT posted for ollama"

echo "== Part D canary: ollama WITH an explicit model runs (no false die) =="
R="$(mk_review_root)"
printf 'ollama_MODEL="fakemodel"\n' > "$R/harness/reviewers.config"
run_review "$R" ollama
grep -q 'pr comment' "$R/.gh-calls.log" 2>/dev/null && ok "Part D canary: explicit model -> review runs + posts (preflight not over-eager)" || no "explicit model still failed to run" "rc=$RRC $(cat "$LASTERR" 2>/dev/null | tail -1)"

echo "== Part D canary: claude-fresh with NO model does NOT require one (trust-auth backend, unchanged) =="
R="$(mk_review_root)"
printf 'claude_fresh_MODEL=""\nclaude_fresh_ALLOWED_TOOLS="Read Grep Glob"\n' > "$R/harness/reviewers.config"
run_review "$R" claude-fresh
grep -q 'pr comment' "$R/.gh-calls.log" 2>/dev/null && ok "Part D canary: claude-fresh empty model -> still runs (no model requirement)" || no "claude-fresh wrongly required a model" "rc=$RRC $(cat "$LASTERR" 2>/dev/null | tail -1)"

echo
echo "==== reviewer: $PASS passed, $FAIL failed, $SKIP skipped ===="
echo "== real-ledger byte-unchanged guard =="
[ "$(ledger_state)" = "$BEADS_BEFORE" ] && ok "REAL .beads byte-unchanged" || no "REAL ledger CHANGED — GUARD TRIPPED"
[ "$FAIL" = 0 ] || exit 1
exit 0
