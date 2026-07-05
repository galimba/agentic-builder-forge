#!/usr/bin/env bash
# harness/beads-lib.sh — shared Beads (bd) helpers for run-task.sh + kill-switch.sh.
#
# Deployed enforcement-protected file: agent edits are floor-denied; changes are authored as sandbox/ candidates and human-spliced under FORGE_ALLOW_HOOK_EDIT=1 (audit-logged).
#
# SOURCED, not executed. No `set -e`/`set -u` (callers vary). The PURE functions below are pinned by
# tests/beads/run.sh against REAL bd v1.0.4 JSON shapes; the GLUE (forge_beads_load / forge_bd /
# forge_beads_preflight) is exercised by the integration suite. bd is ALWAYS run against the single
# DB in the MAIN checkout via forge_bd (bd -C "$ROOT") — never a worktree (single-writer invariant).

# --- defaults so the PURE functions are self-contained without beads.config (unit tests) ----------
: "${BD_BIN:=bd}"
BD_BIN="$(command -v "$BD_BIN" 2>/dev/null || printf '%s' "$BD_BIN")"  # FOLD #5: pin absolute (PATH-axis: bd cannot resolve an agent-shimmed binary)
: "${BD_BLOCKING_TYPES:=blocks}"
: "${BD_REVIEW_STATUS:=in_review}"
: "${BD_VERSION_PIN:=1.0.4}"
: "${BD_RELEASE_ARGS:=update %s --status open --assignee \"\"}"

# Load harness/beads.config relative to the main checkout (wrappers call this). Safe no-op if absent.
forge_beads_load() {
  local root="${1:-${ROOT:-.}}" cfg
  cfg="$root/harness/beads.config"
  # shellcheck disable=SC1090
  [ -f "$cfg" ] && . "$cfg"
}

