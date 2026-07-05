# Operating guide

The operator's control surface: the environment and config knobs, the runtime records the harness
writes and reads, the audited escape doors, the oversight board, target-build setup, and the
retention realities you should know before running this unattended or at volume.

For the boundary each of these controls sits behind, cross-reference
[`limitations.md`](limitations.md).

## Environment controls

The harness reads behavior from environment variables, never from prompt text. The load-bearing ones:

### Confinement and autonomy

The isolation container is **networked by default** and is the **default for target-repo builds**
(attended self-build / Forge-maintenance stays host-side — a documented exception). It is
workspace/filesystem/process isolation, **not** an airtight sandbox and **not** egress control (a
networked container does not prevent exfiltration), and not the release boundary (the human merge is).
Set `FORGE_SANDBOX_NETWORK=none` to restore container-level egress-deny. The knobs below control this.

| Variable | Default | Effect |
| --- | --- | --- |
| `FORGE_UNATTENDED` | unset (attended) | Marks a run as unattended. Turns the Stop tests-gate into never-release-on-red, makes the witness gate a hard refusal, makes the test gate strict (SKIPs count as failures), and enables the out-of-band container reaper on `start`. A non-attended `start` is **refused** unless `FORGE_SANDBOX=1`. |
| `FORGE_SANDBOX` | `0` | `1` brings up the OS isolation container at `start`. **Mandatory for any non-attended run.** For an attended **self-build** the container is off unless you set this (the host-side maintenance exception); attended **target** builds are containerized by default (see `FORGE_TARGET_CONTAINER`). |
| `FORGE_TARGET_CONTAINER` | `1` | Target-repo builds run in a container by default. `0` opts a target build out to host-side. |
| `FORGE_TARGET_REQUIRE_CONTAINER` | `1` | Legacy alias for `FORGE_TARGET_CONTAINER` (honored for back-compat). |
| `FORGE_SANDBOX_NETWORK` | `bridge` | Container network. `bridge` (networked, the default) lets the agent reach registries / GitHub / docs; `none` restores egress-deny (workspace isolation without network). |
| `FORGE_REQUIRE_ROOT` | `0` | `1` upgrades the "not at repo root" warning to a hard refusal. Autonomous intake forces this on. |
| `FORGE_SANDBOX_IMAGE` | `mcr.microsoft.com/devcontainers/javascript-node:20` | Container image. |
| `FORGE_SANDBOX_MANIFEST` | the shipped `devcontainer.json` | Override seam for the container manifest. |

### Build / finish

| Variable | Default | Effect |
| --- | --- | --- |
| `FORGE_SKIP_INSTALL` | `0` | `1` skips `pnpm install` in the new worktree. (Relevant to the `static` target, which has no `package.json` — see the known limitation in [`limitations.md`](limitations.md).) |
| `FORGE_STOP_BLOCK_CAP` | `8` | Attended: consecutive red Stop-blocks before the gate releases with a "human intervention needed" message. Unattended: ignored (never releases). |
| `FORGE_FEATURE_BRANCH` | derived from `source_spec` | Overrides the feature branch a feature build bases on (a `task/*` value is rejected). |
| `FORGE_SELF_REPO` | the Forge's `package.json` name | Overrides the logical name the Forge recognizes as "itself" (self vs. target classification). |
| `TARGET` | `typescript` | Selects the `targets.config` stanza (`TEST_CMD`/`LINT_CMD`/`FORMAT_CMD`/`SANDBOX_GLOB`). Validated against a file-derived allowlist before use. |

### Intake

| Variable | Default | Effect |
| --- | --- | --- |
| `INTAKE_CLARIFY_ROUNDS` | `5` | Clarify round budget (bounds agent-initiated questions, never coverage). |
| `INTAKE_RESTATE_ROUNDS` | `3` | Gate-A restatement round budget. |
| `INTAKE_CLARIFY_MAX_Q` | `4` | Max questions per `AskUserQuestion` call. |
| `FORGE_INTAKE_BLOCK_CAP` | `8` | Consecutive intake Stop-blocks before release. |
| `INTAKE_RATIFY_MAX_AGE` | `86400` (s) | Max age of a ratify token before `convert` refuses it as stale. |

