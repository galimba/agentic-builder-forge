# Development & enforcement-maintenance

How the Forge itself is changed — and, in particular, how its own enforcement files are changed
safely, since the agent that develops the Forge is denied write access to those files by the very
floor it is editing. This is the discipline the harness encodes, not generic advice.

## The change flow

Every change lands as a **pull request into `main`, merged by a human** through the GitHub UI. Merge
commits are authored by the maintainer via the merge button; non-merge commits are agent-authored
under the human's git identity with a `Co-Authored-By: Claude` trailer. The one exception is
human-only direct-to-`main` `chore(beads)` ledger-reconcile commits, made through the audited
`FORGE_ALLOW_MAIN_MERGE=1` door.

So the accurate model is: **agents never commit to `main` (mechanically denied); a human occasionally
does, through a logged door, for ledger reconciles.** Everything substantive goes through a PR.

Conventions:

- **Conventional-commit subjects** with a scope: `fix(floor):`, `feat(intake):`, `test(boundary):`,
  `chore(beads):`, `docs:`. The bead ID goes in the subject.
- **Branch names** off `main`: `task/*` (build loop), `fix/*`, `feat/*`, `chore/*`, `review/*`.
- **One concern per commit** (occasionally a deliberately-cumulative "cluster" commit when a floor
  must move exactly once).
- **Test-first / RED-first**: the failing test is written and committed as a canary before the fix.

## Changing enforcement files — the splice / door pattern

The agent **cannot** write `.claude/hooks/**`, `.claude/settings*.json`, `harness/**`, or
`.harness/**`: the deny hook classifies these as `enforce` and denies the write (`.git/` and
`.beads/` have no door at all). This is deliberate — disabling your own guardrails is the cardinal
failure. Legitimate maintenance goes through a sanctioned, logged door:

1. **The agent stages a candidate under `sandbox/`.** Instead of writing the live files, it writes
   `*.built` candidate files plus `apply-*`, `prove-*`, and `recert-*` scripts and a `SPLICE.md`
   runbook. Nothing under `sandbox/` is a product file.
2. **The agent proves the change pre-splice** — canary tests RED on the deployed floor and GREEN on
   the candidate overlay, a full gate run on a clone, and (for a floor move) the re-certification
   differential.
3. **The agent STOPS before any durable operation.** No commit, no push, no merge, no door. The
   SPLICE.md is the handoff.
4. **A human applies the splice.** The human reviews the full candidate diff, then runs the applier
   with the door set: `FORGE_ALLOW_HOOK_EDIT=1 bash sandbox/<batch>/apply-*.sh`. The applier itself
   refuses without the door and refuses on `main`/`master`/detached HEAD.
5. **The appliers are content-match-or-abort, with hash pins** — not blind copies. A floor applier
   asserts the live floor equals the expected pre-splice hash, splices, then asserts the post-splice
   floor equals the pinned new hash, and aborts (telling the human to restore from git) on any drift.
6. **The human branches, commits per concern, re-certifies, runs the full gate, pushes, opens the
   PR**, and — after an independent pre-merge review — merges.

The door is read from the human's launch environment, not from the command under evaluation, so an
agent cannot set it for itself. Every door use is appended to `.harness/hook-edit-bypass.log`.

## Re-certifying a floor move

