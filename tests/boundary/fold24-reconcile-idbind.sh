#!/usr/bin/env bash
# fold24 — reconcile id-bind canary (PURE-function, RED-first).
#
# The close decision cannot be fixtured against a real PR: today's branch is task/$slug (no id-encoded head
# ref exists) and fold13 leans on the real gh (PR #44, a plain feat/ head ref). So the decision is extracted
# as PURE string functions in harness/beads-lib.sh and called here directly with synthetic args (fold18's
# extract-and-call model). RED pre-splice: `type forge_reconcile_id_bound` absent. GREEN post-splice: the
# 3-arm dispatch + shape hygiene behave. FORGE_BEADS_LIB overrides the sourced lib (prove GREEN against a
# candidate before the splice); defaults to the DEPLOYED harness/beads-lib.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
BEADS_LIB="${FORGE_BEADS_LIB:-$LIVE_ROOT/harness/beads-lib.sh}"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"

# shellcheck source=/dev/null
. "$BEADS_LIB" 2>/dev/null || { bad "cannot source beads-lib ($BEADS_LIB)"; echo "==== fold24-reconcile-idbind: $P passed, $F failed ===="; exit 1; }

# RED gate: the pure predicates must exist (absent on pristine substrate -> RED until the splice lands).
type forge_reconcile_id_bound  >/dev/null 2>&1 || { bad "forge_reconcile_id_bound absent (RED until the splice lands)"; echo "==== fold24-reconcile-idbind: $P passed, $F failed ===="; exit 1; }
type forge_reconcile_record_ok >/dev/null 2>&1 || { bad "forge_reconcile_record_ok absent (RED until the splice lands)"; echo "==== fold24-reconcile-idbind: $P passed, $F failed ===="; exit 1; }
type forge_target_branch_ns    >/dev/null 2>&1 || { bad "forge_target_branch_ns absent (RED until the Phase 3 splice lands)"; echo "==== fold24-reconcile-idbind: $P passed, $F failed ===="; exit 1; }

idb(){ if forge_reconcile_id_bound  "$1" "$2" "$3"; then printf CLOSE; else printf SKIP; fi; }
rok(){ if forge_reconcile_record_ok "$1" "$2";      then printf OK;    else printf SKIP; fi; }

echo "== forge_target_branch_ns: the TRUSTED namespace prefix (default forge/agent), agent env stripped =="
[ "$(forge_target_branch_ns)" = "forge/agent" ] && ok "default namespace -> forge/agent" || bad "default namespace wrong" "$(forge_target_branch_ns)"
[ "$(FORGE_TARGET_BRANCH_NS=evil/attacker forge_target_branch_ns)" = "forge/agent" ] && ok "a poisoned FORGE_TARGET_BRANCH_NS env is IGNORED (trust: read only from the enforce-protected config)" || bad "agent env must NOT influence the reconcile namespace" "$(FORGE_TARGET_BRANCH_NS=evil/attacker forge_target_branch_ns)"

echo "== forge_reconcile_id_bound: the 3-arm dispatch keyed on the gh-VOUCHED head ref =="
# ARM 1 — single-task, id-bound
[ "$(idb fx-aaa 'task/fx-aaa-my-slug' 'task/fx-aaa-my-slug')" = CLOSE ] && ok "ARM1 task/<bead>-<slug> -> CLOSE" || bad "ARM1 should CLOSE"
[ "$(idb fx-aaa 'task/fx-aaa-my-slug' 'WHATEVER-record-field')" = CLOSE ] && ok "ARM1 ignores record.branch (id-bound to \$bead, not the record)" || bad "ARM1 must not consult record.branch"
# ARM 2 — the security-critical skip (branch-field forgery: headref==record_branch but the head ref is a SIBLING's)
[ "$(idb fx-aaa 'task/fx-bbb-sibling' 'task/fx-bbb-sibling')" = SKIP ] && ok "ARM2 forgery task/<OTHER>-<slug> WITH headref==record_branch -> SKIP (branch-field forgery closed; the case fold13 does NOT cover)" || bad "ARM2 MUST skip a sibling task/ head ref even when headref==record_branch"
[ "$(idb fx-aaa 'task/fx-aaaa-tricky' 'task/fx-aaaa-tricky')" = SKIP ] && ok "ARM2 prefix-collision guard: task/fx-aaaa- is NOT task/fx-aaa- (the hyphen boundary matters)" || bad "ARM2 must not let fx-aaaa masquerade as fx-aaa"
# ARM 3 — feature/override -> record-match (feature-override arm)
[ "$(idb fx-ccc 'feat/my-feature' 'feat/my-feature')" = CLOSE ] && ok "ARM3 feat/F WITH headref==record_branch -> CLOSE (folded-close preserved)" || bad "ARM3 folded-close should CLOSE"
[ "$(idb fx-ccc 'feat/my-feature' 'feat/OTHER')" = SKIP ] && ok "ARM3 feat/F WITH headref!=record_branch -> SKIP (record mismatch)" || bad "ARM3 mismatch should SKIP"
[ "$(idb fx-ddd 'release-x' 'release-x')" = CLOSE ] && ok "ARM3 non-feat override (release-x) WITH record-match -> CLOSE (the catch-all arm, NOT task-reconstruction)" || bad "ARM3 must record-match a non-feat override, never misroute it into ARM1"

