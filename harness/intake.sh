#!/usr/bin/env bash
# agentic-builder-forge — intake: objective -> drafted, self-checking specification.
#
#   start "<objective>" --target <repo[,repo...]> [--mode interactive|autonomous]
#                               scaffold specs/NNN-<slug>/spec.md from the template, fill the Header,
#                               ARM the intake sentinel (phase=open), and prime the Architect session
#   clarify [<spec>]            grant one more clarify round (human override; intent-clarity > quota)
#   ratify [<spec>]             HUMAN Gate-A sign-off: bind a token to sha256(understanding.md), phase=ratified
#   analyze [<spec>]            Gate B (cp-schema): nine Task-Breakdown invariants + bidirectional FR<->task traceability
#   convert [<spec>]            MINT — ratify-token + anti-TOCTOU + Gate-B analyze + the floor (fx-v0w) preflight,
#                               then topo-ordered bd creates (data-only transport), crosswalk, blocks
#                               edges, sentinel cleared. Mints into the CWD-discovered ledger.
#   abort                       clear the active-intake sentinel + ALL .harness/intake-* state (spec left in place)
#
# Intake is a SEPARATE lifecycle from the build loop (run-task.sh): it produces specs/, never touches
# sandbox/, and runs with its OWN sentinel (.harness/active-intake.json) — distinct from the builder's
# active-task.json — so the build test-gate never fires during intake and vice versa.
# Deployed enforcement-protected file: agent edits are floor-denied; changes are authored as sandbox/ candidates and human-spliced under FORGE_ALLOW_HOOK_EDIT=1 (audit-logged).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ROOT = the MAIN checkout root, derived from the git common dir (the same rule as lib.sh forge_main_root).
# Deriving from the repo — not from this file's location — lets a pre-splice sandbox/ candidate resolve
# the shared lib and the template exactly as the spliced harness/ copy will.
_common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "intake: not inside a git repo" >&2
  exit 1
}
ROOT="$(dirname "$_common")"
# shellcheck source=../.claude/hooks/lib.sh
. "$ROOT/.claude/hooks/lib.sh"

die() {
  printf 'intake: %s\n' "$1" >&2
  exit 1
}
slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40; }

# Intake sentinel — a SEPARATE lifecycle from the build sentinel (active-task.json). Armed by `start`,
# cleared by `abort` (advanced by `ratify` / cleared by `convert`). FORGE_HARNESS_DIR is
# honored for test isolation — kept in lockstep with lib.sh forge_harness_dir — defaulting to $ROOT/.harness,
# so an intake run's sentinel never arms the real Stop/clarify gates against a running session under test.
_intake_harness_dir() { printf '%s' "${FORGE_HARNESS_DIR:-$ROOT/.harness}"; }
_intake_sentinel()    { printf '%s/active-intake.json' "$(_intake_harness_dir)"; }
# The FR-definition-line hash. Binds the '^- **FR-NNN:**' requirement lines (the SAME
# anchor Gate-B analyze keys on for traceability) into the ratify token, so a post-ratify edit to an FR
# line — even one that leaves understanding.md byte-identical — is refused at convert (closes MEDIUM-3).
# ONE function, used at BOTH mint (cmd_ratify) and verify (cmd_convert), so the two extraction sites
# cannot diverge — a divergence would make convert refuse a legitimately-unchanged spec (a false
# positive). grep is in FILE ORDER: deterministic for a given file; deliberately NOT sorted (file order
# is already stable, and sorting would mask a legitimate FR reordering as non-drift). Edge: a spec with
# zero FR lines hashes the empty string (stable); convert's in-process analyze separately refuses a
# zero-FR spec, so such a spec cannot mint regardless.
# F3 (honesty): this binds the FR-line CONTENT, not task content. The minted task block is
# Gate-B-validated (structure + bidirectional FR<->task traceability), NOT human-ratified here —
# task-block binding is Gate A′'s (ratify-breakdown).
_intake_fr_hash() { grep -E '^- \*\*FR-[0-9]{3}:\*\*' "$1" 2>/dev/null | sha256sum | cut -d' ' -f1; }
# cp-gateA' (R5a): the ONE shared Task-Breakdown extractor — the SAME awk slice cmd_analyze and
# cmd_convert use, factored into a single function so the breakdown ratify-breakdown signs (hash-at-sign-off)
# and convert re-hashes BYTE-IDENTICAL bytes. A divergence would make convert refuse a legitimately-unchanged
# breakdown (a false positive) — the exact hazard the _intake_fr_hash note above warns of. Raw block bytes
# in file order (no canonicalization/sort), mirroring the FR-hash grep-in-file-order discipline.
_intake_task_block() { awk '/<!-- forge:tasks:begin/{f=1;next} /<!-- forge:tasks:end/{f=0} f && $0 !~ /^```/' "$1"; }
_intake_task_hash()  { _intake_task_block "$1" | sha256sum | cut -d' ' -f1; }
# cp-gateA' (B / PROBE-B): the pre-ratified-only floor — convert may mint ONLY from a FRESH,
# HUMAN-ORIGIN ratification, on EVERY path (always-on, fail-closed; never mode-gated). human_origin is the
# TTY-path proof (minted only by cmd_ratify / cmd_ratify_breakdown, which the agent's non-TTY Bash cannot
# run). Freshness bounds a stale-abandoned sign-off: ratified_at older than INTAKE_RATIFY_MAX_AGE (default
# 24h; tighten via intake.config) is refused. Cross-session/session-binding is a documented follow-on (R-14).
_intake_token_human_fresh() { # <token-file> <label> — die fail-closed if non-human-origin or stale
  local tok="$1" label="$2" ho rat mintsec now age max
  ho="$(jq -r '.human_origin // empty' "$tok" 2>/dev/null)"
  [ "$ho" = "true" ] || die "$label ratification token is not human-origin (human_origin != true) — refusing to convert (pre-ratified-only: a token is mintable only at the human's TTY)"
  rat="$(jq -r '.ratified_at // empty' "$tok" 2>/dev/null)"
  [ -n "$rat" ] || die "$label ratification token has no ratified_at — cannot verify freshness; refusing to convert (fail closed)"
  mintsec="$(date -u -d "$rat" +%s 2>/dev/null || printf 0)"
  now="$(date -u +%s)"
  age=$(( now - mintsec ))
  max="${INTAKE_RATIFY_MAX_AGE:-86400}"
  { [ "$age" -ge 0 ] && [ "$age" -le "$max" ]; } || die "$label ratification is stale (age ${age}s, limit INTAKE_RATIFY_MAX_AGE=${max}s, ratified_at=$rat) — re-ratify before converting (pre-ratified-only floor; logged)"
  printf 'intake: %s ratification fresh (age %ss <= %ss) and human-origin.\n' "$label" "$age" "$max" >&2
}
# Concern 1: persist the crosswalk (T0NN -> minted id) — called INCREMENTALLY after each
# mint so the on-disk crosswalk always reflects the ledger truth (re-run safety). Reads XWALK + xw from
# the caller's scope (bash dynamic scoping), mirroring the original end-of-loop writer.
_intake_persist_xwalk() { local k; { for k in "${!XWALK[@]}"; do jq -nc --arg t "$k" --arg b "${XWALK[$k]}" '{($t): $b}'; done; } | jq -sc 'add' >"$xw"; }

# Load config (template path, specs dir, mode default, clarify budgets). Mirrors forge_load_target /
# beads.config: the wrapper hardcodes nothing. Env overrides win (tests point INTAKE_SPECS_DIR at a tmp).
intake_load_config() {
  local cfg="$HERE/intake.config"
  [ -f "$cfg" ] || die "missing harness/intake.config"
  # shellcheck source=/dev/null
  . "$cfg"
}

# Same root-discipline as run-task.sh: Claude loads .claude/ hooks from the launch cwd only
# (claude-code#12962); a session launched outside the root runs UNPROTECTED.
require_root() {
  [ "$PWD" = "$ROOT" ] && return 0
  printf '\n  ⚠  NOT AT REPO ROOT\n     cwd:  %s\n     root: %s\n' "$PWD" "$ROOT" >&2
  printf '     Claude Code loads .claude/ hooks from the launch cwd only (claude-code#12962). If this\n' >&2
  printf '     session was launched outside the root, the deny hooks are NOT loaded and this run is\n' >&2
  printf '     UNPROTECTED. Re-launch Claude Code from the repo root above.\n' >&2
  if [ "${FORGE_REQUIRE_ROOT:-0}" = "1" ]; then
    printf '     FORGE_REQUIRE_ROOT=1 -> refusing.\n\n' >&2
    exit 1
  fi
  printf '     (set FORGE_REQUIRE_ROOT=1 to make this a hard refusal)\n\n' >&2
}

# Resolve a configured dir/file against ROOT unless it is already absolute.
intake_resolve() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$ROOT" "$1" ;; esac; }

