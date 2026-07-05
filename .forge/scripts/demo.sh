#!/usr/bin/env bash
# ==============================================================================
# FORGE DEMO — an offline, end-to-end proof of the governed target-repo loop.
#
#   bash .forge/scripts/demo.sh
#
# Synthesizes a THROWAWAY forge (a clone with a fresh ledger) and a THROWAWAY target
# repo entirely under a temp dir, then drives the real loop against them:
#
#   architect-shaped bead (a real acceptance contract)  ->  run-task start  (worktree
#   + forge/agent/builder branch in the TARGET)  ->  the agent's product write  ->
#   run-task finish  (target test + the no-LLM acceptance gate + a pristine commit).
#
# The final push to a remote stops offline — the throwaway target's origin is a fake
# GitHub URL, so `finish` reaches the commit (which we show) and then cannot push;
# that is exactly where a human merge happens on your real platform. NOTHING in your
# tracked tree, .beads ledger, or .harness runtime state is touched — everything lives
# in a temp dir that is removed on exit.
#
# Requires git, bd, jq. Uses TARGET=static (no Node/pnpm needed). Run it in a terminal
# (the loop's attended-human gates read a TTY).
# ==============================================================================
set -u

FORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
say()  { printf '\n\033[1m→ %s\033[0m\n' "$*"; }   # bold step
note() { printf '   %s\n' "$*"; }
die()  { printf '\ndemo: %s\n' "$*" >&2; exit 1; }

# ---- preflight (mirrors doctor's dependency philosophy) ----------------------
for t in git bd jq; do
    command -v "$t" >/dev/null 2>&1 || die "needs '$t' on PATH (git, bd, jq are required; TARGET=static means Node/pnpm are NOT)."
done
BD_ABS="$(command -v bd)"   # absolute bd path — run-task pins a system-only PATH, so the throwaway forge must pin this
BD_VER="$(bd version 2>/dev/null | sed -n 's/^bd version \([0-9.][0-9.]*\).*/\1/p' | head -1)"
if [ ! -t 0 ]; then
    note "NOTE: no TTY on stdin — the loop's attended gates want one. If this fails at 'start',"
    note "      re-run in an interactive terminal (or: script -qec 'bash .forge/scripts/demo.sh' /dev/null)."
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-demo.XXXXXX")" || die "mktemp failed"
cleanup() {
    # release/prune any worktrees, then remove the whole temp tree (all under $TMP).
    [ -n "${DForge:-}" ] && git -C "$DForge" worktree prune >/dev/null 2>&1
    [ -n "${DTarget:-}" ] && git -C "$DTarget" worktree prune >/dev/null 2>&1
    rm -rf "$TMP" 2>/dev/null
}
trap cleanup EXIT

DForge="$TMP/forge"
DTarget="$TMP/target"
DBare="$TMP/target-origin.git"

# ---- 1. throwaway forge (a clone + a fresh, empty ledger) --------------------
say "Synthesizing a throwaway forge (a clone of THIS harness with a fresh ledger)"
git clone -q --no-hardlinks "$FORGE_ROOT" "$DForge" || die "could not clone the forge into the temp dir"
(
    cd "$DForge" || exit 1
    git config user.email demo@localhost; git config user.name "forge demo"
    git config beads.role maintainer
    # pin BD_BIN to the absolute path (init does this) — run-task strips PATH to system dirs, and bd may
    # live elsewhere (e.g. ~/.local/bin), so a PATH-resolved 'bd' would vanish and the version preflight fail.
    sed -i "s|^BD_BIN=.*|BD_BIN=\"\${BD_BIN:-${BD_ABS}}\"|" harness/beads.config
    # pin the throwaway's version to THIS host's bd (run-task strips BD_ALLOW_VERSION_DRIFT, so the pin must match)
    [ -n "${BD_VER}" ] && sed -i "s|^BD_VERSION_PIN=.*|BD_VERSION_PIN=\"${BD_VER}\"|" harness/beads.config
    # pin the throwaway's target type to `static` — run-task strips a `TARGET=` env, so targets.config's
    # own default is what wins; `static` means the DoD test is a plain shell script (no Node/pnpm needed).
    sed -i 's|^TARGET="${TARGET:-typescript}"|TARGET="${TARGET:-static}"|' harness/targets.config
    bd init --skip-agents --skip-hooks --non-interactive -p dm >/dev/null 2>&1
    bd config set status.custom "in_review:wip" >/dev/null 2>&1
) || die "could not initialize the throwaway ledger"
note "forge:   $DForge   (its own .beads ledger; your real ledger is untouched)"

