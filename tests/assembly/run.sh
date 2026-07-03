#!/usr/bin/env bash
# tests/assembly/run.sh — assembly KEYSTONE suite.
#
# Proves the Question-Zero deadlock-breaking overlay (forge_intra_feature_ready/forge_dep_satisfied), the
# harness-side topo merge onto feat/F (forge_safe_git_merge — abort-on-conflict, NEVER force), the host-side
# assembly log, the one-feature-PR ensure + record + sync-closes-together, and every fail-closed negative.
#
# RED/GREEN seam (the FORGE_DMF_SANDBOXLIB analogue): FORGE_ASSEMBLY_HARNESS selects the harness tree copied
# into each throwaway fixture. DEFAULT = the DEPLOYED $ROOT/harness (pre-overlay -> the suite proves the
# deadlock is REAL, then exits 1 "RED until splice"). Point it at a candidate-harness tree to prove
# the overlay BREAKS the deadlock (GREEN). "A test verifies what ships" — exactly like tests/pristine.
#
#   bash tests/assembly/run.sh                                            # vs deployed -> RED until splice
#   FORGE_ASSEMBLY_HARNESS=path/to/candidate-harness bash tests/assembly/run.sh          # vs candidate -> GREEN
#
# THROWAWAY fixtures only: each fixture is its own git repo + its own bd DB + a github-shaped NON-EXISTENT
# origin + a FAKE gh on PATH. The REAL .beads ledger is byte-guarded. bd absent -> rc 75 SKIP (the overlay's
# whole subject is the real bd ready/show round-trip). No docker is needed (assembly is host-side git/bd/gh).
set -u
export BD_NON_INTERACTIVE=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS_SRC="${FORGE_ASSEMBLY_HARNESS:-$ROOT/harness}"
case "$HARNESS_SRC" in /*) : ;; *) HARNESS_SRC="$ROOT/$HARNESS_SRC" ;; esac
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  PASS [%s]\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
skp()  { SKIP=$((SKIP+1)); printf '  SKIP [%s] %s\n' "$1" "${2:-}"; }

command -v jq  >/dev/null 2>&1 || { echo "FAIL: jq is required";  exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is required"; exit 1; }
command -v bd  >/dev/null 2>&1 || { echo "SKIP: bd absent (the overlay needs the real ledger round-trip) — rc 75 (EX_TEMPFAIL)"; exit 75; }

[ -f "$HARNESS_SRC/run-task.sh" ] || { echo "FAIL: no harness at FORGE_ASSEMBLY_HARNESS=$HARNESS_SRC"; exit 1; }
REAL_BD="$(command -v bd)"
HAS_OVERLAY=0; grep -q 'forge_intra_feature_ready' "$HARNESS_SRC/beads-lib.sh"  2>/dev/null && HAS_OVERLAY=1
HAS_MERGE=0;   grep -q 'forge_safe_git_merge'      "$HARNESS_SRC/sandbox-lib.sh" 2>/dev/null && HAS_MERGE=1

TMPROOT="$(mktemp -d)"
cleanup() {
  local d
  for d in "$TMPROOT"/*/; do [ -d "$d" ] && git -C "$d" worktree prune >/dev/null 2>&1; done
  rm -rf "$TMPROOT" 2>/dev/null
}
trap cleanup EXIT

# ---- HARD real-ledger byte-unchanged guard (convert-class) ----
REAL_LEDGER="$ROOT/.beads/issues.jsonl"
ledger_state() { [ -f "$REAL_LEDGER" ] && sha256sum "$REAL_LEDGER" | cut -d' ' -f1 || printf 'ABSENT'; }
BEADS_BEFORE="$(ledger_state)"

# ── fixture: a throwaway forge-like ROOT (own repo on main, own bd DB, copied harness, fake gh, noexist origin)
mk_forge_root() {
  local R; R="$(mktemp -d -p "$TMPROOT")"
  mkdir -p "$R/harness" "$R/.claude/hooks" "$R/specs" "$R/bin" "$R/.harness"
  cp "$HARNESS_SRC/run-task.sh" "$HARNESS_SRC/kill-switch.sh" "$HARNESS_SRC/accept-gate.sh" \
     "$HARNESS_SRC/beads-lib.sh" "$HARNESS_SRC/sandbox-lib.sh" "$R/harness/" 2>/dev/null
  [ -f "$HARNESS_SRC/review-task.sh" ] && cp "$HARNESS_SRC/review-task.sh" "$R/harness/"
  chmod +x "$R/harness/"*.sh 2>/dev/null
  cp "$ROOT/.claude/hooks/lib.sh" "$R/.claude/hooks/lib.sh"
  cp "$ROOT/harness/beads.config" "$R/harness/beads.config" 2>/dev/null || true
  printf 'BD_BIN=%s\n' "$REAL_BD" >>"$R/harness/beads.config"
  printf 'TARGET=t\nt_TEST_CMD="true"\nt_LINT_CMD="true"\nt_FORMAT_CMD="true"\nt_SANDBOX_GLOB="sandbox/**"\n' >"$R/harness/targets.config"
  cp "$ROOT/package.json" "$R/package.json" 2>/dev/null || printf '{"name":"agentic-builder-forge"}\n' >"$R/package.json"
  install_fake_gh "$R/bin/gh" "$R/.gh-calls.log" "$R/.gh-state"
  (
    cd "$R" && git init -q && git config user.email t@t && git config user.name t \
      && git symbolic-ref HEAD refs/heads/main \
      && printf '.harness/\n.beads/\n' >.gitignore && printf 'base\n' >README.md \
      && git add .gitignore README.md && git commit -q -m base \
      && git remote add origin https://github.com/agentic-builder-forge-assembly-noexist/self.git \
      && git config beads.role maintainer \
      && bd init --skip-agents --skip-hooks --non-interactive --prefix asm >/dev/null 2>&1 \
      && bd config set status.custom "in_review:wip" >/dev/null 2>&1
  ) >/dev/null 2>&1
  printf '%s' "$R"
}

