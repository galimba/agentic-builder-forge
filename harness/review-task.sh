#!/usr/bin/env bash
# agentic-builder-forge — adversarial review dispatch.
#
#   review-task.sh <pr-number|branch>
#
# Fetches the REAL PR diff and hands it to a structurally-separated, READ-ONLY reviewer running in
# a fresh context, then posts the reviewer's findings to the PR as a PLAIN, ADVISORY comment.
#
# The reviewer is NEVER given git/gh or write tools — THIS trusted harness script is the only thing
# that touches GitHub. The verdict is ADVISORY only: the deterministic test gate remains the sole
# merge authority. This script never merges, never pushes, never gates.
#
# Backend is config-driven (harness/reviewers.config): ollama (default) | claude-fresh | codex.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../.claude/hooks/lib.sh
. "$HERE/../.claude/hooks/lib.sh"

die() {
  printf 'review-task: %s\n' "$1" >&2
  exit 1
}

ROOT="$(forge_main_root)" || die "not inside a git repo"
PR="${1:-}"
[ -n "$PR" ] || die 'usage: review-task.sh <pr-number|branch|url> [--repo owner/repo]'
shift || true
# T6: optional --repo (cmd_finish passes the captured target repo; back-compat: derive from cwd).
REPO_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO_ARG="${2:-}"; [ -n "$REPO_ARG" ] || die "--repo requires a value"; shift 2 ;;
    *) shift ;;
  esac
done
command -v gh >/dev/null 2>&1 || die "gh CLI not found"

# FOLD #14: the eval-INDIRECTION backend-selector guard. REVIEWER_BACKEND / DISPOSITION_BACKEND
# flow into `eval "<X>=\${${PREFIX}_<KEY>:-}"` — a metacharacter backend command-SUBSTITUTES at the eval.
# INLINE here (NOT lib.sh's forge_validate_selector) so review-task.sh stays SELF-CONTAINED against the
# reviewer test harness, which copies the DEPLOYED lib.sh into its throwaway root (a hard dependency on a
# freshly-spliced lib.sh symbol would break all three reviewer suites) — the same inline discipline as
# Build 2a/2b's _review_block / run_disposition. PURE string equality (no eval, no glob): a metacharacter
# backend simply fails to match. The allowlist mirrors the run_reviewer / run_disposition dispatch `case`
# arms (ollama | claude-fresh | codex) — keep them in sync.
_rt_known_backend() {
  local _b="$1" _k
  for _k in ollama claude-fresh codex; do [ "$_b" = "$_k" ] && return 0; done
  return 1
}

# --- config-driven backend selection (mirrors targets.config per-prefix style) ---
CFG="$ROOT/harness/reviewers.config"
[ -f "$CFG" ] || die "missing harness/reviewers.config"
# shellcheck disable=SC1090
. "$CFG"
BACKEND="${REVIEWER_BACKEND:-ollama}"
# FOLD #14: refuse a non-allowlisted REVIEWER_BACKEND BEFORE the eval-indirection below — a
# metacharacter backend would command-substitute at the eval. LOUD die (a standalone run sees it; the
# fire-and-forget reviewer caller swallows the exit, so this never gates cmd_finish).
_rt_known_backend "$BACKEND" || die "REVIEWER_BACKEND '$BACKEND' is not a recognized backend (ollama|claude-fresh|codex) — refusing (an unvalidated backend is eval-expanded into a shell command). Set REVIEWER_BACKEND in harness/reviewers.config."
PREFIX="$(printf '%s' "$BACKEND" | tr '-' '_')"
eval "MODEL=\${${PREFIX}_MODEL:-}"
eval "ALLOWED_TOOLS=\${${PREFIX}_ALLOWED_TOOLS:-Read Grep Glob}"
eval "SANDBOX=\${${PREFIX}_SANDBOX:-read-only}"

# --- Build 1 (Part D): ollama backend preflight — require an EXPLICIT model; fail LOUD otherwise -------
# claude-fresh / codex trust the session's own auth (no reachability check). ollama, by contrast, would
# SILENTLY default to a model and then — if it is not pulled / the daemon is down — post a vacuous
# placeholder that reads like "review ran, nothing found". Refuse that: an unset ollama_MODEL dies LOUD and
# INSTRUCTIONAL (names the config key + how to point at ollama). The failure is surfaced honestly via the
# exit (the fire-and-forget caller swallows it; a human/standalone run sees it) — never a fabricated PASS.
if [ "$BACKEND" = "ollama" ] && [ -z "$MODEL" ]; then
  die "ollama backend requires an explicit model — set 'ollama_MODEL' in harness/reviewers.config (e.g. ollama_MODEL=qwen3-coder:30b) and ensure ollama is reachable (run 'ollama serve' and 'ollama pull <model>'). Refusing to post a silent placeholder."
fi

if [ -n "$REPO_ARG" ]; then REPO="$REPO_ARG"; else REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || die "cannot resolve repo"; fi

