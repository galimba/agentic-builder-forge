#!/usr/bin/env bash
# Tests for the agentic-builder-forge intake: spec-template schema invariants + intake.sh scaffolding.
# Runs the scripts DIRECTLY (no Claude), so the contract is proven before anything goes live.
#
# Run: bash tests/intake/run.sh   (or: pnpm test:intake)
#
# Pre-splice candidate verification (mirrors tests/hooks/run.sh FORGE_DENY_HOOK): point the overrides at
# the sandbox candidate before the harness/ + templates/ copies exist:
#   FORGE_INTAKE="$PWD/path/to/candidate/intake.sh" \
#   INTAKE_TEMPLATE="$PWD/path/to/candidate/spec-template.md" bash tests/intake/run.sh
# The invariants-7/8/9 section proves against $INTAKE (the deployed harness, which
# enforces them; the candidate was retired) — see the seam block below; fail-closed if
# the deployed harness ever stops rejecting a fields-missing spec.
set -u
# Fixtures must never prompt — on a TTY stdin, plain `bd init` blocks on the contributor
# wizard. Per-call flags are primary; this env is the backstop for future fixtures.
export BD_NON_INTERACTIVE=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INTAKE="${FORGE_INTAKE:-$ROOT/harness/intake.sh}"
TEMPLATE="${INTAKE_TEMPLATE:-$ROOT/templates/spec-template.md}"
FIX="$ROOT/tests/intake/fixtures/specs"
PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT" 2>/dev/null' EXIT

ok() { PASS=$((PASS + 1)); }
no() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s]\n' "$1"
}

# --- schema: sentinel extraction + the six jq-checkable invariants ------------

