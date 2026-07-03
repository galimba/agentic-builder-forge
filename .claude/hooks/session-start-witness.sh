#!/usr/bin/env bash
# agentic-builder-forge — SessionStart deny-floor witness.
# Deployed enforcement-protected hook; changes are human-spliced as full-file replacements under FORGE_ALLOW_HOOK_EDIT=1.
#
# Hash-pins the deny floor that loaded with THIS session into a per-session sentinel:
#   .harness/session-floor.<session_id>.json  {session_id, source, cwd, actor, ts, floor_hash}
# floor_hash = forge_floor_hash: pre-tool-use-deny.sh + lib.sh + the jq-normalized PreToolUse
# stanza of settings.json (ONE recipe, shared with the verifier — see forge_floor_hash in lib.sh).
# The privileged host ops (intake convert, run-task finish) check it via forge_witness_gate.
#
# NEVER A GATE: SessionStart must not block — exit 0 on EVERY path. ABSENCE of the witness is what
# gates, at the privileged op (PROBE-A.3: off-root launch -> this hook never runs -> no witness ->
# the op refuses). Refusals go to stderr only; stdout stays EMPTY (SessionStart stdout is injected
# into the session context).
#
# R1(ii) COVERAGE (fail closed): if settings.local.json defines hooks.PreToolUse, a higher-
# precedence settings source may have replaced/reordered the canonical floor — the witness is NOT
# written (so privileged ops refuse on absence) and a loud refusal names it. A benign witness must
# never ride alongside a non-canonical PreToolUse definition. Residual (named, not closed):
# user-level (~/.claude/settings.json) and managed-policy settings sources are outside this
# check's scope.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

# Loud named non-write to stderr; ALWAYS exit 0 (SessionStart is not a gate).
refuse() {
  printf 'agentic-builder-forge witness: NOT WRITTEN [%s] — %s\n' "$1" "$2" >&2
  exit 0
}

command -v jq >/dev/null 2>&1 || refuse witness-not-written-no-jq "jq not found on PATH — cannot parse SessionStart input or build the witness; privileged ops will refuse on absence (fail closed)"

forge_read_input
SID="$(forge_json '.session_id')"
SRC="$(forge_json '.source')"
CWD="$(forge_json '.cwd')"

[ -n "$SID" ] || refuse witness-not-written-no-session-id "SessionStart input carried no session_id"
forge_witness_sid_ok "$SID" || refuse witness-not-written-bad-session-id "session_id fails ^[A-Za-z0-9-]+\$ — it lands in a filename and an env file (injection surface; sid: $SID)"

# The floor that actually loaded for THIS session is the project-root one.
ROOT="${CLAUDE_PROJECT_DIR:-$CWD}"
[ -n "$ROOT" ] || refuse witness-not-written-no-root "neither CLAUDE_PROJECT_DIR nor the stdin cwd is available"

# R1(ii): a higher-precedence local settings source defining PreToolUse means the canonical floor
# may not be what loaded — write NO witness (privileged ops then refuse on absence).
LOCAL="$ROOT/.claude/settings.local.json"
if [ -f "$LOCAL" ] && jq -e '.hooks.PreToolUse != null' "$LOCAL" >/dev/null 2>&1; then
  refuse witness-not-written-r1ii-local-pretooluse "$LOCAL defines hooks.PreToolUse — a non-canonical, higher-precedence settings source may control the floor; refusing to witness a floor that may not be what loaded (R1(ii), fail closed)"
fi

# Install-guarantee: the git pre-commit guard (the ALL-ACTORS commit-to-main tier) is only REAL when git's
# resolved hooks dir is <root>/harness/githooks. Unset / wrong (fresh clone, new worktree) => the git-hook
# is SILENTLY INERT and a non-agent main commit would succeed — the failure this check closes, one
# level down. Write NO witness; the privileged ops then refuse on ABSENCE (the same absence-gates model as
# R1(ii)). This is what makes the git-hook tier's install mechanically guaranteed, not honor-based.
forge_hookspath_ok "$ROOT" || refuse witness-not-written-hookspath-uninstalled "the commit-to-main git pre-commit guard at $ROOT is NOT installed — core.hooksPath must resolve to harness/githooks AND an executable pre-commit must be present there (run: git config core.hooksPath harness/githooks; ensure harness/githooks/pre-commit exists and is chmod +x); refusing to witness so the privileged ops fail-closed on absence"

FLOOR_HASH="$(forge_floor_hash "$ROOT")"
[ -n "$FLOOR_HASH" ] || refuse witness-not-written-floor-unhashable "cannot hash the deny floor at $ROOT (deny hook / lib.sh / PreToolUse stanza missing or unreadable)"

HD="$(forge_harness_dir 2>/dev/null)"
[ -n "$HD" ] || refuse witness-not-written-no-harness-dir "cannot resolve the harness dir (not inside a git repo and FORGE_HARNESS_DIR unset)"
# The fresh-clone lesson: .harness/ holds no tracked files, so it may not exist yet.
mkdir -p "$HD" 2>/dev/null || refuse witness-not-written-mkdir-failed "cannot create $HD"

WF="$HD/session-floor.$SID.json"
if ! jq -nc --arg sid "$SID" --arg src "$SRC" --arg cwd "$CWD" \
  --arg actor "${USER:-$(id -un 2>/dev/null || printf unknown)}" \
  --arg ts "$(date -u +%FT%TZ 2>/dev/null || printf unknown)" \
  --arg fh "$FLOOR_HASH" \
  '{session_id: $sid, source: $src, cwd: $cwd, actor: $actor, ts: $ts, floor_hash: $fh}' \
  >"$WF" 2>/dev/null; then
  rm -f "$WF" 2>/dev/null
  refuse witness-not-written-write-failed "could not write $WF"
fi

# PROBE-A.4: export the session id so later in-session commands (the privileged ops) can
# self-identify. SID is charset-validated above, so embedding it single-quoted is safe.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  printf "export CLAUDE_SESSION_ID='%s'\n" "$SID" >>"$CLAUDE_ENV_FILE" 2>/dev/null ||
    printf 'agentic-builder-forge witness: WARNING — witness written but the CLAUDE_ENV_FILE append failed (%s); in-session self-verify may refuse with witness-refused-no-session-id\n' "$CLAUDE_ENV_FILE" >&2
fi

exit 0
