#!/usr/bin/env bash
# agentic-builder-forge — Stop completion-gate (with fail-closed flips under unattended mode).
#
# Deployed enforcement-protected hook: agent edits are floor-denied; changes are human-spliced as
# full-file replacements under FORGE_ALLOW_HOOK_EDIT=1 (preserve the +x bit — settings.json invokes it by bare path).
#
# When a task is active, the run cannot be declared "done" while the configured tests are RED:
# the hook runs TEST_CMD (from targets.config, resolved from the MAIN ROOT only — PROBE-D) and
# BLOCKS the Stop, feeding the failure back so the agent keeps going until green. When no task is
# active it is a no-op in EVERY mode (the supervised build is not gated). Honors `stop_hook_active`
# AND an independent loop cap (FORGE_STOP_BLOCK_CAP, default 8) as a runaway backstop.
#
# TWO MODES, STATED ("flip to fail-closed under unattended"):
#   FORGE_UNATTENDED=1 (unattended/CI)
#     R-16: config-resolution failure or an empty TEST_CMD while a task is active BLOCKS with a
#       named reason — "done" is never allowed on a config failure (fail closed: an unverifiable
#       gate must not pass).
#     cap:  the loop cap NEVER releases — persistent red keeps blocking, with the attempt count in
#       the message. A wedged session is killed externally (the wall-clock reaper);
#       shipping red is strictly worse than wedging.
#   unset (attended — today's behavior, unchanged)
#     The R-16 paths stay no-op allows (a human is supervising the build and reads the terminal),
#     and the cap releases after N red attempts with a human-intervention message.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
forge_read_input

# Backstop 1: never re-block an already-active stop loop.
[ "$(forge_json '.stop_hook_active')" = "true" ] && exit 0
# Only gate while a task is active (no-op in every mode when no task is armed).
forge_task_active || exit 0

unattended=0
[ "${FORGE_UNATTENDED:-0}" = "1" ] && unattended=1

# R-16: a task is active — an unverifiable gate FAILS CLOSED under unattended.
if ! forge_load_target; then
  [ "$unattended" = "1" ] && forge_block "R-16 fail-closed: a task is active but harness/targets.config could not be resolved from the main root — tests cannot be verified, so 'done' is refused (FORGE_UNATTENDED=1). Fix the config; never weaken the gate."
  exit 0 # attended legacy: a human is supervising
fi
if [ -z "${TEST_CMD:-}" ]; then
  [ "$unattended" = "1" ] && forge_block "R-16 fail-closed: TEST_CMD is empty for TARGET=${TARGET:-?} while a task is active — tests cannot be verified, so 'done' is refused (FORGE_UNATTENDED=1). Define ${TARGET:-?}_TEST_CMD in harness/targets.config."
  exit 0 # attended legacy: a human is supervising
fi

cwd="$(forge_json '.cwd')"
[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-.}"
out="$(cd "$cwd" 2>/dev/null && eval "$TEST_CMD" 2>&1)"
rc=$?

hd="$(forge_harness_dir 2>/dev/null)"
cntf="$hd/stop-blocks"
if [ "$rc" = "0" ]; then
  [ -n "$hd" ] && rm -f "$cntf" 2>/dev/null # green: reset counter, allow stop
  exit 0
fi

# Red: block. The loop cap is MODE-SPLIT: unattended NEVER releases on red.
cnt=0
[ -f "$cntf" ] && cnt="$(cat "$cntf" 2>/dev/null || printf 0)"
cnt=$((cnt + 1))
[ -n "$hd" ] && { mkdir -p "$hd" 2>/dev/null; printf '%s' "$cnt" >"$cntf" 2>/dev/null; }
cap="${FORGE_STOP_BLOCK_CAP:-8}"
if [ "$cnt" -ge "$cap" ]; then
  if [ "$unattended" = "1" ]; then
    # UNATTENDED: never allow done-on-red. Keep blocking (counter keeps counting); the wall-clock
    # reaper — not this gate — is what ends a wedged session.
    forge_block "tests still RED after $cnt attempts (cap $cap) — UNATTENDED: the Stop gate never releases on red (done-on-red ships broken work; a wedged session is reaped externally). Make \`$TEST_CMD\` pass. Output:
$out"
  fi
  printf 'agentic-builder-forge: tests still RED after %s attempts — releasing Stop gate; human intervention needed.\n' "$cnt" >&2
  [ -n "$hd" ] && rm -f "$cntf" 2>/dev/null
  exit 0
fi
forge_block "tests are RED — not done. Make \`$TEST_CMD\` pass (attempt $cnt/$cap). Output:
$out"
