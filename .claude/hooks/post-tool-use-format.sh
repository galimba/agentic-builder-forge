#!/usr/bin/env bash
# agentic-builder-forge — PostToolUse format + lint.
#
# On every Write/Edit/MultiEdit to a sandbox file, runs the configured FORMAT (auto-fix) then
# LINT — both from targets.config, never hardcoded. The agent cannot skip it: the hook fires
# deterministically after the edit. PostToolUse can't undo the write, so it normalizes the file
# and, if lint fails, blocks with the lint output fed back so the agent must fix it.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
forge_read_input

FP="$(forge_json '.tool_input.file_path')"
[ -n "$FP" ] || exit 0
# Only the configured sandbox target.
case "$FP" in
  sandbox/* | */sandbox/*) ;;
  *) exit 0 ;;
esac

forge_load_target || exit 0
proj="$(forge_json '.cwd')"
[ -n "$proj" ] || proj="${CLAUDE_PROJECT_DIR:-.}"
case "$FP" in
  /*) abs="$FP" ;;
  *) abs="$proj/$FP" ;;
esac
[ -f "$abs" ] || exit 0

# Format (auto-fix the edited file) — always runs.
[ -n "${FORMAT_CMD:-}" ] && (cd "$proj" 2>/dev/null && eval "$FORMAT_CMD \"$abs\"") >/dev/null 2>&1

# Lint — report; block with feedback on failure.
if [ -n "${LINT_CMD:-}" ]; then
  lout="$(cd "$proj" 2>/dev/null && eval "$LINT_CMD" 2>&1)"
  lrc=$?
  [ "$lrc" = "0" ] || forge_block "lint failed after editing $FP — fix before continuing:
$lout"
fi
exit 0
