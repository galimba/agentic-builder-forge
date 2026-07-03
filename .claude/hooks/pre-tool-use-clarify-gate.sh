#!/usr/bin/env bash
# agentic-builder-forge — PreToolUse clarify round-gate. matcher: AskUserQuestion.
#
# REAL-TIME ENHANCEMENT only. Wired into settings.json ONLY because a live canary PASSED
# (AskUserQuestion is PreToolUse-hookable + deniable — verified live). It is NEVER load-bearing for
# the F1 guarantee: that lives in stop-gate-intake.sh and holds with this hook absent. This hook adds the
# per-ask deny that a Stop floor can only do post-hoc — round budget, per-call question cap,
# autonomous-no-ask, and ask↔record coupling. Passthrough whenever an intake is not active.
#
# Deployed at .claude/hooks/ (enforce-protected; human-spliced under FORGE_ALLOW_HOOK_EDIT=1) —
# sources "$DIR/lib.sh" (the deployed lib.sh).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
forge_read_input

# Only AskUserQuestion, and only during an active intake — otherwise this is invisible (allow).
[ "$(forge_json '.tool_name')" = "AskUserQuestion" ] || exit 0
forge_intake_active || exit 0

sentinel="$(forge_intake_sentinel 2>/dev/null)"
mode="$(jq -r '.mode // "interactive"' "$sentinel" 2>/dev/null)"
spec="$(jq -r '.spec // empty' "$sentinel" 2>/dev/null)"
budget="$(jq -r '.clarify_rounds // 5' "$sentinel" 2>/dev/null)"
maxq="$(jq -r '.clarify_max_q // 4' "$sentinel" 2>/dev/null)"
case "$budget" in '' | *[!0-9]*) budget=5 ;; esac
case "$maxq" in '' | *[!0-9]*) maxq=4 ;; esac

# (a) autonomous: no human present → never ask. Route to a flagged [ASSUMED]. Also forecloses the
#     headless-ask-hang (an unattended session that calls AskUserQuestion would block forever).
[ "$mode" = autonomous ] && forge_deny "Mode is autonomous — no human is present to answer. Route this ambiguity to a flagged [ASSUMED ...] in ## Assumptions (F1: route, never drop); do not call AskUserQuestion."

# (b) per-call question cap (defensive — the AskUserQuestion tool itself caps questions at 4).
qlen="$(forge_json '.tool_input.questions | length')"
case "$qlen" in '' | *[!0-9]*) qlen=0 ;; esac
[ "$qlen" -gt "$maxq" ] && forge_deny "this AskUserQuestion carries $qlen questions (> $maxq) — ask fewer, higher-leverage questions per round."

hd="$(forge_harness_dir 2>/dev/null)"
cntf="$hd/intake-clarify-rounds"
grantf="$hd/intake-clarify-grant"
asked=0
[ -f "$cntf" ] && asked="$(cat "$cntf" 2>/dev/null || printf 0)"
case "$asked" in '' | *[!0-9]*) asked=0 ;; esac

# (c) ask↔record coupling: the prior round's answers must be logged in ## Clarifications (a "### Round N"
#     entry) before the next ask. Deny until asked == recorded.
recorded=0
[ -n "$spec" ] && [ -f "$spec" ] && recorded="$(grep -cE '^### Round ' "$spec" 2>/dev/null || printf 0)"
case "$recorded" in '' | *[!0-9]*) recorded=0 ;; esac
[ "$asked" -gt "$recorded" ] && forge_deny "the previous clarify round is unlogged ($asked asked, $recorded recorded) — write its Q&A into ## Clarifications as '### Round $asked — <date>' and propagate it into the live FR/SC/story text before asking again (ask↔record coupling)."

# (d) round budget: deny the (budget+1)-th agent-initiated round. A human grant lifts the ceiling
#     (intake.sh clarify), so intent-clarity can always loop — even at zero remaining.
grant=0
[ -f "$grantf" ] && grant="$(cat "$grantf" 2>/dev/null || printf 0)"
case "$grant" in '' | *[!0-9]*) grant=0 ;; esac
[ "$asked" -ge "$((budget + grant))" ] && forge_deny "clarify budget exhausted ($asked/$budget rounds). Route the remaining ambiguities to flagged [ASSUMED ...] in ## Assumptions (F1: NO cap on assumptions). A human may grant another round with: intake.sh clarify <spec>"

# Within budget, coupled, interactive → ALLOW, and record this round in the asked counter.
[ -n "$hd" ] && { mkdir -p "$hd" 2>/dev/null; printf '%s' "$((asked + 1))" >"$cntf" 2>/dev/null; }
exit 0
