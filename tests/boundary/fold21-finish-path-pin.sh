#!/usr/bin/env bash
# fold21 RED-first: a sandbox/-shimmed PATH must NOT be honored on the finish/start/abort path.
# run-task.sh + kill-switch.sh must pin PATH at top-of-script (mirroring accept-gate.sh:112's pin), so
# the harness shell cannot resolve a shimmed git/jq/id. RED CONTROL: without the pin a PATH-shim is
# resolved. FIX: with `export PATH=<system literal>` first, the system binary wins. CANARY: the DEPLOYED
# entrypoints carry the pin (RED pre-splice, GREEN post-splice). The LAUNCH-TIME analog — a PATH-shimmed
# `bash` INTERPRETER via the shebang, which runs before line 1 — is the deny-hook boundary,
# NOT this in-script pin (closed by the env-prefix classifier); recorded as a NOTE, never asserted GREEN.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
TMP="$(mktemp -d)"; cleanup(){ rm -rf "$TMP" 2>/dev/null; }; trap cleanup EXIT
PIN="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# A PATH-shim `git` printing SHIM — stands in for any hijacked bare command on the finish path.
mkdir -p "$TMP/bin"; printf '#!/bin/sh\necho SHIM\n' > "$TMP/bin/git"; chmod +x "$TMP/bin/git"

# RED CONTROL: with the shim prepended and NO pin, the harness shell resolves the shim.
red="$( PATH="$TMP/bin:$PATH"; command -v git )"
case "$red" in
  "$TMP/bin/git") ok "RED CONTROL: without a pin, a PATH-shim git is resolved ($red)" ;;
  *) bad "control: shim not resolved (cannot show the trap)" "red=$red" ;;
esac

# FIX: pin PATH to the system literal FIRST (the top-of-script pin) -> the system git wins.
green="$( PATH="$TMP/bin:$PATH"; export PATH="$PIN"; command -v git )"
case "$green" in
  "$TMP/bin/git") bad "FIX: shim still resolved after the pin" "green=$green" ;;
  "") bad "FIX: no git on the pinned PATH" "" ;;
  *) ok "FIX: with the top-of-script PATH pin, the system git wins, NOT the shim ($green)" ;;
esac

# FIX (behavioral): a pinned `git --version` is real git, never the SHIM.
out="$( PATH="$TMP/bin:$PATH"; export PATH="$PIN"; git --version 2>/dev/null )"
case "$out" in
  SHIM) bad "FIX: pinned git still ran the shim" "$out" ;;
  "git version"*) ok "FIX: pinned git --version is real git ($out)" ;;
  *) bad "FIX: unexpected git output" "$out" ;;
esac

# CANARY: every DEPLOYED finish/start/abort entrypoint pins PATH at top-of-script (RED until splice).
for f in run-task.sh accept-gate.sh kill-switch.sh; do
  if grep -qF 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' "$LIVE_ROOT/harness/$f" 2>/dev/null; then
    ok "CANARY: deployed harness/$f pins PATH at top-of-script"
  else
    bad "CANARY: harness/$f missing the top-of-script PATH pin (RED until the splice lands)" "$f"
  fi
done

# NOTE (NOT asserted GREEN): the shebang `#!/usr/bin/env bash` resolves the bash
# INTERPRETER from the agent PATH before line 1 — a shimmed bash is the LAUNCH-TIME vector the in-script
# pin cannot reach. Owned by the deny-hook env-prefix classifier + the OS container.
printf '  NOTE  launch-time interpreter firing (shim bash via the shebang) = deny-hook + container boundary; closed by the env-prefix classifier, not this in-script pin.\n'

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor (lib.sh) intact" || bad "LIVE FLOOR CHANGED or unreadable" "pre=$FLOOR_PRE post=$FLOOR_POST"
echo "==== fold21-finish-path-pin: $P passed, $F failed ===="
[ "$F" -eq 0 ]
