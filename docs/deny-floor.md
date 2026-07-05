# The deny floor — classification (guarantees, tripwires, and non-claims)

This is the **machine-checked claim↔test spine** of the enforcement floor: what it **guarantees**, what it
only **tripwires**, what it **does not claim** — and, on every enforced line, **the test that proves it**.
[`limitations.md`](limitations.md) is the prose depth (the reasoning and the escape-shape detail); this page
is the crisp, testable index. Every `` `test:<suite>` `` token below is a registered `package.json` suite,
and `test:floor-claims` fails closed if this doc ever cites a test that does not exist, if a load-bearing
mechanism's **call-site** is removed from the deny hook (behavioral integrity is the cited suites' own
job), or if the vault honesty-seam is quietly upgraded.

## How to read this

- **GUARANTEE** — mechanically enforced, deterministic, **fails closed**; the deny decision survives
  `--dangerously-skip-permissions` (`forge_deny` emits `permissionDecision:"deny"`; a broken `lib.sh` or a
  missing `jq` denies and exits 2). Holds **when the hook is loaded** (see the off-root limit under §3).
- **TRIPWIRE** — best-effort defense-in-depth: it deters and detects the common shapes, **not** an airtight
  sandbox. The backstop for what it concedes is the **OS isolation container** (default for target builds,
  host-side for attended self-build; networked) **and the human merge**.
- **DOES NOT CLAIM** — deliberately out of scope; the floor makes no promise here, by design.

Each entry carries the `limitations.md` residual tag: `[mech-mitigated]` · `[best-effort]` · `[out-of-scope]`
· `[open]`. The floor spans the deny hook, the Stop gates, the clarify gate, the session witness, and the
acceptance gate — all classified below.

---

## 1. GUARANTEE — mechanically enforced, fail-closed

| Claim | Mechanism | Proof |
| --- | --- | --- |
| The deny decision survives `--dangerously-skip-permissions`; a missing/partial `lib.sh` or absent `jq` denies + exits 2 | `forge_deny` + the lib-keystone (`command -v forge_deny … forge_check_gh`) | `test:hooks` |
| Enforcement files are agent-unwritable — `.claude/hooks/**`, `.claude/settings*.json`, `harness/**`, `.harness/**` (door: `FORGE_ALLOW_HOOK_EDIT=1`, logged) | `ENFORCE_RE` + `forge_enforce_class` + `forge_check_writes` | `test:hooks` |
| Writes under `.git/` denied (tool + Bash tiers) | `forge_enforce_class` (`git`) + `forge_check_writes` | `test:hooks` |
| The `.beads/` ledger is raw-write-denied — mutate via `bd`; `bd` and reads allowed | `forge_enforce_class` (`beads`) | `test:hooks` |
| No push to `main`/`master` — refspec, `--mirror`/`--all`, on-branch, `symbolic-ref` evasions | `forge_check_push` (argv-aware) | `test:hooks` |
| No force-push | `forge_check_push` | `test:hooks` |
| No commit/amend to `main`/`master` (agent tool tier) + an all-actors git pre-commit backstop | `forge_check_commit` + `harness/githooks` | `test:commitguard` |
| `--no-verify` / `core.hooksPath` / `HUSKY=0` denied | textual (over-broad by design) | `test:hooks`, `test:fold29-hookspath-guard` |
| Git-as-mutator can't overwrite floor files (`checkout`/`restore`/`apply`/`am` at a floor pathspec); a missing `forge_check_git` fails closed | `forge_check_git` (12 modeled verbs) | `test:escape-classes` |
| Recursive-force `rm` outside `sandbox/` denied | `forge_check_rm` | `test:hooks` |
| Secret-shaped literals denied (`sk-…`, `gh[opsur]_…`, `github_pat_…`, `AKIA…`, `xox…`, PEM); JWT warns only | secret regex over command + written content | `test:hooks` |
| During a task, writes confined to `sandbox/` (self) or the absolute `work_root` (target); `..` + relative + malformed-sentinel fail closed | task tier + `forge_classify_target` | `test:hooks`, `test:boundary` |
| During intake, writes confined to `specs/**`; `.claude/agents\|skills\|commands` self-rewrite denied | intake allowlist tier | `test:intake`, `test:hooks` |
| Cannot end a build turn while `tests/run-all.sh` is red (the completion authority; unattended) | `stop-gate-tests.sh` | `test:gate` |
| Cannot end an intake before the spec is ratified | `stop-gate-intake.sh` | `test:intake` |
| Clarify / restate budgets are enforced | `pre-tool-use-clarify-gate.sh` | `test:intake` |
| The ratify **tokens** are non-forgeable — hash-bound, stored under agent-unwritable `.harness/`, re-verified at `convert` (the TTY gate itself is an attendance signal, not proof of a human — see §2) | `cmd_ratify` token | `test:intake` |
| Privileged ops (`finish`/`convert`) prove the floor is loaded via a live floor-hash recompute vs the witness | `session-start-witness.sh` + recompute | `test:witness`, `test:fold10-witness` |
| The acceptance gate is judgment-free — diff ⊆ scope, DoD tests pass, evidence present; **no LLM**; profile-blind and vault-blind | `accept-gate.sh` (bash/git/jq) | `test:mechgate` |
| The reviewer can't gate or merge (tool ceiling `Read`/`Grep`/`Glob`; the harness talks to GitHub; findings are advisory comments) | reviewer role + harness | `test:reviewer`, `test:reviewer-disposition` |
| `bd` is authoritative — the agent can't close beads directly (door: `FORGE_ALLOW_BD_CLOSE=1`, logged) | `forge_check_bd` | `test:fold25-bd-verb-deny` |
| Reconcile close for `task/*` + `<ns>/*` head refs is **id-bound** — a forged head ref in those namespaces is rejected (the `feat/` override arm is record-trusted — see §2) | `forge_reconcile_id_bound` (ARM 2) | `test:fold24-reconcile-idbind`, `test:fold13-reconcile` |
| The `bd` binary is pinned (version + absolute path); a version/shape drift fails closed | `harness/beads.config` pin | `test:fold12-bdbin`, `test:fold20-coldstart` |
| The finished target commit is pristine (no forge artifacts) | `run-task.sh` finish (H3) | `test:pristine` |