# NNN = max existing 3-digit prefix under specs/ + 1, zero-padded. No specs dir yet -> 001.
next_num() {
  local dir="$1" max=0 n b d
  if [ -d "$dir" ]; then
    for d in "$dir"/[0-9][0-9][0-9]-*/; do
      [ -d "$d" ] || continue
      b="$(basename "$d")"
      n="${b%%-*}"
      n=$((10#$n))
      [ "$n" -gt "$max" ] && max="$n"
    done
  fi
  # Width fixed at 3 (NNN), matching the [0-9][0-9][0-9] scan/clobber globs. Known, unaddressed: at 1000+
  # specs "%03d" prints 4 digits the 3-digit globs miss (collision) — widen here + the clobber find if
  # >999 specs are ever genuinely needed (far off).
  printf "%03d" "$((max + 1))"
}

# Replace the value after a stable "- **<field>:**" marker (literal prefix match — no regex/sed-delimiter
# hazard with arbitrary objective text). Fails closed if the template lacks the field.
_intake_set_field() {
  local spec="$1" field="$2" value="$3" marker tmp
  marker="- **$field:**"
  grep -qF -- "$marker" "$spec" || die "template missing Header field: $field"
  tmp="$(mktemp)"
  marker="$marker" value="$value" awk '
    BEGIN { m = ENVIRON["marker"]; v = ENVIRON["value"] }
    index($0, m) == 1 { print m " " v; next }
    { print }
  ' "$spec" >"$tmp" && mv "$tmp" "$spec"
}

# Fill the four Header fields, then assert no PLACEHOLDER / empty value survives (fail closed).
intake_fill_header() {
  local spec="$1" objective="$2" target="$3" mode="$4" status="$5" f
  _intake_set_field "$spec" "Objective" "$objective"
  _intake_set_field "$spec" "Target Repo(s)" "$target"
  _intake_set_field "$spec" "Mode" "$mode"
  _intake_set_field "$spec" "Status" "$status"
  for f in "Objective" "Target Repo(s)" "Mode" "Status"; do
    if grep -F -- "- **$f:**" "$spec" | grep -qE '\[PLACEHOLDER|:\*\*[[:space:]]*$'; then
      die "header fill left an empty/placeholder field: $f (in $spec)"
    fi
  done
  return 0
}

cmd_start() {
  intake_load_config
  local objective="" target="" mode="${INTAKE_MODE_DEFAULT:-interactive}"
  local usage='usage: intake.sh start "<objective>" --target <repo[,repo...]> [--mode interactive|autonomous]'
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="${2:-}"; shift 2 || die "$usage" ;;
      --mode) mode="${2:-}"; shift 2 || die "$usage" ;;
      --*) die "unknown flag: $1 ($usage)" ;;
      *)
        if [ -z "$objective" ]; then
          objective="$1"
          shift
        else
          die "unexpected argument: $1 ($usage)"
        fi
        ;;
    esac
  done

  [ -n "$objective" ] || die "$usage"
  # T1: the objective is the one untrusted scaffold-time input and is written verbatim into the spec
  # Header; a newline would inject extra markdown (e.g. a second task-sentinel block) — reject, fail closed.
  case "$objective" in
    *$'\n'*) die "objective must be a single line" ;;
  esac
  [ -n "$target" ] || die "start requires --target <repo[,repo...]>"
  case "$mode" in
    interactive | autonomous) : ;;
    *) die "mode must be interactive or autonomous (got: $mode)" ;;
  esac
  # T7: autonomous/unattended has no human to heed require_root's warning — an off-root launch means
  # Claude's .claude/ deny hooks never loaded (claude-code#12962) and the whole protection floor is absent.
  # Treat off-root as a HARD refusal in autonomous mode, regardless of the ambient FORGE_REQUIRE_ROOT.
  if [ "$mode" = autonomous ]; then FORGE_REQUIRE_ROOT=1; fi
  require_root

  # Single-writer: refuse a new start while an intake is already active — the intake gates key
  # on ONE sentinel, so a second concurrent start would steal them. Finish (ratify/convert) or `abort` first.
  local sentinel; sentinel="$(_intake_sentinel)"
  [ -f "$sentinel" ] && die "an intake is already active ($(jq -r '.spec // "?"' "$sentinel" 2>/dev/null)) — finish it (ratify/convert) or run: intake.sh abort"

  local slug
  slug="$(slugify "$objective")"
  [ -n "$slug" ] || die "objective has no slug-able content (got: '$objective')"

  local specs_dir template_file
  specs_dir="$(intake_resolve "${INTAKE_SPECS_DIR:-specs}")"
  template_file="$(intake_resolve "${INTAKE_TEMPLATE:-templates/spec-template.md}")"
  [ -f "$template_file" ] || die "missing spec template: $template_file"

  # Fail closed: refuse to clobber an existing spec for the same slug (no silent second dir).
  local existing
  existing="$(find "$specs_dir" -maxdepth 1 -type d -name "[0-9][0-9][0-9]-$slug" 2>/dev/null | head -1)"
  [ -z "$existing" ] || die "a spec for '$slug' already exists ($existing) — refusing to clobber"

  local num dir spec
  num="$(next_num "$specs_dir")"
  dir="$specs_dir/$num-$slug"
  spec="$dir/spec.md"
  # Ensure the specs/ parent exists (idempotent, race-safe); the leaf create below is the atomic guard.
  mkdir -p "$specs_dir" || die "cannot create specs dir: $specs_dir"
  # T2: atomic leaf create (no -p) — a same-NNN concurrent start fails closed here instead of last-writer-
  # wins. T4: check mkdir/cp so a filesystem failure (unwritable dir, full disk) reports accurately rather
  # than surfacing later as a bogus "template missing Header field".
  mkdir "$dir" || die "cannot create $dir"
  # T4: now that we own $dir, arm a failure-cleanup so a partial scaffold (failed cp / interrupted header
  # fill) does not wedge the slug behind the clobber check. Armed AFTER mkdir so a lost same-NNN race above
  # never rm's the winner's dir. intake.sh's own process is not subject to the deny hook (which gates Claude
  # tool calls); $dir is freshly built under specs/ from a sanitized slug (no glob/.. metacharacters).
  trap 'rc=$?; [ "$rc" = 0 ] || rm -rf "$dir"' EXIT
  cp "$template_file" "$spec" || die "cannot scaffold $spec"
  intake_fill_header "$spec" "$objective" "$target" "$mode" "draft"

  # Arm the intake sentinel (phase=open). It carries the spec path, mode, and the clarify/restate budgets,
  # so the Stop gate (stop-gate-intake.sh) and the canary-gated clarify-gate read ONE source of truth.
  # Mirrors run-task.sh's jq -nc sentinel write; written atomically (tmp + mv) so a failure never wedges.
  local hd stmp
  hd="$(_intake_harness_dir)"
  mkdir -p "$hd" || die "cannot create harness dir: $hd"
  stmp="$(mktemp)"
  jq -nc \
    --arg spec "$spec" --arg slug "$slug" --arg obj "$objective" --arg tgt "$target" --arg m "$mode" \
    --argjson cr "${INTAKE_CLARIFY_ROUNDS:-5}" --argjson rr "${INTAKE_RESTATE_ROUNDS:-3}" --argjson mq "${INTAKE_CLARIFY_MAX_Q:-4}" \
    --arg ts "$(date -u +%FT%TZ)" \
    '{spec:$spec,slug:$slug,objective:$obj,targets:$tgt,mode:$m,phase:"open",clarify_rounds:$cr,restate_rounds:$rr,clarify_max_q:$mq,started:$ts}' \
    >"$stmp" && mv "$stmp" "$sentinel" || die "cannot write intake sentinel: $sentinel"

  cat <<EOF

✓ intake scaffolded: $objective
  spec:     $spec
  target:   $target
  mode:     $mode
  status:   draft   (intake sentinel ARMED, phase=open — the clarify + Gate-A floors are now live)

  Next — prime the Architect (interactive primary session):
    • Read the role:   .claude/agents/architect.md
    • Use the skills:  clarify   then   spec-authoring   then   decompose
    • Clarify (F1: route, never drop): ask the top ambiguities within the round budget ($((${INTAKE_CLARIFY_ROUNDS:-5})) rounds),
      log each as a '### Round N — <date>' entry in ## Clarifications and propagate it; route EVERY
      remaining ambiguity to a flagged [ASSUMED ...] in ## Assumptions (no cap). Mode=autonomous never asks.
    • Author the prioritized stories -> FR-NNN -> measurable SC-NNN, and fill the F7 ## Deferrals surface.
    • Gate A: the spec-reviewer + restatement loop produce understanding.md; a human ratifies.
    • The Stop gate will hold you here until the clarify floor is met (no orphan [NEEDS CLARIFICATION],
      coverage present). To loop in another clarify round: intake.sh clarify $spec
EOF
}

# clarify [<spec>] — the human grants one more clarify round (override). The ASKING is the Architect's
# (AskUserQuestion, gated); intake.sh owns the budget STATE. Intent-clarity outranks the quota, so this is
# allowed even at zero rounds remaining. [This also re-opens phase ratified -> open here.]
cmd_clarify() {
  intake_load_config
  local sentinel hd grantf grant spec rtmp axis="" axesf catsf
  # G5: optional --axis directs this granted round at a chosen canonical category. Parsed BEFORE the
  # re-open block so that block stays byte-untouched. A bare positional <spec> stays informational (the spec
  # comes from the sentinel), exactly as before.
  while [ $# -gt 0 ]; do
    case "$1" in
      --axis)
        axis="${2:-}"
        shift 2 || die "clarify: --axis needs a <canonical-id>"
        # validate the slug against the canonical enum HERE (before any state mutation) so a bad axis fails
        # fast without bumping the grant counter. The HUMAN names the axis; the agent never grades depth.
        catsf="${FORGE_INTAKE_CATEGORIES:-$ROOT/harness/intake-categories.json}"
        { [ -f "$catsf" ] && jq -e --arg a "$axis" 'any(.categories[]; .id==$a)' "$catsf" >/dev/null 2>&1; } || die "clarify --axis: '$axis' is not a canonical category id ($catsf)"
        ;;
      --*) die "clarify: unknown flag: $1 (usage: clarify [<spec>] [--axis <canonical-id>])" ;;
      *) shift ;;
    esac
  done
  sentinel="$(_intake_sentinel)"
  [ -f "$sentinel" ] || die "no active intake to clarify — run: intake.sh start \"<objective>\" --target <repo>"
  hd="$(_intake_harness_dir)"
  # Looping back to clarify after ratification RE-OPENS Gate A and invalidates the prior token — the
  # FRs may move, so the human must re-ratify the new projection before convert will accept it.
  if [ "$(jq -r '.phase // "open"' "$sentinel" 2>/dev/null)" = "ratified" ]; then
    rtmp="$(mktemp)"
    jq '.phase="open"' "$sentinel" >"$rtmp" && mv "$rtmp" "$sentinel" || die "cannot re-open Gate A"
    rm -f "$hd/intake-ratified.json" "$hd/intake-breakdown-ratified.json"
    printf 'intake clarify: re-opened Gate A (phase ratified -> open); prior spec + breakdown ratification tokens invalidated.\n' >&2
  fi
  grantf="$hd/intake-clarify-grant"
  grant=0
  [ -f "$grantf" ] && grant="$(cat "$grantf" 2>/dev/null || printf 0)"
  case "$grant" in '' | *[!0-9]*) grant=0 ;; esac
  grant=$((grant + 1))
  mkdir -p "$hd" || die "cannot create harness dir: $hd"
  printf '%s' "$grant" >"$grantf" || die "cannot record clarify grant"
  # G5: axis-aware grant — record the human-directed canonical category in a FLAT
  # .harness/intake-clarify-axes ledger (the cmd_abort intake-* glob cleans it). Advisory direction for the
  # spec-reviewer/Architect to dig THAT axis; the budget scalar above still lifts the ceiling. The slug is
  # constrained to the canonical enum — the HUMAN names the axis; the agent never grades depth or coverage.
  if [ -n "$axis" ]; then
    axesf="$hd/intake-clarify-axes"
    printf '%s\n' "$axis" >>"$axesf" || die "cannot record clarify axis"
  fi
  spec="$(jq -r '.spec // empty' "$sentinel" 2>/dev/null)"
  cat <<EOF

