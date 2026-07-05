# Getting Started

From zero to a working harness for your organization.

## 1. Prerequisites

| Tool | Needed for | Required? |
|------|-----------|-----------|
| bash, git, jq | everything | yes |
| pnpm + node >= 18.18 | the test gate, TS target tooling | yes |
| [beads (`bd`)](https://github.com/gastownhall/beads) | the task ledger | yes — **load-bearing**; the task lifecycle cannot run without it (the bd-dependent suites SKIP honestly if absent) |
| docker + devcontainer CLI | the per-task isolation container | the default for target builds and required for non-attended runs (attended self-build runs host-side) |
| gh (GitHub CLI) | PR creation + close-on-merge reconcile | for the PR loop |
| ollama **or** claude CLI **or** codex CLI | the advisory reviewer | one of them |

## 2. Clone and initialize

```bash
git clone https://github.com/galimba/agentic-builder-forge.git my-forge
cd my-forge
bash .forge/scripts/init.sh
```

Init collects your identity (repo/org/maintainer), your ledger prefix, the harness git
author, your reviewer backend (it detects a Claude Code environment and prefers it;
otherwise defaults to the locally-runnable `ollama`), and optionally a custom marker
namespace. It fills every placeholder, creates a **fresh, empty** task ledger with its
own new project identity, wires `core.hooksPath`, and renders your instance README and
onboarding docs.

Two things init deliberately does NOT do:

- **No floor baseline.** The enforcement floor's integrity hash self-mints at your
  first agent session. There is nothing to copy — a committed baseline would be a bug.
- **No ledger import.** A ledger carries a project identity and task history; it is
  never copied between instances.

## 3. Verify

```bash
bash .forge/scripts/doctor.sh --post-init   # placeholders filled, ledger empty+valid, wiring OK, bd+gh present
#   add --container to also require docker + devcontainer (container-proof mode)
bash tests/run-all.sh                       # the canonical gate: PASS everywhere, SKIP only where a runtime is absent
```

`doctor --post-init` now fails if `bd` or `gh` is missing (they are load-bearing for the task lifecycle
and the PR flow); Node/pnpm and the container toolchain warn but do not fail (add `--container` to make the
container toolchain required).

Then watch the whole governed loop run — offline, in seconds — against a **throwaway** target the
demo synthesizes and deletes (nothing touches your tree, ledger, or `.harness`):

```bash
bash .forge/scripts/demo.sh
```

It mints an architect-shaped bead, runs `start` (worktree + a `forge/agent/builder` branch in the
target), writes the product, and runs `finish` (the target test + the no-LLM acceptance gate + a
pristine commit) — the same loop steps 4–5 walk you through against your real code. The final push
stops offline by design: that is exactly where your human merge happens. It needs only `git`, `bd`,
and `jq` (the throwaway is a `static` target, so no Node/pnpm), and runs it in a terminal.

## 4. Point it at your code

```bash
$EDITOR harness/repos.config     # <target-name>=/absolute/path/to/local/clone
$EDITOR harness/targets.config   # test/lint/format commands per target type
```

## 5. Run the loop

```bash
./harness/intake.sh start "My first objective" --target <your-target>   # the name you registered in step 4; then: clarify, spec-review, ratify, (agent authors the breakdown), ratify-breakdown, analyze, convert
./harness/run-task.sh ready                          # see what the decompose minted
./harness/run-task.sh start <id>                     # build in an isolated worktree
./harness/run-task.sh finish                         # green-gated PR
```

`--target` must name a repo you registered in `harness/repos.config` (step 4) — intake fail-closes
on an unknown name. Study `specs/001-example/` — a complete worked spec packet (its `example-target`
is illustrative; register your own before running) — before your first real intake. Then read
[operating.md](operating.md) and [limitations.md](limitations.md).

## Optional: the oversight board

A read-only GitHub Projects board mirroring the ledger:

```bash
BOARD_OWNER=<your-org> ./harness/board-bootstrap.sh ensure
./harness/board-sync.sh
```

The emitted `harness/board.config` is gitignored (it holds your project's node IDs);
`harness/board.config.example` shows the shape.
