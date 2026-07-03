#!/usr/bin/env bash
# harness/accept-gate.sh — the deterministic per-bead acceptance gate (cp-mechgate).
#
# Discharges R-7 (a mechanical per-bead gate: diff⊆scope, dod_tests pass, sc_evidence present),
# R-8 (never hangs, never prompts, never reads stdin; every abnormal outcome — internal error,
# jq failure, missing input, timeout — maps to FAIL with a named reason), and R-15; implements
# the mechanical half of PROBE-G. Pure bash + git + jq + timeout. NO LLM anywhere in the verdict
# path. Exit 0 = PASS (or PASS-LEGACY under the audited R-C knob), exit 1 = FAIL.
#
# Deployed enforcement-protected file: agent edits are floor-denied; changes are authored as sandbox/
# candidates and human-spliced under FORGE_ALLOW_HOOK_EDIT=1. Runs from <root>/harness/ ONLY: the
# $HERE-relative sourcing below ($HERE/../.claude/hooks/lib.sh, $HERE/beads-lib.sh) resolves only
# when this script sits at <root>/harness/ — tests/mechgate/run.sh copies it into a throwaway
# harness to exercise it.
#
#   accept-gate.sh --bead <id> --worktree <path> --base-sha <sha> --mode staged
#   accept-gate.sh --bead <id> --worktree <path> --base-sha <sha> --mode rescope
#                  (Finding 1: FULL re-verify — C0+C1+C2+C3+integrity vs the CURRENT index, identical
#                  to --mode staged in WHICH CHECKS RUN; cmd_finish re-invokes it as the immediately-
#                  pre-commit statement to close the post-gate TOCTOU. The ONLY rescope-specific
#                  behavior is the one harness-staged path .beads/issues.jsonl ledger exemption.)
#   accept-gate.sh --bead <id> --worktree <path> --base-sha <sha> --mode range --range <A..B>
#                  (verdicts a task's diff sourced from HISTORY, A..B = base_sha..task_tip,
#                  with the SAME C0-C3 + integrity checks; the range is validated to be EXACTLY two
#                  resolvable hex commits joined by '..'. Single-bead by construction.)
#
# Contract source (R-E, dual-source cross-check):
#   ANCHOR = the spec's task block, located via bead metadata.source_spec + task_id (validated
#            pointers), re-extracted with the SAME awk extractor intake.sh cmd_analyze uses, and
#            re-validated against the invariant-7/8/9 grammar (jq ordered type-before-use so no
#            branch can error-and-empty a variable and fail OPEN — the forbidden class).
#   CACHE  = bead metadata.accept (minted by intake.sh cmd_convert, R-B).
#   The cross-check verdict is canonical-VALUE equality (R-F: jq '$a == $c' — type-aware, never a
#   string compare); drift → FAIL contract-drift, with the jq -S sha256s of BOTH forms recorded in
#   the audit purely as evidence. ENFORCEMENT (C1–C3) reads the ANCHOR only — the cache is a
#   tamper detector, never an input to the checks.
#   R-C (amendment A3) + DR-2: the legacy trigger is metadata.accept ABSENT AND NO convert residue.
#   convert mints {target_repo, source_spec, task_id, accept}; `--unset-metadata accept` removes only
#   accept, so any surviving source_spec/task_id/target_repo proves a contract existed →
#   FAIL contract-stripped (the knob CANNOT launder it). DR-2 fail-closed: SCALAR or array
#   metadata is a malformed contract, never a genuine pre-contract bead → contract-stripped too, so the
#   gate no longer leans on bd refusing scalar-metadata replacement; ONLY null/absent metadata (real bd
#   v1.0.4 emits "metadata":null for hand-minted beads) with no convert key reaches the legacy path.
#   accept absent with no convert key +
#   FORGE_MECHGATE_ALLOW_LEGACY=1 → PASS-LEGACY (loudly audited); without the knob → FAIL
#   contract-missing; accept PRESENT with an unresolvable anchor → FAIL, never legacy. No other
#   contract override exists BY DESIGN — and PD-2 pins PATH + unsets BD_BIN so no env var or PATH-shim
#   can substitute either source or the bd that reads it (an exported env rides the agent's session
#   into finish).
#
# Checks (fixed order; ALL run even after an earlier failure — collect-and-report; verdict PASS
# iff every check passes):
#   C0 contract   — pointer validation, anchor extraction + grammar re-validation, cross-check.
#                   A C0 failure is terminal for C1–C3 (no trusted contract to check against);
#                   they are recorded "not-run" and the audit still writes.
#   C1 scope      — `git -C <wt> diff --cached --name-only --no-renames -z <base-sha>` (D2:
#                   index vs recorded fork point; renames list BOTH paths; deletions included),
#                   NUL-plumbed end to end; each path matched against each scope glob in case-
#                   pattern position only. Any path matching no glob is an offender.
#   C2 dod_tests  — each selector re-validated, then run as `timeout $T bash <sel>` (single
#                   argv, no eval, stdin /dev/null). ::pattern selectors are REJECTED fail-closed
#                   (R-A), never executed. rc 0 pass; rc 75 FAIL (a skipped DoD test proves
#                   nothing); rc 124 FAIL timeout; missing file FAIL; any other rc FAIL.
#   C3 sc_evidence— INDEX-based (amendment A2): the commit commits the index, so worktree-only
#                   files are phantom evidence. `git ls-files --stage` must list the path,
#                   mode must not be 120000 (symlink), and the staged blob must be non-empty.
#   integrity     — (amendment A1) sha256 of `git diff --cached <base-sha>` taken after arg
#                   validation and again at verdict time; mismatch → FAIL
#                   index-mutated-during-gate (both hashes audited).
#
# Audit (R-9): one record per invocation at .harness/acceptance/<utc-ts>-<pid>-<bead>.json
# (pid disambiguates same-second invocations — R-14: no single-writer assumption), written on
# EVERY exit path past plumbing, built ONLY with jq -nc --arg/--argjson (zero interpolation).
# Schema: the record schema + an additive top-level `reasons` array (every named failure, exactly
# as printed). A failed audit write is itself FAIL. Boundary (documented, unavoidable): failures
# BEFORE the audit dir resolves (lib.sh unsourceable, no git root) exit 1 with a named stderr
# message — there is no audit dir to write into yet.
#
# Forbidden in this gate: LLM, network, stdin reads, prompt, contract overrides, auto-remediation,
# scope inference, warn-and-pass, and ANY mutation of the worktree/index/ledger/bead — the gate
# READS and verdicts; its only writes are the audit record + per-selector logs.
#
# Knobs (the only three): FORGE_MECHGATE_TIMEOUT (per-selector seconds, default 600, clamped
# [1,3600] — an unbounded value would reopen the never-hang guarantee; a tiny one only fails
# closed); FORGE_MECHGATE_KILL_GRACE (PD-3: seconds `timeout -k` waits after SIGTERM before SIGKILL,
# default 5, clamped [1,3600] — a SIGTERM-deaf selector is SIGKILLed after the grace → rc 137 → FAIL,
# so it can never hang the gate); and FORGE_MECHGATE_ALLOW_LEGACY=1 (R-C, above).
#
# Named residual: this gate CANNOT defend its OWN interpreter from inside itself
# — `#!/usr/bin/env bash` resolves bash from the finish-time PATH BEFORE the PATH pin below runs, so a
# sandbox/-shimmed bash could interpret the whole gate and forge PASS. cmd_finish invokes the gate via an
# ABSOLUTE interpreter (/usr/bin/bash) as cheap defense-in-depth, but interpreter trust is a LAUNCH-TIME
# property: the real boundary is the PreToolUse deny-hooks (Claude Code runtime, not the agent's bash) +
# the human merge. The accept-gate is a QUALITY gate, not a deny boundary (its integrity is conditional
# on a trusted launch interpreter).
#
# Named residual: even in rescope the verdict→audit-write→`git commit` are
# separate steps; an orphan that stages between the rescope POSTH (verdict time) and the commit is a
# structural residual window (MEDIUM — not exploitable on the real tight tail, unless artificially
# widened). True closure needs commit-tree binding (declined); the rescope call's proximity to the
# commit is the accepted Option-A defense.
set -u -o pipefail