echo "== ARM 1b — TARGET-build id-bound in the new namespace (forge/agent/builder/<bead>-<slug>) =="
[ "$(idb fx-aaa 'forge/agent/builder/fx-aaa-my-slug' 'forge/agent/builder/fx-aaa-my-slug')" = CLOSE ] && ok "ARM1b <ns>/builder/<bead>-<slug> -> CLOSE" || bad "ARM1b should CLOSE"
[ "$(idb fx-aaa 'forge/agent/builder/fx-aaa-my-slug' 'WHATEVER-record-field')" = CLOSE ] && ok "ARM1b ignores record.branch (id-bound to \$bead, not the record)" || bad "ARM1b must not consult record.branch"
# ARM 2 in the new namespace — the security-critical forgery reject
[ "$(idb fx-aaa 'forge/agent/builder/fx-bbb-sibling' 'forge/agent/builder/fx-bbb-sibling')" = SKIP ] && ok "ARM2 forgery <ns>/builder/<OTHER>-<slug> WITH headref==record_branch -> SKIP (branch-field forgery closed in the new namespace)" || bad "ARM2 MUST skip a sibling forge/agent head ref even when headref==record_branch"
[ "$(idb fx-aaa 'forge/agent/builder/fx-aaaa-tricky' 'forge/agent/builder/fx-aaaa-tricky')" = SKIP ] && ok "ARM2 prefix-collision: <ns>/builder/fx-aaaa- is NOT fx-aaa- (hyphen boundary)" || bad "ARM2 must not let fx-aaaa masquerade as fx-aaa in the new namespace"
[ "$(idb fx-aaa 'forge/agent/architect/fx-aaa-x' 'forge/agent/architect/fx-aaa-x')" = SKIP ] && ok "ARM2 a NON-builder forge/agent/ role -> SKIP (only builder id-binds; other roles fall to the forgery-reject, not record-match)" || bad "ARM2 must skip a non-builder forge/agent role"
[ "$(idb fx-aaa 'forge/agent/builder/fx-bbb/fx-aaa-x' 'forge/agent/builder/fx-bbb/fx-aaa-x')" = SKIP ] && ok "ARM2 multi-segment smuggle (…/fx-bbb/fx-aaa-x) -> SKIP (FIXED prefix, no wildcard role — an id cannot be smuggled in a deeper segment)" || bad "a multi-segment head ref must not id-bind to fx-aaa"
# CROSS-NAMESPACE: the task/ arms are UNCHANGED and independent of the new namespace
[ "$(idb fx-aaa 'task/fx-aaa-x' 'forge/agent/builder/fx-aaa-x')" = CLOSE ] && ok "cross-ns: a real task/ head ref still id-binds ARM1 even if the record is forge/agent-shaped" || bad "task/ ARM1 must be independent of the record namespace"
[ "$(idb fx-aaa 'forge/agent/builder/fx-bbb-x' 'task/fx-aaa-x')" = SKIP ] && ok "cross-ns forgery: a sibling forge/agent head ref with a task/-shaped record -> SKIP" || bad "cross-ns sibling forgery must SKIP"