## 2. TRIPWIRE — best-effort defense-in-depth (backstop = OS container + human merge)

| Shape | What it concedes | Backstop | Proof |
| --- | --- | --- | --- |
| gh capability denies — `pr merge`, repo-admin, secrets, auth, workflow-control, `gh api` writes | a `bash wrapper.sh` around `gh`; a human in a non-agent shell / the GitHub UI | client-side capability boundary, **not** server-side branch protection; the human merge | `test:fold31-gh-capability-deny`, `test:fold19-gh` |
| `intake.sh ratify` self-ratify string-deny | `bash wrapper.sh` around ratify — a string matcher can't see it | the real guard is `cmd_ratify`'s **TTY gate** (the agent's Bash is non-TTY) + human | `test:intake` |
| Env-prefix launch shim deny (`PATH=`/`LD_*`/`BASH_ENV`) `[best-effort]` | here-string, procsub, funsub, command-sub launch, renamed/glob entrypoint | OS container | `test:fold23-envprefix` |
| Interpreter `-c`/`-e` bodies + exotic writers (`python -c`, `tar`, un-enumerated interpreters) `[best-effort]` | program-internal writes the argv walker can't see | OS container | `test:escape-classes`, `test:fold27-interp-flags` |
| Redirect / fd tokenizer shapes (word-glued `>`, named/multi-digit fd) `[best-effort]` | slip the redirect classifier | OS container | `test:fold26-redir-fd`, `test:fold30-multidigit-fd` |
| Broad-revert git (`pull`/`merge`/`reset --hard <ref>` with no floor pathspec) | allowed (no floor pathspec to key on) | witness floor-drift detection + OS container | `test:escape-classes`, `test:witness` |
| Git plumbing + git-config host-exec seams `[best-effort]` | `hash-object -w`/`update-ref`/`commit-tree`/`mktree` (unmodeled floor-write path); `filter.smudge/clean`, `textconv`, `merge.<driver>` execute host commands at worktree/merge seams | OS container + witness drift detection (the git wrapper neutralizes `core.hooksPath`/`fsmonitor`, not these) | `test:escape-classes` |
| bd done-edge laundering `[best-effort]` — the **direct** close-verb is denied (§1) | a `bash x.sh` containing `bd close`, `bd --db "…"`, backslash-newline splits, or `bd delete`/`bd edit` (non-close mutations) | OS container + human ledger triage | `test:fold25-bd-verb-deny`, `test:escape-classes` |
| Reconcile record-trust `[best-effort]` — `task/*`/`<ns>/*` are id-bound (§1) | the `feat/` override arm (ARM 3) trusts the agent-writable `record.branch` + an unsigned merge-commit anchor (the B2 residual) | the human merge | `test:fold13-reconcile` |
| The ratify **TTY gate** is an attendance signal, not proof of a human `[best-effort]` | a PTY-wrapped `ratify` evades the TTY check (the tokens stay non-forgeable, §1) | OS-confinement of unattended runs + human | `test:intake` |
| Container topology — read-only floor mounts (EROFS), dropped caps, unprivileged user; **workspace isolation, not egress control** (networked) | network egress, credential/GitHub-authority misuse, target mutation | the human merge | `test:fold32-topology` |
| The acceptance gate's own interpreter — a sandbox-shimmed `bash` could interpret the gate and forge a PASS `[best-effort]` | launch-time interpreter trust | it is a **quality** gate, not a boundary; container + human merge | `test:mechgate`, `test:fold17-integrity` |
| Finish-time path-pin / LD-strip hardening | — | — | `test:fold21-path-pin`, `test:fold22-ld-strip` |

## 3. DOES NOT CLAIM — deliberately out of scope

- **The sibling vault.** The floor makes **no** vault claim — vault **reads** and **absolute-path** vault
  **writes** are ALLOW; a relative `../my-vault/…` write denies only via the general `..`-unverifiable rule
  (not a vault claim). Read-only-**from-the-Forge** is a **convention**, not an enforced guarantee; the
  optional read-only resolver (`harness/vault.sh`, P7) is advisory + gate-blind. `[out-of-scope]` —
  `test:fold28-vault-out-of-scope`.
- **Network egress.** Not controlled by default — the container is networked (`FORGE_SANDBOX_NETWORK=bridge`;
  set `none` to restore container-level egress-deny). A networked container does not prevent exfiltration.
  `[out-of-scope]` (topology pinned by `test:fold32-topology`).
- **Secret-scanning depth.** A shallow regex, not a real scanner; novel token shapes pass. `[out-of-scope]`.
- **Launch-time interpreter / PATH trust and obfuscation.** Conceded to the container + human merge.
  `[best-effort]` — `test:fold23-envprefix`.
- **Witness scope.** The session witness hashes the **repo-local** floor only; it does not hash user-scope
  `~/.claude/settings.json` or managed-policy layers. `[out-of-scope]`.
- **The off-root / bypass / not-via-`run-task.sh` intersection.** A bypass session launched where
  `.claude/settings.json` isn't discovered and not driven through `run-task.sh` runs with neither the
  hook nor `permissions.deny` — the honest open limit; the witness makes a *privileged* op fail closed.
  `[open]`.
- **The target repo's own code correctness.** The harness gates the target's configured tests/lint, not the
  correctness of its source. `[out-of-scope]`.
- **Reviewer judgment quality.** Advisory and non-gating by design; severity ratings are unreliable. The
  human merge is the control. `[out-of-scope]`.

## Residual: floor→doc completeness `[open]`

`test:floor-claims` locks this doc **doc→test** (no cited suite is a ghost), **anti-silent-removal** (the
load-bearing mechanisms still exist in the deny hook), and the **vault-seam** (it names `fold28` and the deny
hook still makes no vault deny). It does **not** yet assert the reverse — that every `forge_check_*` in the
floor has an entry here — so a *new* deny rule added later without a doc entry is not caught (a deliberate v1
scope choice; a floor→doc completeness check is brittle). Audit this classification when the floor changes.

## See also

- [`limitations.md`](limitations.md) — the prose honest boundary (the reasoning, the full escape-shape
  detail, and the `[mech-mitigated]`/`[best-effort]`/`[out-of-scope]`/`[open]` residual discipline).
- [`architecture.md`](architecture.md) — the enforcement tier stack and the floor identity/witness.
- `tests/hooks/COVERAGE.md` — the line-level `deny path → run.sh assertion` map beneath these claims.