# ---- 2. throwaway target repo (a tiny site with a trivial DoD test) ----------
say "Synthesizing a throwaway TARGET repo (a tiny static site)"
(
    cd "$DTarget" 2>/dev/null || { mkdir -p "$DTarget" && cd "$DTarget"; } || exit 1
    git init -q && git config user.email t@t && git config user.name t
    git symbolic-ref HEAD refs/heads/main
    printf '<h1>landing</h1>\n' > index.html
    mkdir -p tests/dod && printf '#!/usr/bin/env bash\n# the target'"'"'s own DoD test — trivially green offline\nexit 0\n' > tests/dod/run.sh
    chmod +x tests/dod/run.sh
    git add -A && git commit -q -m "base: landing page + DoD test"
    # a real origin so the harness'"'"'s start-time push-URL capture is satisfied; a bare local repo
    # establishes main, then we repoint origin to a fake GitHub URL so finish'"'"'s push stops offline.
    git -C "$DBare" init -q --bare 2>/dev/null || { mkdir -p "$DBare" && git -C "$DBare" init -q --bare; }
    git remote add origin "$DBare" && git push -q -u origin main
    git remote set-url origin "https://github.com/forge-demo/synthtarget.git"
) || die "could not synthesize the target repo"
note "target:  $DTarget   (origin = a fake GitHub URL, so the push stops offline by design)"

# ---- 3. register the target + mint an architect-shaped bead ------------------
say "Registering the target and minting an architect-shaped bead (a real acceptance contract)"
REPOSCFG="$TMP/repos.config"
printf 'synthtarget=%s\n' "$DTarget" > "$REPOSCFG"
# The three machine fields the no-LLM acceptance gate enforces (identical shape to intake→convert):
accjson="$(jq -nc '{scope:["about.html"], dod_tests:["tests/dod/run.sh"], sc_evidence:[{sc:1, path:"about.html"}]}')"
# a forge-relative spec (source_spec is forge-relative; the gate re-reads its Task Breakdown anchor)
mkdir -p "$DForge/specs/demo"
{
    printf '# Demo spec — add an About page\n\n<!-- forge:tasks:begin v1 -->\n```json\n'
    jq -nc --argjson a "$accjson" '{target_repos:["synthtarget"], tasks:[({id:"T001", title:"add an about page", satisfies:["FR-001"], priority:1, depends_on:[], target_repo:"synthtarget", definition_of_done:"about.html exists", success_criteria:["about.html is served"]} + $a)]}'
    printf '\n```\n<!-- forge:tasks:end -->\n'
} > "$DForge/specs/demo/spec.md"
meta="$(jq -nc --argjson a "$accjson" '{target_repo:"synthtarget", source_spec:"specs/demo/spec.md", task_id:"T001", accept:$a}')"
bid="$(cd "$DForge" && printf 'The About page is reachable and its DoD test is green.\n' | bd create "add an about page" --body-file - --acceptance "about.html present and served; DoD test green" --metadata "$meta" -p 1 --silent 2>/dev/null | tr -d '[:space:]')"
[ -n "$bid" ] || die "could not mint the demo bead (bd create failed)"
note "bead:    $bid   (metadata.target_repo=synthtarget, metadata.accept = the machine contract)"

