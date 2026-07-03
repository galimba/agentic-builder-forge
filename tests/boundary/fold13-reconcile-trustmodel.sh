#!/usr/bin/env bash
# FOLD #13 (Family B trust-model) RED-first: the close-on-merge oracle binds ONLY to the HARNESS-
# CAPTURED PR identity (.harness/pr/<bead>.json: repo+branch+pr) + state==MERGED + headRefName==branch — NOT
# the agent-mutable external_ref and NOT a live remote.origin.url read. So an agent pointing external_ref at a
# merged SIBLING PR (or repointing origin) must NOT close its unmerged bead; only its OWN captured PR merging,
# from the captured branch, closes it. Uses a FIXTURE gh (PR #44 = MERGED, branch feat/cp-floorhardening-2 — see below).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
. "$LIVE_ROOT/harness/beads-lib.sh"          # DEPLOYED trust-model forge_reconcile_run (#13)
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
command -v bd >/dev/null 2>&1 || { echo "  SKIP (bd absent — this suite mints real beads)"; echo "==== fold13-reconcile-trustmodel: SKIP ===="; exit 75; }
REPO="example-org/agentic-builder-forge"; MB="feat/cp-floorhardening-2"   # fixture PR #44: MERGED from this branch
TMP="$(mktemp -d)"; cleanup(){ rm -rf "$TMP" 2>/dev/null; }; trap cleanup EXIT
# FIXTURE gh: the reconcile oracle queries `gh pr view <pr> --repo <repo> --json state,headRefName`.
# A template must not depend on any live GitHub repo, so a local fake answers exactly that query:
# PR 44 on the OWN repo is MERGED from $MB; every other pr/repo pair is OPEN. All trust-model
# assertions (identity-bind, branch-bind, fail-closed) keep their semantics against this oracle.
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
# forge_clean_env pins PATH (env -i), which would hide the fixture gh — override it for this test
# only, keeping the env -i strip semantics (same pattern as the doc-hardening suite).
forge_clean_env() { env -i PATH="$FAKEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$@"; }
export ROOT="$TMP/db"; mkdir -p "$ROOT/.harness/pr"
( cd "$ROOT" && git init -q && git config user.email t@t && git config user.name t && git remote add origin "https://github.com/$REPO.git" && bd init >/dev/null 2>&1 && bd config set status.custom "in_review:wip" >/dev/null 2>&1 )
mk(){ # mk <title> -> prints bead id, sets it in_review with the given external_ref ($2)
  bd -C "$ROOT" create "$1" -p 2 >/dev/null 2>&1
  local id; id="$(bd -C "$ROOT" list --json 2>/dev/null | jq -r --arg t "$1" '.[]|select(.title==$t)|.id' | head -1)"
  bd -C "$ROOT" update "$id" --status in_review --external-ref "$2" >/dev/null 2>&1
  printf '%s' "$id"
}
rec(){ jq -nc --arg repo "$REPO" --arg branch "$2" --arg pr "$3" '{repo:$repo,branch:$branch,pr:$pr}' > "$ROOT/.harness/pr/$1.json"; }
# NB: `bd list` excludes closed beads — use `bd show` (shows any bead, incl. closed) to read the real status.
closed(){ [ "$(bd -C "$ROOT" show "$1" --json 2>/dev/null | jq -r '(.[0]//.).status' 2>/dev/null)" = "closed" ]; }

# b1 CORRECTNESS: captured record = the bead's OWN merged PR (#44, real branch) -> MUST close
b1="$(mk 'own-merged-pr' 'https://github.com/example-org/agentic-builder-forge/pull/44')"; rec "$b1" "$MB" "44"
# b2 SECURITY(PR-identity): external_ref points at merged #44, but the record is the bead's OWN unmerged PR -> MUST NOT close
b2="$(mk 'sibling-merged-attack' 'https://github.com/example-org/agentic-builder-forge/pull/44')"; rec "$b2" "forge/b2-unmerged" "99999999"
# b3 SECURITY(branch-bind): record pr=44 (MERGED) but branch=WRONG -> headRefName mismatch -> MUST NOT close
b3="$(mk 'wrong-branch-attack' 'https://github.com/example-org/agentic-builder-forge/pull/44')"; rec "$b3" "WRONG-BRANCH" "44"
# b4 no captured record -> fail-closed skip
b4="$(mk 'no-record' 'https://github.com/example-org/agentic-builder-forge/pull/44')"

forge_reconcile_run quiet >/dev/null 2>&1

closed "$b1"  && ok "CORRECTNESS: own captured PR #44 (MERGED, branch matches) -> bead CLOSED" || bad "own merged PR did not close the bead" ""
[ ! -f "$ROOT/.harness/pr/$b1.json" ] && ok "FOLD #16: the captured-PR record is CONSUMED on close (single-use) -> no stale record to re-close a reopened bead" || bad "FOLD #16: record survived the close (reopen would re-close)" ""
! closed "$b2" && ok "SECURITY (PR-identity): external_ref→merged-sibling #44 IGNORED; own captured PR unmerged -> NOT closed" || bad "sibling-merged external_ref closed an unmerged bead" ""
! closed "$b3" && ok "SECURITY (branch-bind): captured pr 44 MERGED but headRefName != captured branch -> NOT closed" || bad "branch mismatch still closed" ""
! closed "$b4" && ok "FAIL-CLOSED: no .harness/pr record -> bead NOT closed (no agent-supplied oracle)" || bad "no-record bead was closed" ""

# WRITE<->READ record-shape contract (offline residual cover): cmd_finish (run-task.sh) WRITES the captured
# .harness/pr record and forge_reconcile_run (beads-lib.sh) READS it — they must share the field set. The WRITE
# itself is not offline-driveable (FOLD #3's github push fails before run-task reaches the record-write), so pin
# the shape contract structurally so a rename on either end can't silently split write from read.
grep -q "'{repo:\$repo,branch:\$branch,pr:\$pr}'" "$LIVE_ROOT/harness/beads-lib.sh" \
  && ok "WRITE contract: forge_finish_record_pr (beads-lib) writes the .harness/pr record as {repo,branch,pr}" \
  || bad "forge_finish_record_pr record-write shape drifted from {repo,branch,pr}" ""
{ grep -q "jq -r '.repo // empty'" "$LIVE_ROOT/harness/beads-lib.sh" && grep -q "jq -r '.branch // empty'" "$LIVE_ROOT/harness/beads-lib.sh" && grep -q "jq -r '.pr // empty'" "$LIVE_ROOT/harness/beads-lib.sh"; } \
  && ok "READ contract: forge_reconcile_run consumes {repo,branch,pr} (matches the WRITE)" \
  || bad "reconcile record-read shape drifted from {repo,branch,pr}" ""

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact" || bad "LIVE FLOOR CHANGED" ""
echo "==== fold13-reconcile-trustmodel: $P passed, $F failed ===="
[ "$F" -eq 0 ]