✓ intake clarify: granted one more clarify round (human override; +$grant beyond the budget).
  spec: $spec
  The Architect may ask ONE more AskUserQuestion round, then MUST log it as '### Round N — <date>' in
  ## Clarifications and propagate the answer. Remaining ambiguities still route to flagged [ASSUMED ...]
  (F1: no cap on assumptions).
EOF
  # if-block (NOT `[ -n ] && printf`): as the function's last statement the && form would return the test's
  # exit (1) when no --axis was given, making a plain `clarify` exit non-zero.
  if [ -n "$axis" ]; then
    printf '  directed axis: %s — point the spec-reviewer at this canonical category for the granted round (the human directs depth; the agent never grades it).\n' "$axis" >&2
  fi
}

# abort — clear the active-intake sentinel + ALL intake state (to start over or recover a wedged scaffold).
# Mirrors kill-switch.sh's release for the build loop. Does NOT delete the spec (it stays under specs/).
cmd_abort() {
  local sentinel hd spec
  sentinel="$(_intake_sentinel)"
  hd="$(_intake_harness_dir)"
  if [ -f "$sentinel" ]; then
    spec="$(jq -r '.spec // empty' "$sentinel" 2>/dev/null)"
    rm -f "$sentinel"
    printf 'intake aborted: cleared the active-intake sentinel (spec left in place: %s)\n' "$spec"
  else
    printf 'intake abort: no active intake.\n'
  fi
  # Fold-in 1: clear ALL intake state, closed-by-construction — the glob catches every present AND
  # future .harness/intake-* state file (today: intake-clarify-rounds, intake-clarify-grant,
  # intake-stop-blocks, and the Gate-A intake-ratified.json token the old enumerated list missed); it can
  # never catch the build loop's active-task.json. The sentinel is named explicitly because
  # active-intake.json does not match the intake-* prefix.
  rm -f "$sentinel" "$hd"/intake-* 2>/dev/null
}

# ratify [<spec>] — the HUMAN's Gate-A sign-off. Verifies the FULL Gate-A floor — not a subset: a
# terminal-side ratify can PRECEDE the agent's Stop, so the floor cannot be left to the Stop gate alone.
# Checks: understanding.md projection, zero residual markers, the reviewer loop actually ran (>=1
# restatement round), consensus-or-UNRECONCILED. Then binds a token to sha256(understanding.md) (so any
# later drift is caught) and flips the sentinel to phase=ratified. The token lives in .harness/
# (ENFORCE_RE blocks Architect tool-writes there), so it cannot be FORGED via a Write/Edit; only this
# command — run from the human's un-hooked terminal — mints it.
cmd_ratify() {
  # HIGH-1 (THE REAL FIX): Gate-A sign-off is a HUMAN action. Require an interactive terminal on BOTH
  # stdin and stdout — the agent's Bash tool runs non-TTY, so it refuses here. This catches `bash
  # wrapper.sh` and every invocation form the deny-hook string matcher cannot. Honest residual: an agent
  # that allocates a PTY (script/pty) AND routes through a wrapper file dodging the deny regex remains — the
  # same OS-confinement class as the symlink portal (HIGH-2), durably closed at the OS/mount layer, not here.
  { [ -t 0 ] && [ -t 1 ]; } || die "ratify is the human's Gate-A sign-off and must be run from an interactive terminal (no TTY on stdin/stdout) — the agent session cannot self-ratify"
  intake_load_config
  local sentinel hd spec und rst rrounds open tokf sha stmp frsha _catsf _ledger _catset _cc srec _rsha
  sentinel="$(_intake_sentinel)"
  [ -f "$sentinel" ] || die "no active intake to ratify — nothing to sign"
  spec="$(jq -r '.spec // empty' "$sentinel" 2>/dev/null)"
  [ -n "$spec" ] && [ -f "$spec" ] || die "intake sentinel names no readable spec ($spec)"
  und="$(dirname "$spec")/understanding.md"
  [ -f "$und" ] || die "understanding.md not found ($und) — Gate A is not ready (run the restatement loop first)"
  grep -qE '^## What the FRs will build' "$und" || die "understanding.md lacks its '## What the FRs will build' projection — not ratifiable"
  grep -qF '[NEEDS CLARIFICATION' "$spec" && die "the spec still has an unresolved [NEEDS CLARIFICATION] marker — resolve it before ratifying"
  # Fold-in 2: the reviewer-loop evidence. Without it, a hand-written understanding.md is ratifiable
  # with the spec-reviewer never spawned. Patterns mirror stop-gate-intake.sh exactly.
  rst="$(dirname "$spec")/restatement.md"
  [ -f "$rst" ] || die "restatement.md not found ($rst) — the Gate-A spec-reviewer loop never ran; >=1 restatement round is required before sign-off"
  rrounds="$(grep -cE '^### Restatement round ' "$rst" 2>/dev/null)"
  case "$rrounds" in '' | *[!0-9]*) rrounds=0 ;; esac
  [ "$rrounds" -ge 1 ] || die "restatement.md records no '### Restatement round N' — the Gate-A spec-reviewer loop never ran; >=1 round is required before sign-off"
  # C7 evidence (re-expressed): a HARNESS-CAPTURED spec-review record must exist — proof the
  # spec-reviewer actually ran and its verdict was captured by the harness (`intake.sh spec-review` writes
  # .harness/intake-spec-review.json — agent-tool-unwritable), not merely transcribed into restatement.md.
  # restatement.md persists as the reconcile narrative (D2); THIS is the real "the review loop ran" evidence,
  # and (below) its open-count is the consensus oracle. cmd_ratify-only — the Stop floor has no such
  # requirement (the C7 asymmetry preserved).
  srec="$(_intake_harness_dir)/intake-spec-review.json"
  [ -f "$srec" ] || die "no harness-captured spec-review record ($srec) — run: intake.sh spec-review (the Gate-A spec-reviewer must run and be harness-captured before sign-off; restatement.md transcription is no longer the consensus oracle)"
  # Anti-TOCTOU: the record must have reviewed the CURRENT spec — a clean review followed by a spec
  # edit (add an FR, wave off a catastrophic category) must NOT mint on a stale open=0. Mirrors convert's
  # understanding.md/FR drift-refusal (see cmd_convert). Re-hash via the SAME whole-file sha cmd_spec_review stored.
  _rsha="$(jq -r '.spec_sha256 // empty' "$srec" 2>/dev/null)"
  { [ -n "$_rsha" ] && [ "$_rsha" = "$(sha256sum "$spec" | cut -d' ' -f1)" ]; } || die "the spec changed since the spec-review (record sha=$_rsha != current spec sha) — re-run: intake.sh spec-review (anti-TOCTOU: a stale review cannot ratify the edited spec)"
  # Consensus-or-UNRECONCILED: open findings are ratifiable ONLY when understanding.md SURFACES them in a
  # non-empty ## UNRECONCILED block — the gate forces VISIBILITY; the human adjudicates. (Not a reviewer
  # veto: with the findings surfaced, ratification proceeds on the human's say-so alone.)
  open="$(jq '(.findings // []) | length' "$srec" 2>/dev/null)" # the consensus oracle is the captured record, not the transcribed restatement.md lines
  case "$open" in '' | *[!0-9]*) open=0 ;; esac
  if [ "$open" -gt 0 ]; then
    awk '/^## UNRECONCILED/{u=1;next} /^## /{u=0} u && NF && $0 !~ /^[[:space:]]*<!--/ {f=1} END{exit f?0:1}' "$und" ||
      die "$open open DISAGREE/ESCALATE finding(s) in restatement.md and no non-empty ## UNRECONCILED in understanding.md — the projection would hide open disagreement; reconcile them or surface them, then re-run ratify"
  fi
  # G3 (B+C) — the CATASTROPHIC-tier ratify floor: the UN-BYPASSABLE copy of the Stop-floor catastrophic nudge.
  # cmd_ratify can PRECEDE the agent Stop and (above) re-checks only markers + consensus, never coverage — so a
  # catastrophic category waved off as `deliberately N/A` would mint a token. A category in THIS intake's
  # catastrophic set (the sentinel's .risk.catastrophic, set human-TTY-only by `intake.sh risk`; else the
  # registry by-default tier from the enum, so the floor is active even if risk was never run) must be
  # covered/surfaced in the ## Deferrals ledger, never ONLY `deliberately N/A`. Token-TYPE, never adequacy — it
  # never judges whether the coverage is GOOD. Holds even against the human's "enough": cover/surface it, or
  # consciously de-escalate via `intake.sh risk --remove <slug>` (also human-TTY-only). Fail-closed if the enum
  # is unreadable — a catastrophic floor that cannot resolve its set must not mint. Shares the SAME resolution +
  # token-type grep as stop-gate-intake.sh's nudge (the two MUST agree). Additive: the consensus/mint logic
  # above and below is byte-untouched.
  _catsf="${FORGE_INTAKE_CATEGORIES:-$ROOT/harness/intake-categories.json}"
  [ -f "$_catsf" ] || die "G3: canonical coverage taxonomy not found ($_catsf) — cannot verify the catastrophic floor before minting (fail closed)"
  _ledger="$(awk '/^## Deferrals/{f=1;next} /^## /{f=0} f' "$spec")"
  _catset="$(jq -r '.risk.catastrophic[]?' "$sentinel" 2>/dev/null)"
  [ -z "$_catset" ] && _catset="$(jq -r '.categories[]? | select(.risk_default=="by-default") | .id' "$_catsf" 2>/dev/null)"
  # Review fold-in: a present-but-corrupt/unreadable enum yields an empty catastrophic set — fail closed
  # (the floor cannot resolve its set, so it must die, never mint). Matches the literal "unreadable enum -> die".
  [ -n "$_catset" ] || die "G3: empty catastrophic set — the coverage taxonomy is unreadable/corrupt (fail closed; cannot verify the catastrophic floor before minting)"
  while IFS= read -r _cc; do
    [ -n "$_cc" ] || continue
    printf '%s\n' "$_ledger" | awk -F' — ' -v cc="$_cc" '$1 == "- `" cc "`" {print $2}' | grep -qE '(covered by|surfaced)' ||
      die "G3 catastrophic floor: category '$_cc' is mission-critical for this intake but its ## Deferrals disposition is not covered/surfaced (waved off as 'deliberately N/A' or absent) — cover it (covered by FR-NNN) or surface it (surfaced — <ref>), or de-escalate it deliberately: intake.sh risk --remove $_cc"
  done <<EOF
