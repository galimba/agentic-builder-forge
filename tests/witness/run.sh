#!/usr/bin/env bash
# Unit tests for the DEPLOYED witness: .claude/hooks/session-start-witness.sh and its lib.sh
# functions (forge_floor_hash / forge_witness_verify / forge_witness_gate / forge_hookspath_ok). The
# candidate shim was retired; this suite exercises the production hook incl. its hooks-path tier.
#
# SEAM (stated honestly): the hook is tested via its documented stdin contract — fixture JSON
# {session_id, source, cwd} piped directly to the script. SessionStart DELIVERY (headless -p,
# resume, off-root silence) is probe-proven against the real CLI
# and is NOT re-proven here; end-to-end live proof is the human's post-splice
# acceptance step (the witness is deployed and live on main).
#
# ISOLATION: every case runs against a THROWAWAY tree (mktemp) carrying its own copies of the
# floor files plus a private .harness; CLAUDE_PROJECT_DIR and FORGE_HARNESS_DIR pin both the
# floor root and the witness dir to the throwaway — the clone's real .claude/.harness are never
# read as roots or written. The hook's exit code is asserted 0 on EVERY path (never a gate).
#
# Run: bash tests/witness/run.sh   (or: pnpm test:witness — joins the canonical gate by discovery)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# FORGE_WITNESS_HOOK is the override seam; default = the DEPLOYED witness. The candidate shim was
# retired — the suite now exercises the production hook (incl. its commit-guard hooks-path tier).
HOOK="${FORGE_WITNESS_HOOK:-$ROOT/.claude/hooks/session-start-witness.sh}"

# The functions under test, from the deployed lib.sh (forge_floor_hash / forge_witness_sid_ok /
# forge_witness_verify / forge_witness_gate / forge_hookspath_ok).
# shellcheck source=../../.claude/hooks/lib.sh
. "${FORGE_WITNESS_LIB:-$ROOT/.claude/hooks/lib.sh}"

PASS=0
FAIL=0
ERRFILE="$(mktemp)"
TREES=()
trap 'rm -f "$ERRFILE"; [ "${#TREES[@]}" -gt 0 ] && rm -rf "${TREES[@]}"' EXIT

# check <desc> <expected-rc> <actual-rc> [stderr-must-contain]
check() {
  local desc="$1" want="$2" got="$3" needle="${4:-}"
  if [ "$got" = "$want" ] && { [ -z "$needle" ] || grep -qF -- "$needle" "$ERRFILE"; }; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s]\n  expected rc=%s got rc=%s  needle=%s\n  stderr=%s\n' \
      "$desc" "$want" "$got" "${needle:-<none>}" "$(cat "$ERRFILE")"
  fi
}

# mkfloor — build a throwaway floor tree from the repo's REAL floor files (fixture bytes only;
# nothing in the tree is ever executed or registered).
mkfloor() {
  local t
  t="$(mktemp -d)"
  mkdir -p "$t/.claude/hooks" "$t/.harness" "$t/harness/githooks"
  cp "$ROOT/.claude/hooks/pre-tool-use-deny.sh" "$t/.claude/hooks/pre-tool-use-deny.sh"
  cp "$ROOT/.claude/hooks/lib.sh" "$t/.claude/hooks/lib.sh"
  # Witness hardening: the mint script is now a HASHED floor input (forge_floor_hash folds it in), so the
  # throwaway floor must carry it or forge_floor_hash returns 1 (floor-unhashable) and the witness never mints.
  cp "$ROOT/.claude/hooks/session-start-witness.sh" "$t/.claude/hooks/session-start-witness.sh"
  cp "$ROOT/.claude/settings.json" "$t/.claude/settings.json"
  # The deployed witness's forge_hookspath_ok (the commit-guard install-guarantee tier) requires a git
  # tree whose core.hooksPath resolves to <root>/harness/githooks — satisfy it so the witness mints.
  git -C "$t" init -q
  git -C "$t" config core.hooksPath harness/githooks
  # The tightened forge_hookspath_ok requires an executable pre-commit PRESENT (not just a pointed-at
  # dir). Install a HARMLESS stub (exit 0) — a real commit-guard would refuse mkfloor_committed's own commit
  # on main and leave HEAD unborn.
  printf '#!/bin/sh\nexit 0\n' >"$t/harness/githooks/pre-commit"; chmod +x "$t/harness/githooks/pre-commit" 2>/dev/null
  TREES+=("$t")
  printf '%s' "$t"
}