# extract_tasks_json <spec.md> : print the JSON between the sentinels (fence lines stripped). Anything
# outside the begin/end sentinels — including decoy ```json blocks — is ignored.
extract_tasks_json() {
  awk '
    /<!-- forge:tasks:begin/ { infence = 1; next }
    /<!-- forge:tasks:end/   { infence = 0 }
    infence && $0 !~ /^```/ { print }
  ' "$1"
}

# validate_acyclic <json-file> : Kahn topological sort; exit 0 iff the depends_on graph is a DAG.
validate_acyclic() {
  local f="$1" id dep cur s removed=0 n
  declare -A INDEG SUCC
  local -a NODES=() queue=()
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    NODES+=("$id")
    : "${INDEG[$id]:=0}"
  done < <(jq -r '.tasks[].id' "$f" 2>/dev/null)
  while read -r id dep; do
    [ -n "$dep" ] || continue
    SUCC[$dep]="${SUCC[$dep]:-}$id "
    INDEG[$id]=$((${INDEG[$id]:-0} + 1))
  done < <(jq -r '.tasks[] | .id as $i | .depends_on[]? | "\($i) \(.)"' "$f" 2>/dev/null)
  n=${#NODES[@]}
  for id in "${NODES[@]}"; do [ "${INDEG[$id]:-0}" -eq 0 ] && queue+=("$id"); done
  while [ "${#queue[@]}" -gt 0 ]; do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")
    removed=$((removed + 1))
    for s in ${SUCC[$cur]:-}; do
      INDEG[$s]=$((INDEG[$s] - 1))
      [ "${INDEG[$s]}" -eq 0 ] && queue+=("$s")
    done
  done
  [ "$removed" -eq "$n" ]
}

# validate_tasks_json <json-file> : exit 0 iff all six invariants hold; else non-zero + name the offender.
validate_tasks_json() {
  local f="$1" bad
  jq -e '.tasks | type == "array" and length > 0' "$f" >/dev/null 2>&1 || {
    echo "no tasks[]"
    return 1
  }
  # 1. every task has all required keys
  bad="$(jq -r '.tasks[] | select([has("id"), has("title"), has("satisfies"), has("priority"), has("depends_on"), has("target_repo"), has("definition_of_done"), has("success_criteria")] | all | not) | .id // "?"' "$f")"
  [ -z "$bad" ] || {
    echo "missing required key: $bad"
    return 1
  }
  # 2. id format + uniqueness
  bad="$(jq -r '.tasks[] | select(.id | test("^T[0-9]{3}$") | not) | .id' "$f")"
  [ -z "$bad" ] || {
    echo "bad id format: $bad"
    return 1
  }
  jq -e '(.tasks | map(.id)) as $i | ($i | unique | length) == ($i | length)' "$f" >/dev/null 2>&1 || {
    echo "duplicate id"
    return 1
  }
  # 3. priority enum
  bad="$(jq -r '.tasks[] | select(.priority | test("^P[123]$") | not) | .id' "$f")"
  [ -z "$bad" ] || {
    echo "bad priority: $bad"
    return 1
  }
  # 5. non-empty arrays
  bad="$(jq -r '.tasks[] | select((.satisfies | length == 0) or (.definition_of_done | length == 0) or (.success_criteria | length == 0)) | .id' "$f")"
  [ -z "$bad" ] || {
    echo "empty satisfies/DoD/SC: $bad"
    return 1
  }
  # 6. target_repo in target_repos
  bad="$(jq -r '.target_repos as $r | .tasks[] | select(.target_repo as $t | $r | index($t) | not) | .id' "$f")"
  [ -z "$bad" ] || {
    echo "target_repo not in target_repos: $bad"
    return 1
  }
  # 4a. every depends_on resolves to a real task id
  bad="$(jq -r '(.tasks | map(.id)) as $ids | .tasks[] | .id as $i | .depends_on[]? | select($ids | index(.) | not) | "\($i)->\(.)"' "$f")"
  [ -z "$bad" ] || {
    echo "dangling depends_on: $bad"
    return 1
  }
  # 4b. acyclic
  validate_acyclic "$f" || {
    echo "cycle in depends_on"
    return 1
  }
  return 0
}

assert_valid() {
  if validate_tasks_json "$2" >/dev/null 2>&1; then ok; else no "$1 (expected VALID, got: $(validate_tasks_json "$2" 2>&1))"; fi
}
assert_reject() {
  if validate_tasks_json "$2" >/dev/null 2>&1; then no "$1 (expected REJECT, got accept)"; else ok; fi
}

echo "== intake schema: invariants on fixtures =="
assert_valid "valid 2-task fixture" "$FIX/valid.json"
assert_reject "duplicate id" "$FIX/dup-id.json"
assert_reject "dangling depends_on" "$FIX/dangling-dep.json"
assert_reject "cyclic depends_on" "$FIX/cycle.json"
assert_reject "bad priority enum" "$FIX/bad-priority.json"
assert_reject "empty satisfies" "$FIX/empty-satisfies.json"
assert_reject "missing required key" "$FIX/missing-key.json"
assert_reject "target_repo not in target_repos" "$FIX/target-not-in-repos.json"

echo "== intake schema: sentinel extraction from a full spec =="
EX="$TMPROOT/extracted.json"
extract_tasks_json "$FIX/valid-spec.md" >"$EX"
if jq -e . "$EX" >/dev/null 2>&1; then ok; else no "extract_tasks_json yields valid JSON"; fi
assert_valid "extracted block validates" "$EX"

# --- scaffolding: intake.sh start --------------------------------------------

run_intake() { # <specs-dir> <args...> — each call gets a FRESH harness dir so the intake sentinel armed by
  local specs="$1" # `start` is isolated (never the real .harness, never arming the running session's gates),
  shift            # and sequential starts in the same specs dir do not collide on a shared sentinel.
  INTAKE_SPECS_DIR="$specs" INTAKE_TEMPLATE="$TEMPLATE" FORGE_HARNESS_DIR="$(mktemp -d -p "$TMPROOT")" bash "$INTAKE" "$@" >/dev/null 2>&1
}

echo "== intake start: scaffolding =="
S1="$TMPROOT/specs1"
if run_intake "$S1" start "Let reviewers leave comments" --target agentic-builder-forge --mode interactive; then ok; else no "start exits 0 on a good objective"; fi
SPEC="$S1/001-let-reviewers-leave-comments/spec.md"
[ -f "$SPEC" ] && ok || no "creates 001-<slug>/spec.md"
grep -qxF -- "- **Objective:** Let reviewers leave comments" "$SPEC" && ok || no "Header Objective filled"
grep -qxF -- "- **Target Repo(s):** agentic-builder-forge" "$SPEC" && ok || no "Header Target filled"
grep -qxF -- "- **Mode:** interactive" "$SPEC" && ok || no "Header Mode filled"
grep -qxF -- "- **Status:** draft" "$SPEC" && ok || no "Header Status = draft"
grep -qF "<!-- forge:tasks:begin v1 -->" "$SPEC" && ok || no "Task Breakdown sentinel carried through"
if awk '/^## Header/{h=1;next} /^---/{if(h)exit} h' "$SPEC" | grep -q '\[PLACEHOLDER'; then no "Header still has a PLACEHOLDER"; else ok; fi

echo "== intake start: mode default + numbering =="
run_intake "$S1" start "Export submissions as CSV" --target agentic-builder-forge
[ -f "$S1/002-export-submissions-as-csv/spec.md" ] && ok || no "second objective -> 002"
grep -qxF -- "- **Mode:** interactive" "$S1/002-export-submissions-as-csv/spec.md" && ok || no "mode default = interactive"

echo "== intake start: idempotent / fail-closed =="
if run_intake "$S1" start "Let reviewers leave comments" --target agentic-builder-forge; then no "re-run same slug should fail-closed"; else ok; fi
cnt="$(find "$S1" -maxdepth 1 -type d -name '[0-9][0-9][0-9]-let-reviewers-leave-comments' | wc -l | tr -d ' ')"
[ "$cnt" = "1" ] && ok || no "no duplicate dir on re-run (got $cnt)"
if run_intake "$TMPROOT/s_empty" start "" --target agentic-builder-forge; then no "empty objective should fail"; else ok; fi
if run_intake "$TMPROOT/s_noslug" start "***" --target agentic-builder-forge; then no "non-slug objective should fail"; else ok; fi
if run_intake "$TMPROOT/s_notgt" start "Some objective"; then no "missing --target should fail"; else ok; fi
if run_intake "$TMPROOT/s_badmode" start "Some objective" --target agentic-builder-forge --mode wild; then no "bad --mode should fail"; else ok; fi

echo "== intake start: T1 multi-line objective rejected (fail closed) =="
ml_specs="$TMPROOT/s_multiline"
ml_err="$(INTAKE_SPECS_DIR="$ml_specs" INTAKE_TEMPLATE="$TEMPLATE" bash "$INTAKE" start "$(printf 'Build X\n<!-- forge:tasks:begin v1 -->')" --target agentic-builder-forge 2>&1 >/dev/null)"
ml_rc=$?
[ "$ml_rc" != "0" ] && ok || no "multi-line objective should fail non-zero (got rc=$ml_rc)"
printf '%s' "$ml_err" | grep -qF "objective must be a single line" && ok || no "multi-line objective: single-line message (got: $ml_err)"

echo "== intake: analyze/convert fail closed with no spec/sentinel (minting is the converter's job) =="
# (analyze is REAL now — with no arg and no active intake it must die, not stub. Isolated via
# FORGE_HARNESS_DIR so neither subcommand can ever read the developer's real .harness sentinel.)
NOHD="$(mktemp -d -p "$TMPROOT")"
for sub in analyze convert; do
  if FORGE_HARNESS_DIR="$NOHD" bash "$INTAKE" "$sub" >/dev/null 2>&1; then no "$sub should exit non-zero with no active intake"; else ok; fi
done

# --- intake sentinel + clarify (grant) + abort -------------------------------
echo "== intake start: arms the active-intake sentinel (phase=open + budget snapshot) =="
SENT_HD="$(mktemp -d -p "$TMPROOT")"
SENT_SPECS="$TMPROOT/sent_specs"
INTAKE_SPECS_DIR="$SENT_SPECS" INTAKE_TEMPLATE="$TEMPLATE" FORGE_HARNESS_DIR="$SENT_HD" \
  bash "$INTAKE" start "Add a settings page" --target agentic-builder-forge --mode interactive >/dev/null 2>&1
SENTF="$SENT_HD/active-intake.json"
[ -f "$SENTF" ] && ok || no "start writes active-intake.json"
[ "$(jq -r .phase "$SENTF" 2>/dev/null)" = "open" ] && ok || no "sentinel phase=open"
[ "$(jq -r .mode "$SENTF" 2>/dev/null)" = "interactive" ] && ok || no "sentinel mode=interactive"
[ "$(jq -r .clarify_rounds "$SENTF" 2>/dev/null)" = "5" ] && ok || no "sentinel clarify_rounds=5 (config default)"
[ "$(jq -r .spec "$SENTF" 2>/dev/null)" = "$SENT_SPECS/001-add-a-settings-page/spec.md" ] && ok || no "sentinel spec path points at the scaffolded spec"

echo "== intake start: single-writer — refuses while an intake is active =="
if INTAKE_SPECS_DIR="$SENT_SPECS" INTAKE_TEMPLATE="$TEMPLATE" FORGE_HARNESS_DIR="$SENT_HD" \
     bash "$INTAKE" start "Another objective entirely" --target agentic-builder-forge >/dev/null 2>&1; then
  no "second start should refuse while an intake is active"
else ok; fi

echo "== intake clarify: grants a round (human override; intent-clarity > quota) =="
FORGE_HARNESS_DIR="$SENT_HD" bash "$INTAKE" clarify >/dev/null 2>&1 && ok || no "clarify exits 0 with an active intake"
[ "$(cat "$SENT_HD/intake-clarify-grant" 2>/dev/null)" = "1" ] && ok || no "clarify increments the grant counter"
FORGE_HARNESS_DIR="$SENT_HD" bash "$INTAKE" clarify >/dev/null 2>&1
[ "$(cat "$SENT_HD/intake-clarify-grant" 2>/dev/null)" = "2" ] && ok || no "clarify grant accumulates"

echo "== intake abort: clears the sentinel + counters (spec left in place) =="
FORGE_HARNESS_DIR="$SENT_HD" bash "$INTAKE" abort >/dev/null 2>&1 && ok || no "abort exits 0"
[ ! -f "$SENTF" ] && ok || no "abort removes the sentinel"
[ ! -f "$SENT_HD/intake-clarify-grant" ] && ok || no "abort clears the clarify-grant counter"
[ -f "$SENT_SPECS/001-add-a-settings-page/spec.md" ] && ok || no "abort leaves the spec in place"

echo "== intake clarify: no active intake -> fails closed =="
EMPTY_HD="$(mktemp -d -p "$TMPROOT")"
if FORGE_HARNESS_DIR="$EMPTY_HD" bash "$INTAKE" clarify >/dev/null 2>&1; then no "clarify with no active intake should fail"; else ok; fi

# --- Gate-A ratify + anti-TOCTOU convert gate + clarify re-open ---------------------------------------
# B+C/G3: the catastrophic ratify floor reads the ## Deferrals ledger, so the default Gate-A spec bodies must
# cover the by-default catastrophic categories — else every ratify/convert test would block at G3 under the
# candidate (the ratify-side equivalent of the OK_SPEC migration). Generate the by-default-covered ledger from
# the SAME enum cmd_ratify reads (candidate via FORGE_INTAKE_CATEGORIES, else deployed). On the deployed
# pre-splice RED run (no enum) LBC is empty — the deployed cmd_ratify has no G3, so the ledger is irrelevant there.
CATS="${FORGE_INTAKE_CATEGORIES:-$ROOT/harness/intake-categories.json}"
LBC="$(jq -r '.categories[]? | if .risk_default=="by-default" then "- `\(.id)` — covered by FR-001" else "- `\(.id)` — deliberately N/A — fixture default" end' "$CATS" 2>/dev/null)"
G_BODY=$'## User Scenarios\n### US1 (P1) — x\n## Requirements\n- FR-001: System MUST x. (US1)\n## Success Criteria\n- SC-001: completes in under 2 seconds.\n## Deferrals / Out of scope\n'"$LBC"
U_BODY=$'# Understanding\n## What the FRs will build\nThe thing the FRs describe.'
# Ratify verifies the FULL Gate-A floor, so the default setup carries the reviewer-loop evidence —
# a consensus restatement.md (1 round, 0 open findings). The strengthened precondition changes no
# assertion. Optional args vary it: $1 = restatement body ("NONE" omits the file), $2 = understanding body.
RST_CONSENSUS=$'# Restatement\n## Open findings\n## History\n### Restatement round 1\nreviewer: AGREE'
gsetup() { # [restatement|NONE] [understanding] — fresh hd: sentinel(open) + clean spec + understanding (+ restatement)
  local rst="${1:-$RST_CONSENSUS}" und="${2:-$U_BODY}" hd
  hd="$(mktemp -d -p "$TMPROOT")"
  mkdir -p "$hd/s"
  printf '%s' "$G_BODY" >"$hd/s/spec.md"
  printf '%s' "$und" >"$hd/s/understanding.md"
  if [ "$rst" != "NONE" ]; then printf '%s' "$rst" >"$hd/s/restatement.md"; fi
  # Stage E: stage a captured spec-review record DERIVED from the restatement body — cmd_ratify now requires a
  # record (the re-expressed C7 evidence) and reads its open-count as the consensus oracle. Deriving it from
  # $rst keeps deployed (restatement.md) and candidate (record) behaviour identical; trap-proof fixtures
  # override with a diverging record. rst=NONE => no record (cmd_ratify dies at the rst-exists check first, as before).
  if [ "$rst" != "NONE" ]; then
    local _no _ssha; _ssha="$(sha256sum "$hd/s/spec.md" | cut -d' ' -f1)"  # Stage E anti-TOCTOU: bind to the spec
    _no="$(printf '%s' "$rst" | grep -cE '^- \[(DISAGREE|ESCALATE)\]' 2>/dev/null)"; case "$_no" in '' | *[!0-9]*) _no=0 ;; esac
    if [ "$_no" -gt 0 ]; then
      jq -nc --arg ssha "$_ssha" --argjson n "$_no" '{verdict:"DISAGREE",spec_sha256:$ssha,findings:[range($n)|{id:("f"+(.+1|tostring)),category:"misc-placeholders",location:"FR-001",finding:"open"}]}' >"$hd/intake-spec-review.json"
    else
      jq -nc --arg ssha "$_ssha" '{verdict:"AGREE",spec_sha256:$ssha,findings:[]}' >"$hd/intake-spec-review.json"
    fi
  fi
  jq -nc --arg s "$hd/s/spec.md" '{spec:$s,mode:"interactive",phase:"open",clarify_rounds:5,restate_rounds:3,clarify_max_q:4}' >"$hd/active-intake.json"
  printf '%s' "$hd"
}

# cmd_ratify requires an interactive terminal ([ -t 0 ] && [ -t 1 ]). The agent's Bash
# tool is non-TTY (that IS the security property); a human's terminal is a TTY. So EVERY legitimate ratify
# below runs under a PTY via `script` (verified to flip [ -t 0 ] true here): -e returns ratify's real exit
# code, and the child's combined stdout+stderr come back on our stdout for the message-grep fixtures. The
# ONLY bare (non-PTY) ratify call is the new TTY-refusal fixture. If `script` is missing, fail loudly
# rather than let the success fixtures falsely pass.
command -v script >/dev/null 2>&1 && ok || no "(precondition) util-linux 'script' present for the PTY ratify helper"
ratify_human() { local hd="$1"; shift; FORGE_HARNESS_DIR="$hd" script -qec "bash '$INTAKE' ratify $*" /dev/null 2>&1; }
# Gate A′: the breakdown sign-off is ALSO TTY-gated — same PTY helper shape as ratify_human.
ratify_breakdown_human() { local hd="$1"; shift; FORGE_HARNESS_DIR="$hd" script -qec "bash '$INTAKE' ratify-breakdown $*" /dev/null 2>&1; }
# Both Gate-A gates in pipeline order (spec ratify -> breakdown ratify). Gate A′ makes convert REQUIRE
# both tokens, so every mint test that used to ratify-only is migrated to gate_a_full (the breaking-change
# fixture migration — every fixture exercising the convert path). FR-drift / legacy-token tests stay on
# ratify_human: they die at the FR-token gate (before the breakdown gate), proving FR-drift still fires there.
gate_a_full() { ratify_human "$1" >/dev/null 2>&1 && ratify_breakdown_human "$1" >/dev/null 2>&1; }

echo "== intake ratify: Gate-A sign-off binds a sha256 token + flips phase=ratified (via PTY) =="
GHD="$(gsetup)"
ratify_human "$GHD" >/dev/null 2>&1 && ok || no "ratify exits 0 when understanding.md is ratifiable"
[ -f "$GHD/intake-ratified.json" ] && ok || no "ratify writes .harness/intake-ratified.json"
[ "$(jq -r .phase "$GHD/active-intake.json" 2>/dev/null)" = "ratified" ] && ok || no "ratify flips phase -> ratified"
[ -n "$(jq -r '.sha256 // empty' "$GHD/intake-ratified.json" 2>/dev/null)" ] && ok || no "ratify records understanding.md sha256"

echo "== intake ratify: refuses without understanding.md =="
G2="$(mktemp -d -p "$TMPROOT")"
mkdir -p "$G2/s"
printf '%s' "$G_BODY" >"$G2/s/spec.md"
jq -nc --arg s "$G2/s/spec.md" '{spec:$s,mode:"interactive",phase:"open",clarify_rounds:5,restate_rounds:3,clarify_max_q:4}' >"$G2/active-intake.json"
if ratify_human "$G2" >/dev/null 2>&1; then no "ratify should refuse without understanding.md"; else ok; fi

echo "== intake convert: anti-TOCTOU — verifies when unchanged, refuses on understanding.md drift =="
GHD2="$(gsetup)"
ratify_human "$GHD2" >/dev/null 2>&1
cv_ok="$(FORGE_HARNESS_DIR="$GHD2" bash "$INTAKE" convert 2>&1 >/dev/null)"
printf '%s' "$cv_ok" | grep -qF "ratification verified" && ok || no "convert verifies ratification when understanding.md is unchanged (got: $cv_ok)"
printf '\nDRIFT\n' >>"$GHD2/s/understanding.md"
cv_drift="$(FORGE_HARNESS_DIR="$GHD2" bash "$INTAKE" convert 2>&1 >/dev/null)"
printf '%s' "$cv_drift" | grep -qF "changed since ratification" && ok || no "convert refuses on understanding.md drift (anti-TOCTOU) (got: $cv_drift)"

echo "== intake convert: refuses when Gate A not ratified =="
GHD3="$(gsetup)"
if FORGE_HARNESS_DIR="$GHD3" bash "$INTAKE" convert >/dev/null 2>&1; then no "convert should refuse when phase != ratified"; else ok; fi

echo "== intake clarify: re-opens Gate A and invalidates the ratify token =="
GHD4="$(gsetup)"
ratify_human "$GHD4" >/dev/null 2>&1
[ -f "$GHD4/intake-ratified.json" ] && ok || no "(precondition) token exists after ratify"
FORGE_HARNESS_DIR="$GHD4" bash "$INTAKE" clarify >/dev/null 2>&1
[ "$(jq -r .phase "$GHD4/active-intake.json" 2>/dev/null)" = "open" ] && ok || no "clarify re-opens phase ratified -> open"
[ ! -f "$GHD4/intake-ratified.json" ] && ok || no "clarify invalidates the ratify token"

# --- Gate B (analyze) + the abort/ratify fold-ins -----------------------------------------------------

echo "== intake analyze (Gate B): valid breakdown passes; analyze is strictly read-only =="
A_PROSE=$'## User Scenarios\n### US1 (P1) — Comments\nstory prose\n## Requirements\n- **FR-001:** System **MUST** persist a comment. _(US1)_\n- **FR-002:** System **MUST** reject an empty comment. _(US1)_\n## Success Criteria\n- **SC-001:** visible within 2 seconds.\n## Deferrals / Out of scope\n'"$LBC"
# AVALID carries the three machine fields (scope/dod_tests/sc_evidence) so it is
# valid against BOTH the pre-splice intake (invariants 1-6 ignore unknown keys) and the nine-invariant
# candidate/spliced intake. Legacy task blocks (no fields) are now a REJECTION fixture below.
AVALID='{"spec_version":"forge/v1","target_repos":["agentic-builder-forge"],"tasks":[{"id":"T001","title":"persist a comment","satisfies":["FR-001","US1"],"priority":"P1","depends_on":[],"target_repo":"agentic-builder-forge","definition_of_done":["a failing test passes"],"success_criteria":["SC-001"],"scope":["sandbox/comments/**"],"dod_tests":["tests/intake/run.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/comments/evidence/sc1.txt"}]},{"id":"T002","title":"reject empty comments","satisfies":["FR-002"],"priority":"P1","depends_on":["T001"],"target_repo":"agentic-builder-forge","definition_of_done":["a failing test passes"],"success_criteria":["100% rejected"],"scope":["sandbox/comments/reject/**"],"dod_tests":["tests/intake/run.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/comments/reject/evidence/rejection-rates.txt"}]}]}'
AD="$TMPROOT/analyze"
mkdir -p "$AD"
mk_aspec() { # <path> <tasks-json> [prose] — minimal spec: prose + sentinel-fenced task block
  local f="$1" tj="$2" prose="${3:-$A_PROSE}"
  {
    printf '%s\n\n' "$prose"
    printf '%s\n' '<!-- forge:tasks:begin v1 -->'
    printf '%s\n' '```json'
    printf '%s\n' "$tj"
    printf '%s\n' '```'
    printf '%s\n' '<!-- forge:tasks:end -->'
  } >"$f"
}
mk_aspec "$AD/ok.md" "$AVALID"
a_out="$(bash "$INTAKE" analyze "$AD/ok.md" 2>&1)" && ok || no "analyze: valid spec passes (got: $a_out)"
printf '%s' "$a_out" | grep -qF "Gate B PASS" && ok || no "analyze: PASS summary names Gate B (got: $a_out)"
sha_before="$(sha256sum "$AD/ok.md" | cut -d' ' -f1)"
ROHD="$(mktemp -d -p "$TMPROOT")"
FORGE_HARNESS_DIR="$ROHD" bash "$INTAKE" analyze "$AD/ok.md" >/dev/null 2>&1
sha_after="$(sha256sum "$AD/ok.md" | cut -d' ' -f1)"
[ "$sha_before" = "$sha_after" ] && ok || no "analyze: read-only — spec bytes unchanged"
[ -z "$(ls -A "$ROHD" 2>/dev/null)" ] && ok || no "analyze: read-only — writes NO .harness state (found: $(ls -A "$ROHD" 2>/dev/null))"