# ── fake gh: record argv + serve canned JSON; state dir flips pr-state for the sync arm
install_fake_gh() {
  local ghp="$1" log="$2" st="$3"; mkdir -p "$st"; : >"$log"
  # honours gh's -q/--jq (like the real gh: applies the jq expr to the canned --json output) so
  # forge_ensure_feature_pr (`-q 'first(.[].url)//empty'`) and forge_reconcile_run (`-q '[.state,.headRefName]|@tsv'`)
  # see real filtered values. pr create bumps a counter (the exactly-one-create canary).
  cat >"$ghp" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"$log"
ST="$st"
JQE=""; prev=""
for a in "\$@"; do case "\$prev" in -q|--jq) JQE="\$a" ;; esac; prev="\$a"; done
emit() { if [ -n "\$JQE" ]; then printf '%s' "\$1" | jq -r "\$JQE" 2>/dev/null; else printf '%s\n' "\$1"; fi; }
case "\$1 \$2" in
  "pr create")
    n=\$(( \$(cat "\$ST/create-count" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"\$ST/create-count"
    echo "https://github.com/agentic-builder-forge-assembly-noexist/self/pull/7" ;;
  "pr list")  emit "\$(cat "\$ST/pr-list.json" 2>/dev/null || echo '[]')" ;;
  "pr view")  emit "\$(cat "\$ST/pr-state.json" 2>/dev/null || echo '{"state":"OPEN","headRefName":"feat/UNSET"}')" ;;
  "pr comment") echo "https://github.com/x/y/pull/7#c1" ;;
  "pr diff")  echo "" ;;
  *) echo "{}" ;;
esac
exit 0
EOF
  chmod +x "$ghp"
}

mint() { bd -C "$1" create "$2" --metadata "$3" -p 2 --silent </dev/null 2>/dev/null | tr -d '[:space:]'; }

run_start() { local o; o="$(script -qec "cd '$1' && PATH=\"$1/bin:\$PATH\" FORGE_SKIP_INSTALL=1 bash harness/run-task.sh start '$2'" /dev/null 2>&1)"; RC=$?; OUT="$(printf '%s' "$o" | tr -d '\r')"; }
run_finish(){ local o; o="$(script -qec "cd '$1' && PATH=\"$1/bin:\$PATH\" FORGE_SKIP_INSTALL=1 ${3:-} bash harness/run-task.sh finish" /dev/null 2>&1)"; RC=$?; OUT="$(printf '%s' "$o" | tr -d '\r')"; }

