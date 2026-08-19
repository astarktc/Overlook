# Agent instructions

## Agent skills

### Issue tracker

Issues live as local markdown files under `.scratch/<feature>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Diagnostic instrumentation (removed, recoverable)

The SwiftUI perf-audit instrumentation (`DiagFlags.swift`, `[DEBUG-swiftui-audit]` kill switches, main-thread stall injector) was stripped after the 2026-08 cpu-stutter fix. To restore it, see git tag `cpu-stutter-instrumented` (last commit containing it) and `.scratch/cpu-stutter/` for the diagnosis playbook.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
