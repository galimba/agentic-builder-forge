#!/usr/bin/env bash
# doctor dependency-preflight canary (Phase 5b). Proves:
#   A. at-rest bare doctor.sh still exits 0 with bd/gh/docker ABSENT (the CI at-rest contract).
#   B. --post-init FAILs (naming them) when bd/gh are absent.
#   C. --container makes docker absence a FAIL (explicit container-proof mode).
#   D. WARN-level tools (docker) are advisory at rest, never fatal.
#
# Absence is simulated with a symlink PATH-farm that carries the coreutils doctor needs but NOT bd/gh/docker,
# so the test is independent of what this host actually has installed. This suite does NOT move the floor.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
DOC="$ROOT/.forge/scripts/doctor.sh"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ -f "$DOC" ] || { echo "  SKIP (doctor.sh absent)"; echo "==== doctor-preflight: SKIP ===="; exit 75; }

# Build a PATH farm WITHOUT bd/gh/docker/devcontainer (but WITH everything doctor.sh needs).
BINROOT="$(mktemp -d)"; BIN="$BINROOT/bin"; mkdir -p "$BIN"
for t in bash sh git jq sed grep egrep cat head tail cut tr find dirname basename realpath env printf ls awk sort uniq wc mktemp rm mkdir true false; do
    p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$BIN/$t"
done
cleanup(){ rm -rf "$BINROOT" 2>/dev/null; }; trap cleanup EXIT
# sanity: the farm must NOT resolve bd/gh/docker (else the test is vacuous)
if PATH="$BIN" command -v bd >/dev/null 2>&1 || PATH="$BIN" command -v gh >/dev/null 2>&1 || PATH="$BIN" command -v docker >/dev/null 2>&1; then
    echo "  SKIP (could not construct a bd/gh/docker-free PATH farm)"; echo "==== doctor-preflight: SKIP ===="; exit 75
fi
drun(){ PATH="$BIN" bash "$DOC" "$@" 2>&1; }   # doctor resolves FORGE_ROOT via BASH_SOURCE, so cwd is irrelevant

echo "== A: at-rest bare doctor exits 0 with bd/gh/docker absent (CI at-rest contract) =="
o="$(drun)"; rc=$?
[ "$rc" -eq 0 ] && ok "at-rest bare doctor exits 0 despite bd/gh/docker absent" || bad "at-rest doctor failed (rc=$rc)" "$(printf '%s' "$o" | grep -i fail | head -2)"
printf '%s' "$o" | grep -Eq '^  -- .*bd not found' && ok "bd absent -> info (--) at rest, not FAIL" || bad "bd not reported as info at rest"
printf '%s' "$o" | grep -Eq '^  WARN .*docker' && ok "docker absent -> WARN at rest (advisory)" || bad "docker not WARN at rest"

echo "== B: --post-init FAILs (naming bd + gh) when they are absent =="
o="$(drun --post-init)"; rc=$?
[ "$rc" -ne 0 ] && ok "--post-init exits non-zero when bd/gh absent" || bad "--post-init did not fail with bd/gh absent"
printf '%s' "$o" | grep -Eq '^  FAIL .*bd NOT found' && ok "bd absent -> FAIL under --post-init" || bad "bd not FAIL under --post-init"
printf '%s' "$o" | grep -Eq '^  FAIL .*gh NOT found' && ok "gh absent -> FAIL under --post-init" || bad "gh not FAIL under --post-init"

echo "== C: --container makes docker/devcontainer absence a FAIL (explicit container-proof) =="
o="$(drun --container)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$o" | grep -Eq '^  FAIL .*docker NOT found'; } && ok "--container: docker absent -> FAIL" || bad "--container did not FAIL on docker" "rc=$rc"
# without --container, the SAME absence is only WARN (already asserted in A) — the gate is opt-in.

echo "== D: an unknown flag is still rejected (arg surface preserved) =="
drun --bogus >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "unknown flag -> exit 2 (usage)" || bad "unknown flag not rejected"

FLOOR_POST="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "this run did not move the floor" || bad "lib.sh changed during the run"
echo "==== doctor-preflight: $P passed, $F failed ===="
[ "$F" -eq 0 ]
