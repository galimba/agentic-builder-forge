# Pull Request

## What

<!-- One-paragraph summary of the change. -->

## Why

<!-- Motivation. Link the issue if one exists. -->

## Checklist

- [ ] The canonical gate passes locally: `bash tests/run-all.sh`
- [ ] New behavior has a test (RED-first for enforcement changes)
- [ ] No suite skipped silently (SKIPs are honest rc-75, reported by the gate)
- [ ] Docs updated where behavior changed
- [ ] Commit messages follow Conventional Commits

## Enforcement-surface changes only

<!-- Delete this section if you did not touch .claude/hooks/, .claude/settings.json, or harness/. -->

- [ ] I did not weaken a deny rule without documented rationale
- [ ] I did not introduce a committed integrity baseline
- [ ] The change is covered by a boundary/escape-class test
