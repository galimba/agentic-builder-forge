#!/usr/bin/env bash
# tests/reviewer-record/run.sh — Build 2a: Reviewer record + dual contract.
#
# Proves, each RED-first, that the reviewer now emits a machine-readable verdict block AND the harness
# wrapper persists an acceptance-record-shaped .harness/review/<pr>.json, FAIL-CLOSED-LOUD on a
# malformed/absent block but NON-gating on the merge:
#   Part A  the dual contract — reviewer.md sanctions a sentinel-bounded block; review-task.sh extracts it
#           with the ONE canonical slice idiom and fails closed (NO record + a LOUD comment banner + a
#           non-zero exit AFTER the post) on an absent/malformed/duplicated/schema-violating block, while
#           the merge stays non-gating (the once-gate swallows the exit).
#   Part B  the record — .harness/review/<pr>.json carries the reviewer judgment (verdict + findings with
#           STABLE id + location, the 2b coupling) PLUS wrapper provenance (backend, model, feature_sha,
#           actor:"harness", ts); keyed by the canonical PR number (URL or branch-name invocation);
#           idempotent-by-overwrite on a re-review.
#   Part C  invariants — the reviewer allowlist is UNCHANGED (read-only forever); the real .beads is
#           byte-unchanged; the real $ROOT/.harness grows no review/ pollution.
#
# RED/GREEN seam (the Build-1 FORGE_REVIEW_CANDIDATE analogue): FORGE_REVIEW_RECORD_CANDIDATE points at the
# dir holding apply-candidate.py; the suite materializes a throwaway harness = DEPLOYED + applier and tests
# THAT — "a test verifies what ships."
#   bash tests/reviewer-record/run.sh
#       -> deployed, pre-splice: write_review_record is ABSENT -> SKIP rc 75 (keeps the canonical gate green;
#          AUTO-ACTIVATES PASS-required once the door splice lands and the fn is in the deployed tree).
#   FORGE_REVIEW_RECORD_CANDIDATE=sandbox/reviewer-record bash tests/reviewer-record/run.sh
#       -> candidate applied -> GREEN (every arm passes).
#   FORGE_REVIEW_RECORD_PROVE_RED=1 bash tests/reviewer-record/run.sh
#       -> forces the GREEN arms against the DEPLOYED harness -> they FAIL (the RED proof, run by a human).
#
# NOTE on the reviewer.md contract (Part A0): reviewer.md is DIRECTLY writable (committed as a normal edit,
# not spliced through the door), so the A0 doc-contract checks read the live $ROOT/.claude/agents/reviewer.md
# — GREEN once the edit lands on the branch. Its RED proof is vs origin/main, not the candidate seam:
#   git show origin/main:.claude/agents/reviewer.md | grep -c 'forge:review:begin'   # 0 on main, >=1 here
#
# THROWAWAY fixtures only; the REAL $ROOT/.beads ledger is byte-guarded. No docker, no bd, no network: the
# backends are faked (pure text in/out) and gh is a stub. Mechanism only: bash + jq + awk + exit codes.
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
# ---- real-$ROOT/.harness/review must NOT be created by this suite (no pollution of the live tree) ----
REAL_REVIEW_DIR="$ROOT/.harness/review"
REAL_REVIEW_BEFORE="absent"; [ -d "$REAL_REVIEW_DIR" ] && REAL_REVIEW_BEFORE="present"