$_catset
EOF
  sha="$(sha256sum "$und" | cut -d' ' -f1)" || die "cannot hash understanding.md"
  frsha="$(_intake_fr_hash "$spec")"   # also bind the FR-definition lines
  hd="$(_intake_harness_dir)"
  tokf="$hd/intake-ratified.json"
  mkdir -p "$hd" || die "cannot create harness dir: $hd"
  stmp="$(mktemp)"
  jq -nc --arg spec "$spec" --arg sha "$sha" --arg frsha "$frsha" --arg ts "$(date -u +%FT%TZ)" \
    '{spec:$spec,sha256:$sha,fr_sha256:$frsha,ratified_at:$ts,human_origin:true}' >"$stmp" && mv "$stmp" "$tokf" || die "cannot write ratify token"
  stmp="$(mktemp)"
  jq '.phase="ratified"' "$sentinel" >"$stmp" && mv "$stmp" "$sentinel" || die "cannot advance sentinel phase"
  cat <<EOF

✓ Gate A ratified: $spec
  understanding.md sha256: $sha
  FR-definition lines sha256: $frsha   (bound — a post-ratify FR edit is refused at convert)
  phase: open -> ratified   (the Gate-A Stop floor is satisfied; decompose may proceed)
  convert re-hashes understanding.md AND the FR-definition lines, refusing on ANY drift (anti-TOCTOU).
  Next — decompose into the Task Breakdown, then: intake.sh ratify-breakdown -> intake.sh analyze (Gate B) -> intake.sh convert.
EOF
}

# ratify-breakdown [<spec>] — cp-gateA' (R5a): Gate A′, the HUMAN breakdown sign-off. Run AFTER
# decompose, BEFORE analyze/convert. Binds the Task Breakdown block by hash into a SECOND token so convert
# mints ONLY what the human signed — closing F3 (today ratify binds understanding.md + the FR lines,
# but the task block is authored after ratify and unbound, so an agent could rewrite DoD/SC/scope in the
# ratify->convert window and convert would mint it). TTY-gated EXACTLY like cmd_ratify: the agent's non-TTY
# Bash refuses — that is THE guarantee (the deny-hook string match is only defense-in-depth). Blind-approve
# by design: the block is displayed + inspectable, but reviewing it is never required (one keystroke). The
# token lives in .harness/ (ENFORCE_RE blocks Architect tool-writes there), so it cannot be FORGED via a
# Write/Edit — only this command, run from the human's un-hooked terminal, mints it.
cmd_ratify_breakdown() {
  { [ -t 0 ] && [ -t 1 ]; } || die "ratify-breakdown is the human's Gate-A′ sign-off and must be run from an interactive terminal (no TTY on stdin/stdout) — the agent session cannot self-ratify the breakdown"
  intake_load_config
  local sentinel hd spec nblocks tsha stmp phase
  sentinel="$(_intake_sentinel)"
  [ -f "$sentinel" ] || die "no active intake to ratify-breakdown — nothing to sign"
  phase="$(jq -r '.phase // "open"' "$sentinel" 2>/dev/null)"
  [ "$phase" = "ratified" ] || die "Gate A (the spec) is not ratified (phase=$phase) — run: intake.sh ratify, before signing the breakdown (pipeline: ratify -> decompose -> ratify-breakdown)"
  spec="$(jq -r '.spec // empty' "$sentinel" 2>/dev/null)"
  [ -n "$spec" ] && [ -f "$spec" ] || die "intake sentinel names no readable spec ($spec)"
  # exactly one Task Breakdown block, else the hash is ill-defined (mirror cmd_analyze's count guard)
  nblocks="$(grep -cF '<!-- forge:tasks:begin' "$spec" 2>/dev/null)"
  case "$nblocks" in '' | *[!0-9]*) nblocks=0 ;; esac
  [ "$nblocks" -eq 1 ] || die "ratify-breakdown: expected exactly one Task Breakdown block in $spec (found $nblocks) — run decompose first"
  # DISPLAY the block (inspectable; blind-approve allowed). definition_of_done + success_criteria are what
  # the human reads here. Output goes to stderr so a piped/redirected convert pipeline is unaffected.
  printf '\n=== Gate A′: Task Breakdown to ratify (%s) ===\n' "$spec" >&2
  _intake_task_block "$spec" >&2
  printf '=== end Task Breakdown — this is what convert will mint ===\n' >&2
  tsha="$(_intake_task_hash "$spec")"
  hd="$(_intake_harness_dir)"
  mkdir -p "$hd" || die "cannot create harness dir: $hd"
  stmp="$(mktemp)"
  jq -nc --arg spec "$spec" --arg tsha "$tsha" --arg actor "${USER:-$(id -un 2>/dev/null || printf unknown)}" --arg ts "$(date -u +%FT%TZ)" \
    '{spec:$spec,task_sha256:$tsha,actor:$actor,ratified_at:$ts,human_origin:true}' >"$stmp" && mv "$stmp" "$hd/intake-breakdown-ratified.json" || die "cannot write breakdown ratify token"
  cat <<EOF

✓ Gate A′ ratified: the Task Breakdown of $spec
  task block sha256: $tsha   (bound — a post-sign-off task-block edit is refused at convert, anti-TOCTOU)
  convert re-hashes the task block via the SAME extractor and the spec/FR/breakdown tokens must be fresh + human-origin.
  Next: intake.sh analyze (Gate B) -> intake.sh convert.
EOF
}