# mkfloor_no_hookspath — same floor bytes, but the commit-guard hooks-path install is ABSENT
# (a git repo with core.hooksPath NOT set to harness/githooks). The deployed witness's forge_hookspath_ok
# MUST fail here and the hook MUST refuse to witness — the install-guarantee negative case below.
mkfloor_no_hookspath() {
  local t
  t="$(mktemp -d)"
  mkdir -p "$t/.claude/hooks" "$t/.harness"
  cp "$ROOT/.claude/hooks/pre-tool-use-deny.sh" "$t/.claude/hooks/pre-tool-use-deny.sh"
  cp "$ROOT/.claude/hooks/lib.sh" "$t/.claude/hooks/lib.sh"
  cp "$ROOT/.claude/hooks/session-start-witness.sh" "$t/.claude/hooks/session-start-witness.sh"
  cp "$ROOT/.claude/settings.json" "$t/.claude/settings.json"
  git -C "$t" init -q # a git repo, but core.hooksPath is NOT installed -> hooks-path guarantee absent
  TREES+=("$t")
  printf '%s' "$t"
}

# mkfloor_committed — a witness-ENABLED floor whose contents are COMMITTED (HEAD exists), so
# forge_floor_under_active_edit can compare working-tree vs HEAD. mkfloor leaves the tree UNBORN (git init,
# no commit); the conditional-hard discriminator needs a committed baseline to tell a
# CLEAN session (no uncommitted enforce-file diff) from one under ACTIVE floor-edit.
mkfloor_committed() {
  local t
  t="$(mkfloor)"
  git -C "$t" config user.email t@example.invalid
  git -C "$t" config user.name "forge test"
  git -C "$t" add -A
  git -C "$t" commit -qm "fixture floor"
  printf '%s' "$t"
}

# run_hook <tree> <sid> [env KEY=VAL ...] — pipe the documented SessionStart stdin JSON to the hook.
run_hook() {
  local tree="$1" sid="$2"
  shift 2
  jq -nc --arg sid "$sid" --arg cwd "$tree" '{session_id: $sid, source: "startup", cwd: $cwd}' |
    env "$@" CLAUDE_PROJECT_DIR="$tree" FORGE_HARNESS_DIR="$tree/.harness" bash "$HOOK" 2>"$ERRFILE"
}

# verify <tree> <sid-or-empty> [extra env ...] — run the strict verifier in a pinned subshell.
verify() {
  local tree="$1" sid="$2"
  shift 2
  (
    if [ -n "$sid" ]; then export CLAUDE_SESSION_ID="$sid"; else unset CLAUDE_SESSION_ID; fi
    export FORGE_HARNESS_DIR="$tree/.harness" "$@"
    forge_witness_verify "$tree"
  ) 2>"$ERRFILE"
}

# gate <tree> <sid-or-empty> [extra env ...] — same pinning for the two-mode wrapper.
gate() {
  local tree="$1" sid="$2"
  shift 2
  (
    if [ -n "$sid" ]; then export CLAUDE_SESSION_ID="$sid"; else unset CLAUDE_SESSION_ID; fi
    export FORGE_HARNESS_DIR="$tree/.harness" "$@"
    forge_witness_gate "$tree"
  ) 2>"$ERRFILE"
}

