---
name: clarify
description: Resolve the highest-leverage ambiguities in a draft intake spec before decomposition — one round at a time, a tunable round budget that bounds QUESTIONS, never COVERAGE (F1 route-never-drop). Every answer is logged and propagated; every remaining ambiguity becomes a flagged [ASSUMED]. Interactive asks the human via AskUserQuestion; autonomous never asks. WHAT/WHY, never HOW.
---

You run the **clarify loop**: find where the objective is silent or contradictory, resolve the few
ambiguities that most change the spec, and surface the rest as flagged assumptions — so a human at Gate A
ratifies a spec with **no invisible gaps**. You drive this from the Architect role; `intake.sh start` has
already armed the intake sentinel, so the round budget, the ask↔record coupling, and the coverage floor are
**mechanically enforced** (see _The boundary_ below) — hold the discipline and the gates stay quiet.

## The core rule — F1: the budget routes, it never drops

The round budget bounds **how many times you interrupt the human**, not **how much of the objective you
resolve**. These are different things, and conflating them mechanically enforces under-elicitation on
exactly the high-stakes specs this system exists to serve.

- **Every eligible ambiguity is _surfaced_.** The top items by Impact × Uncertainty get a human question
  within budget (interactive); **every remaining eligible ambiguity becomes a flagged
  `[ASSUMED · <category> · confidence:low|med]` entry in `## Assumptions` — there is NO CAP on assumptions.**