# analyze [<spec>] — Gate B: the mechanical Task-Breakdown gate. Validates the nine fail-loud
# invariants from templates/spec-template.md over the spec's task block, then BIDIRECTIONAL FR<->task
# traceability (F5): every task's `satisfies` resolves to an FR-NNN / USn DEFINED in the prose, and every
# defined FR is covered by >=1 task. PURE string cross-reference (awk/grep/jq) — no LLM judgment anywhere
# in this blocking path. STRICTLY READ-ONLY: verifies the artifacts, never edits them, writes no .harness
# state. Resolution: an explicit <spec> path wins (standalone re-check); else the active intake's sentinel.
cmd_analyze() {
  local spec="${1:-}" sentinel
  if [ -z "$spec" ]; then
    sentinel="$(_intake_sentinel)"
    [ -f "$sentinel" ] || die "analyze: no <spec> argument and no active intake — run: intake.sh analyze <spec.md>"
    spec="$(jq -r '.spec // empty' "$sentinel" 2>/dev/null)"
  fi
  { [ -n "$spec" ] && [ -f "$spec" ]; } || die "analyze: spec not found ($spec)"

  # ── task block: exactly one, sentinel-sliced, fence-stripped, valid JSON ─────────────────────────────
  local nblocks json
  nblocks="$(grep -cF '<!-- forge:tasks:begin' "$spec" 2>/dev/null)"
  case "$nblocks" in '' | *[!0-9]*) nblocks=0 ;; esac
  [ "$nblocks" -eq 0 ] && die "analyze: no '<!-- forge:tasks:begin v1 -->' Task Breakdown block in $spec — author it per the decompose skill"
  [ "$nblocks" -gt 1 ] && die "analyze: $nblocks begin-sentinels in $spec — exactly one Task Breakdown block is allowed"
  json="$(_intake_task_block "$spec")"
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || die "analyze: the Task Breakdown block is not valid JSON"
  printf '%s' "$json" | jq -e '(.tasks | type) == "array" and (.tasks | length) > 0' >/dev/null 2>&1 ||
    die "analyze: .tasks is missing or empty — a Task Breakdown with zero tasks is not a decomposition"

  # ── the six invariants (templates/spec-template.md) — fail-loud, offender NAMED in every die ────────
  local bad
  # 1. every task carries all required keys
  bad="$(printf '%s' "$json" | jq -r '.tasks | to_entries[] | (["id","title","satisfies","priority","depends_on","target_repo","definition_of_done","success_criteria"] - (.value | keys)) as $miss | select($miss | length > 0) | "task \(.value.id // "#\(.key)") missing required key(s): \($miss | join(", "))"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 1): $bad"
  # 2. id shape + uniqueness
  bad="$(printf '%s' "$json" | jq -r '.tasks[].id | tostring | select(test("^T[0-9]{3}$") | not)' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 2): task id '$bad' does not match ^T[0-9]{3}\$"
  bad="$(printf '%s' "$json" | jq -r '.tasks | map(.id) | group_by(.) | map(select(length > 1) | .[0]) | .[]' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 2): duplicate task id $bad"
  # 3. priority enum
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | select(.priority | tostring | test("^P[123]$") | not) | "task \(.id): priority \(.priority | tostring)"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 3): $bad is not one of P1|P2|P3"
  # 4a. every depends_on resolves — checked BEFORE the cycle scan, so a dangling dep cannot masquerade as
  #     a prunable (cycle-free) node.
  bad="$(printf '%s' "$json" | jq -r '(.tasks | map(.id)) as $ids | .tasks[] | .id as $t | .depends_on[]? | select(. as $d | $ids | index($d) | not) | "task \($t): depends_on \(.) resolves to no task id"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 4): $bad"
  # 4b. acyclic — iteratively prune nodes that depend on no REMAINING node; any leftover IS a cycle.
  bad="$(printf '%s' "$json" | jq -r '
    def prune: map(.id) as $ids
      | map(select([.deps[] | select(. as $d | $ids | index($d))] | length > 0)) as $stuck
      | if ($stuck | length) == length then . else ($stuck | prune) end;
    [.tasks[] | {id: .id, deps: .depends_on}] | prune | map(.id) | join(", ")')"
  [ -n "$bad" ] && die "analyze (invariant 4): depends_on cycle among: $bad"
  # 5. satisfies / definition_of_done / success_criteria each non-empty
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | . as $t | ("satisfies", "definition_of_done", "success_criteria") | select(($t[.] | length) == 0) | "task \($t.id): \(.) is empty"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 5): $bad"
  # 6. target_repos non-empty; every target_repo a member
  bad="$(printf '%s' "$json" | jq -r 'if (.target_repos | type) != "array" or (.target_repos | length) == 0 then "top-level target_repos is missing or empty" else (.target_repos as $r | .tasks[] | select(.target_repo as $t | $r | index($t) | not) | "task \(.id): target_repo \(.target_repo | tostring) is not in target_repos [\($r | join(", "))]") end' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 6): $bad"

  # ── invariants 7-9 (cp-schema) — the three machine fields the acceptance gate reads ────────────────
  # Formats are NORMATIVE in templates/spec-template.md ("Selector and glob formats"); these checks and
  # that section must never diverge. Pure jq — no LLM, no execution (invariant 8 is SYNTACTIC only:
  # analyze stays read-only; the mechanical acceptance gate RUNS the selectors). Fail-loud,
  # offender NAMED in every die, exactly as invariants 1-6. Every if/elif chain is ordered so no jq
  # branch can error on an unexpected type (a jq error would empty $bad and FAIL OPEN — never allowed).
  # Precondition for 7-9: every tasks[] element is an object. has()/.field on a non-object ERRORS in
  # jq — emptying $bad and failing OPEN through every chain below (the forbidden class; invariants 1-6
  # fail open the same way on such an element and only the traceability stage's own jq error rescues
  # the verdict, with the wrong offender named). Fail closed HERE, offender named by index.
  bad="$(printf '%s' "$json" | jq -r '.tasks | to_entries[] | select((.value | type) != "object") | "task #\(.key) is not an object (got \(.value | type)) — every tasks[] element must be a JSON task object"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariants 7-9): $bad"
  # 7. scope: non-empty array of well-formed repo-relative globs — no absolute path, no '..' anywhere
  #    (the cp-4 *..* traversal class, fail closed), no empty entry, character-allowlisted to the
  #    POSIX-pattern alphabet (no braces: {a,b} is shell EXPANSION, not matching — a case-style
  #    scope matcher would silently never match it).
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | select((has("scope") | not) or ((.scope | type) != "array") or ((.scope | length) == 0)) | "task \(.id // "?"): scope is missing or empty — every task must declare the files its build may touch"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 7): $bad"
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | .id as $t | .scope[] | if type != "string" then "task \($t): scope entry \(. | @json) is not a string" elif (. == "") or startswith("/") or contains("..") or ((test("^[A-Za-z0-9._*?\\[\\]/-]+$")) | not) then "task \($t): scope entry \(. | @json) is not a well-formed repo-relative glob (empty, absolute, contains \"..\", or a character outside [A-Za-z0-9._*?[]/-])" else empty end' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 7): $bad"
  # 8. dod_tests: non-empty array; every entry a syntactically-valid selector
  #    (tests|sandbox)/<segments> — every path segment starts alphanumeric (kills '..', dotfiles,
  #    '-rf'-shaped segments). The ::pattern form was removed (A2: it reserved a convention
  #    R-A calls undefined; the gate C2 never ran it). The explicit '..' check is redundant with
  #    the segment anchor but kept for the named cp-4-class error.
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | select((has("dod_tests") | not) or ((.dod_tests | type) != "array") or ((.dod_tests | length) == 0)) | "task \(.id // "?"): dod_tests is missing or empty — the mechanical DoD needs >=1 named runnable test"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 8): $bad"
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | .id as $t | .dod_tests[] | if type != "string" then "task \($t): dod_tests entry \(. | @json) is not a string" elif contains("..") then "task \($t): dod_tests entry \(. | @json) contains \"..\" — selectors are repo-relative (fail closed)" elif (test("^(tests|sandbox)(/[A-Za-z0-9][A-Za-z0-9._-]*)+$")) | not then "task \($t): dod_tests entry \(. | @json) is not a valid selector — expected (tests|sandbox)/<path> per templates/spec-template.md (Selector and glob formats)" else empty end' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 8): $bad"
  # 9. sc_evidence: non-empty array of {sc, path}; BIDIRECTIONAL against THIS task's success_criteria
  #    (the FR<->task traceability pattern, one level down): every entry resolves to a defined 1-based
  #    SC index, every SC index is covered by >=1 entry, every path a well-formed repo-relative file.
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | select((has("sc_evidence") | not) or ((.sc_evidence | type) != "array") or ((.sc_evidence | length) == 0)) | "task \(.id // "?"): sc_evidence is missing or empty — every success criterion needs a declared evidence path"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 9): $bad"
  #    success_criteria must be a real array BEFORE its length is used as the SC count: jq length on a
  #    scalar is its magnitude (1/"x"/{"k":v} would make coverage vacuously "bidirectional") and on a
  #    boolean it ERRORS — emptying $bad and failing OPEN (the forbidden class). Fail closed, named.
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | select((.success_criteria | type) != "array") | "task \(.id): success_criteria is not an array (got \(.success_criteria | type)) — sc_evidence needs a 1-based criteria list to index into"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 9): $bad"
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | .id as $t | (.success_criteria | length) as $n | .sc_evidence[] | if type != "object" then "task \($t): sc_evidence entry \(. | @json) is not a {sc, path} object" elif (.sc? | type) != "number" then "task \($t): sc_evidence entry \(. | @json) needs a numeric sc (a 1-based index into success_criteria)" elif (.sc | floor) != .sc then "task \($t): sc_evidence sc \(.sc) is not an integer (sc is a 1-based index into success_criteria)" elif (.sc < 1) or (.sc > $n) then "task \($t): sc_evidence sc \(.sc) resolves to no success_criteria index (task defines \($n))" elif (.path? | type) != "string" then "task \($t): sc_evidence entry \(. | @json) needs a string path" elif (.path == "") or (.path | startswith("/")) or (.path | contains("..")) or (((.path | test("^[A-Za-z0-9][A-Za-z0-9._/-]*$"))) | not) then "task \($t): sc_evidence path \(.path | @json) is not a well-formed repo-relative file (empty, absolute, contains \"..\", or a character outside [A-Za-z0-9._/-])" else empty end' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 9): $bad"
  bad="$(printf '%s' "$json" | jq -r '.tasks[] | .id as $t | [.sc_evidence[]? | .sc? | select(type == "number")] as $cov | range(1; (.success_criteria | length) + 1) | select(. as $i | $cov | index($i) | not) | "task \($t): success_criteria #\(.) has no sc_evidence entry — uncovered SC (bidirectional, like FR<->task)"' | head -1)"
  [ -n "$bad" ] && die "analyze (invariant 9): $bad"
  # 9 (A3): every sc_evidence path must fall under >=1 scope glob — the SAME bash case-pattern
  # the acceptance gate's C1 uses (accept-gate.sh). A path NEW this task AND out of scope is an
  # UNSATISFIABLE contract at the gate (C3 stages it, C1 rejects it as out-of-scope). jq cannot
  # glob-match; the scope alphabet (inv 7) and path alphabet (inv 9) are already validated — no spaces,
  # no '..', POSIX chars only — so each is safe unquoted as a case pattern.
  local _sct _scid _scp _scg _scm
  local -a _scglobs
  while IFS= read -r _sct; do
    [ -n "$_sct" ] || continue
    _scid="$(jq -r '.id' <<<"$_sct")"
    _scglobs=()
    while IFS= read -r _scg; do [ -n "$_scg" ] && _scglobs+=("$_scg"); done < <(jq -r '.scope[]?' <<<"$_sct")
    while IFS= read -r _scp; do
      [ -n "$_scp" ] || continue
      _scm=0
      for _scg in "${_scglobs[@]}"; do case "$_scp" in $_scg) _scm=1; break ;; esac; done
      [ "$_scm" = 1 ] || die "analyze (invariant 9): task $_scid: sc_evidence path \"$_scp\" is matched by no scope glob (${_scglobs[*]}) — an out-of-scope evidence path is unsatisfiable at the gate (C3 stages it, C1 rejects it; A3)"
    done < <(jq -r '.sc_evidence[]?.path' <<<"$_sct")
  done < <(printf '%s' "$json" | jq -c '.tasks[]?')

  # ── bidirectional FR<->task traceability (F5) — pure string cross-reference ─────────────────────────
  # Defined ids come from the PROSE: '- **FR-NNN:**' requirement lines (a withdrawn '~~FR-NNN~~' no longer
  # matches, so it drops out of the coverage set) and '### USn ' story headings. The line-anchored patterns
  # cannot collide with JSON content inside the task block.
  local frs uss covered danglings uncovered
  frs="$(grep -oE '^- \*\*FR-[0-9]{3}:\*\*' "$spec" 2>/dev/null | grep -oE 'FR-[0-9]{3}' | sort -u)"
  [ -n "$frs" ] || die "analyze (Gate B traceability): no FR definitions in the prose ('- **FR-NNN:** ...') — nothing to trace the Task Breakdown against"
  uss="$(grep -oE '^### US[0-9]+[[:space:]]' "$spec" 2>/dev/null | grep -oE 'US[0-9]+' | sort -u)"
  danglings="$(printf '%s' "$json" | jq -r '.tasks[] | .id as $t | .satisfies[] | "\($t)\t\(. | tostring)"' |
    while IFS=$'\t' read -r t ref; do
      [ -n "$t" ] || continue
      if printf '%s' "$ref" | grep -qE '^FR-[0-9]{3}$'; then
        printf '%s\n' "$frs" | grep -qFx "$ref" || printf 'task %s satisfies %s — no such FR is defined in the prose\n' "$t" "$ref"
      elif printf '%s' "$ref" | grep -qE '^US[0-9]+$'; then
        printf '%s\n' "$uss" | grep -qFx "$ref" || printf 'task %s satisfies %s — no such US story is in the prose\n' "$t" "$ref"
      else
        printf 'task %s satisfies "%s" — not an FR-NNN / USn reference\n' "$t" "$ref"
      fi
    done)"
  [ -n "$danglings" ] && die "Gate B traceability — dangling satisfies ref(s):
$danglings"
  covered="$(printf '%s' "$json" | jq -r '[.tasks[].satisfies[] | tostring] | unique | .[]')"
  uncovered="$(printf '%s\n' "$frs" | while read -r fr; do
    [ -n "$fr" ] || continue
    printf '%s\n' "$covered" | grep -qFx "$fr" || printf '%s ' "$fr"
  done)"
  [ -n "$uncovered" ] && die "Gate B traceability — uncovered FR(s), defined in the prose but satisfied by NO task: ${uncovered% }"

  local ntasks nfrs
  ntasks="$(printf '%s' "$json" | jq -r '.tasks | length')"
  nfrs="$(printf '%s\n' "$frs" | grep -c .)"
  cat <<EOF

✓ analyze: Gate B PASS — $spec
  invariants:   all nine hold (keys; id shape+unique; priority; depends_on resolved+acyclic; non-empty; target_repo; scope globs; dod_tests selectors; sc_evidence bidirectional)
  traceability: $ntasks task(s) <-> $nfrs FR(s), bidirectional — every satisfies resolves, every FR covered
  Next: intake.sh convert   (gated on the human Gate-A token)
EOF
}

