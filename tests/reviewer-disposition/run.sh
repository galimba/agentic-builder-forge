#!/usr/bin/env bash
# tests/reviewer-disposition/run.sh — Build 2b: the fix-disposition consumer.
#
# Proves, each RED-first, that AFTER the reviewer persists its record (Build 2a), the harness adjudicates the
# reviewer's findings AGAINST the PR (CONFIRMED/REBUTTED), persists a SIBLING .harness/disposition/<pr>.json,
# and posts a SECOND advisory PR comment — FAIL-CLOSED on the disposition RECORD, NON-gating on the MERGE,
# ONE-SHOT (never a loop):
#   Part A  the adjudicator agent — .claude/agents/disposition.md is read-only (tools: Read, Grep, Glob),
#           uses the PR-side verbs CONFIRMED/REBUTTED (NEVER the intake ACCEPT/ESCALATE), inherits the
#           verify-against-artifact rule, adjudicates the SUPPLIED findings (does not hunt new ones), and
#           emits a sentinel-bounded machine block as its terminal element.
#   Part B  run_disposition + extract + persist + post (all INLINE in review-task.sh): a well-formed block ->
#           dispositions extracted, schema-valid, persisted to .harness/disposition/<pr>.json + a second
#           comment posted; a malformed/absent/schema-violating block -> NO record + a loud notice; a CLEAN
#           (or empty-findings) reviewer record -> a no-op; the merge stays non-gating (no path fails finish).
#   Part C  invariants — the disposition agent + reviewer allowlists are read-only; the real .beads is
#           byte-unchanged; the real $ROOT/.harness/{disposition,review} grow no pollution.
#
# RED/GREEN seam (the Build-2a FORGE_REVIEW_RECORD_CANDIDATE analogue): FORGE_REVIEW_DISPOSITION_CANDIDATE
# points at the dir holding apply-candidate.py; the suite materializes a throwaway harness = DEPLOYED +
# applier and tests THAT — "a test verifies what ships."
#   bash tests/reviewer-disposition/run.sh
#       -> deployed, pre-splice: run_disposition is ABSENT -> SKIP rc 75 (keeps the canonical gate green;
#          AUTO-ACTIVATES PASS-required once the door splice lands and the fn is in the deployed tree).
#   FORGE_REVIEW_DISPOSITION_CANDIDATE=sandbox/reviewer-disposition bash tests/reviewer-disposition/run.sh
#       -> candidate applied -> GREEN (every arm passes).
#   FORGE_REVIEW_DISPOSITION_PROVE_RED=1 bash tests/reviewer-disposition/run.sh
#       -> forces the GREEN arms against the DEPLOYED harness -> the positive arms FAIL (the RED proof).
#
# NOTE on the disposition.md contract (Part A0): disposition.md is DIRECTLY writable (committed as a normal
# edit, not spliced through the door), so the A0 doc-contract checks read the live $ROOT/.claude/agents/
# disposition.md — GREEN once the edit lands on the branch. Its RED proof is vs origin/main (absent there).
#
# THROWAWAY fixtures only; the REAL $ROOT/.beads ledger is byte-guarded. No docker, no bd, no network: the
# backends are faked (pure text in/out, the fake ollama keys off the disposition sentinel to route the two
# calls) and gh is a stub. Mechanism only: bash + jq + awk + exit codes.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  PASS [%s]\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
skp() { SKIP=$((SKIP+1)); printf '  SKIP [%s] %s\n' "$1" "${2:-}"; }

command -v jq      >/dev/null 2>&1 || { echo "FAIL: jq is required";      exit 1; }
command -v git     >/dev/null 2>&1 || { echo "FAIL: git is required";     exit 1; }
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
# ---- real-$ROOT/.harness/{disposition,review} must NOT be created/changed by this suite ----
REAL_DISP_DIR="$ROOT/.harness/disposition"
REAL_DISP_BEFORE="absent"; [ -d "$REAL_DISP_DIR" ] && REAL_DISP_BEFORE="present"
REAL_REVIEW_DIR="$ROOT/.harness/review"
REAL_REVIEW_BEFORE="absent"; [ -d "$REAL_REVIEW_DIR" ] && REAL_REVIEW_BEFORE="present"