# ── plumbing (pre-audit boundary: failures here exit 1 with a named stderr message) ──────────────
# PD-2: the gate runs in the agent's finish-time environment and must NOT trust it. Pin PATH
# and IFS BEFORE any tool resolves, so a sandbox/ PATH-shim `git`/`bd`/jq cannot be consulted (a shim
# `git diff --cached --name-only` returning empty would forge scope; a shim BD_BIN would forge the
# contract and run code as the gate). The 12 system tools (git jq timeout sha256sum awk tr grep mktemp
# date cut dirname sed/setsid) live under these dirs; `bd` is addressed by ABSOLUTE path via
# beads.config below (NOT added to PATH — ~/.local/bin is agent-writable and would re-open the shim
# vector). IFS reset defends word-splitting in the pinned block.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
IFS=$' \t\n'
# PD-2 sibling: clear-all-but-allowlist the loader env (the within-script half of the boundary)
for _fv in $(compgen -e 2>/dev/null); do
  case "$_fv" in
    PATH|HOME|SHELL|PWD|OLDPWD|TERM|USER|LOGNAME|HOSTNAME|TMPDIR|TZ|LANG|LANGUAGE|LC_ALL|SSH_AUTH_SOCK|GH_TOKEN|GITHUB_TOKEN) : ;;
    LC_*|FORGE_*|CLAUDE_*|XDG_*|NODE_*|npm_*|PNPM_*|COREPACK_*) : ;;
    *) unset "$_fv" 2>/dev/null || true ;;
  esac
done
unset _fv
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plumb_fail() {
  printf 'accept-gate: FAIL — %s\n' "$1" >&2
  exit 1
}
[ -f "$HERE/../.claude/hooks/lib.sh" ] || plumb_fail "lib-unresolvable: $HERE/../.claude/hooks/lib.sh missing — this gate runs from <root>/harness/ only (see header)"
# shellcheck disable=SC1091  # resolves relative to <root>/harness/, where this file lives
. "$HERE/../.claude/hooks/lib.sh"
[ -f "$HERE/beads-lib.sh" ] || plumb_fail "beads-lib-unresolvable: $HERE/beads-lib.sh missing — this gate runs from <root>/harness/ only (see header)"
# PD-2: drop any inherited BD_BIN BEFORE sourcing beads-lib (defensive — so a shim is not even present
# when the lib is sourced). beads-lib's `: "${BD_BIN:=bd}"` then sets the harmless `bd` fallback.
unset BD_BIN
# shellcheck disable=SC1091  # resolves relative to <root>/harness/, where this file lives
. "$HERE/beads-lib.sh"
. "$HERE/sandbox-lib.sh"   # FOLD #1: forge_safe_gitdir / forge_safe_git (pristine-gitdir)
command -v jq >/dev/null 2>&1 || plumb_fail "jq-missing: cannot build a verdict or an audit record without jq"
command -v timeout >/dev/null 2>&1 || plumb_fail "timeout-missing: the never-hang guarantee (R-8) needs coreutils timeout"
# DOC-1: strip every agent-exported git-env that can redirect root/index/objects/config
# BEFORE forge_main_root (a bare `git rev-parse`) resolves ROOT — the env-i invariant, total.
unset GIT_DIR GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE GIT_WORK_TREE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
ROOT="$(forge_main_root)" || plumb_fail "no-root: not inside a git repo (forge_main_root failed)"
[ -n "$ROOT" ] || plumb_fail "no-root: forge_main_root returned empty"
# PD-2 (LOAD-BEARING): unset BD_BIN again immediately before forge_beads_load so beads.config's
# absolute `:-` default wins (the lib already pinned the inherited fallback to `bd`, which would NOT
# resolve under the pinned PATH — ~/.local/bin is excluded). After this, BD_BIN is the config's
# absolute deployment default and the R-G check confirms the ABSOLUTE path resolves.
unset BD_BIN
forge_beads_load "$ROOT"
# R-G: bd is plumbing, same class as jq/timeout — the contract read cannot be attempted without it
{ [ -n "${BD_BIN:-}" ] && command -v "$BD_BIN" >/dev/null 2>&1; } || plumb_fail "bd-missing: BD_BIN '${BD_BIN:-}' is unset or not resolvable — cannot read the bead contract"
AUD="$ROOT/.harness/acceptance"
mkdir -p "$AUD" 2>/dev/null || plumb_fail "audit-dir-uncreatable: $AUD"