# --- fetch the real PR diff + head SHA (the HARNESS does this, never the reviewer) ---
DIFF_FILE="$(mktemp -t forge_review_diff.XXXXXX)" || die "mktemp failed"
REVIEW_WT=""
cleanup() {
  [ -n "${DIFF_FILE:-}" ] && rm -f "$DIFF_FILE" 2>/dev/null
  if [ -n "$REVIEW_WT" ] && [ -d "$REVIEW_WT" ]; then
    git -C "$ROOT" worktree remove --force "$REVIEW_WT" 2>/dev/null
    git -C "$ROOT" worktree prune 2>/dev/null
  fi
}
trap cleanup EXIT

# T6: in feature assembly the diff source is the task's ACTUAL contribution since it forked from
# feat/F — `git diff base_sha..task_tip` (the STABLE fork-point range). feat/F...task-branch is EMPTY once
# the task is merged onto feat/F, so it must NOT be used post-merge. --no-textconv: don't run a gitattributes
# textconv driver during the diff. The HARNESS computes it (the reviewer never gets git/gh). Falls back to
# `gh pr diff` for a standalone PR review (no range env) — back-compat, unchanged.
if [ "${FORGE_REVIEW_DIFF_MODE:-}" = "range" ] && [ -n "${FORGE_REVIEW_BASE_SHA:-}" ] && [ -n "${FORGE_REVIEW_TASK_SHA:-}" ] && [ -n "${FORGE_REVIEW_WORKTREE:-}" ]; then
  git -C "$FORGE_REVIEW_WORKTREE" --no-pager diff --no-textconv "$FORGE_REVIEW_BASE_SHA".."$FORGE_REVIEW_TASK_SHA" >"$DIFF_FILE" 2>/dev/null || die "could not compute the task contribution diff ($FORGE_REVIEW_BASE_SHA..$FORGE_REVIEW_TASK_SHA)"
  HEAD_SHA="$FORGE_REVIEW_TASK_SHA"
else
  gh pr diff "$PR" --repo "$REPO" --patch >"$DIFF_FILE" 2>/dev/null || die "could not fetch PR diff for $PR"
  HEAD_SHA="$(gh pr view "$PR" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null)"
fi
[ -s "$DIFF_FILE" ] || die "PR diff is empty for $PR"

# --- detached worktree at the reviewed commit = READ CONTEXT for Read/Grep/Glob only. This is a
# normal (FS-writable) checkout, NOT a read-only layer; the reviewer's read-only-ness comes from
# the tool allowlist below, not from this. Never the builder's worktree. ---
if [ -n "$HEAD_SHA" ]; then
  REVIEW_WT="$(mktemp -d -t forge_review_wt.XXXXXX)" || REVIEW_WT=""
  [ -n "$REVIEW_WT" ] && { git -C "$ROOT" worktree add --detach "$REVIEW_WT" "$HEAD_SHA" >/dev/null 2>&1 || REVIEW_WT=""; }
fi

# --- reviewer prompt = body of .claude/agents/reviewer.md (strip the YAML frontmatter) ---
AGENT="$ROOT/.claude/agents/reviewer.md"
[ -f "$AGENT" ] || die "missing .claude/agents/reviewer.md"
PROMPT="$(awk 'BEGIN { fm = 0 } /^---[[:space:]]*$/ { fm++; next } fm >= 2 { print }' "$AGENT")"

