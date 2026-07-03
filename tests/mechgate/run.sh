#!/usr/bin/env bash
# tests/mechgate/run.sh — red-proof suite for the per-bead acceptance gate.
#
# Hermetic via the copied-harness + throwaway-ledger pattern (tests/beads/integration.sh): a tmpdir
# git repo, the harness glue copied in, REAL bd (`bd init` against a throwaway ledger — the
# contract round-trip needs real `--metadata`), per-case worktrees with seeded staged diffs. bd
# absent → SKIP rc 75 (EX_TEMPFAIL, the wave's canonical SKIP code — honest, never green-washed).
#
# Gate under test — seam resolution (mirrors tests/intake/run.sh FORGE_INTAKE):
#   FORGE_ACCEPT_GATE=<path>   explicit override seam; else the DEPLOYED harness/accept-gate.sh
#   (the candidate fallback was retired). Absent → suite FAILS (fail closed).
#   The override selects which gate RUNS — never what contract it reads (no contract override
#   exists; hermeticity comes from the throwaway ROOT, exactly like the beads integration suite).
#   The resolved gate is COPIED to <tmp>/harness/accept-gate.sh because its $HERE-relative
#   sourcing resolves only from a <root>/harness/ location (see the gate header).
#
# Red-proofs (A1/A2; PD-1/2/3 + F1/DR-2/FA): every FAIL case asserts the named offender in
# BOTH the gate's message and the audit record; cases 9/10 prove never-executed via a side-effect
# canary the selector would have created. Never prompts, never reads stdin.
set -u
export BD_NON_INTERACTIVE=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
no() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s] %s\n' "$1" "${2:-}"
}

command -v jq >/dev/null 2>&1 || {
  echo "FAIL: jq is required"
  exit 1
}
command -v bd >/dev/null 2>&1 || {
  echo "SKIP: bd absent (the contract round-trip needs the real binary) — rc 75 (EX_TEMPFAIL)"
  exit 75
}

# ---- resolve the gate under test (seam resolution; fail closed) -----------------------------------
GATE_SRC="${FORGE_ACCEPT_GATE:-}"
if [ -z "$GATE_SRC" ]; then
  GATE_SRC="$ROOT/harness/accept-gate.sh"
fi
{ [ -n "$GATE_SRC" ] && [ -f "$GATE_SRC" ]; } || {
  echo "FAIL: no gate to test — harness/accept-gate.sh is missing (set FORGE_ACCEPT_GATE to override)"
  exit 1
}

# ---- throwaway ROOT: git repo + copied harness glue + real bd ledger -------------------------------
T="$(mktemp -d)"
trap 'git -C "$T" worktree prune >/dev/null 2>&1; rm -rf "$T" 2>/dev/null' EXIT
mkdir -p "$T/harness" "$T/.claude/hooks" "$T/specs" "$T/docs" "$T/sandbox/c4base" "$T/tests"
cp "$GATE_SRC" "$T/harness/accept-gate.sh" && chmod +x "$T/harness/accept-gate.sh"
cp "$ROOT/harness/beads-lib.sh" "$T/harness/beads-lib.sh"
cp "$ROOT/harness/sandbox-lib.sh" "$T/harness/sandbox-lib.sh"   # FOLD #1: accept-gate now sources sandbox-lib (forge_safe_gitdir)
cp "$ROOT/harness/beads.config" "$T/harness/beads.config" 2>/dev/null || true
cp "$ROOT/.claude/hooks/lib.sh" "$T/.claude/hooks/lib.sh"
# Absolute deployment default: the gate pins PATH (dropping ~/.local/bin) and unsets BD_BIN, then reads bd ONLY from
# beads.config. The copied config carries `:-bd` (pre-splice) which would NOT resolve under the pinned
# PATH — so the suite pins the ABSOLUTE real bd here, exactly as the harness/beads.config splice does
# on the deployed tree (an unconditional trailing assignment overrides the `:-` default when sourced).
REAL_BD="$(command -v bd)"
printf 'BD_BIN=%s\n' "$REAL_BD" >>"$T/harness/beads.config"
GATE="$T/harness/accept-gate.sh"

(
  cd "$T" || exit 1
  git init -q
  git config user.email t@t
  git config user.name t
  git symbolic-ref HEAD refs/heads/main
  printf '.harness/\n.beads/\n' >.gitignore
  printf 'base doc\n' >docs/base.txt
  printf 'old\n' >sandbox/c4base/old.txt
  printf 'keep\n' >tests/.keep
  git add .gitignore docs/base.txt sandbox/c4base/old.txt tests/.keep
  git commit -q -m fixture-base
  bd init --skip-agents --skip-hooks --non-interactive --prefix tmg >/dev/null 2>&1
) || {
  echo "FAIL: fixture bootstrap failed"
  exit 1
}
BASE="$(git -C "$T" rev-parse HEAD)"

# ---- helpers --------------------------------------------------------------------------------------
N="" TJ="" BEAD="" WT="" OUT="" RC="" AUDIT=""

mk_tj() { # mk_tj <n> [scope_json] [dod_json] [sc_json] -> task JSON on stdout
  local n="$1" sc dod ev
  sc="${2:-[\"sandbox/**\"]}"
  dod="${3:-[\"sandbox/c$n/t.sh\"]}"
  ev="${4:-}" # NB: a } inside ${4:-...} would END the expansion — build the default via jq instead
  [ -n "$ev" ] || ev="$(jq -nc --arg p "sandbox/c$n/ev.txt" '[{sc:1, path:$p}]')"
  jq -nc --argjson s "$sc" --argjson d "$dod" --argjson e "$ev" \
    '{id:"T001", title:"fixture", scope:$s, dod_tests:$d, sc_evidence:$e}'
}

mk_spec() { # mk_spec <n> <task-json>
  {
    printf '# fixture case %s\n\n<!-- forge:tasks:begin v1 -->\n```json\n' "$1"
    printf '{"target_repos":["agentic-builder-forge"],"tasks":[%s]}\n' "$2"
    printf '```\n<!-- forge:tasks:end -->\n'
  } >"$T/specs/case$1.md"
}

mint() { # mint <title> <metadata-json> -> bead id on stdout
  bd -C "$T" create "$1" --metadata "$2" -p 2 --silent </dev/null 2>/dev/null | tr -d '[:space:]'
}

std_setup() { # std_setup <n> [scope_json] [dod_json] [sc_json] — spec + bead (accept == anchor) + worktree
  N="$1"
  TJ="$(mk_tj "$@")"
  mk_spec "$N" "$TJ"
  local slice meta
  slice="$(jq -c '{scope, dod_tests, sc_evidence}' <<<"$TJ")"
  meta="$(jq -nc --arg s "specs/case$N.md" --argjson a "$slice" '{source_spec:$s, task_id:"T001", accept:$a}')"
  BEAD="$(mint "case $N" "$meta")"
  [ -n "$BEAD" ] || {
    echo "FAIL: bd create returned no id for case $N"
    exit 1
  }
  WT="$T/wt$N"
  git -C "$T" worktree add "$WT" -b "case$N" "$BASE" >/dev/null 2>&1 || {
    echo "FAIL: worktree add failed for case $N"
    exit 1
  }
  mkdir -p "$WT/sandbox/c$N"
}