# seed_overlay <R> [a_status] [a_source] [b_source] [merge_mode]
#   builds feat/demo with an A-merge logged + bead A (a_status, a_source) + bead B (b_source) blocks-dep A.
#   merge_mode: ancestor (default; merge_commit IS feat/demo's tip) | orphan (merge_commit is unrelated).
# Exports: AID BID FEATBR SS MERGE_COMMIT
seed_overlay() {
  local R="$1" a_status="${2:-in_review}" a_src="${3-specs/demo.md}" b_src="${4-specs/demo.md}" mode="${5:-ancestor}"
  SS="specs/demo.md"; FEATBR="feat/demo"
  local a_meta b_meta
  [ -n "$a_src" ] && a_meta="{\"source_spec\":\"$a_src\"}" || a_meta='{"note":"no-source"}'
  [ -n "$b_src" ] && b_meta="{\"source_spec\":\"$b_src\"}" || b_meta='{"note":"no-source"}'
  AID="$(mint "$R" "task A" "$a_meta")"
  BID="$(mint "$R" "task B" "$b_meta")"
  bd -C "$R" dep "$AID" --blocks "$BID" >/dev/null 2>&1          # A blocks B (B depends_on A)
  git -C "$R" branch "$FEATBR" main >/dev/null 2>&1
  git -C "$R" worktree add "$R/.wta" -b task/a "$FEATBR" >/dev/null 2>&1
  mkdir -p "$R/.wta/sandbox/demo"; printf 'A contribution\n' >"$R/.wta/sandbox/demo/a.txt"
  git -C "$R/.wta" add sandbox/demo/a.txt; git -C "$R/.wta" -c user.email=t@t -c user.name=t commit -q -m "A work"
  local atip; atip="$(git -C "$R/.wta" rev-parse HEAD)"
  git -C "$R" worktree add "$R/.wtf" "$FEATBR" >/dev/null 2>&1
  git -C "$R/.wtf" -c user.email=t@t -c user.name=t merge --no-ff --no-edit "$atip" >/dev/null 2>&1
  MERGE_COMMIT="$(git -C "$R/.wtf" rev-parse HEAD)"
  git -C "$R" worktree remove --force "$R/.wta" >/dev/null 2>&1
  git -C "$R" worktree remove --force "$R/.wtf" >/dev/null 2>&1
  if [ "$mode" = "orphan" ]; then
    # a merge_commit that is NOT an ancestor of feat/demo (an unrelated commit on a detached scratch branch)
    git -C "$R" worktree add "$R/.wto" -b scratch/orphan main >/dev/null 2>&1
    printf 'orphan\n' >"$R/.wto/orphan.txt"; git -C "$R/.wto" add orphan.txt
    git -C "$R/.wto" -c user.email=t@t -c user.name=t commit -q -m orphan
    MERGE_COMMIT="$(git -C "$R/.wto" rev-parse HEAD)"
    git -C "$R" worktree remove --force "$R/.wto" >/dev/null 2>&1
  fi
  mkdir -p "$R/.harness/assembly"
  jq -nc --arg ss "$SS" --arg fb "$FEATBR" --arg a "$AID" --arg mc "$MERGE_COMMIT" \
    '{feature:"demo",source_spec:$ss,feat_branch:$fb,feature_pr:"",merges:[{bead:$a,task_branch:"task/a",task_sha:$mc,feat_before_sha:"",merge_commit:$mc,ts:"t",actor:"harness"}],state:"assembling",last_error:null}' \
    >"$R/.harness/assembly/demo.json"
  [ -n "$a_status" ] && [ "$a_status" != "open" ] && bd -C "$R" update "$AID" --status "$a_status" >/dev/null 2>&1
}

bd_ready_has() { bd -C "$1" ready --json 2>/dev/null | jq -e --arg id "$2" 'map(.id) | index($id) != null' >/dev/null 2>&1; }
claimed() { [ "$(bd -C "$1" show "$2" --json 2>/dev/null | jq -r '.[0].status // empty')" = "in_progress" ]; }

echo "============================================================"
echo "assembly keystone — harness: $HARNESS_SRC (overlay=$HAS_OVERLAY merge=$HAS_MERGE)"
echo "============================================================"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ARM 1+2 — the deadlock is REAL (PIN) and the overlay BREAKS it (the keystone, both directions)
# ════════════════════════════════════════════════════════════════════════════════════════════════
R="$(mk_forge_root)"; seed_overlay "$R"
echo "== deadlock-real: A in_review-merged onto feat/F -> bd ready is EMPTY for sibling B =="
if ! bd_ready_has "$R" "$BID"; then ok "bd ready excludes B (A in_review is a WIP blocker — the deadlock is real)"; else no "bd ready unexpectedly includes B (deadlock not reproduced)"; fi

echo "== overlay verdict: start B =="
run_start "$R" "$BID"
if [ "$HAS_OVERLAY" = 1 ]; then
  { [ "$RC" -eq 0 ] && claimed "$R" "$BID"; } && ok "overlay BREAKS the deadlock: start B succeeds + B claimed while bd ready was empty" || no "overlay should have claimed B" "rc=$RC $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
  # chained-sibling: B's worktree forks off feat/demo (carries A's merged work)
  bwt="$(jq -r '.worktree // empty' "$R/.harness/active-task.json" 2>/dev/null)"
  { [ -n "$bwt" ] && [ -f "$bwt/sandbox/demo/a.txt" ]; } && ok "B's worktree forked off feat/demo — it SEES A's merged work" || no "B's worktree did not carry A's work" "wt=$bwt"
else
  [ "$RC" -ne 0 ] && ok "deadlock confirmed: start B FAILS against the pre-overlay harness (no relaxation path)" || no "start B unexpectedly succeeded without the overlay"
fi

if [ "$HAS_OVERLAY" != 1 ]; then
  echo
  echo "RED until the door splice lands — the Q0 overlay is absent from $HARNESS_SRC."
  echo "The deadlock is REAL (proven above). Re-run with FORGE_ASSEMBLY_HARNESS=<candidate-harness> to prove GREEN."
  echo "==== assembly: $PASS passed, $FAIL failed, $SKIP skipped (RED-until-splice) ===="
  exit 1
fi

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ARMS 3-8 — fail-closed negatives + intra/cross classification + blocked surfacing  (overlay present)
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== neg: merge_commit NOT an ancestor of feat/F -> refuse =="
R="$(mk_forge_root)"; seed_overlay "$R" in_review specs/demo.md specs/demo.md orphan
run_start "$R" "$BID"
{ [ "$RC" -ne 0 ] && ! claimed "$R" "$BID"; } && ok "non-ancestor merge_commit -> start B refuses (ancestry fail-closed)" || no "non-ancestor should refuse" "rc=$RC"

