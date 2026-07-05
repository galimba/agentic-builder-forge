# Architecture

How the Forge is composed: the enforcement tiers, where each component lives, and the two facts that
define its identity — the **floor hash** and the **session witness**. This is the current-state map.
For how work *moves* through these parts, see
[`lifecycle.md`](lifecycle.md); for the honest reach of each guarantee, see
[`limitations.md`](limitations.md).

## The shape in one sentence

A build agent runs inside a git worktree; every tool call it makes is screened by a deterministic
`PreToolUse` deny hook; completion is gated on green tests; the run ends at a pull request that a
human merges; and the merge — reconciled mechanically — closes the bead. Everything the agent is
*allowed* to do is bounded by mechanical gates it cannot reason past; everything it is *asked* to do
is a bead.

## The enforcement tiers

The Forge stacks several independent layers. Each is deterministic and fails closed. No single layer
is claimed to be complete; they overlap deliberately, and the honest gaps between them are the
subject of [`limitations.md`](limitations.md).

| # | Tier | Where | What it enforces | Reach |
| --- | --- | --- | --- | --- |
| 1 | `permissions.deny` (project + machine-local user scope) | `.claude/settings.json:63-79`; `~/.claude/settings.json` | A redundant coarse allow/deny on `Edit`/`Write`/a few `Bash` globs. | Secondary. Skipped under `--dangerously-skip-permissions`; `Edit`/`Write` forms only. |
| 2 | **`PreToolUse` deny hook** | `.claude/hooks/pre-tool-use-deny.sh` + `.claude/hooks/lib.sh` | The primary boundary: destructive commands, out-of-sandbox writes, self-edits of enforcement files, push/commit to `main`, `--no-verify`, secret-shaped literals, `.git`/`.beads` raw writes, agent `bd close`. Returns a hard `deny` that survives bypass **when the hook is loaded**. | Best-effort textual classifier of the command string; fails closed; concedes obfuscation to tiers 5–6. |
| 3 | `PostToolUse` format + lint | `.claude/hooks/post-tool-use-format.sh` | Formats and lints files the agent writes **under `sandbox/`**; blocks on lint failure. | `Write`/`Edit`/`MultiEdit` to sandbox paths only. Not Bash redirects, not NotebookEdit, not non-sandbox files. |
| 4 | `Stop` gates | `.claude/hooks/stop-gate-tests.sh`, `.claude/hooks/stop-gate-intake.sh` | Blocks "done": tests-green for a build task; clarify/coverage/Gate-A floor for an intake. | Unattended tests-gate never releases; attended releases after a cap (see below). |
| 5 | Git pre-commit guard | `harness/githooks/pre-commit` | Blocks a commit on `main`/`master` for **every actor and every invocation vector** (agent, human, `eval`, `-c`, pipe). | Fires at git-exec time; independent of the deny hook. Install is verified by the witness. |
| 6 | OS isolation container | `harness/sandbox/devcontainer.json`, `harness/sandbox-lib.sh` | Workspace/filesystem/process isolation: read-only mounts of the enforcement files, **networked by default** (`FORGE_SANDBOX_NETWORK=bridge`; `none` restores egress-deny), dropped caps, unprivileged user. Isolation, **not** an airtight sandbox and **not** egress control. | **Default for target builds** (`FORGE_TARGET_CONTAINER=1`); mandatory for unattended runs (`FORGE_SANDBOX=1`); attended self-build runs host-side (a documented maintenance exception). |
| 7 | `SessionStart` witness | `.claude/hooks/session-start-witness.sh` | Hash-pins the enforcement floor for the session; privileged ops refuse if the floor isn't proven loaded and unchanged. | Gates `finish` and `convert`. Hard under unattended; conditional attended. |
| 8 | Human merge | GitHub | The release decision and the ultimate backstop for everything tiers 2–6 concede. | Convention for the build agent (no branch protection); the reviewer role is mechanically merge-incapable. |

The layered picture: tier 2 is what stops the agent in real time (a Claude-Code-first guardrail /
tripwire) and is the one that survives `--dangerously-skip-permissions`; tiers 5–7 make specific
classes mechanical regardless of vector; tier 6 raises blast-radius isolation *when it is on* (it is
isolation, not an airtight sandbox); tier 8 — the human merge — is the always-present **release
boundary**. No tier is complete confinement, and none is claimed to be.

## Component map

Core = load-bearing enforcement or orchestration. Support = scaffolding, config, history.

### Enforcement hooks — `.claude/hooks/` (core)