# ── materialize the harness-under-test (HUT): DEPLOYED, optionally + the candidate applier ──
HUT="$ROOT/harness"
if [ -n "${FORGE_REVIEW_DISPOSITION_CANDIDATE:-}" ]; then
  CAND="$FORGE_REVIEW_DISPOSITION_CANDIDATE"; case "$CAND" in /*) : ;; *) CAND="$ROOT/$CAND" ;; esac
  [ -f "$CAND/apply-candidate.py" ] || { echo "FAIL: no apply-candidate.py at $CAND"; exit 1; }
  HUT="$TMPROOT/hut"; mkdir -p "$HUT"
  cp "$ROOT/harness/"*.sh "$HUT/" 2>/dev/null
  cp "$ROOT/harness/"*.config "$HUT/" 2>/dev/null
  python3 "$CAND/apply-candidate.py" "$HUT" || { echo "FAIL: apply-candidate.py failed against $HUT"; exit 1; }
fi

HAS_DISP=0; grep -q 'run_disposition' "$HUT/review-task.sh" 2>/dev/null && HAS_DISP=1
# Finding B: the KEY-STRICT disposition validator (door-spliced into review-task.sh). Its marker is the exact
# sorted key-set literal, absent from the loose validator. The B arms (D6b) gate on this so the canonical gate
# stays GREEN until the validator tightening is spliced; PROVE_RED forces them anyway (the RED proof).
HAS_STRICT=0; grep -qF '["disposition","id","reasoning"]' "$HUT/review-task.sh" 2>/dev/null && HAS_STRICT=1

echo "============================================================"
echo "Build 2b reviewer-disposition — HUT: $HUT (run_disposition present=$HAS_DISP)"
echo "============================================================"

if [ "$HAS_DISP" != 1 ] && [ "${FORGE_REVIEW_DISPOSITION_PROVE_RED:-0}" != 1 ]; then
  echo "SKIP: Build 2b (fix-disposition consumer) is not yet spliced into $HUT."
  echo "      prove GREEN:  FORGE_REVIEW_DISPOSITION_CANDIDATE=sandbox/reviewer-disposition bash tests/reviewer-disposition/run.sh"
  echo "      prove RED:    FORGE_REVIEW_DISPOSITION_PROVE_RED=1 bash tests/reviewer-disposition/run.sh"
  echo "      This SKIP (rc 75) keeps the canonical gate green pre-splice; auto-activates PASS-required"
  echo "      once the door splice lands and run_disposition is in the deployed harness."
  exit 75
fi
[ "$HAS_DISP" = 1 ] || echo ">> FORGE_REVIEW_DISPOSITION_PROVE_RED=1 — running the GREEN arms against the UNSPLICED harness; expect the positive arms to FAIL (this IS the RED proof)."

# ── a ROOT review-task.sh can run inside: git repo + lib.sh + reviewer.md + disposition.md + bin/ fakes ──
mk_disp_root() {
  local R; R="$(mktemp -d -p "$TMPROOT")"
  mkdir -p "$R/harness" "$R/.claude/hooks" "$R/.claude/agents" "$R/bin" "$R/.beads" "$R/.cap"
  cp "$HUT/review-task.sh" "$R/harness/review-task.sh"; chmod +x "$R/harness/review-task.sh"
  cp "$ROOT/.claude/hooks/lib.sh" "$R/.claude/hooks/lib.sh"
  cp "$ROOT/.claude/agents/reviewer.md" "$R/.claude/agents/reviewer.md"
  # the REAL disposition agent (so run_disposition loads its real body; the fake ollama keys off its sentinel)
  [ -f "$ROOT/.claude/agents/disposition.md" ] && cp "$ROOT/.claude/agents/disposition.md" "$R/.claude/agents/disposition.md"
  printf 'ollama_MODEL="fakemodel"\n' > "$R/harness/reviewers.config"
  : > "$R/backend.out"; : > "$R/disp.out"
  # fake gh: logs calls; stubs pr diff / pr view (headRefOid -> HEAD sha ; number -> 9) / pr comment / repo view.
  # Two `pr comment` calls now arrive (reviewer, then disposition) — route by body content; allow each to be
  # made to fail independently (.fail-comment / .fail-disp-comment) so the non-gating canaries are precise.
  cat >"$R/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$R/.gh-calls.log"
case "\$1 \$2" in
  "pr diff")    printf 'diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n+changed\n' ;;
  "pr view")    if printf '%s' "\$*" | grep -q 'number'; then printf '9\n'; else git -C "$R" rev-parse HEAD 2>/dev/null; fi ;;
  "pr comment")
    body="\$(cat)"
    if printf '%s' "\$body" | grep -q 'FIX-DISPOSITION'; then
      [ -f "$R/.fail-disp-comment" ] && exit 1
      printf '%s' "\$body" > "$R/.cap/disp-comment.body"
    else
      [ -f "$R/.fail-comment" ] && exit 1
      printf '%s' "\$body" > "$R/.cap/review-comment.body"
    fi
    printf 'https://github.com/o/r/pull/9#c1\n' ;;
  "repo view")  printf 'o/r\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
  # fake ollama: pure text in/out. Routes the TWO calls by content — the disposition prompt carries the
  # disposition sentinel (from the real disposition.md body), the reviewer prompt does not.
  cat >"$R/bin/ollama" <<EOF
#!/usr/bin/env bash
in="\$(cat)"
if printf '%s' "\$in" | grep -q 'forge:disposition'; then
  printf '%s' "\$in" > "$R/.cap/ollama.disp.stdin"
  cat "$R/disp.out" 2>/dev/null
else
  printf '%s' "\$in" > "$R/.cap/ollama.review.stdin"
  cat "$R/backend.out" 2>/dev/null
fi
EOF
  chmod +x "$R/bin/gh" "$R/bin/ollama"
  ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
      && git symbolic-ref HEAD refs/heads/main \
      && printf 'base\n' > README.md && git add README.md && git commit -q -m base ) >/dev/null 2>&1
  printf '%s' "$R"
}
run_review() {  # <root> <pr-arg>   -> sets RRC ; stderr in $LASTERR ; $R/backend.out=reviewer out, $R/disp.out=disposition out
  local R="$1" prarg="$2"
  LASTERR="$R/.stderr"
  ( cd "$R" || exit 1
    export PATH="$R/bin:$PATH" REVIEWER_BACKEND="ollama"
    bash harness/review-task.sh "$prarg" --repo o/r >/dev/null 2>"$LASTERR" )
  RRC=$?
}
disp_path() { printf '%s/.harness/disposition/%s.json' "$1" "$2"; }
rev_path()  { printf '%s/.harness/review/%s.json' "$1" "$2"; }
# no_disp_record: TRUE iff NO disposition json exists ANYWHERE under the root's disposition dir — stronger
# than checking one key, so a mis-keyed/orphan record cannot pass as "fail-closed".
no_disp_record() { [ -z "$(find "$1/.harness/disposition" -name '*.json' 2>/dev/null)" ]; }

# ── reviewer-output fixtures (sets $R/backend.out — the reviewer's stdout, persisted by 2a as the record) ──
rev_two_findings() {  # CONCERNS, 2 discretely-addressable findings F1/F2 -> 2a record has F1,F2 to adjudicate
  cat > "$1/backend.out" <<'OUT'
### Reviewer verdict: CONCERNS

| #  | Severity | File:line                  | Finding   | Why | Suggested fix |
| F1 | HIGH     | harness/review-task.sh:212 | raw embed | ... | keep advisory |

### Summary

Two concerns.

<!-- forge:review:begin v1 -->

```json
{"verdict":"CONCERNS","findings":[{"id":"F1","severity":"HIGH","location":"harness/review-task.sh:212","finding":"raw embed of FINDINGS into the comment body","suggested_fix":"acceptable; advisory only"},{"id":"F2","severity":"LOW","location":"harness/x.sh:9","finding":"a nit","suggested_fix":"rename the var"}]}
```

<!-- forge:review:end v1 -->
OUT
}
rev_clean() {  # CLEAN -> findings [] -> disposition no-op
  cat > "$1/backend.out" <<'OUT'
### Reviewer verdict: CLEAN

Looks clean.

<!-- forge:review:begin v1 -->
{"verdict":"CLEAN","findings":[]}
<!-- forge:review:end v1 -->
OUT
}
rev_concerns_empty() {  # the 2a verdict-asymmetry case: a non-CLEAN verdict that itemized NO findings -> no-op
  cat > "$1/backend.out" <<'OUT'
### Reviewer verdict: CONCERNS

Concerns in prose but nothing itemized.

<!-- forge:review:begin v1 -->
{"verdict":"CONCERNS","findings":[]}
<!-- forge:review:end v1 -->
OUT
}

# ── disposition-output fixtures (sets $R/disp.out — the disposition agent's stdout; REAL fenced+sentinel block) ──
disp_valid() {  # F1 CONFIRMED, F2 REBUTTED — exactly the reviewer's id set
  cat > "$1/disp.out" <<'OUT'
### Disposition verdicts

| Finding | Disposition | Reasoning |
| F1 | CONFIRMED | the diff embeds raw findings as claimed |
| F2 | REBUTTED  | the cited nit is already handled |

### Summary

1 CONFIRMED, 1 REBUTTED.

<!-- forge:disposition:begin v1 -->

```json
{"dispositions":[{"id":"F1","disposition":"CONFIRMED","reasoning":"the diff at the cited line really embeds raw findings"},{"id":"F2","disposition":"REBUTTED","reasoning":"the nit does not hold; the code already handles it"}]}
```

<!-- forge:disposition:end v1 -->
OUT
}
disp_valid_multiline() {  # "test what ships": the EXACT pretty-printed multi-line JSON shape disposition.md emits
  cat > "$1/disp.out" <<'OUT'
### Disposition verdicts

| Finding | Disposition | Reasoning |
| F1 | CONFIRMED | real |
| F2 | REBUTTED  | not an issue |

### Summary

1 CONFIRMED, 1 REBUTTED.

<!-- forge:disposition:begin v1 -->

```json
{
  "dispositions": [
    {
      "id": "F1",
      "disposition": "CONFIRMED",
      "reasoning": "the diff really embeds raw findings at the cited line"
    },
    {
      "id": "F2",
      "disposition": "REBUTTED",
      "reasoning": "the nit does not hold; already handled"
    }
  ]
}
```

<!-- forge:disposition:end v1 -->
OUT
}
disp_absent() {  # prose + verdicts, NO sentinel block
  cat > "$1/disp.out" <<'OUT'
### Disposition verdicts

I adjudicated but forgot to emit the machine block.
OUT
}
disp_malformed() {  # sentinels present, JSON broken
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"CONFIRMED", BROKEN
<!-- forge:disposition:end v1 -->
OUT
}
disp_badenum_accept() {  # the POLARITY TRAP: the intake verb ACCEPT is NOT a valid disposition -> REFUSED
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"ACCEPT","reasoning":"x"},{"id":"F2","disposition":"ESCALATE","reasoning":"y"}]}
<!-- forge:disposition:end v1 -->
OUT
}
disp_empty_reasoning() {  # a disposition with an EMPTY reasoning -> REFUSED
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"CONFIRMED","reasoning":"ok"},{"id":"F2","disposition":"REBUTTED","reasoning":""}]}
<!-- forge:disposition:end v1 -->
OUT
}
disp_invented_id() {  # an id (F3) the reviewer never raised -> REFUSED (no fabricated ids)
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"CONFIRMED","reasoning":"a"},{"id":"F2","disposition":"REBUTTED","reasoning":"b"},{"id":"F3","disposition":"CONFIRMED","reasoning":"invented"}]}
<!-- forge:disposition:end v1 -->
OUT
}
disp_missing_id() {  # only F1 adjudicated; F2 silently dropped -> REFUSED (every finding must be adjudicated)
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"CONFIRMED","reasoning":"a"}]}
<!-- forge:disposition:end v1 -->
OUT
}
disp_dup_id() {  # F1 adjudicated twice -> REFUSED (not discretely 1:1)
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"CONFIRMED","reasoning":"a"},{"id":"F1","disposition":"REBUTTED","reasoning":"b"}]}
<!-- forge:disposition:end v1 -->
OUT
}
disp_double_block() {  # TWO begin sentinels -> ambiguous -> REFUSED
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"CONFIRMED","reasoning":"a"},{"id":"F2","disposition":"REBUTTED","reasoning":"b"}]}
<!-- forge:disposition:end v1 -->
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"REBUTTED","reasoning":"c"},{"id":"F2","disposition":"CONFIRMED","reasoning":"d"}]}
<!-- forge:disposition:end v1 -->
OUT
}
disp_swap_one() {  # for idempotency: a DIFFERENT valid adjudication of the same F1/F2 (both CONFIRMED)
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"CONFIRMED","reasoning":"still real"},{"id":"F2","disposition":"CONFIRMED","reasoning":"now also confirmed"}]}
<!-- forge:disposition:end v1 -->
OUT
}
disp_extra_key() {  # Finding B: a VALID F1/F2 adjudication carrying an EXTRA per-element key -> key-strict REFUSE
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"CONFIRMED","reasoning":"real","x_injected":"ARBITRARY-BLOB"},{"id":"F2","disposition":"REBUTTED","reasoning":"nope"}]}
<!-- forge:disposition:end v1 -->
OUT
}
disp_ws_reasoning() {  # Finding B: a WHITESPACE-ONLY reasoning (length>0 but no content) -> trim-then-REFUSE
  cat > "$1/disp.out" <<'OUT'
<!-- forge:disposition:begin v1 -->
{"dispositions":[{"id":"F1","disposition":"CONFIRMED","reasoning":"real"},{"id":"F2","disposition":"REBUTTED","reasoning":"   "}]}
<!-- forge:disposition:end v1 -->
OUT
}
disp_zerowidth_reasoning() {  # Finding B: a reasoning of ONLY zero-width FORMAT chars (Cf) -> REFUSE
  # U+200B (ZERO WIDTH SPACE) built from its octal UTF-8 bytes \342\200\213 so the source stays plain-ASCII
  # readable (no invisible bytes); these are category Cf, NOT \s, so they exercise the gsub("\\p{Cf}") arm.
  local zw; zw="$(printf '\342\200\213\342\200\213')"
  { printf '<!-- forge:disposition:begin v1 -->\n'
    jq -nc --arg z "$zw" '{dispositions:[{id:"F1",disposition:"CONFIRMED",reasoning:"real"},{id:"F2",disposition:"REBUTTED",reasoning:$z}]}'
    printf '\n<!-- forge:disposition:end v1 -->\n'
  } > "$1/disp.out"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part A0 — the disposition.md contract DOC (committed direct; RED vs origin/main where it is absent)
# ════════════════════════════════════════════════════════════════════════════════════════════════
# a0_meaning_bound <disposition.md> -> 0 iff the OPERATIVE prose binds CONFIRMED->"real defect" and
# REBUTTED->"not an issue". Scoped to the body AFTER the frontmatter (the 2nd '---') — the SAME body the
# harness feeds the agent as its system prompt (review-task.sh) — NOT the whole file: the frontmatter
# `description:` restates both meanings on ONE line, so a whole-file grep is satisfied by the description
# ALONE, and a semantic inversion of the operative definitions (the lines the agent actually OBEYS) with the
# description left intact would slip through. Scoping to the body closes that polarity trap WITHOUT coupling
# to the exact bullet markup (a reformat/indent of the bullet does not false-RED a correct agent). The phrase
# "real defect"/"not an issue" is the contract vocabulary (it recurs in the description + the output spec), so
# a synonym reword is a contract change that should update this guard. A0c proves both directions.
a0_meaning_bound() {
  local body; body="$(awk 'BEGIN { fm = 0 } /^---[[:space:]]*$/ { fm++; next } fm >= 2 { print }' "$1")"
  printf '%s\n' "$body" | grep -qE 'CONFIRMED[^[:alnum:]].*real defect' \
    && printf '%s\n' "$body" | grep -qE 'REBUTTED[^[:alnum:]].*not an issue'
}
echo "== A0: disposition.md is a read-only adjudicator that uses CONFIRMED/REBUTTED + emits a machine block =="
DM="$ROOT/.claude/agents/disposition.md"
if [ -f "$DM" ]; then
  grep -qE '^tools:[[:space:]]*Read,[[:space:]]*Grep,[[:space:]]*Glob[[:space:]]*$' "$DM" \
    && ok "A0: disposition.md frontmatter is read-only 'tools: Read, Grep, Glob'" || no "A0: disposition.md allowlist is not read-only"
  grep -q '<!-- forge:disposition:begin v1 -->' "$DM" && grep -q '<!-- forge:disposition:end v1 -->' "$DM" \
    && ok "A0: disposition.md carries the disposition begin/end sentinels" || no "A0: disposition.md lacks the disposition sentinels (RED on origin/main)"
  grep -qw 'CONFIRMED' "$DM" && grep -qw 'REBUTTED' "$DM" \
    && ok "A0: disposition.md uses the PR-side verbs CONFIRMED/REBUTTED" || no "A0: disposition.md missing CONFIRMED/REBUTTED"
  # THE POLARITY GUARD: the intake verbs ACCEPT/ESCALATE must NEVER appear (a copy of them inverts the build).
  grep -qE 'ACCEPT|ESCALATE' "$DM" \
    && no "A0: disposition.md contains the intake verbs ACCEPT/ESCALATE — the polarity is INVERTED" || ok "A0: disposition.md never uses the intake verbs ACCEPT/ESCALATE (polarity correct)"
  # THE MEANING GUARD: the words alone are not enough — a semantic inversion (keep CONFIRMED/REBUTTED but
  # swap their DEFINITIONS, e.g. "CONFIRMED = drop the finding") would pass every word-presence check above.
  # Bind each verb to its OPERATIVE meaning via a0_meaning_bound (anchored to the operative bullets, NOT the
  # whole file — the frontmatter description must not be able to satisfy it; A0c proves the bind both ways).
  a0_meaning_bound "$DM" \
    && ok "A0: the MEANING is pinned to the operative bullets — CONFIRMED='real defect', REBUTTED='not an issue'" || no "A0: the CONFIRMED/REBUTTED meaning is not bound to 'real defect'/'not an issue' — a semantic inversion would pass silently"
  grep -q 'nothing after the closing' "$DM" \
    && ok "A0: disposition.md pins the block as the terminal element" || no "A0: disposition.md does not pin 'nothing after the closing' sentinel"
  for k in id disposition reasoning; do
    grep -q "$k" "$DM" || no "A0: disposition.md schema is missing key '$k'"
  done
  grep -qi 'verif' "$DM" && grep -qi 'say-so\|artifact' "$DM" \
    && ok "A0: disposition.md inherits the verify-against-the-artifact rule" || no "A0: disposition.md does not state the verify-against-artifact discipline"
  grep -qi 'do not\|does not\|not.*hunt\|not.*new' "$DM" && grep -qi 'supplied' "$DM" \
    && ok "A0: disposition.md adjudicates the SUPPLIED findings (does not hunt new ones)" || no "A0: disposition.md does not constrain to the supplied findings"
  # A0c: the MEANING-bind CANARY — prove a0_meaning_bound actually CATCHES an operatively-inverted agent (the
  # bypass a whole-file grep missed). Build a copy with the two operative definition bullets' meanings SWAPPED
  # but the frontmatter `description:` (line 3) left byte-intact, then assert the guard REJECTS it AND still
  # ACCEPTS the correct shipped agent. Without this, a "stricter-looking" grep that still doesn't bind the
  # operative meaning would pass unnoticed (a different porous guard).
  INVDM="$(mktemp "$TMPROOT/invdisp.XXXXXX")"
  awk '
    /^- \*\*CONFIRMED\*\*.*real defect/ { sub(/real defect/, "not an issue"); print; next }
    /^- \*\*REBUTTED\*\*.*not an issue/ { sub(/not an issue/, "real defect"); print; next }
    { print }
  ' "$DM" > "$INVDM"
  # a SECOND, fully-REWORDED inversion (not the phrase-swap above) — proves the guard is a POSITIVE meaning
  # bind, not merely a detector of the exact swap (closes the "A0c only probes one inversion" objection).
  INVDM2="$(mktemp "$TMPROOT/invdisp2.XXXXXX")"
  awk '
    /^- \*\*CONFIRMED\*\*/ { print "- **CONFIRMED** — the finding is harmless noise; drop it."; next }
    /^- \*\*REBUTTED\*\*/  { print "- **REBUTTED** — the finding is a genuine bug the human must act on."; next }
    { print }
  ' "$DM" > "$INVDM2"
  if grep -qE '^- \*\*CONFIRMED\*\*.*not an issue' "$INVDM" && grep -qE '^- \*\*REBUTTED\*\*.*real defect' "$INVDM"; then
    a0_meaning_bound "$INVDM" \
      && no "A0c: the meaning guard PASSED an operatively-inverted agent (polarity trap OPEN) — frontmatter line 3 alone satisfied it" \
      || ok "A0c: the meaning guard REJECTS an operatively-inverted agent (frontmatter line 3 cannot satisfy it — trap CLOSED)"
    a0_meaning_bound "$INVDM2" \
      && no "A0c: the meaning guard PASSED a fully-reworded operative inversion (positive bind NOT enforced)" \
      || ok "A0c: the meaning guard REJECTS a fully-reworded operative inversion too (binds meaning, not just the phrase-swap)"
    a0_meaning_bound "$DM" \
      && ok "A0c: the meaning guard still ACCEPTS the correct shipped disposition.md (bound, not brittle)" \
      || no "A0c: the meaning guard rejects the CORRECT shipped agent (too brittle — fix the anchor)"
  else
    no "A0c: could not construct the operatively-inverted fixture (the bullet anchors drifted) — update the canary"
  fi