# Run bd against the single DB in the MAIN checkout. Readers add 2>/dev/null at the call site
# (bd prints a beads.role notice to stderr; setup sets `git config beads.role maintainer`).
# FOLD #5/#7: ONE shared sanitized-env wrapper for this lib's git-resolving TOOLS (bd + the
# reconcile gh). env -i strips agent GIT_*/GH_* env-injection; the pinned system PATH defeats a shimmed
# binary; GIT_CONFIG masks; GITHUB_TOKEN passed explicitly (gh API auth survives the strip). Inlined
# (not sandbox-lib's forge_safe_env) — intake.sh sources beads-lib without sandbox-lib; the two-place
# env-policy coupling with forge_safe_env is documented and kept consistent.
forge_clean_env() { unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH GCONV_PATH LOCPATH NLSPATH GLIBC_TUNABLES; env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" "$@"; }
forge_bd() { forge_clean_env "$BD_BIN" -C "${ROOT:-.}" "$@"; }

# ---- PURE: the board contract projection (pinned) -----------------------------------------------
# forge_beads_project <list-json-file> <ready-json-file> -> the stable 7-key array on stdout.
# ready = membership in the AUTHORITATIVE `bd ready` set; blockers = blocking-type depends_on_id
# (unfiltered by target status, so a consumer can detect closed/dangling edges).
forge_beads_project() {
  local list="$1" ready="$2" blk
  blk="$(printf '%s\n' $BD_BLOCKING_TYPES | jq -R . | jq -cs .)"
  jq --slurpfile ready "$ready" --argjson blk "$blk" '
    ($ready[0] | map(.id)) as $rd
    | map({
        id, title, status,
        ready: ((.id) as $i | ($rd | index($i)) != null),
        priority,
        blockers: ([ (.dependencies // [])[] | select(.type as $t | $blk | index($t)) | .depends_on_id ] | sort),
        assignee: (.assignee // null)
      })
    | sort_by(.id)
  ' "$list"
}

# ---- PURE: fail-closed claim decision (pinned) --------------------------------------------------
# forge_beads_claimable <show-json-file> <ready-json-file> -> rc 0 iff ready AND unassigned.
# Fails closed (rc 1) on a missing bead, an already-assigned bead, or one not in the ready set.
forge_beads_claimable() {
  local show="$1" ready="$2" id assignee
  id="$(jq -r '.[0].id // empty' "$show" 2>/dev/null)"
  [ -n "$id" ] || return 1
  assignee="$(jq -r '.[0].assignee // empty' "$show" 2>/dev/null)"
  [ -z "$assignee" ] || return 1
  jq -e --arg id "$id" 'map(.id) | index($id) != null' "$ready" >/dev/null 2>&1 || return 1
  return 0
}

# ---- PURE: close-on-merge decision (pinned) -----------------------------------------------------
# forge_beads_reconcile_decision <status> <merged-bool> -> "close" iff in_review AND merged, else "skip".
forge_beads_reconcile_decision() {
  if [ "$1" = "$BD_REVIEW_STATUS" ] && [ "$2" = "true" ]; then printf 'close'; else printf 'skip'; fi
}

# ---- PURE: kill-switch unclaim args (pinned) ----------------------------------------------------
# forge_beads_release_args <id> -> the bd args that return the bead to open + clear the assignee.
# (kill-switch builds the actual call as an argv array so the empty assignee is passed correctly.)
forge_beads_release_args() {
  # shellcheck disable=SC2059
  printf "$BD_RELEASE_ARGS" "$1"
}

# ---- PURE: version-pin guard (pinned) — makes BD_VERSION_PIN load-bearing ------------------------
# forge_beads_check_version <actual> <pin> -> rc 0 iff non-empty AND equal. A bd upgrade can shift the
# JSON shape -> silent mismap; preflight FAILS on mismatch (override: BD_ALLOW_VERSION_DRIFT=1 -> warn).
forge_beads_check_version() { [ -n "$1" ] && [ "$1" = "$2" ]; }

# ---- PURE: custom-status declaration guard (pinned) — surfaces the setup sequencing -------------
# forge_beads_status_declared <name> (reads `bd statuses` text on stdin) -> rc 0 iff the status exists.
# in_review is a CUSTOM status that MUST be declared at the human-run setup step
# (bd config set status.custom in_review:wip); otherwise finish's `--status in_review` fails.
forge_beads_status_declared() { grep -qw -- "$1"; }

# ---- GLUE: runtime preflight (integration-tested) — fail-closed before mutating ops -------------
forge_beads_preflight() {
  local actual
  actual="$(forge_bd version 2>/dev/null | sed -n 's/^bd version \([0-9.][0-9.]*\).*/\1/p' | head -1)"
  if ! forge_beads_check_version "$actual" "$BD_VERSION_PIN"; then
    if [ "${BD_ALLOW_VERSION_DRIFT:-0}" = "1" ]; then
      printf 'beads-lib: WARNING — bd %s != pinned %s (BD_ALLOW_VERSION_DRIFT=1; proceeding).\n' "${actual:-?}" "$BD_VERSION_PIN" >&2
    else
      printf 'beads-lib: bd %s != pinned %s — the verified JSON contract may not hold; re-verify the contract + re-pin, or set BD_ALLOW_VERSION_DRIFT=1.\n' "${actual:-?}" "$BD_VERSION_PIN" >&2
      return 1
    fi
  fi
  # A2: cold-start self-heal — if the custom in_review status is not yet declared (a fresh
  # `bd init` whose one-time `bd config set status.custom` was skipped), materialize it ONCE then
  # RE-READ. Fail-closed is preserved: the verdict gates on the re-read, never the write — a
  # materialization failure still misses on the re-read and returns 1 (no fall-open).
  if ! forge_bd statuses 2>/dev/null | forge_beads_status_declared "$BD_REVIEW_STATUS"; then
    forge_bd config set status.custom "${BD_REVIEW_STATUS_DECL:-${BD_REVIEW_STATUS}:wip}" >/dev/null 2>&1 || true
    if ! forge_bd statuses 2>/dev/null | forge_beads_status_declared "$BD_REVIEW_STATUS"; then
      printf 'beads-lib: custom status "%s" not declared and could not be materialized — setup: bd config set status.custom "%s" (see harness/beads.config).\n' "$BD_REVIEW_STATUS" "${BD_REVIEW_STATUS_DECL:-${BD_REVIEW_STATUS}:wip}" >&2
      return 1
    fi
  fi
  return 0
}

# FOLD #13 WRITE side (extracted VERBATIM from cmd_finish, co-located with the READ below so the
# record write<->read shape stays coupled): cmd_finish's hold-until-merge step — mark the bead in_review +
# record the HARNESS-CAPTURED PR identity in the enforce-protected .harness/pr/<bead>.json (repo+branch+pr),
# so reconcile binds the close to THIS PR (state==MERGED + headRefName==branch), NEVER the agent-mutable
# external_ref. Fail-soft on the record-write; warn (not die) on the bd-update — byte-identical to the inline block.
forge_finish_record_pr() {  # <bead> <repo> <branch> <prurl> <harness-dir>
  local bead="$1" repo="$2" branch="$3" prurl="$4" harness="$5"
  [ -n "$bead" ] || return 0
  if forge_bd update "$bead" --status "${BD_REVIEW_STATUS:-in_review}" --external-ref "$prurl" >/dev/null 2>&1; then
    echo "  bead $bead → ${BD_REVIEW_STATUS:-in_review} (awaiting human merge; sync closes on merge)"
    mkdir -p "$harness/pr" 2>/dev/null && jq -nc --arg repo "$repo" --arg branch "$branch" --arg pr "${prurl##*/}" '{repo:$repo,branch:$branch,pr:$pr}' > "$harness/pr/$bead.json" 2>/dev/null || true
  else
    echo "  WARNING: could not set $bead → ${BD_REVIEW_STATUS:-in_review} — is status.custom declared? (see harness/beads.config)" >&2
  fi
}

# ---- PURE: reconcile close-decision predicates ---------------------------------------------------
# Extracted as pure string functions (no I/O) so the close decision is verifiable OFFLINE — no real PR yet
# encodes a task/<id>- head ref and gh cannot be fixtured for it (fold24 calls these directly; fold18 model).
#
# forge_target_branch_ns — the TRUSTED target-repo branch namespace prefix (default "forge/agent"), read
# ONLY from the enforce-protected harness/branches.config with the agent env STRIPPED first. A poisoned
# FORGE_TARGET_BRANCH_NS (env) must not bend the reconcile head-ref pattern below: if it did, a forged head
# ref could fall PAST the ARM-2 forgery-reject into the weaker ARM-3 record-match. Malformed prefix ->
# fail-safe to the default. Self builds do NOT use this (they keep task/<id>-<slug>).
forge_target_branch_ns() {
  local cfg ns
  cfg="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/branches.config"
  ns="$(unset FORGE_TARGET_BRANCH_NS; [ -f "$cfg" ] && . "$cfg" 2>/dev/null; printf '%s' "${FORGE_TARGET_BRANCH_NS:-forge/agent}")"
  case "$ns" in '' | *[!A-Za-z0-9/_-]* | /* | */*/*/* | */) ns="forge/agent" ;; esac
  printf '%s' "$ns"
}

# forge_reconcile_id_bound <bead> <headref> <record_branch> — the close dispatch keyed on the gh-VOUCHED
# head ref (NEVER a record field). Returns 0 (close) / 1 (skip). Two id-bound arms (self task/ + target
# <ns>/builder/), one forgery-reject arm, one feat/-override record-match arm.
#   ARM 1  headref == task/<bead>-*            -> CLOSE. SELF-build single-task, id-bound to THIS bead.
#   ARM 1b headref == <ns>/builder/<bead>-*    -> CLOSE. TARGET-build single-task, id-bound to THIS bead.
#          <ns> is the FIXED trusted prefix (no wildcard role) so a multi-segment head ref cannot smuggle
#          another bead's id in — the `-` after <bead> is the prefix-collision guard (fx-aaaa != fx-aaa).
#   ARM 2  headref == task/* OR <ns>/*         -> SKIP.  The security-critical skip: a branch-field forgery
#          points record.branch at a SIBLING's real merged PR, making headref==record_branch TRUE — so any
#          in-namespace head ref that is not THIS bead's must be rejected BEFORE the record-match can fire.
#          The id-match is a REQUIRED conjunct, never OR'd with headref==branch.
#   ARM 3  otherwise (feat/F, non-feat overrides like release-x) -> today's record-match headref==branch.
#          Still trusts the agent-writable record.branch (the documented B2 residual). The default MUST be
#          record-match, never branch-reconstruction, or every folded close would fail.
forge_reconcile_id_bound() {
  local bead="$1" headref="$2" rbranch="$3" ns nsrole
  ns="$(forge_target_branch_ns)"; nsrole="$ns/builder"
  case "$headref" in
    "task/$bead-"*) return 0 ;;
    "$nsrole/$bead-"*) return 0 ;;
    "task/"* | "$ns/"*) return 1 ;;
    *) [ "$headref" = "$rbranch" ] && return 0 || return 1 ;;
  esac
}