echo "== neg: in_review dep with a DIFFERENT source_spec (cross-feature) -> refuse (must be closed) =="
R="$(mk_forge_root)"; seed_overlay "$R" in_review specs/other.md specs/demo.md
run_start "$R" "$BID"
{ [ "$RC" -ne 0 ] && ! claimed "$R" "$BID"; } && ok "cross-feature in_review dep -> start B refuses" || no "cross-feature in_review should refuse" "rc=$RC"

echo "== pos: a CLOSED cross-feature dep -> claim (native; closed satisfies all deps) =="
R="$(mk_forge_root)"; seed_overlay "$R" closed specs/other.md specs/demo.md
run_start "$R" "$BID"
{ [ "$RC" -eq 0 ] && claimed "$R" "$BID"; } && ok "closed cross-feature dep -> start B succeeds (classification precise, not lenient)" || no "closed dep should claim" "rc=$RC $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"

echo "== neg: dependent B has NO source_spec -> refuse (no grouping key) =="
R="$(mk_forge_root)"; seed_overlay "$R" in_review specs/demo.md ""
run_start "$R" "$BID"
{ [ "$RC" -ne 0 ] && ! claimed "$R" "$BID"; } && ok "no source_spec on B -> start B refuses (fail-closed)" || no "no-source-spec should refuse" "rc=$RC"

echo "== neg: in_review dep but NO recorded harness merge (assembly log absent) -> refuse (fail-closed) =="
R="$(mk_forge_root)"; seed_overlay "$R" in_review specs/demo.md specs/demo.md
rm -f "$R/.harness/assembly/demo.json"    # the satisfaction anchor (the harness merge record) is missing
run_start "$R" "$BID"
{ [ "$RC" -ne 0 ] && ! claimed "$R" "$BID"; } && ok "no recorded merge_commit -> start B refuses (the unforgeable anchor is absent)" || no "missing merge record should refuse" "rc=$RC"

echo "== blocked: B blocks-dep on an OPEN A (never finished) -> refuse + NAME the blocker, no side effects =="
R="$(mk_forge_root)"; seed_overlay "$R" open specs/demo.md specs/demo.md
run_start "$R" "$BID"
{ [ "$RC" -ne 0 ] && ! claimed "$R" "$BID"; } && ok "open blocker -> start B refuses, no claim" || no "open blocker should refuse" "rc=$RC"
printf '%s' "$OUT" | grep -qF "$AID" && ok "the refusal NAMES the unsatisfied blocker ($AID)" || no "refusal did not name the blocker" "$(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
[ ! -f "$R/.harness/active-task.json" ] && ok "blocked start created NO sentinel (no side effects)" || no "blocked start left a sentinel"

echo "== blocked + feat/F ABSENT: a refused claim leaves NO orphan feat/F (no-side-effect design rule; FINDING-1) =="
# NB: this arm deliberately does NOT use seed_overlay (which pre-creates feat/demo) — feat/F must be GENUINELY
# absent so the refused-claim path is exercised with feat/F creation still pending. RED vs the pre-fix shape (cmd_start
# creates feat/F BEFORE the claim verdict -> orphan branch on refusal); GREEN once creation is deferred to
# after the grant. The other "blocked" arm above (seed_overlay) cannot catch this — its fixture pre-creates feat/F.
R="$(mk_forge_root)"
FA="$(mint "$R" "task A" '{"source_spec":"specs/demo.md"}')"
FB="$(mint "$R" "task B" '{"source_spec":"specs/demo.md"}')"
bd -C "$R" dep "$FA" --blocks "$FB" >/dev/null 2>&1   # A blocks B; A is OPEN (never finished); no feat/demo, no log
run_start "$R" "$FB"
{ [ "$RC" -ne 0 ] && ! claimed "$R" "$FB"; } && ok "blocked B (feat/F absent) refuses, no claim" || no "blocked B (feat/F absent) should refuse" "rc=$RC"
printf '%s' "$OUT" | grep -qF "$FA" && ok "the refusal still NAMES the unsatisfied blocker ($FA)" || no "refusal did not name the blocker" "$(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
[ -z "$(git -C "$R" branch --list 'feat/*')" ] && ok "NO orphan feat/F created on the refused claim (no-side-effect)" || no "ORPHAN feat/F created on a refused claim (FINDING-1)" "$(git -C "$R" branch --list 'feat/*' | tr -d ' \n')"
[ ! -f "$R/.harness/active-task.json" ] && ok "blocked+absent start created NO sentinel" || no "blocked+absent start left a sentinel"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ARM 9-10 — forge_safe_git_merge: topo-assemble (A then B) + conflict HALTS, NEVER force (canary)
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== back-compat: a ready NON-feature bead (no source_spec) starts byte-identically (no feat/F) =="
R="$(mk_forge_root)"
NF="$(mint "$R" "plain task" '{"note":"non-feature"}')"
run_start "$R" "$NF"
{ [ "$RC" -eq 0 ] && claimed "$R" "$NF"; } && ok "non-feature bead claims natively (start succeeds)" || no "non-feature start failed" "rc=$RC $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
[ "$(jq -r '.source_spec // "MISSING"' "$R/.harness/active-task.json" 2>/dev/null)" = "" ] && ok "sentinel source_spec empty (non-feature path)" || no "sentinel source_spec not empty for non-feature"
[ "$(jq -r '.base' "$R/.harness/active-task.json" 2>/dev/null)" = "main" ] && ok "base == the integration base (main) — byte-identical fall-through" || no "base wrong for non-feature" "$(jq -r .base "$R/.harness/active-task.json" 2>/dev/null)"
[ -z "$(git -C "$R" branch --list 'feat/*')" ] && ok "no feat/* branch created for a non-feature bead" || no "a feature branch was wrongly created"

