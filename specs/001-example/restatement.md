# Restatement — textstat utility

> Gate-A artifact: an independent reviewer restates the spec in its own words and either AGREEs or
> records a DISAGREE/ESCALATE finding. Ratification is blocked while findings are open — they must be
> reconciled in the spec (or surfaced under `## UNRECONCILED` in `understanding.md`) before
> `intake.sh ratify` will mint the token.

## Open findings

(none)

## History

### Restatement round 1

reviewer: DISAGREE — "word" was undefined in the draft: FR-001 promised word counts but nothing pinned
whether that meant whitespace-delimited runs or locale-aware tokenization, so SC-001 was unfalsifiable
(two correct implementations could disagree on the same fixture). Character semantics had the same
ambiguity (bytes vs code points vs graphemes). Routed to a clarify round.

### Restatement round 2

reviewer: AGREE — Clarifications Round 1 pinned word boundaries (FR-006) and the stdin contract
(FR-003); the character-semantics choice arrived after the clarify budget was spent and is flagged as
`[ASSUMED · functional-correctness · confidence:med]` for the human at the ratify gate rather than
silently embedded. Three stories, seven FRs, four SCs, four tasks; every SC is measurable by running
the fixture suite, and every task's contract (scope, dod_tests, sc_evidence) is mechanically checkable.
No open disagreement; nothing to reconcile.
