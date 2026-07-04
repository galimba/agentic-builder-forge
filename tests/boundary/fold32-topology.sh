#!/usr/bin/env bash
# fold32 — container/network topology canary (Phase 2; static + optional live). RED-first.
#
# Phase 2 flips the container to NETWORKED by default and container-DEFAULT for target builds, while
# leaving the RO-mount / hardened-container isolation (Layers A+B) intact. These files are enforce-
# protected but are NOT floor-hash inputs, so this is a NON-floor-moving change (no witness re-mint).
#
#   RED pre-splice (main hardcodes `--network none`, has no FORGE_TARGET_CONTAINER); GREEN post-splice.
#   FORGE_LIVE_ROOT overrides the root (prove GREEN against a candidate clone before the splice).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
DC="$LIVE_ROOT/harness/sandbox/devcontainer.json"
LIB="$LIVE_ROOT/harness/sandbox-lib.sh"
RT="$LIVE_ROOT/harness/run-task.sh"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }

echo "== NETWORK: the manifest is networked-by-default (no hardcoded --network none) =="
grep -qE '"\$\{localEnv:FORGE_SANDBOX_NETWORK\}"' "$DC" && ok "devcontainer.json uses \${localEnv:FORGE_SANDBOX_NETWORK} for --network" || bad "manifest does not parameterize --network (RED until splice)"
# the OLD hardcoded form: "--network",\n "none" — must be gone.
if grep -Pzoq '"--network",\s*\n\s*"none"' "$DC" 2>/dev/null; then bad "manifest still HARDCODES --network none (RED until splice)"; else ok "manifest no longer hardcodes --network none"; fi
grep -qE 'FORGE_SANDBOX_NETWORK:-bridge' "$LIB" && ok "sandbox-lib.sh defaults FORGE_SANDBOX_NETWORK=bridge (networked)" || bad "sandbox-lib.sh does not default FORGE_SANDBOX_NETWORK (RED until splice)"

echo "== CONTAINER-DEFAULT: target builds are container-default; legacy var honored as alias =="
grep -qE 'FORGE_TARGET_CONTAINER' "$RT" && ok "run-task.sh gating references FORGE_TARGET_CONTAINER" || bad "run-task.sh has no FORGE_TARGET_CONTAINER (RED until splice)"
# default-on: the ultimate default must be 1 (on). Main has `FORGE_TARGET_REQUIRE_CONTAINER:-0` (opt-in)
# -> this grep is RED on main, GREEN after the flip to `${FORGE_TARGET_CONTAINER:-${FORGE_TARGET_REQUIRE_CONTAINER:-1}}`.
grep -qE 'FORGE_TARGET_REQUIRE_CONTAINER:-1' "$RT" && ok "target container defaults ON (ultimate default :-1) — container-default for target builds" || bad "target container is not default-on (RED until splice; main has :-0)"
grep -qE 'FORGE_TARGET_REQUIRE_CONTAINER' "$RT" && ok "legacy FORGE_TARGET_REQUIRE_CONTAINER still honored (alias)" || bad "legacy alias dropped"

echo "== LAYER B INTACT: the RO enforce mounts (the real isolation) are UNCHANGED by the network flip =="
grep -qE '/harness,type=bind,readonly' "$DC" && ok "harness/ RO mount intact" || bad "harness/ RO mount missing — Layer B REGRESSED"
grep -qE '/\.claude,type=bind,readonly' "$DC" && ok ".claude RO mount intact" || bad ".claude RO mount missing — Layer B REGRESSED"
grep -qE '/\.git/hooks,type=bind,readonly' "$DC" && ok ".git/hooks RO mount intact" || bad ".git/hooks RO mount missing — Layer B REGRESSED"
grep -qE 'cap-drop=ALL|--cap-drop' "$DC" && ok "hardened container (--cap-drop=ALL) intact (Layer A)" || bad "cap-drop missing — Layer A REGRESSED"

echo "== LIVE (optional, docker-gated): the container is networked by default, restrictable to none =="
if command -v docker >/dev/null 2>&1 && command -v devcontainer >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  . "$LIB" 2>/dev/null
  WT="$LIVE_ROOT/.claude/worktrees/fold32-net"; BR="probe/fold32-net"
  export FORGE_MAIN_ROOT="$LIVE_ROOT"
  git -C "$LIVE_ROOT" worktree add -q "$WT" -b "$BR" HEAD 2>/dev/null && mkdir -p "$WT/sandbox"
  cleanup32() { forge_sandbox_down "$WT" 2>/dev/null; git -C "$LIVE_ROOT" worktree remove --force "$WT" 2>/dev/null; git -C "$LIVE_ROOT" branch -D "$BR" 2>/dev/null; }
  trap cleanup32 EXIT
  if forge_sandbox_up "$WT" >/dev/null 2>&1; then
    net="$(forge_sandbox_exec "$WT" bash -lc 'getent hosts github.com >/dev/null 2>&1 && echo NET || echo NONET' 2>/dev/null | tr -d "[:space:]")"
    case "$net" in *NET*) ok "default container resolves an external host (networked)";; *) bad "default container could not resolve an external host (expected networked)" "$net";; esac
    forge_sandbox_down "$WT" 2>/dev/null
    if FORGE_SANDBOX_NETWORK=none forge_sandbox_up "$WT" >/dev/null 2>&1; then
      net0="$(FORGE_SANDBOX_NETWORK=none forge_sandbox_exec "$WT" bash -lc 'getent hosts github.com >/dev/null 2>&1 && echo NET || echo NONET' 2>/dev/null | tr -d "[:space:]")"
      case "$net0" in *NONET*) ok "FORGE_SANDBOX_NETWORK=none restores egress-deny (opt-out survives)";; *) bad "FORGE_SANDBOX_NETWORK=none did not restrict egress" "$net0";; esac
    else
      ok "SKIP live none-restriction (bring-up under FORGE_SANDBOX_NETWORK=none unavailable)"
    fi
  else
    ok "SKIP live network check (sandbox bring-up unavailable in this env)"
  fi
else
  ok "SKIP live network check (docker/devcontainer absent) — the static assertions are the lock"
fi

FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "this test run did not move the floor" || bad "floor moved during the test"
echo "==== fold32-topology: $P passed, $F failed ===="
[ "$F" -eq 0 ]