echo "== intake analyze (Gate B): rejections — fail-loud, offender NAMED in every message =="
arej() { # <name> <tasks-json | RAWSPEC:path> <must-name> — non-zero exit AND the offender named
  local name="$1" tj="$2" want="$3" f out rc
  if [ "${tj#RAWSPEC:}" != "$tj" ]; then
    f="${tj#RAWSPEC:}"
  else
    f="$AD/r$((PASS + FAIL)).md"
    mk_aspec "$f" "$tj"
  fi
  out="$(bash "$INTAKE" analyze "$f" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$want"; then ok; else no "analyze: $name (rc=$rc; wanted '$want'; got: $out)"; fi
}
arej "dangling satisfies FR" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].satisfies = ["FR-009"]')" "FR-009"
arej "dangling satisfies US" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].satisfies = ["FR-001","US9"]')" "US9"
arej "non-FR/US satisfies ref" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].satisfies = ["FR-001","SC-001"]')" "not an FR-NNN / USn reference"
arej "uncovered FR" "$(printf '%s' "$AVALID" | jq -c 'del(.tasks[1])')" "FR-002"
arej "missing required key" "$(printf '%s' "$AVALID" | jq -c 'del(.tasks[1].definition_of_done)')" "definition_of_done"
arej "bad id shape" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].id = "T1" | .tasks[1].depends_on = []')" "T1"
arej "duplicate id" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].id = "T001" | .tasks[1].depends_on = []')" "duplicate task id T001"
arej "bad priority" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].priority = "P9"')" "P9"
arej "dangling depends_on" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].depends_on = ["T999"]')" "T999"
arej "depends_on cycle" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].depends_on = ["T002"]')" "cycle"
arej "empty satisfies" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].satisfies = []')" "satisfies is empty"
arej "target_repo not member" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].target_repo = "other-repo"')" "other-repo"
arej "target_repos empty" "$(printf '%s' "$AVALID" | jq -c '.target_repos = []')" "target_repos is missing or empty"
arej "zero tasks" "$(printf '%s' "$AVALID" | jq -c '.tasks = []')" ".tasks is missing or empty"
BADJ="$AD/badjson.md"
mk_aspec "$BADJ" '{ this is not json'
arej "task block not JSON" "RAWSPEC:$BADJ" "not valid JSON"
NOBLK="$AD/noblock.md"
printf '%s\n' "$A_PROSE" >"$NOBLK"
arej "no task block" "RAWSPEC:$NOBLK" "no '<!-- forge:tasks:begin v1 -->'"
TWOBLK="$AD/twoblocks.md"
mk_aspec "$TWOBLK" "$AVALID"
cat "$TWOBLK" "$TWOBLK" >"$AD/twoblocks2.md"
arej "two task blocks" "RAWSPEC:$AD/twoblocks2.md" "exactly one"
NOFR="$AD/nofr.md"
mk_aspec "$NOFR" "$AVALID" $'## User Scenarios\n### US1 (P1) — x\n## Requirements\n(none authored)'
arej "no FR definitions in prose" "RAWSPEC:$NOFR" "no FR definitions"

# --- invariants 7/8/9 (scope, dod_tests, sc_evidence) -------------------------------------------------
# The deployed harness/intake.sh enforces inv 7/8/9 (the schema splice landed; the candidate was
# retired). Prove against $INTAKE (= ${FORGE_INTAKE:-deployed}): a spec whose tasks LACK the three
# fields MUST be rejected. If $INTAKE accepts it, that is an inv-7/8/9 regression — fail closed.
echo "== intake analyze (Gate B): invariants 7/8/9 — deployed must reject a fields-missing spec =="
PROBE9="$AD/probe9-fields-missing.md"
mk_aspec "$PROBE9" "$(printf '%s' "$AVALID" | jq -c '.tasks[] |= del(.scope, .dod_tests, .sc_evidence)')"
INTAKE9=""
if bash "$INTAKE" analyze "$PROBE9" >/dev/null 2>&1; then
  no "invariants 7/8/9: \$INTAKE accepts a fields-missing spec — the deployed harness must REJECT it (regression); fail closed"
else
  INTAKE9="$INTAKE"
  ok # deployed harness enforces inv 7/8/9 (rejects a spec missing scope/dod_tests/sc_evidence)
fi

if [ -n "$INTAKE9" ]; then
  arej9() { # <name> <tasks-json | RAWSPEC:path> <must-name> — non-zero exit AND the offender named, vs $INTAKE9
    local name="$1" tj="$2" want="$3" f out rc
    if [ "${tj#RAWSPEC:}" != "$tj" ]; then
      f="${tj#RAWSPEC:}"
    else
      f="$AD/c$((PASS + FAIL)).md"
      mk_aspec "$f" "$tj"
    fi
    out="$(bash "$INTAKE9" analyze "$f" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$want"; then ok; else no "schema: $name (rc=$rc; wanted '$want'; got: $out)"; fi
  }

  echo "== schema: pass fixtures — well-formed scope/dod_tests/sc_evidence accepted =="
  a9_out="$(bash "$INTAKE9" analyze "$AD/ok.md" 2>&1)" && ok || no "schema: AVALID (fields present) passes (got: $a9_out)"
  printf '%s' "$a9_out" | grep -qF "all nine hold" && ok || no "schema: PASS summary reports all nine invariants (got: $a9_out)"
  RICH9="$(printf '%s' "$AVALID" | jq -c '
    .tasks[0].scope = ["sandbox/x/**", "tests/intake/*.sh", "docs/file[0-9].md"]
    | .tasks[0].dod_tests = ["tests/intake/run.sh", "sandbox/x/t.sh", "tests/a/b_1.sh"]
    | .tasks[0].sc_evidence = [{"sc":1,"path":"sandbox/x/evidence/sc1.txt"},{"sc":1,"path":"sandbox/x/evidence/sc1b.txt"}]')"
  mk_aspec "$AD/rich9.md" "$RICH9"
  r9_out="$(bash "$INTAKE9" analyze "$AD/rich9.md" 2>&1)" && ok || no "schema: rich fixture (glob chars, whole-file selectors, multi-evidence per SC) passes (got: $r9_out)"

  echo "== schema: invariant 7 (scope) rejections — offender NAMED =="
  # THE BREAKING-CHANGE FIXTURE: a legacy task block (no scope/dod_tests/sc_evidence) is now
  # REJECTED — intended, fail-closed; the schema is load-bearing for Gate A' and the mechanical gate.
  arej9 "fields-missing spec rejected (legacy fieldless blocks now fail)" "RAWSPEC:$PROBE9" "scope is missing or empty"
  arej9 "scope empty array" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].scope = []')" "task T001: scope is missing or empty"
  arej9 "scope absolute path" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].scope = ["/etc/passwd"]')" 'scope entry "/etc/passwd"'
  arej9 "scope .. traversal" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].scope = ["sandbox/../harness/**"]')" 'scope entry "sandbox/../harness/**"'
  arej9 "scope *..* traversal (the glob-traversal class)" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].scope = ["sandbox/a*..*b/**"]')" 'scope entry "sandbox/a*..*b/**"'
  arej9 "scope empty-string entry" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].scope = ["sandbox/**", ""]')" 'scope entry ""'
  arej9 "scope whitespace entry" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].scope = ["sandbox/a b/**"]')" 'scope entry "sandbox/a b/**"'
  arej9 "scope brace expansion (not POSIX matching)" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].scope = ["docs/x-{a,b}/**"]')" 'scope entry "docs/x-{a,b}/**"'

  echo "== schema: invariant 8 (dod_tests) rejections — offender NAMED =="
  arej9 "dod_tests empty array" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].dod_tests = []')" "task T001: dod_tests is missing or empty"
  arej9 "dod_tests non-selector format" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].dod_tests = ["make test"]')" 'dod_tests entry "make test"'
  arej9 "dod_tests .. traversal" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].dod_tests = ["tests/../../etc/x.sh"]')" 'dod_tests entry "tests/../../etc/x.sh"'
  arej9 "dod_tests absolute path" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].dod_tests = ["/tests/x.sh"]')" 'dod_tests entry "/tests/x.sh"'
  arej9 "dod_tests empty ::pattern" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].dod_tests = ["tests/intake/run.sh::"]')" 'dod_tests entry "tests/intake/run.sh::"'
  # A2: the ::pattern selector form is REJECTED at Gate B (the reserved form guarded a convention
  # R-A calls undefined; the gate C2 never ran them — analyze is now the strict single source of truth).
  arej9 "dod_tests ::pattern rejected (A2: reserved form removed; gate never ran them)" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].dod_tests = ["tests/intake/run.sh::case 7"]')" 'dod_tests entry "tests/intake/run.sh::case 7"'
  arej9 "dod_tests bare top dir" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].dod_tests = ["tests"]')" 'dod_tests entry "tests" is not a valid selector'

  echo "== schema: 7-9 precondition — non-object tasks[] element rejected, offender named =="
  # Without this guard every 7-9 jq chain errors on the element (has() on a string), empties $bad and
  # fails open; the verdict then hangs on the traceability stage's own jq error (wrong offender named).
  arej9 "non-object tasks[] element" "$(printf '%s' "$AVALID" | jq -c '.tasks += ["x"]')" "task #2 is not an object"

  echo "== schema: invariant 9 (sc_evidence) rejections — offender NAMED, bidirectional =="
  arej9 "sc_evidence empty array" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].sc_evidence = []')" "task T001: sc_evidence is missing or empty"
  arej9 "sc_evidence dangling index" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].sc_evidence = [{"sc":5,"path":"sandbox/x.txt"}]')" "sc_evidence sc 5 resolves to no success_criteria index"
  arej9 "sc_evidence zero index (1-based)" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].sc_evidence = [{"sc":0,"path":"sandbox/x.txt"}]')" "sc_evidence sc 0 resolves to no success_criteria index"
  arej9 "sc_evidence uncovered SC" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].success_criteria = ["100% rejected","SC-001"]')" "task T002: success_criteria #2 has no sc_evidence entry"
  arej9 "sc_evidence path .. traversal" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].sc_evidence = [{"sc":1,"path":"sandbox/../x.txt"}]')" 'sc_evidence path "sandbox/../x.txt"'
  arej9 "sc_evidence absolute path" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].sc_evidence = [{"sc":1,"path":"/tmp/x.txt"}]')" 'sc_evidence path "/tmp/x.txt"'
  arej9 "sc_evidence non-integer sc" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].sc_evidence = [{"sc":1.5,"path":"sandbox/x.txt"}]')" "sc_evidence sc 1.5 is not an integer"
  arej9 "sc_evidence non-object entry" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].sc_evidence = ["sandbox/x.txt"]')" "is not a {sc, path} object"
  # A3: an sc_evidence path must fall under >=1 scope glob (else unsatisfiable at the gate — C3
  # stages it, C1 rejects it as out-of-scope). Same bash case-pattern the gate's C1 uses. (T001 scope
  # is sandbox/comments/**, so docs/out-of-scope.txt matches no glob.)
  arej9 "sc_evidence out of scope (A3)" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].sc_evidence = [{"sc":1,"path":"docs/out-of-scope.txt"}]')" 'sc_evidence path "docs/out-of-scope.txt" is matched by no scope glob'
  # success_criteria type guard: jq length on a scalar is its magnitude (vacuous coverage) and on a
  # boolean it ERRORS (fail-open class) — both must be NAMED rejections, never a nine-hold PASS.
  arej9 "success_criteria boolean (jq-length error, fail-open class)" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].success_criteria = true')" "task T001: success_criteria is not an array"
  arej9 "success_criteria scalar 1 (vacuous bidirectional coverage)" "$(printf '%s' "$AVALID" | jq -c '.tasks[0].success_criteria = 1')" "task T001: success_criteria is not an array"
