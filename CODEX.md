# CODEX.md — OpenAI Codex overrides

> Read `AGENTS.md` first — it is the full operating contract for any agent driving the Forge.
> This file holds only Codex-specific notes.

**The Forge is Claude-Code-first.** Real-time enforcement is built around Claude Code; running the
build loop under Codex is a **weaker, best-effort mode**, not a co-equal enforced path. Because the
real-time hook floor is absent, you carry more of the contract yourself — follow `AGENTS.md` by
discipline, not because a hook will stop you.

- All hard rules and workflow rules in `AGENTS.md` apply unchanged. **No overrides.**
- The hooks in `.claude/` are Claude-Code-specific and do not load under Codex. Your mechanical
  boundary is the **weaker** rest of the floor — the git hooks in `harness/githooks` and the
  fail-closed gates inside the `harness/*.sh` scripts. Do not treat the absent Claude hooks as
  permission; the real-time deny/format/stop enforcement simply is not there under Codex.
- Codex also appears as a **review backend** (`codex` in `harness/reviewers.config`). The reviewer
  is read-only and advisory: it posts findings as a plain PR comment, never a blocking review.