# ---- 4. run-task start: worktree + forge/agent/builder branch in the TARGET --
say "run-task start — claims the bead, worktrees the TARGET on a forge/agent/builder branch"
RT="$DForge/harness/run-task.sh"
sout="$(cd "$DForge" && FORGE_TARGET_CONTAINER=0 FORGE_SKIP_INSTALL=1 FORGE_REPOS_CONFIG="$REPOSCFG" timeout 60 bash "$RT" start "$bid" 2>&1)"
srn=$?
if [ "$srn" -ne 0 ]; then
    printf '%s\n' "$sout" | sed 's/^/   /'
    die "run-task start failed (rc=$srn). If it mentions the confinement boundary, re-run in an interactive terminal (TTY)."
fi
wt="$(jq -r '.worktree // empty' "$DForge/.harness/active-task.json" 2>/dev/null)"
br="$(jq -r '.branch // empty' "$DForge/.harness/active-task.json" 2>/dev/null)"
note "branch:  $br   (target-repo namespace: forge/agent/builder/<id>-<slug>)"
note "worktree in the TARGET repo: $wt"

# ---- 5. the agent's product write (inside the confined work root) ------------
say "The agent writes its product (about.html) inside the confined work root"
printf '<!doctype html>\n<title>About</title>\n<h1>About</h1>\n<p>Built by the Forge demo loop.</p>\n' > "$wt/about.html"
note "wrote $wt/about.html"

# ---- 6. run-task finish: target test + acceptance gate + pristine commit -----
say "run-task finish — runs the target test + the no-LLM acceptance gate, then commits"
# The commit lands BEFORE the github-only push. We do NOT require finish exit 0, and we bound it with a
# timeout: the origin is a fake GitHub URL, so the final push either fails fast or (in a network-restricted
# environment) blocks — either way the commit we verify below has already been made.
fout="$(cd "$DForge" && FORGE_TARGET_CONTAINER=0 FORGE_SKIP_INSTALL=1 FORGE_REPOS_CONFIG="$REPOSCFG" timeout 60 bash "$RT" finish 2>&1)"
tbr="$(git -C "$DTarget" for-each-ref --format='%(refname:short)' 'refs/heads/forge/agent/builder/*' | head -1)"
[ -n "$tbr" ] || { printf '%s\n' "$fout" | sed 's/^/   /'; die "the target build branch was not created — the loop did not reach the commit."; }
tfiles="$(git -C "$DTarget" ls-tree -r --name-only "$tbr" 2>/dev/null)"

# ---- 7. show the artifacts + the honest offline boundary --------------------
say "Result — the governed loop reached a pristine commit on the target branch"
note "commit on:  $tbr  ($(git -C "$DTarget" log -1 --format='%h %s' "$tbr" 2>/dev/null))"
if printf '%s\n' "$tfiles" | grep -qx "about.html"; then note "product:    about.html IS in the commit (the acceptance gate's sc_evidence + scope passed)"; else printf '%s\n' "$fout" | tail -20 | sed 's/^/   finish> /'; die "about.html missing from the commit"; fi
if printf '%s\n' "$tfiles" | grep -qE '(^|/)\.claude/|(^|/)\.beads/|(^|/)harness/|(^|/)\.harness/'; then
    die "PURITY VIOLATION: a forge artifact reached the target commit"
else
    note "pristine:   the commit carries ZERO forge/.claude/.beads/harness artifacts (H3 stripped them)"
fi
if printf '%s' "$fout" | grep -qiE 'push|remote|origin'; then note "push:       stopped offline (the fake origin has no reachable remote) — this is where YOUR human merge happens"; fi

say "Demo complete — this all happened in $TMP, which is now removed. Your tree, ledger, and .harness are untouched."
echo ""
echo "   Next, against a REAL target: register it in harness/repos.config (name=/abs/path),"
echo "   author a spec with intake.sh, and run the same start → finish loop — then a human merges the PR."
