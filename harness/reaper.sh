#!/usr/bin/env bash
# agentic-builder-forge cp-reaper — the stale-container reaper (concurrency-hardened).
# Deployed at harness/reaper.sh (enforce-protected; changes are authored as sandbox/ candidates and human-spliced under FORGE_ALLOW_HOOK_EDIT=1).
#
# An abandoned-after-successful-start session leaves its devcontainer — and its RW .git mount —
# running forever with no one to notice. This script sweeps those containers.
#
# ── SCOPE FENCE (read before pointing this at anything) ─────────────────────────────────────────
# The reaper reaps CONTAINERS ONLY. It NEVER touches the host worktree, its node_modules, task
# branches, or the .beads/ ledger — that hygiene belongs elsewhere (worktree/install hygiene
# is its own concern; branch/ledger lifecycle is run-task.sh's). This is NOT a worktree cleaner.
# ────────────────────────────────────────────────────────────────────────────────────────────────
#
# Usage:
#   reaper.sh                      dry-run (DEFAULT): print the verdict table, remove NOTHING
#   reaper.sh --reap               remove stale containers (docker rm -f); append each removal
#                                  {container, worktree, reason, ts} to .harness/reaper.log
#   reaper.sh [--reap] --max-age=<dur>   add the age criterion; <dur> = N | Ns | Nm | Nh | Nd
#
# Enumeration: docker containers carrying the SAME label key forge_sandbox_down is scoped by
# (devcontainer.local_folder — the devcontainer CLI stamps it with the workspace folder).
#
# A container is STALE iff ANY of:
#   (a) its labeled worktree path no longer exists                    reason: worktree-missing
#   (b) the live sentinel (.harness/active-task.json) does not name
#       its worktree                                                  reason: no-live-sentinel
#   (c) --max-age given and the container is older (.Created)         reason: older-than-max-age
# Default WITHOUT --max-age: (a) || (b).
#
# ABSOLUTE GUARD: a container whose worktree IS named by the live sentinel is NEVER stale — by
# ANY criterion, including (c). A running session always survives, even --reap --max-age=1s.
# Only the FOREIGN confinement check (below) is evaluated before the guard.
#
# FOREIGN confinement (host safety): only containers whose labeled path lies under the forge
# worktree base ($ROOT/.claude/worktrees — run-task.sh's WTBASE) are candidates. Anything else
# (e.g. a VS Code devcontainer for an unrelated project carries the same label key) is reported
# FOREIGN and never reaped. FORGE_REAPER_SCOPE overrides the base; FORGE_REAPER_LABEL overrides
# the label key — both are test seams (the suite runs on throwaway labels/paths), same style as
# FORGE_SANDBOX_MANIFEST / FORGE_HARNESS_DIR.
#
# Posture: fail-closed. docker absent -> exit 75 (EX_TEMPFAIL — the suite's SKIP convention;
# tests/run-all.sh interprets 75 as SKIP).
# CORRUPT-SENTINEL refusal: a sentinel that EXISTS but is unparseable JSON or lacks .worktree
# means a live task MAY be running and the reaper cannot tell which container is its — so it
# REFUSES to reap ANYTHING (loud named error to stderr, exit 1), in dry-run and --reap alike.
# An ABSENT sentinel is not corruption: no live task, criterion (b) applies normally.
# When `docker rm -f` fails the reaper disambiguates on the inspect ERROR TEXT (not the exit code —
# docker returns 1 for BOTH "No such object" and daemon/socket errors): a CONFIRMED not-found is a
# BENIGN concurrent race (a parallel --reap pass or the F7c start-teardown trap won) -> no warn, no
# false rc=1, no duplicate log line (concurrency-safe/idempotent). Any OTHER outcome — rm
# fails and inspect either confirms the container still exists OR cannot be reached (daemon blip) —
# is surfaced as WARN + non-zero exit (fail closed; never swallow a live RW .git mount, the F7b lesson).
#
# Exit codes: 0 ok · 1 reap/setup failure or CORRUPT-SENTINEL refusal · 2 usage · 75 docker absent (SKIP).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dual-seat lib resolution: installed (harness/reaper.sh -> ../.claude/hooks/lib.sh) or candidate
# (sandbox/<candidate>/cp-reaper/ -> ../../../.claude/hooks/lib.sh). No env var needed in either seat.
LIB=""
for _c in "$HERE/../.claude/hooks/lib.sh" "$HERE/../../../.claude/hooks/lib.sh"; do
  [ -f "$_c" ] && { LIB="$_c"; break; }