# ── verdict state (composed into the audit at exit; every check defaults not-run) ────────────────
VERDICT="PASS"
LEGACY=false
REASONS='[]'
R_CON="not-run" D_CON="" A_SHA="" C_SHA=""
R_SCOPE="not-run" OFFJ='[]' GLOBJ='[]' D_SCOPE=""
R_DOD="not-run" SELJ='[]'
R_SC="not-run" SCOFFJ='[]'
R_INT="not-run" PREH="" POSTH=""
BEAD="" WT="" BASE_SHA="" MODE="" RANGE="" BR=""
RA="" RB="" RCO="" WTRUN="" DIFF_ENDPOINTS=()   # T5: --mode range endpoints + the diff-spec used by C1/integrity (+ the C2 tree-B checkout)
RLE=false      # PD-1: rescope ledger exemption applied (.beads/issues.jsonl exempted in --mode rescope)
ADVJ='[]'      # DR-3: advisory notes (e.g. scope-breadth-anomaly) — NEVER affect the verdict

fail() { # fail "<named reason>" — message AND audit, always both
  VERDICT="FAIL"
  printf 'accept-gate: FAIL — %s\n' "$1"
  REASONS="$(jq -c --arg r "$1" '. + [$r]' <<<"$REASONS")" || plumb_fail "audit-build: jq failed appending a reason"
}

gate_exit() {
  # integrity recompute (A1) — only when the pre-hash was taken and checks actually ran
  if [ -n "$PREH" ] && [ "$R_INT" = "not-run" ]; then
    # T5: range mode fingerprints `git diff A B`; staged/rescope fingerprint `git diff --cached BASE`.
    POSTH="$(forge_safe_git "$WT" "$GD" diff "${DIFF_ENDPOINTS[@]}" -- 2>/dev/null | sha256sum | cut -d' ' -f1)" || POSTH=""
    if [ -z "$POSTH" ]; then
      R_INT="fail"
      fail "integrity-recompute-failed: could not re-hash the staged diff at verdict time"
    elif [ "$PREH" != "$POSTH" ]; then
      R_INT="fail"
      fail "index-mutated-during-gate: staged diff changed while the gate ran (pre $PREH post $POSTH)"
    else
      R_INT="pass"
    fi
  fi
  local checks rec fts safe out
  checks="$(jq -nc \
    --arg rc "$R_CON" --arg dc "$D_CON" --arg as "$A_SHA" --arg cs "$C_SHA" \
    --arg rs "$R_SCOPE" --argjson so "$OFFJ" --argjson sg "$GLOBJ" --arg ds "$D_SCOPE" \
    --arg rd "$R_DOD" --argjson sel "$SELJ" \
    --arg re "$R_SC" --argjson eo "$SCOFFJ" \
    --arg ri "$R_INT" --arg ph "$PREH" --arg qh "$POSTH" \
    '[
      {name:"contract",    result:$rc, detail:$dc, anchor_sha256:$as, cache_sha256:$cs},
      {name:"scope",       result:$rs, offenders:$so, globs:$sg, detail:$ds},
      {name:"dod_tests",   result:$rd, selectors:$sel},
      {name:"sc_evidence", result:$re, offenders:$eo},
      {name:"integrity",   result:$ri, pre_sha256:$ph, post_sha256:$qh}
    ]')" || plumb_fail "audit-build: jq failed composing the checks array"
  rec="$(jq -nc \
    --arg bead "$BEAD" --arg branch "$BR" --arg base "$BASE_SHA" --arg mode "$MODE" \
    --arg verdict "$VERDICT" --argjson checks "$checks" --argjson legacy "$LEGACY" \
    --argjson timeout "${T:-600}" --argjson killgrace "${KG:-5}" --arg ts "$(date -u +%FT%TZ)" \
    --argjson reasons "$REASONS" --argjson rle "$RLE" --argjson adv "$ADVJ" \
    '{bead:$bead, branch:$branch, base_sha:$base, mode:$mode, verdict:$verdict, checks:$checks,
      legacy_bypass:$legacy, timeout_s:$timeout, kill_grace_s:$killgrace, actor:"harness", ts:$ts,
      reasons:$reasons, rescope_ledger_exempt:$rle, advisories:$adv}')" ||
    plumb_fail "audit-build: jq failed composing the record"
  fts="$(date -u +%Y%m%dT%H%M%SZ)"
  safe="$(printf '%s' "$BEAD" | tr -cd 'A-Za-z0-9._-')"
  [ -n "$safe" ] || safe="unknown"
  out="$AUD/$fts-$$-$safe.json"
  printf '%s\n' "$rec" >"$out" || plumb_fail "audit-write-failed: $out"
  printf 'accept-gate: %s (bead %s; audit %s)\n' "$VERDICT" "${BEAD:-?}" "$out"
  [ "$VERDICT" = "FAIL" ] && exit 1
  exit 0
}

# ── argument parsing (explicit flags only; no positional guessing; never reads stdin) ────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --bead | --worktree | --base-sha | --mode | --range)
      [ $# -ge 2 ] || {
        fail "invalid-args: $1 requires a value"
        gate_exit
      }
      case "$1" in
        --bead) BEAD="$2" ;;
        --worktree) WT="$2" ;;
        --base-sha) BASE_SHA="$2" ;;
        --mode) MODE="$2" ;;
        --range) RANGE="$2" ;;
      esac
      shift 2
      ;;
    *)
      fail "invalid-args: unknown argument '$1' (usage: accept-gate.sh --bead <id> --worktree <path> --base-sha <sha> --mode staged)"
      gate_exit
      ;;
  esac
done

# per-selector timeout: default 600, clamped [1,3600]; non-numeric is operator error → FAIL named
T="${FORGE_MECHGATE_TIMEOUT:-600}"
case "$T" in
  '' | *[!0-9]*)
    fail "invalid-timeout: FORGE_MECHGATE_TIMEOUT='$T' is not a non-negative integer"
    T=600
    gate_exit
    ;;
esac
[ "$T" -lt 1 ] && T=1
[ "$T" -gt 3600 ] && T=3600

# PD-3 per-selector SIGKILL grace: default 5, clamped [1,3600]; same discipline as the timeout above.
# `timeout -k "$KG" "$T" …` SIGKILLs a SIGTERM-deaf selector KG seconds after the deadline → rc 137.
KG="${FORGE_MECHGATE_KILL_GRACE:-5}"
case "$KG" in
  '' | *[!0-9]*)
    fail "invalid-kill-grace: FORGE_MECHGATE_KILL_GRACE='$KG' is not a non-negative integer"
    KG=5
    gate_exit
    ;;