else
  no "A0: .claude/agents/disposition.md is absent (RED on origin/main — author it as a direct edit)"
fi

if [ "$HAS_DISP" != 1 ]; then
  echo ">> (PROVE_RED) skipping the runtime arms' GREEN assertions is NOT done — they run below and FAIL on the unspliced harness."
fi

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part B — run_disposition + extract + persist + post (the consumer)
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== D1: a VALID reviewer record (F1,F2) + a well-formed disposition block -> sibling record + 2nd comment =="
R="$(mk_disp_root)"; rev_two_findings "$R"; disp_valid "$R"
run_review "$R" "https://github.com/o/r/pull/9"
DREC="$(disp_path "$R" 9)"
[ -f "$DREC" ] && jq -e . "$DREC" >/dev/null 2>&1 && ok "D1: sibling record .harness/disposition/9.json exists + is valid JSON" || no "D1: no/invalid disposition record" "rc=$RRC $(tail -1 "$LASTERR" 2>/dev/null)"
[ "$(jq -r '.dispositions | length' "$DREC" 2>/dev/null)" = "2" ] && ok "D1: both dispositions persisted (F1,F2)" || no "D1: dispositions not preserved"
[ "$(jq -r '.dispositions[] | select(.id=="F1") | .disposition' "$DREC" 2>/dev/null)" = "CONFIRMED" ] && ok "D1: F1 -> CONFIRMED" || no "D1: F1 disposition wrong"
[ "$(jq -r '.dispositions[] | select(.id=="F2") | .disposition' "$DREC" 2>/dev/null)" = "REBUTTED" ] && ok "D1: F2 -> REBUTTED" || no "D1: F2 disposition wrong"
[ -f "$R/.cap/disp-comment.body" ] && grep -q 'FIX-DISPOSITION' "$R/.cap/disp-comment.body" 2>/dev/null && ok "D1: a SECOND advisory PR comment (FIX-DISPOSITION) was posted" || no "D1: no disposition comment posted"
grep -q 'CONFIRMED' "$R/.cap/disp-comment.body" 2>/dev/null && grep -q 'REBUTTED' "$R/.cap/disp-comment.body" 2>/dev/null && ok "D1: the comment carries the per-finding verdicts" || no "D1: comment missing the per-finding verdicts"
[ -f "$R/.cap/review-comment.body" ] && ok "D1: the reviewer's first comment is still posted (the conversation reads in order)" || no "D1: reviewer comment missing"
[ "$RRC" = "0" ] && ok "D1: exit 0 (the disposition tail adds no new exit)" || no "D1: non-zero exit (rc=$RRC)"
# THE CORE DATA-FLOW (Build 2b's whole point): the reviewer's findings + the PR diff must actually REACH the
# adjudicator backend. The fake routes on the always-present sentinel, so without these the suite would stay
# GREEN even if DISP_FINDINGS regressed to empty — assert the captured backend stdin carries the real inputs.
DSTDIN="$R/.cap/ollama.disp.stdin"
[ -f "$DSTDIN" ] && grep -q '<reviewer-findings>' "$DSTDIN" 2>/dev/null && ok "D1: the reviewer's findings were DELIVERED to the adjudicator (the <reviewer-findings> wrapper)" || no "D1: <reviewer-findings> never reached the disposition backend"
grep -q '"F1"' "$DSTDIN" 2>/dev/null && grep -q '"F2"' "$DSTDIN" 2>/dev/null && ok "D1: BOTH finding ids (F1,F2) reached the adjudicator (not an empty/garbage payload)" || no "D1: the reviewer finding ids did not reach the backend"
grep -q 'review-task.sh:212' "$DSTDIN" 2>/dev/null && ok "D1: the finding DETAILS (location) reached the adjudicator, not just ids" || no "D1: finding details not delivered"
grep -q '<diff>' "$DSTDIN" 2>/dev/null && grep -q 'changed' "$DSTDIN" 2>/dev/null && ok "D1: the PR diff reached the adjudicator (so it can verify against the artifact)" || no "D1: the PR diff was not delivered to the adjudicator"