std_files() { # default evidence + passing dod test, staged
  printf 'evidence\n' >"$WT/sandbox/c$N/ev.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WT/sandbox/c$N/t.sh"
  git -C "$WT" add "sandbox/c$N/ev.txt" "sandbox/c$N/t.sh"
}

run_gate() { # run_gate [extra env as leading VAR=val words via env] -- uses $BEAD/$WT/$BASE, staged mode
  OUT="$( (cd "$T" && "$GATE" --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode staged) 2>&1)"
  RC=$?
  AUDIT="$(printf '%s\n' "$OUT" | sed -n 's/^accept-gate: [A-Z-]* (bead .*; audit \(.*\))$/\1/p' | tail -1)"
}

run_gate_env() { # run_gate_env VAR=val [VAR=val...]
  OUT="$( (cd "$T" && env "$@" "$GATE" --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode staged) 2>&1)"
  RC=$?
  AUDIT="$(printf '%s\n' "$OUT" | sed -n 's/^accept-gate: [A-Z-]* (bead .*; audit \(.*\))$/\1/p' | tail -1)"
}

run_gate_args() { # run_gate_args <arg...> — full custom argv after the gate path
  OUT="$( (cd "$T" && "$GATE" "$@") 2>&1)"
  RC=$?
  AUDIT="$(printf '%s\n' "$OUT" | sed -n 's/^accept-gate: [A-Z-]* (bead .*; audit \(.*\))$/\1/p' | tail -1)"
}

expect_rc() { # expect_rc <rc> <label>
  if [ "$RC" -eq "$1" ]; then ok; else no "$2" "rc=$RC out: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"; fi
}
out_has() { # out_has <needle> <label>
  if printf '%s' "$OUT" | grep -qF "$1"; then ok; else no "$2" "output lacks '$1'"; fi
}
audit_jq() { # audit_jq <jq-expr> <label>
  if [ -n "$AUDIT" ] && [ -f "$AUDIT" ] && jq -e "$1" "$AUDIT" >/dev/null 2>&1; then ok; else no "$2" "audit=$AUDIT expr=$1"; fi
}

# ===================================================================================================
echo "== case 1: clean fixture -> PASS; audit written, schema-valid =="
std_setup 1
std_files
run_gate
expect_rc 0 "c1 PASS rc 0"
out_has "accept-gate: PASS" "c1 PASS message"
audit_jq '.verdict == "PASS"' "c1 audit verdict PASS"
audit_jq '(.checks | length) == 5 and (.checks | map(.name)) == ["contract","scope","dod_tests","sc_evidence","integrity"]' "c1 audit five named checks"
audit_jq '.actor == "harness" and .mode == "staged" and .legacy_bypass == false and (.bead | length > 0) and (.base_sha | length > 0) and (.ts | length > 0) and (.timeout_s == 600) and (.reasons == [])' "c1 audit schema fields"
audit_jq '.checks[0].result == "pass" and (.checks[0].anchor_sha256 | length) == 64 and .checks[0].anchor_sha256 == .checks[0].cache_sha256' "c1 contract pass, hashes equal"
audit_jq '.checks[4].result == "pass" and (.checks[4].pre_sha256 | length) == 64' "c1 integrity pass"

echo "== case 2: out-of-scope NEW file -> FAIL, file named =="
std_setup 2
std_files
mkdir -p "$WT/docs"
printf 'oops\n' >"$WT/docs/oops.txt"
git -C "$WT" add docs/oops.txt
run_gate
expect_rc 1 "c2 FAIL rc 1"
out_has "docs/oops.txt" "c2 offender named in message"
audit_jq '.verdict == "FAIL" and (.checks[1].result == "fail") and (.checks[1].offenders | index("docs/oops.txt") != null)' "c2 offender in audit"

echo "== case 3: out-of-scope DELETION -> FAIL =="
std_setup 3
std_files
git -C "$WT" rm -q docs/base.txt
run_gate
expect_rc 1 "c3 FAIL rc 1"
out_has "docs/base.txt" "c3 deleted path named in message"
audit_jq '.checks[1].offenders | index("docs/base.txt") != null' "c3 deletion in audit offenders"

echo "== case 4: rename in-scope -> out-of-scope -> FAIL (both-paths rule) =="
std_setup 4
std_files
git -C "$WT" mv sandbox/c4base/old.txt docs/new.txt
run_gate
expect_rc 1 "c4 FAIL rc 1"
out_has "docs/new.txt" "c4 rename target named in message"
audit_jq '(.checks[1].offenders | index("docs/new.txt") != null) and (.checks[1].offenders | index("sandbox/c4base/old.txt")) == null' "c4 target offends, in-scope source does not"

echo "== case 5: failing dod_test (exit 1) -> FAIL, selector named =="
std_setup 5
std_files
printf '#!/usr/bin/env bash\nexit 1\n' >"$WT/sandbox/c5/t.sh"
git -C "$WT" add sandbox/c5/t.sh
run_gate
expect_rc 1 "c5 FAIL rc 1"
out_has "sandbox/c5/t.sh" "c5 selector named in message"
audit_jq '.checks[2].result == "fail" and .checks[2].selectors[0].rc == 1 and .checks[2].selectors[0].verdict == "failed"' "c5 rc 1 in audit"

echo "== case 6: dod_test exit 75 -> FAIL rc75-skip-is-not-acceptance-evidence =="
std_setup 6
std_files
printf '#!/usr/bin/env bash\nexit 75\n' >"$WT/sandbox/c6/t.sh"
git -C "$WT" add sandbox/c6/t.sh
run_gate
expect_rc 1 "c6 FAIL rc 1"
out_has "rc75-skip-is-not-acceptance-evidence" "c6 named reason in message"
audit_jq '.checks[2].selectors[0].verdict == "rc75-skip-is-not-acceptance-evidence" and .checks[2].selectors[0].rc == 75' "c6 named verdict in audit"

