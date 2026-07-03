# CLAUDE.md — agentic-builder-forge

@AGENTS.md

The standing rules above (imported from `AGENTS.md`) are the operating contract. Under Claude Code
they are not advisory: they are enforced by the deterministic hooks in `.claude/hooks/`, wired via
`.claude/settings.json`. A `PreToolUse` hook returning `deny` blocks the tool call even under
`--dangerously-skip-permissions` — that is what makes the floor a floor, not a suggestion. This
repository is **infrastructure** — a build harness — not a documentation or knowledge vault.

- The harness contract is `SPEC.md`.
- How to run a task and the done-condition are in `README.md`; the operating guide is in `docs/`.
- If you keep a sibling knowledge repo (e.g. `../my-vault`), it is **read-only** to the Forge.

## The enforcement floor (Claude Code hooks)

| Hook | Event | What it enforces |
| --- | --- | --- |
| `pre-tool-use-deny.sh` | `PreToolUse` | Hard `deny` for destructive command shapes: `rm -rf` outside the sandbox, force-push, push/commit to `{{DEFAULT_BRANCH}}`, `--no-verify`, secret-shaped literals, raw writes into `.beads/**`, and writes to the enforcement files themselves. |
| `post-tool-use-format.sh` | `PostToolUse` | Auto-formats and lints every `Write`/`Edit`, using the commands in `harness/targets.config`. |
| `stop-gate-tests.sh` | `Stop` | Blocks ending a build turn while `tests/run-all.sh` is red; the failure is fed back into the loop. |
| `stop-gate-intake.sh` | `Stop` | Blocks ending an intake session before the spec has passed the clarify loop and been human-ratified. |
| `pre-tool-use-clarify-gate.sh` | `PreToolUse` | Enforces the intake clarify/restate budgets (`harness/intake.config`) before spec writes. |
| `session-start-witness.sh` | `SessionStart` | **Self-mints** the floor's integrity baseline at session start (no committed hash); tampering after that point is detected. |

The canonical completion gate is `tests/run-all.sh`: it discovers every `test:*` script in
`package.json`, reports PASS / SKIP(75) / FAIL, and fails closed.

## Stop-gate behavior

When a `Stop` gate blocks, the reason it prints **is your next unit of work**. Fix the red tests
(or complete the intake step) and finish again. Never try to end the session by editing
`.claude/hooks/**` or `.claude/settings.json`, weakening a gate, or blanking a `test:*` script —
the deny hook blocks writes to the enforcement files, and gutting a check to go green is the
cardinal failure. If a gate seems genuinely wrong, stop and show the human.

## Customization checklist

1. `harness/targets.config` — build/test/lint/format commands per target type (`typescript`
   default; `python` and `static` examples).
2. `harness/reviewers.config` — review backends (`ollama` | `claude-fresh` | `codex`); shipped
   model names are examples.
3. `harness/repos.config` — copy from `harness/repos.config.example` (gitignored target-repo map).
4. Run `bash .forge/scripts/init.sh`, then `bash .forge/scripts/doctor.sh --post-init`.

Full reference: `docs/configuration.md`.
