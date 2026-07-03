#!/usr/bin/env bash
# Tests for the agentic-builder-forge intake — the canonical COVERAGE TAXONOMY enum.
# Runs directly (no Claude). Proves: (1) harness/intake-categories.json is the ONE machine-readable source
# (well-formed, the ratified 142-category set), and (2) the 3-way prose drift is KILLED — the skills/agents
# no longer hardcode an "11 categories" count and instead REFERENCE the enum.
#
# Run: bash tests/categories/run.sh   (or: pnpm test:categories)
#
# Pre-splice candidate verification (mirrors tests/hooks/run.sh FORGE_*_HOOK): point the enum override at the
# sandbox candidate before the harness/ copy exists:
#   FORGE_INTAKE_CATEGORIES="$PWD/path/to/candidate/intake-categories.json" bash tests/categories/run.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CAT="${FORGE_INTAKE_CATEGORIES:-$ROOT/harness/intake-categories.json}"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
no() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s]\n' "$1"
}
# check <label> <cmd...> : ok iff cmd exits 0
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok; else no "$label"; fi
}

command -v jq >/dev/null 2>&1 || {
  echo "categories: jq is required" >&2
  exit 1
}

# RATIFIED BASELINE — bump these deliberately if the taxonomy is intentionally changed (human re-ratifies).
RATIFIED_COUNT=142
RATIFIED_CLUSTERS='["Scope & Intent","Domain & Data","Interfaces & Integration","UX & Interaction","Content & Brand","Quality: Performance & Efficiency","Quality: Reliability & Resilience","Quality: Security","Quality: Safety","Quality: Maintainability & Flexibility","Operational & Lifecycle","Constraints, Risk & Governance"]'

echo "== taxonomy: the canonical coverage-taxonomy enum ($CAT) =="
check "enum file exists" test -f "$CAT"
check "enum is a JSON object with a categories[] array" jq -e 'type=="object" and (.categories|type=="array")' "$CAT"
check "enum carries the ratified $RATIFIED_COUNT categories" jq -e --argjson n "$RATIFIED_COUNT" '(.categories|length)==$n' "$CAT"
check "every category id is unique" jq -e '([.categories[].id]|length) == ([.categories[].id]|unique|length)' "$CAT"
check "every id is canonical kebab-case" jq -e '[.categories[].id|test("^[a-z0-9]+(-[a-z0-9]+)*$")]|all' "$CAT"
check "every category has a non-empty name and cluster" jq -e '[.categories[]|(.name|type=="string" and (.|length>0)) and (.cluster|type=="string" and (.|length>0))]|all' "$CAT"
check "every cluster is one of the 12 ratified clusters" jq -e --argjson c "$RATIFIED_CLUSTERS" '[.categories[].cluster]|unique|all(.[]; . as $x | $c|index($x)!=null)' "$CAT"
# B+C: the 3-tier registry risk default (D1 ratification). by-default + if-in-scope = the catastrophic-class
# suggestions; the per-INTAKE catastrophic set is human-assigned via cmd_risk (the enum is only the default).
check "every category has a valid 3-tier risk_default" jq -e '[.categories[].risk_default|.=="by-default" or .=="if-in-scope" or .=="none"]|all' "$CAT"
check "the ratified by-default count (22)" jq -e '([.categories[]|select(.risk_default=="by-default")]|length)==22' "$CAT"
check "the ratified if-in-scope count (8)" jq -e '([.categories[]|select(.risk_default=="if-in-scope")]|length)==8' "$CAT"

# carry-forward + live-gap presence (the set must not silently drop the existing 11 or the live-run axes)
for slug in functional-scope-behaviour data-model-domain terminology-consistency misc-placeholders \
  completion-signals-acceptance integration-external-dependencies edge-cases-failure-handling \
  competitive-differentiation content-design-information-architecture visual-brand-consistency content-source-fidelity; do
  check "enum contains canonical id '$slug'" jq -e --arg s "$slug" 'any(.categories[]; .id==$s)' "$CAT"
done

echo "== taxonomy: the 3-way prose drift is KILLED (single source = the enum) =="
SKILL="$ROOT/.claude/skills/clarify/SKILL.md"
REVIEWER="$ROOT/.claude/agents/spec-reviewer.md"
ARCH="$ROOT/.claude/agents/architect.md"
# no live machinery file may hardcode an "11 categories"/"11-category" count any more
hardcode_re='(\b11[[:space:]-]?categor|eleven categor|all 11|11-category)'
check "clarify/SKILL.md drops the hardcoded 11-count" bash -c '! grep -qiE "'"$hardcode_re"'" "$0"' "$SKILL"
check "spec-reviewer.md drops the hardcoded 11-count" bash -c '! grep -qiE "'"$hardcode_re"'" "$0"' "$REVIEWER"
check "architect.md drops the hardcoded 11-count" bash -c '! grep -qiE "'"$hardcode_re"'" "$0"' "$ARCH"
# and each instead REFERENCES the canonical enum (the single source)
check "clarify/SKILL.md references intake-categories.json" grep -qF "intake-categories.json" "$SKILL"
check "spec-reviewer.md references intake-categories.json" grep -qF "intake-categories.json" "$REVIEWER"
check "architect.md references the canonical taxonomy" grep -qiE "canonical coverage taxonomy|intake-categories.json" "$ARCH"
# the spec template + spec-authoring (the other disposition-slug surfaces) defer to the same source
check "spec-template.md ## Deferrals references the canonical enum" grep -qF "intake-categories.json" "$ROOT/templates/spec-template.md"
check "spec-template.md constrains the disposition slug to a canonical id" grep -qF "<canonical-id>" "$ROOT/templates/spec-template.md"
check "spec-authoring constrains the [ASSUMED] slug to a canonical id" grep -qF "intake-categories.json" "$ROOT/.claude/skills/spec-authoring/SKILL.md"

echo "== categories: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