done
[ -n "$LIB" ] || { echo "reaper: cannot locate .claude/hooks/lib.sh from $HERE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

usage() {
  echo "usage: reaper.sh [--reap] [--max-age=<N|Ns|Nm|Nh|Nd>]" >&2
  exit 2
}

# parse <dur> -> seconds; empty output + rc 1 on malformed.
parse_dur() {
  local d="$1" n unit
  case "$d" in '' | *[!0-9smhd]*) return 1 ;; esac
  unit="${d##*[0-9]}"
  n="${d%"$unit"}"
  case "$n" in '' | *[!0-9]*) return 1 ;; esac
  case "$unit" in
    '' | s) printf '%s' "$n" ;;
    m) printf '%s' "$((n * 60))" ;;
    h) printf '%s' "$((n * 3600))" ;;
    d) printf '%s' "$((n * 86400))" ;;
    *) return 1 ;;
  esac
}

REAP=0
MAX_AGE="" # seconds; empty = criterion (c) off
for arg in "$@"; do
  case "$arg" in
    --reap) REAP=1 ;;
    --max-age=*)
      MAX_AGE="$(parse_dur "${arg#--max-age=}")" || { echo "reaper: bad --max-age '${arg#--max-age=}'" >&2; usage; }
      ;;
    *) usage ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "reaper: SKIP — docker absent (nothing to reap; rc 75)" >&2; exit 75; }
command -v jq >/dev/null 2>&1 || { echo "reaper: jq is required" >&2; exit 1; }

LABEL_KEY="${FORGE_REAPER_LABEL:-devcontainer.local_folder}"

# Confinement base for forge-owned worktrees (string-prefix check — works even when the path is gone).
if [ -n "${FORGE_REAPER_SCOPE:-}" ]; then
  SCOPE="$FORGE_REAPER_SCOPE"
else
  _root="$(forge_main_root 2>/dev/null)" || { echo "reaper: cannot resolve forge_main_root (run from the forge checkout or set FORGE_REAPER_SCOPE)" >&2; exit 1; }
  SCOPE="$_root/.claude/worktrees"
fi

HARNESS="$(forge_harness_dir)" || { echo "reaper: cannot resolve the harness dir" >&2; exit 1; }
SENTINEL="$HARNESS/active-task.json"

# Live sentinel -> the one worktree that is NEVER stale (the ABSOLUTE guard). A sentinel that
# EXISTS but cannot be trusted (unparseable JSON, or no .worktree) is a CORRUPT-SENTINEL: a live
# task may be running and we cannot identify its container, so refuse to reap ANYTHING — dry-run
# and --reap alike. Only an ABSENT sentinel means "no live task" (criterion (b) applies normally).
LIVE_WT=""
if [ -f "$SENTINEL" ]; then
  if ! jq -e . "$SENTINEL" >/dev/null 2>&1; then
    echo "reaper: CORRUPT-SENTINEL — $SENTINEL exists but is not parseable JSON; a live task may be running and its container cannot be identified. REFUSING to reap anything. Fix or remove the sentinel, then re-run." >&2
    exit 1
  fi
  LIVE_WT="$(jq -r '.worktree // empty' "$SENTINEL" 2>/dev/null)"
  if [ -z "$LIVE_WT" ]; then
    echo "reaper: CORRUPT-SENTINEL — $SENTINEL parses but lacks .worktree; a live task may be running and its container cannot be identified. REFUSING to reap anything. Fix or remove the sentinel, then re-run." >&2
    exit 1
  fi
fi

NOW="$(date -u +%s)"
RC=0

# Enumerate by label-key EXISTENCE (label=<key> matches any value; label=<key>=<value> is the
# per-worktree form forge_sandbox_down uses).
CIDS="$(docker ps -aq --filter "label=$LABEL_KEY" 2>/dev/null)"

