# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Older releases | No |

## Reporting a Vulnerability

- Use GitHub's **Private Vulnerability Reporting** (Security tab → Report a vulnerability)
- Do **not** open public issues for security concerns
- You will receive acknowledgment within 48 hours

## Scope

**Covered:**

- The enforcement floor (`.claude/hooks/`) — the deny hook, stop gates, format hook, session witness
- Harness scripts (`harness/`) — task runner, intake, acceptance gate, sandbox driver, reconcile
- The initialization and doctor scripts (`.forge/scripts/`)
- Template content that could introduce issues when instantiated

**Not covered:**

- Code an adopter's agents produce inside their own instance
- Target repositories the harness builds against
- AI model behavior (that is the model provider's responsibility)

## Security Considerations for Operators

### The enforcement floor is deny-by-default, not a sandbox

- The PreToolUse deny hook classifies commands and file writes textually; the container
  sandbox (mount-layer read-only + `--network none`) is the stronger boundary. Run
  non-attended builds with `FORGE_SANDBOX=1` — the harness refuses otherwise.
- The floor's integrity baseline **self-mints at SessionStart**. There is no committed
  hash: do not add one, and treat any tracked `.harness/session-floor.*.json` as a bug.
- Enforcement files (`.claude/hooks/`, `.claude/settings.json`, `harness/`) are
  deny-listed against agent edits. Changes to them are a human act, on purpose.

### Initialization is an injection-sensitive surface

- `.forge/scripts/init.sh` substitutes operator input into enforcement-adjacent files.
  It validates and escapes every input; run it only from a trusted shell, and review
  `git diff` after initialization.

### Secrets

- The deny hook blocks secret-shaped strings in writes, best-effort. Do not store
  secrets, API keys, or PII in the repository; use environment variables or a secret
  manager. Reviewer backends may send diffs to external model providers — choose the
  local backend (`ollama`) if that is unacceptable.

### Spec intake is adversarial-input territory

- Specs are read by agents. A malicious spec is a prompt-injection vector; the human
  ratify step at Gate A exists for this reason. Read what you ratify.
