---
name: decompose
description: Turn a RATIFIED intake spec (post-Gate-A) into the machine-parseable Task Breakdown — tasks with binary DoD and measurable, tech-agnostic Success Criteria, plus the three machine fields (scope, dod_tests, sc_evidence) the mechanical gate enforces, traced to FR/stories, self-checked via the F8 adversarial coverage pass, then mechanically verified by the Gate-B analyze gate. Emits the spec's task block; does not mint beads.
---

# Decompose

> The **decompose** skill turns a ratified intake spec into the machine-parseable **Task Breakdown** —
> a set of tasks, each with a binary Definition of Done and a measurable, technology-agnostic Success
> Criterion, traced back to the requirements and stories that justify it. A thin reimplementation of
> Spec Kit's planning step — _boilerplate, not framework_. It **emits the spec's task block; it does not
> mint beads** — that boundary belongs to the deterministic converter.

## Purpose

Decompose runs **after Gate-A ratification**: its input is the **human-validated FR set** — the human has
signed `understanding.md` (`intake.sh ratify`), which binds a sha256 token to the projection of those FRs.
Read the objective and the ratified spec (stories, FR-NNN, SC-NNN, Assumptions) and produce the
`<!-- forge:tasks:begin -->` JSON block defined in `templates/spec-template.md`, conforming exactly to
its field schema and validation invariants. Stop at the spec — the converter mints beads later.

Because the token binds to the ratified content, the FR set is **frozen** while you decompose: if
decomposition reveals the FRs themselves must change, do not silently edit them — the human re-opens via
`intake.sh clarify` (which invalidates the token) and re-ratifies the new projection.

## WHAT/WHY-not-HOW discipline

Tasks state the **outcome** (the _what_) and trace to a requirement/story (the _why_) — never the
**implementation** (the _how_). The builder agent chooses HOW under the test-first gate, and is free to
reuse existing code; a task that prescribes files/libraries/algorithms forecloses that and tends to make
success unmeasurable.

