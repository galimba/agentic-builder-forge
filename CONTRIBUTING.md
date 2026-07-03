# Contributing to agentic-builder-forge

## Welcome

Thank you for your interest in contributing. This project is a template for a
deterministic, enforcement-first agentic build harness. Your contributions improve the
foundation other organizations instantiate. Please read our
[Code of Conduct](CODE_OF_CONDUCT.md) before participating.

## Two Types of Contributions

**a) Contributing to the template repo** — improving the harness for everyone (hardening
the floor, better tests, documentation fixes). This is what this guide covers.

**b) Using the template for your own harness** — cloning and running
`bash .forge/scripts/init.sh` for your organization. That's normal usage, not a
contribution. No PR needed.

## How to Report Bugs

- Use the [Bug Report](.github/ISSUE_TEMPLATE/bug_report.yml) issue template
- Include: OS, shell version, agent platform, steps to reproduce
- Include the output of `bash .forge/scripts/doctor.sh` and, when relevant, the failing
  suite's output from `bash tests/run-all.sh`

## How to Suggest Features

- Open a [Feature Request](.github/ISSUE_TEMPLATE/feature_request.yml) issue before
  submitting a PR for major changes

## How to Submit Changes

1. Fork the repository
2. Create a branch: `feature/description`, `fix/description`, or `docs/description`
3. Make your changes
4. Run the canonical gate locally — it is the sole merge authority:

   ```bash
   bash tests/run-all.sh
   ```

5. Run linters:

   ```bash
   shellcheck --severity=error harness/*.sh .claude/hooks/*.sh .forge/scripts/*.sh
   markdownlint '**/*.md'
   ```

6. Commit using Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`)
7. Push and open a PR against `main`
8. Fill in the [PR template](.github/pull_request_template.md) completely

## Ground Rules for the Enforcement Floor

Changes to `.claude/hooks/`, `.claude/settings.json`, and `harness/` are the project's
most sensitive surface. PRs touching them must:

- Keep every existing test green and add a RED-first test for any new guarantee
- Never weaken a deny rule without an explicit, documented rationale
- Never introduce a committed integrity baseline (the floor self-mints at SessionStart)

## Testing Requirements

Every behavioral change needs a test. New test suites register as a `test:*` script in
`package.json` — the gate discovers them automatically and no suite may sit outside it.
Suites that need an unavailable runtime (docker, bd) must SKIP honestly (exit 75), never
pass vacuously.
