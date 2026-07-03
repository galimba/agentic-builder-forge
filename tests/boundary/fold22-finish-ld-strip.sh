#!/usr/bin/env bash
# fold22 RED-first: an agent LD_PRELOAD/LD_AUDIT/GCONV_PATH/… .so must NOT fire on the
# finish/start/abort path. run-task.sh/accept-gate.sh/kill-switch.sh must clear-all-but-allowlist the
# loader env at top-of-script (default-deny), so even the bare `env` binary that forge_safe_env/
# forge_clean_env launch comes up clean. RED CONTROL: under LD_PRELOAD=<so>, the .so constructor fires
# INSIDE the `env` binary itself, BEFORE env -i clears the child (env -i alone does NOT stop it). FIX:
# with the loader-env clear (unset LD_*) first, the .so does NOT fire. CANARY: the deployed entrypoints
# clear-all + the wrappers carry the per-call unset (RED pre-splice, GREEN post-splice). The OWN-LAUNCH
# firing — the .so firing when the kernel/env load env+bash for the script's OWN launch, before line 1 —
# is the deny-hook+container boundary; demonstrated as a NOTE, NEVER asserted GREEN here.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd

# SKIP (rc 75) on genuine compiler absence — the run-all SKIP protocol (EX_TEMPFAIL).
CC=""; for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "fold22-finish-ld-strip: SKIP — no C compiler (cc/gcc/clang) to build the constructor .so"; exit 75; }

P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
TMP="$(mktemp -d)"; cleanup(){ rm -rf "$TMP" 2>/dev/null; }; trap cleanup EXIT
SENT="$TMP/fired"

# A constructor .so: its constructor runs host-side at LOAD time (before the host program's main) and
# touches a sentinel. That touch IS the host-exec.
cat > "$TMP/eok.c" <<EOF
#include <stdio.h>
__attribute__((constructor)) static void _f(void){ FILE*p=fopen("$SENT","w"); if(p){fputs("fired",p);fclose(p);} }
EOF
"$CC" -shared -fPIC -o "$TMP/eok.so" "$TMP/eok.c" 2>/dev/null \
  || { echo "fold22-finish-ld-strip: SKIP — compiler present but could not build a shared object"; exit 75; }

# RED CONTROL: under LD_PRELOAD, the .so fires INSIDE the bare `env` binary — env -i clears the CHILD's
# env, but the loader already ran the constructor in the env process. Sentinel present == it fired.
rm -f "$SENT"
( export LD_PRELOAD="$TMP/eok.so"; env -i PATH="/usr/bin:/bin" true ) >/dev/null 2>&1
if [ -f "$SENT" ]; then
  ok "RED CONTROL: LD_PRELOAD fires the .so inside the bare \`env\` binary (env -i does NOT stop it)"
else
  bad "control: .so did not fire via env -i (loader may ignore LD_PRELOAD here; cannot show the trap)" ""
fi

# FIX: the top-of-script clear (here: unset the loader vars before launching env) -> the .so does NOT fire.
rm -f "$SENT"
( export LD_PRELOAD="$TMP/eok.so"; unset LD_PRELOAD; env -i PATH="/usr/bin:/bin" true ) >/dev/null 2>&1
if [ ! -f "$SENT" ]; then
  ok "FIX: after the loader-env clear, the .so does NOT fire on the env-binary launch"
else
  bad "FIX: .so still fired after the clear" ""
fi

# CANARY: deployed entrypoints clear-all-but-allowlist the loader env; the wrappers carry the per-call unset.
for f in run-task.sh accept-gate.sh kill-switch.sh; do
  if grep -qF 'clear-all-but-allowlist the loader env' "$LIVE_ROOT/harness/$f" 2>/dev/null \
     && grep -qF 'compgen -e' "$LIVE_ROOT/harness/$f" 2>/dev/null; then
    ok "CANARY: deployed harness/$f clears the loader env at top-of-script"
  else
    bad "CANARY: harness/$f missing the top-of-script loader-env clear (RED until the splice lands)" "$f"
  fi
done
for w in sandbox-lib.sh beads-lib.sh; do
  if grep -qF 'unset LD_PRELOAD' "$LIVE_ROOT/harness/$w" 2>/dev/null; then
    ok "CANARY: deployed harness/$w carries the per-wrapper LD unset (DiD)"
  else
    bad "CANARY: harness/$w missing the per-wrapper LD unset (RED until the splice lands)" "$w"
  fi
done

# NOTE (residual; NOT asserted GREEN): the OWN-LAUNCH firing — the loader firing the .so
# when the kernel/env load env+bash for the script's OWN launch, before line 1 — is structurally
# un-closable in-script. Demonstrate it (it stays live regardless of any in-script measure) and record
# that it is owned by the deny-hook env-prefix classifier + the OS container — never counted here.
rm -f "$SENT"
printf '#!/usr/bin/env bash\n:\n' > "$TMP/probe.sh"; chmod +x "$TMP/probe.sh"
( export LD_PRELOAD="$TMP/eok.so"; "$TMP/probe.sh" ) >/dev/null 2>&1
if [ -f "$SENT" ]; then
  printf '  NOTE  own-launch firing CONFIRMED (LD_PRELOAD fires the .so at the script own launch, before line 1) — residual, owned by the env-prefix classifier + container, NOT this in-script fix.\n'
else
  printf '  NOTE  own-launch firing not reproduced in this env (loader may ignore LD_PRELOAD for this exec) — the deny-hook+container boundary still owns it.\n'
fi

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor (lib.sh) intact" || bad "LIVE FLOOR CHANGED or unreadable" "pre=$FLOOR_PRE post=$FLOOR_POST"
echo "==== fold22-finish-ld-strip: $P passed, $F failed ===="
[ "$F" -eq 0 ]
