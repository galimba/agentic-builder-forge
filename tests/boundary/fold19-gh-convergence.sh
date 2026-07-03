#!/usr/bin/env bash
# Target A1 RED-first: gh-API transient convergence in beads-lib.sh.
#
#  A1.1 forge_reconcile_run: the assembly model points EVERY in_review feature bead at the SAME feature PR,
#       so the per-bead loop issues K identical `gh pr view` calls per sync. Fix memoizes by repo#pr -> 1 call.
#  A1.2 forge_ensure_feature_pr: an empty/timed-out `gh pr list` fell straight to `gh pr create`, and a create
#       that fails because the PR ALREADY EXISTS (stderr, hidden by 2>/dev/null) returned 1 -> die-after-push at
#       run-task.sh:480. Fix retries the ambiguous discover and converges an already-exists create to the PR url.
#
#   GREEN (deployed lib — the A1 fix has landed): 1 pr-view call; ensure_feature_pr converges
#         to the existing PR url. (Pre-splice RED: K pr-view calls; died on already-exists.)
#   FAIL-CLOSED canary:     a GENUINE (non-already-exists) create failure still returns non-zero + no url.
#
# No network: a PATH-shimmed fake gh + forge_clean_env stubbed to a pass-through (the real forge_clean_env's
# env -i pins PATH and would hide the fake — that hardening is its OWN property, exercised elsewhere).
# Seam: FORGE_BEADS_LIB overrides the lib under test (candidate overlays). SKIP 75 if gh/bd absent.
#   bash tests/boundary/fold19-gh-convergence.sh   # GREEN vs the deployed lib (standing regression lock; package.json "test:fold19-gh")
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
DEPLOYED="$LIVE_ROOT/harness/beads-lib.sh"
export FORGE_DEPLOYED_BEADS_LIB="$DEPLOYED"
# shellcheck disable=SC1090
. "${FORGE_BEADS_LIB:-$DEPLOYED}"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
command -v gh >/dev/null 2>&1 || { echo "  SKIP (gh absent)"; echo "==== fold19-gh-convergence: SKIP ===="; exit 75; }
command -v bd >/dev/null 2>&1 || { echo "  SKIP (bd absent)"; echo "==== fold19-gh-convergence: SKIP ===="; exit 75; }

export BD_REVIEW_STATUS="in_review"
export FORGE_PR_RETRY_SLEEP=0   # keep the bounded-retry fast + deterministic in tests

TMP="$(mktemp -d)"; cleanup(){ rm -rf "$TMP" 2>/dev/null; }; trap cleanup EXIT
ST="$TMP/gh-state"; mkdir -p "$ST" "$TMP/bin"
export GH_FAKE_ST="$ST"

# ── fake gh: log argv; honor -q/--jq; per-state-file modes for list/create; pr view serves pr-state.json ──
cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
ST="${GH_FAKE_ST:?fake gh needs GH_FAKE_ST}"
printf 'gh %s\n' "$*" >>"$ST/calls.log"
JQE=""; prev=""
for a in "$@"; do case "$prev" in -q|--jq) JQE="$a" ;; esac; prev="$a"; done
emit(){ if [ -n "$JQE" ]; then printf '%s' "$1" | jq -r "$JQE" 2>/dev/null; else printf '%s\n' "$1"; fi; }
case "$1 $2" in
  "pr view")
    emit "$(cat "$ST/pr-state.json" 2>/dev/null || echo '{"state":"OPEN","headRefName":"feat/demo"}')"; exit 0 ;;
  "pr list")
    c=$(( $(cat "$ST/list-calls" 2>/dev/null || echo 0) + 1 )); echo "$c" >"$ST/list-calls"
    case "$(cat "$ST/list-mode" 2>/dev/null)" in
      transient)            exit 1 ;;
      found)                emit "$(cat "$ST/found.json")"; exit 0 ;;
      empty-then-found)     if [ "$c" -ge 2 ]; then emit "$(cat "$ST/found.json")"; else emit '[]'; fi; exit 0 ;;
      transient-then-found) if [ "$c" -ge 2 ]; then emit "$(cat "$ST/found.json")"; exit 0; else exit 1; fi ;;
      *)                    emit '[]'; exit 0 ;;
    esac ;;
  "pr create")
    n=$(( $(cat "$ST/create-count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$ST/create-count"
    case "$(cat "$ST/create-mode" 2>/dev/null)" in
      exists)   printf 'pull request create failed: a pull request for branch "feat/demo" into branch "main" already exists:\nhttps://github.com/o/r/pull/7\n' >&2; exit 1 ;;
      hardfail) printf 'pull request create failed: HTTP 500 (server error)\n' >&2; exit 1 ;;
      *)        echo "https://github.com/o/r/pull/7"; exit 0 ;;
    esac ;;
  *) echo "{}"; exit 0 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
forge_clean_env() { GITHUB_TOKEN="${GITHUB_TOKEN:-x}" "$@"; }   # test stub: reach the fixture's fake gh past env -i

# ════════ A1.1 — forge_reconcile_run: ONE gh pr view per distinct repo#pr ════════
export ROOT="$TMP/db"; mkdir -p "$ROOT/.harness/pr"
( cd "$ROOT" && git init -q && git config user.email t@t && git config user.name t \
    && bd init --non-interactive >/dev/null 2>&1 && bd config set status.custom "in_review:wip" >/dev/null 2>&1 )