fi

echo "== intake analyze (Gate B): spec resolution — explicit arg vs sentinel; fail-closed =="
NOS="$(mktemp -d -p "$TMPROOT")"
if FORGE_HARNESS_DIR="$NOS" bash "$INTAKE" analyze >/dev/null 2>&1; then no "analyze without arg or sentinel should fail closed"; else ok; fi
SHD="$(mktemp -d -p "$TMPROOT")"
jq -nc --arg s "$AD/ok.md" '{spec:$s,mode:"interactive",phase:"ratified"}' >"$SHD/active-intake.json"
FORGE_HARNESS_DIR="$SHD" bash "$INTAKE" analyze >/dev/null 2>&1 && ok || no "analyze resolves the spec from the active sentinel"

echo "== intake abort: clears ALL intake state — fold-in 1 (token + closed-by-construction glob) =="
FHD="$(gsetup)"
ratify_human "$FHD" >/dev/null 2>&1
[ -f "$FHD/intake-ratified.json" ] && ok || no "(precondition) ratify minted the token"
printf '3' >"$FHD/intake-clarify-rounds"
printf '1' >"$FHD/intake-clarify-grant"
printf '2' >"$FHD/intake-stop-blocks"
printf 'x' >"$FHD/intake-future-counter" # a state file abort has never heard of — the glob must catch it
FORGE_HARNESS_DIR="$FHD" bash "$INTAKE" abort >/dev/null 2>&1 && ok || no "abort exits 0"
[ ! -f "$FHD/active-intake.json" ] && ok || no "abort removes the sentinel"
left="$(find "$FHD" -maxdepth 1 -name 'intake-*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = "0" ] && ok || no "abort clears ALL intake-* state incl. the ratify token + future files (left: $left)"
[ -f "$FHD/s/spec.md" ] && ok || no "abort leaves the spec in place"

echo "== intake ratify: full Gate-A floor — fold-in 2 (reviewer-loop evidence; visibility, not a veto) =="
# These floor-refusals run UNDER the PTY (ratify_human) so the TTY gate passes and they exercise the FLOOR
# logic — the TTY gate is tested separately below, not by accidentally short-circuiting these.
RNO="$(gsetup NONE)"
r_out="$(ratify_human "$RNO")"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$r_out" | grep -qF "restatement.md not found"; then ok; else no "ratify refuses without restatement.md (rc=$rc; got: $r_out)"; fi
RZR="$(gsetup $'# Restatement\n## Open findings\n## History\n(transcribed, but no round markers)')"
r_out="$(ratify_human "$RZR")"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$r_out" | grep -qF "no '### Restatement round N'"; then ok; else no "ratify refuses zero restatement rounds (rc=$rc; got: $r_out)"; fi
RST_OPEN1=$'# Restatement\n## Open findings\n- [ESCALATE] FR-007 — upstream-failure handling uncovered\n## History\n### Restatement round 1\nreviewer flagged it'
ROPEN="$(gsetup "$RST_OPEN1")"
r_out="$(ratify_human "$ROPEN")"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$r_out" | grep -qF "UNRECONCILED"; then ok; else no "ratify refuses open findings with no ## UNRECONCILED (rc=$rc; got: $r_out)"; fi
U_UNREC="$U_BODY"$'\n## UNRECONCILED — human input needed\n- FR-007 failure path: reviewer and Architect did not converge; the human decides.'
RUNREC="$(gsetup "$RST_OPEN1" "$U_UNREC")"
ratify_human "$RUNREC" >/dev/null 2>&1 && ok || no "ratify ALLOWS open findings once ## UNRECONCILED surfaces them (the human adjudicates — no reviewer veto)"
[ -f "$RUNREC/intake-ratified.json" ] && ok || no "...and mints the token on that path"

echo "== intake ratify: refuses without a TTY (the agent's non-TTY Bash cannot self-ratify) =="
# THE bare (non-PTY) ratify call: stdin/stdout are pipes here (exactly the agent's Bash tool), so the
# [ -t 0 ] && [ -t 1 ] gate must refuse BEFORE any floor work. Differential: against the pre-splice
# intake.sh (no gate) this SUCCEEDS (the bug); against the candidate it refuses. The wrapper-file vector
# (bash wrapper.sh) reduces to exactly this — ratify reached with no TTY — so this fixture is its closure.
GNT="$(gsetup)"
nt_out="$(FORGE_HARNESS_DIR="$GNT" bash "$INTAKE" ratify 2>&1 </dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$nt_out" | grep -qF "interactive terminal"; then ok; else no "ratify refuses without a TTY (rc=$rc; got: $nt_out)"; fi
[ ! -f "$GNT/intake-ratified.json" ] && ok || no "no-TTY ratify mints NO token (the self-ratify path is closed)"

echo "== intake ratify: a wrapper file holding the ratify call ALSO refuses under non-TTY =="
# End-to-end COMPOSITION proof (not redundant with the two halves): the deny hook provably cannot catch
# `bash wrapper.sh` (see the hooks-suite allow-at-hook fixture), and ratify-non-TTY refuses (above) — this
# proves they COMPOSE: a wrapper the agent could write under specs/ reaches cmd_ratify with no TTY and is
# refused, no token. (PTY + this wrapper together remain the OS-confinement residual, tracked pre-3.3.)
GWRAP="$(gsetup)"
printf '#!/usr/bin/env bash\nexec bash %s ratify\n' "$INTAKE" >"$GWRAP/s/wrapper.sh"
w_out="$(FORGE_HARNESS_DIR="$GWRAP" bash "$GWRAP/s/wrapper.sh" 2>&1 </dev/null)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$w_out" | grep -qF "interactive terminal" && [ ! -f "$GWRAP/intake-ratified.json" ]; then ok; else no "wrapper.sh holding ratify refuses under non-TTY + mints no token (rc=$rc; got: $w_out)"; fi

# --- the converter — THROWAWAY LEDGER ONLY ------------------------------------------------------------
# HARD GUARD: the real .beads/issues.jsonl must be BYTE-UNCHANGED across the ENTIRE convert section.
# This is a suite-FAILING assertion, not an observation — if it ever trips, a convert test touched the
# real ledger, which is unrecoverable. Captured as the file's sha if present, else the literal ABSENT
# (a fresh clone has no untracked ledger) — clone-portable AND strictly stronger: a present ledger must
# be byte-identical after the run, and an absent one must STAY absent (a convert that minted into a real
# ledger would flip ABSENT->sha and trip the guard).
echo "== intake convert: throwaway-ledger guard armed =="
REAL_LEDGER="$ROOT/.beads/issues.jsonl"
ledger_state() { if [ -f "$REAL_LEDGER" ]; then sha256sum "$REAL_LEDGER" | cut -d' ' -f1; else printf 'ABSENT'; fi; }
BEADS_STATE_BEFORE="$(ledger_state)"
[ -n "$BEADS_STATE_BEFORE" ] && ok || no "(guard armed) captured the real-ledger state ($BEADS_STATE_BEFORE)"

# csetup <ledger-dir> <harness-dir> [tasks-json] — build a throwaway repo with its OWN bd ledger, a
# minimal enforcement floor (for the fx-v0w preflight), a ratifiable spec (prose + Gate-A artifacts +
# task block), and a RATIFIED sentinel. convert is then run with cwd=<ledger-dir>, so bd discovers the
# throwaway ledger and intake.sh's ROOT (git-common-dir of cwd) is the throwaway repo.
cfloor() { # <repo> — scaffold the minimal enforcement floor the preflight asserts
  mkdir -p "$1/.claude/hooks"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$1/.claude/hooks/pre-tool-use-deny.sh"
  chmod +x "$1/.claude/hooks/pre-tool-use-deny.sh"
  printf '# stub lib\n' >"$1/.claude/hooks/lib.sh"
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"pre-tool-use-deny.sh"}]}]}}\n' >"$1/.claude/settings.json"
}
cspec() { # <dir> <tasks-json> — spec.md (prose+block) + understanding.md + restatement.md
  mk_aspec "$1/spec.md" "$2"
  printf '%s' "$U_BODY" >"$1/understanding.md"
  printf '%s' "$RST_CONSENSUS" >"$1/restatement.md"
}
csent() { # <harness-dir> <spec-path> — sentinel(open); ratify flips it with the real command
  jq -nc --arg s "$2" '{spec:$s,mode:"interactive",phase:"open",clarify_rounds:5,restate_rounds:3,clarify_max_q:4}' >"$1/active-intake.json"
  # Stage E: cspec writes a CONSENSUS restatement (RST_CONSENSUS, 0 open), so stage the matching consensus
  # spec-review record (AGREE) bound to the spec sha — cmd_ratify requires the record (C7), verifies its
  # spec_sha256 == the current spec (anti-TOCTOU), and reads its open-count.
  jq -nc --arg ssha "$(sha256sum "$2" | cut -d' ' -f1)" '{verdict:"AGREE",spec_sha256:$ssha,findings:[]}' >"$1/intake-spec-review.json"
}

echo "== intake convert: refuses when Gate B (analyze) fails — convert->analyze ordering =="
CL1="$(mktemp -d -p "$TMPROOT")"
(cd "$CL1" && git init -q .)
cfloor "$CL1"
mkdir -p "$CL1/s"
cspec "$CL1/s" "$(printf '%s' "$AVALID" | jq -c '.tasks[1].satisfies = ["FR-009"]')"
CH1="$(mktemp -d -p "$TMPROOT")"
csent "$CH1" "$CL1/s/spec.md"
gate_a_full "$CH1" || no "(precondition) ratify succeeds on the dangling-satisfies spec (Gate B is convert's job)"
cv_out="$(cd "$CL1" && FORGE_HARNESS_DIR="$CH1" bash "$INTAKE" convert 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$cv_out" | grep -qF "FR-009"; then ok; else no "convert refuses on Gate-B failure, naming the offender (rc=$rc; got: $cv_out)"; fi

