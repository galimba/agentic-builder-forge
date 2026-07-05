# Spec Template — Intake Artifact

> The intake artifact for the Forge. An Architect agent turns a fuzzy objective into this spec —
> prioritized stories, testable requirements, measurable success criteria — and then into a
> machine-parseable **Task Breakdown** that a deterministic converter reads to mint beads. Derives from
> Spec-Driven Development patterns (GitHub Spec Kit), reimplemented thin: _boilerplate, not framework_.
> This is the **input** artifact; it feeds the `bd` ledger.

## How to use this template

`harness/intake.sh start` scaffolds this template into `specs/NNN-<slug>/spec.md` and fills the Header
(Objective, Target Repo(s), Mode, Status). The Architect (`.claude/agents/architect.md`) authors the
rest: fill every `[PLACEHOLDER]`, and wherever the objective is silent leave a `[NEEDS CLARIFICATION:
<question>]` marker — the `spec-authoring` skill carries the clarify discipline (interactive resolves
with the human; autonomous records a flagged `[ASSUMED …]` for the merge gate). The `decompose` skill
fills the **Task Breakdown**. Gate A then produces a companion `understanding.md` (a projection of the completed FR set) beside this spec; a human ratifies it (`intake.sh ratify`) before decomposition. Keep prose human-facing; keep the Task Breakdown JSON machine-parseable. A
human approves the spec before any bead is minted.

Conventions: ATX headings, no emoji, **bold** for emphasis, `backticks` for ids/paths/flags. Requirement
ids are stable once assigned — never renumber; mark withdrawn items `~~FR-007~~ (withdrawn)`.

---

## Header