# ── 1. hash determinism ──────────────────────────────────────────────────────────────────────────
T="$(mkfloor)"
H1="$(forge_floor_hash "$T")"
H2="$(forge_floor_hash "$T")"
: >"$ERRFILE"
[ -n "$H1" ] && [ "$H1" = "$H2" ]
check "floor_hash: same inputs -> same hash, twice" 0 $?

run_hook "$T" sid-determinism
check "hook: exits 0 on the happy path" 0 $?
WF="$T/.harness/session-floor.sid-determinism.json"
FH1="$(jq -r '.floor_hash // empty' "$WF" 2>/dev/null)"
rm -f "$WF"
run_hook "$T" sid-determinism
FH2="$(jq -r '.floor_hash // empty' "$WF" 2>/dev/null)"
: >"$ERRFILE"
[ -n "$FH1" ] && [ "$FH1" = "$FH2" ] && [ "$FH1" = "$H1" ]
check "hook: two runs mint the identical floor_hash (== forge_floor_hash)" 0 $?

# ── 2. witness shape ─────────────────────────────────────────────────────────────────────────────
: >"$ERRFILE"
jq -e --arg sid sid-determinism --arg cwd "$T" \
  '.session_id == $sid and .source == "startup" and .cwd == $cwd
   and (.actor | length) > 0 and (.ts | length) > 0 and (.floor_hash | length) == 64' \
  "$WF" >/dev/null 2>"$ERRFILE"
check "witness: all six fields present and bound to the session" 0 $?

# ── 3. jq normalization — whitespace edits must NOT false-drift ──────────────────────────────────
jq '.' "$T/.claude/settings.json" >"$T/.claude/settings.json.reindented" &&
  mv "$T/.claude/settings.json.reindented" "$T/.claude/settings.json"
verify "$T" sid-determinism
check "verify: settings.json re-indent (jq round-trip) is NOT drift" 0 $?

# ── 4. verified floor passes hard mode too (positive two-mode control) ───────────────────────────
gate "$T" sid-determinism FORGE_UNATTENDED=1
check "gate: FORGE_UNATTENDED=1 + verified witness -> 0" 0 $?

# ── 5. drift — mutate a COPY of pre-tool-use-deny.sh in the throwaway tree ───────────────────────
printf '\n# drift: one appended byte changes the floor\n' >>"$T/.claude/hooks/pre-tool-use-deny.sh"
verify "$T" sid-determinism
check "verify: deny-hook mutation -> witness-refused-floor-drift (named)" 1 $? witness-refused-floor-drift

# ── 6. absence — no sentinel for the session id ──────────────────────────────────────────────────
T2="$(mkfloor)"
verify "$T2" sid-never-witnessed
check "verify: no witness for this session -> witness-refused-absent (named)" 1 $? witness-refused-absent

# ── 7. session binding — a sentinel for a DIFFERENT session id does not satisfy ──────────────────
run_hook "$T2" sid-aaa
verify "$T2" sid-bbb
check "verify: witness for sid-aaa does not satisfy sid-bbb (per-session, not existence)" 1 $? witness-refused-absent

# ── 8. session mismatch defense beyond the filename ──────────────────────────────────────────────
jq '.session_id = "sid-tampered"' "$T2/.harness/session-floor.sid-aaa.json" >"$T2/.harness/tmp.json" &&
  mv "$T2/.harness/tmp.json" "$T2/.harness/session-floor.sid-aaa.json"
verify "$T2" sid-aaa
check "verify: recorded session_id != filename sid -> witness-refused-session-mismatch" 1 $? witness-refused-session-mismatch

# ── 9. unreadable witness ────────────────────────────────────────────────────────────────────────
printf '{"session_id":"sid-nohash"}' >"$T2/.harness/session-floor.sid-nohash.json"
verify "$T2" sid-nohash
check "verify: witness without floor_hash -> witness-refused-unreadable" 1 $? witness-refused-unreadable

