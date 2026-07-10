# textstat — worked-example intake spec

> **Worked example.** This directory is a complete ratified intake packet — the artifact set the Forge
> produces between "fuzzy objective" and "minted beads": `spec.md` (this file), `understanding.md` (the
> Gate-A projection a human ratified), `restatement.md` (the reviewer consensus log), and
> `crosswalk.json` (local `T0NN` ids → minted `fx-xxx` bead ids, written by `intake.sh convert`). The
> lifecycle it walked: `intake.sh start` → one clarify round (then budget exhausted → flagged
> assumptions) → Gate-A restatement (one DISAGREE, reconciled) → `intake.sh ratify` → `intake.sh
convert` minted four beads → `run-task` built each in an isolated worktree → `finish` opened a PR per
> task → a human merged → `reconcile` closed the beads. The target repo `example-target` matches the
> entry in `harness/repos.config.example`; every id below is an example, nothing here is live.

## Header

- **Objective:** Add a small text-statistics utility (`textstat`) to `example-target`: line, word, and
  character counts for UTF-8 text, usable on a file operand and in shell pipelines.
- **Target Repo(s):** `example-target`
- **Mode:** interactive
- **Status:** approved

---

## User Scenarios

### US1 (P1) — Count a file's lines, words, and characters

As a developer in `example-target`, I want a `textstat` command that reports line, word, and character
counts for a text file, so that I can check fixture and corpus sizes without leaving the repo's
toolchain.

- **Independent Test:** Run `textstat` on a checked-in fixture file; the three reported counts equal the
  fixture's reference counts.
- **Acceptance Scenarios:**
  1. **Given** a UTF-8 file with known content, **When** `textstat <file>` runs, **Then** it prints the
     file's line, word, and character counts and exits 0.
  2. **Given** a path that does not exist, **When** `textstat <path>` runs, **Then** it exits non-zero
     with a one-line diagnostic naming the path and prints no counts.
- **Edge Cases:**
  - Empty file → counts are `0 0 0`, exit 0 (valid input, not an error — see Assumptions).
  - A final line without a trailing newline still counts as a line.
  - Input that is not valid UTF-8 → rejected loudly per FR-002.

### US2 (P2) — Compose in shell pipelines

As a developer, I want `textstat` to read standard input when no file operand is given, so that I can
pipe generated text through it.

- **Independent Test:** Piping known content produces the same counts as the file-operand form for
  identical content.
- **Acceptance Scenarios:**
  1. **Given** content on stdin and no file operand, **When** `textstat` runs, **Then** the counts equal
     the file-operand counts for the same bytes.
- **Edge Cases:**
  - stdin closed with no data → `0 0 0`, exit 0.

### US3 (P3) — Machine-readable output

As a script author, I want `textstat --json`, so that downstream tooling parses counts without scraping
human-oriented text.

- **Independent Test:** `--json` output parses as a JSON object with the three integer fields.
- **Acceptance Scenarios:**
  1. **Given** a valid input, **When** `textstat --json` runs, **Then** stdout is exactly one JSON
     object `{"lines": n, "words": n, "chars": n}`.
- **Edge Cases:**
  - Error under `--json` → diagnostic on stderr, no partial JSON on stdout (FR-002 applies unchanged).

---

## Requirements

- **FR-001:** System **MUST** report the line, word, and character counts of a UTF-8 text file named by
  a single file operand. _(US1)_
- **FR-002:** System **MUST** exit non-zero with a one-line diagnostic naming the input when the operand
  is missing, unreadable, or not valid UTF-8 — and **MUST NOT** print partial counts. _(US1)_
- **FR-003:** System **MUST** read standard input to EOF when invoked without a file operand, and report
  the same counts the file form would for identical content. _(US2)_
- **FR-004:** System **MUST**, under `--json`, emit exactly one JSON object with integer fields `lines`,
  `words`, `chars` — and nothing else — on stdout. _(US3)_