echo "== case 7: timeout under tiny FORGE_MECHGATE_TIMEOUT -> FAIL timeout; clamp proven =="
std_setup 7
std_files
printf '#!/usr/bin/env bash\nsleep 5\n' >"$WT/sandbox/c7/t.sh"
git -C "$WT" add sandbox/c7/t.sh
run_gate_env FORGE_MECHGATE_TIMEOUT=1
expect_rc 1 "c7 FAIL rc 1"
out_has "timeout" "c7 timeout named in message"
audit_jq '.checks[2].selectors[0].verdict == "timeout" and .checks[2].selectors[0].rc == 124 and .timeout_s == 1' "c7 rc 124 + timeout_s 1 in audit"
# clamp low: 0 -> 1 (still times out the sleeping selector; proves 0 was not honored verbatim)
run_gate_env FORGE_MECHGATE_TIMEOUT=0
audit_jq '.timeout_s == 1' "c7 clamp: 0 -> 1"
# clamp high: 9999 -> 3600 (use a fast-passing case so nothing waits)
std_setup 7b
std_files
run_gate_env FORGE_MECHGATE_TIMEOUT=9999
expect_rc 0 "c7 clamp-high run passes"
audit_jq '.timeout_s == 3600' "c7 clamp: 9999 -> 3600"

echo "== case 8: missing dod_test file -> FAIL selector-missing =="
std_setup 8 '["sandbox/**"]' '["sandbox/c8/missing.sh"]'
std_files
run_gate
expect_rc 1 "c8 FAIL rc 1"
out_has "selector-missing" "c8 named reason in message"
out_has "sandbox/c8/missing.sh" "c8 selector named in message"
audit_jq '.checks[2].selectors[0].verdict == "selector-missing"' "c8 named verdict in audit"

echo "== case 9: ::pattern selector -> FAIL pattern-selector-rejected, NEVER executed (canary) =="
std_setup 9 '["sandbox/**"]' '["sandbox/c9/t.sh::some pattern"]'
std_files
printf '#!/usr/bin/env bash\ntouch canary9\nexit 0\n' >"$WT/sandbox/c9/t.sh"
git -C "$WT" add sandbox/c9/t.sh
run_gate
expect_rc 1 "c9 FAIL rc 1"
out_has "pattern-selector-rejected" "c9 named reason in message"
audit_jq '.reasons | map(select(contains("pattern-selector-rejected"))) | length > 0' "c9 named reason in audit"
if [ ! -e "$WT/canary9" ] && [ ! -e "$T/canary9" ]; then ok; else no "c9 canary: selector must NEVER execute"; fi

echo "== case 10: grammar-invalid stored selector -> FAIL named, NEVER executed (canary) =="
std_setup 10 '["sandbox/**"]' '["sandbox/c10/evil.sh; touch canary10"]'
std_files
printf '#!/usr/bin/env bash\ntouch canary10\nexit 0\n' >"$WT/sandbox/c10/evil.sh"
git -C "$WT" add sandbox/c10/evil.sh
run_gate
expect_rc 1 "c10 FAIL rc 1"
out_has "canary10" "c10 offending entry named in message"
audit_jq '.reasons | map(select(contains("canary10"))) | length > 0' "c10 offending entry in audit"
if [ ! -e "$WT/canary10" ] && [ ! -e "$T/canary10" ]; then ok; else no "c10 canary: selector must NEVER execute"; fi

echo "== case 11: sc_evidence path absent from the index -> FAIL =="
std_setup 11
printf '#!/usr/bin/env bash\nexit 0\n' >"$WT/sandbox/c11/t.sh"
git -C "$WT" add sandbox/c11/t.sh
run_gate
expect_rc 1 "c11 FAIL rc 1"
out_has "missing-from-index" "c11 named reason in message"
out_has "sandbox/c11/ev.txt" "c11 path named in message"
audit_jq '.checks[3].result == "fail" and (.checks[3].offenders | map(select(contains("sandbox/c11/ev.txt"))) | length > 0)' "c11 offender in audit"

echo "== case 12: staged-but-empty sc_evidence -> FAIL empty =="
std_setup 12
std_files
: >"$WT/sandbox/c12/ev.txt"
git -C "$WT" add sandbox/c12/ev.txt
run_gate
expect_rc 1 "c12 FAIL rc 1"
out_has "empty" "c12 named reason in message"
audit_jq '.checks[3].offenders | map(select(contains("sandbox/c12/ev.txt") and contains("empty"))) | length > 0' "c12 offender in audit"

echo "== case 13: STAGED symlink sc_evidence (mode 120000) -> FAIL symlink =="
std_setup 13
std_files
rm -f "$WT/sandbox/c13/ev.txt"
ln -s /etc/hostname "$WT/sandbox/c13/ev.txt"
git -C "$WT" add sandbox/c13/ev.txt
run_gate
expect_rc 1 "c13 FAIL rc 1"
out_has "symlink" "c13 named reason in message"
audit_jq '.checks[3].offenders | map(select(contains("sandbox/c13/ev.txt") and contains("symlink"))) | length > 0' "c13 offender in audit"