esac
[ "$KG" -lt 1 ] && KG=1
[ "$KG" -gt 3600 ] && KG=3600

[ -n "$BEAD" ] || { fail "invalid-args: --bead is required"; gate_exit; }
printf '%s' "$BEAD" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || { fail "invalid-bead-id: '$BEAD' (must start alphanumeric; [A-Za-z0-9._-] only — never option-shaped)"; gate_exit; }
[ -n "$WT" ] || { fail "invalid-args: --worktree is required"; gate_exit; }
[ -d "$WT" ] || { fail "worktree-missing: $WT is not a directory"; gate_exit; }
# FOLD #1: route every host git op against the agent-touched worktree through a PRISTINE
# gitdir (the gate authors a minimal config; it never reads the agent .git/config), so no planted
# exec knob (fsmonitor/hooksPath/pager/gpg.program/diff|merge|filter drivers/textconv/sshCommand/
# alias, or any future knob) can execute host-side. Build once; clean up on exit.
GD="$(forge_safe_gitdir "$WT")" || { fail "worktree-not-a-repo: $WT"; gate_exit; }
trap 'rm -rf "${GD:-}" "${RCO:-}" 2>/dev/null' EXIT
forge_safe_git "$WT" "$GD" rev-parse --git-dir >/dev/null 2>&1 || { fail "worktree-not-a-repo: $WT"; gate_exit; }
BR="$(forge_safe_git "$WT" "$GD" rev-parse --abbrev-ref HEAD 2>/dev/null)" || BR=""
[ -n "$BASE_SHA" ] || { fail "invalid-args: --base-sha is required"; gate_exit; }
printf '%s' "$BASE_SHA" | grep -Eq '^[0-9a-fA-F]{4,40}$' || { fail "invalid-base-sha: '$BASE_SHA' (hex object name required — never option-shaped)"; gate_exit; }
forge_safe_git "$WT" "$GD" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null || { fail "base-sha-unresolvable: $BASE_SHA is not a commit in $WT"; gate_exit; }
case "$MODE" in
  staged) ;;
  rescope)
    # Finding 1: FULL re-verify re-invoked by cmd_finish as the IMMEDIATELY-pre-commit
    # statement — closes the post-gate TOCTOU (the staged gate verdicts one index; the commit commits
    # a LATER index in a separate process). rescope runs C0 + C1 + C2 + C3 + integrity against the
    # CURRENT index — identical to --mode staged in WHICH CHECKS RUN (the PD-1 scope-only skip guard
    # was removed: integrity only proves no mutation WITHIN one run, and C1 admits in-scope edits, so a
    # surviving orphan could destroy a C2/C3 property in-scope after the staged PASS). By rescope time
    # the harness has staged .beads/issues.jsonl (out-of-scope by design); rescope exempts that ONE
    # known path (recorded rescope_ledger_exempt:true). `--mode staged` runs before the ledger is
    # staged and grants NO exemption. The audit `mode` still reads `rescope` (provenance).
    ;;
  range)
    # T5: verdict a task's diff sourced from HISTORY (A..B = base_sha..task_tip) instead of the live
    # index — the SAME C0-C3 + integrity, single-bead (--bead required above; a range that mixes beads fails
    # closed by construction — one bead's contract over one contiguous range). Validate the range is EXACTLY
    # two resolvable hex commits joined by '..' (NOT '...', no extra dots), then resolve each as a commit.
    [ -n "$RANGE" ] || { fail "invalid-args: --mode range requires --range A..B"; gate_exit; }
    case "$RANGE" in
      *...*) fail "invalid-range: '$RANGE' — three-dot ranges are not accepted (use A..B)"; gate_exit ;;
      *..*) : ;;
      *) fail "invalid-range: '$RANGE' — expected A..B"; gate_exit ;;
    esac
    RA="${RANGE%%..*}"; RB="${RANGE##*..}"
    [ "$RANGE" = "${RA}..${RB}" ] || { fail "invalid-range: '$RANGE' — exactly one '..' between two object names (A..B)"; gate_exit; }
    { [ -n "$RA" ] && [ -n "$RB" ]; } || { fail "invalid-range: '$RANGE' — both endpoints required (A..B)"; gate_exit; }
    printf '%s' "$RA" | grep -Eq '^[0-9a-fA-F]{4,40}$' || { fail "invalid-range: '$RA' is not a hex object name"; gate_exit; }
    printf '%s' "$RB" | grep -Eq '^[0-9a-fA-F]{4,40}$' || { fail "invalid-range: '$RB' is not a hex object name"; gate_exit; }
    forge_safe_git "$WT" "$GD" cat-file -e "$RA^{commit}" 2>/dev/null || { fail "range-unresolvable: $RA is not a commit in $WT"; gate_exit; }
    forge_safe_git "$WT" "$GD" cat-file -e "$RB^{commit}" 2>/dev/null || { fail "range-unresolvable: $RB is not a commit in $WT"; gate_exit; }
    ;;
  '') fail "invalid-args: --mode is required (staged|rescope|range)"; gate_exit ;;
  *) fail "invalid-mode: '$MODE' (staged|rescope|range)"; gate_exit ;;
esac

# T5: the diff-spec used by C1 (name-only) and integrity (full). range -> `A B`; else `--cached BASE`.
if [ "$MODE" = "range" ]; then DIFF_ENDPOINTS=("$RA" "$RB"); else DIFF_ENDPOINTS=(--cached "$BASE_SHA"); fi

# ── integrity pre-hash (A1): the staged diff this verdict is about, fingerprinted up front ───────
PREH="$(forge_safe_git "$WT" "$GD" diff "${DIFF_ENDPOINTS[@]}" -- 2>/dev/null | sha256sum | cut -d' ' -f1)" || PREH=""
[ -n "$PREH" ] || { fail "integrity-precompute-failed: could not hash the gated diff (${MODE} ${DIFF_ENDPOINTS[*]})"; gate_exit; }

# ── C0: contract resolution (R-E dual-source cross-check) ────────────────────────────────────────
# Every jq below is ordered type-check-before-field-use (the intake.sh:424-428 rule): a jq error
# would empty the capture and — in $bad-style validators — fail OPEN. Captures whose EMPTINESS
# means failure (bead_json, anchor) are safe by construction: empty fails CLOSED.
BEAD_JSON="$(forge_clean_env timeout 30 "$BD_BIN" -C "$ROOT" show "$BEAD" --json 2>/dev/null | jq -c '.[0] // empty' 2>/dev/null)" || BEAD_JSON=""
if [ -z "$BEAD_JSON" ]; then
  R_CON="fail"
  D_CON="bead-not-found"
  fail "bead-not-found: bd show '$BEAD' returned nothing usable"
