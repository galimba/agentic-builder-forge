# {{REPO_NAME}}

> {{ORG_NAME}}'s agentic build harness — initialized {{INIT_DATE}} from the
> [agentic-builder-forge](https://github.com/galimba/agentic-builder-forge) template.

This repository runs a deterministic, enforcement-first build harness: specs go in
through a clarify-gated intake, work is decomposed into a task ledger, agents build in
isolated worktrees behind a deny-by-default floor, tests are the sole merge authority,
and a human ratifies every spec and merges every PR.

## Daily driver commands

```bash
./harness/run-task.sh ready            # what is ready to build
./harness/run-task.sh start <id>       # claim a task, open its worktree (FORGE_SANDBOX=1 for container)
./harness/run-task.sh finish           # green-gated finish -> PR
./harness/intake.sh start "…" --target <repo>   # begin a new spec intake (see docs/lifecycle.md)
./harness/intake.sh ratify             # human sign-off at Gate A (interactive terminal only)
bash tests/run-all.sh                  # the canonical gate
bash .forge/scripts/doctor.sh          # diagnostics
```

## Where things live

| Path                 | What                                                          |
| -------------------- | ------------------------------------------------------------- |
| `specs/`             | Ratified spec packets (intake output)                         |
| `harness/`           | The mechanism: runner, intake, gates, reviewer, sandbox       |
| `.claude/`           | Enforcement floor (hooks) + agent role cards + skills         |
| `harness/*.config`   | The customization surface (targets, reviewers, ledger, repos) |
| `docs/`              | Architecture, lifecycle, operating guide, honest limitations  |
| `docs/onboarding.md` | Start here if you are new                                     |

## House rules

- `{{DEFAULT_BRANCH}}` advances only by PR merge from a task branch — enforced by the
  commit guard, not convention.
- The reviewer is advisory; the test gate decides. Humans merge.
- Enforcement files (`.claude/hooks/`, `harness/`) change only through human-reviewed
  PRs — agents are denied writes there by the floor itself.
- Task IDs look like `{{BEAD_PREFIX}}-xxxx`; the ledger lives in `.beads/` (bd).

## Getting help

See `docs/onboarding.md`, then `docs/operating.md`. Template-level documentation is
preserved in `docs/forge-template-readme.md`.
