#!/usr/bin/env bash
# agentic-builder-forge — Stop gate for INTAKE. SEPARATE from stop-gate-tests.sh (which red→green-gates
# builds). While an intake is active AND pre-ratification (phase=open), the Architect cannot declare the
# spec "done" until it satisfies the deterministic F1 clarify floor (+ a lean coverage sweep).
#
# CARRIER-INDEPENDENT: this floor is the F1 GUARANTEE and holds with the AskUserQuestion clarify-gate
# ENTIRELY ABSENT — the guarantee never rests on that (canary-gated) enhancement. Proven by the
# "F1-via-Stop-floor-ALONE" fixtures in tests/hooks/run.sh.
#
# [The Gate-A floor EXTENDS this: understanding.md content invariants + restatement consensus
#  (0 open DISAGREE) OR a non-empty ## UNRECONCILED — layered on top of the clarify/coverage floor.]
#
# Deployed at .claude/hooks/ (enforce-protected; human-spliced under FORGE_ALLOW_HOOK_EDIT=1) —
# sources "$DIR/lib.sh" (the deployed .claude/hooks/lib.sh, exposing forge_intake_*).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
forge_read_input

# Backstop: never re-block an already-active stop loop.
[ "$(forge_json '.stop_hook_active')" = "true" ] && exit 0
# Only gate while an intake is active AND still open (pre-ratification). Inert otherwise (and inert for
# builds — that is stop-gate-tests.sh's job, keyed on the SEPARATE active-task.json sentinel).
forge_intake_active || exit 0
[ "$(forge_intake_phase 2>/dev/null)" = "open" ] || exit 0

sentinel="$(forge_intake_sentinel 2>/dev/null)"
spec="$(jq -r '.spec // empty' "$sentinel" 2>/dev/null)"
mode="$(jq -r '.mode // "interactive"' "$sentinel" 2>/dev/null)"
budget="$(jq -r '.clarify_rounds // 5' "$sentinel" 2>/dev/null)"
case "$budget" in '' | *[!0-9]*) budget=5 ;; esac
restate_budget="$(jq -r '.restate_rounds // 3' "$sentinel" 2>/dev/null)"
case "$restate_budget" in '' | *[!0-9]*) restate_budget=3 ;; esac

# ── Determine the floor verdict (fail-closed: any unreadable input blocks, never silently passes) ──────
fail=""
# risk_halt discriminates a CATASTROPHIC-sweep fail (set ONLY in that sweep, below) from a
# Gate-A / F1 fail, so the autonomous surface-and-release arm in the runaway tail fires for catastrophic gaps
# ONLY — never converting a protected Gate-A failure into a release (the shared-runaway-tail trap #2).
risk_halt=""
if [ -z "$spec" ] || [ ! -f "$spec" ]; then
  fail="the intake sentinel names no readable spec ($spec) — cannot verify the clarify floor"
