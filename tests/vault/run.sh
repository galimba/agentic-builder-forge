#!/usr/bin/env bash
# tests/vault/run.sh — optional read-only Vault (P7).
#
# Proves (a) the mechanical decision path is VAULT-BLIND — the load-bearing inertness lock: the vault
# never drives acceptance / bead / branch / security / merge; (b) the resolver harness/vault.sh is
# read-only, paths-only, absolute-only, and optional. The inertness lock inspects the DEPLOYED core, so
# it runs even pre-splice; the resolver checks SKIP honestly (rc 75) if harness/vault.sh is absent, so
# the suite is green on the branch and runs in full once the candidate is applied. This suite writes
# nothing to the tree and never moves the floor.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
VS="${FORGE_VAULT_SH:-$ROOT/harness/vault.sh}"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
skip(){ echo "  SKIP ($1)"; echo "==== vault: SKIP ===="; exit 75; }
FLOOR_PRE="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"

# ── INERTNESS LOCK — runs even without vault.sh (it inspects the deployed mechanical core) ─────────
# The vault must never drive a mechanical verdict. The gate + its sourced libs + run-task + the bead-mint
# (intake convert) + the completion authority (run-all.sh) carry ZERO vault references; the floor hooks may
# DISCUSS the vault in comments but must never INVOKE vault.sh or SOURCE vault.config. A regression that
# wired a vault read into any of these fails this lock. (No external tool dependency here — no jq/bd — so
# the lock runs on every host, including jq-less CI.)
echo "== inertness: the mechanical decision/mint/completion path is vault-blind =="
for f in harness/accept-gate.sh harness/beads-lib.sh harness/sandbox-lib.sh harness/run-task.sh harness/intake.sh tests/run-all.sh .claude/hooks/lib.sh; do
  if grep -qiE 'vault' "$ROOT/$f" 2>/dev/null; then bad "$f mentions vault — the decision/mint/completion path must be vault-blind"; else ok "$f: zero vault references"; fi
done
if grep -rnE 'vault\.sh|vault\.config' "$ROOT/.claude/hooks/" >/dev/null 2>&1; then bad "a floor hook invokes vault.sh / sources vault.config"; else ok "no floor hook invokes vault.sh or sources vault.config"; fi

# ── HONESTY LOCK — no doc re-introduces the enforced "the floor blocks the vault" claim ────────────
# Phase 1 removed a leaky "vault is read-only, ENFORCED" claim; the floor makes NO vault claim (fold28).
# A doc asserting the deny hook / floor blocks or protects the vault is FALSE — guard against re-introduction.
echo "== honesty: no doc claims the floor blocks/protects the vault =="
# Match the leaky ASSERTION shapes, then drop lines carrying an honesty-marker (a line that QUOTES the
# removed claim to explain its removal, or states the honest 'no vault claim / by convention' position).
if grep -rniE 'block[s]? the vault|protect[s]? the vault|vault is (mechanically )?(blocked|protected)|vault[^.]{0,30}read-only[^.]{0,15}enforc' \
     "$ROOT/.claude/agents/architect.md" "$ROOT/AGENTS.md" "$ROOT/CLAUDE.md" \
     "$ROOT/docs/limitations.md" "$ROOT/docs/configuration.md" "$ROOT/docs/operating.md" 2>/dev/null \
   | grep -viE 'remov|earlier|leaky|not a vault claim|no .*vault claim|out of.{0,12}scope|by convention|makes no'; then
  bad "a doc claims the floor blocks/protects the vault (the leaky enforced-vault claim Phase 1 removed)"
else
  ok "no doc claims the floor blocks/protects the vault (honesty seam intact)"
fi
grep -qiE 'no .*vault claim|out of.{0,12}scope' "$ROOT/docs/limitations.md" 2>/dev/null && ok "limitations.md keeps the honest 'no vault claim / out of scope' position" || bad "limitations.md lost the honest vault bullet"

if [ ! -f "$VS" ]; then
  echo "  (harness/vault.sh absent — resolver checks skipped; inertness lock above still ran)"
  echo "==== vault: $P passed, $F failed (resolver SKIPPED, pre-splice) ===="
  [ "$F" -eq 0 ] && exit 75 || exit 1
fi