# --- Build 1 (Part B): the ratified spec + the feature ledger as REVIEW CONTEXT -----------------------
# FORGE_REVIEW_SOURCE_SPEC (set by the aggregate-review fire in run-task.sh) names the ratified spec path
# relative to $ROOT. Feeding the spec + every bead grouped under it lets the reviewer judge the ASSEMBLED
# feature against its ratified contract, not the diff in isolation. READ-ONLY: this is prompt CONTEXT, never
# a new write capability — the reviewer tool allowlist (Read/Grep/Glob) is unchanged. Empty when no
# source_spec (a standalone / range run) -> CONTEXT="" and the original instruction is used, so the backend
# input is BYTE-IDENTICAL to the pre-Build-1 behavior (CONTEXT is inserted as a bare %s; the conditional
# instruction below keeps the standalone prompt from referencing a spec/ledger that is not present).
CONTEXT=""
if [ -n "${FORGE_REVIEW_SOURCE_SPEC:-}" ]; then
  _ss="$FORGE_REVIEW_SOURCE_SPEC"
  case "$_ss" in /*) _spec_path="$_ss" ;; *) _spec_path="$ROOT/$_ss" ;; esac
  _ctxf="$(mktemp -t forge_review_ctx.XXXXXX)" || _ctxf=""
  if [ -n "$_ctxf" ]; then
    {
      if [ -f "$_spec_path" ]; then
        printf '<ratified-spec path="%s">\n' "$_ss"
        cat "$_spec_path"
        printf '\n</ratified-spec>\n\n'
      else
        printf '<ratified-spec path="%s" note="spec file not present at review time"></ratified-spec>\n\n' "$_ss"
      fi
      # the feature ledger: every bead grouped under this source_spec, with its acceptance contract. Read the
      # committed ledger snapshot at $ROOT/.beads/issues.jsonl DIRECTLY (reads ARE allowed; the deny floor
      # blocks only WRITES to .beads) — no bd call (avoids the inherited-TTY hang + the version coupling).
      if [ -f "$ROOT/.beads/issues.jsonl" ]; then
        printf '<feature-ledger source_spec="%s">\n' "$_ss"
        jq -rc --arg ss "$_ss" 'select((.metadata.source_spec // "")==$ss)
          | {id, task_id:(.metadata.task_id // null), title, status,
             accept:(.metadata.accept // null), acceptance_criteria:(.acceptance_criteria // null)}' \
          "$ROOT/.beads/issues.jsonl" 2>/dev/null
        printf '</feature-ledger>\n'
      fi
    } >"$_ctxf"
    CONTEXT="$(cat "$_ctxf")"; rm -f "$_ctxf"
    [ -n "$CONTEXT" ] && CONTEXT="$CONTEXT"$'\n'   # restore the trailing newline command-substitution strips, so empty CONTEXT stays byte-exact
  fi
fi
# the reviewer instruction references the spec+ledger ONLY when they are actually present; a standalone /
# range run (no source_spec -> empty CONTEXT) keeps the ORIGINAL instruction + byte-identical input.
if [ -n "$CONTEXT" ]; then
  _REVIEW_INSTR="Review the assembled feature against its ratified spec + ledger, then the PR diff below; read related files for context. Emit findings in the strict format."
else
  _REVIEW_INSTR="Review the PR diff below; read related files for context. Emit findings in the strict format."
fi

echo "→ reviewing PR $PR with backend '$BACKEND'${MODEL:+ (model: $MODEL)} — READ-ONLY, advisory" >&2

# --- dispatch to the configured backend; each is read-only by construction ---
run_reviewer() {
  case "$BACKEND" in
    ollama)
      command -v ollama >/dev/null 2>&1 || {
        echo "ollama not found"
        return 1
      }
      # Pure text in / text out — the model has NO tools, NO shell: read-only by construction.
      printf '%s\n\n%s<diff>\n%s\n</diff>\n' "$PROMPT" "$CONTEXT" "$(cat "$DIFF_FILE")" |
        ollama run "$MODEL" --nowordwrap 2>/dev/null
      ;;
    claude-fresh)
      command -v claude >/dev/null 2>&1 || {
        echo "claude not found"
        return 1
      }
      # THE read-only gate: no Bash and no write tools in the allowlist => the model cannot form a
      # mutating call at all. Runs from $ROOT so the deny hook loads as a SECONDARY backstop.
      # --add-dir grants read ACCESS to the worktree (context) — it does NOT enforce read-only.
      # shellcheck disable=SC2086
      (cd "$ROOT" && claude -p \
        --append-system-prompt "$PROMPT" \
        --allowedTools $ALLOWED_TOOLS \
        --disallowedTools Bash Write Edit MultiEdit NotebookEdit \
        --permission-mode default \
        ${REVIEW_WT:+--add-dir "$REVIEW_WT"} \
        --model "${MODEL:-sonnet}" \
        "${_REVIEW_INSTR}

${CONTEXT}$(cat "$DIFF_FILE")")
      ;;
    codex)
      command -v codex >/dev/null 2>&1 || {
        echo "codex not found"
        return 1
      }
      printf '%s\n\n%s%s\n' "$PROMPT" "$CONTEXT" "$(cat "$DIFF_FILE")" |
        codex exec --sandbox "${SANDBOX:-read-only}" --skip-git-repo-check ${MODEL:+-m "$MODEL"} -
      ;;
    *)
      echo "unknown REVIEWER_BACKEND '$BACKEND'"
      return 1
      ;;
  esac
}

# ── Build 2a: the SOLE machine-readable review-block extractor + the record writer ───────────────────
# The reviewer now emits, after its prose, ONE sentinel-bounded JSON block (.claude/agents/reviewer.md):
#   <!-- forge:review:begin v1 --> {verdict, findings:[{id,severity,location,finding,suggested_fix}]} <!-- forge:review:end v1 -->
# _review_block mirrors the ONE canonical Task-Breakdown slice idiom (_intake_task_block, harness/intake.sh:62) —
# the SAME awk begin/end-sentinel slice with the code-fence strip — but with REVIEW sentinels, reading the captured
# reviewer stdout from a pipe (FINDINGS is a string, not a file). It is INLINE here (not a shared-lib fn) BECAUSE
# review-task.sh sources only .claude/hooks/lib.sh, a deny-floor HASH INPUT that must stay byte-frozen; intake.sh
# (home of the canonical extractor) is not sourced here. There is exactly ONE review-block extraction site (this
# record write), so the no-divergence invariant the canonical extractor enforces is satisfied by construction.
_review_block() { awk '/<!-- forge:review:begin/{f=1;next} /<!-- forge:review:end/{f=0} f && $0 !~ /^```/'; }

# write_review_record <pr-number> <review-block-json> -> persist .harness/review/<pr>.json (atomic tmp+mv).
# Clean split of authority: the reviewer EMITS judgment (verdict + per-finding id/severity/location/finding/
# suggested_fix); the harness STAMPS execution provenance (backend, model, feature_sha, actor:"harness", ts) —
# the acceptance-record house style (harness/accept-gate.sh:196-204). Legitimate harness-runtime write: the deny
# floor gates the AGENT's tool calls, not this script's own redirect (harness/beads-lib.sh:276-278). tmp+mv (the
# forge_assembly_append idiom) => an interrupted/concurrent write can't leave a torn record; keyed by PR number =>
# a re-review OVERWRITES in place, never orphans a stale record.
write_review_record() {
  local prnum="$1" block="$2" dir tmp now
  dir="$ROOT/.harness/review"
  mkdir -p "$dir" 2>/dev/null || return 1
  now="$(date -u +%FT%TZ)"
  tmp="$(mktemp -t forge_review_rec.XXXXXX)" || return 1
  jq -nc \
    --arg pr "$prnum" \
    --argjson block "$block" \
    --arg backend "$BACKEND" \
    --arg model "$MODEL" \
    --arg fsha "${HEAD_SHA:-}" \
    --arg ts "$now" \
    '{pr:$pr, verdict:$block.verdict, findings:($block.findings // []),
      backend:$backend, model:$model, feature_sha:$fsha, actor:"harness", ts:$ts}' \
    >"$tmp" 2>/dev/null && mv "$tmp" "$dir/$prnum.json" || { rm -f "$tmp"; return 1; }
}

# ── Build 2b: the disposition adjudicator — config-driven backend, the SOLE disposition-block extractor,
# and the SIBLING-record writer. ALL INLINE here for the SAME reason Build 2a's _review_block /
# write_review_record are: review-task.sh sources only .claude/hooks/lib.sh, a deny-floor HASH INPUT that
# must stay byte-frozen; a shared-lib helper would shift the floor hash. One disposition-block extraction
# site (the record write below), so the no-divergence invariant holds by construction.
#
# run_disposition mirrors run_reviewer EXACTLY: config-driven backend dispatch, READ-ONLY by construction
# (ollama/codex have no tools / a native read-only sandbox; claude-fresh gets the IDENTICAL write-tool
# denylist). It feeds the disposition agent body (system prompt) + the SUPPLIED reviewer findings + the PR
# diff + the spec/ledger CONTEXT — it adjudicates that supplied list, it does NOT hunt for new findings.
run_disposition() {
  case "$DISP_BACKEND" in
    ollama)
      command -v ollama >/dev/null 2>&1 || {
        echo "ollama not found"
        return 1
      }
      # Pure text in / text out — the model has NO tools, NO shell: read-only by construction.
      printf '%s\n\n%s<reviewer-findings>\n%s\n</reviewer-findings>\n<diff>\n%s\n</diff>\n' \
        "$DISP_PROMPT" "$CONTEXT" "$DISP_FINDINGS" "$(cat "$DIFF_FILE")" |
        ollama run "$DISP_MODEL" --nowordwrap 2>/dev/null
      ;;
    claude-fresh)
      command -v claude >/dev/null 2>&1 || {
        echo "claude not found"
        return 1
      }
      # THE read-only gate: the SAME denylist as run_reviewer — no Bash and no write tools in the allowlist
      # => the model cannot form a mutating call at all. Runs from $ROOT so the deny hook loads as a
      # SECONDARY backstop. --add-dir grants read ACCESS to the worktree (context); it does NOT enforce r/o.
      # shellcheck disable=SC2086
      (cd "$ROOT" && claude -p \
        --append-system-prompt "$DISP_PROMPT" \
        --allowedTools $DISP_ALLOWED_TOOLS \
        --disallowedTools Bash Write Edit MultiEdit NotebookEdit \
        --permission-mode default \
        ${REVIEW_WT:+--add-dir "$REVIEW_WT"} \
        --model "${DISP_MODEL:-sonnet}" \
        "Adjudicate EACH supplied reviewer finding against the PR diff below — CONFIRMED (a real defect, verified against the diff) or REBUTTED (not an issue). Verify against the artifact, never the reviewer's say-so. Adjudicate ONLY the supplied findings; do not hunt for new ones. Emit the strict format.

${CONTEXT}<reviewer-findings>
${DISP_FINDINGS}
</reviewer-findings>
$(cat "$DIFF_FILE")")
      ;;
    codex)
      command -v codex >/dev/null 2>&1 || {
        echo "codex not found"
        return 1
      }
      printf '%s\n\n%s<reviewer-findings>\n%s\n</reviewer-findings>\n%s\n' \
        "$DISP_PROMPT" "$CONTEXT" "$DISP_FINDINGS" "$(cat "$DIFF_FILE")" |
        codex exec --sandbox "${DISP_SANDBOX:-read-only}" --skip-git-repo-check ${DISP_MODEL:+-m "$DISP_MODEL"} -
      ;;
    *)
      echo "unknown DISPOSITION_BACKEND '$DISP_BACKEND'"
      return 1
      ;;
  esac
}

# _disposition_block mirrors _review_block (the canonical begin/end-sentinel awk slice with the code-fence
# strip) — review-side disposition sentinels, reading the captured stdout from a pipe.
_disposition_block() { awk '/<!-- forge:disposition:begin/{f=1;next} /<!-- forge:disposition:end/{f=0} f && $0 !~ /^```/'; }

# write_disposition_record <pr-number> <disposition-block-json> -> persist .harness/disposition/<pr>.json
# (atomic tmp+mv). A SIBLING to the 2a review record — NEVER a mutation of it: the 2a record overwrites in
# place on every reviewer fire, so a folded-in disposition field would be CLOBBERED on a re-review (data
# loss). This single-author sibling joins to the 2a record on pr + feature_sha. The harness STAMPS
# provenance (backend, model, actor:"harness", ts); the agent emits judgment (per-finding id + disposition +
# reasoning). The tmp lives INSIDE the dest dir, so the mv is a true same-filesystem atomic rename (tightens
# the 2a cross-fs `mktemp -t` nit); keyed by PR number => overwrite in place, never an orphan.
write_disposition_record() {
  local prnum="$1" block="$2" dir tmp now
  dir="$ROOT/.harness/disposition"
  mkdir -p "$dir" 2>/dev/null || return 1
  now="$(date -u +%FT%TZ)"
  tmp="$(mktemp "$dir/.forge_disp_rec.XXXXXX")" || return 1
  jq -nc \
    --arg pr "$prnum" \
    --argjson block "$block" \
    --arg backend "$DISP_BACKEND" \
    --arg model "$DISP_MODEL" \
    --arg fsha "${HEAD_SHA:-}" \
    --arg ts "$now" \
    '{pr:$pr, feature_sha:$fsha, dispositions:($block.dispositions // []),
      backend:$backend, model:$model, actor:"harness", ts:$ts}' \
    >"$tmp" 2>/dev/null && mv "$tmp" "$dir/$prnum.json" || { rm -f "$tmp"; return 1; }
}

FINDINGS="$(run_reviewer)"
RC=$?
if [ -z "$FINDINGS" ]; then
  if [ "$BACKEND" = "ollama" ]; then
    FINDINGS="⚠️ REVIEW DID NOT RUN — the ollama backend produced no output (rc=$RC): model '${MODEL:-?}' is likely not pulled, or the ollama daemon is unreachable. Run 'ollama serve' and 'ollama pull ${MODEL:-<model>}', or set a reachable ollama_MODEL in harness/reviewers.config. An honest non-review, not a clean result."
  else
    FINDINGS="_(reviewer produced no output — backend '$BACKEND' may be unavailable; rc=$RC)_"
  fi
fi

# ── Build 2a: extract + validate the structured verdict block, then persist the review record ─────────
# Fail-closed on the RECORD (an absent/duplicated/malformed block writes NO record — never a fabricated
# verdict), NON-gating on the MERGE (advisory exactly as before; the loud signal is the banner below + a
# non-zero exit AFTER the comment posts, which the fire-and-forget once-gate swallows). Mirrors intake's
# exactly-one-block + valid-JSON discipline (harness/intake.sh:447-454), surfacing loudly instead of aborting
# before the post.
REVIEW_BLOCK=""; REVIEW_BANNER=""; RECORD_OK=0; RECORD_REASON=""
NBLK="$(printf '%s\n' "$FINDINGS" | grep -cF '<!-- forge:review:begin' 2>/dev/null)"
case "$NBLK" in '' | *[!0-9]*) NBLK=0 ;; esac
if [ "$NBLK" -eq 0 ]; then
  RECORD_REASON="the reviewer output carries no <!-- forge:review:begin --> structured verdict block"
elif [ "$NBLK" -gt 1 ]; then
  RECORD_REASON="$NBLK structured verdict blocks were emitted (expected exactly one) — ambiguous output"
else
  REVIEW_BLOCK="$(printf '%s\n' "$FINDINGS" | _review_block)"
  if ! printf '%s' "$REVIEW_BLOCK" | jq -e . >/dev/null 2>&1; then
    RECORD_REASON="the structured verdict block is not valid JSON"
  elif ! printf '%s' "$REVIEW_BLOCK" | jq -e '(.verdict | type == "string") and (.verdict | IN("CLEAN","CONCERNS","BLOCK-RECOMMENDED")) and (.findings | type == "array") and (if .verdict == "CLEAN" then (.findings | length) == 0 else true end) and ((.findings | map(.id)) as $ids | ($ids | length) == ($ids | unique | length)) and (all(.findings[]; (has("id") and has("severity") and has("location") and has("finding") and has("suggested_fix")) and (.id | type == "string") and ((.id | length) > 0) and (.location | type == "string") and ((.location | length) > 0) and (.finding | type == "string") and ((.finding | length) > 0) and (.severity | type == "string") and (.severity | IN("CRITICAL","HIGH","MEDIUM","LOW","INFO")) and (.suggested_fix | type == "string") and ((.suggested_fix | length) > 0)))' >/dev/null 2>&1; then
    RECORD_REASON="the structured verdict block fails the schema (verdict enum; CLEAN => empty findings; unique non-empty ids; each finding a non-empty id, location, finding, an enum severity, and a non-empty suggested_fix)"
  else
    # canonical numeric PR key: the once-gate fires a URL, so ${PR##*/} extracts the number; a bare number maps
    # to itself; a branch-name invocation (no number in $PR) falls back to `gh pr view --json number`. A still
    # non-numeric key is REFUSED (mirrors forge_reconcile_run's all-digits guard, harness/beads-lib.sh:163) — a
    # mis-keyed record (review/feat/foo.json) is worse than none.
    PR_NUM="${PR##*/}"
    case "$PR_NUM" in '' | *[!0-9]*) PR_NUM="$(gh pr view "$PR" --repo "$REPO" --json number -q .number 2>/dev/null)" || PR_NUM="" ;; esac
    case "$PR_NUM" in '' | *[!0-9]*) PR_NUM="" ;; esac
    if [ -z "$PR_NUM" ]; then
      RECORD_REASON="could not derive a canonical numeric PR key from '$PR' — refusing a mis-keyed record"
    elif write_review_record "$PR_NUM" "$REVIEW_BLOCK"; then
      RECORD_OK=1
      echo "✓ review record persisted: .harness/review/$PR_NUM.json (verdict $(printf '%s' "$REVIEW_BLOCK" | jq -r .verdict 2>/dev/null))" >&2
    else
      RECORD_REASON="record write failed (could not persist .harness/review/$PR_NUM.json)"
    fi
  fi
