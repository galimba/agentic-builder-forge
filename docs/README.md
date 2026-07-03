# agentic-builder-forge documentation

Start at the root [`../README.md`](../README.md) if you're new. This index covers the deeper docs.

These describe the Forge as it is on the default branch today. Where an older comment contradicts them, they follow the code — and where the code's behavior differs from its own stale comments, the code wins.

| Document | For | Covers |
| --- | --- | --- |
| [`getting-started.md`](getting-started.md) | Newcomers | From clone through `init.sh` to your first merged PR. |
| [`architecture.md`](architecture.md) | Contributors / operators | The enforcement tier stack, the component map (where everything lives), the floor identity, and the session witness. |
| [`lifecycle.md`](lifecycle.md) | Contributors / operators | The end-to-end flow — intake and build pipelines, self / target / feature builds, and who acts at each stage (automated / agent / human). |
| [`operating.md`](operating.md) | Operators | Environment and config controls, the runtime records and their schemas, the audited escape doors, the oversight board, target-build setup, and retention realities. |
| [`development.md`](development.md) | Contributors | How the harness itself is changed — the splice/door pattern for enforcement files, floor re-certification, the proof/test model, and the roles. |
| [`configuration.md`](configuration.md) | Adopters | Every config seam (`harness/*.config`), field by field. |
| [`limitations.md`](limitations.md) | Everyone relying on the guarantees | The complete honest boundary: mechanically enforced vs. best-effort vs. out-of-scope, and every known limitation, enumerated and tagged. |

`init.sh` also renders an **onboarding doc** into this directory with your instance's own values (repo, org, default branch, bead prefix).