- **FR-005:** System **MUST** count characters as Unicode code points — not bytes, not grapheme
  clusters. See `[ASSUMED · functional-correctness · confidence:med]` in Assumptions. _(US1)_
- **FR-006:** System **MUST** count words as maximal runs of non-whitespace characters (resolved in
  Clarifications Round 1). _(US1)_
- **FR-007:** System **SHOULD** process inputs of at least 100 MB without memory growth proportional to
  input size. _(US1)_

---

## Success Criteria

- **SC-001:** 100% of the counting fixtures (ASCII, multi-byte UTF-8, empty, no-trailing-newline) report
  counts equal to their reference values; 0 mismatches.
- **SC-002:** For every error fixture (missing path, unreadable path, invalid UTF-8), the exit code is
  non-zero, exactly one diagnostic line names the input, and stdout carries no counts.
- **SC-003:** For identical content, the stdin form and the file-operand form report identical counts on
  100% of fixtures.
- **SC-004:** 100% of `--json` outputs parse as JSON and carry the same three counts as the plain form
  for the same input.

---

## Assumptions

- `[ASSUMED · functional-correctness · confidence:med]` "Characters" are Unicode code points — not
  bytes, not grapheme clusters. **Chosen because** code points are deterministic across platforms and
  need no segmentation tables. **Discarded:** byte counts (encoding-dependent, surprising for UTF-8);
  grapheme clusters (require Unicode segmentation data — a dependency this intake refuses).
  _(propagated to FR-005, SC-001)_ — this ambiguity surfaced after the intake's one-round clarify
  budget (`INTAKE_CLARIFY_ROUNDS=1`) was spent, so it routed here as a flagged assumption for the
  ratify gate instead of a second question (the budget bounds questions, never coverage — route, never
  drop).
- `[ASSUMED · dependency-supply-chain · confidence:med]` The utility uses the language standard library
  only — zero new runtime dependencies. **Chosen because** counting needs no third-party capability and
  every new dependency widens the supply-chain surface. **Discarded:** a Unicode segmentation library
  (only needed for grapheme counting, which was not chosen). _(propagated to T001 scope; see Deferrals)_
- Empty input is valid input: counts are `0 0 0` and the exit code is 0. Deliberate, no clarification
  round needed. _(propagated to US1/US2 Edge Cases)_
- `[VAULT-PROPOSAL · cli-conventions]` Every CLI in `example-target` reads stdin when invoked without a
  file operand. **Bead draft:** title "vault: record the stdin-fallback CLI convention" — body: FR-003's
  behaviour generalized to a repo-wide convention, so future intakes inherit it instead of re-clarifying
  it. (The Architect never writes the vault; a human mints this bead.)

---

## Deferrals / Out of scope

The **coverage ledger**: every canonical category from `harness/intake-categories.json` appears exactly
once with one of the three legal dispositions (**covered by FR-NNN**, **deliberately N/A — reason**, or
**surfaced — ref**), so an omission is a ratifiable decision, not an invisible gap. Breadth is cheap —
most categories are `deliberately N/A` for a change this small.

> **Catastrophic-tier note (G3):** the following `by-default` categories were consciously de-escalated
> for this intake by a human via `intake.sh risk --remove <id>` — a stateless, offline, read-only text
> utility gives them no surface, so their `deliberately N/A` dispositions below are legal at the ratify
> floor: `data-migration-schema-evolution`, `ml-training-data-provenance`, `concurrency-consistency`, `authorization-access-control`, `confidentiality`, `data-privacy`, `identity-auth-session`, `integrity`, `resistance`, `secrets-key-management`, `tenancy-isolation`, `ml-output-safety-guardrails`, `backup-disaster-recovery`, `data-residency-sovereignty`, `data-retention-lifecycle`, `library-licensing-attribution`, `ml-bias-fairness`, `regulatory-compliance-consent`.

**Scope & Intent**

