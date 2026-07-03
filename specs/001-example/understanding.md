# Understanding — textstat utility

> Gate-A artifact: a projection of the completed FR set, written beside the spec and ratified by a
> human (`intake.sh ratify`) before any bead is minted. It restates what will exist if every FR is
> satisfied — so the human ratifies an outcome, not a diff.

## What the FRs will build

The FRs add one small, self-contained utility to `example-target`: a `textstat` CLI that reads UTF-8
text and reports three integers — lines, words, characters. Nothing persists, nothing goes over the
network; the only interfaces are argv, stdin, stdout, and stderr.

- **FR-001 + FR-005 + FR-006** are the counting core (T001): a single pass over the input that counts
  newline-delimited lines (a final unterminated line still counts), words as maximal runs of
  non-whitespace, and characters as Unicode code points. The semantics are pinned — code points by the
  flagged `[ASSUMED · functional-correctness · confidence:med]` the human ratifies with this document,
  word boundaries by Clarifications Round 1 — so output is a pure function of input.
- **FR-002** is the error contract (T002): a missing, unreadable, or non-UTF-8 input exits non-zero
  with exactly one diagnostic line naming the input, and never prints partial counts. Diagnostics go to
  stderr; stdout stays clean for pipelines.
- **FR-003** is the stdin fallback (T003): with no file operand the tool reads stdin to EOF and reports
  counts identical to the file form for the same bytes — the pipeline-parity criterion (SC-003) is what
  makes the two entry points one behaviour, not two.
- **FR-004** is the machine surface (T004): `--json` emits exactly one JSON object with integer keys
  `lines`, `words`, `chars`. Those three keys are the public contract (see
  `public-api-surface-semver` in the Deferrals ledger); evolution is additive-only.
- **FR-007** bounds resources: a streaming pass whose memory does not grow with input size, checked
  against a generated 100 MB fixture.

Each task produces an in-scope diff — `src/textstat/**` plus `tests/textstat/**` and nothing else — and
the acceptance gate verdicts it mechanically: **C1** confirms the staged diff ⊆ the task's `scope`;
**C2** runs the whole-file `dod_tests` selector (`tests/textstat/run.sh`); **C3** confirms every
`sc_evidence` file is staged, non-symlink, and non-empty; the **integrity** check confirms the staged
diff did not change while the gate ran. The four SCs are all measurable by running the fixture suite —
no judgement calls at the merge gate.