echo "== case 14: metadata.accept != spec block -> FAIL contract-drift (both hashes audited) =="
N=14
TJ="$(mk_tj 14)"
mk_spec 14 "$TJ"
drift_slice="$(jq -c '{scope: (.scope + ["docs/**"]), dod_tests, sc_evidence}' <<<"$TJ")"
meta14="$(jq -nc --arg s "specs/case14.md" --argjson a "$drift_slice" '{source_spec:$s, task_id:"T001", accept:$a}')"
BEAD="$(mint "case 14" "$meta14")"
WT="$T/wt14"
git -C "$T" worktree add "$WT" -b case14 "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c14"
std_files
run_gate
expect_rc 1 "c14 FAIL rc 1"
out_has "contract-drift" "c14 named reason in message"
audit_jq '.checks[0].detail == "contract-drift" and (.checks[0].anchor_sha256 | length) == 64 and (.checks[0].cache_sha256 | length) == 64 and .checks[0].anchor_sha256 != .checks[0].cache_sha256' "c14 both hashes in audit, unequal"
audit_jq '.checks[1].result == "not-run" and .checks[2].result == "not-run" and .checks[3].result == "not-run"' "c14 C0 fail terminal: 1-3 not-run"

echo "== case 14b: accept sc as STRING \"1\" (spec: number 1) -> FAIL contract-drift (type-aware, R-F) =="
N=14b
TJ="$(mk_tj 14b)"
mk_spec 14b "$TJ"
drift14b="$(jq -c '.sc_evidence[0].sc = "1" | {scope, dod_tests, sc_evidence}' <<<"$TJ")"
meta14b="$(jq -nc --arg s "specs/case14b.md" --argjson a "$drift14b" '{source_spec:$s, task_id:"T001", accept:$a}')"
BEAD="$(mint "case 14b" "$meta14b")"
WT="$T/wt14b"
git -C "$T" worktree add "$WT" -b case14b "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c14b"
std_files
run_gate
expect_rc 1 "c14b FAIL rc 1"
out_has "contract-drift" "c14b named reason in message"
audit_jq '.checks[0].detail == "contract-drift" and .checks[0].anchor_sha256 != .checks[0].cache_sha256' "c14b type drift detected, hashes differ in audit"

echo "== case 15: invalid source_spec pointer (absolute; ..; outside specs/) -> FAIL =="
N=15
TJ="$(mk_tj 15)"
slice15="$(jq -c '{scope, dod_tests, sc_evidence}' <<<"$TJ")"
WT="$T/wt15"
git -C "$T" worktree add "$WT" -b case15 "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c15"
std_files
for bad in "/etc/passwd" "specs/../sneak.md" "docs/case15.md"; do
  BEAD="$(mint "case 15 $bad" "$(jq -nc --arg s "$bad" --argjson a "$slice15" '{source_spec:$s, task_id:"T001", accept:$a}')")"
  run_gate
  expect_rc 1 "c15 FAIL rc 1 ($bad)"
  out_has "source-spec-invalid" "c15 named reason ($bad)"
  audit_jq '.checks[0].detail == "source-spec-invalid" and .verdict == "FAIL"' "c15 audit names the pointer class ($bad)"
done

echo "== case 16: contract absent, no knob -> FAIL contract-missing =="
N=16
BEAD="$(mint "case 16" '{"note":"hand-minted, no accept, no pointers"}')"
WT="$T/wt16"
git -C "$T" worktree add "$WT" -b case16 "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c16"
std_files
run_gate
expect_rc 1 "c16 FAIL rc 1"
out_has "contract-missing" "c16 named reason in message"
audit_jq '.checks[0].detail == "contract-missing" and .legacy_bypass == false' "c16 audit contract-missing, no bypass"

echo "== case 17: contract absent + FORGE_MECHGATE_ALLOW_LEGACY=1 -> PASS-LEGACY, audited =="
run_gate_env FORGE_MECHGATE_ALLOW_LEGACY=1
expect_rc 0 "c17 rc 0"
out_has "PASS-LEGACY" "c17 PASS-LEGACY in message"
audit_jq '.verdict == "PASS-LEGACY" and .legacy_bypass == true' "c17 audit verdict + legacy_bypass"
audit_jq '[.checks[1,2,3,4].result] | all(. == "skipped-legacy")' "c17 checks 1-4 skipped-legacy"

echo "== case 18: in-scope filename containing a space -> PASS (NUL plumbing proven) =="
std_setup 18
std_files
printf 'spacey\n' >"$WT/sandbox/c18/a b.txt"
git -C "$WT" add "sandbox/c18/a b.txt"
run_gate
expect_rc 0 "c18 PASS rc 0"
audit_jq '.verdict == "PASS" and .checks[1].result == "pass"' "c18 scope pass with spaced filename"

echo "== case 19: audit record written on a check-0 FAIL path too =="
N=19
BEAD="tmg-zz$$"
WT="$T/wt16" # any valid worktree; the bead does not exist
run_gate
expect_rc 1 "c19 FAIL rc 1 (bead not found)"
out_has "bead-not-found" "c19 named reason in message"
if [ -n "$AUDIT" ] && [ -f "$AUDIT" ]; then ok; else no "c19 audit file exists on C0 failure"; fi
audit_jq '.verdict == "FAIL" and .checks[0].result == "fail" and .checks[0].detail == "bead-not-found"' "c19 audit records the C0 failure"

echo "== case 20: --mode range A..B -> the not-implemented STUB is GONE; verdicts a commit range (C0-C3+integrity) =="
# A..B = base_sha..task_tip, sourced from HISTORY; same checks as staged. The deployed gate is
# the fail-closed stub (RED-until-splice); FORGE_ACCEPT_GATE=<candidate> proves GREEN.
std_setup 20
std_files
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "c20 tip"
RTIP="$(git -C "$WT" rev-parse HEAD)"
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode range --range "$BASE..$RTIP"
printf '%s' "$OUT" | grep -qF "not-implemented" && no "c20 the --mode range STUB is still present (not replaced)" || ok
expect_rc 0 "c20 range PASS rc 0 (stub gone)"
out_has "accept-gate: PASS" "c20 range PASS message"
audit_jq '.mode == "range" and .verdict == "PASS" and (.checks | map(.name)) == ["contract","scope","dod_tests","sc_evidence","integrity"]' "c20 range runs all five checks"
audit_jq '.checks[4].result == "pass" and (.checks[4].pre_sha256 | length) == 64' "c20 range integrity over git diff A B"

echo "== case 20b: --mode range FAIL — out-of-scope file in B (named, same as staged) =="
std_setup 20b
std_files
mkdir -p "$WT/docs"
printf 'oops\n' >"$WT/docs/oops20b.txt"
git -C "$WT" add docs/oops20b.txt
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "c20b tip"
RTIP="$(git -C "$WT" rev-parse HEAD)"
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode range --range "$BASE..$RTIP"
expect_rc 1 "c20b range FAIL rc 1"
out_has "docs/oops20b.txt" "c20b out-of-scope file named"
audit_jq '.mode == "range" and .checks[1].result == "fail" and (.checks[1].offenders | index("docs/oops20b.txt") != null)' "c20b out-of-scope offender in audit"

echo "== case 20c: --mode range FAIL — dod_test RED in tree B (C2 runs against an archive of B) =="
std_setup 20c
std_files
printf '#!/usr/bin/env bash\nexit 1\n' >"$WT/sandbox/c20c/t.sh"
git -C "$WT" add sandbox/c20c/t.sh
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "c20c tip"
RTIP="$(git -C "$WT" rev-parse HEAD)"
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode range --range "$BASE..$RTIP"
expect_rc 1 "c20c range FAIL rc 1"
out_has "sandbox/c20c/t.sh" "c20c failing dod selector named"
audit_jq '.checks[2].result == "fail" and .checks[2].selectors[0].rc == 1' "c20c dod rc 1 in audit"

echo "== case 20d: --mode range FAIL — sc_evidence absent from tree B (missing-from-tree) =="
std_setup 20d
printf '#!/usr/bin/env bash\nexit 0\n' >"$WT/sandbox/c20d/t.sh"
git -C "$WT" add sandbox/c20d/t.sh
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "c20d tip"     # NB: no ev.txt committed
RTIP="$(git -C "$WT" rev-parse HEAD)"
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode range --range "$BASE..$RTIP"
expect_rc 1 "c20d range FAIL rc 1"
out_has "missing-from-tree" "c20d missing-from-tree named (range reads tree B, not the index)"
out_has "sandbox/c20d/ev.txt" "c20d evidence path named"
audit_jq '.checks[3].result == "fail"' "c20d sc_evidence fail in audit"

echo "== case 20e: --mode range FAIL — malformed / unresolvable ranges (fail-closed) =="
std_setup 20e
std_files
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "c20e tip"
RTIP="$(git -C "$WT" rev-parse HEAD)"
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode range --range "$BASE...$RTIP"
expect_rc 1 "c20e three-dot FAIL rc 1"
out_has "invalid-range" "c20e three-dot named"
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode range
expect_rc 1 "c20e missing --range FAIL rc 1"
out_has "requires --range" "c20e missing-range named"
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode range --range "deadbeef..cafebabe"
expect_rc 1 "c20e unresolvable FAIL rc 1"
out_has "range-unresolvable" "c20e unresolvable-commit named"
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode range --range "$BASE..$RTIP..$BASE"
expect_rc 1 "c20e extra-dots FAIL rc 1"
out_has "invalid-range" "c20e extra-dots named"

echo "== case 21: dod_test stages a file mid-run -> FAIL index-mutated-during-gate (A1) =="
std_setup 21
std_files
printf '#!/usr/bin/env bash\necho extra > extra.txt\ngit add extra.txt\nexit 0\n' >"$WT/sandbox/c21/t.sh"
git -C "$WT" add sandbox/c21/t.sh
run_gate
expect_rc 1 "c21 FAIL rc 1"
out_has "index-mutated-during-gate" "c21 named reason in message"
audit_jq '.checks[4].result == "fail" and (.checks[4].pre_sha256 | length) == 64 and (.checks[4].post_sha256 | length) == 64 and .checks[4].pre_sha256 != .checks[4].post_sha256' "c21 both hashes in audit, unequal"

echo "== case 22: evidence on disk but NOT in the index -> FAIL (phantom evidence, A2) =="
std_setup 22
printf '#!/usr/bin/env bash\nexit 0\n' >"$WT/sandbox/c22/t.sh"
git -C "$WT" add sandbox/c22/t.sh
printf 'on disk only\n' >"$WT/sandbox/c22/ev.txt" # present in the worktree, never staged
run_gate
expect_rc 1 "c22 FAIL rc 1"
out_has "missing-from-index" "c22 named reason in message"
if [ -f "$WT/sandbox/c22/ev.txt" ]; then ok; else no "c22 precondition: file IS on disk"; fi
audit_jq '.checks[3].offenders | map(select(contains("sandbox/c22/ev.txt"))) | length > 0' "c22 offender in audit"

echo "== case 23: PD-2 — sandbox PATH-shim git is IGNORED under the pinned PATH -> FAIL =="
std_setup 23
std_files
mkdir -p "$WT/docs"
printf 'oops\n' >"$WT/docs/oops23.txt"
git -C "$WT" add docs/oops23.txt
SHIMD="$T/shim23"
mkdir -p "$SHIMD"
# shim git: returns EMPTY for the scope listing (diff … --name-only); passes everything else through.
# If the gate consulted it, scope would see zero files -> no offenders -> PASS the out-of-scope diff.
cat >"$SHIMD/git" <<'SH'
#!/usr/bin/env bash
case " $* " in *" diff "*" --name-only "*) exit 0 ;; esac
exec /usr/bin/git "$@"
SH
chmod +x "$SHIMD/git"
# sanity: the shim IS a real attack — it returns empty for the exact scope listing the gate runs
if [ -z "$("$SHIMD/git" -C "$WT" diff --cached --name-only --no-renames -z "$BASE" --)" ]; then ok; else no "c23 shim precondition: returns empty for the scope listing"; fi
OUT="$( (cd "$T" && PATH="$SHIMD:$PATH" "$GATE" --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode staged) 2>&1)"
RC=$?
AUDIT="$(printf '%s\n' "$OUT" | sed -n 's/^accept-gate: [A-Z-]* (bead .*; audit \(.*\))$/\1/p' | tail -1)"
expect_rc 1 "c23 FAIL rc 1 (shim git not consulted; real git used)"
out_has "docs/oops23.txt" "c23 out-of-scope file flagged despite the shim on PATH"
audit_jq '.checks[1].result == "fail" and (.checks[1].offenders | index("docs/oops23.txt") != null)' "c23 offender in audit (pinned PATH used real git)"

echo "== case 24: PD-2 — exported BD_BIN shim is IGNORED; real ledger read; RCE canary NOT created =="
SHIMBD="$T/shim24bd"
CANARY24="$T/canary24"
cat >"$SHIMBD" <<SH
#!/usr/bin/env bash
touch "$CANARY24"
echo '[{"id":"forged","metadata":{"source_spec":"specs/forged.md","task_id":"T001","accept":{"scope":["sandbox/**"],"dod_tests":["sandbox/x/t.sh"],"sc_evidence":[{"sc":1,"path":"sandbox/x/ev.txt"}]}}}]'
SH
chmod +x "$SHIMBD"
WT="$T/wt16" # any valid worktree
BEAD="tmg-shim24$$" # a bead id absent from the real ledger
run_gate_env BD_BIN="$SHIMBD"
expect_rc 1 "c24 FAIL rc 1 (shim bd ignored; real bd has no such bead)"
out_has "bead-not-found" "c24 bead-not-found (gate read the real ledger, not the shim)"
if [ ! -e "$CANARY24" ]; then ok; else no "c24 canary: the shim bd must NEVER be executed by the gate"; fi

echo "== case 25: DR-2 — convert bead with accept stripped -> FAIL contract-stripped (knob cannot launder) =="
N=25
TJ="$(mk_tj 25)"
mk_spec 25 "$TJ"
slice25="$(jq -c '{scope, dod_tests, sc_evidence}' <<<"$TJ")"
meta25="$(jq -nc --arg r "agentic-builder-forge" --arg s "specs/case25.md" --argjson a "$slice25" '{target_repo:$r, source_spec:$s, task_id:"T001", accept:$a}')"
BEAD="$(mint "case 25" "$meta25")"
bd -C "$T" update "$BEAD" --unset-metadata accept >/dev/null 2>&1
WT="$T/wt25"
git -C "$T" worktree add "$WT" -b case25 "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c25"
std_files
run_gate_env FORGE_MECHGATE_ALLOW_LEGACY=1
expect_rc 1 "c25 FAIL rc 1 (stripped, not laundered by the legacy knob)"
out_has "contract-stripped" "c25 named reason in message"
audit_jq '.checks[0].detail == "contract-stripped" and .legacy_bypass == false and .verdict == "FAIL"' "c25 audit contract-stripped, no bypass"

echo "== case 25b: DR-2 — strip source_spec+task_id+accept; target_repo residue STILL caught -> contract-stripped =="
N=25b
TJ="$(mk_tj 25b)"
mk_spec 25b "$TJ"
slice25b="$(jq -c '{scope, dod_tests, sc_evidence}' <<<"$TJ")"
meta25b="$(jq -nc --arg r "agentic-builder-forge" --arg s "specs/case25b.md" --argjson a "$slice25b" '{target_repo:$r, source_spec:$s, task_id:"T001", accept:$a}')"
BEAD="$(mint "case 25b" "$meta25b")"
bd -C "$T" update "$BEAD" --unset-metadata source_spec --unset-metadata task_id --unset-metadata accept >/dev/null 2>&1
# precondition: target_repo is the SOLE convert residue after the 3-key strip
if [ "$(bd -C "$T" show "$BEAD" --json 2>/dev/null | jq -r '.[0].metadata | (has("target_repo")) and (has("source_spec") | not) and (has("accept") | not)')" = "true" ]; then ok; else no "c25b precondition: only target_repo survives the 3-key strip"; fi
WT="$T/wt25b"
git -C "$T" worktree add "$WT" -b case25b "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c25b"
std_files
run_gate_env FORGE_MECHGATE_ALLOW_LEGACY=1
expect_rc 1 "c25b FAIL rc 1 (target_repo residue caught)"
out_has "contract-stripped" "c25b named reason in message"
audit_jq '.checks[0].detail == "contract-stripped"' "c25b audit contract-stripped (target_repo alone triggers DR-2)"

echo "== case 26: DR-2 — genuine legacy (no convert keys) -> knob: PASS-LEGACY; no knob: contract-missing =="
N=26
BEAD="$(mint "case 26" '{"note":"hand-minted, never converted"}')"
WT="$T/wt26"
git -C "$T" worktree add "$WT" -b case26 "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c26"
std_files
run_gate_env FORGE_MECHGATE_ALLOW_LEGACY=1
expect_rc 0 "c26 PASS-LEGACY rc 0 (no convert residue)"
out_has "PASS-LEGACY" "c26 PASS-LEGACY in message"
audit_jq '.verdict == "PASS-LEGACY" and .legacy_bypass == true' "c26 audit PASS-LEGACY"
run_gate
expect_rc 1 "c26 FAIL rc 1 (no knob)"
out_has "contract-missing" "c26 contract-missing without the knob"

echo "== case 27: DR-2 — full 4-key strip (no convert residue) -> fails closed: contract-missing (no knob) =="
# Named residual: with NO convert key left, a fully-stripped convert bead is mechanically
# indistinguishable from genuine legacy. It still FAILS contract-missing without the knob (fail
# closed); WITH the explicit audited knob it would PASS-LEGACY — the operator owns that bypass.
N=27
TJ="$(mk_tj 27)"
mk_spec 27 "$TJ"
slice27="$(jq -c '{scope, dod_tests, sc_evidence}' <<<"$TJ")"
meta27="$(jq -nc --arg r "agentic-builder-forge" --arg s "specs/case27.md" --argjson a "$slice27" '{target_repo:$r, source_spec:$s, task_id:"T001", accept:$a}')"
BEAD="$(mint "case 27" "$meta27")"
bd -C "$T" update "$BEAD" --unset-metadata target_repo --unset-metadata source_spec --unset-metadata task_id --unset-metadata accept >/dev/null 2>&1
WT="$T/wt27"
git -C "$T" worktree add "$WT" -b case27 "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c27"
std_files
run_gate
expect_rc 1 "c27 FAIL rc 1 (full strip, no knob -> contract-missing)"
out_has "contract-missing" "c27 fails closed without the knob"
audit_jq '.checks[0].detail == "contract-missing"' "c27 audit contract-missing"

echo "== case 28: DR-2 — pointers stripped but accept KEPT -> anchor resolution -> FAIL source-spec-invalid =="
N=28
TJ="$(mk_tj 28)"
mk_spec 28 "$TJ"
slice28="$(jq -c '{scope, dod_tests, sc_evidence}' <<<"$TJ")"
meta28="$(jq -nc --arg r "agentic-builder-forge" --arg s "specs/case28.md" --argjson a "$slice28" '{target_repo:$r, source_spec:$s, task_id:"T001", accept:$a}')"
BEAD="$(mint "case 28" "$meta28")"
bd -C "$T" update "$BEAD" --unset-metadata source_spec --unset-metadata task_id >/dev/null 2>&1 # accept KEPT
WT="$T/wt28"
git -C "$T" worktree add "$WT" -b case28 "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c28"
std_files
run_gate_env FORGE_MECHGATE_ALLOW_LEGACY=1
expect_rc 1 "c28 FAIL rc 1 (accept present -> anchor resolution, never legacy)"
out_has "source-spec-invalid" "c28 anchor resolution fails on the missing pointer"
audit_jq '.checks[0].detail == "source-spec-invalid"' "c28 audit source-spec-invalid (accept present, pointers gone)"

echo "== case 29: Finding 1 — --mode rescope exempts .beads/issues.jsonl AND now RUNS C2/C3 (full re-verify); staged FAILs the ledger =="
std_setup 29
# a dod test that touches a canary WHEN executed — Finding 1: rescope is now a FULL re-verify, so C2 RUNS
printf '#!/usr/bin/env bash\ntouch canary29\nexit 0\n' >"$WT/sandbox/c29/t.sh"
printf 'evidence\n' >"$WT/sandbox/c29/ev.txt"
git -C "$WT" add sandbox/c29/t.sh sandbox/c29/ev.txt
# stage the harness ledger snapshot (out-of-scope by the sandbox/** boundary; force past fixture gitignore)
mkdir -p "$WT/.beads"
printf '[]\n' >"$WT/.beads/issues.jsonl"
git -C "$WT" add -f .beads/issues.jsonl
# rescope: ledger exempt -> C1 passes; C2/C3 now RUN (Finding 1 full re-verify) and pass -> PASS
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode rescope
expect_rc 0 "c29 rescope PASS rc 0 (ledger exempt, C2/C3 run and pass)"
audit_jq '.mode == "rescope" and .verdict == "PASS" and .rescope_ledger_exempt == true' "c29 rescope: ledger exempt, PASS"
audit_jq '.checks[2].result == "pass" and .checks[3].result == "pass"' "c29 rescope now RUNS C2 + C3 (Finding 1 full re-verify, not skipped)"
audit_jq '.checks[0].result == "pass" and .checks[1].result == "pass" and .checks[4].result == "pass"' "c29 rescope runs C0 + C1 + integrity"
if [ -e "$WT/canary29" ]; then ok; else no "c29 rescope MUST execute dod_tests now (C2 runs in full re-verify; selector cd's into \$WT)"; fi
# staged control: the same ledger path is out-of-scope and NOT exempt -> FAIL
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode staged
expect_rc 1 "c29 staged FAIL rc 1 (.beads/issues.jsonl out-of-scope, no exemption)"
out_has ".beads/issues.jsonl" "c29 staged names the ledger as an offender"
audit_jq '.mode == "staged" and (.checks[1].offenders | index(".beads/issues.jsonl") != null) and .rescope_ledger_exempt == false' "c29 staged: no exemption"

echo "== case 30: PD-1 — rescope catches an out-of-scope file staged AFTER a staged PASS (TOCTOU repro) =="
std_setup 30
std_files
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode staged
expect_rc 0 "c30 staged PASS (clean agent diff)"
# a deferred/orphan child stages an out-of-scope file AFTER the staged verdict
mkdir -p "$WT/docs"
printf 'late\n' >"$WT/docs/late30.txt"
git -C "$WT" add docs/late30.txt
# the rescope re-check (cmd_finish's immediately-pre-commit gate) catches it
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode rescope
expect_rc 1 "c30 rescope FAIL rc 1 (late out-of-scope stage caught)"
out_has "docs/late30.txt" "c30 rescope names the late-staged offender"
audit_jq '.mode == "rescope" and .checks[1].result == "fail" and (.checks[1].offenders | index("docs/late30.txt") != null)' "c30 rescope audit names the offender"

echo "== case 31: DR-3 — vacuous scope globs flagged ADVISORY-only (never blocks); typed globs not flagged =="
std_setup 31 '["sandbox/**","**","[a-z]*","**/*.ts"]'
std_files
run_gate
expect_rc 0 "c31 PASS rc 0 (advisory never blocks)"
audit_jq '.verdict == "PASS" and .checks[1].result == "pass"' "c31 verdict PASS despite vacuous globs"
audit_jq '(.advisories | length) == 2' "c31 exactly the 2 vacuous globs flagged"
audit_jq 'any(.advisories[]; contains("vacuous glob \"**\""))' "c31 ** flagged as scope-breadth-anomaly"
audit_jq 'any(.advisories[]; contains("vacuous glob \"[a-z]*\""))' "c31 [a-z]* flagged"
audit_jq '(any(.advisories[]; contains("\"sandbox/**\"")) | not) and (any(.advisories[]; contains("\"**/*.ts\"")) | not)' "c31 constraining globs (sandbox/**, **/*.ts) NOT flagged"