else
  rounds="$(grep -cE '^### Round ' "$spec" 2>/dev/null || printf 0)"
  case "$rounds" in '' | *[!0-9]*) rounds=0 ;; esac
  # Grant-asymmetry fix: a human grant (`intake.sh clarify`) lifts the round ceiling for the
  # real-time clarify-gate (pre-tool-use-clarify-gate.sh:54-57). The Stop floor MUST honor the SAME grant
  # the SAME way, reading the SAME .harness/intake-clarify-grant counter via forge_harness_dir — otherwise a
  # granted round wedges this floor until the runaway cap releases, and the F1.3 message below advertises
  # `intake.sh clarify` as a remedy it would then ignore. Read here (before F1.3) so the budget arm honors it.
  ghd="$(forge_harness_dir 2>/dev/null)"
  grant=0
  [ -n "$ghd" ] && [ -f "$ghd/intake-clarify-grant" ] && grant="$(cat "$ghd/intake-clarify-grant" 2>/dev/null || printf 0)"
  case "$grant" in '' | *[!0-9]*) grant=0 ;; esac
  # F1.1 — zero residual [NEEDS CLARIFICATION]: every ambiguity must be RESOLVED (answered) or ROUTED
  #        (a flagged [ASSUMED] in ## Assumptions). A leftover marker is an unrouted ambiguity.
  if grep -qF '[NEEDS CLARIFICATION' "$spec"; then
    fail="an unresolved [NEEDS CLARIFICATION] marker remains — answer it in ## Clarifications or route it to a flagged [ASSUMED ...] in ## Assumptions (F1: route, never drop)"
  # F1.2 — autonomous → zero asked rounds: no human is present, so every ambiguity must become an [ASSUMED].
  elif [ "$mode" = autonomous ] && [ "$rounds" -gt 0 ]; then
    fail="Mode is autonomous but ## Clarifications records $rounds asked round(s) — autonomous must route every ambiguity to [ASSUMED], never ask a human"
  # F1.3 — recorded rounds ≤ budget (+ human grant): the degraded round budget (this is what bounds
  #        questioning when the real-time AskUserQuestion clarify-gate is absent / the canary failed). A
  #        human grant lifts the ceiling exactly as it does for the clarify-gate (the grant-asymmetry fix).
  elif [ "$rounds" -gt "$((budget + grant))" ]; then
    fail="## Clarifications records $rounds rounds, over the budget of $budget (+$grant granted) — route the remaining ambiguities to flagged [ASSUMED ...] (a human may grant another round via: intake.sh clarify <spec>)"
  # Coverage sweep (lean): the load-bearing sections must each carry content, and the F7 negative-space
  # surface must exist so the human can ratify omissions at Gate A.
  elif ! grep -qE '^### US[0-9]' "$spec"; then
    fail="## User Scenarios has no US story — an objective with zero prioritized stories is an elicitation gap"
  elif ! grep -qE '(^|[^A-Za-z])FR-[0-9]{3}([^0-9]|$)' "$spec"; then
    fail="## Requirements has no FR-NNN — author the functional requirements before declaring the spec ready"
  elif ! grep -qE '(^|[^A-Za-z])SC-[0-9]{3}([^0-9]|$)' "$spec"; then
    fail="## Success Criteria has no SC-NNN — every objective needs at least one measurable success criterion"
  elif ! grep -qE '^## Deferrals' "$spec"; then
    fail="the F7 ## Deferrals / Out of scope section is missing — list the categories consciously skipped or N/A so the human can ratify the omissions at Gate A"
  fi

  # B+C — the F1 per-category VISIBILITY floor (G1/G2). A clone of cmd_analyze's enumerate-declared-set +
  # bidirectional string cross-reference (intake.sh cmd_analyze: "no LLM judgment anywhere"), here over
  # canonical-category <-> disposition instead of FR <-> task. Runs ONLY after the lean coverage floor is
  # clean (so it cannot mask a missing-FR/US gap). EVERY canonical category (the enum) must carry an F2
  # disposition in the consolidated ## Deferrals ledger; and EVERY ledger slug must be a canonical id (both
  # directions, like cmd_analyze). This is PRESENCE, never ADEQUACY — a `deliberately N/A` line satisfies it
  # BY DESIGN: the value is forced VISIBILITY for the human at Gate A; the spec-reviewer (advisory) + the
  # human (ratify) judge whether each disposition's CLAIM is true. No LLM on this blocking edge. Fail-closed
  # if the enum is unreadable. The enum path honors FORGE_INTAKE_CATEGORIES (test
  # override), else the deployed harness/intake-categories.json resolved from the main root.
  if [ -z "$fail" ]; then
    catsf="${FORGE_INTAKE_CATEGORIES:-$(forge_main_root 2>/dev/null)/harness/intake-categories.json}"
    declared="$(jq -r '.categories[].id' "$catsf" 2>/dev/null | sort -u)"
    if [ -z "$declared" ]; then
      fail="the canonical coverage taxonomy ($catsf) is missing or unreadable — cannot verify the per-category visibility floor (fail closed)"
    else
      # the consolidated ledger = the ## Deferrals block (up to the next '## ' heading).
      ledger="$(awk '/^## Deferrals/{f=1;next} /^## /{f=0} f' "$spec")"
      # ids that carry a real F2 disposition: a line `- ` + a backtick-wrapped canonical id + a disposition
      # keyword (covered by | deliberately N/A | surfaced). The leading-backtick anchor makes the id exact
      # (no slug is a substring of another), and the keyword requirement is what makes a bare placeholder NOT
      # count — a content-free `deliberately N/A — <reason>` DOES count (presence, not adequacy).
      dispositioned="$(printf '%s\n' "$ledger" | grep -E '(covered by|deliberately N/A|surfaced)' | sed -nE 's/^- `([a-z0-9]+(-[a-z0-9]+)*)`.*/\1/p' | sort -u)"
      # forward (uncovered): a canonical category with no disposition line is a SILENT OMISSION -> block.
      missing="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$dispositioned") | grep -m1 . || true)"
      # reverse (dangling): a ledger slug that is not a canonical id is a typo/miscategorization -> block.
      bogus="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$dispositioned") | grep -m1 . || true)"
      if [ -n "$missing" ]; then
        fail="the ## Deferrals coverage ledger has no disposition for canonical category '$missing' — every taxonomy category must appear once as \`<id>\` — covered by FR-NNN | deliberately N/A — <reason> | surfaced — <ref> (F1 visibility floor: presence, not adequacy; the human ratifies the claim at Gate A)"
      elif [ -n "$bogus" ]; then
        fail="the ## Deferrals ledger dispositions '$bogus', which is not a canonical category id ($catsf) — fix the slug to a taxonomy id, or it is a silent miscategorization (F1 visibility floor)"
      fi
    fi
  fi

  # B+C — the CATASTROPHIC-tier Stop nudge (G3 mirror). A category in THIS intake's catastrophic set —
  # human-assigned via `intake.sh risk` (the sentinel's .risk.catastrophic), else the registry by-default tier
  # from the enum (so the floor is active even before any risk assignment) — cannot be merely waved off as
  # `deliberately N/A`: it must be covered or surfaced. This checks the disposition TOKEN-TYPE (covered/surfaced
  # vs N/A), NEVER adequacy — it never judges whether the coverage is GOOD. Ratify-BYPASSABLE here BY DESIGN
  # (this Stop nudge matches today's coverage-sweep posture); the UN-bypassable copy lives at
  # cmd_ratify (G3), which a terminal-side ratify cannot skip. Reuses $catsf/$ledger from the sweep above
  # (both set whenever this block is reached, i.e. the sweep ran clean).
  if [ -z "$fail" ]; then
    cat_set="$(jq -r '.risk.catastrophic[]?' "$sentinel" 2>/dev/null)"
    [ -z "$cat_set" ] && cat_set="$(jq -r '.categories[]? | select(.risk_default=="by-default") | .id' "$catsf" 2>/dev/null)"
    while IFS= read -r cc; do
      [ -n "$cc" ] || continue
      if ! printf '%s\n' "$ledger" | awk -F' — ' -v cc="$cc" '$1 == "- `" cc "`" {print $2}' | grep -qE '(covered by|surfaced)'; then
        fail="catastrophic category '$cc' is mission-critical for this intake but its ## Deferrals disposition is not covered/surfaced (waved off as 'deliberately N/A') — cover it (covered by FR-NNN) or surface it (surfaced — <ref>); to consciously de-escalate it, a human runs: intake.sh risk --remove $cc (B+C catastrophic floor: token-TYPE, not adequacy; the un-bypassable copy is at ratify)"
        risk_halt=1 # mark this as a catastrophic-sweep fail (drives the autonomous surface-and-release arm)
        break
      fi
    done <<EOF