- `competitive-differentiation` — deliberately N/A — internal utility; no market positioning.
- `completion-signals-acceptance` — covered by SC-001, SC-002, SC-003, SC-004.
- `functional-appropriateness` — covered by FR-001 — counting is the entire capability; nothing extraneous.
- `functional-completeness` — covered by FR-001, FR-002, FR-003, FR-004, FR-005, FR-006, FR-007.
- `functional-correctness` — surfaced — [ASSUMED · functional-correctness · confidence:med].
- `functional-scope-behaviour` — covered by FR-001, FR-003, FR-004.
- `misc-placeholders` — deliberately N/A — no unresolved placeholders remain in this spec.
- `solution-generality` — deliberately N/A — deliberately single-purpose; a general text-analysis framework is out of scope.
- `target-audience-stakeholders` — deliberately N/A — developers working inside `example-target`; no external users.

**Domain & Data**

- `data-lineage-provenance` — deliberately N/A — no data is stored or transformed for downstream use.
- `data-migration-schema-evolution` — deliberately N/A — no persistent schema exists or is created.
- `data-model-domain` — deliberately N/A — three integer counts; no domain entities.
- `data-quality-validation` — covered by FR-002 — input that is not valid UTF-8 is rejected loudly.
- `late-duplicate-out-of-order` — deliberately N/A — no event streams.
- `ml-training-data-provenance` — deliberately N/A — no ML component.
- `offline-sync-conflict-resolution` — deliberately N/A — no sync; the tool is offline by construction.
- `persistence-storage-choice` — deliberately N/A — nothing persists; the tool writes only to stdout/stderr.
- `source-schema-drift` — deliberately N/A — input is free-form text; there is no schema to drift.
- `state-management` — deliberately N/A — single pass over input; no state survives the invocation.
- `time-zones-clock` — deliberately N/A — no timestamps or clocks anywhere in scope.

**Interfaces & Integration**

- `api-contract-versioning` — deliberately N/A — no network API.
- `cli-exit-code-contract` — covered by FR-002 — zero on success, non-zero with a one-line diagnostic on any failure.
- `cli-stdio-piping-contract` — covered by FR-003 (answered in Clarifications Round 1).
- `co-existence` — deliberately N/A — touches no other tool's state; output goes to stdout only.
- `eventing-messaging-async` — deliberately N/A — synchronous single pass; no events.
- `integration-external-dependencies` — deliberately N/A — no external services; offline by construction.
- `public-api-surface-semver` — covered by FR-004 — the JSON keys `lines`, `words`, `chars` are the machine contract; evolution is additive-only.

**UX & Interaction**

- `appropriateness-recognizability` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `assistive-accessibility` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `cli-arg-flag-ux` — covered by FR-001, FR-003, FR-004 — one operand, one flag, stdin fallback.
- `human-factors-ergonomics` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `inclusivity` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `internationalization-localization` — deliberately N/A — output is numeric; FR-005 pins counting semantics independent of locale.
- `learnability` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `motion-animation-design` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `operability` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `progressive-enhancement-graceful-degradation` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `reduced-motion-accessibility` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `responsive-multi-viewport` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `sdk-developer-experience` — deliberately N/A — CLI only; no exported library API in this intake.
- `self-descriptiveness` — deliberately N/A — the flag surface is a single `--json`; `--help` text follows the target repo's CLI conventions.
- `ui-consistency` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `ui-responsiveness` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `user-assistance` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `user-engagement-aesthetics` — deliberately N/A — non-interactive CLI; no visual or interactive surface.
- `user-error-protection` — covered by FR-002 — errors are loud, named, and never yield partial counts.
- `ux-interaction-flow` — deliberately N/A — non-interactive CLI; no visual or interactive surface.

**Content & Brand**

- `brand-voice-editorial-consistency` — deliberately N/A — no content or brand surface.
- `content-design-information-architecture` — deliberately N/A — no content or brand surface.
- `content-model-structure` — deliberately N/A — no content or brand surface.
- `content-source-fidelity` — deliberately N/A — no content or brand surface.
- `content-versioning` — deliberately N/A — no content or brand surface.
- `conversion-tracking-experimentation` — deliberately N/A — no content or brand surface.
- `developer-docs-examples` — deliberately N/A — usage is one line; documented per the target repo's README conventions on merge.
- `editorial-publishing-workflow` — deliberately N/A — no content or brand surface.
- `seo-discoverability` — deliberately N/A — no content or brand surface.
- `terminology-consistency` — deliberately N/A — no content or brand surface.
- `visual-brand-consistency` — deliberately N/A — no content or brand surface.

