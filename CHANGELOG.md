# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-03

### Added

- Initial public release of the agentic-builder-forge template
- Enforcement floor: PreToolUse deny hook, PostToolUse format hook, Stop gates
  (tests + intake), clarify gate, self-minting SessionStart witness
- Harness: task runner with per-task worktrees and optional container sandbox,
  spec intake with clarify loop and human ratify, decompose-to-ledger, acceptance
  gate, advisory read-only reviewer (ollama / claude-fresh / codex backends),
  kill-switch, reaper, optional GitHub Projects oversight board
- Beads (bd) task-ledger integration with config-driven pinning
- Canonical test gate (`tests/run-all.sh`) with PASS/SKIP/FAIL verdicts across
  40+ suites
- One-command initialization (`.forge/scripts/init.sh`) with post-init doctor
- One worked example spec packet (`specs/001-example/`)
- Full documentation set under `docs/`

[Unreleased]: https://github.com/galimba/agentic-builder-forge/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/galimba/agentic-builder-forge/releases/tag/v0.1.0