$cat_set
EOF
  fi

  # Gate-A floor: runs ONLY after the F1 clarify + coverage floor is clean. The two-party
  # restatement (spec-reviewer <-> Architect) must have CONVERGED — consensus is mechanical: zero open
  # DISAGREE/ESCALATE findings in restatement.md — OR surfaced its unreconciled gaps to the human in a
  # non-empty ## UNRECONCILED block. understanding.md must project the FR set (a touch-stub does not pass).
  if [ -z "$fail" ]; then
    specdir="$(dirname "$spec")"
    und="$specdir/understanding.md"
    rst="$specdir/restatement.md"
    if [ ! -f "$und" ]; then
      fail="Gate A: understanding.md is missing — run the restatement loop (spawn the spec-reviewer, reconcile each finding, regenerate the projection at $und)"
    elif ! grep -qE '^## What the FRs will build' "$und"; then
      fail="Gate A: understanding.md lacks its '## What the FRs will build' projection — it must project what the completed FR set builds (a touch-stub does not pass)"
    else
      # Consensus reads the HARNESS-CAPTURED spec-review record, NOT the Architect-transcribed
      # restatement.md (under-transcription could fake the count to 0 — the closed transcription trap).
      # `intake.sh spec-review` spawns the spec-reviewer as a read-only backend, owns its stdout, and writes
      # .harness/intake-spec-review.json (agent-tool-unwritable via ENFORCE_RE) — the Architect picks WHEN,
      # cannot fake the RESULT. open = the record's open-findings count. Record ABSENT => open=0 (same allow as
      # the rst-absent path before — the ≥1-review evidence is enforced at cmd_ratify, the C7 asymmetry).
      # restatement.md persists as the reconcile narrative (D2) and still bounds the loop via its round-count
      # below; it is no longer the consensus oracle. ONLY the open-count SOURCE moves; UNRECONCILED + the
      # restate_budget arm stay byte-intact.
      open=0
      srec="$(forge_harness_dir 2>/dev/null)/intake-spec-review.json"
      # Anti-TOCTOU: a record that reviewed an OLDER spec is STALE — it must NOT yield open=0 (false
      # consensus). On a spec_sha256 mismatch, FAIL (re-run spec-review); mirrors convert's drift-refusal. fail
      # set here + the open==0 consensus arm below as a no-op => the runaway tail blocks; the UNRECONCILED +
      # restate_budget arms stay byte-intact (only the open-count SOURCE + this staleness guard are new).
      if [ -f "$srec" ]; then
        rsha="$(jq -r '.spec_sha256 // empty' "$srec" 2>/dev/null)"
        if [ -n "$rsha" ] && [ "$rsha" != "$(sha256sum "$spec" 2>/dev/null | cut -d' ' -f1)" ]; then
          fail="Gate A: the spec-review record is STALE — it reviewed an older spec (record sha != current); the spec changed since the review. Re-run: intake.sh spec-review (anti-TOCTOU; mirrors convert's drift-refusal)"
        else
          open="$(jq '(.findings // []) | length' "$srec" 2>/dev/null)"
        fi
      fi
      case "$open" in '' | *[!0-9]*) open=0 ;; esac
      if [ "$open" -eq 0 ]; then
        : # consensus reached (open-DISAGREE == 0) — allow
      elif awk '/^## UNRECONCILED/{u=1;next} /^## /{u=0} u && NF && $0 !~ /^[[:space:]]*<!--/ {f=1} END{exit f?0:1}' "$und"; then
        : # the fail-closed ## UNRECONCILED surface is present and non-empty — allow (the human adjudicates)
      else
        restate_rounds=0
        [ -f "$rst" ] && restate_rounds="$(grep -cE '^### Restatement round ' "$rst" 2>/dev/null)"
        case "$restate_rounds" in '' | *[!0-9]*) restate_rounds=0 ;; esac
        if [ "$restate_rounds" -ge "$restate_budget" ]; then
          fail="Gate A: $restate_rounds restatement rounds with $open finding(s) still open and no ## UNRECONCILED — write a NON-EMPTY '## UNRECONCILED — human input needed' block in understanding.md listing the open findings (consensus is open-DISAGREE==0; it cannot be fabricated)"
        else
          fail="Gate A: $open open DISAGREE/ESCALATE finding(s) remain — reconcile each (edit the spec, or add a reconcile-note and re-run the spec-reviewer to ACCEPT/ESCALATE), or surface ## UNRECONCILED in understanding.md"
        fi
      fi
    fi
  fi