echo "== intake convert: fx-v0w preflight — refuses to mint without the enforcement floor =="
CL2="$(mktemp -d -p "$TMPROOT")"
(cd "$CL2" && git init -q .) # NO cfloor: the deny hook is absent
mkdir -p "$CL2/s"
cspec "$CL2/s" "$AVALID"
CH2="$(mktemp -d -p "$TMPROOT")"
csent "$CH2" "$CL2/s/spec.md"
gate_a_full "$CH2"
cv_out="$(cd "$CL2" && FORGE_HARNESS_DIR="$CH2" bash "$INTAKE" convert 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$cv_out" | grep -qF "fx-v0w"; then ok; else no "convert preflight refuses without the floor (rc=$rc; got: $cv_out)"; fi

echo "== intake convert: FULL MINT into the throwaway ledger (topo, crosswalk, edges, fields) =="
CL3="$(mktemp -d -p "$TMPROOT")"
(cd "$CL3" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix tst >/dev/null 2>&1)
cfloor "$CL3"
mkdir -p "$CL3/s"
cspec "$CL3/s" "$AVALID"
CH3="$(mktemp -d -p "$TMPROOT")"
csent "$CH3" "$CL3/s/spec.md"
gate_a_full "$CH3"
cv_out="$(cd "$CL3" && FORGE_HARNESS_DIR="$CH3" bash "$INTAKE" convert 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok || no "convert exits 0 on the valid ratified spec (got rc=$rc: $cv_out)"
XW="$CL3/s/crosswalk.json"
[ -f "$XW" ] && ok || no "crosswalk.json written under the spec dir"
X1="$(jq -r '.T001 // empty' "$XW" 2>/dev/null)"
X2="$(jq -r '.T002 // empty' "$XW" 2>/dev/null)"
{ [ -n "$X1" ] && [ -n "$X2" ] && [ "$X1" != "$X2" ]; } && ok || no "crosswalk maps T001 and T002 to distinct minted ids (got: $X1 / $X2)"
nbeads="$(cd "$CL3" && bd list --json 2>/dev/null | jq 'length')"
[ "$nbeads" = "2" ] && ok || no "exactly 2 beads minted in the throwaway ledger (got: $nbeads)"
B1="$(cd "$CL3" && bd show "$X1" --json 2>/dev/null | jq '.[0]')"
B2="$(cd "$CL3" && bd show "$X2" --json 2>/dev/null | jq '.[0]')"
[ "$(printf '%s' "$B1" | jq -r '.title')" = "persist a comment" ] && ok || no "T001 title carried to the bead"
[ "$(printf '%s' "$B1" | jq -r '.priority')" = "1" ] && ok || no "P1 -> numeric priority 1 (got: $(printf '%s' "$B1" | jq -r '.priority'))"
printf '%s' "$B1" | jq -r '.acceptance_criteria' | grep -qF "a failing test passes" && ok || no "DoD landed in .acceptance_criteria (bd --acceptance reconciled against the real binary)"
[ "$(printf '%s' "$B1" | jq -r '.metadata.target_repo')" = "agentic-builder-forge" ] && ok || no "target_repo landed in .metadata (NOT --repo)"
printf '%s' "$B1" | jq -r '.description' | grep -qF "Satisfies: FR-001, US1" && ok || no "satisfies serialized into the bead body"
(cd "$CL3" && bd dep list "$X2" 2>/dev/null) | grep -qF "$X1" && ok || no "blocks edge: T002's bead depends on T001's bead via the crosswalk"
[ ! -f "$CH3/active-intake.json" ] && ok || no "convert clears the intake sentinel on success"
[ "$(find "$CH3" -maxdepth 1 -name 'intake-*' | wc -l | tr -d ' ')" = "0" ] && ok || no "convert clears ALL intake-* state on success"
cv2="$(cd "$CL3" && FORGE_HARNESS_DIR="$CH3" bash "$INTAKE" convert 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$cv2" | grep -qF "no active intake"; then ok; else no "re-convert refuses after the sentinel is cleared (got: $cv2)"; fi

echo "== intake convert: spec content is DATA; injection payload mints INERT =="
# The payload carries command-substitution, backticks, a pipe and a redirect. If the converter ever
# interpolated spec content into a shell, the marker file would exist and/or the mint would mangle.
PWN="$TMPROOT/cp5-pwned-marker"
INJ_TITLE='persist $(touch '"$PWN"') `touch '"$PWN"'` ; cat /etc/passwd | tee pwn > pwn2'
INJ="$(printf '%s' "$AVALID" | jq -c --arg t "$INJ_TITLE" '.tasks[0].title = $t | .tasks[0].definition_of_done = [$t]')"
CL4="$CL3" # reuse the throwaway ledger (a second intake into the same bd store)
mkdir -p "$CL4/s2"
cspec "$CL4/s2" "$INJ"
CH4="$(mktemp -d -p "$TMPROOT")"
csent "$CH4" "$CL4/s2/spec.md"
gate_a_full "$CH4"
(cd "$CL4" && FORGE_HARNESS_DIR="$CH4" bash "$INTAKE" convert >/dev/null 2>&1) && ok || no "convert exits 0 on the injection spec (payload is just data)"
[ ! -f "$PWN" ] && ok || no "spec-as-data: NO side-effect file — the payload never executed"
XI="$(jq -r '.T001 // empty' "$CL4/s2/crosswalk.json" 2>/dev/null)"
BI="$(cd "$CL4" && bd show "$XI" --json 2>/dev/null | jq '.[0]')"
printf '%s' "$BI" | jq -r '.title' | grep -qF 'persist $(touch' && ok || no "spec-as-data: the bead title carries the payload as LITERAL text"
printf '%s' "$BI" | jq -r '.acceptance_criteria' | grep -qF '`touch' && ok || no "spec-as-data: acceptance carries the backtick payload as LITERAL text"

echo "== intake convert: the FR-definition-line binding (fr_sha256) closes the FR-swap hole =="
# Inserted INSIDE the throwaway-ledger guard window (before the verdict), so these convert calls are
# covered by the real-ledger byte-unchanged assertion. Reuses cfloor/cspec/csent/ratify_human/AVALID.

# (1) ratify binds BOTH hashes.
CB="$(mktemp -d -p "$TMPROOT")"; (cd "$CB" && git init -q .); cfloor "$CB"; mkdir -p "$CB/s"
cspec "$CB/s" "$AVALID"; CBH="$(mktemp -d -p "$TMPROOT")"; csent "$CBH" "$CB/s/spec.md"
ratify_human "$CBH" >/dev/null 2>&1
{ [ -n "$(jq -r '.sha256 // empty' "$CBH/intake-ratified.json" 2>/dev/null)" ] && \
  [ -n "$(jq -r '.fr_sha256 // empty' "$CBH/intake-ratified.json" 2>/dev/null)" ]; } && ok || \
  no "fr-binding: ratify binds BOTH understanding.md sha256 AND the FR-line fr_sha256"

# (2) convert REFUSES on FR-line drift even when understanding.md is byte-identical — the exact FR-swap
#     hole. bd init so a pre-binding binary demonstrably MINTS the unratified FR content (red there).
CD="$(mktemp -d -p "$TMPROOT")"; (cd "$CD" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix tdr >/dev/null 2>&1); cfloor "$CD"; mkdir -p "$CD/s"
cspec "$CD/s" "$AVALID"; CDH="$(mktemp -d -p "$TMPROOT")"; csent "$CDH" "$CD/s/spec.md"
und_before="$(sha256sum "$CD/s/understanding.md" | cut -d' ' -f1)"
ratify_human "$CDH" >/dev/null 2>&1
# Edit an FR-definition line's PROSE only; FR ids + structure are unchanged, so analyze still passes —
# the ONLY thing that can catch this is the FR-line hash.
sed -i 's/persist a comment\./persist a comment within 24h./' "$CD/s/spec.md"
und_after="$(sha256sum "$CD/s/understanding.md" | cut -d' ' -f1)"
[ "$und_before" = "$und_after" ] && ok || no "fr-binding (precondition): the FR-line edit left understanding.md byte-identical"
cv="$(cd "$CD" && FORGE_HARNESS_DIR="$CDH" bash "$INTAKE" convert 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$cv" | grep -qF "FR-definition lines changed"; then ok; else \
  no "fr-binding: convert REFUSES post-ratify FR-line drift with understanding.md byte-identical (rc=$rc; got: $cv)"; fi

# (3) convert SUCCEEDS when neither drifted — no false positive (the legitimate path stays open).
CN="$(mktemp -d -p "$TMPROOT")"; (cd "$CN" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix tnf >/dev/null 2>&1); cfloor "$CN"; mkdir -p "$CN/s"
cspec "$CN/s" "$AVALID"; CNH="$(mktemp -d -p "$TMPROOT")"; csent "$CNH" "$CN/s/spec.md"
gate_a_full "$CNH"
cv="$(cd "$CN" && FORGE_HARNESS_DIR="$CNH" bash "$INTAKE" convert 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || no "fr-binding: convert SUCCEEDS when neither understanding.md nor FR lines drifted (no false positive) (rc=$rc; got: $cv)"

# (4) convert REFUSES a "pre-cp-2 token" (the harness's name for a token with no fr_sha256) — fail-closed
#     on the schema gap. bd init so a pre-binding binary demonstrably mints with the old token (red there).
CO="$(mktemp -d -p "$TMPROOT")"; (cd "$CO" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix tol >/dev/null 2>&1); cfloor "$CO"; mkdir -p "$CO/s"
cspec "$CO/s" "$AVALID"; COH="$(mktemp -d -p "$TMPROOT")"; csent "$COH" "$CO/s/spec.md"
ratify_human "$COH" >/dev/null 2>&1
jq 'del(.fr_sha256)' "$COH/intake-ratified.json" >"$COH/.tok" && mv "$COH/.tok" "$COH/intake-ratified.json"
cv="$(cd "$CO" && FORGE_HARNESS_DIR="$COH" bash "$INTAKE" convert 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$cv" | grep -qF "pre-cp-2 token"; then ok; else \
  no "fr-binding: convert REFUSES a pre-cp-2 token with no fr_sha256 (fail-closed) (rc=$rc; got: $cv)"; fi

echo "== intake convert: convert hardening — idempotency, version-pin, explicit edge type =="
# Inside the throwaway-ledger guard window (covered by the real-ledger byte-unchanged assertion).
# Reuses cfloor/cspec/csent/ratify_human/AVALID. bd shims live under $TMPROOT (trap-cleaned).

# ── concern 1a: re-run after a PARTIAL mint failure — no duplicate, all tasks present ─────────────────
CI="$(mktemp -d -p "$TMPROOT")"; (cd "$CI" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix tid >/dev/null 2>&1); cfloor "$CI"; mkdir -p "$CI/s"
cspec "$CI/s" "$AVALID"; CIH="$(mktemp -d -p "$TMPROOT")"; csent "$CIH" "$CI/s/spec.md"
gate_a_full "$CIH"
realbd="$(command -v bd)"; shim="$(mktemp -d -p "$TMPROOT")"
cat >"$shim/bd" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "create" ]; then case " \$* " in *"reject empty comments"*) echo "simulated bd create failure (T002)" >&2; exit 1 ;; esac; fi
exec "$realbd" "\$@"
SHIM
chmod +x "$shim/bd"
(cd "$CI" && PATH="$shim:$PATH" FORGE_HARNESS_DIR="$CIH" bash "$INTAKE" convert >/dev/null 2>&1) || true   # run1: T001 minted, T002 fails, dies
(cd "$CI" && FORGE_HARNESS_DIR="$CIH" bash "$INTAKE" convert >/dev/null 2>&1) || true                      # run2: real bd — completes the remainder
ni="$(cd "$CI" && bd list --json 2>/dev/null | jq 'length')"
[ "$ni" = "2" ] && ok || no "hardening(1a): re-run after a partial mint yields EXACTLY 2 beads — no duplicate, no orphan (got $ni)"

