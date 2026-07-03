# Onboarding — {{REPO_NAME}}

Welcome to {{ORG_NAME}}'s build harness. This guide gets you productive in ~15 minutes.

## 1. What this repo is

A supervised loop that turns ratified specs into merged PRs:

```
intake (clarify + human ratify) -> decompose -> ledger (beads)
   -> run-task (isolated worktree, optional container sandbox)
   -> tests/lint/format gates (deterministic, fail-closed)
   -> finish -> PR + advisory review -> HUMAN merges -> reconcile closes the task
```

Three properties make it trustworthy:

1. **The floor.** Agent sessions run behind deny-by-default hooks (`.claude/hooks/`).
   Agents cannot edit enforcement files, rewrite git history, bypass gates, or push to
   `{{DEFAULT_BRANCH}}`. The floor witnesses its own integrity at session start.
2. **Deterministic gates.** `bash tests/run-all.sh` is the sole merge authority. The
   reviewer only comments; it can never block or approve.
3. **Human authority.** You ratify specs (`intake.sh ratify`) and you merge PRs. The
   harness refuses to do either for you.

## 2. Setup on your machine

```bash
git clone <this-repo> && cd {{REPO_NAME}}
git config core.hooksPath harness/githooks   # commit guard (init already did this for the initializer)
cp harness/repos.config.example harness/repos.config   # if missing
$EDITOR harness/repos.config                 # absolute paths to YOUR target clones
bash .forge/scripts/doctor.sh                # verify wiring
bash tests/run-all.sh                        # everything green/SKIP?
```

Prerequisites: bash, git, jq, pnpm (node >= 18.18), bd (beads), and optionally
docker + the devcontainer CLI for the container sandbox, gh for PR flow.

## 3. Your first task

```bash
./harness/run-task.sh ready        # pick a ready task id ({{BEAD_PREFIX}}-…)
./harness/run-task.sh start {{BEAD_PREFIX}}-xxxx
# ... agent (or you) works in the printed worktree ...
./harness/run-task.sh finish       # only exits green; opens the PR
```

If anything wedges: `./harness/kill-switch.sh {{BEAD_PREFIX}}-xxxx` releases the claim
and tears down the worktree/sandbox safely.

## 4. Your first intake

```bash
./harness/intake.sh start "Short imperative objective" --target <repo>
# answer the clarify questions (budgeted; overflow becomes flagged assumptions)
./harness/intake.sh spec-review       # capture the adversarial spec-review verdict
./harness/intake.sh ratify            # read it, then sign — the human floor (Gate A)
# the agent now authors the Task Breakdown block into the spec (the 'decompose' skill — no CLI step)
./harness/intake.sh ratify-breakdown  # human sign-off on the breakdown (Gate A')
./harness/intake.sh analyze           # mechanical Gate B (nine invariants)
./harness/intake.sh convert           # mint ledger tasks
```

The full pipeline with per-step detail is in `docs/lifecycle.md` (Pipeline 1).
See `specs/001-example/` for what a finished spec packet looks like.

## 5. Read next

- `docs/operating.md` — running the loop day to day
- `docs/limitations.md` — what the harness honestly does NOT guarantee
- `CLAUDE.md` / `AGENTS.md` — the contract your agents operate under
