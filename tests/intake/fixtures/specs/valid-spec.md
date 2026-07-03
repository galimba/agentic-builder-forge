# Example Spec (extractor fixture)

- **Objective:** Example objective for the sentinel-extraction test.
- **Target Repo(s):** agentic-builder-forge
- **Mode:** interactive
- **Status:** ready-for-tasks

## Decoy

A decoy fenced block the extractor MUST ignore (it is not between the sentinels):

```json
{ "not": "the task block", "ignore": true }
```

## Task Breakdown

<!-- forge:tasks:begin v1 -->

```json
{
  "spec_version": "forge/v1",
  "target_repos": ["agentic-builder-forge"],
  "tasks": [
    {
      "id": "T001",
      "title": "First task",
      "satisfies": ["FR-001", "US1"],
      "priority": "P1",
      "depends_on": [],
      "target_repo": "agentic-builder-forge",
      "definition_of_done": ["A failing test passes."],
      "success_criteria": ["SC-001"],
      "scope": ["sandbox/first/**"],
      "dod_tests": ["tests/intake/run.sh"],
      "sc_evidence": [{ "sc": 1, "path": "sandbox/first/evidence/sc1.txt" }]
    },
    {
      "id": "T002",
      "title": "Second task",
      "satisfies": ["FR-002"],
      "priority": "P2",
      "depends_on": ["T001"],
      "target_repo": "agentic-builder-forge",
      "definition_of_done": ["Another failing test passes."],
      "success_criteria": ["A measurable outcome holds."],
      "scope": ["sandbox/second/**"],
      "dod_tests": ["tests/intake/run.sh"],
      "sc_evidence": [{ "sc": 1, "path": "sandbox/second/evidence/sc1.txt" }]
    }
  ]
}
```

<!-- forge:tasks:end -->