# ── 10. no session id — fail closed ──────────────────────────────────────────────────────────────
verify "$T2" ""
check "verify: CLAUDE_SESSION_ID unset -> witness-refused-no-session-id" 1 $? witness-refused-no-session-id

# ── 11. R1(ii) — settings.local.json carrying hooks.PreToolUse blocks the witness ────────────────
T3="$(mkfloor)"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"evil.sh"}]}]}}' \
  >"$T3/.claude/settings.local.json"
run_hook "$T3" sid-r1ii
RC=$?
[ "$RC" = "0" ] && [ ! -f "$T3/.harness/session-floor.sid-r1ii.json" ] &&
  grep -qF witness-not-written-r1ii-local-pretooluse "$ERRFILE"
check "hook: R1(ii) local PreToolUse -> exit 0, NO witness, loud named refusal" 0 $?

# ── 12. R1(ii) companion — a permissions-only settings.local.json (the real clone's shape) is fine
printf '{"permissions":{"allow":["Bash(echo ok)"]}}' >"$T3/.claude/settings.local.json"
run_hook "$T3" sid-r1ii-ok
RC=$?
: >"$ERRFILE"
[ "$RC" = "0" ] && [ -f "$T3/.harness/session-floor.sid-r1ii-ok.json" ]
check "hook: permissions-only settings.local.json -> witness IS written" 0 $?

# ── 13. two-mode — FORGE_UNATTENDED=1 + no witness -> nonzero; unset -> warn + zero ──────────────
T4="$(mkfloor)"
gate "$T4" sid-unwitnessed FORGE_UNATTENDED=1
check "gate: FORGE_UNATTENDED=1 + no witness -> 1 (HARD REFUSAL)" 1 $? "HARD REFUSAL"
gate "$T4" sid-unwitnessed
# Conditional-hard: a NEVER-witnessed checkout (no prior session-floor.* for this root)
# degrades gracefully to WARN attended (forge_root_ever_witnessed is false -> the clean-drift HARD arm is not
# reached). rc 0 unchanged from the old warn-only; only the message text changed ("(attended mode)" dropped).
# The HARD arm (a witness-ENABLED clean session that drifts) is exercised by the conditional-hard cases below.
check "gate: attended + never-witnessed -> 0 with loud WARNING (graceful degrade)" 0 $? "WARNING (attended)"

# ── 14. install-guarantee (commit-guard hooks-path tier) — FIRST suite coverage of the witness
#    hooks-path tier. On a floor tree LACKING the core.hooksPath install, forge_hookspath_ok fails and the
#    hook MUST refuse: exit 0, NO witness written, loud named refusal — so privileged ops fail-closed on
#    the absence. RED-first: a witness lacking forge_hookspath_ok (the pre-install-guarantee shape, e.g. the
#    retired candidate shim) MINTS here instead of refusing, so this case is non-vacuous.
TNH="$(mkfloor_no_hookspath)"
run_hook "$TNH" sid-no-hookspath
RC=$?
[ "$RC" = "0" ] && [ ! -f "$TNH/.harness/session-floor.sid-no-hookspath.json" ] &&
  grep -qF witness-not-written-hookspath-uninstalled "$ERRFILE"
check "hook: hooks-path uninstalled -> exit 0, NO witness, named refusal (install-guarantee, RED-first)" 0 $?

# ── 15. CLAUDE_ENV_FILE export (the probe-proven env-file pattern) ──────────────────────────────
ENVF="$(mktemp)"
run_hook "$T4" sid-envfile CLAUDE_ENV_FILE="$ENVF"
RC=$?
[ "$RC" = "0" ] && grep -qF "export CLAUDE_SESSION_ID='sid-envfile'" "$ENVF"
check "hook: CLAUDE_ENV_FILE gains export CLAUDE_SESSION_ID=<sid>" 0 $?
rm -f "$ENVF"