echo "== D1b: 'test what ships' — the agent's REAL pretty-printed multi-line fenced block extracts + validates =="
R="$(mk_disp_root)"; rev_two_findings "$R"; disp_valid_multiline "$R"
run_review "$R" "https://github.com/o/r/pull/9"
DREC="$(disp_path "$R" 9)"
[ -f "$DREC" ] && jq -e . "$DREC" >/dev/null 2>&1 && ok "D1b: a multi-line fenced disposition block (as disposition.md emits) extracts + persists" || no "D1b: the multi-line block did not extract" "rc=$RRC $(tail -1 "$LASTERR" 2>/dev/null)"
[ "$(jq -r '.dispositions | length' "$DREC" 2>/dev/null)" = "2" ] && ok "D1b: both dispositions parsed from the pretty-printed JSON" || no "D1b: dispositions not parsed from multi-line JSON"

echo "== D2: NON-GATING canary — a malformed disposition block -> NO record + loud notice, finish still succeeds =="
R="$(mk_disp_root)"; rev_two_findings "$R"; disp_malformed "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_disp_record "$R" && ok "D2: no disposition record for a malformed block (fail-closed on the record)" || no "D2: a disposition record was fabricated"
[ -f "$(rev_path "$R" 9)" ] && jq -e '.verdict=="CONCERNS"' "$(rev_path "$R" 9)" >/dev/null 2>&1 && ok "D2: the reviewer record is UNAFFECTED (still persisted)" || no "D2: the reviewer record was disturbed"
grep -q 'no structured disposition record persisted' "$LASTERR" 2>/dev/null && ok "D2: stderr LOUDLY reports the no-disposition-record path" || no "D2: the disposition failure is not surfaced loudly" "$(tail -1 "$LASTERR" 2>/dev/null)"
[ "$RRC" = "0" ] && ok "D2: cmd_finish path still exits 0 — a disposition failure NEVER gates the merge" || no "D2: a disposition failure changed the exit (rc=$RRC) — GATING REGRESSION"