| File | Lines | Role |
| --- | --- | --- |
| `lib.sh` | ~2352 | **The floor.** Every command classifier: the deny/block emitters (`forge_deny`, `forge_block`), the shared enforce-path classifier (`forge_enforce_class`), the rm / write / redirect / mutator / push / commit / git-mutator / bd-close walkers, the env-prefix launch classifier, and the floor-hash + witness machinery. |
| `pre-tool-use-deny.sh` | ~317 | The `PreToolUse` deny orchestrator. Fail-closed keystone (missing/partial `lib.sh` → deny + exit 2; missing `jq` → exit 2). Three tiers: universal, task-scoped (a build sentinel exists), intake-scoped (an intake sentinel exists). |
| `pre-tool-use-clarify-gate.sh` | ~61 | `PreToolUse` on `AskUserQuestion`, intake only. Bounds the clarify question loop (autonomous never-ask, per-call cap, ask↔record coupling, round budget). Self-described as a real-time enhancement, *never* the load-bearing guarantee. |
| `post-tool-use-format.sh` | ~41 | `PostToolUse`. Formats + lints sandbox-path writes using the target's configured commands; blocks on lint failure. |
| `stop-gate-tests.sh` | ~78 | `Stop`. Blocks completion while tests are red. |
| `stop-gate-intake.sh` | ~221 | `Stop`. The intake depth/coverage/Gate-A floor. |
| `session-start-witness.sh` | ~87 | `SessionStart`. Mints the per-session floor witness. |

### Harness / orchestration — `harness/` (core unless noted)

| File | Lines | Role |
| --- | --- | --- |
| `run-task.sh` | ~633 | The build-loop driver. Subcommands `start`, `finish`, `status`, `ready`, `board`, `sync`. Owns claim, worktree creation, self-vs-target classification, the finish chain, and reconcile. |
| `beads-lib.sh` | ~425 | `bd` wrappers and the **reconcile close oracle** — closes a bead only when GitHub vouches the PR merged and the id-bound head-ref check passes. Writes and consumes the per-bead PR record. |
| `accept-gate.sh` | ~694 | The deterministic per-bead acceptance gate: diff ⊆ scope, DoD tests pass, success-criteria evidence present. No LLM in the verdict path. A *quality* gate, not a deny boundary. |
| `intake.sh` | ~1065 | The spec→beads pipeline: `start`, `clarify`, `abort`, `ratify`, `ratify-breakdown`, `analyze`, `convert`, `risk`, `spec-review`. Owns the two human ratify gates and the mechanical Gate B. |
| `sandbox-lib.sh` | ~387 | The confinement-container driver (`forge_sandbox_up/down/exec`, EROFS liveness probe) **and** the finish-path safe-git helpers (plumbing commit/push, push-URL allowlist, target-purity strip/assert). |
| `review-task.sh` | ~524 | Dispatches the advisory reviewer and the disposition adjudicator; writes the review/disposition records; posts PR comments. Never gates. |
| `kill-switch.sh` | ~98 | Aborts a run: removes worktree/branch/sentinel, releases the bead, tears the container down, deletes the PR record. |
| `reaper.sh` | ~219 | Sweeps stale confinement **containers** (containers only — not worktrees). Dry-run by default. Support. |
| `board-sync.sh` / `board-bootstrap.sh` | ~199 / ~116 | The one-way, read-only GitHub Project oversight board. Support. |
| `githooks/pre-commit` | ~48 | The all-actors commit-on-`main` guard (tier 5). |
| `targets.config` | — | Per-target `TEST_CMD`/`LINT_CMD`/`FORMAT_CMD`/`SANDBOX_GLOB`. Ships `typescript` (default), `python`, `static`. The commands are read from here, never hardcoded in the hooks. |
| `beads.config`, `reviewers.config`, `intake.config`, `intake-categories.json`, `repos.config(.example)`, `board.config(.example)` | — | Config for `bd`, review backends, intake budgets, the 142-category coverage enum, the target-name→path map, and the board manifest. |
| `sandbox/devcontainer.json` | — | The container manifest: read-only enforcement mounts, networked by default (`FORGE_SANDBOX_NETWORK`; `none` to restrict), `--cap-drop=ALL`, unprivileged user. |

### Roles, skills, data, tests, docs