printf '%-14s %-52s %-44s %s\n' "CONTAINER" "WORKTREE" "REASON" "VERDICT"
[ -n "$CIDS" ] || { echo "(no containers carry label key '$LABEL_KEY')"; exit 0; }

for cid in $CIDS; do
  wt="$(docker inspect -f "{{ index .Config.Labels \"$LABEL_KEY\" }}" "$cid" 2>/dev/null)" || continue
  created="$(docker inspect -f '{{.Created}}' "$cid" 2>/dev/null)" || created=""

  # FOREIGN: not under the forge worktree base -> never a reap candidate.
  case "$wt" in
    "$SCOPE"/*) : ;;
    *)
      printf '%-14s %-52s %-44s %s\n' "$cid" "$wt" "outside-scope($SCOPE)" "FOREIGN"
      continue
      ;;
  esac

  # ABSOLUTE GUARD: the sentinel-named worktree is NEVER stale, by ANY criterion — (a), (b),
  # or (c). A live session always survives; only FOREIGN confinement is checked before this.
  if [ -n "$LIVE_WT" ] && [ "$wt" = "$LIVE_WT" ]; then
    printf '%-14s %-52s %-44s %s\n' "$cid" "$wt" "-" "LIVE"
    continue
  fi

  reasons=""
  [ -e "$wt" ] || reasons="worktree-missing"
  if [ -z "$LIVE_WT" ] || [ "$wt" != "$LIVE_WT" ]; then
    reasons="${reasons:+$reasons+}no-live-sentinel"
  fi
  if [ -n "$MAX_AGE" ] && [ -n "$created" ]; then
    cep="$(date -u -d "$created" +%s 2>/dev/null || true)"
    if [ -n "$cep" ] && [ "$((NOW - cep))" -gt "$MAX_AGE" ]; then
      reasons="${reasons:+$reasons+}older-than-max-age"
    fi
  fi

  if [ -z "$reasons" ]; then
    printf '%-14s %-52s %-44s %s\n' "$cid" "$wt" "-" "LIVE"
    continue
  fi
  printf '%-14s %-52s %-44s %s\n' "$cid" "$wt" "$reasons" "STALE"

  if [ "$REAP" = 1 ]; then
    if docker rm -f "$cid" >/dev/null 2>&1; then
      mkdir -p "$HARNESS" 2>/dev/null # fresh-clone lesson: .harness/ may not exist yet
      ts="$(date -u +%FT%TZ)"
      jq -nc --arg c "$cid" --arg w "$wt" --arg r "$reasons" --arg ts "$ts" \
        '{container:$c, worktree:$w, reason:$r, ts:$ts}' >>"$HARNESS/reaper.log"
      echo "reaped $cid ($wt: $reasons)"
    elif ! _ierr="$(docker inspect "$cid" 2>&1 >/dev/null)"; then
      # Docker-inspect disambiguation (review finding F1). `docker rm -f` failed AND `docker
      # inspect` errored. docker returns exit 1 for BOTH "No such object" (genuinely gone) AND
      # daemon/socket/permission errors, so key on the error TEXT — never the exit code alone.
      case "$_ierr" in
        *"No such"* | *"no such"*)
          # CONFIRMED gone: a concurrent --reap pass (or the F7c start-teardown trap) won the race.
          # BENIGN + idempotent: keep RC=0, emit NO warning, write NO log line (the pass that actually
          # removed it logged it once) — this is what turns a double-reap into a no-op, not a false rc=1.
          echo "already reaped $cid ($wt: $reasons) — concurrent pass won the race" >&2
          ;;
        *)
          # rm failed and inspect could NOT confirm removal (daemon/socket blip): a live container +
          # its RW .git mount may still be up — fail closed, never swallow (the forge_sandbox_down F7b
          # lesson). Self-heals on the next sweep once docker recovers.
          echo "reaper: WARNING — could not remove container $cid ($wt) and could not confirm its removal: ${_ierr:-docker inspect failed}" >&2
          RC=1
          ;;
      esac
    else
      # rm failed AND `docker inspect` SUCCEEDED: the container is still present and genuinely refuses
      # to die, keeping a RW .git mount alive — surface, never swallow (forge_sandbox_down F7b).
      echo "reaper: WARNING — could not remove container $cid ($wt)" >&2
      RC=1
    fi
  fi
done

exit "$RC"
