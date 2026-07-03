# Limitations & guarantees

This is the honest boundary of the Forge, stated plainly. It is the most important document in the
set: the code's own comments are more careful about what the harness does and does not do than any
marketing would be, and this page matches the code, not the marketing.

Read it as three questions:

1. **What is mechanically enforced?** (deterministic, no model judgment, fails closed)
2. **What is best-effort, and what's the backstop?** (hardened but not airtight — the known escape classes)
3. **What is explicitly out of scope?** (deliberately not controlled)

A fourth section covers structural limits of the trust model — design facts, not defects — and the
document ends with a note on how to read it as an adopter.

The overall posture: **a mechanically-enforced deny floor plus a human-gated release.** The floor
reliably blocks a fixed set of dangerous command shapes and fails closed; determined obfuscation is
conceded to an OS container and to the human merge. The container is **off by default in attended
runs**, so in the normal workflow the deny floor raises the cost of the easy shapes and the human
merge is the actual backstop. This is a strong, defensible position — stated honestly it is more
credible than "unbypassable," which the enforcement library itself refuses to claim ("It is NOT
airtight and does NOT claim to be").

---

## 1. What is mechanically enforced

Deterministic controls that fire regardless of the model's judgment and fail closed (a broken,
unparseable, or partially-loaded hook denies; it does not wave work through). These hold **when the
hook is loaded** — see the off-root limit in §4.

| Guarantee | Mechanism |
| --- | --- |
| The deny decision survives `--dangerously-skip-permissions` | `forge_deny` emits `permissionDecision:"deny"`; a broken `lib.sh` or missing `jq` → deny + exit 2. |
| Enforcement files can't be edited by the agent | `.claude/hooks/**`, `harness/**`, `.harness/**`, settings — denied (door: `FORGE_ALLOW_HOOK_EDIT=1`, logged). `.git/` and `.beads/` — denied with **no door**. |
| Writes are confined during a task | To `sandbox/` (self build) or the resolved `work_root` (target build); `..` and relative paths fail closed. |
| Intake writes are confined | To `specs/**`; `.claude/agents\|skills\|commands` self-rewrite denied. |
| No push/commit to `main`/`master` | Live-branch reads (not string guesses) in the deny hook **and** an all-actors git pre-commit guard (every vector). |
| No force/mirror/bare push, no `+refspec` to main | Argv-aware push walker with value-flag routing. |
| `--no-verify` / `core.hooksPath` / `HUSKY=0` denied | Textual, over-broad by design. |
| Git-as-mutator can't overwrite floor files | 12 modeled verbs; `git apply`/`am` bounded by git-decoded numstat at forced `-p0` (structural, not a blacklist). |
| Agent can't close beads directly | `bd close/done/import/supersede/duplicate`, `update --status closed`, `bd todo done` denied (door: `FORGE_ALLOW_BD_CLOSE=1`, logged). |
| Secret-shaped literals denied | Regex for `sk-…`, `gh[opsur]_…`, `github_pat_…`, `AKIA…`, `xox…`, PEM keys (JWT warns only). |
| Human ratify gates are TTY-gated; the tokens are non-forgeable | `ratify`/`ratify-breakdown` require a TTY; tokens live under agent-unwritable `.harness/` and are hash-bound + re-verified at `convert`. (Spoofing the *attendance signal* itself with a PTY is a separate residual class — see §2.) |
| Privileged ops prove the floor is loaded | `finish` and `convert` verify the session witness against a live floor-hash recompute. |
| The acceptance gate is judgment-free | `accept-gate.sh`: diff ⊆ scope, DoD tests pass, evidence present — pure bash/git/jq, no LLM. |
| The reviewer can't gate or merge | Tool ceiling is `Read`/`Grep`/`Glob`; the harness talks to GitHub; findings are advisory PR comments. |

## 2. What is best-effort (and the backstop)

The deny hook is a textual classifier of the command string the agent hands the Bash tool. It models
the common shapes and their laundering, but it cannot model all of shell grammar and **does not see
inside subprocesses**. Its design rule: classify write targets identifiable from the argv; defer
program-internal writes to the OS container; fail closed on anything entirely program-internal. The
known escape shapes, from the code's own comments:

| Surface | Escape shapes it concedes | Backstop |
| --- | --- | --- |
| Env-prefix launch (`PATH=`/`LD_*`/`BASH_ENV`) | here-string `<<<`, process substitution, command-substitution that launches, function/case/coproc bodies, a separator inside a quoted value (`${x:-a;b}`), ANSI-C `$'…'`, `flock -c`, `awk system()`, backslash-newline, renamed/glob entrypoint | OS container + human merge |
| Interpreter `-c`/`-e` bodies | `php -r`, `lua -e`, other un-enumerated interpreters; `bash -cx` (c-not-terminal) | OS container |
| Exotic / unrecognized writers | `python -c`, custom binaries, toybox/busybox multicall; recognized writers (perl/ruby `-i`, `sed -i`, editors, tar, cpio, patch) fail closed | OS container |
| Program-internal writes to floor paths | `awk 'BEGIN{print > "…"}'`, `sed -n 'w …'`, symlink indirection | OS container |
| Broad-revert git | whole-tree `git pull`/`merge`/`rebase`/`reset --hard <ref>` with no floor pathspec are allowed | **witness floor-drift detection** + OS container |
| bd done-edge laundering | `bash sandbox/x.sh` containing `bd close`, `env -i` survival, embedded-quoted verb, GNU `parallel` | OS container + human triage |
| Path-qualified `sudo` (`/usr/bin/sudo`) | evades the word-match | platform safety hook + container |
| The acceptance gate's own interpreter | a sandbox-shimmed `bash` could interpret the gate and forge a PASS | it's a *quality* gate, not a boundary; launch-time trust is the container + human merge |

**The load-bearing caveat: the container is not always on.** The OS confinement container
(`--network none`, read-only mounts of the enforcement files, dropped caps, unprivileged user) is
brought up **only** for unattended runs (where `FORGE_SANDBOX=1` is mandatory) and for opt-in target
builds (`FORGE_TARGET_REQUIRE_CONTAINER=1`). **In a default attended run there is no container.** So
for every "backstop: OS container" row above, in the attended workflow the real backstop is the deny
hook (for the shapes it models) plus the human merge (for everything it concedes). This is the single
most important reframing of the security story: *attended, the human merge is the completeness
boundary.*

**Subprocess blindness (architectural).** `PreToolUse` sees only the tool-call input — the command
string, file path, and content. It never sees the process tree a command spawns. A script the agent
writes into `sandbox/` and then runs exposes only `bash sandbox/foo.sh` to the hook; the verbs inside
are never classified. This is *why* the launch/interpreter/exotic-writer classes are conceded to the
container. The reconcile bead-close deliberately relies on this (it runs as a subprocess, so the
`bd close` deny "over-blocks zero automation").

### Known limitation classes of the textual floor

Properties of the classifier as shipped — not bugs discovered in your instance, but the shapes the
mechanism itself concedes or only partially models:

- **Git plumbing is an unmodeled floor-write path.** The git-as-mutator walker models porcelain and
  index verbs; the plumbing equivalents (`hash-object -w`, `mktree`, `commit-tree`, `update-ref`) are
  not classified. Conceded to the container + human merge.
- **The done-edge deny covers close-verbs only.** `bd delete` and `bd edit` are allowed; an agent can
  mutate or remove ledger entries without "closing" them. Conceded to the container and to human
  governance of the ledger.
- **Interpreter eval-body holes on floor paths.** `bash -cx` (where `-c` is not the terminal flag),
  path-prefixed interpreters, here-strings and process substitution feeding an interpreter, and any
  interpreter not in the enumerated set (`php -r`, `lua -e`, …).
- **Redirect-tokenizer holes.** Word-glued forms (`echo x>.git/…`), separator-less shapes, and
  named-fd redirections can slip the redirect classifier.
- **`NODE_OPTIONS` / `NODE_PATH` remain allowlisted** — the node-world analog of `LD_PRELOAD`.
  Container-backstopped.
- **Symlink portals and `sed`'s attached-`w` form are closed at the mount layer, not textually.** The
  container's read-only mounts of the enforcement files are the close; there is deliberately no
  textual rule, and the boundary-test battery pins that choice (adding a textual close would flip a
  canary RED). Attended — no container — these are open for floor paths.
- **Planted git-config host-exec at worktree-add/merge seams.** `filter.smudge`/`filter.clean`,
  `textconv`, and `merge.<driver>.driver` can execute host commands at seams the harness drives; the
  git wrapper neutralizes `core.hooksPath` and `fsmonitor` but not these.
- **The TTY gate is an attendance signal, not proof of a human.** An agent that allocates a PTY and
  routes `ratify` through a wrapper is not caught by the TTY check; that class is deferred to
  OS-level confinement of unattended runs. (The ratify *tokens* remain non-forgeable either way —
  hash-bound, stored under an agent-unwritable path, re-verified at `convert`.)
- **The acceptance gate has a check-to-use window.** Between its checks and the release action the
  tree can change; the gate is a quality gate, and the human merge is the boundary that absorbs this.
- **Reconcile trusts the harness-written PR record.** It queries the repo named in the record with no
  pinned origin allowlist, so a record naming an unlisted repo would still be queried. The record is
  harness-written and single-use, which limits reach. Similarly, the close path for merges that do not
  come from a `task/*` head ref trusts the record branch and an unsigned merge-commit anchor;
  `task/*` head refs are id-bound and unaffected.
- **Intake validation is shallow in places.** A bare `definition_of_done: true` satisfies the
  non-empty check, and degenerate scope globs (`./x`, `x//y`, a trailing `/`) are accepted.
- **Test discovery only sees registered keys.** The gate runs every `test:*` script in
  `package.json`; a test file that exists on disk but is never registered silently never runs. This
  is the exact rot the discovery discipline exists to prevent — audit the registration periodically.