**Quality: Performance & Efficiency**

- `caching-strategy` — deliberately N/A — nothing to cache.
- `capacity` — covered by FR-007 — 100 MB input floor.
- `data-freshness-completeness-sla` — deliberately N/A — no data pipeline.
- `ml-inference-latency-cost` — deliberately N/A — no ML component.
- `resource-utilization` — covered by FR-007 — memory must not grow with input size.
- `throughput` — deliberately N/A — single invocation; FR-007 is the only resource bound.
- `time-behaviour-latency` — deliberately N/A — batch tool with no latency target.
- `web-vitals` — deliberately N/A — no web surface.

**Quality: Reliability & Resilience**

- `availability` — deliberately N/A — not a service.
- `concurrency-consistency` — deliberately N/A — stateless single-threaded pass; no shared state.
- `edge-cases-failure-handling` — covered by FR-002 and the US1/US2 edge cases (empty input, no trailing newline, invalid UTF-8).
- `fault-tolerance` — deliberately N/A — fail-loud is the chosen behaviour (FR-002); no degraded mode.
- `faultlessness` — covered by SC-001 — 100% fixture parity, zero tolerated mismatches.
- `idempotency-retries` — deliberately N/A — read-only; re-running is naturally idempotent.
- `link-integrity` — deliberately N/A — no links.
- `ml-eval-metrics` — deliberately N/A — no ML component.
- `ml-robustness-ood` — deliberately N/A — no ML component.
- `predictability-determinism` — covered by FR-005, FR-006 — pinned counting semantics make output a pure function of input.
- `rate-limiting-backpressure` — deliberately N/A — no inbound callers.
- `recoverability` — deliberately N/A — stateless; nothing to recover.

**Quality: Security**

- `accountability` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `authenticity` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `authorization-access-control` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `confidentiality` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `data-privacy` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `identity-auth-session` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `integrity` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `non-repudiation` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `resistance` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `secrets-key-management` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.
- `tenancy-isolation` — deliberately N/A — local, read-only, offline; no auth, secrets, tenancy, or network surface.

**Quality: Safety**

- `fail-safe` — deliberately N/A — no physical, ML, or user-facing safety surface.
- `hazard-warning` — deliberately N/A — no physical, ML, or user-facing safety surface.
- `ml-output-safety-guardrails` — deliberately N/A — no ML component.
- `operational-constraint` — deliberately N/A — no physical, ML, or user-facing safety surface.
- `risk-identification` — deliberately N/A — no physical, ML, or user-facing safety surface.
- `safe-integration` — deliberately N/A — no physical, ML, or user-facing safety surface.
- `trust-safety-abuse-moderation` — deliberately N/A — no physical, ML, or user-facing safety surface.

**Quality: Maintainability & Flexibility**

- `adaptability` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `analysability` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `browser-device-compat` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `cli-shell-os-compat` — deliberately N/A — runs wherever the target repo's toolchain runs; no additional OS matrix.
- `configurability` — deliberately N/A — no configuration surface; one flag.
- `dependency-footprint` — deliberately N/A — zero new runtime dependencies (see Assumptions).
- `extensibility` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `installability` — deliberately N/A — ships inside the target repo; no separate install.
- `modifiability` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `modularity` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `packaging-distribution` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `portability` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `replaceability` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `reusability` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `scalability` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `serviceability` — deliberately N/A — one small module inside the target repo's existing toolchain.
- `testability` — covered by every task's `dod_tests` — whole-file selectors under `tests/textstat/`.

**Operational & Lifecycle**