# forge_reconcile_record_ok <repo> <branch> — read-side shape HYGIENE (0 well-formed / 1 skip).
# INLINE by design (beads-lib does not source sandbox-lib): mirrors forge_repo_from_url's owner/repo shape
# WITHOUT calling it. A malformed/garbage record fails CLOSED (skip) before the gh query instead of reaching
# it, and the reconcile loop never crashes on a bad record. HONESTY: hygiene, NOT the B1 security fix — there
# is no allowlist, so an UNLISTED attacker repo still passes; do not present it as closing B1. Over-block
# guard: it accepts every well-formed owner/repo the harness writes today (same char class as the shape it mirrors).
forge_reconcile_record_ok() {
  local repo="$1" branch="$2"
  [ -n "$repo" ] && [ -n "$branch" ] || return 1
  case "$repo" in [A-Za-z0-9._-]*/[A-Za-z0-9._-]*) ;; *) return 1 ;; esac
  case "$repo" in */*/* | -* | */-*) return 1 ;; esac
  case "$branch" in *[[:space:]]*) return 1 ;; esac
  return 0
}

# ---- GLUE: close-on-merge reconcile (integration-tested) ----------------------------------------
# Close in_review beads whose recorded PR has merged — mechanical, event-derived; NEVER a manual close.
# mode: blocking (print) | quiet. Each gh call is time-boxed; everything fails soft.
# FOLD #7/#9/#11/#13: the close-on-merge oracle binds ONLY to the HARNESS-CAPTURED PR identity
# recorded at finish in the enforce-protected .harness/pr/<bead>.json (repo+branch+pr) — NOT the
# agent-mutable external_ref and NOT a live remote.origin.url read. So neither `bd update --external-ref
# <foreign|sibling>` (data axis) nor `git config remote.origin.url <attacker>` (trust-anchor axis) can
# fabricate a merge: close IFF this bead's captured PR is state==MERGED AND its headRefName == the captured
# branch. gh runs under forge_clean_env (env axis, #7/#9). No record / any mismatch => skip (fail-closed).
forge_reconcile_run() {
  local mode="${1:-quiet}" lf bead rec repo branch pr out state headref key
  local -A _pr_cache=()   # A1.1: memoize gh pr view by "repo#pr" so K beads on ONE feature PR query it once
  command -v gh >/dev/null 2>&1 || return 0
  lf="$(mktemp)" || return 0
  forge_bd list --json >"$lf" 2>/dev/null || {
    rm -f "$lf"
    return 0
  }
  while IFS= read -r bead; do
    [ -n "$bead" ] || continue
    rec="${ROOT:-.}/.harness/pr/$bead.json"
    [ -f "$rec" ] || continue
    repo="$(jq -r '.repo // empty' "$rec" 2>/dev/null)"
    branch="$(jq -r '.branch // empty' "$rec" 2>/dev/null)"
    pr="$(jq -r '.pr // empty' "$rec" 2>/dev/null)"
    case "$pr" in ''|*[!0-9]*) continue ;; esac
    forge_reconcile_record_ok "$repo" "$branch" || continue
    # A1.1: ONE gh pr view per distinct repo#pr per invocation (the assembly model points EVERY
    # in_review feature bead at the SAME feature PR -> K identical calls without this). Cache even an
    # empty/timeout result (the +set test distinguishes "queried-empty" from "not-yet-queried"). The
    # per-bead close + record-consume below stay per-bead; only the QUERY dedupes. Fail-closed is
    # untouched: empty out -> empty state/headref -> the MERGED guard is false -> skip.
    key="$repo#$pr"
    if [ -n "${_pr_cache[$key]+set}" ]; then
      out="${_pr_cache[$key]}"
    else
      out="$(forge_clean_env timeout 5 gh pr view "$pr" --repo "$repo" --json state,headRefName -q '[.state,.headRefName]|@tsv' 2>/dev/null)" || out=""
      _pr_cache[$key]="$out"
    fi
    state="$(printf '%s' "$out" | cut -f1)"; headref="$(printf '%s' "$out" | cut -f2)"
    if [ "$state" = "MERGED" ] && [ -n "$headref" ] && forge_reconcile_id_bound "$bead" "$headref" "$branch"; then
      if forge_bd close "$bead" --reason "merged: $repo#$pr" >/dev/null 2>&1; then
        # FOLD #16: the captured-PR record is SINGLE-USE — consume it on close (mirrors #15 on the
        # release edge), so it survives NO lifecycle transition. A reopened/re-claimed bead then starts with
        # no record and reconcile fail-closed-skips — the oracle is bound to the CURRENT claim, fires once.
        rm -f "$rec" 2>/dev/null || true
        [ "$mode" = "blocking" ] && echo "  closed $bead (merged via $repo#$pr)"
      fi
    fi
  done < <(jq -r --arg s "${BD_REVIEW_STATUS:-in_review}" '.[]? | select(.status==$s) | .id' "$lf" 2>/dev/null)
  rm -f "$lf"
  return 0
}