**Fail-safe over-blocks (annoying, not dangerous).** The classifier errs closed in known ways: it can
misread a `chmod`/`chown`/`truncate` mode/owner/size operand as a path and deny a benign command, and
the env-prefix classifier over-blocks a benign non-allowlisted variable before a terminal runner with
no command word (`DEBUG=1 timeout 60`) — you will see this fire on some benign read-only pipelines.
Both fail closed; neither opens a hole.

## 3. What is explicitly out of scope

- **The sibling vault (e.g. `../my-vault`).** It is an external repo, deliberately **out of the
  Forge's scope**. The deny floor makes **no** claim about vault writes — an absolute vault path is
  not adjudicated; only a relative `../my-vault/…` write is denied, and that is via the general
  `..`-unverifiable rule, not a vault claim. (An earlier "vault is read-only, enforced" claim was
  removed precisely because it was leaky and the floor could not keep it.)
- **Network egress** — controlled only *inside* the container (`--network none`), i.e. not in attended
  runs.
- **Secret-scanning depth** — a shallow regex, not a real scanner; novel token shapes pass.
- **The target repo's own code quality** — the harness gates the target's configured tests/lint, not
  the correctness of its source.
- **Launch-time interpreter/PATH trust and obfuscation** — conceded to the container + human merge.
- **Reviewer judgment quality.** The reviewer is advisory and non-gating *by design*: findings land as
  a plain PR comment, never a blocking review, and severity ratings — especially from small local
  models — are unreliable. The human merge judgment is the control; do not treat reviewer output as a
  gate.
- **Witness scope.** The session witness hashes the repo-local floor. It does not hash user-scope
  settings (`~/.claude/settings.json`) or managed-policy sources; those layers are outside its claim.
- **Non-goals** — meta-orchestration, observability/tracing, RAG, and reviewer calibration are
  deliberately not built here.

## 4. Structural / trust-model limits (design facts, not defects)

- **The container is off by default in attended runs** — restated here because it governs §2's whole
  backstop column. Attended, the human merge is the completeness boundary.
- **No server-side branch protection.** "Agents never merge / never push `main`" is enforced against
  the agent's *tool calls*. There is no `gh pr merge` deny rule and no git pre-*push* hook, so a build
  agent's Bash `gh pr merge` is not mechanically blocked, and a human with a terminal is trusted. The
  reviewer *role* is mechanically merge-incapable (tool ceiling). Configure branch protection on your
  hosting platform if you want a server-side guarantee.
- **`intake.sh clarify` and `abort` are not TTY-gated** — unlike `ratify`, they are agent-invocable.
  This is convention, not mechanism; but `clarify` only lifts the question budget and `abort` only
  destroys intake state — neither forges a human sign-off.
- **The attended Stop tests-gate releases at a cap.** "Cannot declare done while red" is literally
  true only unattended; attended it is a bounded nag (default 8) that then releases with a
  human-intervention message.
- **The off-root / bypass / not-via-`run-task.sh` intersection.** A session under
  `--dangerously-skip-permissions`, launched where `.claude/settings.json` isn't discovered (a
  subdirectory, or a clone missing the user-scope backstop), and not driven through `run-task.sh`,
  runs with **neither** the bypass-surviving hook (not loaded) **nor** `permissions.deny` (skipped
  under bypass). That intersection is the honest open limit; the mitigations are: launch at the repo
  root, install the user-scope backstop, and the witness (which makes a privileged op fail closed on a
  no-witness session).
- **Single-writer task store.** The embedded `bd` DB lives in the main checkout; concurrent agents are
  not supported. A shared task server is the natural extension point.

---

## The one thing to take away

The Forge does not claim to be an impenetrable sandbox, and you should not present it as one. It
claims to be a **deterministic control plane with a human-gated release** — a floor that reliably
blocks the easy dangerous shapes and fails closed, an audited set of human-only doors, and a human who
reviews and merges every change. Where that floor is porous, it says so, an OS container closes the
gap *when it is enabled*, and the human merge closes it otherwise. That is the guarantee.

## How to read this document

This page describes the **guarantee shape of the mechanism** — what the shipped floor enforces,
concedes, and ignores. It is not a bug tracker. Your instance will accumulate its own residuals:
over-blocks you hit, gaps you probe, mitigations you accept-and-defer. Maintain that ledger yourself —
file each residual as a bead (e.g. `fx-…`) and tag it with the taxonomy this document uses:

- **`[mech-mitigated]`** — a mechanical control reduces the risk but doesn't fully close it (often an
  over-block that fails *safe*).
- **`[best-effort]`** — a textual best-effort with the OS container as backstop (recall §2: that
  container is off by default attended).
- **`[out-of-scope]`** — deliberately not controlled.
- **`[open]`** — a genuine gap, no full mechanical mitigation yet.

When you accept a residual rather than fix it, record the acceptance and its rationale where a future
session will find it. An unwritten concession is indistinguishable from an unknown hole.