else
  CACHE="$(jq -c 'if (.metadata | type) == "object" then (.metadata.accept // empty) else empty end' <<<"$BEAD_JSON" 2>/dev/null)" || CACHE=""
  if [ -z "$CACHE" ]; then
    # DR-2: metadata.accept is ABSENT — distinguish a STRIPPED convert bead from a bead
    # that never had a contract. cmd_convert (R-B) mints {target_repo, source_spec, task_id, accept};
    # `bd update --unset-metadata accept` removes only accept, so source_spec/task_id/target_repo
    # SURVIVE and prove a contract existed. A genuine pre-contract (legacy) bead carries NONE of these
    # convert-minted keys. So: accept absent AND any convert key present -> contract-stripped, NEVER
    # legacy (the loud knob cannot launder a stripped contract). accept absent AND no convert key ->
    # the R-C legacy path. (A full strip that also drops every convert key reaches the legacy path,
    # but then fails closed anyway at anchor resolution / contract-missing — named residual.)
    # DR-2 fail-closed (re-review): metadata that is a SCALAR or array (not an object, not null) is a
    # malformed contract — never a genuine pre-contract bead — so CONVKEY="true" routes it to
    # contract-stripped, NOT legacy. This drops the dependency on bd refusing object→scalar metadata
    # replacement. ONLY null/absent metadata (real bd emits "metadata":null for hand-minted beads) is
    # honored as legacy; a malformed jq read still falls to CONVKEY="true" (fail closed).
    CONVKEY="$(jq -r 'if (.metadata | type) == "object"
        then ((.metadata | has("source_spec")) or (.metadata | has("task_id")) or (.metadata | has("target_repo")))
        elif (.metadata | type) == "null" then false
        else true end' <<<"$BEAD_JSON" 2>/dev/null)" || CONVKEY="true"
    if [ "$CONVKEY" = "true" ]; then
      R_CON="fail"
      D_CON="contract-stripped"
      fail "contract-stripped: bead '$BEAD' has no metadata.accept but retains convert-minted metadata (source_spec/task_id/target_repo) — this bead went through convert and lost its accept; FORGE_MECHGATE_ALLOW_LEGACY cannot launder a stripped contract"
    elif [ "${FORGE_MECHGATE_ALLOW_LEGACY:-0}" = "1" ]; then
      # R-C (amendment A3): the legacy trigger is metadata.accept ABSENT with NO convert residue.
      VERDICT="PASS-LEGACY"
      LEGACY=true
      R_CON="skipped-legacy"
      D_CON="metadata.accept absent (no convert residue); FORGE_MECHGATE_ALLOW_LEGACY=1 (R-C — loud, audited bypass)"
      R_SCOPE="skipped-legacy" R_DOD="skipped-legacy" R_SC="skipped-legacy" R_INT="skipped-legacy"
      printf 'accept-gate: PASS-LEGACY — bead %s carries no metadata.accept; FORGE_MECHGATE_ALLOW_LEGACY=1 (R-C bypass, audited)\n' "$BEAD"
      gate_exit
    else
      R_CON="fail"
      D_CON="contract-missing"
      fail "contract-missing: bead '$BEAD' carries no metadata.accept (R-C: FORGE_MECHGATE_ALLOW_LEGACY=1 is the explicit, audited bypass for pre-contract beads)"
    fi
  else
    SRC="$(jq -r 'if (.metadata | type) == "object" then (.metadata.source_spec // empty) else empty end' <<<"$BEAD_JSON" 2>/dev/null)" || SRC=""
    TID="$(jq -r 'if (.metadata | type) == "object" then (.metadata.task_id // empty) else empty end' <<<"$BEAD_JSON" 2>/dev/null)" || TID=""
    ANCHOR=""
    if ! printf '%s' "$SRC" | grep -Eq '^specs/[A-Za-z0-9._/-]+\.md$' || printf '%s' "$SRC" | grep -qF '..'; then
      R_CON="fail"
      D_CON="source-spec-invalid"
      fail "source-spec-invalid: metadata.source_spec '$SRC' (must match ^specs/[A-Za-z0-9._/-]+\\.md\$, no '..')"
    elif [ ! -f "$ROOT/$SRC" ] || [ -L "$ROOT/$SRC" ]; then
      R_CON="fail"
      D_CON="source-spec-unresolvable"
      fail "source-spec-unresolvable: $SRC is not a regular file under the repo root"
    elif ! printf '%s' "$TID" | grep -Eq '^T[0-9]{3}$'; then
      R_CON="fail"
      D_CON="task-id-invalid"
      fail "task-id-invalid: metadata.task_id '$TID' (must match ^T[0-9]{3}\$)"
    else
      # the SAME extractor cmd_analyze uses (intake.sh:383) — the two must never diverge
      BLOCK="$(awk '/<!-- forge:tasks:begin/{f=1;next} /<!-- forge:tasks:end/{f=0} f && $0 !~ /^```/' "$ROOT/$SRC")"
      if ! printf '%s' "$BLOCK" | jq -e . >/dev/null 2>&1; then
        R_CON="fail"
        D_CON="anchor-extract-failed"
        fail "anchor-extract-failed: the Task Breakdown block in $SRC is missing or not valid JSON"
      else
        ANCHOR="$(printf '%s' "$BLOCK" | jq -c --arg t "$TID" '[.tasks[]? | select((type == "object") and (.id == $t))][0] | if . == null then empty else {scope, dod_tests, sc_evidence} end' 2>/dev/null)" || ANCHOR=""
        if [ -z "$ANCHOR" ]; then
          R_CON="fail"
          D_CON="anchor-task-not-found"
          fail "anchor-task-not-found: task $TID is not in the Task Breakdown of $SRC"
        fi
      fi
    fi
    if [ -n "$ANCHOR" ]; then
      # grammar re-validation: the invariant-7/8/9 jq, mirrored over ONE task slice. Stored data
      # is not trusted — neither the spec block nor the bead survives unvalidated. Each chain is
      # a $bad-style validator (empty = pass), so the type-before-use ordering is load-bearing.
      BADV="$(jq -r '
        if type != "object" then "anchor is not an object"
        elif ((.scope | type) != "array") or ((.scope | length) == 0) then "scope is missing or empty"
        elif ([.scope[] | select((type != "string") or (. == "") or startswith("/") or contains("..") or ((test("^[A-Za-z0-9._*?\\[\\]/-]+$")) | not))] | length) > 0
          then "scope entry " + ([.scope[] | select((type != "string") or (. == "") or startswith("/") or contains("..") or ((test("^[A-Za-z0-9._*?\\[\\]/-]+$")) | not))][0] | @json) + " is not a well-formed repo-relative glob"
        elif ((.dod_tests | type) != "array") or ((.dod_tests | length) == 0) then "dod_tests is missing or empty"
        elif ([.dod_tests[] | select((type != "string") or contains("..") or ((test("^(tests|sandbox)(/[A-Za-z0-9][A-Za-z0-9._-]*)+(::[A-Za-z0-9][A-Za-z0-9 ._:-]*)?$")) | not))] | length) > 0
          then "dod_tests entry " + ([.dod_tests[] | select((type != "string") or contains("..") or ((test("^(tests|sandbox)(/[A-Za-z0-9][A-Za-z0-9._-]*)+(::[A-Za-z0-9][A-Za-z0-9 ._:-]*)?$")) | not))][0] | @json) + " is not a valid selector"
        elif ((.sc_evidence | type) != "array") or ((.sc_evidence | length) == 0) then "sc_evidence is missing or empty"
        elif ([.sc_evidence[] | select((type != "object") or ((.sc? | type) != "number") or ((.path? | type) != "string") or (.path == "") or (.path | startswith("/")) or (.path | contains("..")) or (((.path | test("^[A-Za-z0-9][A-Za-z0-9._/-]*$"))) | not))] | length) > 0
          then "sc_evidence entry " + ([.sc_evidence[] | select((type != "object") or ((.sc? | type) != "number") or ((.path? | type) != "string") or (.path == "") or (.path | startswith("/")) or (.path | contains("..")) or (((.path | test("^[A-Za-z0-9][A-Za-z0-9._/-]*$"))) | not))][0] | @json) + " is not a well-formed {sc, path}"
        else empty end' <<<"$ANCHOR" 2>/dev/null)"
      ANCHOR_OK=1
      if ! jq -e . >/dev/null 2>&1 <<<"$ANCHOR"; then
        ANCHOR_OK=0
        R_CON="fail"
        D_CON="anchor-grammar-unverifiable"
        fail "anchor-grammar-unverifiable: jq could not parse the extracted anchor (fail closed)"
      elif [ -n "$BADV" ]; then
        ANCHOR_OK=0
        R_CON="fail"
        D_CON="anchor-grammar"
        fail "anchor-grammar: task $TID in $SRC — $BADV (fail closed; analyze should have rejected this spec)"
      fi
      if [ "$ANCHOR_OK" = 1 ]; then
        A_CAN="$(jq -Sc . <<<"$ANCHOR" 2>/dev/null)" || A_CAN=""
        C_CAN="$(jq -Sc . <<<"$CACHE" 2>/dev/null)" || C_CAN=""
        if [ -z "$A_CAN" ] || [ -z "$C_CAN" ]; then
          R_CON="fail"
          D_CON="canonicalize-failed"
          fail "canonicalize-failed: could not canonicalize anchor/cache for the cross-check (fail closed)"
        else
          A_SHA="$(printf '%s' "$A_CAN" | sha256sum | cut -d' ' -f1)"
          C_SHA="$(printf '%s' "$C_CAN" | sha256sum | cut -d' ' -f1)"
          # R-F: the VERDICT is canonical-value equality (type-aware: {"sc":"1"} != {"sc":1});
          # the jq -S canonical forms + sha256s above are computed purely for the audit record.
          # A jq error here lands in the else branch — drift, fail CLOSED.
          if jq -e -n --argjson a "$ANCHOR" --argjson c "$CACHE" '$a == $c' >/dev/null 2>&1; then
            R_CON="pass"
            D_CON="anchor == cache (canonical-value-equal)"
          else
            R_CON="fail"
            D_CON="contract-drift"
            fail "contract-drift: spec task block (anchor sha256 $A_SHA) != bead metadata.accept (cache sha256 $C_SHA) — the ratified spec is the anchor; a bead-side rewrite does not move the contract"
          fi
        fi
      fi
    fi
  fi