### Review

| Variable | Default | Effect |
| --- | --- | --- |
| `REVIEWER_BACKEND` | `ollama` | Review backend: `ollama` (local) \| `claude-fresh` \| `codex`. Validated against an allowlist before use. |
| `DISPOSITION_BACKEND` | the reviewer backend | Backend for the finding-adjudication pass. |
| `SPEC_REVIEW_BACKEND` | reviewer backend | Backend for the intake Gate-A spec review. |

### Beads / board

| Variable | Default | Effect |
| --- | --- | --- |
| `BD_ACTOR` | `BEADS_ACTOR` → `git config user.name` → `forge-local` | The claim/close actor recorded in the ledger. Override via `BEADS_ACTOR` (not `BD_ACTOR`, which `beads.config` assigns unconditionally); `forge-local` is only the last-resort fallback. |
| `BD_DEFAULT_PRIORITY` | `2` | Priority for `start --new`. |
| `BD_ALLOW_VERSION_DRIFT` | `0` | `1` lets a non-pinned `bd` version through the preflight (use only knowingly). |
| `BD_CLOSED_WINDOW` | `30` (days) | Recently-closed window shown in the board's Done lane. |
| `FORGE_HARNESS_DIR` | `<repo>/.harness` | Relocates **all** runtime state (a test seam; note it moves the sentinels, witnesses, and escape logs too). |

### Test gate

| Variable | Default | Effect |
| --- | --- | --- |
| `FORGE_GATE_STRICT` | tolerant (unattended → strict) | `1` makes suite SKIPs (rc 75) count as failures. |
| `FORGE_REQUIRE_DOCKER` | `0` | `1` makes a Docker-absent SKIP a hard failure for container suites. |

Config files carry the rest: `harness/targets.config` (toolchains), `harness/beads.config` (`bd`
binary/pin/identity), `harness/reviewers.config` (backends, models, tool ceilings),
`harness/intake.config` (budgets), `harness/intake-categories.json` (the 142-category coverage enum),
`harness/repos.config` (target map), `harness/board.config` (board manifest).

## The audited escape doors

Four capabilities are deliberately gated behind an explicit environment flag, and every use is
appended to an audit log. The **three deny-hook doors** (`FORGE_ALLOW_HOOK_EDIT`,
`FORGE_ALLOW_MAIN_MERGE`, `FORGE_ALLOW_BD_CLOSE`) are read from the `PreToolUse` hook's own process
environment — never parsed from the command under evaluation — so an agent's Bash prefix cannot open
them for itself; they are true human-only doors.

The fourth, `FORGE_MECHGATE_ALLOW_LEGACY`, is **different, and weaker**: it is read by the
`accept-gate.sh` subprocess of `finish` — a command the agent itself runs — and because `FORGE_*`
prefixes are benign-allowlisted by the env classifier, an agent *can* set it on its own `finish`
invocation. It is not deterred by the floor; it is deterred by the loud audit record
(`legacy_bypass: true`), the still-required green tests, and the human merge. The accept-gate is a
*quality* gate, not a deny boundary — treat this flag accordingly.

Not every task's Definition of Done is a runnable test. Docs, config, and artifact work no longer
need a fabricated exit-0 `dod_test` to clear the accept-gate: a task may carry an empty `dod_tests`
so long as it declares **≥1 `sc_evidence` entry with a typed `assert`** — `contains` or `absent` (a
single-line literal ≤512 chars matched against the *staged blob*) or `sha256` (the blob's exact
digest). The gate runs a fixed, gate-owned checker over the staged index (`grep -F` / `sha256sum`) —
no author-supplied code runs — and stays fail-closed: a phantom path (worktree-only, symlink, or
empty), an absent-when-required or present-when-forbidden literal, a digest mismatch, or a checker
timeout each **FAIL**. A non-empty `dod_tests` is unaffected and behaves exactly as before.