# ── 16. sid injection — a traversal-shaped session_id must never become a path ───────────────────
T5="$(mkfloor)"
run_hook "$T5" "../evil"
RC=$?
[ "$RC" = "0" ] && [ -z "$(find "$T5/.harness" -name 'session-floor.*' -print -quit 2>/dev/null)" ] &&
  [ ! -e "$T5/session-floor...-evil.json" ] && [ ! -e "$T5/evil.json" ] &&
  grep -qF witness-not-written-bad-session-id "$ERRFILE"
check "hook: session_id '../evil' -> exit 0, nothing written, named refusal" 0 $?
verify "$T5" "sid spaced"
check "verify: malformed CLAUDE_SESSION_ID -> witness-refused-bad-session-id" 1 $? witness-refused-bad-session-id

# sid charset is a WHOLE-STRING property: a multiline sid whose one clean line would satisfy a
# per-line `grep -Eq '^…$'` must still be REJECTED — else a single-quote-bearing newline sid breaks
# out of the single-quoted CLAUDE_ENV_FILE export (proven RCE on the pre-fix validator).
NL_SID="$(printf "%s\nclean" "';export RCE_PROOF=pwned;'")"
: >"$ERRFILE"
forge_witness_sid_ok "$NL_SID"
check "sid_ok: quote+newline sid is REJECTED (no per-line grep bypass)" 1 $?
ENVF5="$(mktemp)"
run_hook "$T5" "$NL_SID" CLAUDE_ENV_FILE="$ENVF5"
RC=$?
[ "$RC" = "0" ] && ! grep -qF 'RCE_PROOF' "$ENVF5" &&
  grep -qF witness-not-written-bad-session-id "$ERRFILE"
check "hook: quote+newline sid -> exit 0, no env-file injection, named refusal" 0 $?
rm -f "$ENVF5"

# ── 17. missing floor input fails closed (no partial hash) ───────────────────────────────────────
T6="$(mkfloor)"
rm -f "$T6/.claude/hooks/lib.sh"
: >"$ERRFILE"
forge_floor_hash "$T6" >/dev/null 2>"$ERRFILE"
check "floor_hash: missing lib.sh -> rc 1 (never a partial-floor hash)" 1 $?
run_hook "$T6" sid-nofloor
RC=$?
[ "$RC" = "0" ] && [ ! -f "$T6/.harness/session-floor.sid-nofloor.json" ] &&
  grep -qF witness-not-written-floor-unhashable "$ERRFILE"
check "hook: unhashable floor -> exit 0, NO witness, named refusal" 0 $?

# ── 18. witness hardening: forge_floor_under_active_edit — the discriminator predicate, fail-closed-TOTAL.
#    0 = active edit (uncommitted enforce-file diff -> WARN, do not brick floor-dev); 1 = NOT active (clean,
#    not-a-git-repo, OR any git ERROR -> the gate is hard-eligible). The `case $?` form makes a git-diff error
#    (unborn / unresolvable HEAD / rc-128) fail-CLOSED to 1, not fall through to 0 — the contract is total.
TPC="$(mkfloor_committed)"
: >"$ERRFILE"; forge_floor_under_active_edit "$TPC"
check "active-edit predicate: committed-clean floor -> NOT active (rc1, hard-eligible)" 1 $?
printf '\n# active edit\n' >>"$TPC/.claude/hooks/lib.sh"
: >"$ERRFILE"; forge_floor_under_active_edit "$TPC"
check "active-edit predicate: uncommitted enforce-file diff -> active (rc0, warn)" 0 $?
TPU="$(mkfloor)" # mkfloor is UNBORN (git init, NO commit) -> git diff --quiet HEAD errors (rc 128)
: >"$ERRFILE"; forge_floor_under_active_edit "$TPU"
check "active-edit predicate: unborn/no-HEAD git error -> FAIL-CLOSED NOT active (rc1)" 1 $?
TPN="$(mktemp -d)"; TREES+=("$TPN") # not a git repo at all
: >"$ERRFILE"; forge_floor_under_active_edit "$TPN"
check "active-edit predicate: not-a-git-repo -> fail-closed NOT active (rc1)" 1 $?

