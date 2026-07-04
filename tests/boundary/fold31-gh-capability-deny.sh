#!/usr/bin/env bash
# fold31 — gh (GitHub CLI) capability-deny canary (JSON-stdin, RED-first, FLOOR-MOVING).
#
# "Agents never merge / never administer" was CONVENTION-ONLY: the harness never CALLS `gh pr merge`, but
# nothing stopped an agent's Bash from calling it. Phase 4 adds a bounded gh capability boundary at the deny
# floor. Driven through the hook's JSON-stdin verdict contract (mirrors fold25 / tests/commitguard/run.sh).
# RED pre-splice (the live floor has no forge_check_gh -> every gh mutation ALLOWs); GREEN post-splice.
# FORGE_GUARD_DENY / FORGE_LIVE_ROOT override the hook + root (prove GREEN against a candidate overlay
# before the splice).
#
# FLOOR NOTE: forge_check_gh is a FLOOR-MOVING splice (it deliberately moves the floor hash, recorded at
# recert). This test asserts only that ITS OWN run does not move the floor (FLOOR_PRE == FLOOR_POST).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
LIVE_ROOT="${FORGE_LIVE_ROOT:-$(dirname "$_gcd")}"; unset _gcd
HOOK="${FORGE_GUARD_DENY:-$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh}"
command -v jq >/dev/null 2>&1 || { echo "fold31: SKIP — jq required to drive the hook"; exit 75; }
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"

verdict() { # <cmd> -> DENY | ALLOW
  local out
  out="$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | ( cd "$LIVE_ROOT" && bash "$HOOK" 2>/dev/null ))"
  printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && printf DENY || printf ALLOW
}

deny=(
  # ── pr merge (the flagship hole) ──
  'gh pr merge 5'
  'gh pr merge 5 --squash --delete-branch'
  'gh pr merge --auto 5'
  'gh -R owner/repo pr merge 5'                       # global -R value-flag before the group
  'gh pr merge'                                       # no-arg (merges the current-branch PR)
  # ── repo-admin mutations ──
  'gh repo delete owner/repo --yes'
  'gh repo archive owner/repo'
  'gh repo rename newname'
  'gh repo edit --visibility public'
  'gh repo set-default owner/repo'
  'gh repo deploy-key add key.pub'
  'gh repo transfer owner/repo neworg'
  # ── secrets (mutation AND listing) ──
  'gh secret set TOKEN --body xxx'
  'gh secret delete TOKEN'
  'gh secret remove TOKEN'
  'gh secret list'
  # ── dangerous auth operations ──
  'gh auth login --with-token'
  'gh auth logout'
  'gh auth token'
  'gh auth refresh --scopes repo'
  'gh auth setup-git'
  'gh auth switch'
  # ── workflow control ──
  'gh workflow run deploy.yml'
  'gh workflow disable ci.yml'
  'gh workflow enable ci.yml'
  # ── gh api mutation paths (method / field / input) ──
  'gh api -X POST repos/o/r/issues'
  'gh api --method PATCH repos/o/r'
  'gh api -X DELETE repos/o/r/pulls/1/reviews/2'
  'gh api --method=PUT repos/o/r/pulls/1/merge'       # the merge endpoint via api PUT
  'gh api -XPOST repos/o/r/merges'                     # glued -XPOST
  'gh api repos/o/r/issues -f title=x'                 # a field forces POST
  'gh api repos/o/r/issues -F body=@file'              # -F field
  'gh api --field title=x repos/o/r/issues'
  'gh api --input body.json repos/o/r/issues'          # --input body
  'gh api graphql -f query=x'                           # graphql is POST-only; -f -> accepted fail-closed over-block (agent graphql-via-Bash is rare; the harness runs graphql as an invisible subprocess). Documented residual.
  # ── launder shapes (defense-in-depth) ──
  'bash -c "gh pr merge 5"'                            # interpreter -c launder
  'eval gh pr merge 5'                                 # eval launder
  'echo gh pr merge 5 | bash'                          # pipe-into-shell launder
  'sudo gh repo delete owner/repo'                     # runner-wrapped resolves through to gh
  'timeout 5 gh pr merge 5'                            # runner-wrapped
  'xargs gh pr merge'                                  # non-piped xargs resolves through to gh
)
allow=(
  # ── the benign gh surface the build loop + reviewer depend on ──
  'gh pr create --base main --title x --body y'        # the harness finish path — MUST stay allowed
  'gh pr create --fill'
  'gh pr view 5'
  'gh pr view 5 --json state,headRefName'
  'gh pr diff 5'
  'gh pr comment 5 --body "looks good"'
  'gh pr comment 5 --body-file -'                       # reviewer post
  'gh pr comment 5 --body "$(cat findings.md)"'         # substitution in a BENIGN arg -> must NOT over-block
  'gh pr list --state open'
  'gh pr checks 5'
  'gh pr status'
  'gh pr ready 5'                                       # draft->ready: a mutation, but not merge/admin -> out of scope, allow
  'gh pr edit 5 --add-label wip'                        # pr edit is not repo-admin -> allow
  'gh repo view owner/repo'
  'gh repo list owner'
  'gh repo clone owner/repo'
  'gh auth status'                                      # the one allowed auth read
  'gh workflow list'
  'gh workflow view ci.yml'
  'gh run list'
  'gh run view 123'
  'gh issue create --title x --body y'
  'gh issue comment 5 --body z'
  'gh issue list'
  'gh api repos/o/r/pulls/5'                            # a GET read — the reviewer/agent REST read path
  'gh api repos/o/r/pulls/5/merge'                      # GET /merge = is-it-merged READ (no method) -> allow
  'gh api -H "Accept: application/vnd.github+json" repos/o/r'   # read header value must not desync
  'gh api repos/o/r --jq ".full_name"'                 # jq value must not be misread as a flag
  'gh api --method GET repos/o/r'                       # explicit GET
  # ── gh appearing as a NON-command-word must never trigger ──
  'echo "gh pr merge is forbidden"'                    # gh inside an echo string
  'git log --grep "gh pr merge"'                        # gh inside a git arg
  'grep -r "gh pr merge" docs/'                          # gh inside a grep pattern
  'cat notes.txt | grep merge'                          # merge word, no gh command word
  'gh pr view 5 | cat'                                  # benign gh read piped to a NON-shell
  # ── over-block guards: an OPAQUE command word + a gh-verb-shaped COMMON WORD must NOT deny (no opaque-cw arm).
  #    (These carry no leading env-assignment, so the pre-existing forge_check_envprefix over-block is not in play.) ──
  'git rebase && $EDITOR merge'                          # $EDITOR + bare "merge" — benign; must ALLOW
  '$SHELL rename'                                        # opaque cw + "rename" — benign; must ALLOW
  '$EDITOR --merge a.txt b.txt'                          # opaque cw + --merge flag — benign; must ALLOW
)

