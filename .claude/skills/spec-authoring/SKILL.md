---
name: spec-authoring
description: Author an intake spec from templates/spec-template.md — prioritized stories, testable FR-NNN, measurable technology-agnostic SC-NNN — resolving [NEEDS CLARIFICATION] per the Header Mode. Produces the prose spec; hands the Task Breakdown to the decompose skill. WHAT/WHY, never HOW.
---

Use this skill when authoring an intake spec (the Architect role). It governs the prose sections;
the `<!-- forge:tasks:begin -->` Task Breakdown is the `decompose` skill's job.

## The artifact and its conventions

The spec lives at `specs/NNN-<slug>/spec.md`, scaffolded from `templates/spec-template.md` with the
Header (Objective, Target Repo(s), Mode, Status) already filled. Conventions: ATX headings, no emoji,
**bold** for emphasis, `backticks` for ids/paths/flags. Ids are stable once assigned — never renumber;
mark withdrawn items `~~FR-007~~ (withdrawn)`.

## Stories (User Scenarios)

Prioritized: **P1** must-have for the objective to mean anything; **P2** important but deferrable; **P3**
nice-to-have. Each story is a **vertical, independently-testable slice**, not a horizontal layer. Give
each an **Independent Test** (the single observable behaviour proving _this story alone_ works — it
informs the closing task's DoD), Acceptance Scenarios (Given/When/Then), and Edge Cases (use `[NEEDS
CLARIFICATION: …]` where behaviour is silent).

## Requirements (FR-NNN)

Imperatives the system must satisfy. **MUST** for load-bearing, **SHOULD** for strong-but-optional. Each
is testable and traces to ≥1 story. State _what_ must be true — never the library/file/algorithm (that is
HOW; the builder chooses it under the test-first gate). Use inline `[NEEDS CLARIFICATION: …]` wherever the
objective does not pin a behaviour down.

## Success Criteria (SC-NNN)

Measurable, technology-agnostic outcomes — **no** framework, library, or file names. Prefer numeric
thresholds or directly observable outcomes. The test: **two people, measuring independently and without
reading the code, would agree on pass/fail.** (Worked good/bad examples live in the `decompose` skill.)

## Clarification — see the `clarify` skill (the loop is WIRED)

Where the objective is silent, leave `[NEEDS CLARIFICATION: <question>]`, then resolve it with the
**`clarify`** skill, which carries the full protocol: the Impact × Uncertainty ranking, the round budget,
the F1 route-never-drop rule, the per-round `### Round N` recording, and interactive-vs-autonomous
behaviour. In short — interactive asks the human via `AskUserQuestion` within the round budget and logs
each round in `## Clarifications`; autonomous never asks and routes every ambiguity to a flagged
`[ASSUMED · <canonical-id> · confidence:low|med]` entry in `## Assumptions` (`<canonical-id>` is a category
`id` from `harness/intake-categories.json`). Either way the post-condition is
**zero residual `[NEEDS CLARIFICATION]`** — reached by a `## Clarifications` answer or an `## Assumptions`
entry, never by dropping the ambiguity (F1: route, never drop — no cap on assumptions).

This is no longer goodwill. The round budget, the ask↔record coupling, the autonomous-no-ask rule, and the
coverage floor are mechanically enforced: `pre-tool-use-clarify-gate.sh` denies the over-budget round, the
over-cap or autonomous ask, and the next round until the prior is logged; `stop-gate-intake.sh` is the
Stop-floor F1 guarantee that holds even with the ask-gate absent. Recording stays two-part per answer — the
`## Clarifications` log line **and** the answer propagated into the live section with its marker removed.

## Hand-off: Gate A, then decompose

When the prose is clarified (no orphaned markers) and the **complete** FR set is authored, the Architect
runs the **Gate-A two-party restatement** (spawn the `spec-reviewer`, reconcile to consensus or surface
`## UNRECONCILED`, produce `understanding.md`; a human ratifies) — see `architect.md`. After ratification,
use the `decompose` skill to author the Task Breakdown and run its F8 adversarial coverage pass. The
mechanical **Gate-B** FR↔task traceability gate (`harness/intake.sh analyze`) then verifies the block.
Drive `Status` `draft → clarifying → ready-for-tasks`; `approved` is the human's at the merge gate.