echo "== case 32: PD-3 — SIGTERM-deaf selector is SIGKILLed after the grace -> FAIL (never hangs) =="
std_setup 32
std_files
printf '#!/usr/bin/env bash\ntrap "" TERM\nwhile true; do sleep 1; done\n' >"$WT/sandbox/c32/t.sh"
git -C "$WT" add sandbox/c32/t.sh
# tiny timeout + grace so this returns in ~2s instead of hanging forever (the whole point of -k)
run_gate_env FORGE_MECHGATE_TIMEOUT=1 FORGE_MECHGATE_KILL_GRACE=1
expect_rc 1 "c32 FAIL rc 1 (killed after grace, not hung)"
out_has "killed-after-grace" "c32 killed-after-grace named in message"
audit_jq '.checks[2].selectors[0].verdict == "killed-after-grace" and .checks[2].selectors[0].rc == 137' "c32 rc 137 killed-after-grace in audit"
audit_jq '.kill_grace_s == 1' "c32 kill_grace_s recorded in audit"

echo "== case 33: PD-3 — control: TERM-respecting slow selector -> rc 124 timeout (unchanged) =="
std_setup 33
std_files
printf '#!/usr/bin/env bash\nsleep 5\n' >"$WT/sandbox/c33/t.sh"
git -C "$WT" add sandbox/c33/t.sh
run_gate_env FORGE_MECHGATE_TIMEOUT=1
expect_rc 1 "c33 FAIL rc 1"
out_has "timeout" "c33 timeout named in message"
audit_jq '.checks[2].selectors[0].verdict == "timeout" and .checks[2].selectors[0].rc == 124' "c33 rc 124 timeout in audit (unchanged)"

