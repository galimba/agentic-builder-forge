# Agent operating rules — agentic-builder-forge

This repository is **the Forge**: a deterministic build harness for an agentic
software-development lifecycle. These rules are stated here for humans and agents, but prose is
not the boundary — they are enforced **mechanically** by the enforcement floor: the git hooks in
`harness/githooks`, the fail-closed gates inside the `harness/*.sh` scripts, and (when the build
agent is Claude Code) the hooks in `.claude/`. This file is the platform-neutral contract.
Claude Code specifics live in `CLAUDE.md`; Codex notes live in `CODEX.md`.

## Hard rules (never violate)

- **Never push to the default branch (`{{DEFAULT_BRANCH}}`).** Open a pull request from a task
  branch; a human reviews and merges. Agents never merge.
- **Never use `--no-verify`** on `git commit` or `git push`.
- **Never edit the enforcement floor to make a task pass** — `.claude/hooks/**`,
  `.claude/settings.json`, `harness/githooks/**`, or the gates in `harness/**`. Disabling your own
  guardrails is the cardinal failure. Gutting a `test:*` script to go green counts.
- **If you keep a sibling knowledge repo (e.g. `../my-vault`), it is read-only to the Forge.**
  Never write to or commit anything there.
- **The `.beads/` ledger is bd-managed.** Never hand-edit it — mutate the ledger only through
  `bd`. Raw writes and shell redirects into `.beads/**` are denied; `bd` commands and *reads* of
  the ledger are allowed.
- **Stay in the sandbox.** During a task run, write only inside the task's worktree (and
  `sandbox/` in this repo). Runs may execute inside a network-none container sandbox — do not try
  to reach the network from inside it.
- **No destructive commands:** no `rm -rf` outside the sandbox, no force-push, no writes to
  `.git/`.
- **No secrets** in code or shell commands (API keys, tokens, private keys).

## How work flows

- Upstream of the build loop, **intake** (`harness/intake.sh`) turns a fuzzy objective into a
  ratified spec: a clarify loop within the budgets in `harness/intake.config`, then an explicit
  **human ratify**, then decomposition into beads. No beads are minted from an unratified spec.
- **Work is a bead.** Bead IDs carry your ledger prefix (`{{BEAD_PREFIX}}`; examples in these docs
  use `fx`, e.g. `fx-123`). Claim a *ready* bead before starting
  (`./harness/run-task.sh start <bead-id>` — fails closed if it's missing, not ready, or already
  claimed; `start --new "<desc>"` is the only create path).
- One task → one git **worktree + branch**. The shared checkout is never modified directly.
- **Test-first:** write a failing test, then code, until green. The canonical gate is
  `tests/run-all.sh` — it discovers every `test:*` script in `package.json`, reports
  PASS / SKIP(75) / FAIL, and fails closed. You cannot declare a task done while tests are red.
- Every file write/edit is **auto-formatted and linted**. You cannot skip it.
- A run ends by **opening a pull request** — never by merging. `finish` sets the bead `in_review`
  and opens the PR.
- An **advisory, read-only reviewer** (`harness/review-task.sh`) posts findings as a plain PR
  comment — never a blocking review, and its findings never gate the merge. The deterministic test
  gate stays the completion authority.
- The **human merge** closes the bead: `run-task.sh sync` reconciles it to `closed` from the
  harness-captured PR record. Never `bd close` by hand. `kill-switch.sh` aborts a run and releases
  the claim back to ready.
- Test/lint/format commands come from `harness/targets.config` — never hardcode them.

## Scope

- This repository is the harness, not the product it builds. One concern per commit.
- If something blocks unexpectedly, **stop and show the human** — never weaken a rule, a gate, or
  a test to make a check pass.

## Customization checklist

1. `harness/targets.config` — build/test/lint/format commands per target type (`typescript` is
   the default; `python` and `static` are examples).
2. `harness/reviewers.config` — review backends (`ollama` | `claude-fresh` | `codex`). The model
   names shipped are examples; provision your own.
3. `harness/repos.config` — copy from `harness/repos.config.example`; maps the target repos the
   Forge builds. Gitignored.
4. Optional: `harness/board.config` for the read-only oversight board — do NOT copy the
   `.example` (its node IDs are placeholders); generate the live file with
   `BOARD_OWNER=<org> ./harness/board-bootstrap.sh ensure`. `harness/intake.config` tunes the
   clarify/restate budgets.
5. Run `bash .forge/scripts/init.sh` to fill the `{{…}}` placeholders, create a fresh bead ledger,
   and wire the git hooks. Verify with `bash .forge/scripts/doctor.sh --post-init`.

Full reference: `docs/configuration.md`.