# ── 19. witness hardening: forge_witness_gate CONDITIONAL-HARD — the boundary fires on an UNSANCTIONED
#    clean-session drift (attended), but WARNS while the floor is under ACTIVE edit (sanctioned mid-session
#    dev). The discriminator is the uncommitted-enforce-file-diff, NOT a cosmetic attended/unattended split.
#    Drift is forced by a witness recording a wrong hash (a real floor-disable that drifts; the .harness file
#    is untracked so it never itself counts as an enforce-file edit).
TG="$(mkfloor_committed)"
printf '{"session_id":"sid-cd","floor_hash":"deadbeef-not-the-live-hash"}' >"$TG/.harness/session-floor.sid-cd.json"
gate "$TG" sid-cd
check "gate: committed-CLEAN witness-enabled + drift (attended) -> HARD (boundary fires)" 1 $? "HARD REFUSAL (attended, clean witness-enabled session)"
printf '\n# active edit\n' >>"$TG/.claude/hooks/lib.sh" # now an uncommitted enforce-file diff
gate "$TG" sid-cd
check "gate: floor under ACTIVE edit + drift (attended) -> WARN (do not brick floor-dev)" 0 $? "WARNING (attended)"
gate "$TG" sid-cd FORGE_UNATTENDED=1
check "gate: ACTIVE edit + drift UNATTENDED -> HARD (discriminator does not apply unattended)" 1 $? "HARD REFUSAL"
# unborn + drift -> attended HARD: the fail-closed-total predicate makes the gate fire even on a git error.
TGU="$(mkfloor)"
printf '{"session_id":"sid-u","floor_hash":"deadbeef-not-the-live-hash"}' >"$TGU/.harness/session-floor.sid-u.json"
gate "$TGU" sid-u
check "gate: unborn/git-error + drift (attended) -> HARD (fail-closed-total, no warn fall-through)" 1 $? "HARD REFUSAL (attended, clean witness-enabled session)"

# ── 20. witness hardening: hash-coverage fold — the mint script AND the SessionStart stanza are now
#    SELF-VERIFIED inputs (editing either MOVES the floor hash -> drift-detectable), closing the asymmetry
#    where they were floor-protected but not hashed. A MISSING mint script makes the floor unhashable (fail-closed).
TH="$(mkfloor)"
H0="$(forge_floor_hash "$TH")"
printf '\n# tamper the mint logic\n' >>"$TH/.claude/hooks/session-start-witness.sh"
H1="$(forge_floor_hash "$TH")"
: >"$ERRFILE"; [ -n "$H0" ] && [ -n "$H1" ] && [ "$H0" != "$H1" ]
check "hash-fold: editing the mint script (session-start-witness.sh) MOVES the floor hash" 0 $?
TH2="$(mkfloor)"
HA="$(forge_floor_hash "$TH2")"
jq '.hooks.SessionStart = [{"hooks":[{"type":"command","command":"evil.sh"}]}]' "$TH2/.claude/settings.json" \
  >"$TH2/.claude/settings.json.t" && mv "$TH2/.claude/settings.json.t" "$TH2/.claude/settings.json"
HB="$(forge_floor_hash "$TH2")"
: >"$ERRFILE"; [ -n "$HA" ] && [ -n "$HB" ] && [ "$HA" != "$HB" ]
check "hash-fold: editing the SessionStart stanza MOVES the floor hash" 0 $?
TH3="$(mkfloor)"
rm -f "$TH3/.claude/hooks/session-start-witness.sh"
: >"$ERRFILE"; forge_floor_hash "$TH3" >/dev/null 2>"$ERRFILE"
check "hash-fold: missing session-start-witness.sh -> rc1 (unhashable, fail-closed; now a required input)" 1 $?

echo
echo "witness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