fi

# C0 failure is terminal for C1–C3: there is no trusted contract to check the build against.
[ "$R_CON" = "pass" ] || gate_exit

# ── C1: diff ⊆ scope (D2 file set; NUL plumbing end to end; case-pattern matching only) ──────────
GLOBJ="$(jq -c '.scope' <<<"$ANCHOR")" || GLOBJ='[]'
mapfile -t GLOBS < <(jq -r '.scope[]' <<<"$ANCHOR" 2>/dev/null)
R_SCOPE="pass"
if [ "${#GLOBS[@]}" -eq 0 ]; then
  R_SCOPE="fail"
  D_SCOPE="no-globs"
  fail "scope-unreadable: validated anchor yielded zero scope globs (fail closed)"
else
  # DR-3 (advisory, NEVER blocks): flag vacuous scope globs. A glob is degenerate iff it consists
  # SOLELY of '*', '?', '/', and bracket expressions '[...]' — no literal path character to constrain
  # the boundary (ERE ^([*?/]|\[[^]]*\])+$). '**/*.ts', 'sandbox/**', 'docs/file[0-9].md' all carry a
  # literal segment and are NOT vacuous. This is normative in templates/spec-template.md; the gate and
  # that list must agree. The anomaly is recorded in the audit's advisories and never moves the verdict.
  for g in "${GLOBS[@]}"; do
    if printf '%s' "$g" | grep -Eq '^([*?/]|\[[^]]*\])+$'; then
      ADVJ="$(jq -c --arg id "$BEAD" --arg g "$g" '. + ["scope-breadth-anomaly (advisory): bead " + $id + " declares vacuous glob " + ($g | @json) + " — boundary does not constrain"]' <<<"$ADVJ")" || plumb_fail "audit-build: jq failed appending a scope-breadth advisory"
    fi
  done
  DIFFZ="$(mktemp)"
  # T5: range -> `git diff --name-only -z A B`; staged/rescope -> `git diff --cached --name-only -z BASE`.
  if ! forge_safe_git "$WT" "$GD" diff --name-only --no-renames -z "${DIFF_ENDPOINTS[@]}" -- >"$DIFFZ" 2>/dev/null; then
    R_SCOPE="fail"
    D_SCOPE="diff-failed"
    fail "diff-failed: git diff (${MODE} ${DIFF_ENDPOINTS[*]}) failed in $WT"
  else
    NOFF=0
    while IFS= read -r -d '' f; do
      [ -n "$f" ] || continue
      m=0
      for g in "${GLOBS[@]}"; do
        # $g unquoted ONLY in pattern position — safe: the invariant-7 alphabet was re-validated
        # in C0 (no $ ` ~ \ space quote brace); a case pattern is never word-split or executed.
        # shellcheck disable=SC2254
        case "$f" in $g) m=1; break ;; esac
      done
      # PD-1: --mode rescope exempts the single harness-staged ledger snapshot (.beads/issues.jsonl),
      # which the staged gate already verdicted before the harness added it. staged mode grants NO
      # exemption (it runs before the ledger is staged).
      if [ "$m" = 0 ] && [ "$MODE" = "rescope" ] && [ "$f" = ".beads/issues.jsonl" ]; then
        m=1
        RLE=true
      fi
      if [ "$m" = 0 ]; then
        NOFF=$((NOFF + 1))
        if [ "$NOFF" -le 50 ]; then
          OFFJ="$(jq -c --arg f "$f" '. + [$f]' <<<"$OFFJ")" || plumb_fail "audit-build: jq failed appending a scope offender"
          fail "scope: '$f' matches no scope glob of task $TID (declared boundary: $(jq -c . <<<"$GLOBJ"))"
        fi
      fi
    done <"$DIFFZ"
    if [ "$NOFF" -gt 50 ]; then
      D_SCOPE="offenders capped at 50 in this record; total=$NOFF"
      fail "scope: $((NOFF - 50)) further offender(s) beyond the 50 recorded (total $NOFF)"
    fi
    [ "$NOFF" -eq 0 ] || R_SCOPE="fail"
  fi
  rm -f "$DIFFZ"