echo "== case 34: PD-3 — selector's plain background child is reaped after C2 (group sweep) =="
std_setup 34
std_files
MARK34="orphan34_$$"
printf '#!/usr/bin/env bash\n( exec -a %s sleep 90 ) &\nexit 0\n' "$MARK34" >"$WT/sandbox/c34/t.sh"
git -C "$WT" add sandbox/c34/t.sh
run_gate
expect_rc 0 "c34 PASS rc 0 (selector exits clean)"
audit_jq '.checks[2].selectors[0].verdict == "pass"' "c34 dod selector pass"
sleep 1
if pgrep -f "$MARK34" >/dev/null 2>&1; then no "c34 orphan: plain background child must be reaped after C2 (group swept)"; else ok; fi
pkill -f "$MARK34" 2>/dev/null || true

echo "== case 35: PD-3 — clean selector (exit 0, no children, no trap) -> pass, audit written (unchanged) =="
std_setup 35
std_files
run_gate
expect_rc 0 "c35 PASS rc 0"
audit_jq '.verdict == "PASS" and .checks[2].selectors[0].verdict == "pass" and .checks[2].selectors[0].rc == 0' "c35 dod pass, audit written"
audit_jq '.kill_grace_s == 5' "c35 default kill_grace_s 5 recorded"