# ── materialize the harness-under-test (HUT): DEPLOYED, optionally + the candidate applier ──
HUT="$ROOT/harness"
if [ -n "${FORGE_REVIEW_RECORD_CANDIDATE:-}" ]; then
  CAND="$FORGE_REVIEW_RECORD_CANDIDATE"; case "$CAND" in /*) : ;; *) CAND="$ROOT/$CAND" ;; esac
  [ -f "$CAND/apply-candidate.py" ] || { echo "FAIL: no apply-candidate.py at $CAND"; exit 1; }
  HUT="$TMPROOT/hut"; mkdir -p "$HUT"
  cp "$ROOT/harness/"*.sh "$HUT/" 2>/dev/null
  cp "$ROOT/harness/"*.config "$HUT/" 2>/dev/null
  python3 "$CAND/apply-candidate.py" "$HUT" || { echo "FAIL: apply-candidate.py failed against $HUT"; exit 1; }
fi

HAS_REC=0; grep -q 'write_review_record' "$HUT/review-task.sh" 2>/dev/null && HAS_REC=1

echo "============================================================"
echo "Build 2a reviewer-record — HUT: $HUT (record-fn present=$HAS_REC)"
echo "============================================================"

if [ "$HAS_REC" != 1 ] && [ "${FORGE_REVIEW_RECORD_PROVE_RED:-0}" != 1 ]; then
  echo "SKIP: Build 2a (reviewer record) is not yet spliced into $HUT."
  echo "      prove GREEN:  FORGE_REVIEW_RECORD_CANDIDATE=sandbox/reviewer-record bash tests/reviewer-record/run.sh"
  echo "      prove RED:    FORGE_REVIEW_RECORD_PROVE_RED=1 bash tests/reviewer-record/run.sh"
  echo "      This SKIP (rc 75) keeps the canonical gate green pre-splice; auto-activates PASS-required"
  echo "      once the door splice lands and write_review_record is in the deployed harness."
  exit 75
fi
[ "$HAS_REC" = 1 ] || echo ">> FORGE_REVIEW_RECORD_PROVE_RED=1 — running the GREEN arms against the UNSPLICED harness; expect FAILs (this IS the RED proof)."

# ── a ROOT review-task.sh can run inside: git repo + lib.sh + reviewer.md + bin/ fakes ───────────────
mk_review_root() {
  local R; R="$(mktemp -d -p "$TMPROOT")"
  mkdir -p "$R/harness" "$R/.claude/hooks" "$R/.claude/agents" "$R/bin" "$R/.beads" "$R/.cap"
  cp "$HUT/review-task.sh" "$R/harness/review-task.sh"; chmod +x "$R/harness/review-task.sh"
  cp "$ROOT/.claude/hooks/lib.sh" "$R/.claude/hooks/lib.sh"
  cp "$ROOT/.claude/agents/reviewer.md" "$R/.claude/agents/reviewer.md"
  printf 'ollama_MODEL="fakemodel"\n' > "$R/harness/reviewers.config"
  : > "$R/backend.out"
  # fake gh: logs calls; stubs pr diff / pr view (headRefOid -> HEAD sha ; number -> 9) / pr comment / repo view
  cat >"$R/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$R/.gh-calls.log"
case "\$1 \$2" in
  "pr diff")    printf 'diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n+changed\n' ;;
  "pr view")    if printf '%s' "\$*" | grep -q 'number'; then printf '9\n'; else git -C "$R" rev-parse HEAD 2>/dev/null; fi ;;
  "pr comment") [ -f "$R/.fail-comment" ] && exit 1; cat > "$R/.cap/comment.body"; printf 'https://github.com/o/r/pull/9#c1\n' ;;
  "repo view")  printf 'o/r\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
  # fake ollama: pure text in/out — emits whatever backend.out holds (the reviewer's "output")
  cat >"$R/bin/ollama" <<EOF
#!/usr/bin/env bash
cat > "$R/.cap/ollama.stdin"
cat "$R/backend.out" 2>/dev/null
EOF
  chmod +x "$R/bin/gh" "$R/bin/ollama"
  ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
      && git symbolic-ref HEAD refs/heads/main \
      && printf 'base\n' > README.md && git add README.md && git commit -q -m base ) >/dev/null 2>&1
  printf '%s' "$R"
}
run_review() {  # <root> <pr-arg>   -> sets RRC ; stderr in $LASTERR ; uses $R/backend.out as reviewer output
  local R="$1" prarg="$2"
  LASTERR="$R/.stderr"
  ( cd "$R" || exit 1
    export PATH="$R/bin:$PATH" REVIEWER_BACKEND="ollama"
    bash harness/review-task.sh "$prarg" --repo o/r >/dev/null 2>"$LASTERR" )
  RRC=$?
}
rec_path() { printf '%s/.harness/review/%s.json' "$1" "$2"; }
# no_record: TRUE iff NO record json exists ANYWHERE under the root's review dir — stronger than checking
# one key, so a mis-keyed/orphan record (review/feat/foo.json, a wrong number) cannot pass as "fail-closed".
no_record() { [ -z "$(find "$1/.harness/review" -name '*.json' 2>/dev/null)" ]; }

# ── reviewer-output fixtures (the backend's stdout) ──────────────────────────────────────────────────
out_valid_concerns() {  # fenced block, 2 findings with stable ids + locations (mirrors reviewer.md shape)
  cat > "$1/backend.out" <<'OUT'
### Reviewer verdict: CONCERNS

| #  | Severity | File:line                  | Finding    | Why | Suggested fix |
| F1 | HIGH     | harness/review-task.sh:212 | raw embed  | ... | keep advisory |

### Summary

Two concerns; the raw embed is the most important.

<!-- forge:review:begin v1 -->

```json
{"verdict":"CONCERNS","findings":[{"id":"F1","severity":"HIGH","location":"harness/review-task.sh:212","finding":"raw embed of FINDINGS into the comment body","suggested_fix":"acceptable; advisory only"},{"id":"F2","severity":"LOW","location":"harness/x.sh:9","finding":"a nit","suggested_fix":"rename the var"}]}
```

<!-- forge:review:end v1 -->
OUT
}
out_valid_clean() {  # CLEAN -> findings: []
  cat > "$1/backend.out" <<'OUT'
### Reviewer verdict: CLEAN

(nothing material)

### Summary

Looks clean.

<!-- forge:review:begin v1 -->
{"verdict":"CLEAN","findings":[]}
<!-- forge:review:end v1 -->
OUT
}
out_absent() {  # prose + verdict, NO sentinel block at all
  cat > "$1/backend.out" <<'OUT'
### Reviewer verdict: CONCERNS

I found a thing but forgot to emit the machine block.

### Summary

Prose only.
OUT
}
out_malformed_json() {  # sentinels present, JSON broken
  cat > "$1/backend.out" <<'OUT'
### Reviewer verdict: CONCERNS

### Summary
x.

<!-- forge:review:begin v1 -->
{"verdict":"CONCERNS","findings":[{"id":"F1", BROKEN
<!-- forge:review:end v1 -->
OUT
}
out_schema_noloc() {  # valid JSON, a finding MISSING location (the 2b forward-compat guarantee)
  cat > "$1/backend.out" <<'OUT'
### Reviewer verdict: CONCERNS

### Summary
x.

<!-- forge:review:begin v1 -->
{"verdict":"CONCERNS","findings":[{"id":"F1","severity":"HIGH","finding":"no location","suggested_fix":"y"}]}
<!-- forge:review:end v1 -->
OUT
}
out_schema_badverdict() {  # verdict not in the enum
  cat > "$1/backend.out" <<'OUT'
<!-- forge:review:begin v1 -->
{"verdict":"LGTM","findings":[]}
<!-- forge:review:end v1 -->
OUT
}
out_double_block() {  # TWO begin sentinels -> ambiguous
  cat > "$1/backend.out" <<'OUT'
<!-- forge:review:begin v1 -->
{"verdict":"CLEAN","findings":[]}
<!-- forge:review:end v1 -->
<!-- forge:review:begin v1 -->
{"verdict":"BLOCK-RECOMMENDED","findings":[]}
<!-- forge:review:end v1 -->
OUT
}
out_empty_fix() {  # valid JSON, a finding with an EMPTY suggested_fix (uniformity w/ id/location/finding)
  cat > "$1/backend.out" <<'OUT'
<!-- forge:review:begin v1 -->
{"verdict":"CONCERNS","findings":[{"id":"F1","severity":"HIGH","location":"a:1","finding":"x","suggested_fix":""}]}
<!-- forge:review:end v1 -->
OUT
}
out_dup_id() {  # two findings sharing id F1 -> not discretely addressable (breaks the 2b coupling)
  cat > "$1/backend.out" <<'OUT'
<!-- forge:review:begin v1 -->
{"verdict":"CONCERNS","findings":[{"id":"F1","severity":"HIGH","location":"a:1","finding":"x","suggested_fix":"y"},{"id":"F1","severity":"LOW","location":"b:2","finding":"z","suggested_fix":"w"}]}
<!-- forge:review:end v1 -->
OUT
}
out_clean_with_findings() {  # CLEAN verdict carrying a finding -> contract violation (CLEAN => [])
  cat > "$1/backend.out" <<'OUT'
<!-- forge:review:begin v1 -->
{"verdict":"CLEAN","findings":[{"id":"F1","severity":"INFO","location":"a:1","finding":"fyi","suggested_fix":"n/a"}]}
<!-- forge:review:end v1 -->
OUT
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part A0 — the reviewer.md contract DOC sanctions the machine block (committed direct; RED vs origin/main)
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== A0: reviewer.md sanctions a sentinel-bounded machine block as the terminal element =="
RM="$ROOT/.claude/agents/reviewer.md"
grep -q '<!-- forge:review:begin v1 -->' "$RM" 2>/dev/null && grep -q '<!-- forge:review:end v1 -->' "$RM" 2>/dev/null \
  && ok "reviewer.md carries the review begin/end sentinels" || no "reviewer.md lacks the review sentinels (RED on origin/main)"
grep -q 'nothing after the closing' "$RM" 2>/dev/null \
  && ok "reviewer.md 'nothing after' now points past the closing sentinel" || no "reviewer.md output-format constraint not updated"
for k in verdict findings id severity location suggested_fix; do
  grep -q "$k" "$RM" 2>/dev/null || no "reviewer.md schema is missing key '$k'"
done
grep -q 'A `CLEAN` verdict carries' "$RM" 2>/dev/null \
  && ok "reviewer.md documents CLEAN -> empty findings" || no "reviewer.md does not document the CLEAN/empty-findings rule"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part A — extraction + fail-closed-loud (NON-gating)
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== A1: a VALID fenced block -> extracted, record written, NO banner on the comment =="
R="$(mk_review_root)"; out_valid_concerns "$R"
run_review "$R" "https://github.com/o/r/pull/9"
REC="$(rec_path "$R" 9)"
[ -f "$REC" ] && jq -e . "$REC" >/dev/null 2>&1 && ok "A1: record .harness/review/9.json exists + is valid JSON" || no "A1: no/invalid record" "rc=$RRC $(tail -1 "$LASTERR" 2>/dev/null)"
[ "$(jq -r '.verdict' "$REC" 2>/dev/null)" = "CONCERNS" ] && ok "A1: verdict lifted from the block (CONCERNS)" || no "A1: verdict not lifted"
[ "$(jq -r '.findings | length' "$REC" 2>/dev/null)" = "2" ] && ok "A1: both findings preserved (not collapsed)" || no "A1: findings not preserved"
grep -q 'MANUAL VERIFICATION REQUIRED' "$R/.cap/comment.body" 2>/dev/null && no "A1: loud banner wrongly shown for a valid block" || ok "A1: NO loud banner for a valid block (BODY shape preserved)"
[ "$RRC" = "0" ] && ok "A1: exit 0 on a valid record" || no "A1: non-zero exit on a valid record (rc=$RRC)"

echo "== A2: a CLEAN block -> record with findings: [] =="
R="$(mk_review_root)"; out_valid_clean "$R"
run_review "$R" "https://github.com/o/r/pull/9"
REC="$(rec_path "$R" 9)"
[ "$(jq -r '.verdict' "$REC" 2>/dev/null)" = "CLEAN" ] && [ "$(jq -c '.findings' "$REC" 2>/dev/null)" = "[]" ] \
  && ok "A2: CLEAN record with empty findings[]" || no "A2: CLEAN/empty-findings record wrong" "rc=$RRC"

echo "== A3: an ABSENT block -> NO record + LOUD banner + non-zero exit (fail-closed-loud) =="
R="$(mk_review_root)"; out_absent "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_record "$R" && ok "A3: no record written for an absent block" || no "A3: a record was fabricated for an absent block"
grep -q 'MANUAL VERIFICATION REQUIRED' "$R/.cap/comment.body" 2>/dev/null && ok "A3: the comment carries the LOUD manual-verification banner" || no "A3: no loud banner" "$(head -c 120 "$R/.cap/comment.body" 2>/dev/null)"
grep -q 'I found a thing but forgot' "$R/.cap/comment.body" 2>/dev/null && ok "A3: the prose is still posted (advisory, never dropped)" || no "A3: prose not posted"
[ "$RRC" -ne 0 ] && ok "A3: non-zero exit on the no-record path (honest signal)" || no "A3: exited 0 despite no record"

echo "== A4: a MALFORMED-JSON block -> NO record + LOUD banner =="
R="$(mk_review_root)"; out_malformed_json "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_record "$R" && ok "A4: no record for malformed JSON" || no "A4: record written for malformed JSON"
grep -q 'MANUAL VERIFICATION REQUIRED' "$R/.cap/comment.body" 2>/dev/null && ok "A4: loud banner for malformed JSON" || no "A4: no loud banner for malformed JSON"

echo "== A5: a SCHEMA-VIOLATING block (finding missing location) -> NO record (2b forward-compat guard) =="
R="$(mk_review_root)"; out_schema_noloc "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_record "$R" && ok "A5: a finding without a stable location is REFUSED (no record)" || no "A5: recorded a finding with no location"
grep -q 'MANUAL VERIFICATION REQUIRED' "$R/.cap/comment.body" 2>/dev/null && ok "A5: loud banner for the schema violation" || no "A5: no loud banner"
R="$(mk_review_root)"; out_schema_badverdict "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_record "$R" && ok "A5b: a non-enum verdict is REFUSED (no record)" || no "A5b: recorded a non-enum verdict"
R="$(mk_review_root)"; out_empty_fix "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_record "$R" && ok "A5c: an EMPTY suggested_fix is REFUSED (uniform with id/location/finding)" || no "A5c: recorded an empty suggested_fix"
R="$(mk_review_root)"; out_dup_id "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_record "$R" && ok "A5d: DUPLICATE finding ids are REFUSED (2b needs discrete addressing)" || no "A5d: recorded duplicate finding ids"
R="$(mk_review_root)"; out_clean_with_findings "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_record "$R" && ok "A5e: a CLEAN verdict carrying findings is REFUSED (CLEAN => [])" || no "A5e: recorded a CLEAN verdict with findings"

echo "== A6: TWO blocks -> ambiguous -> NO record + LOUD banner (mirrors intake exactly-one-block) =="
R="$(mk_review_root)"; out_double_block "$R"
run_review "$R" "https://github.com/o/r/pull/9"
no_record "$R" && ok "A6: ambiguous double block -> no record" || no "A6: recorded an ambiguous double block"
grep -q 'MANUAL VERIFICATION REQUIRED' "$R/.cap/comment.body" 2>/dev/null && ok "A6: loud banner for a double block" || no "A6: no loud banner"

echo "== A7: NON-GATING — a non-zero review exit is swallowed by the fire-and-forget once-gate =="
# (i) the once-gate forge_review_feature_if_complete (UNCHANGED from Build 1) returns 0 even when its
#     review script exits non-zero -> a malformed review can NEVER gate cmd_finish / the merge.
CANARY="$TMPROOT/exit3.sh"; printf '#!/usr/bin/env bash\nexit 3\n' > "$CANARY"; chmod +x "$CANARY"
WRC="$(
  . "$HUT/beads-lib.sh" 2>/dev/null
  forge_feature_complete() { return 0; }
  forge_review_feature_if_complete "specs/feat/spec.md" "https://github.com/o/r/pull/9" "o/r" "$CANARY" >/dev/null 2>&1
  echo $?
)"
[ "$WRC" = "0" ] && ok "A7: once-gate returns 0 despite the review script exiting 3 (merge never gated)" || no "A7: once-gate propagated a non-zero review exit (rc=$WRC)"
# (ii) the fire line is fire-and-forget (|| true) — the structural guarantee.
grep -A6 'forge_review_feature_if_complete()' "$HUT/beads-lib.sh" 2>/dev/null | grep -q '|| true' \
  && ok "A7: the once-gate fire is fire-and-forget (|| true)" || no "A7: once-gate fire is not || true"

echo "== A8: a COMMENT-POST FAILURE keeps the durable record (not orphaned/silent) + LOUD stderr + non-zero =="
# the record is the machine-readable trace (written before the post); a flaky `gh pr comment` must NOT discard
# it, and the failure must be surfaced loudly — never a silent die. (The non-zero exit is swallowed by the
# once-gate just like A7, so the merge stays non-gating.)
R="$(mk_review_root)"; out_valid_concerns "$R"; : > "$R/.fail-comment"
run_review "$R" "https://github.com/o/r/pull/9"
[ -f "$(rec_path "$R" 9)" ] && jq -e '.verdict=="CONCERNS"' "$(rec_path "$R" 9)" >/dev/null 2>&1 \
  && ok "A8: the record persists through the comment-post failure (durable trace, not orphaned)" || no "A8: record lost/invalid on comment-post failure"
[ "$RRC" -ne 0 ] && ok "A8: non-zero exit on a comment-post failure (honest signal, not exit 0)" || no "A8: exited 0 on comment-post failure"
grep -q 'comment post FAILED' "$LASTERR" 2>/dev/null && grep -q 'record persisted' "$LASTERR" 2>/dev/null \
  && ok "A8: stderr LOUDLY reports the failed post AND names the persisted record" || no "A8: comment-post failure not surfaced loudly" "$(tail -1 "$LASTERR" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part B — record shape, provenance, keying, idempotency, 2b forward-compat
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== B1: wrapper-stamped provenance (backend, model, feature_sha, actor:harness, ts) =="
R="$(mk_review_root)"; out_valid_concerns "$R"
HEAD_SHA_EXP="$(git -C "$R" rev-parse HEAD 2>/dev/null)"
run_review "$R" "https://github.com/o/r/pull/9"
REC="$(rec_path "$R" 9)"
[ "$(jq -r '.backend' "$REC" 2>/dev/null)" = "ollama" ]      && ok "B1: backend stamped" || no "B1: backend wrong"
[ "$(jq -r '.model' "$REC" 2>/dev/null)" = "fakemodel" ]     && ok "B1: model stamped" || no "B1: model wrong"
[ "$(jq -r '.feature_sha' "$REC" 2>/dev/null)" = "$HEAD_SHA_EXP" ] && ok "B1: feature_sha = the reviewed feature tip" || no "B1: feature_sha wrong"
[ "$(jq -r '.actor' "$REC" 2>/dev/null)" = "harness" ]       && ok "B1: actor:harness (provenance house style)" || no "B1: actor wrong"
jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$REC" >/dev/null 2>&1 && ok "B1: ts is a UTC ISO-8601 stamp" || no "B1: ts not a UTC stamp"
[ "$(jq -r '.pr' "$REC" 2>/dev/null)" = "9" ]                && ok "B1: keyed by the canonical PR number (from the URL)" || no "B1: pr field wrong"

echo "== B2: KEYING — a branch-name invocation falls back to gh pr view --json number =="
R="$(mk_review_root)"; out_valid_clean "$R"
run_review "$R" "feat/some-branch"
[ -f "$(rec_path "$R" 9)" ] && ok "B2: branch-name PR -> record keyed by the resolved number (9.json)" || no "B2: branch-name PR did not resolve to a numeric key" "rc=$RRC $(tail -1 "$LASTERR" 2>/dev/null)"
grep -q 'json number' "$R/.gh-calls.log" 2>/dev/null && ok "B2: the number-resolution fallback was used" || no "B2: gh pr view --json number not consulted"

echo "== B3: IDEMPOTENT — a re-review OVERWRITES the same <pr>.json (no orphan, no duplicate) =="
R="$(mk_review_root)"; out_valid_concerns "$R"
run_review "$R" "https://github.com/o/r/pull/9"
out_valid_clean "$R"                                   # second review of the SAME PR -> CLEAN
run_review "$R" "https://github.com/o/r/pull/9"
NREC="$(find "$R/.harness/review" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
[ "$NREC" = "1" ] && ok "B3: exactly one record file after a re-review (overwrite, not orphan)" || no "B3: $NREC record files after re-review"
[ "$(jq -r '.verdict' "$(rec_path "$R" 9)" 2>/dev/null)" = "CLEAN" ] && ok "B3: the record reflects the LATEST review (CLEAN)" || no "B3: record not updated to the latest review"

echo "== B4: 2b FORWARD-COMPAT — every finding is discretely addressable (stable id + location) =="
R="$(mk_review_root)"; out_valid_concerns "$R"
run_review "$R" "https://github.com/o/r/pull/9"
REC="$(rec_path "$R" 9)"
jq -e 'all(.findings[]; (.id|type=="string" and (.|length>0)) and (.location|type=="string" and (.|length>0)) and has("severity") and has("finding") and has("suggested_fix"))' "$REC" >/dev/null 2>&1 \
  && ok "B4: each finding carries a non-empty id + location + the full schema (2b can attach to it)" || no "B4: a finding is not discretely addressable"
[ "$(jq -r '.findings[0].id' "$REC" 2>/dev/null)" = "F1" ] && ok "B4: the reviewer-assigned id (F1) is preserved verbatim" || no "B4: finding id not preserved"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Part C — invariants: reviewer stays read-only; real ledger + real .harness untouched
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== C1: the reviewer allowlist is UNCHANGED (read-only forever) =="
grep -qE '^tools:[[:space:]]*Read,[[:space:]]*Grep,[[:space:]]*Glob[[:space:]]*$' "$ROOT/.claude/agents/reviewer.md" \
  && ok "C1: reviewer.md frontmatter is still 'tools: Read, Grep, Glob'" || no "C1: reviewer allowlist changed"
grep -q -- '--disallowedTools Bash Write Edit MultiEdit NotebookEdit' "$HUT/review-task.sh" \
  && ok "C1: claude-fresh --disallowedTools (write tools blocked) unchanged" || no "C1: claude-fresh disallowedTools changed"

echo "== C2: the harness writes — the reviewer agent cannot and need not (record write is in the wrapper) =="
grep -q 'write_review_record' "$HUT/review-task.sh" 2>/dev/null \
  && ok "C2: write_review_record lives in review-task.sh (harness runtime), not the agent" || no "C2: record writer missing from the wrapper"

echo
echo "==== reviewer-record: $PASS passed, $FAIL failed, $SKIP skipped ===="
echo "== guards: real .beads + real \$ROOT/.harness/review unchanged by this suite =="
[ "$(ledger_state)" = "$BEADS_BEFORE" ] && ok "REAL .beads byte-unchanged" || no "REAL ledger CHANGED — GUARD TRIPPED"
REAL_REVIEW_AFTER="absent"; [ -d "$REAL_REVIEW_DIR" ] && REAL_REVIEW_AFTER="present"
[ "$REAL_REVIEW_AFTER" = "$REAL_REVIEW_BEFORE" ] && ok "REAL \$ROOT/.harness/review unchanged ($REAL_REVIEW_BEFORE) — no live-tree pollution" || no "the suite polluted \$ROOT/.harness/review ($REAL_REVIEW_BEFORE -> $REAL_REVIEW_AFTER)"
[ "$FAIL" = 0 ] || exit 1
exit 0