fi

# Finding 1: --mode rescope is a FULL re-verify — C2 + C3 run here exactly as in --mode
# staged. The PD-1 scope-only skip guard was REMOVED: integrity proves the index unmutated only WITHIN
# one gate run, and C1 admits in-scope deletions/edits, so a surviving orphan could destroy a C2/C3
# property in-scope between the staged PASS and the commit (evidence deletion / dod sabotage). The only
# rescope-specific behavior left is the one-path .beads/issues.jsonl ledger exemption in C1; the audit
# `mode` still reads `rescope`. C2 + C3 below therefore run unconditionally once C0 has passed.
# Residual (Finding V-1, LOW): that C2 re-verify catches dod sabotage ONLY when the dod_test
# HONESTLY RE-EXECUTES — the guarantee is conditional on dod_test idempotency/statelessness. A
# verdict-memoizing dod_test that caches its own staged-run PASS to an untracked marker and then
# short-circuits on the rescope run defeats it (untracked state is not diffable, hence out of
# mechanical scope); the human merge remains the boundary.

# ── C2: dod_tests (re-validate, then run — single argv, timeout-bounded, stdin /dev/null) ────────
# T5: the run dir. staged/rescope run the dod_tests in the LIVE worktree ($WT). range runs them
# against a THROWAWAY checkout of tree B (the worktree is not necessarily at B): `git archive B | tar -x`
# materializes B's product tree (no .git) into $RCO, cleaned by the EXIT trap. Same timeout/kill/rc rules.
WTRUN="$WT"
if [ "$MODE" = "range" ]; then
  RCO="$(mktemp -d "${TMPDIR:-/tmp}/forge-range-co.XXXXXX")" || { fail "range-checkout-failed: mktemp for the tree-$RB dod checkout failed"; gate_exit; }
  if ! forge_safe_git "$WT" "$GD" archive "$RB" 2>/dev/null | tar -x -C "$RCO" 2>/dev/null; then
    fail "range-checkout-failed: could not materialize tree $RB for the dod_tests (git archive | tar)"
    gate_exit
  fi
  WTRUN="$RCO"
fi
mapfile -t SELS < <(jq -r '.dod_tests[]' <<<"$ANCHOR" 2>/dev/null)
R_DOD="pass"
if [ "${#SELS[@]}" -eq 0 ]; then
  R_DOD="fail"
  fail "dod-unreadable: validated anchor yielded zero dod_tests selectors (fail closed)"