echo "== case 36: Finding 1a — in-scope sc_evidence deletion AFTER staged PASS -> rescope FAILs missing-from-index (C3 runs) =="
std_setup 36
std_files
# staged PASS: clean agent diff (ev.txt + t.sh in scope, evidence present, dod passes)
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode staged
expect_rc 0 "c36 staged PASS (clean agent diff)"
# a surviving orphan removes the in-scope sc_evidence from the INDEX (deletion is IN-SCOPE for C1)
git -C "$WT" rm --cached -q sandbox/c36/ev.txt
# pre-fix rescope skipped C3 and PASSed (the Finding-1 hole); post-fix rescope RUNS C3 and FAILs
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode rescope
expect_rc 1 "c36 rescope FAIL rc 1 (evidence gone from index; C3 now runs in rescope)"
out_has "missing-from-index" "c36 rescope names missing-from-index (C3 ran)"
out_has "sandbox/c36/ev.txt" "c36 rescope names the deleted evidence path"
audit_jq '.mode == "rescope" and .checks[3].result == "fail" and (.checks[3].offenders | map(select(contains("sandbox/c36/ev.txt"))) | length > 0)' "c36 rescope audit: C3 fail names the evidence"
audit_jq '.checks[1].result == "pass"' "c36 the deletion is in-scope for C1 (C1 alone could NOT catch it — only the now-running C3 does)"

echo "== case 37: Finding 1b — in-scope dod_test overwritten to exit 1 AFTER staged PASS -> rescope FAILs (C2 runs) =="
std_setup 37
std_files
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode staged
expect_rc 0 "c37 staged PASS (dod test exit 0)"
# a surviving orphan sabotages the in-scope dod_test to fail (the edit is IN-SCOPE for C1)
printf '#!/usr/bin/env bash\nexit 1\n' >"$WT/sandbox/c37/t.sh"
git -C "$WT" add sandbox/c37/t.sh
# pre-fix rescope skipped C2 and PASSed; post-fix rescope RUNS C2 -> the exit-1 test FAILs
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode rescope
expect_rc 1 "c37 rescope FAIL rc 1 (dod now fails; C2 runs in rescope)"
out_has "sandbox/c37/t.sh" "c37 rescope names the sabotaged selector"
audit_jq '.mode == "rescope" and .checks[2].result == "fail" and .checks[2].selectors[0].rc == 1 and .checks[2].selectors[0].verdict == "failed"' "c37 rescope audit: C2 fail rc 1"
audit_jq '.checks[1].result == "pass"' "c37 the edit is in-scope for C1 (only the now-running C2 catches it)"