# The converter half of the floor witness (fx-v0w): re-assert the enforcement floor is PRESENT before minting — never
# assume the session that reached convert actually loaded the hooks (an off-root launch loads nothing,
# claude-code#12962). Mechanical presence checks only; the unattended-runner half lives in run-task.sh.
convert_preflight() {
  local hooks="$ROOT/.claude/hooks"
  # LOW (fail-closed): the minter builds bodies + metadata + the topo order with jq — absent jq it
  # would silently misbuild. Refuse before any bd create.
  command -v jq >/dev/null 2>&1 || die "convert: jq not found on PATH — cannot build or verify the mint (preflight, fail closed)"
  { [ -f "$hooks/pre-tool-use-deny.sh" ] && [ -x "$hooks/pre-tool-use-deny.sh" ]; } ||
    die "convert: enforcement preflight FAILED — $hooks/pre-tool-use-deny.sh missing or not executable; refusing to mint without the floor (fx-v0w)"
  [ -f "$hooks/lib.sh" ] ||
    die "convert: enforcement preflight FAILED — $hooks/lib.sh missing (fx-v0w)"
  grep -qF 'pre-tool-use-deny.sh' "$ROOT/.claude/settings.json" 2>/dev/null ||
    die "convert: enforcement preflight FAILED — the deny hook is not registered in $ROOT/.claude/settings.json (fx-v0w)"
  # cp-witness: prove the deny floor LOADED in THIS session — hash-pinned SessionStart
  # witness, self-identified via CLAUDE_SESSION_ID (PROBE-A.4). Generalizes the grep above
  # (presence -> hash). HARD under FORGE_UNATTENDED=1, AND HARD attended on a clean witnessed session;
  # warn-only attended ONLY while the floor is under active edit or the checkout never minted a witness
  # (see forge_witness_gate).
  # declare -F guard: forge_witness_gate lives in lib.sh (the cp-witness splice). When intake runs
  # against a $ROOT whose lib.sh predates that splice (a stub-lib test throwaway, or an un-upgraded
  # checkout), the function is absent — degrade to the mechanical presence checks above rather than
  # dying on an undefined command. When loaded, its own two-mode logic decides hard-vs-warn.
  if declare -F forge_witness_gate >/dev/null 2>&1; then
    forge_witness_gate "$ROOT" ||
      die "convert: session-floor witness FAILED — the deny floor is not proven loaded in this session (fx-v0w; FORGE_UNATTENDED=1)"
  fi
}