- **DoD** = observable truth conditions for this task ("a failing test for X passes", "the endpoint
  returns the documented shape"), **not** steps ("edit `foo.ts` to add `bar()`").
- **Success Criteria** = measurable, technology-agnostic thresholds, **not** mechanisms.
- **Allowed exceptions** — these are _scope and proof declarations_, not implementation, and stay in
  the task: `target_repo` (which repo the work lands in), dependency ordering (`depends_on`), and the
  three machine fields `scope` (where the build may write), `dod_tests` (which named tests prove the
  DoD) and `sc_evidence` (where each criterion's evidence lands). Declaring a _boundary_ or a _proof
  location_ is not prescribing HOW the work inside it is done.

| Leaks HOW (avoid)                                    | States WHAT/WHY (use)                                                        |
| ---------------------------------------------------- | ---------------------------------------------------------------------------- |
| "Use `React.memo` to optimise the node list."        | "Dragging 100 nodes holds ≥ 55 fps with no dropped frames." _(SC)_           |
| "Add a `users` Postgres table with a `btree` index." | "A returning user is recognised by stable identity across sessions." _(FR)_  |
| "Wrap the fetch in a `try/catch` and log."           | "A failed upstream call surfaces a typed error; no silent fallback." _(DoD)_ |

## How stories map to tasks

- **Each story decomposes into ≥ 1 task.** A P1 story usually yields its tasks at `P1`; priority is
  inherited but may be refined per task.
- **Every task traces back.** `satisfies` carries ≥ 1 `FR-NNN` and/or story id — no orphan tasks.
- **Every FR is covered.** Each `FR-NNN` is satisfied by ≥ 1 task (an uncovered FR is a decomposition
  bug — and the Gate-B analyze gate rejects it mechanically).
- **The Independent Test becomes the closing task's proof.** A story's _Independent Test_ (from the spec)
  informs the DoD / `verification` of the task that completes that story.
- **Prefer vertical slices.** A task should deliver an independently-testable increment (one concern per
  commit — the Forge's grain), not a horizontal layer ("all the types", "all the styling") that can't be
  verified alone.
- **Order by dependency, not just priority.** `depends_on` encodes real prerequisites; the converter mints
  in topological order. A P2 task that unblocks a P1 task still comes first in the graph.

## Definition of Done vs Success Criteria

Both are required per task; they answer different questions.

|            | Definition of Done                                       | Success Criteria                                         |
| ---------- | -------------------------------------------------------- | -------------------------------------------------------- |
| Question   | "Is this task finished?"                                 | "Is the outcome good enough?"                            |
| Shape      | binary checklist, local to the task                      | measurable threshold, tech-agnostic                      |
| Scope      | this task only                                           | may be shared (references `SC-NNN`)                      |
| Test-first | **MUST** include "a test fails first, then passes"       | the metric the test/measurement asserts                  |
| Example    | "Validator exits non-zero on duplicate ids; test green." | "100% of malformed fixtures rejected, 0 valid rejected." |

Because the harness gates on red→green, **every** task's DoD includes a test that fails before the work
and passes after; `verification` names how that proof is run.

## The three machine fields

The free-text DoD/SC above are what the **human reads** at the Gate A′ breakdown sign-off. Each task
ALSO carries three **machine-checkable** fields — what the mechanical acceptance gate **enforces**.
Author all three for every task; Gate-B `analyze` rejects the block (invariants 7/8/9, offender named)
if any is missing or malformed. The exact grammars are normative in `templates/spec-template.md`
("Selector and glob formats") — author to them, not from memory.

- **`scope`** — repo-relative globs naming the files this task's build may touch. The gate checks the
  task branch's diff ⊆ `scope`. Declare the REAL write surface (e.g. `sandbox/<feature>/**` plus the
  test dir if the task adds tests); a too-narrow scope blocks the builder's legitimate diff, a
  repo-wide `**` scope makes the check vacuous — both are decomposition bugs. No absolute paths, no
  `..`, POSIX-pattern characters only (no `{a,b}` braces).
- **`dod_tests`** — named runnable test selectors, the mechanical Definition of Done: a `<path>`
  (a repo-relative test file under `tests/` or `sandbox/`). The gate runs each as a whole file
  (`timeout <T> bash <path>`); a `::pattern` form is rejected (pattern execution is not a defined
  convention). Every selector must name a test that exists when the task completes (the test-first
  gate's red→green test belongs here). Prose like "all tests pass" is not a selector.
- **`sc_evidence`** — one or more `{"sc": N, "path": "<file>"}` entries per task: `N` is the 1-based
  index into THIS task's `success_criteria`; `path` is the repo-relative file where that criterion's
  evidence will land — it MUST fall under this task's `scope`, so the build can create it
  in-scope. Bidirectional: every criterion needs ≥ 1 entry, every entry must resolve. The gate checks
  each path exists and is non-empty after the build.

## F8 — the adversarial coverage pass (run it BEFORE analyze)

A drafted breakdown that "looks complete" is the failure mode F8 exists to catch. After drafting the
block, attack your own decomposition with three questions — played to break it, not to confirm it:

1. **Per FR — "delete the task."** For each `FR-NNN`: which task, if deleted, would leave this FR
   satisfied by nothing? If you cannot name one, the FR is uncovered _now_ (its only "coverage" is
   incidental). Add or sharpen a task.
2. **Per task — "justify or drop."** For each task: which FR/US does it exist FOR? A task whose
   `satisfies` you have to stretch is an orphan — either the spec is missing a requirement (loop back:
   the human re-opens and re-ratifies) or the task is scope creep (drop it).
3. **Per P1 edge case — "name the proof."** For each P1 story's Edge Cases: which task's DoD or
   `verification` proves it? An edge case no task proves is silent risk riding to the builder.

Route every gap to a fix in the block — never rationalize one ("probably covered by T003" is finding a
gap, not coverage). Then run the mechanical check:

```
harness/intake.sh analyze
```

**Gate B is wired** and is pure string cross-reference — no judgment, no leniency: it validates the nine invariants below and the
bidirectional FR↔task traceability, and it **names the offender** in every rejection (which task's
`satisfies` dangles, which FR is uncovered, which `scope` glob traverses, which SC lacks evidence). F8
is how you arrive at analyze with zero findings; analyze is what makes the floor non-optional.

## Worked examples — measurable, technology-agnostic Success Criteria

Each shows the weak version (unmeasurable or HOW-leaking) and the version decompose should emit.

**1. Frontend rendering**

- BAD: "Make the dashboard fast and responsive." _(no threshold; "fast" is unfalsifiable)_
- GOOD: "Lighthouse Performance ≥ 90 on the dashboard route (mobile preset); cumulative layout shift
  (CLS) < 0.1; renders without horizontal overflow at 320 / 768 / 1440 px viewport widths."

**2. API performance & reliability**

- BAD: "Optimise the submission endpoint with caching." _(prescribes HOW; "optimise" is unmeasurable)_
- GOOD: "p95 response latency < 200 ms at 50 requests/second sustained for 5 minutes; 0 unhandled 5xx
  responses across the acceptance suite."

**3. Data correctness & failure handling**

- BAD: "Import the CSV reliably." _("reliably" has no pass/fail line)_
- GOOD: "100% of the 1,000-row golden fixture round-trips with zero diffs; malformed rows are rejected
  with a typed error and the remaining valid rows still process (no partial write)."

The test in each case: two people, measuring independently and without reading the code, would agree on
pass/fail.

## End-to-end mini example

A tiny fuzzy objective decomposed, to tie this skill back to the spec contract.

**Objective:** "Let reviewers leave comments on a submission."
**Story US1 (P1):** _As a reviewer, I want to post a comment on a submission, so that the author gets
feedback._ — **Independent Test:** a posted comment is visible on reload.
**FR-001:** System MUST persist a comment against a submission. **FR-002:** System MUST reject an empty
comment. **SC-001:** a posted comment is visible to another viewer within 2 seconds.

Decomposed task block (conforms to `templates/spec-template.md`):

```json
{
  "spec_version": "forge/v1",
  "target_repos": ["example-target"],
  "tasks": [
    {
      "id": "T001",
      "title": "Persist a non-empty comment against a submission",
      "satisfies": ["FR-001", "FR-002", "US1"],
      "priority": "P1",
      "depends_on": [],
      "target_repo": "example-target",
      "definition_of_done": [
        "A failing test posts a comment and asserts it is retrievable by submission id; it then passes.",
        "A failing test posts an empty comment and asserts rejection with a typed validation error; it then passes."
      ],
      "success_criteria": [
        "100% of non-empty comments persist and are retrievable; 100% of empty comments are rejected."
      ],
      "scope": ["sandbox/comments/**", "tests/comments/**"],
      "dod_tests": ["tests/comments/persistence.sh"],
      "sc_evidence": [{ "sc": 1, "path": "sandbox/comments/evidence/sc1-persist-and-reject.txt" }],
      "verification": "run the comment persistence test suite"
    },
    {
      "id": "T002",
      "title": "Show a posted comment to other viewers on reload",
      "satisfies": ["US1", "FR-001"],
      "priority": "P1",
      "depends_on": ["T001"],
      "target_repo": "example-target",
      "definition_of_done": [
        "A failing test posts a comment, reloads as a second viewer, and asserts the comment is visible; it then passes."
      ],
      "success_criteria": [
        "SC-001",
        "A posted comment is visible to a second viewer within 2 seconds of posting."
      ],
      "scope": ["sandbox/comments/visibility/**", "tests/comments/**"],
      "dod_tests": ["tests/comments/visibility.sh"],
      "sc_evidence": [
        { "sc": 1, "path": "sandbox/comments/visibility/evidence/sc001-visibility-latency.txt" },
        { "sc": 2, "path": "sandbox/comments/visibility/evidence/sc2-second-viewer.txt" }
      ],
      "verification": "run the comment-visibility end-to-end test"
    }
  ]
}
```

Note: `T001` carries the story's Independent Test logic in its DoD; `T002` depends on `T001` and closes
the story against the measurable `SC-001`. F8 check on this block: deleting `T001` leaves FR-001 and
FR-002 uncovered (so it is load-bearing); both tasks justify themselves against US1; the empty-comment
edge case is proven by `T001`'s second DoD line. The machine fields: each task's `scope` is its real
write surface (not `**`), each `dod_tests` selector names the red→green test from the DoD, and every
success criterion has an evidence path (`T002` covers both of its criteria).

## Output boundary and the enforcement seam

- **Decompose stops at the spec.** It writes the task block into the spec and nothing else — it does not
  call `bd`, does not mint beads, does not touch the ledger. Bead creation is the converter's job
  (`intake.sh convert`, which carries the Gate-A ratification + anti-TOCTOU gate), and the exact
  bead-field mapping is locked against the real `bd` binary (see the _Bridge to `bd`_ section of
  `templates/spec-template.md`).
- **Validation is the seam, not goodwill.** The emitted JSON is accepted only after `intake.sh analyze`
  (**Gate B — wired**) passes: the nine fail-loud
  invariants from `templates/spec-template.md` (well-formed unique ids; `depends_on` resolves and is
  acyclic; non-empty `satisfies`/DoD/SC; `priority` enum; `target_repo` ∈ `target_repos`; well-formed
  `scope` globs; syntactically-valid `dod_tests` selectors; bidirectional `sc_evidence` ↔
  `success_criteria`) plus **bidirectional FR↔task traceability** — every `satisfies` entry resolves
  to an FR/US defined in the prose, and every defined FR is covered by ≥ 1 task. Every rejection names
  the offending id. Run F8, then analyze, before handing off.