echo "== merge unit: forge_safe_git_merge topo-assembles A then B onto feat/F (--no-ff) =="
R="$(mk_forge_root)"
. "$R/harness/sandbox-lib.sh"
git -C "$R" branch feat/demo main >/dev/null 2>&1
git -C "$R" worktree add "$R/ua" -b task/ua feat/demo >/dev/null 2>&1
printf 'line1\n' >"$R/ua/f.txt"; git -C "$R/ua" add f.txt; git -C "$R/ua" -c user.email=t@t -c user.name=t commit -q -m A
ASHA="$(git -C "$R/ua" rev-parse HEAD)"; git -C "$R" worktree remove --force "$R/ua" >/dev/null 2>&1
outA="$(forge_safe_git_merge "$R" feat/demo "$ASHA")"; rcA=$?
{ [ "$rcA" -eq 0 ] && git -C "$R" cat-file -e "feat/demo:f.txt" 2>/dev/null; } && ok "merge A onto feat/demo (rc0; feat/demo carries A's file)" || no "merge A failed" "rc=$rcA"
git -C "$R" worktree add "$R/ub" -b task/ub feat/demo >/dev/null 2>&1   # B forks off feat/demo (WITH A)
[ -f "$R/ub/f.txt" ] && ok "B's worktree forked off feat/demo SEES A's merged file (chained sibling)" || no "B worktree missing A's file"
printf 'line1\nline2\n' >"$R/ub/f.txt"; git -C "$R/ub" add f.txt; git -C "$R/ub" -c user.email=t@t -c user.name=t commit -q -m B
BSHA="$(git -C "$R/ub" rev-parse HEAD)"; git -C "$R" worktree remove --force "$R/ub" >/dev/null 2>&1
outB="$(forge_safe_git_merge "$R" feat/demo "$BSHA")"; rcB=$?
mergeA="$(printf '%s' "$outA" | cut -f2)"; mergeB="$(printf '%s' "$outB" | cut -f2)"
[ "${FORGE_ASM_DBG:-0}" = 1 ] && echo "  DBG outA=[$outA] outB=[$outB] mergeA=$mergeA mergeB=$mergeB feat=$(git -C "$R" rev-parse feat/demo) rcB=$rcB"
{ [ "$rcB" -eq 0 ] && git -C "$R" merge-base --is-ancestor "$mergeA" "$mergeB" 2>/dev/null; } && ok "topo order on feat/demo: A's merge precedes B's" || no "merge B / topo order failed" "rc=$rcB"

echo "== conflict halts: same-line clash -> rc1 + merge --abort + feat/F unchanged + NO force flag (git-trace canary) =="
R="$(mk_forge_root)"
. "$R/harness/sandbox-lib.sh"
git -C "$R" branch feat/demo main >/dev/null 2>&1
git -C "$R" worktree add "$R/ux" -b task/ux main >/dev/null 2>&1
printf 'X\n' >"$R/ux/c.txt"; git -C "$R/ux" add c.txt; git -C "$R/ux" -c user.email=t@t -c user.name=t commit -q -m X
XSHA="$(git -C "$R/ux" rev-parse HEAD)"; git -C "$R" worktree remove --force "$R/ux" >/dev/null 2>&1
forge_safe_git_merge "$R" feat/demo "$XSHA" >/dev/null 2>&1     # feat/demo now has c.txt=X
FEAT_BEFORE="$(git -C "$R" rev-parse feat/demo)"
git -C "$R" worktree add "$R/uy" -b task/uy main >/dev/null 2>&1   # Y forks off MAIN (not feat/demo-with-X)
printf 'Y\n' >"$R/uy/c.txt"; git -C "$R/uy" add c.txt; git -C "$R/uy" -c user.email=t@t -c user.name=t commit -q -m Y
YSHA="$(git -C "$R/uy" rev-parse HEAD)"; git -C "$R" worktree remove --force "$R/uy" >/dev/null 2>&1
TRACE="$R/.gittrace"
GIT_TRACE="$TRACE" forge_safe_git_merge "$R" feat/demo "$YSHA" >/dev/null 2>&1; rcC=$?
[ "$rcC" -eq 1 ] && ok "conflict -> forge_safe_git_merge returns rc1 (HALT)" || no "conflict should return rc1" "rc=$rcC"
[ "$(git -C "$R" rev-parse feat/demo)" = "$FEAT_BEFORE" ] && ok "feat/demo UNCHANGED after the aborted conflict (merge --abort ran)" || no "feat/demo advanced on conflict"
if [ -f "$TRACE" ] && grep -Eq ' merge .*--no-ff' "$TRACE"; then
  ok "git-trace canary: a real merge (--no-ff) WAS traced (not a vacuous pass)"
  grep -E ' merge ' "$TRACE" | grep -Eq -- '(-X|--strateg|(^| )-s( |$)|--force|-Xours|-Xtheirs)' \
    && no "git-trace canary: the merge carried a force/strategy flag" \
    || ok "git-trace canary: the merge invocation carried NO -X/--strategy/-s/--force"