- `analytics-instrumentation` — deliberately N/A — no service to operate; rides the target repo's existing CI and release path.
- `backfill-reprocessing` — deliberately N/A — no service to operate; rides the target repo's existing CI and release path.
- `backup-disaster-recovery` — deliberately N/A — stateless; nothing to back up.
- `build-ci-cd` — deliberately N/A — rides the target repo's existing test gate; no pipeline change.
- `deployment-infrastructure` — deliberately N/A — no service to operate; rides the target repo's existing CI and release path.
- `documentation-runbooks` — deliberately N/A — no runbook; nothing to operate.
- `environments-configuration` — deliberately N/A — no service to operate; rides the target repo's existing CI and release path.
- `feature-flagging` — deliberately N/A — no service to operate; rides the target repo's existing CI and release path.
- `infra-idempotent-provisioning` — deliberately N/A — no service to operate; rides the target repo's existing CI and release path.
- `infra-state-drift-detection` — deliberately N/A — no service to operate; rides the target repo's existing CI and release path.
- `ml-drift-monitoring` — deliberately N/A — no ML component.
- `ml-reproducibility` — deliberately N/A — no ML component.
- `observability-telemetry` — deliberately N/A — diagnostics go to stderr (FR-002); no telemetry.
- `regression-safety-change-isolation` — covered by the task `scope` boundary — the acceptance gate rejects any diff outside `src/textstat/**` and `tests/textstat/**`.
- `rollout-rollback-release-strategy` — deliberately N/A — one additive PR per task; rollback is `git revert`.
- `testing-strategy-test-data` — covered by every task's `definition_of_done` — test-first, with fixtures under `tests/textstat/`.

**Constraints, Risk & Governance**

- `cli-config-precedence` — deliberately N/A — no config file, no environment variables.
- `constraints-tradeoffs` — deliberately N/A — the one live tradeoff (code points vs bytes vs graphemes) is recorded in ## Assumptions.
- `cost-budget` — deliberately N/A — no regulatory, cost, or governance constraint for a local text utility.
- `data-residency-sovereignty` — deliberately N/A — input never leaves the host.
- `data-retention-lifecycle` — deliberately N/A — the tool writes nothing.
- `dependency-supply-chain` — surfaced — [ASSUMED · dependency-supply-chain · confidence:med].
- `implementation-requirements` — surfaced — Clarifications Round 1 (target repo's existing toolchain and test gate).
- `library-licensing-attribution` — deliberately N/A — zero new dependencies; nothing to attribute.
- `ml-bias-fairness` — deliberately N/A — no ML component.
- `ml-explainability` — deliberately N/A — no ML component.
- `physical-requirements` — deliberately N/A — no regulatory, cost, or governance constraint for a local text utility.
- `regulatory-compliance-consent` — deliberately N/A — no regulatory, cost, or governance constraint for a local text utility.
- `static-vs-dynamic-hosting-model` — deliberately N/A — not hosted.

## Clarifications

### Round 1 — 2026-01-15

- **Q (functional-scope-behaviour):** What is a "word" — a whitespace-delimited run, or a locale-aware
  token? → **A:** A maximal run of non-whitespace characters; Unicode whitespace delimits. _(propagated
  to FR-006, SC-001)_
- **Q (cli-stdio-piping-contract):** With no file operand, should the tool error out or read stdin? →
  **A:** Read stdin to EOF — the tool must compose in pipelines. _(propagated to FR-003, US2)_
- **Q (implementation-requirements):** Standalone script, or part of the target repo's toolchain? →
  **A:** Inside `example-target`'s existing language and test gate; no new toolchain. _(propagated to
  the Task Breakdown `scope` and `dod_tests`)_

---

## Task Breakdown

Four tasks, one PR each. `T001` is the counting core; the other three fan out from it and can build in
parallel once it merges. The JSON between the sentinels is the machine contract `intake.sh convert`
reads to mint beads — the converter validated it (all nine invariants), minted `fx-` beads in
topological order, and recorded the mapping in `crosswalk.json` beside this spec.

<!-- forge:tasks:begin v1 -->