echo "== N assembly-folded beads on ONE feat/F all close (the regression guard) =="
allclose=1; for b in fx-f01 fx-f02 fx-f03 fx-f04; do [ "$(idb "$b" 'feat/bundle' 'feat/bundle')" = CLOSE ] || allclose=0; done
[ "$allclose" = 1 ] && ok "4 folded beads on feat/bundle -> all CLOSE" || bad "folded close regressed on feat/F"
allclose=1; for b in fx-r01 fx-r02 fx-r03; do [ "$(idb "$b" 'release-x' 'release-x')" = CLOSE ] || allclose=0; done
[ "$allclose" = 1 ] && ok "3 folded beads on FORGE_FEATURE_BRANCH=release-x -> all CLOSE (non-feat override)" || bad "release-x folded close regressed"

echo "== read-side shape hygiene — malformed repo/branch -> SKIP (fail-closed), well-formed -> OK =="
[ "$(rok 'example-org/agentic-builder-forge' 'feat/x')" = OK ] && ok "well-formed owner/repo + branch -> OK (over-block guard: the harness's own records pass)" || bad "well-formed record must pass"
[ "$(rok 'example-org/agentic-builder-forge' 'task/fx-aaa-x')" = OK ] && ok "well-formed task/ branch -> OK" || bad "well-formed task branch must pass"
[ "$(rok '' 'feat/x')" = SKIP ] && ok "empty repo -> SKIP" || bad "empty repo must skip"
[ "$(rok 'example-org/agentic-builder-forge' '')" = SKIP ] && ok "empty branch -> SKIP" || bad "empty branch must skip"
[ "$(rok 'no-slash-here' 'feat/x')" = SKIP ] && ok "repo without owner/repo slash -> SKIP" || bad "slashless repo must skip"
[ "$(rok 'a/b/c' 'feat/x')" = SKIP ] && ok "triple-slash repo -> SKIP" || bad "triple-slash must skip"
[ "$(rok '-evil/repo' 'feat/x')" = SKIP ] && ok "leading-dash owner -> SKIP" || bad "leading-dash must skip"
[ "$(rok 'owner/-evil' 'feat/x')" = SKIP ] && ok "leading-dash repo segment -> SKIP" || bad "leading-dash repo must skip"
[ "$(rok 'example-org/agentic-builder-forge' 'has space')" = SKIP ] && ok "branch with whitespace -> SKIP" || bad "whitespace branch must skip"

# A STATIC extra ARM3 sanity case with a realistic feature-branch shape. HONEST: this is NOT a live gh query
# — forge_reconcile_id_bound is a pure function with no I/O; in production the reconcile loop feeds it a real
# merged PR's gh-vouched head ref, not this test. It is a static duplicate of the ARM3 record-match arm.
[ "$(idb fx-real 'feat/cp-floorhardening-2' 'feat/cp-floorhardening-2')" = CLOSE ] && ok "ARM3 static sanity: a feat/ head ref matching its record -> CLOSE" || bad "ARM3 static sanity failed"

echo "== CANARY: the deployed harness carries the Phase 3 wiring (RED until the splice lands) =="
grep -qF 'forge_target_branch_ns()' "$LIVE_ROOT/harness/beads-lib.sh" && ok "beads-lib defines forge_target_branch_ns" || bad "helper missing"
grep -qF 'forge_target_branch_ns)/builder/$id-$slug' "$LIVE_ROOT/harness/run-task.sh" && ok "run-task builds the target branch via the trusted helper" || bad "run-task target-branch wiring missing"
grep -qF 'FORGE_TARGET_BRANCH_NS=' "$LIVE_ROOT/harness/branches.config" 2>/dev/null && ok "branches.config carries the trusted namespace" || bad "branches.config missing"
grep -qF 'forge_target_branch_ns)"/*' "$LIVE_ROOT/harness/kill-switch.sh" && ok "kill-switch widened to the target namespace" || bad "kill-switch guard not widened"

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "this test run did NOT move the floor" || bad "lib.sh changed during the test run" "pre=$FLOOR_PRE post=$FLOOR_POST"
echo "==== fold24-reconcile-idbind: $P passed, $F failed ===="
[ "$F" -eq 0 ]