else
  no "git-trace canary: no merge invocation was traced (GIT_TRACE passthrough broken)"
fi

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ARM 11 — host-side assembly log helpers + the feature-complete cutover
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== assembly-log unit: init/append/set/merge_count round-trip; the record schema is exact =="
R="$(mk_forge_root)"
(
  set -u; ROOT="$R"; . "$R/harness/beads-lib.sh"
  forge_assembly_init "feat/demo" "specs/demo.md"
  forge_assembly_append "feat/demo" "asm-1" "task/1" "sha1" "before1" "merge1"
  forge_assembly_append "feat/demo" "asm-2" "task/2" "sha2" "merge1" "merge2"
  forge_assembly_set "feat/demo" feature_pr "https://example/pull/9"
  forge_assembly_set "feat/demo" state "complete"
  printf 'count=%s\n' "$(forge_assembly_merge_count feat/demo)"
) >"$R/.alog.out" 2>&1
AF="$R/.harness/assembly/demo.json"
jq -e '.feature=="demo" and .source_spec=="specs/demo.md" and .feat_branch=="feat/demo"' "$AF" >/dev/null 2>&1 && ok "assembly log: top-level {feature,source_spec,feat_branch}" || no "assembly log top-level wrong"
jq -e '(.merges|length)==2 and .merges[0].bead=="asm-1" and .merges[0].merge_commit=="merge1" and .merges[0].actor=="harness" and .merges[1].bead=="asm-2"' "$AF" >/dev/null 2>&1 && ok "assembly log: 2 merge records, exact schema {bead,task_branch,task_sha,feat_before_sha,merge_commit,ts,actor}" || no "assembly merges wrong" "$(jq -c .merges "$AF")"
jq -e '.feature_pr=="https://example/pull/9" and .state=="complete"' "$AF" >/dev/null 2>&1 && ok "assembly log: forge_assembly_set updates feature_pr + state" || no "assembly_set failed"
grep -q 'count=2' "$R/.alog.out" && ok "forge_assembly_merge_count == 2" || no "merge_count wrong" "$(cat "$R/.alog.out")"

echo "== feature-complete cutover: complete IFF no bead with this source_spec is open/in_progress =="
R="$(mk_forge_root)"
A1="$(mint "$R" "f1" '{"source_spec":"specs/demo.md"}')"; A2="$(mint "$R" "f2" '{"source_spec":"specs/demo.md"}')"
( set -u; ROOT="$R"; . "$R/harness/beads-lib.sh"
  forge_feature_complete "specs/demo.md" && echo "R1=complete" || echo "R1=incomplete" ) >"$R/.fc.out" 2>&1
grep -q 'R1=incomplete' "$R/.fc.out" && ok "two OPEN feature beads -> NOT complete" || no "should be incomplete with open beads"
bd -C "$R" update "$A1" --status in_review >/dev/null 2>&1; bd -C "$R" close "$A2" --reason done >/dev/null 2>&1
( set -u; ROOT="$R"; . "$R/harness/beads-lib.sh"
  forge_feature_complete "specs/demo.md" && echo "R2=complete" || echo "R2=incomplete" ) >>"$R/.fc.out" 2>&1