# Best-effort, NON-BLOCKING reconcile for the human read commands (status/ready) + nothing on the
# start/finish critical path (the claim never waits on it). board stays a PURE read (Agent B's fast
# snapshot source). Errors swallowed + logged; never changes the caller's exit status.
forge_reconcile_best_effort() {
  local log="${HARNESS:-${ROOT:-.}/.harness}/reconcile.log"
  mkdir -p "$(dirname "$log")" 2>/dev/null
  forge_reconcile_run quiet >>"$log" 2>&1 || true
  return 0
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# cp-assembly — Question-Zero overlay + the host-side assembly merge log
# ════════════════════════════════════════════════════════════════════════════════════════════════
# The deadlock: bd marks a finished task in_review (a WIP status, not closed), so
# `bd ready` drops it, so a sibling that blocks-depends on it can never be claimed → the feature
# deadlocks. The overlay below is an ADDITIVE second readiness path layered onto the existing claim
# (claimable := forge_beads_claimable OR forge_intra_feature_ready). forge_beads_claimable is NOT
# modified — the overlay only ADDS a relaxation for the narrow intra-feature case, never grants a
# claim to a missing or already-assigned bead. Deterministic (pure jq/git/string, NO LLM),
# fail-closed on every unresolved input, unspoofable (the satisfaction anchor is a harness-produced
# git fact in the floor-protected .harness/assembly/<feature>.json).

# forge_dep_satisfied <dep_id> <dependent_source_spec> <feat_branch> <repo> -> rc0 iff SATISFIED.
# predicate: closed -> SATISFIED (native rule, ALL deps); else must be a same-feature,
# in_review dep whose harness-recorded merge_commit is a git-ancestor of feat/F. Every unresolved
# input (missing bead/status, no grouping key, cross-feature, not-in_review, no merge record,
# ancestry-check error) -> UNSATISFIED. The merge_commit is read ONLY from the enforce-protected
# assembly log (an agent cannot forge it: writing .harness/** is denied, and even a bead-side
# source_spec rewrite cannot manufacture ancestry of a commit it never produced).
forge_dep_satisfied() {
  local dep_id="$1" dss="$2" feat="$3" repo="$4" sf status ds feature af mc
  [ -n "$dep_id" ] || return 1
  sf="$(mktemp)" || return 1
  forge_bd show "$dep_id" --json >"$sf" 2>/dev/null || { rm -f "$sf"; return 1; }
  status="$(jq -r '.[0].status // empty' "$sf" 2>/dev/null)"
  [ -n "$status" ] || { rm -f "$sf"; return 1; }                 # missing/unreadable -> fail closed
  if [ "$status" = "closed" ]; then rm -f "$sf"; return 0; fi     # native rule: closed satisfies ALL deps
  ds="$(jq -r '.[0].metadata.source_spec // empty' "$sf" 2>/dev/null)"
  rm -f "$sf"
  [ -n "$ds" ] && [ -n "$dss" ] || return 1                      # no grouping key on either side -> fail closed
  [ "$ds" = "$dss" ] || return 1                                  # CROSS-feature in_review must be closed
  [ "$status" = "${BD_REVIEW_STATUS:-in_review}" ] || return 1    # intra, but not yet finished
  feature="$(basename "$feat")"                                   # feat/<slug> -> <slug> (the assembly file key)
  af="${ROOT:-.}/.harness/assembly/$feature.json"
  [ -f "$af" ] || return 1                                        # no harness merge record -> fail closed
  mc="$(jq -r --arg b "$dep_id" 'first((.merges // [])[] | select(.bead==$b) | .merge_commit) // empty' "$af" 2>/dev/null)"
  [ -n "$mc" ] || return 1                                        # no recorded merge_commit -> fail closed
  # THE satisfaction anchor: the harness-recorded merge commit must be a git-ancestor of feat/F.
  git -C "$repo" merge-base --is-ancestor "$mc" "refs/heads/$feat" >/dev/null 2>&1 || return 1
  return 0
}

# forge_intra_feature_ready <id> <source_spec> <feat_branch> <repo> -> rc0 iff the bead is claimable
# via the intra-feature relaxation: it EXISTS, is OPEN, is UNASSIGNED (re-checked here so the overlay
# never grants what the native rule denies for those reasons), has a source_spec, AND every blocking
# dep is forge_dep_satisfied. On refusal it records the unsatisfied blocker id(s) in
# FORGE_UNSAT_BLOCKERS for cmd_start's fail-closed die message (T7).
forge_intra_feature_ready() {
  local id="$1" dss="$2" feat="$3" repo="$4" sf bid status assignee blk d unsat="" _ifr_deps=()
  FORGE_UNSAT_BLOCKERS=""
  [ -n "$id" ] || return 1
  [ -n "$dss" ] || return 1                                       # no grouping key -> overlay cannot apply
  sf="$(mktemp)" || return 1
  forge_bd show "$id" --json >"$sf" 2>/dev/null || { rm -f "$sf"; return 1; }
  bid="$(jq -r '.[0].id // empty' "$sf" 2>/dev/null)"
  [ "$bid" = "$id" ] || { rm -f "$sf"; return 1; }               # missing bead -> fail closed (never mint)
  status="$(jq -r '.[0].status // empty' "$sf" 2>/dev/null)"
  [ "$status" = "open" ] || { rm -f "$sf"; return 1; }           # only an OPEN bead is claimable
  assignee="$(jq -r '.[0].assignee // empty' "$sf" 2>/dev/null)"
  [ -z "$assignee" ] || { rm -f "$sf"; return 1; }              # already assigned -> never re-claim
  # NB: `bd show --json` shapes each dependency as {id, status, ..., dependency_type} — DISTINCT from
  # `bd list --json`'s {depends_on_id, type} that forge_beads_project reads. Use the show-shape fields here.
  blk="$(printf '%s\n' $BD_BLOCKING_TYPES | jq -R . | jq -cs .)"
  mapfile -t _ifr_deps < <(jq -r --argjson blk "$blk" '[ (.[0].dependencies // [])[] | select(.dependency_type as $t | $blk | index($t)) | .id ] | .[]' "$sf" 2>/dev/null)
  rm -f "$sf"
  for d in "${_ifr_deps[@]}"; do
    [ -n "$d" ] || continue
    forge_dep_satisfied "$d" "$dss" "$feat" "$repo" || unsat="${unsat:+$unsat }$d"
  done
  if [ -n "$unsat" ]; then FORGE_UNSAT_BLOCKERS="$unsat"; return 1; fi
  return 0
}

# ── host-side assembly merge log (.harness/assembly/<feature>.json) ──────────────────────────────
# Runner-side writers — co-located with forge_finish_record_pr (the existing .harness/pr writer).
# Legitimate exactly as that one is: the deny floor gates the AGENT's tool calls, not the harness's
# own runtime writes. The file is the unforgeable surfacing artifact (enforce-class).

# forge_assembly_init <feat_branch> <source_spec> -> ensure the assembly file exists (idempotent).
forge_assembly_init() {
  local feat="$1" ss="$2" feature dir af
  feature="$(basename "$feat")"; dir="${ROOT:-.}/.harness/assembly"; af="$dir/$feature.json"
  mkdir -p "$dir" 2>/dev/null || return 1
  [ -f "$af" ] && return 0
  jq -nc --arg feature "$feature" --arg ss "$ss" --arg fb "$feat" \
    '{feature:$feature,source_spec:$ss,feat_branch:$fb,feature_pr:"",merges:[],state:"assembling",last_error:null}' >"$af" 2>/dev/null
}

# forge_assembly_append <feat_branch> <bead> <task_branch> <task_sha> <feat_before_sha> <merge_commit>
forge_assembly_append() {
  local feat="$1" feature af tmp now
  feature="$(basename "$feat")"; af="${ROOT:-.}/.harness/assembly/$feature.json"
  [ -f "$af" ] || return 1
  now="$(date -u +%FT%TZ)"; tmp="$(mktemp)" || return 1
  jq --arg bead "$2" --arg tb "$3" --arg tsha "$4" --arg before "$5" --arg mc "$6" --arg now "$now" \
    '.merges += [{bead:$bead,task_branch:$tb,task_sha:$tsha,feat_before_sha:$before,merge_commit:$mc,ts:$now,actor:"harness"}]' \
    "$af" >"$tmp" 2>/dev/null && mv "$tmp" "$af" || { rm -f "$tmp"; return 1; }
}

# forge_assembly_set <feat_branch> <key> <value> -> set a top-level scalar (state|last_error|feature_pr).
forge_assembly_set() {
  local feat="$1" key="$2" val="$3" feature af tmp
  feature="$(basename "$feat")"; af="${ROOT:-.}/.harness/assembly/$feature.json"
  [ -f "$af" ] || return 1
  tmp="$(mktemp)" || return 1
  jq --arg v "$val" --arg k "$key" 'setpath([$k]; $v)' "$af" >"$tmp" 2>/dev/null && mv "$tmp" "$af" || { rm -f "$tmp"; return 1; }
}

# forge_assembly_merge_count <feat_branch> -> prints the number of recorded merges (0 if no file).
forge_assembly_merge_count() {
  local feat="$1" feature af
  feature="$(basename "$feat")"; af="${ROOT:-.}/.harness/assembly/$feature.json"
  [ -f "$af" ] || { printf '0'; return 0; }
  jq -r '(.merges // []) | length' "$af" 2>/dev/null || printf '0'
}

# forge_ensure_feature_pr <repo> <feat_branch> <base> <title> <body> -> print THE feature PR url. Discovers
# an existing OPEN PR for feat/F first (so refinishes never open a second); creates ONE only if none. gh runs
# under forge_clean_env (env -i + GITHUB_TOKEN + config masks) with --repo explicit — the SAME sanitized gh
# discipline as forge_reconcile_run (no GIT_DIR needed: --repo/--head/--base are explicit, gh uses the API).
# rc!=0 on a hard gh failure (the caller fails closed). Human-merge-only: never auto-merges feat/F.
forge_ensure_feature_pr() {
  local repo="$1" feat="$2" base="$3" title="$4" body="$5" url combined rc tries=0
  command -v gh >/dev/null 2>&1 || return 1
  [ -n "$repo" ] && [ -n "$feat" ] && [ -n "$base" ] || return 1
  # A1.2: discover the existing OPEN feature PR with bounded retry. An empty/timed-out list is
  # AMBIGUOUS (no-PR vs transient) -> retry; NEVER assume "create" on a transient (the old code fell
  # straight to create and then died-after-push in run-task.sh when the PR already existed).
  while [ "$tries" -lt 3 ]; do
    url="$(forge_clean_env timeout 15 gh pr list --repo "$repo" --head "$feat" --state open --json url -q 'first(.[].url) // empty' 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$url" ]; then printf '%s' "$url"; return 0; fi
    [ "$rc" -eq 0 ] && break    # clean rc, empty url -> genuinely no open PR yet -> proceed to create
    tries=$((tries + 1)); sleep "${FORGE_PR_RETRY_SLEEP:-2}"
  done
  # Create, capturing COMBINED output: a non-zero exit whose cause is "already exists" is a RE-DISCOVER
  # signal (the PR raced in / a prior push created it), NOT a die. gh prints the existing PR url on the
  # already-exists line, so re-query first and fall back to parsing the url out of the captured output.
  combined="$(forge_clean_env timeout 30 gh pr create --repo "$repo" --base "$base" --head "$feat" --title "$title" --body "$body" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    url="$(printf '%s\n' "$combined" | grep -oE 'https://[^ ]+/pull/[0-9]+' | head -1)"
    if [ -n "$url" ]; then printf '%s' "$url"; return 0; fi
    return 1
  fi
  case "$combined" in
    *"already exists"*)
      url="$(forge_clean_env timeout 15 gh pr list --repo "$repo" --head "$feat" --state open --json url -q 'first(.[].url) // empty' 2>/dev/null)"
      [ -n "$url" ] && { printf '%s' "$url"; return 0; }
      url="$(printf '%s\n' "$combined" | grep -oE 'https://[^ ]+/pull/[0-9]+' | head -1)"
      [ -n "$url" ] && { printf '%s' "$url"; return 0; }
      return 1 ;;
    *) return 1 ;;
  esac
}