- **`.claude/agents/*.md`** (support): `architect`, `builder`, `reviewer`, `disposition`,
  `spec-reviewer`. Each documents a role and sets a tool ceiling, and each states the same rule:
  *the hooks are the boundary, not this prose.* See [`development.md`](development.md#roles).
- **`.claude/skills/`** (support): `clarify`, `decompose`, `spec-authoring` — the intake agent's
  playbooks. The mechanical floors live in the hooks; these are agent judgment inside those floors.
- **`.beads/`** (core data): the `bd` ledger (Dolt embedded backend). `issues.jsonl` (tracked,
  auto-exported) and `interactions.jsonl` (tracked audit trail) are bd-managed; raw writes are
  denied, `bd` verbs and reads pass.
- **`.harness/`** (core runtime state, untracked): sentinels, session-floor witnesses, and the
  `pr/` `assembly/` `acceptance/` `review/` `disposition/` records plus the three escape-door audit
  logs. Schemas in [`operating.md`](operating.md#runtime-records).
- **`tests/`** (core proof): the suites auto-discovered by `tests/run-all.sh`, including the
  `fold10`–`fold30` boundary canaries. See [`development.md`](development.md#the-proof-model).
- **`docs/`, `SPEC.md`, `sandbox/`, `specs/`**: `SPEC.md` is the frozen bootstrap contract the
  harness skeleton was built to satisfy (see [`docs/README.md`](README.md) for the doc index);
  `sandbox/` is the self-build work root (empty between runs); `specs/` holds intake artifacts.

## The floor identity

The "floor" is the set of files whose bytes define the enforcement behavior. It has a single
canonical fingerprint, computed by `forge_floor_hash` (`.claude/hooks/lib.sh:2156-2179`) over five
inputs in a fixed order:

1. `.claude/hooks/pre-tool-use-deny.sh` (bytes)
2. `.claude/hooks/lib.sh` (bytes)
3. `.claude/hooks/session-start-witness.sh` (bytes)
4. the `jq -cS`-normalized `hooks.PreToolUse` stanza of `.claude/settings.json`
5. the `jq -cS`-normalized `hooks.SessionStart` stanza of the same file

It fails closed: any input missing/unreadable, either stanza absent, or `jq` unavailable → no output.
Whitespace and key-order changes in `settings.json` do not move the hash (the stanzas are normalized),
but array order is preserved because hook order is semantically load-bearing.

The value is instance-specific and deliberately **not committed anywhere**: the baseline self-mints
at `SessionStart`, when the witness records the hash of the floor actually loaded (see below). To
see the current value on your checkout, read the newest `.harness/session-floor.<session-id>.json`.

Note what is **not** a floor input: `settings.local.json` (protected but not hashed), and
`harness/targets.config` (protected but not hashed). A change to those does not move the floor and
does not require re-certification. `harness/**` files *other than* the pre-commit hook are protected
from agent edits but are likewise not part of the floor-hash recipe — they are verified by their own
tests, not by the witness.

## The session witness

The witness makes "the real hooks are loaded in *this* session" mechanically provable, closing the
off-root launch hole (a session started where `.claude/` isn't discovered loads no hooks).

- **Mint:** on `SessionStart`, `session-start-witness.sh` computes the floor hash and writes
  `.harness/session-floor.<session-id>.json` (`{session_id, source, cwd, actor, ts, floor_hash}`).
  It is **never a gate** — it exits 0 on every path. It *refuses to mint* (leaving no witness) when
  the git pre-commit guard isn't actually installed and executable, or when `settings.local.json`
  defines its own `PreToolUse` hooks. Absence of a witness is what gates later — never SessionStart.
- **Verify:** the two privileged operations — `run-task.sh finish` and `intake.sh convert` —
  recompute the floor hash live and compare it to this session's witness. Under `FORGE_UNATTENDED=1`
  a mismatch or missing witness is a **hard** refusal. Attended, it is a hard refusal on a clean,
  previously-witnessed checkout, and a warn-and-proceed only when the floor is under a human's active
  uncommitted edit or the checkout was never witnessed (a fresh clone).

This is why a floor-moving change is *self-healing*: editing any of the five inputs invalidates every
existing witness, and the next `SessionStart` re-mints the new hash. It is also why the floor hash is
the anchor of the re-certification discipline (see [`development.md`](development.md#re-certifying-a-floor-move)).

## Design principle: argv-classify, container-defer

The deny hook's design rule (stated and re-stated throughout `lib.sh`) explains
its shape and its limits in one line: **classify write targets that are identifiable from the argv;
defer program-internal writes to the OS container; and fail closed on anything entirely
program-internal.** A `cp x .git/config` is classifiable and denied; an `awk 'BEGIN{print > "..."}'`
is program-internal and conceded to the container. The textual floor is a **guardrail / tripwire** —
defense-in-depth that raises the cost of the easy shapes, not complete confinement; the isolation
container (when on — workspace isolation, not an airtight sandbox) and, always, the **human merge** are
the boundaries for whatever the floor concedes. [`limitations.md`](limitations.md) enumerates exactly
where that line falls.
