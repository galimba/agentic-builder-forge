# CODEX.md — OpenAI Codex overrides

> Read `AGENTS.md` first — it is the full operating contract for any agent driving the Forge.
> This file holds only Codex-specific notes.

- All hard rules and workflow rules in `AGENTS.md` apply unchanged. **No overrides.**
- The hooks in `.claude/` are Claude-Code-specific and do not load under Codex. Your mechanical
  boundary is the rest of the floor — the git hooks in `harness/githooks` and the fail-closed
  gates inside the `harness/*.sh` scripts. Do not treat the absent Claude hooks as permission.
- Codex also appears as a **review backend** (`codex` in `harness/reviewers.config`). The reviewer
  is read-only and advisory: it posts findings as a plain PR comment, never a blocking review.
