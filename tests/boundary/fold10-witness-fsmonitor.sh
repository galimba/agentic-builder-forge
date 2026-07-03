#!/usr/bin/env bash
# FOLD #10 (HIGH) — fixed by the floor-hardening splice (cardinal lib.sh / deny-floor change).
# RED-FIRST PIN + acceptance test. forge_floor_under_active_edit (.claude/hooks/lib.sh:~1779) ran a BARE
# `git diff --quiet HEAD` with NO `-c core.fsmonitor=`, so a planted core.fsmonitor in the F1-RW shared
# .git/config EXECs host-side during the finish witness gate (attended verify-fail path). The fix adds
# `-c core.fsmonitor= -c core.hooksPath=/dev/null` at :1779 and `-c core.fsmonitor=` (ONLY — the hooksPath
# override would corrupt `rev-parse --git-path hooks`) at forge_hookspath_ok (:1670). DEFAULT = the DEPLOYED
# tree (RED until the splice lands); FORGE_BOUNDARY_LIB=<candidate> proves GREEN.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
LIB="${FORGE_BOUNDARY_LIB:-$LIVE_ROOT/.claude/hooks/lib.sh}"   # SEAM: candidate vs DEPLOYED (default)
. "$LIB"                                      # the witness-path functions under test
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
TMP="$(mktemp -d)"; cleanup(){ rm -rf "$TMP" 2>/dev/null; }; trap cleanup EXIT
CL="$TMP/clone"; git clone -q --no-hardlinks "$LIVE_ROOT" "$CL"
MARK="$TMP/HOST_EXEC_FIRED"; EVIL="$TMP/evil.sh"
printf '#!/bin/sh\ntouch "%s"\n' "$MARK" > "$EVIL"; chmod +x "$EVIL"

# CONTROL: prove core.fsmonitor execs on a bare `git diff --quiet HEAD`, and that the -c form suppresses it.
git -C "$CL" config core.fsmonitor "$EVIL"
git -C "$CL" diff --quiet HEAD -- .claude/hooks/lib.sh >/dev/null 2>&1 || true
[ -f "$MARK" ] && ok "CONTROL: a BARE 'git diff --quiet HEAD' EXECS core.fsmonitor host-side (the primitive)" || bad "control: fsmonitor did not fire on bare git (cannot prove the vector)" ""
rm -f "$MARK"
git -C "$CL" -c core.fsmonitor= diff --quiet HEAD -- .claude/hooks/lib.sh >/dev/null 2>&1 || true
[ ! -f "$MARK" ] && ok "CONTROL: '-c core.fsmonitor=' SUPPRESSES the exec (the witness-PR fix form)" || bad "control: -c core.fsmonitor= did not suppress" ""
rm -f "$MARK"

# THE PIN: the DEPLOYED forge_floor_under_active_edit must NOT exec the planted program. RED until the witness PR.
forge_floor_under_active_edit "$CL" >/dev/null 2>&1 || true
[ ! -f "$MARK" ] && ok "FOLD #10 CLOSED: forge_floor_under_active_edit did NOT exec planted core.fsmonitor" \
  || bad "FOLD #10 OPEN (expected RED on the deployed tree until the floor-hardening splice): witness-path bare git EXECUTED core.fsmonitor host-side" "fix = -c core.fsmonitor= -c core.hooksPath=/dev/null at lib.sh:1779 (+ -c core.fsmonitor= at :1670)"

# ── :1670 forge_hookspath_ok — the DiD neutralizer (-c core.fsmonitor= ONLY) must NOT corrupt the hooks-path
#    resolution. A `-c core.hooksPath=/dev/null` HERE would: `rev-parse --git-path hooks` would return
#    /dev/null and the guard would never verify a correct install. Correctness/over-block guard — GREEN on
#    BOTH deployed and candidate (it proves the change is SAFE; :1670 is not a live fsmonitor vector since
#    rev-parse does not refresh the index).
git -C "$CL" config core.hooksPath "$CL/harness/githooks" 2>/dev/null
rm -f "$MARK"
if forge_hookspath_ok "$CL" >/dev/null 2>&1; then
  ok ":1670 forge_hookspath_ok still verifies a correct core.hooksPath (the fsmonitor= DiD did not corrupt --git-path hooks)"
else
  bad ":1670 forge_hookspath_ok FAILED for a correctly-installed hooksPath — the neutralizer corrupted the check" ""
fi
[ ! -f "$MARK" ] && ok ":1670 no planted core.fsmonitor exec on the hookspath probe (rev-parse does not refresh the index)" || { bad ":1670 planted core.fsmonitor EXECUTED on the hookspath probe" ""; rm -f "$MARK"; }
git -C "$CL" config core.hooksPath "$CL/nonexistent-hooks-dir" 2>/dev/null
if forge_hookspath_ok "$CL" >/dev/null 2>&1; then
  bad ":1670 forge_hookspath_ok verified a WRONG hooksPath — the check is vacuous" ""
else
  ok ":1670 forge_hookspath_ok correctly rejects a wrong core.hooksPath (not vacuous)"
fi

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact" || bad "LIVE FLOOR CHANGED" "$FLOOR_PRE -> $FLOOR_POST"
echo "==== fold10-witness-fsmonitor (RED until witness PR): $P passed, $F failed ===="
[ "$F" -eq 0 ]