# ── resolver: read-only, paths-only, absolute-only, optional ──────────────────────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/vaultA" "$TMP/vaultB"
CFG="$TMP/vault.config"
{ printf '# a comment\n'; printf 'a=%s/vaultA\n' "$TMP"; printf 'b=%s/vaultB\n' "$TMP"; printf 'rel=../x\n'; printf 'trav=/x/../y\n'; printf 'ghost=/no/such/dir\n'; } >"$CFG"

echo "== resolver: paths prints only absolute, existing dirs =="
out="$(FORGE_VAULT_CONFIG="$CFG" bash "$VS" paths 2>/dev/null)"
printf '%s\n' "$out" | grep -qxF "$TMP/vaultA" && ok "paths includes vaultA" || bad "paths missing vaultA" "$out"
printf '%s\n' "$out" | grep -qxF "$TMP/vaultB" && ok "paths includes vaultB" || bad "paths missing vaultB"
printf '%s\n' "$out" | grep -qE 'rel|trav|ghost|\.\.' && bad "paths leaked a skipped entry" "$out" || ok "paths skips relative / .. / nonexistent"
[ "$(printf '%s' "$out" | grep -c .)" = "2" ] && ok "paths prints exactly the 2 valid dirs" || bad "unexpected path count" "$out"

echo "== resolver: doctor summary (surfaces skipped) + optional (absent config) =="
doctor_out="$(FORGE_VAULT_CONFIG="$CFG" bash "$VS" doctor 2>/dev/null)"
printf '%s' "$doctor_out" | grep -qF "configured 3; present 2" && ok "doctor counts configured(3)/present(2)" || bad "doctor count wrong" "$doctor_out"
printf '%s' "$doctor_out" | grep -qF "skipped 2" && ok "doctor surfaces skipped(2) — a typo'd entry is not silently dropped" || bad "doctor does not surface skipped count" "$doctor_out"
FORGE_VAULT_CONFIG="$TMP/nope" bash "$VS" doctor 2>/dev/null | grep -qF "none (optional)" && ok "absent config -> none (optional)" || bad "absent config not optional"
o="$(FORGE_VAULT_CONFIG="$TMP/nope" bash "$VS" doctor 2>/dev/null)"; rc=$?; [ "$rc" = 0 ] && ok "absent config -> exit 0 (optional, never fails)" || bad "absent config exit $rc"

echo "== resolver: unknown subcommand fails closed; writes nothing (read-only) =="
FORGE_VAULT_CONFIG="$CFG" bash "$VS" bogus >/dev/null 2>&1; [ "$?" = "2" ] && ok "unknown subcommand -> exit 2" || bad "unknown subcommand not exit 2"
bash "$VS" >/dev/null 2>&1; [ "$?" = "2" ] && ok "no subcommand -> exit 2" || bad "no-arg not exit 2"
before="$(cd "$TMP" && find . | sort | sha256sum)"
FORGE_VAULT_CONFIG="$CFG" bash "$VS" paths >/dev/null 2>&1
FORGE_VAULT_CONFIG="$CFG" bash "$VS" doctor >/dev/null 2>&1
after="$(cd "$TMP" && find . | sort | sha256sum)"
[ "$before" = "$after" ] && ok "resolver wrote nothing (read-only)" || bad "resolver mutated the tree"

echo "== resolver: malformed / empty-name / empty-path / CRLF entries are skipped, never emitted =="
CFG2="$TMP/vault2.config"
{ printf 'noequals line\n'; printf '=/etc\n'; printf 'x=\n'; printf 'crlf=%s/vaultA\r\n' "$TMP"; } >"$CFG2"
o2="$(FORGE_VAULT_CONFIG="$CFG2" bash "$VS" paths 2>/dev/null)"
printf '%s\n' "$o2" | grep -qxF "$TMP/vaultA" && ok "CRLF entry resolves after CR strip" || bad "CRLF entry not resolved" "$o2"
printf '%s\n' "$o2" | grep -qE '/etc|noequals' && bad "a malformed/empty entry leaked into paths" "$o2" || ok "malformed / empty-name / empty-path entries skipped"
[ "$(printf '%s' "$o2" | grep -c .)" = "1" ] && ok "only the 1 valid (CRLF) entry emitted" || bad "unexpected count for the edge config" "$o2"

FLOOR_POST="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
{ [ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ]; } && ok "this run did not move the floor" || bad "lib.sh changed during the run"

echo "==== vault: $P passed, $F failed ===="
[ "$F" -eq 0 ]