```json
{
  "spec_version": "forge/v1",
  "target_repos": ["example-target"],
  "tasks": [
    {
      "id": "T001",
      "title": "Count lines, words, and characters of a UTF-8 file operand",
      "satisfies": ["FR-001", "FR-005", "FR-006", "FR-007", "US1"],
      "priority": "P1",
      "depends_on": [],
      "target_repo": "example-target",
      "definition_of_done": [
        "A failing test asserts the reference fixture's line/word/character counts are reported exactly; it then passes.",
        "Code-point and word-boundary semantics (FR-005, FR-006) are each pinned by a dedicated multi-byte fixture.",
        "A generated 100 MB input completes without memory growth proportional to input size (FR-007)."
      ],
      "success_criteria": [
        "SC-001",
        "Peak resident memory stays flat (within 10%) between a 1 MB and a 100 MB input."
      ],
      "scope": ["src/textstat/**", "tests/textstat/**"],
      "dod_tests": ["tests/textstat/run.sh"],
      "sc_evidence": [
        { "sc": 1, "path": "tests/textstat/evidence/t001-sc1-fixture-counts.txt" },
        { "sc": 2, "path": "tests/textstat/evidence/t001-sc2-memory-bound.txt" }
      ],
      "verification": "run tests/textstat/run.sh and assert the counting cases exit 0 with reference counts"
    },
    {
      "id": "T002",
      "title": "Fail loudly on a missing, unreadable, or non-UTF-8 operand",
      "satisfies": ["FR-002", "US1"],
      "priority": "P1",
      "depends_on": ["T001"],
      "target_repo": "example-target",
      "definition_of_done": [
        "A failing test asserts a missing operand exits non-zero, names the path in one diagnostic line, and prints no counts; it then passes.",
        "Unreadable-file and invalid-UTF-8 fixtures are rejected the same way."
      ],
      "success_criteria": ["SC-002"],
      "scope": ["src/textstat/**", "tests/textstat/**"],
      "dod_tests": ["tests/textstat/run.sh"],
      "sc_evidence": [
        { "sc": 1, "path": "tests/textstat/evidence/t002-sc1-error-transcripts.txt" }
      ],
      "verification": "run tests/textstat/run.sh and assert the error cases exit non-zero with empty stdout"
    },
    {
      "id": "T003",
      "title": "Read stdin to EOF when no file operand is given",
      "satisfies": ["FR-003", "US2"],
      "priority": "P2",
      "depends_on": ["T001"],
      "target_repo": "example-target",
      "definition_of_done": [
        "A failing test pipes fixture content on stdin and asserts counts identical to the file-operand form; it then passes.",
        "Empty stdin yields 0 0 0 with exit 0."
      ],
      "success_criteria": ["SC-003"],
      "scope": ["src/textstat/**", "tests/textstat/**"],
      "dod_tests": ["tests/textstat/run.sh"],
      "sc_evidence": [{ "sc": 1, "path": "tests/textstat/evidence/t003-sc1-stdin-parity.txt" }],
      "verification": "pipe a fixture through the CLI and diff against the file-operand output"
    },
    {
      "id": "T004",
      "title": "Emit a stable JSON object under --json",
      "satisfies": ["FR-004", "US3"],
      "priority": "P3",
      "depends_on": ["T001"],
      "target_repo": "example-target",
      "definition_of_done": [
        "A failing test parses the --json output and asserts integer fields lines/words/chars equal the plain form; it then passes.",
        "On error, stdout carries no partial JSON (the diagnostic goes to stderr)."
      ],
      "success_criteria": ["SC-004"],
      "scope": ["src/textstat/**", "tests/textstat/**"],
      "dod_tests": ["tests/textstat/run.sh"],
      "sc_evidence": [{ "sc": 1, "path": "tests/textstat/evidence/t004-sc1-json-roundtrip.txt" }],
      "verification": "parse the --json output and compare fields to the plain-form counts"
    }
  ]
}
```

<!-- forge:tasks:end -->