echo "== DENY: the agent's dangerous gh surfaces (merge / repo-admin / secrets / auth / workflow / api-write / launder) =="
for c in "${deny[@]}"; do
  [ "$(verdict "$c")" = DENY ] && ok "DENY $c" || bad "expected DENY (RED until the splice lands)" "$c"
done
echo "== ALLOW: gh reads + comments + create + api GET (over-block guards — MUST NOT break the build loop) =="
for c in "${allow[@]}"; do
  [ "$(verdict "$c")" = ALLOW ] && ok "ALLOW $c" || bad "expected ALLOW (over-block)" "$c"
done

echo "== CANARY: the deployed floor carries forge_check_gh + the wire-in + the keystone probe =="
grep -qF 'forge_check_gh() {' "$LIVE_ROOT/.claude/hooks/lib.sh" && ok "lib.sh defines forge_check_gh" || bad "lib.sh missing forge_check_gh (RED until splice)"
grep -qF 'forge_gh_deny() {' "$LIVE_ROOT/.claude/hooks/lib.sh" && ok "lib.sh carries forge_gh_deny" || bad "lib.sh missing forge_gh_deny (RED until splice)"
grep -qF 'forge_check_gh "$CMD"' "$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh" && ok "deny.sh wires in forge_check_gh" || bad "deny.sh missing the wire-in (RED until splice)"
grep -qF 'command -v forge_check_gh' "$LIVE_ROOT/.claude/hooks/pre-tool-use-deny.sh" && ok "keystone: deny.sh load-guard probes forge_check_gh" || bad "keystone probe missing forge_check_gh (RED until splice)"

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh 2>/dev/null)"
[ -n "$FLOOR_PRE" ] && [ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "this test run did NOT move the floor (the splice move is recorded at recert)" || bad "lib.sh changed during the test run" "pre=$FLOOR_PRE post=$FLOOR_POST"
echo "==== fold31-gh-capability-deny: $P passed, $F failed ===="
[ "$F" -eq 0 ]