fi
if [ "$RECORD_OK" != 1 ]; then
  REVIEW_BANNER="> ## ⚠️ REVIEW DID NOT PRODUCE A VALID STRUCTURED VERDICT — MANUAL VERIFICATION REQUIRED
>
> No structured review record was persisted (${RECORD_REASON}). The backend may be unfit for structured review. This stays advisory and **does not gate merge** (the deterministic test suite is the sole authority), but a human should **verify this PR manually** — do not treat the prose below as a recorded verdict.

"
fi

# --- post as a PLAIN, ADVISORY, NON-GATING PR comment (the harness posts, never the reviewer) ---
BODY="> ## 🤖 ADVISORY REVIEW — NON-GATING
>
> Automated adversarial review by a structurally-separated reviewer (backend: \`$BACKEND\`${MODEL:+, model: \`$MODEL\`}). **It does NOT gate merge.** The deterministic test suite is the sole merge authority. Treat every finding as a signal for a human to triage — not ground truth, and never a block. A weak/local reviewer can hallucinate findings; verify before acting.

---

$FINDINGS

---

_Generated by \`harness/review-task.sh\` · advisory only · merge is decided by a human on green tests._"

# Build 2a: prepend the loud banner (empty string for a valid record, so BODY is unchanged then) — advisory.
BODY="${REVIEW_BANNER}${BODY}"
POST_OK=1
printf '%s' "$BODY" | gh pr comment "$PR" --repo "$REPO" --body-file - \
  && echo "✓ advisory review posted to PR $PR (non-gating)." >&2 \
  || POST_OK=0
# Build 2a: the comment post is BEST-EFFORT; the RECORD is the durable, machine-readable trace (Build 2b +
# audit read .harness/review/<pr>.json), so a failed post never discards it and is NEVER a silent orphan.
# Surface a failed post LOUDLY for a standalone/CI runner; the fire-and-forget once-gate swallows stderr.
if [ "$POST_OK" != 1 ]; then
  if [ "${RECORD_OK:-0}" = 1 ]; then
    echo "review-task: ⚠️ the advisory comment post FAILED, but the structured record persisted at .harness/review/${PR_NUM:-?}.json (the durable trace) — verify the PR manually." >&2
  else
    echo "review-task: ⚠️ the advisory comment post FAILED and no valid structured record was produced (${RECORD_REASON:-unknown}) — verify the PR manually." >&2
  fi
fi
# ── Build 2b: adjudicate the reviewer's findings against the PR, then persist + post the dispositions ──
# ONE-SHOT (NOT a loop — a need for a second round means the upstream pipeline failed catastrophically and is
# an escalate-and-investigate signal, never a feature). Guarded on RECORD_OK=1 (a persisted reviewer record
# is the only thing worth adjudicating; $PR_NUM/$REVIEW_BLOCK/$HEAD_SHA are already in scope). FAIL-CLOSED on
# the disposition RECORD (a malformed/absent/schema-violating block => NO record + a loud notice). NON-gating
# on the MERGE: this whole tail rides the SAME fire-and-forget once-gate swallow as the reviewer
# (forge_review_feature_if_complete: >/dev/null 2>&1 || true; return 0) — it adds NO new exit and never
# touches RECORD_OK/POST_OK, so it can never gate cmd_finish.
if [ "${RECORD_OK:-0}" = 1 ]; then
  _DNF="$(printf '%s' "$REVIEW_BLOCK" | jq -r '(.findings // []) | length' 2>/dev/null)"
  case "$_DNF" in '' | *[!0-9]*) _DNF=0 ;; esac
  if [ "$_DNF" -eq 0 ]; then
    # CLEAN (findings: []) OR the 2a verdict-asymmetry case (a non-CLEAN verdict that itemized no findings):
    # there is nothing to adjudicate -> a clean no-op. No disposition record, no second comment, no loop.
    echo "→ disposition: the reviewer recorded 0 findings — nothing to adjudicate (no-op)." >&2
  else
    # backend: defaults to the reviewer's backend (one model to provision); set DISPOSITION_BACKEND in
    # harness/reviewers.config to a DIFFERENT family for provider diversity (the adjudicator should not be the
    # same model whose findings' cousins it is grading). Falls back to the reviewer backend when unset.
    DISP_BACKEND="${DISPOSITION_BACKEND:-$BACKEND}"
    # FOLD #14: refuse a non-allowlisted DISPOSITION_BACKEND. Neutralize it to an inert token
    # BEFORE the eval-indirection (so a metacharacter backend cannot command-substitute) and carry the
    # refusal into the fail-closed-on-RECORD path below. NON-gating (this tail adds NO exit).
    _DISP_BAD=""
    if ! _rt_known_backend "$DISP_BACKEND"; then _DISP_BAD="$DISP_BACKEND"; DISP_BACKEND="invalid-backend"; fi
    DISP_PREFIX="$(printf '%s' "$DISP_BACKEND" | tr '-' '_')"
    eval "DISP_MODEL=\${${DISP_PREFIX}_MODEL:-}"
    eval "DISP_ALLOWED_TOOLS=\${${DISP_PREFIX}_ALLOWED_TOOLS:-Read Grep Glob}"
    eval "DISP_SANDBOX=\${${DISP_PREFIX}_SANDBOX:-read-only}"
    DISP_AGENT="$ROOT/.claude/agents/disposition.md"
    DISP_OK=0; DISP_REASON=""; DISP_BLOCK=""
    if [ -n "$_DISP_BAD" ]; then
      DISP_REASON="DISPOSITION_BACKEND '$_DISP_BAD' is not a recognized backend (ollama|claude-fresh|codex) — refusing (an unvalidated backend is eval-expanded into a shell command). Set DISPOSITION_BACKEND in harness/reviewers.config."
    elif [ ! -f "$DISP_AGENT" ]; then
      DISP_REASON="missing .claude/agents/disposition.md (the adjudicator agent)"
    elif [ "$DISP_BACKEND" = "ollama" ] && [ -z "$DISP_MODEL" ]; then
      DISP_REASON="the ollama disposition backend requires an explicit model — set 'ollama_MODEL' (or a DISPOSITION_BACKEND with a model) in harness/reviewers.config"
    else
      DISP_PROMPT="$(awk 'BEGIN { fm = 0 } /^---[[:space:]]*$/ { fm++; next } fm >= 2 { print }' "$DISP_AGENT")"
      # the supplied findings = the persisted reviewer record's findings (id/severity/location/finding/
      # suggested_fix); the agent adjudicates THESE, it does not review the PR afresh.
      DISP_FINDINGS="$(printf '%s' "$REVIEW_BLOCK" | jq -c '{findings:(.findings // [])}' 2>/dev/null)"
      echo "→ adjudicating $_DNF reviewer finding(s) on PR $PR_NUM with backend '$DISP_BACKEND'${DISP_MODEL:+ (model: $DISP_MODEL)} — READ-ONLY, advisory" >&2
      DISP_OUTPUT="$(run_disposition)"; DDRC=$?
      DNBLK="$(printf '%s\n' "$DISP_OUTPUT" | grep -cF '<!-- forge:disposition:begin' 2>/dev/null)"
      case "$DNBLK" in '' | *[!0-9]*) DNBLK=0 ;; esac
      if [ -z "$DISP_OUTPUT" ]; then
        DISP_REASON="the disposition backend '$DISP_BACKEND' produced no output (rc=$DDRC) — likely unreachable/unconfigured"
      elif [ "$DNBLK" -eq 0 ]; then
        DISP_REASON="the disposition output carries no <!-- forge:disposition:begin --> block"
      elif [ "$DNBLK" -gt 1 ]; then
        DISP_REASON="$DNBLK disposition blocks were emitted (expected exactly one) — ambiguous output"
      else
        DISP_BLOCK="$(printf '%s\n' "$DISP_OUTPUT" | _disposition_block)"
        DISP_EXPECT_IDS="$(printf '%s' "$REVIEW_BLOCK" | jq -c '[.findings[].id] | sort' 2>/dev/null)"
        if ! printf '%s' "$DISP_BLOCK" | jq -e . >/dev/null 2>&1; then
          DISP_REASON="the disposition block is not valid JSON"
        elif ! printf '%s' "$DISP_BLOCK" | jq -e --argjson expect "$DISP_EXPECT_IDS" '(.dispositions | type == "array") and ((.dispositions | length) > 0) and ((.dispositions | map(.id)) as $ids | (($ids | length) == ($ids | unique | length)) and (($ids | sort) == $expect)) and (all(.dispositions[]; (keys == ["disposition","id","reasoning"]) and (.id | type == "string") and ((.id | length) > 0) and (.disposition | type == "string") and (.disposition | IN("CONFIRMED","REBUTTED")) and (.reasoning | type == "string") and ((.reasoning | gsub("\\s";"") | gsub("\\p{Cf}";"") | length) > 0)))' >/dev/null 2>&1; then
          DISP_REASON="the disposition block fails the schema (dispositions a non-empty array; each a non-empty id, a disposition in {CONFIRMED,REBUTTED}, and a non-empty reasoning; the id set must be EXACTLY the reviewer findings' ids — unique, none missing, none invented)"
        elif write_disposition_record "$PR_NUM" "$DISP_BLOCK"; then
          DISP_OK=1
          echo "✓ disposition record persisted: .harness/disposition/$PR_NUM.json ($(printf '%s' "$DISP_BLOCK" | jq -r '[.dispositions[]|select(.disposition=="CONFIRMED")]|length' 2>/dev/null) CONFIRMED / $(printf '%s' "$DISP_BLOCK" | jq -r '[.dispositions[]|select(.disposition=="REBUTTED")]|length' 2>/dev/null) REBUTTED)" >&2
        else
          DISP_REASON="disposition record write failed (could not persist .harness/disposition/$PR_NUM.json)"
        fi
      fi
    fi
    if [ "$DISP_OK" = 1 ]; then
      # post the per-finding verdicts as a SECOND, advisory PR comment — a CLEAN APPEND (no --edit-last), so
      # the reviewer's comment and this one read as a verified conversation where the human merges.
      DISP_BODY="> ## 🧭 FIX-DISPOSITION — ADVISORY, NON-GATING
>
> Each finding from the advisory review above, adjudicated against this PR by a structurally-separated read-only adjudicator (backend: \`$DISP_BACKEND\`${DISP_MODEL:+, model: \`$DISP_MODEL\`}) — **CONFIRMED** (a real defect, verified against the diff) or **REBUTTED** (not an issue). **It does NOT gate merge.** The deterministic test suite is the sole authority; act on the CONFIRMED findings, and verify before you do.

| Finding | Disposition | Reasoning |
| ------- | ----------- | --------- |
$(printf '%s' "$DISP_BLOCK" | jq -r '.dispositions[] | "| \(.id) | \(.disposition) | \(.reasoning | gsub("[\\r\\n|]"; " ")) |"' 2>/dev/null)

---

_Generated by \`harness/review-task.sh\` (Build 2b) · advisory only · sibling record: \`.harness/disposition/$PR_NUM.json\`._"
      if printf '%s' "$DISP_BODY" | gh pr comment "$PR" --repo "$REPO" --body-file - >/dev/null 2>&1; then
        echo "✓ disposition comment posted to PR $PR (non-gating)." >&2
      else
        # the comment is BEST-EFFORT; the record is the durable trace (already persisted), never discarded.
        echo "review-task: ⚠️ the disposition comment post FAILED, but the disposition record persisted at .harness/disposition/$PR_NUM.json (the durable trace) — verify the PR manually." >&2
      fi
    else
      # FAIL-CLOSED on the disposition RECORD: none was written; surface it LOUDLY. NON-gating — NO exit change
      # (the reviewer record + comment already succeeded; the merge is decided by green tests + a human).
      echo "review-task: ⚠️ no structured disposition record persisted (${DISP_REASON:-unknown}) — the reviewer's findings were not adjudicated; verify the PR manually (advisory; does NOT gate merge)." >&2
    fi
  fi
fi
# Build 2a: fail-closed-loud on the RECORD, never on the MERGE — a non-zero exit when no valid record was
# persisted (after the post attempt). Swallowed by the fire-and-forget once-gate, so it NEVER gates cmd_finish.
if [ "${RECORD_OK:-0}" != 1 ]; then
  echo "review-task: ⚠️ no structured review record persisted (${RECORD_REASON:-unknown}) — manual verification required (advisory; does NOT gate merge)" >&2
  exit 3
fi
[ "$POST_OK" = 1 ] || exit 4
exit 0