# ── concern 1b: crash BETWEEN bd create and the crosswalk write — marker reconciliation, no duplicate ──
CG="$(mktemp -d -p "$TMPROOT")"; (cd "$CG" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix tgp >/dev/null 2>&1); cfloor "$CG"; mkdir -p "$CG/s"
cspec "$CG/s" "$AVALID"; CGH="$(mktemp -d -p "$TMPROOT")"; csent "$CGH" "$CG/s/spec.md"
gate_a_full "$CGH"
gspec="$CG/s/spec.md"
# A1: convert now mints metadata.source_spec REPO-RELATIVE (${spec#$ROOT/}); a real
# post-A1 partial run's beads carry the relative form, and the reconcile key (intake.sh:627) matches on it.
# Model that here with the relative path — an ABSOLUTE-source_spec pre-mint would model a PRE-A1 bead, which
# post-A1 convert correctly does NOT adopt (it would re-mint). ROOT==$CG when convert runs with cwd=$CG.
gspec_rel="${gspec#"$CG"/}"
# simulate a prior run that minted BOTH beads but never wrote the crosswalk / cleared the sentinel
# F5: a partial run's beads carry source_spec+task_id metadata; the reconciliation is
# metadata-based, so the pre-mint here models that (a legacy description-only bead would NOT reconcile).
(cd "$CG" && printf 'x\nSource: %s (T001)\n' "$gspec_rel" | bd create "persist a comment" --body-file - --metadata "{\"source_spec\":\"$gspec_rel\",\"task_id\":\"T001\"}" >/dev/null 2>&1)
(cd "$CG" && printf 'x\nSource: %s (T002)\n' "$gspec_rel" | bd create "reject empty comments" --body-file - --metadata "{\"source_spec\":\"$gspec_rel\",\"task_id\":\"T002\"}" >/dev/null 2>&1)
cv="$(cd "$CG" && FORGE_HARNESS_DIR="$CGH" bash "$INTAKE" convert 2>&1)"
ng="$(cd "$CG" && bd list --json 2>/dev/null | jq 'length')"
[ "$ng" = "2" ] && ok || no "hardening(1b): convert RECONCILES pre-minted beads via the Source marker (crash gap) — no duplicate (got $ng)"

# ── concern 2: convert refuses when bd version != BD_VERSION_PIN, minting nothing ─────────────────────
CV="$(mktemp -d -p "$TMPROOT")"; (cd "$CV" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix tvp >/dev/null 2>&1); cfloor "$CV"; mkdir -p "$CV/s"
cspec "$CV/s" "$AVALID"; CVH="$(mktemp -d -p "$TMPROOT")"; csent "$CVH" "$CV/s/spec.md"
gate_a_full "$CVH"
cv="$(cd "$CV" && BD_VERSION_PIN=9.9.9 FORGE_HARNESS_DIR="$CVH" bash "$INTAKE" convert 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$cv" | grep -qF "!= pinned 9.9.9"; then ok; else no "hardening(2): convert REFUSES when bd version != BD_VERSION_PIN (rc=$rc; got: $cv)"; fi
[ "$(cd "$CV" && bd list --json 2>/dev/null | jq 'length')" = "0" ] && ok || no "hardening(2): the version-pin refusal mints NOTHING"

# ── concern 3: explicit --type blocks survives a bd whose dep-add DEFAULT drifted to non-blocks ───────
CE="$(mktemp -d -p "$TMPROOT")"; (cd "$CE" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix tet >/dev/null 2>&1); cfloor "$CE"; mkdir -p "$CE/s"
cspec "$CE/s" "$AVALID"; CEH="$(mktemp -d -p "$TMPROOT")"; csent "$CEH" "$CE/s/spec.md"
gate_a_full "$CEH"
realbd="$(command -v bd)"; eshim="$(mktemp -d -p "$TMPROOT")"
cat >"$eshim/bd" <<SHIM
#!/usr/bin/env bash
# simulate the probed hazard: a future bd whose dep-add default is non-blocks. Inject --type related when
# 'dep add' is called WITHOUT an explicit type; pass everything else through to the real bd.
if [ "\$1" = "dep" ] && [ "\$2" = "add" ]; then
  case " \$* " in *" --type "*|*" -t "*) : ;; *) shift 2; exec "$realbd" dep add --type related "\$@" ;; esac
fi
exec "$realbd" "\$@"
SHIM
chmod +x "$eshim/bd"
(cd "$CE" && PATH="$eshim:$PATH" FORGE_HARNESS_DIR="$CEH" bash "$INTAKE" convert >/dev/null 2>&1)
xt2="$(jq -r '.T002 // empty' "$CE/s/crosswalk.json" 2>/dev/null)"
etype="$(cd "$CE" && bd dep list "$xt2" --json 2>/dev/null | jq -r '.[0].dependency_type // empty')"
[ "$etype" = "blocks" ] && ok || no "hardening(3): explicit --type blocks survives a drifted bd dep-add default (got edge type: ${etype:-none})"

echo "== intake convert: F2 edge-idempotency + F5 injection-proof reconciliation =="

# F2: the convert edges loop relies on bd dep add being idempotent on a duplicate same-type edge
# (PROBE-3: rc 0). Pin the relied-on contract: re-adding the same blocks edge is a no-op, edge stays single.
F2D="$(mktemp -d -p "$TMPROOT")"; (cd "$F2D" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix f2 >/dev/null 2>&1)
f2a="$(cd "$F2D" && bd create A --silent 2>/dev/null | tr -d '[:space:]')"; f2b="$(cd "$F2D" && bd create B --silent 2>/dev/null | tr -d '[:space:]')"
(cd "$F2D" && bd dep add --type blocks "$f2b" "$f2a" >/dev/null 2>&1); f2r1=$?
(cd "$F2D" && bd dep add --type blocks "$f2b" "$f2a" >/dev/null 2>&1); f2r2=$?   # the re-run's duplicate add
{ [ "$f2r1" = 0 ] && [ "$f2r2" = 0 ]; } && ok || no "F2: convert edge re-add idempotent (dup blocks edge rc 0, no wedge) (r1=$f2r1 r2=$f2r2)"
[ "$(cd "$F2D" && bd dep list "$f2b" --json 2>/dev/null | jq 'length')" = "1" ] && ok || no "F2: the re-added edge stays single (no duplicate edge)"

# F5: reconciliation matches STRUCTURED metadata (source_spec+task_id), NOT a .description
# substring — a bead body embedding ANOTHER spec's "Source: <spec> (<tid>)" marker is NOT mis-adopted.
F5L="$(mktemp -d)"; F5C="$(mktemp -d -p "$TMPROOT")"
(cd "$F5C" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix f5 >/dev/null 2>&1); cfloor "$F5C"; mkdir -p "$F5C/s"
cspec "$F5C/s" "$AVALID"; F5H="$(mktemp -d -p "$TMPROOT")"; csent "$F5H" "$F5C/s/spec.md"
gate_a_full "$F5H"
f5spec="$F5C/s/spec.md"
# the INJECTION: a malicious bead whose BODY carries the victim spec's exact marker line, but whose
# metadata.source_spec is a DIFFERENT spec (bd-set, not from the body). With metadata-only matching, it
# must NOT be adopted when converting the victim spec — convert mints fresh.
(cd "$F5C" && printf 'pwn\nSource: %s (T001)\n' "$f5spec" | bd create "injected" --body-file - --metadata '{"source_spec":"/evil/other.md","task_id":"T001"}' >/dev/null 2>&1)
cv="$(cd "$F5C" && FORGE_HARNESS_DIR="$F5H" bash "$INTAKE" convert 2>&1)"; cvrc=$?
[ "$cvrc" -eq 0 ] && ok || no "F5: convert succeeds on the victim spec (got rc=$cvrc: $cv)"
t1="$(jq -r '.T001 // empty' "$F5C/s/crosswalk.json" 2>/dev/null)"
inj="$(cd "$F5C" && bd list --json 2>/dev/null | jq -r '.[] | select(.title=="injected") | .id')"
{ [ -n "$t1" ] && [ "$t1" != "$inj" ]; } && ok || no "F5: T001 minted FRESH ($t1), NOT mis-adopted as the injected bead ($inj)"
ntotal="$(cd "$F5C" && bd list --json 2>/dev/null | jq 'length')"
[ "$ntotal" = "3" ] && ok || no "F5: exactly 3 beads (injected + T001 + T002 minted fresh) — injection not adopted (got $ntotal)"
rm -rf "$F5L" 2>/dev/null

echo "== Gate A′ breakdown-ratify — token binds the Task Breakdown; convert anti-TOCTOU + fail-closed =="

# (1) Happy path: ratify-breakdown (after spec-ratify) writes a token binding the Task Breakdown block;
#     convert SUCCEEDS (no false positive) when both gates are ratified and nothing drifted. Mints into a
#     throwaway ledger (covered by the real-ledger byte-unchanged guard below).
GBR="$(mktemp -d -p "$TMPROOT")"; (cd "$GBR" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix gbr >/dev/null 2>&1)
cfloor "$GBR"; mkdir -p "$GBR/s"; cspec "$GBR/s" "$AVALID"; GBRH="$(mktemp -d -p "$TMPROOT")"; csent "$GBRH" "$GBR/s/spec.md"
ratify_human "$GBRH" >/dev/null 2>&1
ratify_breakdown_human "$GBRH" >/dev/null 2>&1 && ok || no "ratify-breakdown exits 0 at a PTY after spec-ratify"
[ -f "$GBRH/intake-breakdown-ratified.json" ] && ok || no "ratify-breakdown writes intake-breakdown-ratified.json"
[ "$(jq -r '.human_origin // empty' "$GBRH/intake-breakdown-ratified.json" 2>/dev/null)" = "true" ] && ok || no "breakdown token records human_origin:true"
gbr_h="$(awk '/<!-- forge:tasks:begin/{f=1;next} /<!-- forge:tasks:end/{f=0} f && $0 !~ /^```/' "$GBR/s/spec.md" | sha256sum | cut -d' ' -f1)"
[ "$(jq -r '.task_sha256 // empty' "$GBRH/intake-breakdown-ratified.json" 2>/dev/null)" = "$gbr_h" ] && ok || no "breakdown task_sha256 == sha256 of the extracted Task Breakdown block (shared extractor, both ends)"
cvb="$(cd "$GBR" && FORGE_HARNESS_DIR="$GBRH" bash "$INTAKE" convert 2>&1)"; rcb=$?
{ [ "$rcb" -eq 0 ] && printf '%s' "$cvb" | grep -qF "breakdown ratification verified"; } && ok || no "convert SUCCEEDS + logs breakdown verified when both gates ratified, nothing drifted (rc=$rcb: $cvb)"

# (2) THE non-vacuity proof (R5a): a post-sign-off Task-Breakdown DRIFT (a DoD-string
#     edit) with understanding.md AND the FR lines BYTE-IDENTICAL — convert MUST refuse. RED vs the deployed
#     intake (no breakdown gate -> it MINTS the drift), GREEN vs the candidate (refuses). This single case is
#     what proves the gate CLOSES the hole rather than merely adding a token.
CDR="$(mktemp -d -p "$TMPROOT")"; (cd "$CDR" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix cdr >/dev/null 2>&1)
cfloor "$CDR"; mkdir -p "$CDR/s"; cspec "$CDR/s" "$AVALID"; CDRH="$(mktemp -d -p "$TMPROOT")"; csent "$CDRH" "$CDR/s/spec.md"
und_b="$(sha256sum "$CDR/s/understanding.md" | cut -d' ' -f1)"; fr_b="$(grep -E '^- \*\*FR-[0-9]{3}:\*\*' "$CDR/s/spec.md" | sha256sum | cut -d' ' -f1)"
ratify_human "$CDRH" >/dev/null 2>&1; ratify_breakdown_human "$CDRH" >/dev/null 2>&1
sed -i 's/"a failing test passes"/"a DIFFERENT failing test passes"/' "$CDR/s/spec.md"
und_a="$(sha256sum "$CDR/s/understanding.md" | cut -d' ' -f1)"; fr_a="$(grep -E '^- \*\*FR-[0-9]{3}:\*\*' "$CDR/s/spec.md" | sha256sum | cut -d' ' -f1)"
{ [ "$und_b" = "$und_a" ] && [ "$fr_b" = "$fr_a" ]; } && ok || no "(precondition) the DoD-string edit left understanding.md AND the FR lines byte-identical"
cvd="$(cd "$CDR" && FORGE_HARNESS_DIR="$CDRH" bash "$INTAKE" convert 2>&1)"; rcd=$?
{ [ "$rcd" -ne 0 ] && printf '%s' "$cvd" | grep -qF "Task Breakdown changed"; } && ok || no "CRITICAL (R5a): convert REFUSES a post-sign-off task-block edit while understanding.md+FR are byte-identical (rc=$rcd: $cvd)"

