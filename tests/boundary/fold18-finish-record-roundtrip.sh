#!/usr/bin/env bash
# FOLD #13 WRITE<->READ round-trip (covers the finish-WRITE logic offline, the residual FOLD #3 left):
# the WRITE (forge_finish_record_pr, extracted VERBATIM from cmd_finish) and the READ (forge_reconcile_run)
# agree end-to-end through the REAL code — NOT a reimplementation. WRITE a record for the bead's OWN merged
# PR #44 (branch feat/cp-floorhardening-2), then RECONCILE reads it (real gh: #44 MERGED + branch matches) and
# closes the bead. The push→write GATING is the only un-covered bit offline (push mechanism is fold3).
# Sources DEPLOYED beads-lib: RED pre-door (forge_finish_record_pr absent), GREEN post-door.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
. "$LIVE_ROOT/harness/beads-lib.sh"          # DEPLOYED forge_finish_record_pr (WRITE) + forge_reconcile_run (READ)
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
command -v bd >/dev/null 2>&1 || { echo "  SKIP (bd absent — this suite mints real beads)"; echo "==== fold18-finish-record-roundtrip: SKIP ===="; exit 75; }
type forge_finish_record_pr >/dev/null 2>&1 || { bad "forge_finish_record_pr absent (RED until the extraction door lands)" ""; echo "==== fold18-finish-record-roundtrip: $P passed, $F failed ===="; exit 1; }
REPO="example-org/agentic-builder-forge"; MB="feat/cp-floorhardening-2"   # fixture PR #44: MERGED from this branch
TMP="$(mktemp -d)"; cleanup(){ rm -rf "$TMP" 2>/dev/null; }; trap cleanup EXIT
# FIXTURE gh (see fold13): answers the reconcile oracle's exact query — PR 44 on the OWN repo is
# MERGED from $MB — so the round-trip proof depends on no live GitHub repo.
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
pr=""; repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift ;;
    --json|-q) shift ;;
    [0-9]*) pr="$1" ;;
  esac
  shift
done
if [ "$pr" = "44" ] && [ "$repo" = "example-org/agentic-builder-forge" ]; then
  printf 'MERGED\tfeat/cp-floorhardening-2\n'
else
  printf 'OPEN\tno-such-branch\n'
fi
FAKEGH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"
forge_clean_env() { env -i PATH="$FAKEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$@"; }
export ROOT="$TMP/db"; mkdir -p "$ROOT/.harness"
( cd "$ROOT" && git init -q && git config user.email t@t && git config user.name t && git remote add origin "https://github.com/$REPO.git" && bd init >/dev/null 2>&1 && bd config set status.custom "in_review:wip" >/dev/null 2>&1 )
bd -C "$ROOT" create "round-trip bead" -p 2 >/dev/null 2>&1
id="$(bd -C "$ROOT" list --json 2>/dev/null | jq -r '.[]|select(.title=="round-trip bead")|.id' | head -1)"
[ -n "$id" ] && ok "setup: bead minted ($id)" || bad "setup: no bead" ""

# ---- WRITE: the REAL forge_finish_record_pr writes the record + sets in_review (no push needed) ----
forge_finish_record_pr "$id" "$REPO" "$MB" "https://github.com/$REPO/pull/44" "$ROOT/.harness" >/dev/null 2>&1
rec="$ROOT/.harness/pr/$id.json"
{ [ -f "$rec" ] && [ "$(jq -r .repo "$rec" 2>/dev/null)" = "$REPO" ] && [ "$(jq -r .branch "$rec" 2>/dev/null)" = "$MB" ] && [ "$(jq -r .pr "$rec" 2>/dev/null)" = "44" ]; } \
  && ok "WRITE: forge_finish_record_pr wrote .harness/pr/<bead>.json = {repo:$REPO, branch:$MB, pr:44}" \
  || bad "WRITE: record missing/wrong shape" "$( [ -f "$rec" ] && cat "$rec" || echo NO-FILE)"
[ "$(bd -C "$ROOT" show "$id" --json 2>/dev/null | jq -r '(.[0]//.).status' 2>/dev/null)" = "in_review" ] \
  && ok "WRITE: forge_finish_record_pr set the bead -> in_review" || bad "WRITE: bead not in_review" ""

# ---- READ: the REAL forge_reconcile_run reads THAT record -> #44 MERGED + branch matches -> closes ----
forge_reconcile_run quiet >/dev/null 2>&1
[ "$(bd -C "$ROOT" show "$id" --json 2>/dev/null | jq -r '(.[0]//.).status' 2>/dev/null)" = "closed" ] \
  && ok "ROUND-TRIP: forge_reconcile_run closed the bead via the WRITTEN record (write->read agree end-to-end through the real code)" \
  || bad "ROUND-TRIP: reconcile did not close the bead written by forge_finish_record_pr" ""

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact" || bad "LIVE FLOOR CHANGED" ""
echo "==== fold18-finish-record-roundtrip: $P passed, $F failed ===="
[ "$F" -eq 0 ]