echo "== D3: CLEAN reviewer record (findings []) -> disposition NO-OP (no record, no second comment) =="
R="$(mk_disp_root)"; rev_clean "$R"; disp_valid "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_disp_record "$R" && ok "D3: no disposition record for a CLEAN reviewer record (nothing to adjudicate)" || no "D3: adjudicated a CLEAN record"
[ ! -f "$R/.cap/disp-comment.body" ] && ok "D3: no second comment posted on CLEAN (one-shot, no-loop respected)" || no "D3: a disposition comment was posted for a CLEAN record"
[ -z "$(cat "$R/.cap/ollama.disp.stdin" 2>/dev/null)" ] && ok "D3: the disposition backend was never even invoked (true no-op)" || no "D3: the disposition backend ran on a CLEAN record"
[ "$RRC" = "0" ] && ok "D3: clean exit on the CLEAN no-op" || no "D3: non-zero exit on a CLEAN no-op (rc=$RRC)"

echo "== D3b: the 2a verdict-asymmetry case (non-CLEAN verdict, empty findings) -> also a NO-OP =="
R="$(mk_disp_root)"; rev_concerns_empty "$R"; disp_valid "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_disp_record "$R" && [ ! -f "$R/.cap/disp-comment.body" ] && ok "D3b: a CONCERNS verdict with empty findings is a no-op (no findings to confirm/rebut)" || no "D3b: adjudicated a verdict with no itemized findings"