fi

# ── Counter + runaway backstop (mirrors stop-gate-tests.sh:27-44) ──────────────────────────────────────
hd="$(forge_harness_dir 2>/dev/null)"
cntf="$hd/intake-stop-blocks"
if [ -z "$fail" ]; then
  [ -n "$hd" ] && rm -f "$cntf" 2>/dev/null # floor satisfied: reset, allow Stop (hand off to the human to ratify)
  exit 0
fi
# AUTONOMOUS surface-and-release: a catastrophic-tier gap (risk_halt) in autonomous mode
# cannot be fixed by an absent human, and there is NO intake-side wall-clock reaper (the build gate's
# never-release is safe only because stop-gate-tests.sh's reaper reaps the wedge; intake has none — confirmed),
# so blocking would wedge forever. Surface it LOUDLY and RELEASE immediately — the mandatory human-ratify
# bookend (cmd_ratify's G3, which the agent cannot mint) is the real gate. Keyed on risk_halt (set ONLY by the
# catastrophic sweep) so a Gate-A / F1 fail in autonomous mode is NOT released here — it keeps the normal
# block + cap below (the shared-runaway-tail trap #2). NEVER never-release.
if [ "$mode" = autonomous ] && [ "$risk_halt" = "1" ]; then
  printf 'agentic-builder-forge: intake (autonomous): %s\n  Surfacing for the mandatory human ratify (intake.sh ratify enforces the catastrophic floor at Gate A) and RELEASING the Stop gate — no autonomous wedge, never never-release; record it in a non-empty ## UNRECONCILED for the human.\n' "$fail" >&2
  [ -n "$hd" ] && rm -f "$cntf" 2>/dev/null
  exit 0
fi
cnt=0
[ -f "$cntf" ] && cnt="$(cat "$cntf" 2>/dev/null || printf 0)"
cnt=$((cnt + 1))
[ -n "$hd" ] && { mkdir -p "$hd" 2>/dev/null; printf '%s' "$cnt" >"$cntf" 2>/dev/null; }
cap="${FORGE_INTAKE_BLOCK_CAP:-8}"
if [ "$cnt" -ge "$cap" ]; then
  printf 'agentic-builder-forge: intake clarify floor still unmet after %s attempts — releasing the Stop gate; human intervention needed.\n' "$cnt" >&2
  [ -n "$hd" ] && rm -f "$cntf" 2>/dev/null
  exit 0
fi
forge_block "intake clarify floor (attempt $cnt/$cap): $fail"
