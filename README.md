# agentic-builder-forge

A deterministic, **Claude-Code-first** control plane for agentic software development. Clone it, run one init script, and get a working **external governance harness** for **your** org: an AI coding agent takes one task at a time through a test-first loop in an isolated git worktree — working against a **separate target repository, never embedding into it** — bounded by mechanical guardrails, and ending by opening a pull request that **a human reviews and merges**.

[![CI](https://github.com/galimba/agentic-builder-forge/actions/workflows/ci.yml/badge.svg)](https://github.com/galimba/agentic-builder-forge/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Use this template](https://img.shields.io/badge/Use%20this-template-2ea44f?logo=github)](https://github.com/galimba/agentic-builder-forge/generate)

## What Is This

The Forge runs *governed autonomy*. The agent does the implementation work and a second agent reviews it, but the boundary around them is deterministic — an enforcement layer (**the floor**) made of deny-by-default hooks that don't depend on a model's judgment and fail *closed*. The decision to ship is always a human's: the harness opens and reviews pull requests; it never merges them. That split — autonomous build, human-gated release — is the control loop the whole workflow is built around.

The Forge is **Claude-Code-first**: its real-time enforcement — the `PreToolUse` / `PostToolUse` / `Stop` / `SessionStart` hooks — is built around Claude Code. Other agents (e.g. Codex) can follow the same workflow in a weaker sense, bounded by the git hooks and the fail-closed harness scripts, but they do **not** get the real-time hook floor. It is a control repo that stays **external** to the code it builds — it operates on separate target repositories and never embeds itself into them.

For one unit of work, the harness:

1. **Intake** — turns a fuzzy objective into a spec through a bounded clarify loop, which a **human ratifies**, then decomposes it into **beads** (the task ledger, `bd` — the single source of truth).
2. **Build** — `run-task.sh` claims a bead, creates an isolated worktree on a task branch (inside a networked isolation container by default for target builds; see [The Honest Boundary](#the-honest-boundary)), and drives a test-first loop.
3. **Gate** — auto-format and lint on every write; a Stop gate that refuses "done" while tests are red. The canonical gate is `tests/run-all.sh`.
4. **Finish** — commits, pushes the task branch, opens a **pull request**. Never merges, never pushes the default branch.
5. **Review** — a read-only, structurally separated reviewer posts **advisory** findings as a plain PR comment — never a blocking review.
6. **Merge & reconcile** — a **human merges**; `run-task.sh sync` closes the bead from the harness-captured PR record.

A one-command kill switch (`harness/kill-switch.sh`) aborts any run cleanly.

## Quick Start

```bash
# 1. Create your forge from the template
git clone https://github.com/galimba/agentic-builder-forge.git my-forge
cd my-forge

# 2. Initialize for your org — collects your values (repo, org, maintainer,
#    bead prefix, ...), fills placeholders, creates a FRESH empty bead ledger,
#    installs the git-level guards, and renders your instance docs
bash .forge/scripts/init.sh

# 3. Verify the install
bash .forge/scripts/doctor.sh --post-init

# 4. Prove the gate is green (discovers and runs every test suite)
bash tests/run-all.sh

# 5. Watch the whole governed loop run end-to-end — offline, in seconds — against a
#    THROWAWAY target the demo synthesizes and deletes. Nothing touches your tree or ledger:
#    architect-shaped bead → start (worktree + branch in the target) → the agent's product
#    write → finish (target test + the no-LLM acceptance gate + a pristine commit).
bash .forge/scripts/demo.sh

# 6. Now do it for real. First register your target, then author its spec through intake.
$EDITOR harness/repos.config                 # <your-target>=/absolute/path/to/local/clone
./harness/intake.sh start "add a greet(name) function returning 'Hello, <name>!'" --target <your-target>
#    ... clarify → spec-review → ratify (you, at a TTY) → decompose → ratify-breakdown → analyze → convert
#    ... study specs/001-example/ (a complete worked packet) before your first real intake
./harness/run-task.sh ready                 # the beads intake minted
./harness/run-task.sh start <bead-id>       # agent works test-first in the worktree it prints
./harness/run-task.sh finish                # green tests required; opens a PR — never merges
#    ... you review and merge the PR on your platform ...
./harness/run-task.sh sync                  # closes the bead from the merged PR record
```

New here? Start with [`docs/getting-started.md`](docs/getting-started.md), which walks the same path in full.

> **Advanced / ad-hoc:** `run-task.sh start --new "<desc>"` mints a one-off bead directly, skipping
> intake. It is a convenience for a quick single task, **not** the normal path: such a bead carries no
> acceptance contract (`scope` / `dod_tests` / `sc_evidence`), so it only passes the acceptance gate
> under the audited `FORGE_MECHGATE_ALLOW_LEGACY=1` allowance. In the normal flow, **beads are
> architect-generated from a ratified spec** — humans act at intake approval and at the final merge.

## Features

- **Deterministic enforcement floor** — `PreToolUse` deny hook blocks a fixed set of destructive command shapes (out-of-sandbox `rm -rf`, force-push, push/commit to the default branch, `--no-verify`, secret-shaped literals, self-edits of the enforcement files). Broken or unparseable hooks deny; they never wave work through.
- **Test-gated completion** — the Stop gate blocks "done" on red tests; `tests/run-all.sh` is the canonical verdict (PASS / SKIP / FAIL, fail-closed).
- **Isolated execution** — every task runs in its own git worktree on its own branch; target-repo builds run inside a **networked** isolation container by default (unattended runs require `FORGE_SANDBOX=1`; attended self-build stays host-side) with read-only mounts of the enforcement files. Set `FORGE_SANDBOX_NETWORK=none` to restrict egress.
- **Ledger-driven work** — every unit of work is a bead; the human merge is what closes it, reconciled mechanically from the PR record.
- **Human-ratified intake** — a clarify loop with mechanical depth/coverage floors turns objectives into specs a human signs off on before any bead is minted.
- **Advisory review, pluggable backends** — the reviewer runs read-only against the PR diff and posts findings as a comment; backends: local `ollama`, a fresh `claude` CLI session, or `codex`.
- **Session witness** — at `SessionStart` the floor self-mints its integrity baseline (no committed hash), so privileged operations can prove the real hooks are loaded.
- **Optional oversight board** — a read-only GitHub Projects board projecting ledger state for human supervision (`harness/board-bootstrap.sh`).
- **Kill switch** — one command removes the worktree, branch, and sentinel, and releases the bead back to ready.

## Prerequisites

| Tool | Needed for | Notes |
| --- | --- | --- |
| `bash`, `git`, `jq` | everything | the hooks fail closed without `jq` |
| Node.js ≥ 18.18 + `pnpm` | the default TypeScript build target and the harness's own test suites | |
| Beads (`bd`) | the task ledger | **load-bearing** — the task lifecycle cannot run without it; the bd-dependent suites SKIP honestly if absent. Installed separately; `init.sh` pins the binary path and version. |
| GitHub CLI (`gh`) | the PR flow and the optional oversight board | authenticated |
| A reviewer backend | advisory PR review | one of: `ollama` with a pulled model, the `claude` CLI, or the `codex` CLI — model names in `harness/reviewers.config` are **examples you must provision** |
| Docker + devcontainer CLI | *for container builds* | the isolation container is the default for target builds and required for unattended runs (attended self-build runs host-side) |

## What's Included

```
.forge/scripts/       init.sh (adopt the template), doctor.sh (post-init health check)
.claude/              The enforcement floor: hooks + settings.json wiring
  hooks/              deny hook, format hook, stop gates, clarify gate, session witness
harness/              The build harness
  run-task.sh         start / finish / ready / sync — the per-task loop
  intake.sh           spec authoring: clarify loop + human ratify + bead decomposition
  review-task.sh      the advisory PR reviewer
  kill-switch.sh      abort any run cleanly
  reaper.sh           stale-run cleanup
  githooks/           git-level guards (installed via core.hooksPath at init)
  *.config            the customization seams (see below)
docs/                 Documentation (see docs/README.md)
templates/            Spec and document templates used by intake
tests/                The harness's own test suites + run-all.sh (the canonical gate)
AGENTS.md             Standing rules for any agent working in the repo
```

## Opinionated, but Customizable

The defaults encode one working shape of the harness; every seam you're meant to touch is a config file, documented in [`docs/configuration.md`](docs/configuration.md):

- **`harness/targets.config`** — build targets: `typescript` (default), a `python` example, and `static`.
- **`harness/reviewers.config`** — reviewer backend (`ollama` | `claude-fresh` | `codex`) and model.
- **`harness/beads.config`** — the task ledger (prefix, binary pin).
- **`harness/repos.config.example`** — map of target repos the harness may build against (copy to `repos.config`, which is gitignored).
- **`harness/board.config.example`** — the optional GitHub Projects oversight board (regenerated by `board-bootstrap.sh`).
- **`harness/intake.config`** — clarify/restate budgets for the intake loop.

## The Honest Boundary

The floor is deny-by-default hooks plus a self-minting session witness — it deterministically blocks the enumerated dangerous shapes, but it is a **guardrail / tripwire**, not complete confinement: a textual classifier of tool calls, **not an airtight sandbox against a determined adversary**. The isolation container raises the blast-radius floor (workspace / filesystem / process isolation), but it is **not airtight either** — even a networked container would not by itself prevent credential misuse, GitHub-authority misuse, exfiltration, or target-repo mutation. The one always-present release boundary is the **human merge**. The reviewer is **optional and advisory by design** — its findings never gate a merge. The test gate is the sole mechanical completion authority: no run reaches a PR while tests are red. And humans hold both ends of the loop — a human ratifies every spec at intake, and a human merges every PR. Read [`docs/limitations.md`](docs/limitations.md) before relying on the Forge for anything security-sensitive; it enumerates what is mechanically enforced, what is best-effort, and what is convention.

**Container model.** Target-repo builds run in a **networked isolation container by default**
(`FORGE_TARGET_CONTAINER=1`; the legacy `FORGE_TARGET_REQUIRE_CONTAINER=1` is honored). Unattended runs
require it (`FORGE_SANDBOX=1`); an attended **self-build / Forge-maintenance** runs host-side — a
documented high-trust exception. The container is **workspace isolation, not egress control**: it is
networked (`FORGE_SANDBOX_NETWORK=bridge`; set `none` to restore egress-deny), so it bounds
filesystem/process blast radius but does **not** prevent network exfiltration — what it enforces is the
read-only enforcement mounts, dropped caps, and an unprivileged user.

## Documentation

| Document | Covers |
| --- | --- |
| [`docs/getting-started.md`](docs/getting-started.md) | From clone to first merged PR. |
| [`docs/architecture.md`](docs/architecture.md) | Every component, the enforcement tier stack, the floor identity and witness. |
| [`docs/lifecycle.md`](docs/lifecycle.md) | The end-to-end flow — intake and build, and who acts at each stage. |
| [`docs/operating.md`](docs/operating.md) | Env/config controls, runtime records, the audited escape doors, the board. |
| [`docs/development.md`](docs/development.md) | How the harness itself is changed safely. |
| [`docs/configuration.md`](docs/configuration.md) | Every config seam, field by field. |
| [`docs/limitations.md`](docs/limitations.md) | The complete honest boundary, every known limitation, tagged. |

`init.sh` also renders an onboarding doc into `docs/` with your instance's own values.

## License

[Apache License 2.0](LICENSE)
