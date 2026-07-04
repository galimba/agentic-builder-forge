# SPEC.md — the harness contract

> This document is the contract of the Forge: the invariants the build harness commits to
> on every run, in every instance stamped from this template. It is not a build plan and
> not a changelog. If a behavior described here and the code ever disagree, the code is
> wrong.

## What the harness is

A deterministic, **Claude-Code-first** enforcement skeleton for agentic building: an agent
takes one task at a time and builds it in isolation under mechanical guardrails, ending in a
pull request that only a human may merge. The guardrails are a fail-closed **floor** — a
deny-by-default tripwire that raises the cost of the dangerous shapes, not an airtight
sandbox — and the human merge is the release boundary. The Forge is an **external** control
repo: it operates on separate target repositories and never embeds itself into them.
Everything larger — the task ledger, the intake loop, the advisory reviewer, the optional
oversight board — is layered on that seed without weakening it.

## Why minimal

The documented failure mode of agentic build systems is multi-agent complexity before
single-agent reliability. The harness therefore commits to the smallest loop in which one
backend can do one task safely and provably, and grows only through configuration — never
by relaxing the loop.

## Design commitments

- **Determinism over prose.** Enforcement lives in hooks and scripts (the floor), not in
  advisory instructions. Prose is context; hooks are the contract.
- **Fail-closed gates.** A gate that cannot evaluate denies. Every enforcement defect
  found so far fails in the closed (safe) direction, and new gates must too.
- **Native enforcement, Claude-Code-first.** The real-time guardrails reuse **Claude Code's**
  own hook points (`PreToolUse` deny, `PostToolUse` format, `Stop` gates, `SessionStart`
  witness), which fire in interactive and headless modes alike. Other agents (e.g. Codex) can
  follow the same workflow bounded by the git hooks and the fail-closed harness scripts, but
  the real-time hook floor is built around Claude Code. Hook syntax moves — re-verify against
  current Claude Code docs when touching the floor.
- **Blast-radius control.** One git worktree per task; optionally an isolation container
  around the build (opt-in today, shipped manifest `--network none`; the Forge is being
  aligned toward networked, container-default target-repo execution as a later topology
  change — see `docs/limitations.md`). The shared checkout is never edited directly.
- **Budgets and limits live in code**, not in prompts (see `harness/intake.config` for
  clarify/restate budgets).
- **Config-driven commands.** Test/lint/format commands are read from per-target config,
  never hardcoded, so retargeting is a config edit.
- **Advisory-only review.** The reviewer is read-only and posts findings as a plain PR
  comment — never a blocking review, never an approval.
- **Human merge authority.** The harness opens PRs; only a human merges.

## The lifecycle

1. **Intake** — `harness/intake.sh`: spec authoring with a clarify loop and a human
   ratification step (the clarify gate blocks skipping it).
2. **Decompose** — the ratified spec becomes beads in the task ledger (`bd`,
   `harness/beads.config`).
3. **Build** — `harness/run-task.sh` claims a bead and builds in an isolated git worktree,
   optionally inside a network-none container sandbox; the tests/lint/format gates enforce
   green throughout.
4. **Finish** — the run ends by opening a pull request. It never merges.
5. **Review** — `harness/review-task.sh`: an advisory read-only reviewer
   (`harness/reviewers.config`) posts findings as a plain PR comment.
6. **Merge** — a human, and only a human.
7. **Reconcile** — the bead is closed from the harness-captured PR record.

A running task can be terminated cleanly at any point with `harness/kill-switch.sh`.

## Invariants

Every instance must be able to demonstrate all of these live:

1. **Isolation.** Starting a task creates a dedicated git worktree + branch; the run
   touches only that worktree. The shared checkout is never modified directly.
2. **Test-first loop.** Given a coding task, the agent writes a failing test, then code,
   until the test passes — visibly red → green.
3. **Format/lint enforcement.** On every file write/edit, the configured formatter+linter
   runs automatically (`PostToolUse`); the agent cannot disable or skip it.
4. **Completion gate.** A run cannot be declared done while tests are red — the `Stop`
   hook blocks completion and feeds the agent back into the loop. The canonical gate is
   `tests/run-all.sh`: it discovers every `test:*` script in `package.json` and emits
   PASS / SKIP(75) / FAIL verdicts, fail-closed.