# forge_feature_complete <source_spec> -> rc0 iff NO bead with this source_spec is open/in_progress (every
# feature bead is in_review/closed). Cutover: Fail-closed (rc1=not-complete) on any bd read error.
forge_feature_complete() {
  local ss="$1" lf n
  [ -n "$ss" ] || return 1
  lf="$(mktemp)" || return 1
  forge_bd list --json >"$lf" 2>/dev/null || { rm -f "$lf"; return 1; }
  n="$(jq -r --arg ss "$ss" '[ .[] | select((.metadata.source_spec // "")==$ss) | select(.status=="open" or .status=="in_progress") ] | length' "$lf" 2>/dev/null)"
  rm -f "$lf"
  [ "$n" = "0" ]
}

# forge_review_feature_if_complete <source_spec> <pr_url> <repo> <review_script>
# Fire the advisory reviewer ONCE per feature — only when forge_feature_complete is true
# (every feature bead in_review/closed). This IS the once-gate: cmd_finish calls it at EVERY feature-task
# finish and it no-ops until the LAST task completes the feature, so the reviewer sees the ASSEMBLED feat/F,
# never a single task's range (the per-task range fires are gone). AGGREGATE mode: it sets NO
# FORGE_REVIEW_DIFF_MODE, so review-task.sh falls to `gh pr diff "$pr"` (the full feature diff) and points
# its read-context worktree at the feature tip (gh pr view headRefOid). The ratified spec + ledger are fed
# via FORGE_REVIEW_SOURCE_SPEC (review-task.sh resolves + injects them). NON-gating, fire-and-forget: every
# failure is swallowed; the verdict stays advisory and never blocks finish, never --request-changes.
forge_review_feature_if_complete() {
  local ss="$1" pr="$2" repo="$3" script="$4"
  [ -n "$ss" ] || return 0
  forge_feature_complete "$ss" || return 0       # not complete yet -> the once-gate holds; no fire
  [ -n "$pr" ] && [ -n "$script" ] && [ -x "$script" ] || return 0
  FORGE_REVIEW_SOURCE_SPEC="$ss" /usr/bin/bash "$script" "$pr" ${repo:+--repo "$repo"} >/dev/null 2>&1 || true
  return 0
}