fi
SI=0
FTS_LOG="$(date -u +%Y%m%dT%H%M%SZ)"
BEAD_SAFE="$(printf '%s' "$BEAD" | tr -cd 'A-Za-z0-9._-')"
for sel in "${SELS[@]}"; do
  SI=$((SI + 1))
  s_rc="" s_verdict="" s_log=""
  case "$sel" in
    *::*)
      s_verdict="pattern-selector-rejected"
      R_DOD="fail"
      fail "dod: '$sel' — pattern-selector-rejected: pattern execution convention not defined — use a whole-file selector (R-A; NEVER executed)"
      ;;
    *)
      if ! printf '%s' "$sel" | grep -Eq '^(tests|sandbox)(/[A-Za-z0-9][A-Za-z0-9._-]*)+$'; then
        s_verdict="selector-grammar-invalid"
        R_DOD="fail"
        fail "dod: '$sel' — selector-grammar-invalid (fail closed; NEVER executed)"
      elif [ ! -f "$WTRUN/$sel" ]; then
        s_verdict="selector-missing"
        R_DOD="fail"
        fail "dod: '$sel' — selector-missing: absence of the named DoD test is not 'no tests = pass'"
      else
        s_log="$AUD/$FTS_LOG-$$-${BEAD_SAFE:-unknown}-sel$SI.log"
        : >"$s_log" 2>/dev/null || s_log=""
        # PD-3: run the selector under `timeout -k` (SIGKILL KG seconds after the SIGTERM deadline, so
        # a SIGTERM-deaf selector cannot hang the gate → rc 137), inside its OWN process group via
        # `set -m` (the backgrounded `timeout` job's PGID == its PID). After it returns — pass, fail,
        # timeout, or kill — sweep that group so a plain background child the selector left behind does
        # not outlive the gate. HYGIENE, best-effort, NOT a security boundary: the sweep reaps
        # same-session/process-group descendants; a selector that deliberately `setsid`s a grandchild
        # into a NEW session escapes it (POSIX gives no handle to a foreign session — no cgroups here).
        # PD-1's `--mode rescope` re-check is the actual TOCTOU guarantee against anything such an
        # orphan stages post-return. Job-control chatter is routed to the per-selector log.
        (
          cd "$WTRUN" || exit 127
          set -m
          timeout -k "$KG" "$T" bash "$sel" </dev/null >>"${s_log:-/dev/null}" 2>&1 &
          _cpid=$!
          wait "$_cpid"
          _rc=$?
          kill -TERM -- -"$_cpid" 2>/dev/null
          kill -KILL -- -"$_cpid" 2>/dev/null
          exit "$_rc"
        ) 2>>"${s_log:-/dev/null}"
        s_rc=$?
        case "$s_rc" in
          0) s_verdict="pass" ;;
          75)
            s_verdict="rc75-skip-is-not-acceptance-evidence"
            R_DOD="fail"
            fail "dod: '$sel' — rc75-skip-is-not-acceptance-evidence (a skipped DoD test proves nothing)"
            ;;
          124)
            s_verdict="timeout"
            R_DOD="fail"
            fail "dod: '$sel' — timeout (rc 124 after ${T}s; FORGE_MECHGATE_TIMEOUT clamps to [1,3600])"
            ;;
          137)
            s_verdict="killed-after-grace"
            R_DOD="fail"
            fail "dod: '$sel' — killed-after-grace (rc 137; SIGTERM-deaf, SIGKILLed ${KG}s after the ${T}s deadline — FORGE_MECHGATE_KILL_GRACE)"
            ;;
          *)
            s_verdict="failed"
            R_DOD="fail"
            fail "dod: '$sel' — failed (rc $s_rc; log: ${s_log:-none})"
            ;;
        esac
      fi
      ;;
  esac
  SELJ="$(jq -c --arg s "$sel" --arg rc "$s_rc" --arg v "$s_verdict" --arg l "$s_log" \
    '. + [{sel:$s, rc:(if $rc == "" then null else ($rc | tonumber) end), verdict:$v, log:$l}]' <<<"$SELJ")" ||
    plumb_fail "audit-build: jq failed appending a selector record"
done

# ── C3: sc_evidence — INDEX-based (A2): the commit commits the index, not the worktree ───────────
R_SC="pass"
SCN="$(jq -r '.sc_evidence | length' <<<"$ANCHOR" 2>/dev/null)" || SCN=0
case "$SCN" in '' | *[!0-9]*) SCN=0 ;; esac
if [ "$SCN" -eq 0 ]; then
  R_SC="fail"
  fail "sc-unreadable: validated anchor yielded zero sc_evidence entries (fail closed)"
fi
EI=0
while [ "$EI" -lt "$SCN" ]; do
  p="$(jq -r --argjson i "$EI" '.sc_evidence[$i].path // empty' <<<"$ANCHOR" 2>/dev/null)" || p=""
  EI=$((EI + 1))
  # re-validate (C0 already did; stored data stays untrusted at every use site — and the path
  # alphabet is what makes the unquoted-free git pathspec below safe: no glob chars, no ':')
  if [ -z "$p" ] || ! printf '%s' "$p" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || printf '%s' "$p" | grep -qF '..'; then
    R_SC="fail"
    SCOFFJ="$(jq -c --arg p "$p" '. + [$p + " (path-grammar)"]' <<<"$SCOFFJ")" || plumb_fail "audit-build: jq failed appending an sc offender"
    fail "sc-evidence: '$p' — path-grammar-invalid (fail closed)"
    continue
  fi
  # T5: range reads TREE B (`ls-tree B`); staged/rescope read the INDEX (`ls-files --stage`). Both
  # emit `<mode> ...` first, so the symlink-mode + size>0 checks below are identical for either source.
  if [ "$MODE" = "range" ]; then
    LSOUT="$(forge_safe_git "$WT" "$GD" ls-tree "$RB" -- "$p" 2>/dev/null)" || LSOUT=""
  else
    LSOUT="$(forge_safe_git "$WT" "$GD" ls-files --stage -- "$p" 2>/dev/null)" || LSOUT=""
  fi
  if [ -z "$LSOUT" ]; then
    R_SC="fail"
    if [ "$MODE" = "range" ]; then
      SCOFFJ="$(jq -c --arg p "$p" '. + [$p + " (missing-from-tree)"]' <<<"$SCOFFJ")" || plumb_fail "audit-build: jq failed appending an sc offender"
      fail "sc-evidence: '$p' — missing-from-tree: evidence absent from tree $RB is phantom evidence (the commit commits the tree)"
    else
      SCOFFJ="$(jq -c --arg p "$p" '. + [$p + " (missing-from-index)"]' <<<"$SCOFFJ")" || plumb_fail "audit-build: jq failed appending an sc offender"
      fail "sc-evidence: '$p' — missing-from-index: evidence not staged is phantom evidence (the commit commits the index)"
    fi
    continue
  fi
  FMODE="${LSOUT%% *}"
  if [ "$FMODE" = "120000" ]; then
    R_SC="fail"
    SCOFFJ="$(jq -c --arg p "$p" '. + [$p + " (symlink)"]' <<<"$SCOFFJ")" || plumb_fail "audit-build: jq failed appending an sc offender"
    fail "sc-evidence: '$p' — symlink (mode 120000): a link to any host file must not satisfy 'evidence exists'"
    continue
  fi
  if [ "$MODE" = "range" ]; then
    BSIZE="$(forge_safe_git "$WT" "$GD" cat-file -s "$RB:$p" 2>/dev/null)" || BSIZE=""
  else
    BSIZE="$(forge_safe_git "$WT" "$GD" cat-file -s ":$p" 2>/dev/null)" || BSIZE=""
  fi
  case "$BSIZE" in '' | *[!0-9]*) BSIZE="" ;; esac
  if [ -z "$BSIZE" ] || [ "$BSIZE" -eq 0 ]; then
    R_SC="fail"
    SCOFFJ="$(jq -c --arg p "$p" '. + [$p + " (empty)"]' <<<"$SCOFFJ")" || plumb_fail "audit-build: jq failed appending an sc offender"
    fail "sc-evidence: '$p' — empty: the staged blob has no content (or is unreadable — fail closed)"
    continue
  fi
done

gate_exit