# convert [<spec>] — THE MINTER, behind every gate in order: (1) sentinel + phase=ratified + the
# human's token; (2) anti-TOCTOU re-hash of understanding.md; (3) Gate B — cmd_analyze
# runs in-process and die()s with the named offender on any violation; (4) the enforcement-floor
# preflight. Only then mint, in topological depends_on order, recording a T0NN -> minted-id crosswalk
# under the spec dir, then add the blocks edges, then clear the sentinel + ALL intake state.
# ZERO-INTERPOLATION: spec content travels as DATA only — quoted "$var" argv (never re-parsed by
# a shell), the body via stdin (--body-file -), metadata JSON built by jq --arg (no string splicing).
# Nothing from the spec is ever eval'd or embedded in a command string. The bd ledger is the one
# discovered from the CURRENT working directory (bd's own resolution) — production runs from the repo
# root mint into the real ledger; tests run from a throwaway directory and can never touch it.
cmd_convert() {
  intake_load_config
  local sentinel hd spec specdir und tokf phase want have frwant frhave
  sentinel="$(_intake_sentinel)"
  [ -f "$sentinel" ] || die "no active intake to convert"
  phase="$(jq -r '.phase // "open"' "$sentinel" 2>/dev/null)"
  [ "$phase" = "ratified" ] || die "Gate A not ratified (phase=$phase) — a human must run: intake.sh ratify"
  hd="$(_intake_harness_dir)"
  tokf="$hd/intake-ratified.json"
  [ -f "$tokf" ] || die "no Gate-A ratification token — refusing to convert"
  spec="$(jq -r '.spec // empty' "$sentinel" 2>/dev/null)"
  und="$(dirname "$spec")/understanding.md"
  [ -f "$und" ] || die "understanding.md missing ($und) — cannot verify the ratification binding"
  want="$(jq -r '.sha256 // empty' "$tokf" 2>/dev/null)"
  have="$(sha256sum "$und" | cut -d' ' -f1)"
  { [ -n "$want" ] && [ "$want" = "$have" ]; } || die "understanding.md changed since ratification (anti-TOCTOU: ratified=$want now=$have) — re-ratify before converting"
  # The FR-definition lines must ALSO be unchanged since sign-off. A token with no
  # fr_sha256 is a pre-cp-2 token that never bound the FR lines — FAIL CLOSED (refuse, never skip),
  # so it cannot mint FR content it never covered. Re-extract via the SAME _intake_fr_hash as mint.
  frwant="$(jq -r '.fr_sha256 // empty' "$tokf" 2>/dev/null)"
  [ -n "$frwant" ] || die "ratification token has no fr_sha256 (pre-cp-2 token) — the FR-definition lines were never bound; re-ratify before converting"
  frhave="$(_intake_fr_hash "$spec")"
  [ "$frwant" = "$frhave" ] || die "spec FR-definition lines changed since ratification (ratified=$frwant now=$frhave) — a post-ratify FR edit would mint unratified content; re-ratify before converting"
  printf 'intake: Gate-A ratification verified — understanding.md AND the FR-definition lines unchanged since sign-off.\n' >&2
  # cp-gateA' (B / PROBE-B): the spec ratification must be FRESH + human-origin (always-on, fail-closed).
  _intake_token_human_fresh "$tokf" "Gate-A spec"
  # cp-gateA' (R5a): the Task Breakdown must ALSO be human-ratified (Gate A′) and unchanged since
  # sign-off. A MISSING breakdown token (Gate A′ never run) is FAIL CLOSED — refuse, never skip (mirrors the
  # fr_sha256 pre-cp-2 fail-closed). Re-hash via the SAME _intake_task_hash the sign-off used (no divergence).
  local btok twant thave
  btok="$hd/intake-breakdown-ratified.json"
  [ -f "$btok" ] || die "no Gate-A′ breakdown ratification token — a human must sign the Task Breakdown: intake.sh ratify-breakdown (refusing to convert)"
  _intake_token_human_fresh "$btok" "Gate-A′ breakdown"
  twant="$(jq -r '.task_sha256 // empty' "$btok" 2>/dev/null)"
  [ -n "$twant" ] || die "breakdown ratification token has no task_sha256 (pre-cp-gateA' token) — the Task Breakdown was never bound; re-run ratify-breakdown before converting"
  thave="$(_intake_task_hash "$spec")"
  [ "$twant" = "$thave" ] || die "the Task Breakdown changed since the Gate-A′ sign-off (R5a: ratified=$twant now=$thave) — a post-sign-off task-block edit would mint unratified content; re-run ratify-breakdown before converting"
  printf 'intake: Gate-A′ breakdown ratification verified — the Task Breakdown is unchanged since sign-off.\n' >&2
  specdir="$(dirname "$spec")"
  # cp-mechgate (A1): the stored source_spec MUST be repo-relative — the acceptance
  # gate C0 resolves it as $ROOT/$SRC and rejects an absolute path (source-spec-invalid;
  # mechgate case 15). intake_resolve made $spec absolute; strip $ROOT/ for the values STORED
  # in the bead (the minted source_spec AND the reconcile key that must match it byte-for-byte).
  # Filesystem reads of $spec stay absolute.
  local spec_rel="${spec#"$ROOT"/}"

  # Gate B — analyze MUST pass; it die()s naming the offender, which aborts convert here.
  cmd_analyze "$spec"
  # The floor must be present before anything is minted (fx-v0w).
  convert_preflight
  command -v bd >/dev/null 2>&1 || die "convert: bd not found on PATH — cannot mint"
  # Concern 2: the BD_VERSION_PIN preflight that guards start/finish (beads-lib.sh) must
  # ALSO guard the mint — convert previously checked only `command -v bd`, so a bd drifted from the pin
  # could mint under an unverified JSON contract. The floor (convert_preflight, above) AND the pin
  # are both re-asserted at convert.
  # (beads-lib.sh defaults BD_VERSION_PIN if no beads.config is present.)
  # Source the SIBLING beads-lib.sh ($HERE-relative, like intake.config) so a pre-splice candidate
  # resolves it exactly as the spliced harness/ copy will; forge_beads_load reads $ROOT/harness/beads.config.
  . "$HERE/beads-lib.sh"
  forge_beads_load "$ROOT"
  local _bdv
  _bdv="$(forge_bd version 2>/dev/null | sed -n 's/^bd version \([0-9.][0-9.]*\).*/\1/p' | head -1)"
  if ! forge_beads_check_version "$_bdv" "${BD_VERSION_PIN:-}"; then
    [ "${BD_ALLOW_VERSION_DRIFT:-0}" = "1" ] \
      && printf 'intake: WARNING — bd %s != pinned %s (BD_ALLOW_VERSION_DRIFT=1; proceeding).\n' "${_bdv:-?}" "${BD_VERSION_PIN:-?}" >&2 \
      || die "convert: bd ${_bdv:-?} != pinned ${BD_VERSION_PIN:-?} — the verified JSON contract may not hold; re-pin or set BD_ALLOW_VERSION_DRIFT=1"
  fi

  # Re-extract the task block (analyze just validated it: present, unique, valid JSON, six invariants,
  # bidirectional traceability, acyclic — so topo below cannot loop).
  local json
  json="$(_intake_task_block "$spec")"

  # Topological order over depends_on (Kahn): emit each task once all its deps are emitted.
  local ordered
  ordered="$(printf '%s' "$json" | jq -c '
    def topo($emitted):
      if length == 0 then []
      else ([.[] | select([(.depends_on // [])[] | select(. as $d | $emitted | index($d) | not)] | length == 0)]) as $ready
      | if ($ready | length) == 0 then error("depends_on cycle (analyze should have caught this)")
        else $ready + ((. - $ready) | topo($emitted + ($ready | map(.id)))) end
      end;
    .tasks | topo([]) | .[]')" || die "convert: topological ordering failed"

  # ── mint — IDEMPOTENT (concern 1 / MEDIUM-4): safe to re-run after a partial failure ────────────────
  # Adopt any crosswalk a prior (possibly partial) run wrote, then for each task SKIP if already minted —
  # recorded in the crosswalk, OR (covering a crash BETWEEN bd create and the crosswalk write) found in
  # the ledger by the deterministic "Source: <spec> (<task-id>)" marker every bead carries. The
  # crosswalk is persisted INCREMENTALLY after each create. RECOVERY BOUNDARY: bd create is atomic — it
  # returns an id with the bead committed, or fails with no bead — so the only gap is "bead minted,
  # crosswalk entry not yet written," which the marker reconciliation closes. A re-run completes the
  # remainder and NEVER duplicates. (Zero-interpolation still holds: every spec value is quoted argv or stdin.)
  local tj tid title prio trepo acc acc_json body meta out mid xw existing ledger_json k v
  declare -A XWALK
  xw="$specdir/crosswalk.json"
  if [ -f "$xw" ]; then
    while IFS=$'\t' read -r k v; do [ -n "$k" ] && XWALK[$k]="$v"; done < <(jq -r 'to_entries[]? | "\(.key)\t\(.value)"' "$xw" 2>/dev/null)
  fi
  ledger_json="$(bd list --json 2>/dev/null || printf '[]')"
  while IFS= read -r tj; do
    [ -n "$tj" ] || continue
    tid="$(jq -r '.id' <<<"$tj")"
    if [ -n "${XWALK[$tid]:-}" ]; then printf '  skip %s -> %s (already minted — crosswalk)\n' "$tid" "${XWALK[$tid]}"; continue; fi
    # F5: match STRUCTURED metadata (source_spec+task_id; bd-set, NOT from the spec body) — a
    # bead body embedding another spec's "Source: ..." marker cannot be mis-adopted. MIGRATION
    # BOUNDARY: this reconciles only beads minted WITH the metadata. A PARTIAL convert from before
    # the metadata existed carries no source_spec metadata, so its beads are NOT
    # auto-reconciled — that partial run must be aborted + re-ratified (operator action), not re-run.
    existing="$(printf '%s' "$ledger_json" | jq -r --arg s "$spec_rel" --arg t "$tid" '.[]? | select(.metadata.source_spec == $s and .metadata.task_id == $t) | .id' | head -1)"
    if [ -n "$existing" ]; then XWALK[$tid]="$existing"; _intake_persist_xwalk; printf '  adopt %s -> %s (found in ledger — crosswalk reconciled)\n' "$tid" "$existing"; continue; fi
    title="$(jq -r '.title' <<<"$tj")"
    prio="$(jq -r '.priority' <<<"$tj")"
    trepo="$(jq -r '.target_repo' <<<"$tj")"
    acc="$(jq -r '"- " + (.definition_of_done | join("\n- "))' <<<"$tj")"
    body="$(jq -r --arg spec "$spec_rel" '
      "Satisfies: " + (.satisfies | join(", "))
      + "\n\nDefinition of Done:\n- " + (.definition_of_done | join("\n- "))
      + "\n\nSuccess Criteria:\n- " + (.success_criteria | join("\n- "))
      + (if .verification then "\n\nVerification: " + .verification else "" end)
      + "\n\nSource: " + $spec + " (" + .id + ")"' <<<"$tj")"
    # cp-mechgate (R-B): mint the task's machine contract onto the bead as metadata.accept
    # — jq-to-jq on the validated task object (zero interpolation holds). The acceptance
    # gate cross-checks this CACHE against the spec's task block (the ANCHOR) at finish (R-E).
    # MIGRATION BOUNDARY (mirrors the note above): a PARTIAL pre-extension convert re-run
    # would adopt accept-less beads via the reconcile branch — same remedy: abort + re-ratify,
    # never re-run a partial convert across this splice.
    acc_json="$(jq -c '{scope, dod_tests, sc_evidence}' <<<"$tj")"
    meta="$(jq -nc --arg r "$trepo" --arg s "$spec_rel" --arg t "$tid" --argjson a "$acc_json" '{target_repo:$r, source_spec:$s, task_id:$t, accept:$a}')"
    out="$(printf '%s\n' "$body" | bd create "$title" --body-file - --acceptance "$acc" --metadata "$meta" -p "$prio" 2>&1)" ||
      die "convert: bd create failed for $tid: $out"
    mid="$(printf '%s' "$out" | grep -oE 'Created issue: [a-z][a-z0-9]*-[a-z0-9]{2,}' | head -1 | grep -oE '[a-z][a-z0-9]*-[a-z0-9]{2,}$')"
    [ -n "$mid" ] || die "convert: could not parse the minted id for $tid from bd output: $out"
    XWALK[$tid]="$mid"
    _intake_persist_xwalk
    printf '  minted %s -> %s  (%s)\n' "$tid" "$mid" "$title"
  done <<<"$ordered"

  # ── blocks edges, post-mint via the crosswalk: <task> depends on <dep> ──────────────────────────────
  local d
  while IFS= read -r tj; do
    [ -n "$tj" ] || continue
    tid="$(jq -r '.id' <<<"$tj")"
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      bd dep add --type blocks "${XWALK[$tid]}" "${XWALK[$d]}" >/dev/null 2>&1 ||   # explicit blocks type, never the bd default
        die "convert: bd dep add failed (${XWALK[$tid]} depends on ${XWALK[$d]})"
    done <<<"$(jq -r '.depends_on[]?' <<<"$tj")"
  done <<<"$ordered"

  # ── clear ALL intake state (the abort glob). The crosswalk ($xw) was persisted INCREMENTALLY during the
  # ── mint loop (concern 1), so it already reflects the ledger truth — no final consolidation here. ──
  rm -f "$sentinel" "$hd"/intake-* 2>/dev/null

  local n
  n="$(printf '%s' "$json" | jq -r '.tasks | length')"
  cat <<EOF

✓ convert: minted $n bead(s) from $spec
  crosswalk: $xw
  edges:     every depends_on translated through the crosswalk to a blocks dependency
  sentinel:  cleared (intake complete — the human merge closes the loop)
EOF
}

# risk [--in-scope <f,..>] [--add <slug,..>] [--remove <slug,..>] [--clear] — the HUMAN's per-intake
# catastrophe assignment (B+C G3/G4). TTY-gated EXACTLY like cmd_ratify (the agent's non-TTY Bash refuses) —
# that is THE guarantee; the deny-hook command-match would be defense-in-depth but is a floor-input edit
# (recert), so it is deferred (the TTY gate is the primary guard, mirroring ratify's honest residual).
# Resolves the effective catastrophic set from the canonical enum's risk_default tier + the human inputs and
# stores it (human_origin) in the intake sentinel's .risk; the Stop floor's catastrophic nudge and the
# cmd_ratify catastrophic floor both READ .risk.catastrophic (falling back to the registry by-default tier
# when no assignment exists, so the floor is active even if risk is never run). The `if-in-scope` tier
# elevates to catastrophic ONLY when the human sets a context flag — the agent may SUGGEST it, never set it.
#   risk                         show the in-scope flags + resolved catastrophic set
#   risk --in-scope <f[,f]>      set context (safety-critical|regulated|financial) -> elevate the if-in-scope tier
#   risk --add <slug[,slug]>     additionally mark catastrophic for THIS intake
#   risk --remove <slug[,slug]>  de-escalate (even a by-default category — a deliberate human override)
#   risk --clear                 reset to the registry default (by-default tier only)
cmd_risk() {
  { [ -t 0 ] && [ -t 1 ]; } || die "risk is the human's per-intake catastrophe assignment and must be run from an interactive terminal (no TTY on stdin/stdout) — the agent cannot self-assign risk; the in-scope elevation is a human action, never an agent inference"
  intake_load_config
  local sentinel hd catsf in_scope="" add="" remove="" clear=0 show=0 stmp f s
  sentinel="$(_intake_sentinel)"
  [ -f "$sentinel" ] || die "no active intake — run: intake.sh start \"<objective>\" --target <repo>"
  hd="$(_intake_harness_dir)"
  catsf="${FORGE_INTAKE_CATEGORIES:-$ROOT/harness/intake-categories.json}"
  [ -f "$catsf" ] || die "canonical coverage taxonomy not found ($catsf) — cannot resolve the risk tiers"
  [ $# -eq 0 ] && show=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --in-scope) in_scope="${2:-}"; shift 2 || die "risk: --in-scope needs <flag[,flag]>" ;;
      --add) add="${2:-}"; shift 2 || die "risk: --add needs <slug[,slug]>" ;;
      --remove) remove="${2:-}"; shift 2 || die "risk: --remove needs <slug[,slug]>" ;;
      --clear) clear=1; shift ;;
      *) die "risk: unknown argument: $1 (usage: risk [--in-scope <f,..>] [--add <slug,..>] [--remove <slug,..>] [--clear])" ;;
    esac
  done
  # validate the in-scope context flags against the known set
  if [ -n "$in_scope" ]; then
    for f in $(printf '%s' "$in_scope" | tr ',' ' '); do
      case "$f" in safety-critical | regulated | financial) : ;; *) die "risk: unknown in-scope context '$f' (known: safety-critical, regulated, financial)" ;; esac
    done
  fi
  # validate every add/remove slug is a canonical category id (constrain to the taxonomy)
  for s in $(printf '%s' "$add,$remove" | tr ',' ' '); do
    [ -n "$s" ] || continue
    jq -e --arg s "$s" 'any(.categories[]; .id==$s)' "$catsf" >/dev/null 2>&1 || die "risk: '$s' is not a canonical category id ($catsf)"
  done

  if [ "$show" = 1 ]; then
    printf '\n=== intake risk assignment (%s) ===\n' "$sentinel" >&2
    jq -r '.risk // {} | "in-scope: \((.in_scope // []) | join(", ") | if .=="" then "(none)" else . end)\ncatastrophic (\((.catastrophic // [])|length)): \((.catastrophic // []) | join(", ") | if .=="" then "(none assigned — the registry by-default tier applies)" else . end)"' "$sentinel" >&2
    return 0
  fi

  # resolve the effective catastrophic set: by-default ∪ (if-in-scope IF a context flag is set) ∪ add − remove.
  local elevate=0 addjson removejson scopejson catset n
  { [ "$clear" = 0 ] && [ -n "$in_scope" ]; } && elevate=1
  # build via -n + --arg (null input): an empty string yields a valid "[]" — `printf '' | jq -R` would emit
  # NOTHING (no input line) and pass invalid JSON to the downstream --argjson.
  addjson="$(jq -cn --arg s "$add" '$s | split(",") | map(select(length > 0))')"
  removejson="$(jq -cn --arg s "$remove" '$s | split(",") | map(select(length > 0))')"
  scopejson="$(jq -cn --arg s "$in_scope" '$s | split(",") | map(select(length > 0))')"
  catset="$(jq -n --slurpfile cats "$catsf" --argjson add "$addjson" --argjson remove "$removejson" --argjson elevate "$elevate" \
    '($cats[0].categories) as $c
     | ([ $c[] | select(.risk_default=="by-default") | .id ]
        + (if $elevate==1 then [ $c[] | select(.risk_default=="if-in-scope") | .id ] else [] end)
        + $add)
     | unique | map(select(. as $x | ($remove | index($x)) == null)) | sort')"
  mkdir -p "$hd" || die "cannot create harness dir: $hd"
  stmp="$(mktemp)"
  jq --argjson scope "$scopejson" --argjson cat "$catset" --arg ts "$(date -u +%FT%TZ)" \
    '.risk = {in_scope: $scope, catastrophic: $cat, human_origin: true, set_at: $ts}' "$sentinel" >"$stmp" && mv "$stmp" "$sentinel" || die "cannot write the risk assignment to the sentinel"
  n="$(printf '%s' "$catset" | jq 'length')"
  cat <<EOF

✓ intake risk: $n catastrophic categories assigned for this intake.
  in-scope context: ${in_scope:-(none)}$([ "$elevate" = 1 ] && printf '   (if-in-scope tier ELEVATED to catastrophic)')
  The Stop floor's catastrophic nudge AND the Gate-A ratify floor now require each to be covered/surfaced
  (not 'deliberately N/A'). De-escalate one deliberately with: intake.sh risk --remove <slug>
EOF
}