# (3) Fail-closed: ratify-breakdown never run -> missing breakdown token -> convert refuses (never skips,
#     mirroring the fr_sha256 missing-field fail-closed). Spec ratified + fresh, so it reaches the breakdown gate.
CMT="$(mktemp -d -p "$TMPROOT")"; (cd "$CMT" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix cmt >/dev/null 2>&1)
cfloor "$CMT"; mkdir -p "$CMT/s"; cspec "$CMT/s" "$AVALID"; CMTH="$(mktemp -d -p "$TMPROOT")"; csent "$CMTH" "$CMT/s/spec.md"
ratify_human "$CMTH" >/dev/null 2>&1
cvm="$(cd "$CMT" && FORGE_HARNESS_DIR="$CMTH" bash "$INTAKE" convert 2>&1)"; rcm=$?
{ [ "$rcm" -ne 0 ] && printf '%s' "$cvm" | grep -qF "no Gate-A′ breakdown ratification token"; } && ok || no "convert FAIL-CLOSED on a missing breakdown token (rc=$rcm: $cvm)"

# (4) no-TTY refusal: a bare (non-PTY) ratify-breakdown refuses AND mints NO token — the agent self-ratify
#     path is closed by the SAME TTY gate as ratify (the deny-hook string match is only defense-in-depth).
CNT="$(mktemp -d -p "$TMPROOT")"; (cd "$CNT" && git init -q .); cfloor "$CNT"; mkdir -p "$CNT/s"; cspec "$CNT/s" "$AVALID"
CNTH="$(mktemp -d -p "$TMPROOT")"; csent "$CNTH" "$CNT/s/spec.md"; ratify_human "$CNTH" >/dev/null 2>&1
ntb="$(FORGE_HARNESS_DIR="$CNTH" bash "$INTAKE" ratify-breakdown </dev/null 2>&1)"; ntrc=$?
{ [ "$ntrc" -ne 0 ] && printf '%s' "$ntb" | grep -qF "interactive terminal" && [ ! -f "$CNTH/intake-breakdown-ratified.json" ]; } && ok || no "no-TTY ratify-breakdown refuses + mints NO token (rc=$ntrc: $ntb)"

# (5) Ordering: ratify-breakdown BEFORE spec-ratify (phase=open) refuses — Gate A′ cannot precede Gate A.
COR="$(mktemp -d -p "$TMPROOT")"; (cd "$COR" && git init -q .); cfloor "$COR"; mkdir -p "$COR/s"; cspec "$COR/s" "$AVALID"
CORH="$(mktemp -d -p "$TMPROOT")"; csent "$CORH" "$COR/s/spec.md"
orb="$(ratify_breakdown_human "$CORH")"; orrc=$?
{ [ "$orrc" -ne 0 ] && printf '%s' "$orb" | grep -qF "not ratified"; } && ok || no "ratify-breakdown refuses before spec-ratify (phase=open) (rc=$orrc: $orb)"

# (6) clarify re-open invalidates the breakdown token (mirrors the spec token at line ~303).
CCL="$(mktemp -d -p "$TMPROOT")"; (cd "$CCL" && git init -q .); cfloor "$CCL"; mkdir -p "$CCL/s"; cspec "$CCL/s" "$AVALID"
CCLH="$(mktemp -d -p "$TMPROOT")"; csent "$CCLH" "$CCL/s/spec.md"
ratify_human "$CCLH" >/dev/null 2>&1; ratify_breakdown_human "$CCLH" >/dev/null 2>&1
[ -f "$CCLH/intake-breakdown-ratified.json" ] && ok || no "(precondition) breakdown token exists before clarify"
FORGE_HARNESS_DIR="$CCLH" bash "$INTAKE" clarify >/dev/null 2>&1
[ ! -f "$CCLH/intake-breakdown-ratified.json" ] && ok || no "clarify re-open invalidates the breakdown token"

# (7) Always-on, fail-closed: convert refuses a STALE spec token, and a non-human-origin spec
#     token. The spec freshness/origin gate fires before the breakdown gate, so these die at the spec token.
CST="$(mktemp -d -p "$TMPROOT")"; (cd "$CST" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix cst >/dev/null 2>&1)
cfloor "$CST"; mkdir -p "$CST/s"; cspec "$CST/s" "$AVALID"; CSTH="$(mktemp -d -p "$TMPROOT")"; csent "$CSTH" "$CST/s/spec.md"
ratify_human "$CSTH" >/dev/null 2>&1; ratify_breakdown_human "$CSTH" >/dev/null 2>&1
jq '.ratified_at="2000-01-01T00:00:00Z"' "$CSTH/intake-ratified.json" >"$CSTH/.t" && mv "$CSTH/.t" "$CSTH/intake-ratified.json"
cvs="$(cd "$CST" && FORGE_HARNESS_DIR="$CSTH" bash "$INTAKE" convert 2>&1)"; rcs=$?
{ [ "$rcs" -ne 0 ] && printf '%s' "$cvs" | grep -qiF "stale"; } && ok || no "convert refuses a STALE ratification token (rc=$rcs: $cvs)"
CHO="$(mktemp -d -p "$TMPROOT")"; (cd "$CHO" && git init -q . && bd init --skip-agents --skip-hooks --non-interactive --prefix cho >/dev/null 2>&1)
cfloor "$CHO"; mkdir -p "$CHO/s"; cspec "$CHO/s" "$AVALID"; CHOH="$(mktemp -d -p "$TMPROOT")"; csent "$CHOH" "$CHO/s/spec.md"
ratify_human "$CHOH" >/dev/null 2>&1; ratify_breakdown_human "$CHOH" >/dev/null 2>&1
jq 'del(.human_origin)' "$CHOH/intake-ratified.json" >"$CHOH/.t" && mv "$CHOH/.t" "$CHOH/intake-ratified.json"
cvh="$(cd "$CHO" && FORGE_HARNESS_DIR="$CHOH" bash "$INTAKE" convert 2>&1)"; rch=$?
{ [ "$rch" -ne 0 ] && printf '%s' "$cvh" | grep -qiF "human-origin"; } && ok || no "convert refuses a non-human-origin token (rc=$rch: $cvh)"

echo "== intake convert: throwaway-ledger guard verdict =="
BEADS_STATE_AFTER="$(ledger_state)"
[ "$BEADS_STATE_BEFORE" = "$BEADS_STATE_AFTER" ] && ok || no "REAL .beads/issues.jsonl state CHANGED during the convert tests — THE UNRECOVERABLE GUARD TRIPPED (before=$BEADS_STATE_BEFORE after=$BEADS_STATE_AFTER)"

echo "== intake risk (B+C): TTY-gated per-intake catastrophic assignment, sentinel-borne =="
# RED on the deployed intake.sh (no `risk` command -> usage die -> .risk never written); GREEN on the
# candidate + FORGE_INTAKE_CATEGORIES. The enum resolves the 3-tier registry default; the human assigns.
RHD="$(mktemp -d -p "$TMPROOT")"
RENUM="${FORGE_INTAKE_CATEGORIES:-$ROOT/harness/intake-categories.json}"
jq -nc '{spec:"x/spec.md",mode:"interactive",phase:"open",clarify_rounds:5,restate_rounds:3,clarify_max_q:4}' >"$RHD/active-intake.json"
risk_human() { FORGE_HARNESS_DIR="$RHD" FORGE_INTAKE_CATEGORIES="$RENUM" script -qec "bash '$INTAKE' risk $*" /dev/null >/dev/null 2>&1; }
rcat() { jq '.risk.catastrophic | length' "$RHD/active-intake.json" 2>/dev/null; }
# TTY refusal: the agent's non-TTY Bash cannot self-assign risk (mirrors ratify). (On the deployed run the
# command also dies — unknown command — so this never false-passes either way.)
if FORGE_HARNESS_DIR="$RHD" FORGE_INTAKE_CATEGORIES="$RENUM" bash "$INTAKE" risk >/dev/null 2>&1; then no "risk refuses a non-TTY (agent cannot self-assign)"; else ok; fi
# registry by-default tier (no in-scope context) = 22 catastrophic
risk_human --clear; [ "$(rcat)" = 22 ] && ok || no "risk --clear resolves the 22 by-default catastrophic categories (got $(rcat))"
# the human-set in-scope context flag ELEVATES the if-in-scope tier (+8 = 30) — the ONLY way they activate
risk_human --in-scope safety-critical; [ "$(rcat)" = 30 ] && ok || no "risk --in-scope safety-critical elevates the if-in-scope tier to 30 (got $(rcat))"
[ "$(jq -r '.risk.human_origin' "$RHD/active-intake.json" 2>/dev/null)" = true ] && ok || no "risk records human_origin=true"
# de-escalate a by-default category (a deliberate human override)
risk_human --remove data-migration-schema-evolution
[ "$(jq --arg s data-migration-schema-evolution '.risk.catastrophic | index($s) == null' "$RHD/active-intake.json" 2>/dev/null)" = true ] && ok || no "risk --remove de-escalates a by-default category"
# a non-canonical slug is refused (slugs constrained to the taxonomy)
if risk_human --add not-a-real-category; then no "risk rejects a non-canonical --add slug"; else ok; fi