echo "== D4: the disposition agent is READ-ONLY — run_disposition applies the SAME --disallowedTools as run_reviewer =="
# slice the run_disposition function body and assert the write-tool denylist is present inside it.
DISP_FN="$(awk '/^run_disposition\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$HUT/review-task.sh" 2>/dev/null)"
printf '%s' "$DISP_FN" | grep -q -- '--disallowedTools Bash Write Edit MultiEdit NotebookEdit' \
  && ok "D4: run_disposition's claude-fresh arm denies Bash/Write/Edit/MultiEdit/NotebookEdit (read-only)" || no "D4: run_disposition is missing the write-tool denylist (NOT read-only)"
printf '%s' "$DISP_FN" | grep -q 'codex exec --sandbox' \
  && ok "D4: run_disposition's codex arm uses --sandbox (native read-only)" || no "D4: run_disposition codex arm not sandboxed"
NDENY="$(grep -c -- '--disallowedTools Bash Write Edit MultiEdit NotebookEdit' "$HUT/review-task.sh" 2>/dev/null)"
[ "${NDENY:-0}" -ge 2 ] && ok "D4: the write-tool denylist now appears for BOTH reviewer + disposition" || no "D4: denylist count is $NDENY (expected >=2)"

echo "== D5: SIBLING record — disposition is .harness/disposition/<pr>.json, NOT a mutation of the 2a record =="
R="$(mk_disp_root)"; rev_two_findings "$R"; disp_valid "$R"
HEAD_SHA_EXP="$(git -C "$R" rev-parse HEAD 2>/dev/null)"
run_review "$R" "https://github.com/o/r/pull/9"
DREC="$(disp_path "$R" 9)"; RREC="$(rev_path "$R" 9)"
[ -f "$DREC" ] && [ -f "$RREC" ] && ok "D5: BOTH records coexist (sibling, not in-place mutation)" || no "D5: the records do not coexist"
[ "$(jq -r 'has("dispositions")' "$RREC" 2>/dev/null)" = "false" ] && ok "D5: the 2a review record was NOT mutated (carries no dispositions field)" || no "D5: the 2a record was mutated with a dispositions field (clobber risk)"
[ "$(jq -r '.pr' "$DREC" 2>/dev/null)" = "9" ] && ok "D5: disposition record keyed by the canonical PR number" || no "D5: disposition pr key wrong"
[ "$(jq -r '.feature_sha' "$DREC" 2>/dev/null)" = "$HEAD_SHA_EXP" ] && ok "D5: feature_sha = the reviewed feature tip (joins to the 2a record)" || no "D5: feature_sha wrong"
[ "$(jq -r '.feature_sha' "$DREC" 2>/dev/null)" = "$(jq -r '.feature_sha' "$RREC" 2>/dev/null)" ] && ok "D5: disposition.feature_sha == review.feature_sha (the join key holds)" || no "D5: the records do not join on feature_sha"
[ "$(jq -r '.backend' "$DREC" 2>/dev/null)" = "ollama" ] && ok "D5: backend stamped" || no "D5: backend wrong"
[ "$(jq -r '.model' "$DREC" 2>/dev/null)" = "fakemodel" ] && ok "D5: model stamped" || no "D5: model wrong"
[ "$(jq -r '.actor' "$DREC" 2>/dev/null)" = "harness" ] && ok "D5: actor:harness (provenance house style)" || no "D5: actor wrong"
jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$DREC" >/dev/null 2>&1 && ok "D5: ts is a UTC ISO-8601 stamp" || no "D5: ts not a UTC stamp"
jq -e 'all(.dispositions[]; (.id|type=="string" and (.|length>0)) and (.disposition|IN("CONFIRMED","REBUTTED")) and (.reasoning|type=="string" and (.|length>0)))' "$DREC" >/dev/null 2>&1 && ok "D5: every disposition is well-formed (id + enum + reasoning)" || no "D5: a persisted disposition is malformed"

echo "== D6: SCHEMA fail-closed — malformed/absent/inverted blocks write NO record (each a loud notice) =="
for fx in disp_absent disp_badenum_accept disp_empty_reasoning disp_invented_id disp_missing_id disp_dup_id disp_double_block; do
  R="$(mk_disp_root)"; rev_two_findings "$R"; "$fx" "$R"
  run_review "$R" "https://github.com/o/r/pull/9"
  no_disp_record "$R" && ok "D6/$fx: no disposition record (fail-closed)" || no "D6/$fx: a record was written for a bad block"
done
# spell out the two highest-value guards:
R="$(mk_disp_root)"; rev_two_findings "$R"; disp_badenum_accept "$R"; run_review "$R" "https://github.com/o/r/pull/9"
no_disp_record "$R" && ok "D6: the POLARITY guard — a disposition of ACCEPT/ESCALATE is REFUSED (enum is CONFIRMED/REBUTTED)" || no "D6: an intake-verb disposition was accepted — POLARITY BREACH"
R="$(mk_disp_root)"; rev_two_findings "$R"; disp_missing_id "$R"; run_review "$R" "https://github.com/o/r/pull/9"
no_disp_record "$R" && ok "D6: an INCOMPLETE adjudication (a finding left unadjudicated) is REFUSED" || no "D6: a partial adjudication was recorded"
R="$(mk_disp_root)"; rev_two_findings "$R"; disp_invented_id "$R"; run_review "$R" "https://github.com/o/r/pull/9"
no_disp_record "$R" && ok "D6: a FABRICATED finding id is REFUSED (the id set must be the reviewer's)" || no "D6: an invented id was recorded"