- The budget therefore keeps human questions few (don't fatigue the human) while guaranteeing **nothing is
  left unsurfaced**. Zero residual `[NEEDS CLARIFICATION]` is the post-condition, reached by _either_ a
  `## Clarifications` answer _or_ an `## Assumptions` entry — never by silently dropping the ambiguity.
- The human may trigger **another clarify round even at zero rounds remaining** (`intake.sh clarify <spec>`)
  — intent-clarity outranks the quota. The budget only bounds _agent-initiated_ questioning.

## Question taxonomy — the canonical coverage set

Every unresolved point maps to exactly one **canonical category**. The categories are defined in ONE
machine-readable source — **`harness/intake-categories.json`** (`id` + canonical `name` + `cluster`) — and
this skill, the `spec-reviewer`, the spec template, and the deterministic coverage floor all defer to it, so
the taxonomy can never drift across copies again. Use a category's canonical `id` as the `AskUserQuestion`
`header` and as the disposition slug in the `## Deferrals` ledger.

The set is broad by design and grouped into **12 clusters** (read the enum for every `id`):

- **Scope & Intent** — what the system does / does not do, who it is for, "done" signals, competitive positioning
- **Domain & Data** — entities, persistence, migration, data quality, lineage, time/clock
- **Interfaces & Integration** — APIs, contracts/versioning, interoperability, eventing
- **UX & Interaction** — flows, accessibility (assistive + reduced-motion), responsiveness, motion, inclusivity
- **Content & Brand** — content design / information architecture, visual brand, content-source fidelity, copy
- **Quality: Performance & Efficiency** — latency, throughput, capacity, resource utilization
- **Quality: Reliability & Resilience** — availability, fault tolerance, recoverability, predictability
- **Quality: Security** — confidentiality, integrity, authn/authz, secrets, tenancy, privacy
- **Quality: Safety** — operational constraints, hazard handling, fail-safe, ML output safety
- **Quality: Maintainability & Flexibility** — modularity, testability, portability, scalability
- **Operational & Lifecycle** — deployment, observability, rollout/rollback, disaster recovery, cost
- **Constraints, Risk & Governance** — compliance/consent, licensing, data residency, supply-chain, mandated stack

> Breadth is the SAFE direction: the floor checks **presence, not adequacy**, so a category that does not apply
> is one `deliberately N/A — <reason>` line (defaults are pre-fillable). Accessibility, the split
> reliability/availability/operability axes, and the broadened security/safety set are deliberate: a
> load-bearing infra/multi-agent system under-covers these if NFR is narrowed to "performance & scale".

## Ranking — Impact × Uncertainty

Only **unresolved** categories are eligible (a category fully covered by an FR/SC/edge case, or marked N/A
in `## Deferrals`, is skipped). Score each eligible category on two axes, 1–3:

- **Impact** — blast radius if the answer changes: reshapes the architecture / many FR / the task graph
  (**3**), affects one story or a few FR (**2**), polishes an edge (**1**).
- **Uncertainty** — how silent or contradictory the objective is here: no signal (**3**), a hint but
  underspecified (**2**), mostly clear with a small gap (**1**).

Rank by the **product**, descending. Ask the top item first. **Re-score after each answer** — an answer
often resolves or raises siblings and reorders the queue. **Stop early** when the top remaining product
falls to a diminishing-returns threshold (≤ 2 — nothing both impactful and uncertain remains), even with
budget left.

## One-at-a-time protocol

```
loop:
  1. score eligible categories → rank by Impact × Uncertainty
  2. if queue empty OR top product ≤ 2 OR asked == budget:  break  → route the REST to ## Assumptions
  3. ask the single top-ranked question via AskUserQuestion (interactive only)
  4. record it as a "### Round N — <date>" entry in ## Clarifications, and PROPAGATE the answer into the
     live FR/SC/story text, removing the resolved [NEEDS CLARIFICATION] marker
  5. asked += 1 ; goto 1   (re-score — the queue may have changed)
```

Never batch unrelated questions. Asking and recording are **coupled**: step 4 (log **and** propagate) for
round _k_ must be on disk before round _k+1_ is asked — the clarify-gate denies the next ask otherwise.

**Recording format** (one entry per AskUserQuestion round; the `### Round N` header is what the round
counter keys on):

```markdown
### Round 1 — 2026-01-15

- **Q (security):** How should users authenticate? → **A:** Session token. _(propagated to FR-003, SC-002)_
```

**Option format:** multiple-choice, 2–5 options, mapped to `AskUserQuestion`. Exactly one option marked
**(Recommended)** and listed first (the safest/most conventional default); the tool's free-text "Other" is
always available.

## Interactive vs autonomous

- **`Mode: interactive`** — run the loop, asking via `AskUserQuestion`, within the round budget, one at a
  time. Route every un-asked eligible ambiguity to a flagged `[ASSUMED …]`.
- **`Mode: autonomous`** — **never ask** (there is no human; the clarify-gate denies AskUserQuestion
  entirely, and an unattended ask would hang). For **every** eligible ambiguity — not just the top N —
  write a flagged assumption, decoupled from the budget entirely:

  ```markdown
  - [ASSUMED · security · confidence:med] Authenticate via session token. **Chosen because** it matches
    existing flows with no new infra. **Discarded:** OAuth 2.0, API key. _(propagated to FR-003, SC-002)_
  ```

  Propagate each assumed answer into the live spec and clear the marker, so the spec is internally
  consistent — and the human at Gate A sees exactly what to ratify or overturn.

## Coverage sweep (F2 — before you declare the spec ready)

Walk **every canonical category** (the set in `harness/intake-categories.json`). Each must be one of:
**covered** (`covered by FR-NNN` — an FR / SC / edge case exists), **deliberately N/A**
(`deliberately N/A — <reason>`, recorded in the `## Deferrals / Out of scope` ledger so the human can ratify
the omission), or **surfaced** (`surfaced — <ref>` — a `## Clarifications` answer or a flagged `[ASSUMED …]`).
Every category appears exactly once in the ledger, by canonical `id`; a category that is none of these is an
elicitation gap — close it before Gate A. (The Stop floor greps each canonical id for one of these
dispositions — presence, never adequacy.)

## Self-check before ready (F3 — enumerable, symmetric to the Task-Breakdown self-check)

Confirm, all verifiable by reading (no judgment call):

1. the coverage sweep over every canonical category (`harness/intake-categories.json`) is complete (each covered / deliberately N/A / surfaced);
2. **zero** orphaned `[NEEDS CLARIFICATION]` / `[PLACEHOLDER]` remain;
3. every **P1** story has ≥ 1 explicit edge case **and** ≥ 1 failure/error-path scenario;
4. every story with latency / volume / availability implications has ≥ 1 NFR `SC-NNN`;
5. every `[ASSUMED …]` carries its **Chosen because** / **Discarded** and a propagation note;
6. the `## Deferrals / Out of scope` surface lists the categories consciously skipped or N/A.

## The boundary (WIRED, not advisory)

This skill describes the behaviour; the **hooks are the boundary**, and they are live:

- **`pre-tool-use-clarify-gate.sh`** (PreToolUse on `AskUserQuestion`, the real-time enhancement) denies the
  round beyond the budget, denies > the per-call question cap, denies AskUserQuestion entirely in autonomous
  mode, and denies the next round until the prior round is logged (ask↔record coupling). A human grant
  (`intake.sh clarify`) lifts the ceiling.
- **`stop-gate-intake.sh`** (Stop, the carrier-independent F1 **guarantee**) blocks the agent from declaring
  the spec done while any `[NEEDS CLARIFICATION]` remains, the round count exceeds budget, autonomous has any
  asked round, or the coverage sweep / F7 `## Deferrals` surface is incomplete. This floor holds even if the
  AskUserQuestion gate is absent — the guarantee never rests on it.

Beyond these hooks sit the Gate-A two-party restatement (the `spec-reviewer` subagent, an `understanding.md`
projection, and a human ratification token) and the Gate-B FR↔task traceability check — see the Architect
role for the full cycle.