echo "== case 38: Finding 1 — rescope full re-verify on a CLEAN diff -> PASS with C2/C3 = pass (rescope == staged coverage) =="
std_setup 38
std_files
run_gate_args --bead "$BEAD" --worktree "$WT" --base-sha "$BASE" --mode rescope
expect_rc 0 "c38 rescope PASS rc 0 (clean re-verify)"
audit_jq '.mode == "rescope" and .verdict == "PASS"' "c38 rescope clean PASS"
audit_jq '.checks[2].result == "pass" and .checks[3].result == "pass"' "c38 rescope RUNS C2 + C3 (not skipped-rescope)"
audit_jq '.checks[0].result == "pass" and .checks[1].result == "pass" and .checks[4].result == "pass"' "c38 rescope runs all five checks"
audit_jq '.rescope_ledger_exempt == false' "c38 no ledger staged -> no exemption applied"

echo "== case 39: DR-2 — non-object metadata (scalar/array/number) + accept absent -> contract-stripped, knob cannot launder =="
# Real bd validates metadata as a JSON object on create ("metadata must be a JSON object"), so scalar
# metadata is unreachable via real bd. Pin the gate's fail-closed branch DIRECTLY via a config-pinned
# fake bd that emits non-object metadata (sound: the gate reads BD_BIN ONLY from beads.config — case 24
# proves it ignores the environment; forge_main_root + forge_beads_load resolve a self-contained root).
DR2="$T/dr2"
mkdir -p "$DR2/harness" "$DR2/.claude/hooks"
cp "$GATE" "$DR2/harness/accept-gate.sh" && chmod +x "$DR2/harness/accept-gate.sh"
cp "$ROOT/harness/beads-lib.sh" "$DR2/harness/beads-lib.sh"
cp "$ROOT/harness/sandbox-lib.sh" "$DR2/harness/sandbox-lib.sh"   # FOLD #1: accept-gate sources sandbox-lib (forge_safe_gitdir)
cp "$ROOT/.claude/hooks/lib.sh" "$DR2/.claude/hooks/lib.sh"
cat >"$DR2/harness/scalar-bd" <<'SH'
#!/usr/bin/env bash
# DR-2 fixture bd: emit a bead with NON-OBJECT metadata selected by the requested id; no accept.
case " $* " in
  *" dr2scalar "*) echo '[{"id":"dr2scalar","metadata":"i-am-a-scalar-string-not-an-object"}]' ;;
  *" dr2array "*) echo '[{"id":"dr2array","metadata":[]}]' ;;
  *" dr2number "*) echo '[{"id":"dr2number","metadata":42}]' ;;
  *) echo '[]' ;;
esac
SH
chmod +x "$DR2/harness/scalar-bd"
printf 'BD_BIN=%s\n' "$DR2/harness/scalar-bd" >"$DR2/harness/beads.config"
(
  cd "$DR2" || exit 1
  git init -q
  git config user.email t@t
  git config user.name t
  git symbolic-ref HEAD refs/heads/main
  printf 'base\n' >base.txt
  git add base.txt
  git commit -q -m dr2-base
) || {
  echo "FAIL: dr2 mini-root bootstrap failed"
  exit 1
}
DR2BASE="$(git -C "$DR2" rev-parse HEAD)"
for shape in dr2scalar dr2array dr2number; do
  OUT="$( (cd "$DR2" && env FORGE_MECHGATE_ALLOW_LEGACY=1 "$DR2/harness/accept-gate.sh" --bead "$shape" --worktree "$DR2" --base-sha "$DR2BASE" --mode staged) 2>&1)"
  RC=$?
  AUDIT="$(printf '%s\n' "$OUT" | sed -n 's/^accept-gate: [A-Z-]* (bead .*; audit \(.*\))$/\1/p' | tail -1)"
  expect_rc 1 "c39 $shape FAIL rc 1 (non-object metadata fails closed even with the knob)"
  out_has "contract-stripped" "c39 $shape -> contract-stripped"
  audit_jq '.checks[0].detail == "contract-stripped" and .legacy_bypass == false and .verdict == "FAIL"' "c39 $shape audit contract-stripped, no legacy bypass"
done

echo "== case 39b: DR-2 regression — NULL/absent metadata is genuine pre-contract -> knob: PASS-LEGACY; no knob: contract-missing =="
N=39b
BEAD="$(bd -C "$T" create "case 39b legacy null" -p 2 --silent </dev/null 2>/dev/null | tr -d '[:space:]')"
[ -n "$BEAD" ] || {
  echo "FAIL: bd create returned no id for case 39b"
  exit 1
}
# precondition (tolerant): a no-metadata bead's metadata is null (real bd v1.0.4) or {} — both genuine legacy
mt="$(bd -C "$T" show "$BEAD" --json 2>/dev/null | jq -rc '.[0].metadata')"
if [ "$mt" = "null" ] || [ "$mt" = "{}" ]; then ok; else no "c39b precondition: no-metadata bead must be null/{} (got: $mt)"; fi
WT="$T/wt39b"
git -C "$T" worktree add "$WT" -b case39b "$BASE" >/dev/null 2>&1
mkdir -p "$WT/sandbox/c39b"
# knob: null metadata is honored as a genuine pre-contract (legacy) bead — NOT stripped
run_gate_env FORGE_MECHGATE_ALLOW_LEGACY=1
expect_rc 0 "c39b PASS-LEGACY rc 0 (null metadata honored under the knob, NOT stripped)"
out_has "PASS-LEGACY" "c39b null metadata -> PASS-LEGACY (genuine pre-contract)"
audit_jq '.verdict == "PASS-LEGACY" and .legacy_bypass == true' "c39b audit PASS-LEGACY (null != stripped)"
# no knob: null metadata routes to the legacy path -> contract-missing (NOT contract-stripped)
run_gate
expect_rc 1 "c39b FAIL rc 1 (no knob -> contract-missing)"
out_has "contract-missing" "c39b no knob: null metadata -> contract-missing (legacy path, not stripped)"
audit_jq '.checks[0].detail == "contract-missing" and .legacy_bypass == false' "c39b audit contract-missing (null routed to legacy)"

echo
echo "==== $PASS passed, $FAIL failed (gate: $GATE_SRC) ===="
[ "$FAIL" = 0 ]