# ── the HARNESS-CAPTURED Gate-A spec review (closes the transcription trap) ───────────────────────────────
# The Architect calls `intake.sh spec-review` (via Bash, clarify-class — NOT TTY-gated); intake.sh — NOT the
# session — spawns the spec-reviewer as a READ-ONLY backend (the review-task.sh run_reviewer pattern), OWNS its
# stdout, slices the sentinel-JSON verdict, and writes .harness/intake-spec-review.json (agent-tool-unwritable
# via ENFORCE_RE). The Architect picks WHEN to review; it cannot fake the RESULT. The Stop floor + cmd_ratify
# read the record's open-count as the consensus oracle (no longer the Architect-transcribed restatement.md).
# The slice/validate/write are INLINE here — never lib.sh (the review-task.sh lesson: lib.sh is a frozen
# floor-hash input; intake.sh is not). FAIL-CLOSED on the RECORD (absent/dup/malformed block => NO record, a
# loud banner), ADVISORY on the prose. Backend is config-driven: SPEC_REVIEW_BACKEND defaults to
# REVIEWER_BACKEND (reviewers.config, D3) — read-only by construction in every backend (no write tools).
_spec_review_block() { awk '/<!-- forge:spec-review:begin/{f=1;next} /<!-- forge:spec-review:end/{f=0} f && $0 !~ /^```/'; }
cmd_spec_review() {
  intake_load_config
  local sentinel spec specdir und rst hd cfg backend model allowed prompt input out nblk block tmp dir now
  sentinel="$(_intake_sentinel)"
  [ -f "$sentinel" ] || die "no active intake to spec-review — run: intake.sh start \"<objective>\" --target <repo>"
  spec="${1:-$(jq -r '.spec // empty' "$sentinel" 2>/dev/null)}"
  { [ -n "$spec" ] && [ -f "$spec" ]; } || die "spec-review: spec not found ($spec)"
  command -v jq >/dev/null 2>&1 || die "spec-review: jq not found on PATH (fail closed)"
  specdir="$(dirname "$spec")"; und="$specdir/understanding.md"; rst="$specdir/restatement.md"
  hd="$(_intake_harness_dir)"
  cfg="$HERE/reviewers.config"
  # shellcheck source=/dev/null
  [ -f "$cfg" ] && . "$cfg"
  backend="${SPEC_REVIEW_BACKEND:-${REVIEWER_BACKEND:-ollama}}"
  eval "model=\"\${${backend//-/_}_MODEL:-}\""
  eval "allowed=\"\${claude_fresh_ALLOWED_TOOLS:-Read Grep Glob}\""
  # the spec-reviewer system prompt = its agent body (YAML frontmatter stripped), mirroring how review-task.sh
  # builds $PROMPT from reviewer.md.
  local body; body="$ROOT/.claude/agents/spec-reviewer.md"
  [ -f "$body" ] || die "spec-review: $body not found"
  prompt="$(awk 'f; /^---[[:space:]]*$/{c++; if(c==2)f=1}' "$body")"
  # the artifact the reviewer reads (pure text in — works for the no-tool backends too)
  input="$(printf 'Review this DRAFT intake spec against the canonical coverage taxonomy and emit the strict format, ending with the sentinel-JSON block.\n\n<spec path="%s">\n%s\n</spec>\n<understanding>\n%s\n</understanding>\n<restatement>\n%s\n</restatement>\n' \
    "$spec" "$(cat "$spec")" "$(cat "$und" 2>/dev/null)" "$(cat "$rst" 2>/dev/null)")"
  printf '→ spec-review of %s with backend '\''%s'\''%s — READ-ONLY, advisory\n' "$spec" "$backend" "${model:+ (model: $model)}" >&2
  run_spec_reviewer() {
    case "$backend" in
      ollama)
        command -v ollama >/dev/null 2>&1 || { echo "ollama not found"; return 1; }
        printf '%s\n\n%s\n' "$prompt" "$input" | ollama run "$model" --nowordwrap 2>/dev/null ;;
      claude-fresh)
        command -v claude >/dev/null 2>&1 || { echo "claude not found"; return 1; }
        # read-only by construction: NO Bash/Write/Edit in the allowlist => the model cannot form a mutating call.
        # shellcheck disable=SC2086
        (cd "$ROOT" && claude -p --append-system-prompt "$prompt" --allowedTools $allowed \
          --disallowedTools Bash Write Edit MultiEdit NotebookEdit --permission-mode default \
          --add-dir "$specdir" --model "${model:-sonnet}" "$input") ;;
      codex)
        command -v codex >/dev/null 2>&1 || { echo "codex not found"; return 1; }
        printf '%s\n\n%s\n' "$prompt" "$input" | codex exec --sandbox "${codex_SANDBOX:-read-only}" --skip-git-repo-check ${model:+-m "$model"} - ;;
      *) echo "unknown SPEC_REVIEW_BACKEND '$backend'"; return 1 ;;
    esac
  }
  out="$(run_spec_reviewer)"
  # extract + validate the sentinel-JSON verdict block, then persist the record (fail-closed on the RECORD).
  nblk="$(printf '%s\n' "$out" | grep -cF '<!-- forge:spec-review:begin' 2>/dev/null)"
  case "$nblk" in '' | *[!0-9]*) nblk=0 ;; esac
  if [ "$nblk" -ne 1 ]; then
    printf '\n⚠️  SPEC-REVIEW DID NOT PRODUCE A VALID STRUCTURED VERDICT — no record written (%s block(s); backend '\''%s'\'' may be unfit/unavailable). Gate-A consensus reads the record, so a missing record is NOT consensus. Fix the backend and re-run.\n' "$nblk" "$backend" >&2
    printf '%s\n' "$out" >&2
    die "spec-review: no single structured verdict block — refusing to write a record (fail closed)"
  fi
  block="$(printf '%s\n' "$out" | _spec_review_block)"
  printf '%s' "$block" | jq -e '(.verdict | IN("AGREE","DISAGREE")) and (.findings | type == "array") and (if .verdict == "AGREE" then (.findings | length) == 0 else true end) and ((.findings | map(.id)) as $i | ($i|length) == ($i|unique|length)) and (all(.findings[]?; (has("id") and has("category") and has("location") and has("finding")) and (.id|type=="string" and (.|length>0)) and (.finding|type=="string" and (.|length>0))))' >/dev/null 2>&1 ||
    die "spec-review: the verdict block fails the schema (verdict AGREE|DISAGREE; AGREE => empty findings; unique non-empty ids; each finding has id/category/location/finding) — no record written (fail closed)"
  dir="$hd"; mkdir -p "$dir" || die "cannot create harness dir: $dir"
  now="$(date -u +%FT%TZ)"
  # Anti-TOCTOU: bind the record to the spec it reviewed (whole-file sha, mirroring convert's
  # understanding.md hash). The consensus reads (Stop floor + cmd_ratify) refuse a record whose
  # spec_sha256 != the CURRENT spec — a clean review followed by a spec edit can no longer fake consensus.
  local ssha; ssha="$(sha256sum "$spec" | cut -d' ' -f1)"
  tmp="$(mktemp "$dir/intake-spec-review.XXXXXX")" || die "cannot mktemp the record"
  jq -nc --arg spec "$spec" --arg ssha "$ssha" --argjson block "$block" --arg backend "$backend" --arg model "$model" --arg ts "$now" \
    '{spec:$spec, spec_sha256:$ssha, verdict:$block.verdict, findings:($block.findings // []), backend:$backend, model:$model, actor:"harness", ts:$ts}' \
    >"$tmp" 2>/dev/null && mv "$tmp" "$dir/intake-spec-review.json" || { rm -f "$tmp"; die "spec-review: record write failed"; }
  cat <<EOF

✓ spec-review captured: $hd/intake-spec-review.json
  verdict: $(printf '%s' "$block" | jq -r .verdict)   open findings: $(printf '%s' "$block" | jq -r '(.findings // []) | length')
  Gate-A consensus reads THIS record (not restatement.md's transcribed lines). Reconcile each open finding
  (edit the spec / add a reconcile-note in restatement.md), then re-run: intake.sh spec-review — until 0 open.
EOF
}

case "${1:-}" in
  start)
    shift
    cmd_start "$@"
    ;;
  clarify)
    shift
    cmd_clarify "$@"
    ;;
  abort)
    shift
    cmd_abort "$@"
    ;;
  ratify)
    shift
    cmd_ratify "$@"
    ;;
  ratify-breakdown)
    shift
    cmd_ratify_breakdown "$@"
    ;;
  convert)
    shift
    cmd_convert "$@"
    ;;
  analyze)
    shift
    cmd_analyze "$@"
    ;;
  risk)
    shift
    cmd_risk "$@"
    ;;
  spec-review)
    shift
    cmd_spec_review "$@"
    ;;
  *) die 'usage: intake.sh {start "<objective>" --target <repo[,repo...]> [--mode interactive|autonomous] | clarify [--axis <id>] | spec-review | risk [--in-scope <f,..>] [--add <slug,..>] [--remove <slug,..>] [--clear] | ratify | ratify-breakdown | abort | analyze | convert}' ;;
esac