grep -q 'R2=complete' "$R/.fc.out" && ok "all feature beads in_review/closed -> COMPLETE" || no "should be complete" "$(cat "$R/.fc.out")"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ARM 12-13 — record(branch=feat/F) + ONE feature PR (discover-before-create) + sync closes together
# (forge_clean_env pins PATH (env -i) so the fixture's fake gh is unreachable by the REAL wrapper — that
#  hardening is forge_clean_env's OWN property; these units stub it to a pass-through to exercise the
#  gh-ORCHESTRATION + record + reconcile LOGIC with the fake gh.)
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== record + feature-PR + sync (fake gh; forge_clean_env stubbed to reach it) =="
R="$(mk_forge_root)"
B1="$(mint "$R" "feat bead 1" '{"source_spec":"specs/demo.md"}')"
B2="$(mint "$R" "feat bead 2" '{"source_spec":"specs/demo.md"}')"
(
  set -u; ROOT="$R"; export PATH="$R/bin:$PATH"
  . "$R/harness/beads-lib.sh"
  forge_clean_env() { GITHUB_TOKEN="${GITHUB_TOKEN:-x}" "$@"; }   # test stub: reach the fixture's fake gh
  printf '[]\n' >"$R/.gh-state/pr-list.json"
  u1="$(forge_ensure_feature_pr "owner/repo" "feat/demo" "main" "demo" "body")"
  jq -nc --arg u "$u1" '[{url:$u}]' >"$R/.gh-state/pr-list.json"          # the PR now exists (push refreshed it)
  u2="$(forge_ensure_feature_pr "owner/repo" "feat/demo" "main" "demo" "body")"
  printf 'create_count=%s u1=%s u2=%s\n' "$(cat "$R/.gh-state/create-count" 2>/dev/null || echo 0)" "$u1" "$u2"
  grep -q 'pr merge' "$R/.gh-calls.log" && echo "GH_PR_MERGE=yes" || echo "GH_PR_MERGE=no"
  # record BOTH feature beads against feat/demo + the SAME feature PR
  forge_finish_record_pr "$B1" "owner/repo" "feat/demo" "$u1" "$R/.harness"
  forge_finish_record_pr "$B2" "owner/repo" "feat/demo" "$u1" "$R/.harness"
  printf 'B1_BRANCH=%s\n' "$(jq -r '.branch // empty' "$R/.harness/pr/$B1.json" 2>/dev/null)"   # before reconcile consumes it
  # sync: fake gh pr view -> MERGED + headRefName==feat/demo -> reconcile closes BOTH together
  printf '{"state":"MERGED","headRefName":"feat/demo"}\n' >"$R/.gh-state/pr-state.json"
  forge_reconcile_run quiet
  printf 'B1=%s B2=%s\n' "$(bd -C "$R" show "$B1" --json | jq -r '.[0].status')" "$(bd -C "$R" show "$B2" --json | jq -r '.[0].status')"
) >"$R/.gh.out" 2>&1
grep -q 'create_count=1 ' "$R/.gh.out" && ok "exactly ONE gh pr create across two finishes (discover-before-create)" || no "feature PR not created exactly once" "$(grep create_count "$R/.gh.out")"
grep -q 'GH_PR_MERGE=no' "$R/.gh.out" && ok "human-merge-only: forge_ensure_feature_pr NEVER calls gh pr merge" || no "gh pr merge was called"
grep -q 'B1_BRANCH=feat/demo' "$R/.gh.out" && ok "feature bead records branch==feat/demo (not the task branch)" || no "record branch wrong" "$(grep B1_BRANCH "$R/.gh.out")"
grep -q "B1=closed B2=closed" "$R/.gh.out" && ok "sync closes ALL feature beads TOGETHER (shared feat/F + feature PR, MERGED)" || no "sync did not close the feature together" "$(grep 'B1=' "$R/.gh.out")"
[ ! -f "$R/.harness/pr/$B1.json" ] && ok "the captured-PR record is single-use (consumed on close)" || no "record not consumed on close"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ARM 15-16 — cmd_finish REAL-finish integration: first-task-fails (NOT partial) vs partial-after-merge.
# (Finish dies at the noexist push by design — the forge's unredirectable push; we assert the PRE-push
#  merge/log/state. A's post-push in_review is simulated, since the real push can't reach a fake remote.)
# ════════════════════════════════════════════════════════════════════════════════════════════════
_TJ='{"id":"T001","title":"t","scope":["sandbox/**"],"dod_tests":["sandbox/demo/t.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/demo/ev.txt"}]}'
_TJ2='{"id":"T002","title":"t","scope":["sandbox/**"],"dod_tests":["sandbox/demo/t.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/demo/ev.txt"}]}'
write_spec()   { mkdir -p "$1/specs"; { printf '# demo\n\n<!-- forge:tasks:begin v1 -->\n```json\n'; printf '{"target_repos":["agentic-builder-forge"],"tasks":[%s,%s]}\n' "$_TJ" "$_TJ2"; printf '```\n<!-- forge:tasks:end -->\n'; } >"$1/specs/demo.md"; }
mint_contract(){ local slice; slice="$(printf '%s' "$_TJ" | jq -c '{scope,dod_tests,sc_evidence}')"; mint "$1" "$2" "$(jq -nc --arg s specs/demo.md --arg t "$3" --argjson a "$slice" '{source_spec:$s,task_id:$t,accept:$a}')"; }
put_work()     { mkdir -p "$1/sandbox/demo"; printf '#!/usr/bin/env bash\nexit %s\n' "${2:-0}" >"$1/sandbox/demo/t.sh"; printf 'evidence\n' >"$1/sandbox/demo/ev.txt"; }
sentinel_wt()  { jq -r '.worktree // empty' "$1/.harness/active-task.json" 2>/dev/null; }

echo "== cmd_finish: FIRST task fails the gate -> NORMAL failure, NO partial state, no assembly log =="
R="$(mk_forge_root)"; write_spec "$R"; AID="$(mint_contract "$R" "task A" T001)"
run_start "$R" "$AID"
if [ "$RC" -eq 0 ]; then
  put_work "$(sentinel_wt "$R")" 1                       # dod exits 1 -> the staged gate RED-gates
  run_finish "$R"
  [ "$RC" -ne 0 ] && ok "first-task finish FAILS (gate RED)" || no "first-task finish should fail" "rc=$RC"
  [ ! -f "$R/.harness/assembly/demo.json" ] && ok "NO assembly log on a first-task gate failure (nothing merged -> not partial)" || no "first-task failure left an assembly log" "$(jq -c . "$R/.harness/assembly/demo.json" 2>/dev/null)"
  claimed "$R" "$AID" && ok "A stays claimed after the gate RED (re-runnable)" || no "A not claimed after RED"
else
  no "start A (contract bead) failed" "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