| Door (env var) | Opens | Audit log | Notes |
| --- | --- | --- | --- |
| `FORGE_ALLOW_HOOK_EDIT=1` | Editing an enforcement/harness file (`.claude/hooks/**`, `harness/**`, `.harness/**`, settings). | `.harness/hook-edit-bypass.log` | The sanctioned path for maintaining the hooks (see [`development.md`](development.md)). **No door exists for `.git/` or `.beads/`** — those are unconditionally denied. |
| `FORGE_ALLOW_MAIN_MERGE=1` | A commit on `main`/`master` (both the deny-hook tier and the git pre-commit tier honor it). | `.harness/main-commit-escape.log` | The supervised way a human finalizes a merge or a ledger reconcile directly on `main`. |
| `FORGE_ALLOW_BD_CLOSE=1` | An agent-mediated `bd close`/done-edge verb in-session. | `.harness/bd-close-escape.log` | A convenience triage door, not a necessity — normal closure is the reconcile subprocess. |
| `FORGE_MECHGATE_ALLOW_LEGACY=1` | The acceptance gate passing a pre-contract bead (no `metadata.accept`). | the acceptance audit record (`legacy_bypass`) | Loud, audited; for beads minted before the acceptance contract existed. |

These logs are explicit, attributable, append-only audit evidence — never silent. They give you task
provenance and an audit-friendly trail; map that to your own governance obligations as needed (the
Forge names no certification regime and makes no compliance promise). Editing a hook through your
terminal `$EDITOR` is outside Claude Code's permission system and is never blocked; the door is for
edits made through an agent tool call.

## Runtime records

All under `.harness/` (untracked). The harness's own writes here are legitimate; agent tool-writes to
`.harness/**` are denied by the floor, which is what makes the ratify tokens and PR records
unforgeable.

| Path | Written by | Read by | Lifecycle | Schema (keys) |
| --- | --- | --- | --- | --- |
| `active-task.json` | `start` | `finish`, `status`, `kill-switch`, `reaper`, the deny hook | Per build task; removed at `finish`/`kill-switch`. | `task, slug, branch, worktree, base, base_sha, bead, started, pid, push_url, source_spec, feature_branch` (+ `work_root, target_repo, target_path` for target builds) |
| `active-intake.json` | `intake.sh start` | intake commands, `stop-gate-intake.sh` | Per intake; cleared at `convert`/`abort`. | `spec, slug, objective, targets, mode, phase, clarify_rounds, restate_rounds, clarify_max_q, started` |
| `intake-ratified.json` / `intake-breakdown-ratified.json` | `ratify` / `ratify-breakdown` (human, TTY) | `convert` | Per intake; wiped at `convert`/`abort`/clarify re-open. | `{spec, sha256, fr_sha256, ratified_at, human_origin:true}` / `{spec, task_sha256, actor, ratified_at, human_origin:true}` |
| `intake-spec-review.json` | `spec-review` | `stop-gate-intake.sh`, `ratify` | Per intake. | `{spec, spec_sha256, verdict, findings, backend, model, actor, ts}` |
| `pr/<bead>.json` | `finish` (`forge_finish_record_pr`) | `sync`/reconcile (consumed on close); deleted by `kill-switch` | Per bead; single-use. | `{repo, branch, pr}` |
| `assembly/<feature>.json` | `finish` (feature builds) | reconcile, `finish` partial-detection | Per feature branch; appended per merge. | `{feature, source_spec, feat_branch, feature_pr, merges:[{bead, task_branch, task_sha, feat_before_sha, merge_commit, ts, actor}], state, last_error}` |
| `acceptance/<ts>-<pid>-<bead>.json` + `…-selN.log` | `accept-gate.sh` (≈2 per finish) | humans / tooling | Persistent audit; accumulates. | `{bead, branch, base_sha, mode, verdict, checks[contract/scope/dod_tests/sc_evidence/integrity], legacy_bypass, timeout_s, kill_grace_s, actor, ts, reasons, rescope_ledger_exempt, advisories}` |
| `review/<pr>.json` | `review-task.sh` | disposition step, humans | Per feature PR; persistent. | `{pr, verdict, findings:[{id, severity, location, finding, suggested_fix}], backend, model, feature_sha, actor, ts}` |
| `disposition/<pr>.json` | `review-task.sh` | humans | Per feature PR; sibling of the review record. | `{pr, feature_sha, dispositions:[{id, disposition∈CONFIRMED\|REBUTTED, reasoning}], backend, model, actor, ts}` |
| `session-floor.<session-id>.json` | `SessionStart` witness | `finish`, `convert` (verify) | Per session; **never garbage-collected**. | `{session_id, source, cwd, actor, ts, floor_hash}` |
| `board-sync-state.json` | `board-sync.sh sync` | `board-sync.sh check` | Persistent singleton. | `{digest, count, synced_at}` |
| `hook-edit-bypass.log` / `main-commit-escape.log` / `bd-close-escape.log` | the escape doors above | humans / audit | Append-only forensic. | TSV audit lines |

