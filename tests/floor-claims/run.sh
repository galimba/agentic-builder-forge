#!/usr/bin/env bash
# tests/floor-claims/run.sh — the deny-floor classification honesty lock (P8).
#
# Keeps docs/deny-floor.md from rotting:
#   1. no ghost-test claims — every `test:<suite>` the doc cites is a REGISTERED package.json suite;
#   2. anti-silent-removal — the load-bearing GUARANTEE mechanisms still exist in the deny hook;
#   3. vault-seam lock — the DOES-NOT-CLAIM vault entry names fold28 AND the deny hook still makes NO
#      vault deny (the Phase-1 honesty seam cannot be silently upgraded to a guarantee);
#   4. doc shape — the three canonical sections + the residual taxonomy + the limitations.md cross-link.
# Text-only — no bd / jq / network — so it runs on every host and never SKIPs. It moves no floor.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
DOC="$ROOT/docs/deny-floor.md"
PKG="$ROOT/package.json"
HOOK="$ROOT/.claude/hooks/pre-tool-use-deny.sh"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
{ [ -f "$DOC" ] && [ -f "$PKG" ] && [ -f "$HOOK" ]; } || { echo "  FAIL: docs/deny-floor.md / package.json / deny hook missing"; echo "==== floor-claims: 0 passed, 1 failed ===="; exit 1; }

echo "== 1. no ghost-test claims — every cited test:<suite> is registered in package.json =="
missing=""
for tok in $(grep -oE 'test:[a-z0-9-]+' "$DOC" | sort -u); do
  grep -qF "\"$tok\":" "$PKG" || missing="$missing $tok"
done
[ -z "$missing" ] && ok "every cited test:<suite> is a registered package.json suite" || bad "doc cites unregistered suite(s):$missing"
ncited="$(grep -oE 'test:[a-z0-9-]+' "$DOC" | sort -u | grep -vc '^test:floor-claims$')"
[ "$ncited" -ge 15 ] && ok "doc cites $ncited distinct proving suites (>=15)" || bad "doc cites only $ncited proving suites — too few (gutted?)"

echo "== 2. anti-silent-removal — the deny hook still carries the load-bearing GUARANTEE mechanisms =="
# NB: these anchor on CALL-SITE presence in the deny hook, not lib.sh body integrity — a walker gutted
# to a no-op in lib.sh is caught by its behavioral suite (test:hooks/escape-classes/…), not here.
for anchor in 'ENFORCE_RE=' 'command -v forge_deny' 'forge_enforce_class' 'forge_check_push' 'forge_check_commit' 'forge_check_gh' 'forge_check_bd' 'forge_check_rm' 'forge_check_envprefix' 'forge_check_writes' 'forge_check_git'; do
  grep -qF "$anchor" "$HOOK" && ok "deny hook retains: $anchor" || bad "deny hook LOST a documented mechanism: $anchor"
done
grep -qE 'sk-\[A-Za-z0-9\]|AKIA\[0-9A-Z\]' "$HOOK" && ok "deny hook retains the secret-shaped-literal regex" || bad "deny hook lost the secret regex"

echo "== 3. vault-seam lock — DOES-NOT-CLAIM names fold28 + the deny hook still makes NO vault deny =="
grep -qiE 'vault' "$DOC" && ok "doc classifies the vault seam" || bad "doc does not classify the vault seam"
grep -qF 'test:fold28-vault-out-of-scope' "$DOC" && ok "the vault seam names its proof (fold28)" || bad "vault seam does not name fold28"
grep -qF '"test:fold28-vault-out-of-scope":' "$PKG" && ok "fold28 is a registered suite" || bad "fold28 not registered"
# Robust: strip full-line comments (the hook's only 'vault' mentions are explanatory block comments), then
# assert the LIVE code carries NO 'vault' token — a re-introduced vault deny (a `case */vault/*)` pattern
# OR a forge_deny reason) surfaces here regardless of same-line co-occurrence. fold28 is the behavioral
# backstop for the canonical absolute-path shape; this catches the broader textual re-introduction class.
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -qi 'vault'; then bad "the deny hook's LIVE code references a vault — a re-introduced vault deny breaks the honesty seam"; else ok "the deny hook's live code makes no vault reference (honesty seam intact)"; fi

echo "== 3b. tripwire completeness — the known best-effort residuals are classified, not dropped =="
# Locks against over-claim-by-omission: each residual that limitations.md flags best-effort must appear in
# this classification (as a TRIPWIRE / §3 entry), so a §1 GUARANTEE row cannot silently drop its caveat.
for kw in 'done-edge' 'record-trust' 'attendance' 'plumbing' 'env-prefix'; do
  grep -qiF "$kw" "$DOC" && ok "doc classifies the residual: $kw" || bad "doc dropped a known best-effort residual: $kw (over-claim-by-omission)"
done

echo "== 4. doc shape — the three canonical sections + taxonomy + limitations.md cross-link =="
for h in 'GUARANTEE' 'TRIPWIRE' 'DOES NOT CLAIM'; do
  grep -qF "$h" "$DOC" && ok "doc has the $h section" || bad "doc missing the $h section"
done
grep -qE '\[out-of-scope\]|\[best-effort\]|\[open\]|\[mech-mitigated\]' "$DOC" && ok "doc carries the residual taxonomy tags" || bad "doc lacks the residual taxonomy tags"
grep -qF 'limitations.md' "$DOC" && ok "doc cross-links limitations.md" || bad "doc does not cross-link limitations.md"

FLOOR_POST="$(git -C "$ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
{ [ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ]; } && ok "this run did not move the floor" || bad "lib.sh changed during the run"

echo "==== floor-claims: $P passed, $F failed ===="
[ "$F" -eq 0 ]