5. **Destructive-action block.** A deliberately destructive instruction (`rm -rf` a
   protected path, force-push, a write outside the sandbox, a secret-shaped string) is
   denied by the `PreToolUse` hook and does not execute.
6. **PR, not merge.** The loop ends in a pull request. The agent never merges, never
   pushes the default branch, never uses `--no-verify`.
7. **Kill-switch.** A running task terminates cleanly via one documented command, leaving
   no half-applied changes on shared branches.
8. **Config-driven targets.** Pointing the harness at a different language is an edit to
   `harness/targets.config` (`typescript` is the default; a `python` example and a
   `static` target are included), not a code edit.

## The enforcement floor

The floor is `.claude/hooks/*` wired via `.claude/settings.json`: the deny hook, the
format hook, the stop gates (tests, intake), the clarify gate, and the session witness.
Its properties:

- The integrity baseline **self-mints at SessionStart** — there is no committed hash for
  an agent to regenerate or forge.
- Agents never edit the floor, never use `--no-verify`, never push the default branch.
  These rules are enforced by the floor itself, not merely stated.
- Matching is fail-closed: when a rule cannot decide, it denies.

## Config seams

All extension points are config, not code:

| Seam | Purpose |
| --- | --- |
| `harness/targets.config` | Build targets and their test/lint/format commands |
| `harness/reviewers.config` | Review backends (`ollama` \| `claude-fresh` \| `codex`); model names are examples the adopter must provision |
| `harness/beads.config` | Task-ledger settings |
| `harness/repos.config[.example]` | Target repo map (gitignored; instance-specific) |
| `harness/board.config[.example]` | Optional GitHub Projects oversight board, regenerated by `harness/board-bootstrap.sh` |
| `harness/intake.config` | Clarify/restate budgets for intake |

## Out of scope

The harness does not merge, does not modify its own floor, and does not grow into a
meta-orchestration framework, an observability stack, or a RAG system — those live outside
it (for shared context, use a sibling vault, e.g. `../my-vault`). The default posture is
human-supervised; unattended operation exists but is gated behind `FORGE_UNATTENDED` —
gated, not forbidden.

## Adopter verification

After `bash .forge/scripts/init.sh`, verify your instance upholds the contract:

- [ ] `bash .forge/scripts/doctor.sh --post-init` passes.
- [ ] `bash tests/run-all.sh` is green (no FAIL verdicts).
- [ ] A destructive command attempt (e.g. `rm -rf` on a protected path) is denied by the
      floor.
- [ ] Declaring a task done with a red test is blocked by the stop gate.
- [ ] A full run against `sandbox/` (or your own `example-target`) ends in a PR, not a
      merge.
- [ ] `harness/kill-switch.sh` terminates a running task with no residue on shared
      branches.
- [ ] Switching the active target in `harness/targets.config` changes the enforced
      commands without any code edit.

## Residual risks

- The deny layer is pattern-based; false positives are possible (benign commands may be
  blocked). This fails in the safe direction but can obstruct innocent work. Known cases
  and their safe-direction analysis are cataloged in `docs/limitations.md`.
- The harness assumes nothing about platform branch protection. Human-only merge is the
  baseline control; enable branch protection on your hosting platform where available.

## Structure

```
.claude/
├── settings.json                # floor wiring
└── hooks/                       # the enforcement floor
    ├── pre-tool-use-deny.sh         # destructive-action block
    ├── pre-tool-use-clarify-gate.sh # intake clarify enforcement
    ├── post-tool-use-format.sh      # format/lint on edit
    ├── stop-gate-tests.sh           # completion gate
    ├── stop-gate-intake.sh          # intake completion gate
    └── session-start-witness.sh     # self-minted integrity baseline
harness/                         # lifecycle scripts + config seams
tests/run-all.sh                 # canonical fail-closed gate
sandbox/                         # trivial target for proving the loop
.forge/scripts/init.sh           # adopter initialization (then doctor.sh --post-init)
AGENTS.md, CLAUDE.md             # standing agent rules (mirrors of the floor, not substitutes)
SPEC.md                          # this contract
```