echo "== intake G3 (B+C): the UN-bypassable catastrophic ratify floor (cmd_ratify, protected) =="
# RED on the PRISTINE deployed intake.sh (cmd_ratify has no coverage check -> MINTS despite an uncovered
# catastrophic category); GREEN on the candidate + enum (cmd_ratify REFUSES; no token). Plus the conscious
# de-escalation escape (risk --remove) and the over-block guard. ratify is human-TTY-only -> PTY via `script`.
g3body() { jq -r --arg na "$1" '.categories[]? | if .id==$na then "- `\(.id)` — deliberately N/A — waved off" elif .risk_default=="by-default" then "- `\(.id)` — covered by FR-001" else "- `\(.id)` — deliberately N/A — fixture default" end' "$CATS" 2>/dev/null; }
g3setup() { # <deferrals-ledger> — fresh Gate-A-ready harness (consensus restatement); prints the harness dir
  local hd
  hd="$(mktemp -d -p "$TMPROOT")"
  mkdir -p "$hd/s"
  { printf '## User Scenarios\n### US1 (P1) — x\n## Requirements\n- FR-001: System MUST x. (US1)\n## Success Criteria\n- SC-001: completes fast.\n## Deferrals / Out of scope\n'; printf '%s\n' "$1"; } >"$hd/s/spec.md"
  printf '%s' "$U_BODY" >"$hd/s/understanding.md"
  printf '%s' "$RST_CONSENSUS" >"$hd/s/restatement.md"
  # Stage E: g3setup ratifies (the G3 fixtures), so stage the consensus spec-review record cmd_ratify now
  # requires (C7), bound to the spec sha (anti-TOCTOU) — else the record-exists/sha check refuses before the
  # G3 catastrophic check under test.
  jq -nc --arg ssha "$(sha256sum "$hd/s/spec.md" | cut -d' ' -f1)" '{verdict:"AGREE",spec_sha256:$ssha,findings:[]}' >"$hd/intake-spec-review.json"
  jq -nc --arg s "$hd/s/spec.md" '{spec:$s,mode:"interactive",phase:"open",clarify_rounds:5,restate_rounds:3,clarify_max_q:4}' >"$hd/active-intake.json"
  printf '%s' "$hd"
}
g3ratify() { FORGE_HARNESS_DIR="$1" FORGE_INTAKE_CATEGORIES="$CATS" script -qec "bash '$INTAKE' ratify" /dev/null >/dev/null 2>&1; }
# (1) THE bypass RED anchor: a by-default catastrophic category waved off as `deliberately N/A` -> ratify REFUSED.
GNAH="$(g3setup "$(g3body data-migration-schema-evolution)")"
g3ratify "$GNAH"
if [ -f "$GNAH/intake-ratified.json" ]; then no "G3: ratify REFUSES a catastrophic-N/A spec (no token) — RED proves the deployed bypass MINTS"; else ok; fi
# (2) conscious de-escalation escape: a human (PTY) de-escalates the category, then ratify succeeds.
FORGE_HARNESS_DIR="$GNAH" FORGE_INTAKE_CATEGORIES="$CATS" script -qec "bash '$INTAKE' risk --remove data-migration-schema-evolution" /dev/null >/dev/null 2>&1
g3ratify "$GNAH"
[ -f "$GNAH/intake-ratified.json" ] && ok || no "G3: after 'risk --remove', ratify succeeds (the conscious de-escalation escape)"
# (3) over-block guard: a fully-covered catastrophic ledger ratifies clean (no false block).
GOKH="$(g3setup "$(g3body __no_such_id__)")"
g3ratify "$GOKH"
[ -f "$GOKH/intake-ratified.json" ] && ok || no "G3: a fully-covered catastrophic ledger ratifies clean (no over-block)"
# (1b) THE LEAK guard: a catastrophic category waved off as `deliberately N/A` whose
# free-text REASON contains 'covered by' must STILL be REFUSED — the token-TYPE check anchors on the disposition
# token (field 2 after the id+em-dash), NOT the whole ledger line. RED on the deployed substrate (the line-level
# grep finds 'covered by' in the reason and MINTS); GREEN on the candidate (the token-anchored awk refuses).
GLEAK="$(g3setup "$(jq -r '.categories[]? | if .id=="data-migration-schema-evolution" then "- `\(.id)` — deliberately N/A — will be covered by a later phase" elif .risk_default=="by-default" then "- `\(.id)` — covered by FR-001" else "- `\(.id)` — deliberately N/A — fixture default" end' "$CATS" 2>/dev/null)")"
g3ratify "$GLEAK"
if [ -f "$GLEAK/intake-ratified.json" ]; then no "G3 LEAK: ratify MINTED a catastrophic N/A whose reason says 'covered by' (token leak — RED proves the deployed line-level grep mints)"; else ok; fi
# (4) over-block guard (the other direction): a genuine `surfaced — <ref>` whose REF text contains 'covered'
# still ratifies — the disposition token is 'surfaced', so it must PASS (no false block from the anchored check).
GSURF="$(g3setup "$(jq -r '.categories[]? | if .id=="data-migration-schema-evolution" then "- `\(.id)` — surfaced — covered in the design doc" elif .risk_default=="by-default" then "- `\(.id)` — covered by FR-001" else "- `\(.id)` — deliberately N/A — fixture default" end' "$CATS" 2>/dev/null)")"
g3ratify "$GSURF"
[ -f "$GSURF/intake-ratified.json" ] && ok || no "G3 over-block: a 'surfaced — <ref>' catastrophic disposition was REFUSED (false block)"
# (5) fold-in fail-closed: a PRESENT-but-corrupt enum at ratify (no sentinel risk) must FAIL CLOSED (no token) —
# an unresolvable catastrophic set must die, never mint ('unreadable enum -> die'). RED on deployed (the loop
# reads zero categories and mints); GREEN on the candidate ([ -n "$_catset" ] || die fold-in).
GCORRUPT="$(g3setup "$(g3body __no_such_id__)")"
printf 'not json{' >"$GCORRUPT/corrupt-enum.json"
FORGE_HARNESS_DIR="$GCORRUPT" FORGE_INTAKE_CATEGORIES="$GCORRUPT/corrupt-enum.json" script -qec "bash '$INTAKE' ratify" /dev/null >/dev/null 2>&1
[ -f "$GCORRUPT/intake-ratified.json" ] && no "G3 fold-in: ratify MINTED with a present-but-corrupt enum (must fail closed)" || ok

echo "== intake clarify --axis (Stage D / G5): axis-aware grant, canonical-slug-constrained =="
# clarify is agent-allowed (NOT TTY-gated) -> direct invocation. RED on deployed (clarify ignores --axis: no
# axes ledger, bad slug not rejected); GREEN on the candidate. The pure scalar-grant path is unchanged; the
# protected re-open block (token invalidation) is byte-untouched.
AXHD="$(mktemp -d -p "$TMPROOT")"
jq -nc '{spec:"x/spec.md",mode:"interactive",phase:"open",clarify_rounds:5,restate_rounds:3,clarify_max_q:4}' >"$AXHD/active-intake.json"
clax() { FORGE_HARNESS_DIR="$AXHD" FORGE_INTAKE_CATEGORIES="$CATS" bash "$INTAKE" clarify "$@" >/dev/null 2>&1; }
clax
[ "$(cat "$AXHD/intake-clarify-grant" 2>/dev/null)" = 1 ] && ok || no "clarify (no axis) increments the scalar grant (unchanged path)"
[ ! -f "$AXHD/intake-clarify-axes" ] && ok || no "clarify (no axis) writes NO axes ledger"
clax --axis data-model-domain
grep -qxF 'data-model-domain' "$AXHD/intake-clarify-axes" 2>/dev/null && ok || no "clarify --axis records the directed canonical category in the axes ledger"
[ "$(cat "$AXHD/intake-clarify-grant" 2>/dev/null)" = 2 ] && ok || no "clarify --axis also lifts the budget scalar (grant=2)"
if clax --axis not-a-real-category; then no "clarify --axis rejects a non-canonical slug (constrained to the enum)"; else ok; fi
# the rejected bad-slug call must NOT have bumped the grant (fail-fast validation, before any mutation)
[ "$(cat "$AXHD/intake-clarify-grant" 2>/dev/null)" = 2 ] && ok || no "clarify --axis <bad> fails fast WITHOUT bumping the grant counter"

echo "== intake Stage E: cmd_ratify reads the HARNESS-CAPTURED record (transcription trap closed) =="
# RED on deployed (cmd_ratify trusts the Architect-transcribed restatement.md); GREEN on candidate (reads the
# captured record). gsetup's default restatement is consensus (RST_CONSENSUS -> derived AGREE record).
# (1) THE trap: consensus restatement (0 transcribed) BUT a captured record (bound to the CURRENT spec) with
# open findings — proves the OPEN-COUNT oracle moved off restatement.md (the record's spec_sha256 matches, so
# it passes the anti-TOCTOU check and the refusal is on the open-count, not staleness).
ETH="$(gsetup)"
jq -nc --arg ssha "$(sha256sum "$ETH/s/spec.md" | cut -d' ' -f1)" '{verdict:"DISAGREE",spec_sha256:$ssha,findings:[{id:"f1",category:"security-privacy",location:"FR-001",finding:"uncovered"}]}' >"$ETH/intake-spec-review.json"
ratify_human "$ETH" >/dev/null 2>&1
if [ -f "$ETH/intake-ratified.json" ]; then no "Stage E: ratify REFUSES when the captured record has open findings (RED: deployed mints on the transcribed restatement)"; else ok; fi
# (2) C7 evidence re-expressed: NO captured record -> ratify refuses (>=1 captured review must have run).
ETH2="$(gsetup)"; rm -f "$ETH2/intake-spec-review.json"
ratify_human "$ETH2" >/dev/null 2>&1
if [ -f "$ETH2/intake-ratified.json" ]; then no "Stage E: ratify REFUSES with no captured spec-review record (C7: >=1 harness-captured review)"; else ok; fi
# (3) over-block guard: consensus restatement + AGREE record (matching sha) -> ratify succeeds (no false block).
ETH3="$(gsetup)"
ratify_human "$ETH3" >/dev/null 2>&1
[ -f "$ETH3/intake-ratified.json" ] && ok || no "Stage E: consensus record (AGREE) ratifies clean (no over-block)"
# (4) the STALENESS trap: a clean AGREE record whose spec_sha256 is STALE (reviewed an older spec). Deployed
# trusts the consensus restatement -> MINTS; candidate's anti-TOCTOU sha check -> REFUSES (re-run spec-review).
ETS="$(gsetup)"
jq '.spec_sha256="0000staleshaneverthecurrentspec0000"' "$ETS/intake-spec-review.json" >"$ETS/.t" && mv "$ETS/.t" "$ETS/intake-spec-review.json"
ratify_human "$ETS" >/dev/null 2>&1
if [ -f "$ETS/intake-ratified.json" ]; then no "Stage E: ratify REFUSES a STALE spec-review record (spec_sha256 != current spec; anti-TOCTOU, mirrors convert's drift-refusal)"; else ok; fi

echo "== intake spec-review (Stage E): harness-captured backend -> sentinel-JSON record (fail-closed) =="
# RED on deployed (no `spec-review` command -> dies, no record); GREEN on candidate + a stub backend.
SEHD="$(mktemp -d -p "$TMPROOT")"; SEBIN="$(mktemp -d -p "$TMPROOT")"; mkdir -p "$SEHD/s"
printf '## User Scenarios\n### US1 (P1) — x\n## Requirements\n- **FR-001:** x. (US1)\n## Success Criteria\n- SC-001: y.\n' >"$SEHD/s/spec.md"
printf '# Understanding\n## What the FRs will build\nx.\n' >"$SEHD/s/understanding.md"
printf '# Restatement\n### Restatement round 1\nx\n' >"$SEHD/s/restatement.md"
jq -nc --arg s "$SEHD/s/spec.md" '{spec:$s,mode:"interactive",phase:"open",clarify_rounds:5,restate_rounds:3,clarify_max_q:4}' >"$SEHD/active-intake.json"
# fake backend: emits prose + the sentinel-JSON verdict block
{ printf '#!/usr/bin/env bash\ncat >/dev/null\ncat <<'\''BLK'\''\nprose\n'; printf '<!-- forge:spec-review:begin v1 -->\n{"verdict":"DISAGREE","findings":[{"id":"f1","category":"security-privacy","location":"FR-001","finding":"x"}]}\n<!-- forge:spec-review:end v1 -->\nBLK\n'; } >"$SEBIN/ollama"
chmod +x "$SEBIN/ollama"
PATH="$SEBIN:$PATH" SPEC_REVIEW_BACKEND=ollama FORGE_HARNESS_DIR="$SEHD" FORGE_INTAKE_CATEGORIES="$CATS" bash "$INTAKE" spec-review >/dev/null 2>&1
if [ "$(jq -r '.verdict' "$SEHD/intake-spec-review.json" 2>/dev/null)" = "DISAGREE" ] && [ "$(jq '.findings|length' "$SEHD/intake-spec-review.json" 2>/dev/null)" = 1 ] && [ "$(jq -r '.actor' "$SEHD/intake-spec-review.json" 2>/dev/null)" = "harness" ]; then ok; else no "spec-review captures the backend's sentinel-JSON verdict to .harness/intake-spec-review.json (harness-stamped)"; fi
# fail-closed: a backend emitting NO sentinel block writes NO record (a missing record is not consensus).
SEHD2="$(mktemp -d -p "$TMPROOT")"; SEBIN2="$(mktemp -d -p "$TMPROOT")"; mkdir -p "$SEHD2/s"
cp "$SEHD/s/spec.md" "$SEHD2/s/spec.md"; cp "$SEHD/s/understanding.md" "$SEHD2/s/understanding.md"; cp "$SEHD/s/restatement.md" "$SEHD2/s/restatement.md"
jq -nc --arg s "$SEHD2/s/spec.md" '{spec:$s,mode:"interactive",phase:"open",clarify_rounds:5,restate_rounds:3,clarify_max_q:4}' >"$SEHD2/active-intake.json"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "no structured block here"\n' >"$SEBIN2/ollama"; chmod +x "$SEBIN2/ollama"
PATH="$SEBIN2:$PATH" SPEC_REVIEW_BACKEND=ollama FORGE_HARNESS_DIR="$SEHD2" FORGE_INTAKE_CATEGORIES="$CATS" bash "$INTAKE" spec-review >/dev/null 2>&1
[ -f "$SEHD2/intake-spec-review.json" ] && no "spec-review writes NO record when the backend emits no sentinel block (fail-closed on the record)" || ok

echo "==== intake: $PASS passed, $FAIL failed ===="
[ "$FAIL" = "0" ]