echo "== D6b: KEY-STRICT schema (Finding B) — an extra per-element key OR a whitespace-only reasoning -> NO record =="
# Gated on HAS_STRICT (the validator tightening is door-spliced into review-task.sh): SKIP pre-splice so the
# canonical gate stays green; PROVE_RED forces these against the loose deployed validator (the RED proof).
if [ "$HAS_STRICT" = 1 ] || [ "${FORGE_REVIEW_DISPOSITION_PROVE_RED:-0}" = 1 ]; then
  R="$(mk_disp_root)"; rev_two_findings "$R"; disp_extra_key "$R"; run_review "$R" "https://github.com/o/r/pull/9"
  no_disp_record "$R" && ok "D6b: a disposition carrying an EXTRA key (x_injected) is REFUSED (exact key-set, not presence-only)" || no "D6b: an extra-key block was persisted — the schema is not key-strict"
  R="$(mk_disp_root)"; rev_two_findings "$R"; disp_ws_reasoning "$R"; run_review "$R" "https://github.com/o/r/pull/9"
  no_disp_record "$R" && ok "D6b: a WHITESPACE-ONLY reasoning is REFUSED (trimmed before the non-empty check)" || no "D6b: a whitespace-only reasoning was persisted — reasoning is not trimmed"
  R="$(mk_disp_root)"; rev_two_findings "$R"; disp_zerowidth_reasoning "$R"; run_review "$R" "https://github.com/o/r/pull/9"
  no_disp_record "$R" && ok "D6b: a ZERO-WIDTH-only reasoning (Cf format chars, not \\s) is REFUSED (visible content required)" || no "D6b: a zero-width-only reasoning was persisted — Cf chars not stripped"
  # the strict validator must NOT break the happy path: a correct 3-key F1/F2 block still records.
  R="$(mk_disp_root)"; rev_two_findings "$R"; disp_valid "$R"; run_review "$R" "https://github.com/o/r/pull/9"
  [ -f "$(disp_path "$R" 9)" ] && ok "D6b: the strict validator still ACCEPTS a correct 3-key block (happy path intact)" || no "D6b: the strict validator rejects a valid block (too strict)"
else
  skp "D6b: key-strict schema (Finding B) not yet spliced — loose validator deployed" "prove GREEN: FORGE_REVIEW_DISPOSITION_CANDIDATE=sandbox/reviewer-disposition-schema bash tests/reviewer-disposition/run.sh ; prove RED: FORGE_REVIEW_DISPOSITION_PROVE_RED=1 ..."
fi

echo "== D7: IDEMPOTENT — a re-adjudication OVERWRITES the same <pr>.json (no orphan, no duplicate) =="
R="$(mk_disp_root)"; rev_two_findings "$R"; disp_valid "$R"
run_review "$R" "https://github.com/o/r/pull/9"
disp_swap_one "$R"                                     # second adjudication of the SAME PR
run_review "$R" "https://github.com/o/r/pull/9"
NDREC="$(find "$R/.harness/disposition" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
[ "$NDREC" = "1" ] && ok "D7: exactly one disposition record after a re-adjudication (overwrite, not orphan)" || no "D7: $NDREC disposition records after re-run"
[ "$(jq -r '.dispositions[] | select(.id=="F2") | .disposition' "$(disp_path "$R" 9)" 2>/dev/null)" = "CONFIRMED" ] && ok "D7: the record reflects the LATEST adjudication (F2 now CONFIRMED)" || no "D7: record not updated to the latest run"

echo "== D8: NON-GATING — a disposition COMMENT-post failure keeps the record + stays exit 0 =="
R="$(mk_disp_root)"; rev_two_findings "$R"; disp_valid "$R"; : > "$R/.fail-disp-comment"
run_review "$R" "https://github.com/o/r/pull/9"
[ -f "$(disp_path "$R" 9)" ] && ok "D8: the disposition record persists through a comment-post failure (durable trace)" || no "D8: record lost on comment-post failure"
grep -q 'disposition comment post FAILED' "$LASTERR" 2>/dev/null && ok "D8: stderr loudly names the failed disposition comment + the persisted record" || no "D8: failed disposition post not surfaced" "$(tail -1 "$LASTERR" 2>/dev/null)"
[ "$RRC" = "0" ] && ok "D8: still exit 0 — a failed disposition comment never gates" || no "D8: exit changed on a disposition comment failure (rc=$RRC)"

echo "== D9: STRUCTURAL non-gating — the disposition follow-on introduces NO exit/return statement =="
# the tail must only LOG; the script's exit stays governed solely by RECORD_OK/POST_OK (the reviewer's).
# Strip full-comment lines AND inline comments first, so prose that merely MENTIONS exit/RECORD_OK is not
# mistaken for code, then word-match ANY exit/return form (exit N, exit "$rc", bare exit, exit $((..)), return).
DISP_TAIL="$(awk '/Build 2b: adjudicate the reviewer/{f=1} /Build 2a: fail-closed-loud on the RECORD/{f=0} f' "$HUT/review-task.sh" 2>/dev/null)"
DISP_TAIL_CODE="$(printf '%s\n' "$DISP_TAIL" | grep -v '^[[:space:]]*#' | sed 's/[[:space:]]#[[:space:]].*$//')"
printf '%s\n' "$DISP_TAIL_CODE" | grep -qwE 'exit|return' \
  && no "D9: the disposition follow-on contains an exit/return statement — could alter the script's exit" || ok "D9: the disposition follow-on contains NO exit/return (cannot introduce a merge-gating exit)"
printf '%s\n' "$DISP_TAIL_CODE" | grep -qE '(RECORD_OK|POST_OK)=' \
  && no "D9: the disposition follow-on reassigns RECORD_OK/POST_OK (could alter the reviewer's exit)" || ok "D9: the disposition follow-on never reassigns RECORD_OK/POST_OK"

echo "== D10: the once-gate swallow — even a non-zero review exit (so any disposition stderr) never gates finish =="
CANARY="$TMPROOT/exit3.sh"; printf '#!/usr/bin/env bash\nexit 3\n' > "$CANARY"; chmod +x "$CANARY"
WRC="$(
  . "$HUT/beads-lib.sh" 2>/dev/null
  forge_feature_complete() { return 0; }
  forge_review_feature_if_complete "specs/feat/spec.md" "https://github.com/o/r/pull/9" "o/r" "$CANARY" >/dev/null 2>&1
  echo $?
)"
[ "$WRC" = "0" ] && ok "D10: the once-gate returns 0 despite the review script exiting 3 (merge never gated)" || no "D10: once-gate propagated a non-zero exit (rc=$WRC)"