A change that alters any of the five floor-hash inputs (see
[`architecture.md`](architecture.md#the-floor-identity)) "moves the floor" and must be
re-certified before it lands. The discipline the `recert-*.sh` scripts encode:

1. **Behavioral corpus differential.** Drive an identical corpus of commands through the *old* (live)
   deny hook and the *new* (candidate overlay) hook and assert the verdict delta is **exactly** the
   intended DENY↔ALLOW flips for this change — with **zero collateral** on Forge-own paths
   (`.git`, `.beads`, `harness`, `.claude/settings`). A flip that wasn't intended is a failure.
2. **Hash labels via `forge_floor_hash`** (not a hand-rolled `cat`): the old hash must equal the
   pinned baseline, the new hash must equal the pinned expected value (what the next `SessionStart`
   will mint), the floor must actually move, and each intended input file must be non-byte-identical.
3. **Canary RED→GREEN, made permanent.** The intended flips are encoded as standing gate tests
   (`tests/boundary/foldNN-*.sh`) that are RED on the deployed floor and GREEN on the candidate —
   after the splice they run GREEN by default and stay as regression locks.
4. **Full gate green at the new hash** (`pnpm test`), pre-proven on a candidate clone.

A change that touches a protected file but **not** a floor-hash input skips re-certification. Nothing
under `harness/**` is a floor-hash input — not `harness/targets.config`, and not even
`harness/githooks/pre-commit` (that guard is verified by its own `test:commitguard` suite, not by the
floor hash). Such a change must still *prove* the five inputs are byte-unchanged (the floor hash did
not move), so the witness doesn't need to re-mint.

## The proof model

Correctness is proven before merge, and the tests are structured so proof can't silently rot.

- **The gate auto-assembles.** `pnpm test` → `tests/run-all.sh`, which discovers every `test:*` key
  in `package.json`. A suite that isn't a registered key is invisible to the gate — so
  registration is the thing that keeps a suite from silently dropping out.
- **Three verdicts, never conflated:** rc 0 = PASS, rc 75 = SKIP (e.g. Docker absent), anything else
  = FAIL. Zero discovered suites is itself a failure. Unattended runs go strict (SKIP → FAIL).
- **Floor tests self-guard.** Each floor/boundary test brackets its run with a `git hash-object` of
  `lib.sh` before and after and asserts *it* didn't move the floor — the deliberate move is proven in
  the recert, not by a test mutating the live floor.
- **Folds drive the hook as a subprocess.** A fold feeds a synthetic tool-call JSON to the hook script
  on stdin and greps the verdict. The attack command is *classified as a string*, never executed —
  `sudo …`/`rm -rf …` are analyzed, not run.
- **Over-block is the primary failure mode.** Every fold carries an explicit allow-list section:
  legitimate in-bounds commands with real-world flags must still pass. Blocking real work is treated
  as worse than a narrow under-block, because a floor that breaks the build loop is unusable.
- **Isolation is enforced for the container tests.** They run against a throwaway `/tmp` clone; an
  `isolation-lib` guard realpath-resolves final mount targets and fails closed if any test could name
  a live enforcement path as a write target.
- **Hermeticity byte-guards.** Suites that touch a real `bd` ledger or `.harness` record sha256 it
  before and after and fail loudly if the real artifact changed.

The `tests/hooks/COVERAGE.md` file maps each deny path in the hooks to the assertion that pins it, so
a rewrite can't silently unpin a current true-positive. (It carries self-acknowledged line-number
drift for the consolidated walkers — the mapping is maintained, the line refs lag.)

## Roles

Five agent roles are documented in `.claude/agents/`. Each sets a tool ceiling and each states the
same rule up front: **the hooks are the boundary, not this prose** — an interactive Claude Code
session does not honor a subagent's `tools:` restriction, so the file documents the role while the
hooks do the enforcing.

| Role | Tool ceiling | May do | May not | Enforced by |
| --- | --- | --- | --- | --- |
| **architect** | Read, Grep, Glob, Write, Edit, AskUserQuestion, Task | Author a spec under `specs/**`, drive the clarify loop and Gate-A restatement, write the Task Breakdown. | Mint beads, run `bd`, self-ratify, touch code/harness/hooks/ledger, write the vault. | Intake `specs/**` write-allowlist; `ratify` TTY gate + deny-hook command forms; clarify/Stop floors. |
| **builder** | Read, Grep, Glob, Edit, Write, MultiEdit, Bash | One task, test-first, write only under the work root, end with `finish` → PR. | Push/commit `main`, `--no-verify`, edit enforcement files (all *mechanical*); merge, review own work (by *convention* + a client-side deny — the builder has Bash; `gh pr merge` and the repo-admin/secret/auth/workflow/gh-api-write surfaces are denied by the deny hook as defense-in-depth, but a human in a non-agent shell is still trusted for the merge). | Deny hook, git pre-commit guard, Stop gate, PostToolUse format/lint (for the mechanical items); workflow separation + the human merge (for merge/self-review). |
| **reviewer** | Read, Grep, Glob | Adversarial PR-diff review; severity-tagged advisory findings in a sentinel JSON block. | Write, push, comment directly, merge, or **gate** — the verdict is advisory; the deterministic tests are what must pass and the human decides the merge. | Tool grant (no Write/Bash); harness fails closed and posts "manual verification required" on a missing/malformed verdict. |
| **disposition** | Read, Grep, Glob | Adjudicate each *supplied* reviewer finding CONFIRMED/REBUTTED against the diff. | Hunt new findings, write/fix/merge, gate. | Tool grant; fail-closed sentinel record. |
| **spec-reviewer** | Read, Grep, Glob | Review a draft spec vs. the coverage taxonomy; ACCEPT/ESCALATE the architect's reconciliations. | Ratify, block, or use conversation context — the human ratifies at Gate A. | Tool grant; the harness owns its output slice. |
| **human** | — | Ratify Gate A / A′ (TTY), set the escape doors post-review, **merge PRs**, run `sync`. | — | TTY gates, launch-environment doors, GitHub — none agent-reachable through the Forge tooling. |

## If you spot a code/comment inconsistency

Some in-tree comments and doc fragments can lag the code (e.g. a provenance header left over from a
splice, or a script header that under-counts the floor-hash inputs). These are cosmetic. File a bead
(via the intake flow or `run-task.sh start --new`) rather than editing an enforcement file directly —
and never "fix" a comment by taking the door unless the human is doing the splice. The documentation
set here is written to be internally consistent with the *code's behavior*; where a source comment
contradicts the code, the code is authoritative.