mk(){ bd -C "$ROOT" create "$1" -p 2 >/dev/null 2>&1; bd -C "$ROOT" list --json 2>/dev/null | jq -r --arg t "$1" '.[]|select(.title==$t)|.id' | head -1; }
rec(){ jq -nc '{repo:"o/r",branch:"feat/demo",pr:"7"}' > "$ROOT/.harness/pr/$1.json"; }
status_of(){ bd -C "$ROOT" show "$1" --json 2>/dev/null | jq -r '(.[0]//.).status' 2>/dev/null; }
b1="$(mk one)"; b2="$(mk two)"; b3="$(mk three)"
for b in "$b1" "$b2" "$b3"; do bd -C "$ROOT" update "$b" --status in_review >/dev/null 2>&1; rec "$b"; done

# arm A1.1a: 3 in_review beads, ONE shared PR, NOT merged (OPEN) -> dedupe the query, close nothing
printf '{"state":"OPEN","headRefName":"feat/demo"}' >"$ST/pr-state.json"; : >"$ST/calls.log"
forge_reconcile_run quiet >/dev/null 2>&1
n="$(grep -c 'pr view' "$ST/calls.log" 2>/dev/null || echo 0)"
[ "$n" -eq 1 ] && ok "A1.1 dedupe: 3 beads on one feature PR -> exactly 1 gh pr view" \
  || bad "A1.1: expected 1 gh pr view for one repo#pr, got $n (no dedupe)" ""
still=0; for b in "$b1" "$b2" "$b3"; do [ "$(status_of "$b")" = "in_review" ] && still=$((still+1)); done
[ "$still" -eq 3 ] && ok "A1.1: OPEN PR -> no bead closed (fail-closed verdict unchanged)" || bad "A1.1: $still/3 still in_review on an OPEN PR" ""

# arm A1.1b: positive — MERGED + headRefName==branch -> all 3 close, STILL exactly 1 query
printf '{"state":"MERGED","headRefName":"feat/demo"}' >"$ST/pr-state.json"; : >"$ST/calls.log"
forge_reconcile_run quiet >/dev/null 2>&1
n2="$(grep -c 'pr view' "$ST/calls.log" 2>/dev/null || echo 0)"
closed=0; for b in "$b1" "$b2" "$b3"; do [ "$(status_of "$b")" = "closed" ] && closed=$((closed+1)); done
{ [ "$closed" -eq 3 ] && [ "$n2" -eq 1 ]; } \
  && ok "A1.1 positive: MERGED -> all 3 beads close, still exactly 1 gh pr view (per-bead close, dedup'd query)" \
  || bad "A1.1 positive: expected 3 closed + 1 query, got closed=$closed query=$n2" ""

# ════════ A1.2 — forge_ensure_feature_pr: converge on transient / already-exists ════════
printf '[{"url":"https://github.com/o/r/pull/7"}]' >"$ST/found.json"
reset_gh(){ : >"$ST/calls.log"; echo 0 >"$ST/list-calls"; echo 0 >"$ST/create-count"; }

# arm A: PR exists; discovered only AFTER create fails "already exists" (list stays empty -> stderr url-parse)
reset_gh; echo empty >"$ST/list-mode"; echo exists >"$ST/create-mode"
outA="$(forge_ensure_feature_pr o/r feat/demo main 'T' 'B')"; rcA=$?
{ [ "$rcA" -eq 0 ] && [ "$outA" = "https://github.com/o/r/pull/7" ]; } \
  && ok "A1.2 arm A: create 'already exists' -> converge to the existing PR url (rc 0), NOT die-after-push" \
  || bad "A1.2 arm A: expected rc0 + the PR url, got rc=$rcA out='$outA'" ""

# arm B: PR exists; a transient first list, then found on RETRY -> converge with NO spurious create
reset_gh; echo transient-then-found >"$ST/list-mode"; echo exists >"$ST/create-mode"
outB="$(forge_ensure_feature_pr o/r feat/demo main 'T' 'B')"; rcB=$?
ccB="$(cat "$ST/create-count")"
{ [ "$rcB" -eq 0 ] && [ "$outB" = "https://github.com/o/r/pull/7" ] && [ "$ccB" -eq 0 ]; } \
  && ok "A1.2 arm B: transient list -> RETRY discovers the PR (rc 0), NO spurious create" \
  || bad "A1.2 arm B: expected rc0 + url + 0 creates, got rc=$rcB out='$outB' creates=$ccB" ""

# canary: a GENUINE create failure (not already-exists) must STILL fail closed (rc!=0, no url)
reset_gh; echo empty >"$ST/list-mode"; echo hardfail >"$ST/create-mode"
outC="$(forge_ensure_feature_pr o/r feat/demo main 'T' 'B')"; rcC=$?
{ [ "$rcC" -ne 0 ] && [ -z "$outC" ]; } \
  && ok "A1.2 FAIL-CLOSED: a genuine (non-already-exists) create failure still returns non-zero + no url" \
  || bad "A1.2 canary: a genuine failure was not fail-closed, rc=$rcC out='$outC'" ""

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact (.claude/hooks/lib.sh unchanged)" || bad "LIVE FLOOR CHANGED" ""
echo "==== fold19-gh-convergence: $P passed, $F failed ===="
[ "$F" -eq 0 ]