echo "== D11: the disposition backend is CONFIGURABLE (default reviewer's; DISPOSITION_BACKEND overrides) =="
grep -q 'DISPOSITION_BACKEND' "$HUT/review-task.sh" 2>/dev/null && ok "D11: review-task.sh reads DISPOSITION_BACKEND" || no "D11: DISPOSITION_BACKEND not consulted"
grep -q 'DISPOSITION_BACKEND:-\$BACKEND\|DISPOSITION_BACKEND:-$BACKEND' "$HUT/review-task.sh" 2>/dev/null && ok "D11: it FALLS BACK to the reviewer backend when unset" || no "D11: no fallback to the reviewer backend"
grep -q 'DISPOSITION_BACKEND' "$HUT/reviewers.config" 2>/dev/null && ok "D11: reviewers.config documents the DISPOSITION_BACKEND knob" || no "D11: reviewers.config missing the knob"
grep -qi 'diversit\|different' "$HUT/reviewers.config" 2>/dev/null && ok "D11: the config recommends a different family (provider diversity)" || no "D11: the config does not recommend provider diversity"

echo "== D12 (FOLD #14): a metacharacter DISPOSITION_BACKEND is refused BEFORE the eval-indirection =="
# The 2b disposition tail runs `eval \"DISP_MODEL=\${\${DISP_PREFIX}_MODEL:-}\"` with DISP_PREFIX derived from
# DISPOSITION_BACKEND via `tr - _` (which leaves $() {} : intact), so a metacharacter backend command-
# SUBSTITUTES at the eval. Fix 1b neutralizes DISP_BACKEND to an inert token BEFORE that eval (review-task.sh,
# the _rt_known_backend guard) — fail-closed-on-record, strictly NON-gating. GATED on Fix 1b being present in
# the HUT, so this stays SKIP-green on a pre-Fix-1b harness and AUTO-ACTIVATES on the splice (PROVE_RED forces
# it: the metacharacter then command-substitutes on the un-fixed harness — the RED proof). `:=` (assign-default),
# NOT `:-`: `tr - _` would mangle `:-` into `:_` (a bad substitution that errors before the $() runs).
HAS_FIX1B=0; grep -q '_rt_known_backend' "$HUT/review-task.sh" 2>/dev/null && HAS_FIX1B=1
if [ "$HAS_FIX1B" = 1 ] || [ "${FORGE_REVIEW_DISPOSITION_PROVE_RED:-0}" = 1 ]; then
  R="$(mk_disp_root)"; rev_two_findings "$R"          # 2 findings -> RECORD_OK=1, _DNF>0 -> the disposition tail runs
  D12SUB="$R/DISP_BACKEND_SUBST_FIRED"
  ( cd "$R"; export PATH="$R/bin:$PATH" REVIEWER_BACKEND="ollama" DISPOSITION_BACKEND='x:=$(touch '"$D12SUB"')'
    bash harness/review-task.sh "https://github.com/o/r/pull/9" >/dev/null 2>"$R/.d12err" ); D12RC=$?
  [ ! -e "$D12SUB" ] && ok "D12: metacharacter DISPOSITION_BACKEND did NOT command-substitute (sink closed before the eval)" || no "D12: SUBST sink OPEN — the neutralizer is missing/ineffective"
  [ ! -f "$(disp_path "$R" 9)" ] && ok "D12: NO disposition record for a metacharacter backend (fail-closed on the record)" || no "D12: a disposition record was written despite a metacharacter backend"
  [ "$D12RC" = "0" ] && ok "D12: still exit 0 — a metacharacter disposition backend never gates cmd_finish (non-gating)" || no "D12: a bad disposition backend gated finish (rc=$D12RC)"
  grep -q 'not a recognized backend' "$R/.d12err" 2>/dev/null && ok "D12: a LOUD refusal reason is surfaced on stderr" || no "D12: no loud refusal reason for the metacharacter backend" "$(tail -1 "$R/.d12err" 2>/dev/null)"
  [ -f "$(rev_path "$R" 9)" ] && ok "D12 over-block: the reviewer RECORD still persisted (the refusal is scoped to the disposition backend, not the review)" || no "D12 over-block: the reviewer record was lost (the refusal over-reached)"
else
  skp "D12 metacharacter DISPOSITION_BACKEND" "Fix 1b (_rt_known_backend) not in \$HUT/review-task.sh — SKIP-green pre-splice; auto-activates on the splice (or FORGE_REVIEW_DISPOSITION_PROVE_RED=1 to force)"
fi

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part C — invariants: agents stay read-only; the real ledger + real .harness untouched
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== C1: the reviewer allowlist is UNCHANGED (Build 1/2a not regressed) =="
grep -qE '^tools:[[:space:]]*Read,[[:space:]]*Grep,[[:space:]]*Glob[[:space:]]*$' "$ROOT/.claude/agents/reviewer.md" \
  && ok "C1: reviewer.md frontmatter is still 'tools: Read, Grep, Glob'" || no "C1: reviewer allowlist changed"
grep -q 'write_review_record' "$HUT/review-task.sh" 2>/dev/null \
  && ok "C1: Build 2a's write_review_record is still present (no regression)" || no "C1: the 2a record writer vanished"

echo "== C2: the harness writes — the disposition agent cannot and need not =="
grep -q 'write_disposition_record' "$HUT/review-task.sh" 2>/dev/null \
  && ok "C2: write_disposition_record lives in review-task.sh (harness runtime), not the agent" || no "C2: disposition writer missing from the wrapper"

echo
echo "==== reviewer-disposition: $PASS passed, $FAIL failed, $SKIP skipped ===="
echo "== guards: real .beads + real \$ROOT/.harness/{disposition,review} unchanged by this suite =="
[ "$(ledger_state)" = "$BEADS_BEFORE" ] && ok "REAL .beads byte-unchanged" || no "REAL ledger CHANGED — GUARD TRIPPED"
REAL_DISP_AFTER="absent"; [ -d "$REAL_DISP_DIR" ] && REAL_DISP_AFTER="present"
[ "$REAL_DISP_AFTER" = "$REAL_DISP_BEFORE" ] && ok "REAL \$ROOT/.harness/disposition unchanged ($REAL_DISP_BEFORE) — no live-tree pollution" || no "the suite polluted \$ROOT/.harness/disposition ($REAL_DISP_BEFORE -> $REAL_DISP_AFTER)"
REAL_REVIEW_AFTER="absent"; [ -d "$REAL_REVIEW_DIR" ] && REAL_REVIEW_AFTER="present"
[ "$REAL_REVIEW_AFTER" = "$REAL_REVIEW_BEFORE" ] && ok "REAL \$ROOT/.harness/review unchanged ($REAL_REVIEW_BEFORE)" || no "the suite polluted \$ROOT/.harness/review ($REAL_REVIEW_BEFORE -> $REAL_REVIEW_AFTER)"
[ "$FAIL" = 0 ] || exit 1
exit 0
