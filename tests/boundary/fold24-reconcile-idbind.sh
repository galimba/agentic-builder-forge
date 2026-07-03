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

idb(){ if forge_reconcile_id_bound  "$1" "$2" "$3"; then printf CLOSE; else printf SKIP; fi; }
rok(){ if forge_reconcile_record_ok "$1" "$2";      then printf OK;    else printf SKIP; fi; }

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

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "this test run did NOT move the floor" || bad "lib.sh changed during the test run" "pre=$FLOOR_PRE post=$FLOOR_POST"
echo "==== fold24-reconcile-idbind: $P passed, $F failed ===="
[ "$F" -eq 0 ]