- **Objective:** [PLACEHOLDER — one or two sentences: the outcome wanted, in the user's words.]
- **Target Repo(s):** [PLACEHOLDER — repo slug(s), e.g. `example-target`. Must match `target_repos` in the Task Breakdown.]
- **Mode:** [`interactive` | `autonomous`]
- **Status:** [`draft` | `clarifying` | `ready-for-tasks` | `approved`]

---

## User Scenarios

Prioritized user stories. **P1** = must-have for the objective to be meaningful; **P2** = important but
deferrable; **P3** = nice-to-have. Each story is an independently-testable slice (vertical, not a
horizontal layer). Story ids (`US1`, `US2`, …) are stable and referenced by tasks.

### US1 (P1) — [Story title]

[As a `<role>`, I want `<capability>`, so that `<benefit>`.]

- **Independent Test:** [What single observable behaviour proves _this story alone_ works, with nothing
  else built? This becomes (or informs) the closing task's Definition of Done.]
- **Acceptance Scenarios:**
  1. **Given** [precondition], **When** [action], **Then** [observable outcome].
  2. **Given** […], **When** […], **Then** […].
- **Edge Cases:**
  - [What happens when [boundary / empty / failure]? `[NEEDS CLARIFICATION: …]` if silent.]

### US2 (P2) — [Story title]

[Repeat the structure above. Add US3, US4… as needed. Not every spec needs P2/P3 stories.]

---

## Requirements

Functional requirements, each phrased as an imperative the system must satisfy. Use `[NEEDS
CLARIFICATION: …]` inline wherever the objective does not pin a behaviour down. Each requirement should
be testable and trace to at least one story.

- **FR-001:** System **MUST** [specific, testable behaviour]. _(US1)_
- **FR-002:** System **MUST** [specific, testable behaviour]. _(US1)_
- **FR-003:** System **MUST** [behaviour] `[NEEDS CLARIFICATION: which auth method — session token,
OAuth, API key?]`. _(US2)_
- **FR-004:** System **SHOULD** [behaviour that is desirable but not load-bearing]. _(US2)_

> Phrasing: **MUST** for load-bearing requirements, **SHOULD** for strong-but-optional. Avoid HOW — state
> _what_ must be true, not which library/file/algorithm delivers it (see the WHAT/WHY-not-HOW discipline
> in the `decompose` skill).

---

## Success Criteria

Measurable, technology-agnostic outcomes that prove the objective is met. **No** framework, library, or
file names. Prefer numeric thresholds or directly observable outcomes. Each `SC-NNN` is referenced by
tasks and is the yardstick a human uses at the merge gate.

- **SC-001:** [Measurable outcome, e.g. "95% of submissions complete in under 2 seconds end-to-end."]
- **SC-002:** [Measurable outcome, e.g. "A first-time user completes the primary flow without external
  help in under 3 minutes."]
- **SC-003:** [Measurable outcome, tech-agnostic.]

> A criterion is good only if two people would agree on pass/fail by measuring, without reading the code.
> See worked examples in the `decompose` skill.

---

## Assumptions

Decisions taken where the objective was silent. In **autonomous** mode the Architect records its
best-guess answers here (the clarify discipline; see the `spec-authoring` skill), each flagged for the
human approval gate:

- `[ASSUMED · <canonical-id> · confidence:low|med]` [The assumed answer.] **Chosen because** [rationale].
  **Discarded:** [the alternatives not taken]. _(propagated to FR-00X / SC-00X)_ — `<canonical-id>` is a
  category `id` from `harness/intake-categories.json`; this assumption is the category's `surfaced —` ledger entry.
- [Plain assumptions the author made deliberately, without a clarification round, also go here.]
- `[VAULT-PROPOSAL · <area>]` [A durable decision that belongs in the read-only vault.] **Bead draft:**
  [the title + body a human would mint to land this in the vault — the Architect never writes the vault.]

---

## Deferrals / Out of scope

The **coverage ledger**, made visible for the Gate-A human review (F7). Every **canonical category** — the set
in `harness/intake-categories.json` (`id` + `name` + `cluster`), the single machine-readable source the clarify
skill and the spec-reviewer also defer to — appears **exactly once**, by its canonical `id`, carrying one of the
three F2 dispositions. An omission is then a _ratifiable decision_, not an invisible gap. One line each;
defaults are pre-fillable (most categories are `deliberately N/A` for any given build — breadth is cheap).

The three legal dispositions (F2 vocabulary — do **not** use a bare category-level "deferred"):

- `<canonical-id>` — **covered by FR-NNN** (an FR / SC / edge case exists), or
- `<canonical-id>` — **deliberately N/A — <reason>** (consciously skipped or not applicable), or
- `<canonical-id>` — **surfaced — <ref>** (a `## Clarifications` answer or a flagged `[ASSUMED …]`).

Examples:

- `data-model-domain` — covered by FR-003, FR-004.
- `assistive-accessibility` — deliberately N/A — this change is a non-interactive CLI flag.
- `competitive-differentiation` — surfaced — [ASSUMED · competitive-differentiation · confidence:med].

## Clarifications

Append-only log of resolved ambiguities — **one `### Round N` entry per clarify round** (one
`AskUserQuestion` call). Each answer is _also_ written into the live spec section above (and its
`[NEEDS CLARIFICATION]` marker removed). The round budget bounds questions, never coverage (F1); see the
`clarify` skill for the protocol.

### Round 1 — YYYY-MM-DD

- **Q (data model):** [question asked] → **A:** [chosen answer]. _(propagated to FR-003, SC-002)_
- **Q (edge cases):** [question asked] → **A:** [chosen answer]. _(propagated to US1 Edge Cases)_

---

## Task Breakdown

The **machine-parseable contract**. A deterministic converter (bash + `jq`) slices the block between the
sentinels below, strips the code fence, and pipes the JSON to `jq` to mint beads. The sentinels make
extraction unambiguous even if other ` ```json ` blocks appear elsewhere in this spec. **Do not** edit the
sentinel lines. There is exactly one task block per spec.

This block is the **single source of truth** for tasks — there is no parallel human-maintained task list
to drift from. The prose sections above carry the _what/why_; this block carries the _machine contract_.

### Field schema (per task)

| field                | type     | rule                                                                                                                                                                                                                    |
| -------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`                 | string   | `^T[0-9]{3}$`; unique within this spec. **Local** id — _not_ the bead id (bead ids are minted as `fx-xxx`).                                                                                                             |
| `title`              | string   | imperative one-liner; becomes the bead title.                                                                                                                                                                           |
| `satisfies`          | string[] | ≥1 entry; each matches `FR-[0-9]{3}` or a story id like `US1`. Traceability to requirements/stories.                                                                                                                    |
| `priority`           | string   | one of `P1`, `P2`, `P3`. Maps to the bead numeric priority (see _Bridge to `bd`_ below).                                                                                                                                |
| `depends_on`         | string[] | local task ids (e.g. `["T001"]`); may be empty `[]`; the graph **MUST** be acyclic.                                                                                                                                     |
| `target_repo`        | string   | the repo this task lands in; **MUST** be one of the top-level `target_repos`.                                                                                                                                           |
| `definition_of_done` | string[] | ≥1 binary, checkable condition for **this** task. Includes a test that fails first, then passes (test-first gate).                                                                                                      |
| `success_criteria`   | string[] | ≥1 measurable + technology-agnostic criterion; may reference an `SC-NNN` from above or state an inline threshold.                                                                                                       |
| `scope`              | string[] | ≥1 entry; each a repo-relative **glob** (POSIX pattern) naming the files this task's build may touch. Format is normative (below); validated by invariant 7; enforced by the mechanical acceptance gate (diff ⊆ scope). |
| `dod_tests`          | string[] | runnable **test selectors** — the mechanical Definition of Done, not prose. MUST be present as an array; may be `[]` when a non-test `sc_evidence` `assert` is the proof (the ≥1-mechanical-proof rule, P6a). Grammar is normative (below); validated syntactically by invariant 8; executed by the acceptance gate, never by `analyze`.  |
| `sc_evidence`        | object[] | ≥1 entry; each `{"sc": N, "path": "<file>"}` with an **optional** nested `"assert": {"kind": "contains\|absent\|sha256", "value": "<literal\|64-hex>"}` — `N` a **1-based index** into this task's `success_criteria`, `path` the repo-relative file where that criterion's evidence will land, `assert` a **non-test mechanical proof** the gate checks over the staged blob (grammar below). Bidirectional (invariant 9).       |
| `verification`       | string   | optional but recommended: the test or command that proves the DoD (the red→green hook).                                                                                                                                 |

The free-text fields stay: `definition_of_done` and `success_criteria` are what the human reads at the
Gate A′ breakdown sign-off. The three machine fields (`scope`, `dod_tests`, `sc_evidence`) are what the
mechanical acceptance gate enforces. `scope` is always required. The mechanical Definition of Done is
now **≥1 mechanical proof**: a non-empty `dod_tests` **or** ≥1 `sc_evidence` entry carrying an `assert`
(P6a) — `dod_tests` MUST still be present as an array, `[]` when the proof is a non-test `assert`.
Neither the scope boundary nor the proof substitutes for the other.

### Selector and glob formats (normative)

Invariants 7 and 8 validate **exactly** these formats — the definitions here and the checks in
`harness/intake.sh` `cmd_analyze` must never diverge.

A **scope glob** is repo-relative and fail-closed:

- non-empty; must **not** start with `/` (no absolute paths);
- must **not** contain `..` anywhere (this rejects the whole `*..*` traversal class);
- characters limited to `A-Z a-z 0-9 . _ * ? [ ] / -` — no whitespace, no backslash, no `~`, no `$`,
  and no brace expansion (`{a,b}` is shell _expansion_, not pattern matching — the acceptance gate
  matches scope with POSIX patterns, where a brace would silently never match).
- Examples: `sandbox/example-target/**`, `tests/intake/run.sh`, `harness/*.sh`, `docs/file[0-9].md`.

A **`dod_tests` selector** is a `<path>` — a repo-relative runnable test file under `tests/` or
`sandbox/`, where `<path>` matches `^(tests|sandbox)(/[A-Za-z0-9][A-Za-z0-9._-]*)+$` (every path
segment starts alphanumeric — `..`, dotfiles, and option-shaped segments like `-rf` are all rejected).
Examples: `tests/intake/run.sh`, `sandbox/validator/run.sh`. Validation is **syntactic only** —
`analyze` is read-only and never executes a selector; the mechanical acceptance gate runs the whole
file.

An **`sc_evidence` path** is a repo-relative file path: non-empty, not absolute, no `..` anywhere,
matching `^[A-Za-z0-9][A-Za-z0-9._/-]*$`, and matched by ≥1 of this task's `scope` globs (so the
evidence the build creates is always stageable in-scope).

#### `sc_evidence` assert grammar (P6a, normative)

An `sc_evidence` entry MAY carry an optional `"assert": {"kind": <kind>, "value": <value>}` — a
**non-test mechanical proof** the gate checks in place of a `dod_tests` selector. It is the second way
a task satisfies the **≥1-mechanical-proof** rule (invariant 8): a non-empty `dod_tests` **or** ≥1
`sc_evidence` entry with an `assert`. This definition and the checks in `harness/intake.sh`
`cmd_analyze` (invariant 9) and `harness/accept-gate.sh` (C3) must never diverge — exactly as the three
formats above are pinned to `cmd_analyze`.

- `kind` is one of `contains`, `absent`, `sha256` — no other value is legal.
- `value` is **non-empty** in every case.
- For `contains` / `absent`, `value` is a **literal single-line substring**: matched with `grep -F`
  (fixed string, never a regex), **≤512 characters**, and **no control characters** (`[[:cntrl:]]`
  rejects them — including the embedded newline that would make it multi-line).
- For `sha256`, `value` is exactly **64 lowercase-hex** characters (`^[0-9a-f]{64}$`).

The acceptance gate runs a **fixed, gate-owned checker** over the **staged blob** (`git cat-file blob
:<path>`): `contains` / `absent` pipe it to `grep -F -q -e "$value"` (`contains` passes iff the literal
is present; `absent` passes iff it is provably absent — any read/grep error, timeout, or kill fails
closed), and `sha256` pipes it to `sha256sum` and compares. **No author-supplied code runs** — unlike a
`dod_tests` selector, which is a whole file the gate executes — so an assert is the safer proof. The
checker reads the **index** (staged, non-symlink, non-empty blob): a worktree-only evidence file is
**phantom** and fails at C3 before the assert is ever consulted, exactly as an assert-free `sc_evidence`
path does. Validation in `analyze` is **syntactic only** (like the invariant-8 selector grammar); the
gate's checker is bounded by the same `FORGE_MECHGATE_TIMEOUT` / kill-grace as a `dod_tests` selector.

#### Gate-side matching semantics (normative, both directions)

The acceptance gate (`harness/accept-gate.sh`) matches each staged path against each scope glob
as a POSIX shell case-pattern. Pinned semantics (machine-probed):

- `*` crosses `/` — `harness/*` matches `harness/a/b.sh`;
- `**` is equivalent to `*` (no globstar special-casing);
- `dir/**` does **not** match the bare `dir` entry itself;
- `?` is exactly one character; `[0-9]` classes work;
- matching is **literal and case-sensitive** — no expansion, no dotfile special-casing.

`dod_tests` selectors are executed by the gate as whole files (`timeout <T> bash <selector>`,
single argv, stdin `/dev/null`). The `::pattern` form is **rejected at Gate B** (`analyze`)
and by the gate (the pattern execution convention is not defined — use a whole-file selector). `sc_evidence` paths are
verified against the **index** (staged, non-symlink, non-empty blob) — a worktree-only file is
phantom evidence. This subsection and `harness/accept-gate.sh` must never diverge — exactly as
the formats above are pinned to `cmd_analyze`.

##### Degenerate (vacuous) scope globs — advisory

A scope glob is **vacuous** iff it consists **solely** of `*`, `?`, `/`, and bracket expressions
`[...]` — i.e. it contains no literal path character to constrain the boundary. Canonical
definition (the single source of truth the gate implements):

> A glob is vacuous iff it matches the POSIX ERE `^([*?/]|\[[^]]*\])+$`.

Examples (vacuous): `*`, `**`, `?*`, `*?`, `**/*`, `[a-z]*`, `[0-9]/[a-z]`. Non-examples
(constraining — every one carries a literal segment): `**/*.ts`, `sandbox/**`, `harness/*.sh`,
`docs/file[0-9].md`. A vacuous glob declares a scope that everything satisfies, so the boundary
does not constrain — but it is **NOT a validation error**: the acceptance gate records a
`scope-breadth-anomaly` **advisory** in the audit and the verdict is unaffected (advisory only,
never blocks). The gate's vacuous-glob test and this regex must never diverge.

### Validation invariants (fail-loud, jq-checkable)

The converter rejects the spec — loudly, no partial mint — unless **all** hold (mirrors the fail-loud jq
validation in `harness/board-sync.sh`):

1. Every task has all required keys: `id`, `title`, `satisfies`, `priority`, `depends_on`, `target_repo`,
   `definition_of_done`, `success_criteria`. (`verification` optional.)
2. `id` matches `^T[0-9]{3}$` and is unique across `tasks`.
3. `priority` ∈ `{P1, P2, P3}`.
4. Every entry in `depends_on` references an existing task `id`, and the dependency graph topologically
   sorts (no cycles).
5. `satisfies`, `definition_of_done`, and `success_criteria` are each non-empty.
6. `target_repo` ∈ top-level `target_repos`.
7. `scope` is a non-empty array; every entry is a well-formed repo-relative glob per the normative
   format above (no absolute path, no `..` anywhere, no empty string, no character outside the allowed
   set).
8. `dod_tests` is present as an array — possibly empty `[]`; every entry is a syntactically valid
   selector per the normative grammar above. Syntactic only — `analyze` never executes a test. **≥1
   mechanical proof:** a non-empty `dod_tests` **or** ≥1 `sc_evidence` entry carrying an `assert` (P6a).
   A task with an empty `dod_tests` and no assert has no mechanical Definition of Done and is rejected.
9. `sc_evidence` is a non-empty array of `{sc, path}` objects, **bidirectional**: every
   `success_criteria` index (1-based) is covered by ≥1 entry; every entry's `sc` resolves to a defined
   index; every `path` is a well-formed repo-relative file per the normative format above **and is
   matched by ≥1 `scope` glob** (an out-of-scope evidence path is unsatisfiable at the
   gate: C3 stages it, C1 rejects it). An entry MAY carry an optional `assert`, validated
   syntactically per the **assert grammar (P6a)** above; the acceptance gate runs its fixed checker
   over the staged blob (`analyze` never does).

> A reference jq predicate for invariant 2 (id uniqueness), illustrating the idiom:
> `jq -e '(.tasks | map(.id)) as $ids | ($ids | unique | length) == ($ids | length)'`

### Bridge to `bd` (locked — verified against the real binary, bd v1.0.4)

The conversion script lives in `harness/intake.sh` (`convert`); every mapping below is verified against
the live `bd` and fixture-pinned in `tests/intake/run.sh`:

- **Local ids → minted ids.** Bead ids are minted/hashed and unpredictable. The converter
  creates beads in **topological order** of `depends_on`, recording a `T0NN → fx-xxx` **crosswalk**
  (`crosswalk.json` beside this spec).
- **Dependencies resolved post-mint.** After all beads exist, the converter adds `blocks` edges by
  translating each `depends_on` local id through the crosswalk to the minted bead id (`bd dep add`).
- **Body fields (locked).** `title` → bead title; `definition_of_done` → `--acceptance`, landing in the
  bead's `.acceptance_criteria` (a native field — verified on the binary); `satisfies`,
  `success_criteria`, and `verification` → serialized into the bead body, with a `Source:` line naming
  this spec and the local task id.
- **Priority (locked).** `bd` accepts `P0–P4` natively (`-p P1` lands as numeric priority 1) — the
  spec's `P1/P2/P3` passes through unchanged; no mapping table.
- **`target_repo` (locked landing).** The spec **always carries** `target_repo` per task and
  `target_repos` at the top level. It lands on the bead as `.metadata.target_repo` via `--metadata`
  (JSON built with `jq --arg`, so spec content cannot inject) — never via `--repo`, which would invoke
  bd's own routing.

### The block

<!-- forge:tasks:begin v1 -->

```json
{
  "spec_version": "forge/v1",
  "target_repos": ["example-target"],
  "tasks": [
    {
      "id": "T001",
      "title": "Reject specs whose Task Breakdown fails schema validation",
      "satisfies": ["FR-001", "US1"],
      "priority": "P1",
      "depends_on": [],
      "target_repo": "example-target",
      "definition_of_done": [
        "A failing test asserts a spec with a duplicate task id is rejected; it then passes.",
        "Validation runs all nine invariants and exits non-zero on the first violation, naming the offending task id."
      ],
      "success_criteria": [
        "SC-001",
        "100% of the malformed-spec fixtures are rejected with a non-zero exit and a named offending id; 0 valid fixtures are rejected."
      ],
      "scope": ["sandbox/validator/**", "tests/intake/fixtures/specs/**"],
      "dod_tests": ["tests/intake/run.sh"],
      "sc_evidence": [
        { "sc": 1, "path": "sandbox/validator/evidence/sc1-fixture-verdicts.txt" },
        { "sc": 2, "path": "sandbox/validator/evidence/sc2-rejection-rates.txt" }
      ],
      "verification": "run the validator against tests/fixtures/specs/*.json and assert exit codes"
    },
    {
      "id": "T002",
      "title": "Mint beads from a validated Task Breakdown in dependency order",
      "satisfies": ["FR-002", "US1"],
      "priority": "P1",
      "depends_on": ["T001"],
      "target_repo": "example-target",
      "definition_of_done": [
        "A failing test asserts that a two-task spec with T002 depending on T001 mints beads such that the dependency edge resolves to the minted id; it then passes.",
        "A T0NN → fx-xxx crosswalk is emitted for the run."
      ],
      "success_criteria": [
        "Given a valid N-task spec, exactly N beads are minted and every depends_on edge resolves to a real minted bead id (0 dangling edges)."
      ],
      "scope": ["sandbox/converter/**"],
      "dod_tests": ["tests/intake/run.sh"],
      "sc_evidence": [{ "sc": 1, "path": "sandbox/converter/evidence/sc1-crosswalk-edges.txt" }],
      "verification": "mint from tests/fixtures/specs/two-task.json and assert the crosswalk + resolved edges"
    }
  ]
}
```

<!-- forge:tasks:end -->