echo "== cmd_finish: a LATER task fails AFTER a sibling merged -> PARTIAL surfaced, no rollback =="
R="$(mk_forge_root)"; write_spec "$R"
AID="$(mint_contract "$R" "task A" T001)"; BID="$(mint_contract "$R" "task B" T002)"
bd -C "$R" dep "$AID" --blocks "$BID" >/dev/null 2>&1
run_start "$R" "$AID"
if [ "$RC" -eq 0 ]; then
  put_work "$(sentinel_wt "$R")" 0                        # A passes the gate -> merge+log -> push dies
  run_finish "$R"
  { [ -f "$R/.harness/assembly/demo.json" ] && [ "$(jq -r '(.merges|length)' "$R/.harness/assembly/demo.json")" = "1" ]; } \
    && ok "A merged onto feat/demo + LOGGED (pre-push), even though finish died at the noexist push" \
    || no "A merge/log missing" "rc=$RC $(jq -c . "$R/.harness/assembly/demo.json" 2>/dev/null)"
  rm -f "$R/.harness/active-task.json"                    # A's finish died pre-sentinel-clear; clear to start B
  bd -C "$R" update "$AID" --status in_review >/dev/null 2>&1   # simulate A's post-push in_review (precondition)
  run_start "$R" "$BID"
  if [ "$RC" -eq 0 ]; then
    put_work "$(sentinel_wt "$R")" 1                      # B RED-gates AFTER A is merged
    run_finish "$R"
    [ "$RC" -ne 0 ] && ok "B finish FAILS (gate RED after A merged)" || no "B finish should fail"
    [ "$(jq -r '.state' "$R/.harness/assembly/demo.json" 2>/dev/null)" = "partial" ] && ok "assembly state -> 'partial' (later task RED-gated after >=1 sibling merged)" || no "state not partial" "$(jq -c . "$R/.harness/assembly/demo.json" 2>/dev/null)"
    [ "$(jq -r '(.merges|length)' "$R/.harness/assembly/demo.json" 2>/dev/null)" = "1" ] && ok "NO rollback: A's merge stays on feat/demo + in the log" || no "A's merge was rolled back"
    printf '%s' "$(jq -r '.last_error // empty' "$R/.harness/assembly/demo.json" 2>/dev/null)" | grep -qF "$BID" && ok "last_error names the failing bead ($BID)" || no "last_error does not name B"
    claimed "$R" "$BID" && ok "B stays claimed (human resolves the partial)" || no "B not claimed"
  else
    no "start B via overlay (post-A-merge) failed" "rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
  fi
else
  no "start A (contract bead) failed for the partial arm" "rc=$RC"
fi

echo "== static: human-merge-only — no 'gh pr merge' call; the assembly auto-merges ONLY onto feat/F =="
if grep -rn 'gh pr merge' "$HARNESS_SRC"/*.sh 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' | grep -q .; then no "found a 'gh pr merge' CALL in the harness (human-merge-only violated)"; else ok "no 'gh pr merge' call anywhere in the harness"; fi
grep -qE 'forge_safe_git_merge "\$_repo_root" "\$feat_branch"' "$HARNESS_SRC/run-task.sh" && ok "the only auto-merge is forge_safe_git_merge onto \$feat_branch (never main)" || no "assembly merge target is not feat/F"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ARM 14 — the surfacing artifact is enforce-protected: the DEPLOYED floor DENIES an agent write
# ════════════════════════════════════════════════════════════════════════════════════════════════
echo "== floor: an agent-style write to .harness/assembly/*.json is DENIED by the EXISTING deny-floor (no floor change) =="
DENY="$ROOT/.claude/hooks/pre-tool-use-deny.sh"
if [ -x "$DENY" ]; then
  for tgt in ".harness/assembly/test.json" ".harness/pr/feat.json"; do
    vd="$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$tgt" | "$DENY" 2>/dev/null)"; vrc=$?
    if [ "$vrc" -ne 0 ] || printf '%s' "$vd" | grep -qi 'deny'; then ok "deny-floor DENIES an agent Write to $tgt (unforgeable surfacing artifact)"; else no "deny-floor did NOT deny $tgt" "rc=$vrc out=$vd"; fi
  done
  vd="$(printf '{"tool_name":"Write","tool_input":{"file_path":"sandbox/ok.txt","content":"x"}}' | "$DENY" 2>/dev/null)"; vrc=$?
  { [ "$vrc" -eq 0 ] && ! printf '%s' "$vd" | grep -qi 'deny'; } && ok "control: a sandbox/ write is ALLOWED (the floor is targeted, not blanket)" || skp "floor-control" "deployed deny hook shape differs (rc=$vrc) — assembly/pr denials above are the load-bearing check"
else
  skp "floor-probe" "no deployed pre-tool-use-deny.sh to probe (verified in-source + by deployed-floor probe)"
fi

echo
echo "==== assembly: $PASS passed, $FAIL failed, $SKIP skipped ===="
echo "== real-ledger byte-unchanged guard =="
[ "$(ledger_state)" = "$BEADS_BEFORE" ] && ok "REAL .beads byte-unchanged" || no "REAL ledger CHANGED — GUARD TRIPPED"
[ "$FAIL" = 0 ] || exit 1
exit 0