## The oversight board

A read-only GitHub Project (v2) that projects bead state one-way for human supervision — it never
writes back to `bd`.

```bash
./harness/board-bootstrap.sh          # create / verify the board structure (idempotent)
./harness/board-sync.sh sync          # project beads → board (one-way, Beads-wins, archive-on-absence)
./harness/board-sync.sh check         # exit 0 = in sync, non-zero = drift report
```

`board-sync` reads **only** the stable 7-key `run-task.sh board --json` contract — never `bd`
directly, never `.beads/` — and that read-only property is enforced by a test (`board-sync.sh`
contains no raw `bd`/`.beads` in executable code). The Done lane shows recently-closed work within
`BD_CLOSED_WINDOW` days. Note the board is a *projection*: if `board-sync` hasn't been run recently,
the board is stale against the ledger — the ledger is the source of truth, the board is the view.

## Target builds

Target builds are how the Forge does its real work — driving a build into an external repo. To set
one up:

1. **Map the target.** Copy `harness/repos.config.example` to `harness/repos.config` and add a line
   mapping the target's logical name to its absolute clone path on this host. `repos.config` is
   gitignored (host-absolute paths are instance data); `run-task.sh` fail-closes with a clear message
   if it's missing, and the resolution is strict (unlisted name, non-absolute, or non-git → refusal).
2. **Give the bead a target.** The bead's `metadata.target_repo` must be that logical name. Intake
   mints this from the spec's `--target`; for a hand-made bead, set it via `bd`.
3. **Start it.** `./harness/run-task.sh start <bead-id>`. The harness classifies it as a target build
   (distinct git store), worktrees the *target* repo, sets the deny-hook confinement to that work
   root, and keeps the ledger, PR, and floor Forge-side.
4. **Container (default for target builds).** Attended target builds run in a **networked isolation
   container by default** (`FORGE_TARGET_CONTAINER=0` opts out to host-side; `FORGE_SANDBOX_NETWORK=none`
   restores egress-deny). Unattended target builds require `FORGE_SANDBOX=1`.
5. **Finish** strips any Forge artifacts and asserts the target PR is pristine before committing.

Feature builds (multiple beads sharing a `source_spec`) assemble onto one `feat/<spec-slug>` branch
and open a single feature PR; all sibling beads close together when it merges. See
[`lifecycle.md`](lifecycle.md#self-builds-vs-target-builds-vs-feature-builds).

## Retention and cleanup

(Know these before running unattended or at volume.)

The Forge does not currently garbage-collect several things. None is dangerous; all accumulate:

- **Session-floor witnesses** (`.harness/session-floor.*.json`) — one per Claude session, never
  cleaned. They grow indefinitely. Safe to delete old ones by hand; the current session's is
  re-minted on the next `SessionStart`.
- **Acceptance records** (`.harness/acceptance/…`) — ~2 per `finish`, kept as audit. Accumulate.
- **Merged-task worktrees** (`.claude/worktrees/<slug>`) — `finish` removes the sentinel and the
  container but **not** the worktree; `kill-switch` is abort-only; `reaper.sh` sweeps *containers*,
  not worktrees. So worktrees of completed tasks accumulate and need occasional manual
  `git worktree remove` / `git worktree prune`.
- **Orphaned PR records** (`.harness/pr/<bead>.json`) — normally consumed on close. If a human closes
  a bead by hand (working around a reconcile gap), the record is left behind with no cleanup path.
- **Stale containers** — `reaper.sh --reap` removes containers whose worktree is gone or that aren't
  named by the live sentinel; it auto-fires only on the unattended `start` path. Attended, run it by
  hand. It never touches the sentinel-named worktree's container and refuses everything on a corrupt
  sentinel.
