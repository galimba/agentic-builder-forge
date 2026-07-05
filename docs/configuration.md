# Configuration

The complete customization surface. Everything an adopter edits lives here; everything
else is mechanism.

## Init-time identity (asked once by `.forge/scripts/init.sh`)

| Value | Placeholder / target | Notes |
|-------|---------------------|-------|
| Repository name | `{{REPO_NAME}}` in docs, `package.json` name | lowercase, URL-safe |
| Organization name | `{{ORG_NAME}}` in docs | display name |
| GitHub org/user | `{{GITHUB_ORG}}` in docs, issue links | |
| Maintainer | `{{MAINTAINER}}` in CODEOWNERS, CoC | user or team |
| Platform | `{{PLATFORM}}` | claude-code / codex / custom |
| Default branch | `{{DEFAULT_BRANCH}}` | the mechanical commit/push guard protects `main`/`master` by name; any other value relies on branch protection + convention |
| Ledger prefix | `BD_PREFIX` in `harness/beads.config` + `bd init -p` | task IDs: `<prefix>-xxxx` |
| Harness git author | `harness/sandbox-lib.sh` | automated commits say "the harness made this" — substituted, not read from git config (the sandbox runs `env -i`) |
| Reviewer backend | `REVIEWER_BACKEND` default in `harness/reviewers.config` | detected: prefers claude-fresh in a Claude Code environment, else ollama |
| Target-repo branch namespace | `FORGE_TARGET_BRANCH_NS` in `harness/branches.config` | target-repo builder branches `<ns>/builder/<id>-<slug>`; default `forge/agent`; trusted by the reconcile close |
| Container network | `FORGE_SANDBOX_NETWORK` (**env-only knob**) | default `bridge` (networked); `none` restores egress-deny. Init prompts + records the choice but does not persist it — export a non-default value in the shell/CI env |
| Container-default for targets | `FORGE_TARGET_CONTAINER` (**env-only knob**) | default `1` (container-default target builds); `0` = host-side. Same env-only handling as above |
| Marker namespace | `forge:` -> `<yours>:` everywhere it is emitted AND parsed | default fine; init renames atomically and verifies count parity |

Init state is recorded in `.forge/.initialized` (gitignored). Re-running init is guarded.

### Non-interactive init (headless / CI)

`init.sh` is interactive by default. Pass `--non-interactive` (or set `FORGE_INIT_NONINTERACTIVE=1`) to run
headless: every value is read from a `FORGE_INIT_<NAME>` env var, and a **required** value with no default
aborts with `exit 2` naming the missing var. Every flag/env value flows through the **same**
`validate_input` / `validate_token` / escape gates as an interactive answer — a flag never bypasses
validation (`init.sh` is an injection-sensitive surface). See `bash .forge/scripts/init.sh --help` for the
full env-var list. Required: `FORGE_INIT_REPO_NAME`, `FORGE_INIT_ORG_NAME`, `FORGE_INIT_GITHUB_ORG`,
`FORGE_INIT_MAINTAINER`; the rest default (platform `claude-code`, branch `main`, prefix `fx`, namespace
`forge/agent`, network `bridge`, container `1`, marker `forge`). The y/N gates default yes
(`FORGE_INIT_UPDATE_REMOTE` / `_SCAFFOLD` / `_RUN_DOCTOR`); `--reinit` (or `FORGE_INIT_REINIT=y`) proceeds
past the already-initialized guard.

## Config files (edit any time)

### `harness/targets.config` — what "build" means

Per-target-type commands, selected by `TARGET` (default `typescript`; `python` and
`static` stanzas show the seam). Swapping languages is a config edit, not a code edit:

```bash
TARGET=python ./harness/run-task.sh start <id>
```

### `harness/repos.config` — where your code lives (gitignored)

`<target-name>=/absolute/path/to/local/clone`, one per line. Host-specific by design;
`repos.config.example` is the committed shape.

### `harness/reviewers.config` — the advisory reviewer

`REVIEWER_BACKEND`: `ollama` (local, free, private) | `claude-fresh` (fresh context,
read-only tools) | `codex` (cross-provider). The model names shipped in each stanza are
**examples** — set them to models you have provisioned. Optional `DISPOSITION_BACKEND`
and `SPEC_REVIEW_BACKEND` select different backends for the finding-adjudication and
spec-review passes (provider diversity reduces correlated blind spots).

The reviewer posts a plain PR comment. It can never block, approve, or request changes —
that is a load-bearing guarantee, not a default.

### `harness/beads.config` — the task ledger

`BD_BIN` (absolute path, pinned by init), `BD_VERSION_PIN`, `BD_PREFIX`, default
priority, review status. The verified command surface for the pinned bd version is
documented in the file itself.

### `harness/intake.config` — intake budgets

`INTAKE_CLARIFY_ROUNDS` (default 5), `INTAKE_RESTATE_ROUNDS` (default 3),
`INTAKE_CLARIFY_MAX_Q` (default 4). Budgets bound agent-initiated QUESTIONS, never spec
coverage — overflow becomes flagged `[ASSUMED …]` entries. All env-overridable.

### `harness/board.config` — optional oversight board (gitignored)

Emitted by `./harness/board-bootstrap.sh ensure` (requires `BOARD_OWNER`). Never edit
by hand; re-run ensure.

## Runtime knobs (environment)

| Variable | Effect |
|----------|--------|
| `FORGE_SANDBOX=1` | run the task inside the isolation container (opt-in; shipped manifest is `--network none` today — workspace isolation, not an airtight sandbox). Mandatory for non-attended builds — the harness refuses without it |
| `FORGE_SANDBOX_IMAGE` | override the sandbox base image (default: a devcontainers javascript-node image) |
| `TARGET=<type>` | select the targets.config stanza |
| `REVIEWER_BACKEND=<b>` | one-shot reviewer backend override |
| `FORGE_GATE_STRICT=1` | any honest SKIP reddens the gate (set on fully-provisioned runners) |
| `FORGE_UNATTENDED=1` | unattended posture: implies strict gate |
| `BD_CLOSED_WINDOW` | days of closed tasks shown in the board Done lane |

## What is NOT configurable (on purpose)

- The enforcement floor's deny rules and self-protection (change = human PR, reviewed)
- The reviewer's advisory-only posture
- The green-gate requirement on finish
- The human ratify step at intake Gate A
