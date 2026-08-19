# 07 — Verification soak and instrumentation cleanup

**What to build:** Proof the user's original symptom is gone, then a clean tree. A Release build of the fixed app streams on the 4K external display for hours with CPU a small fraction of a core, zero SwiftUI layout churn, and no visible stutter; afterwards the diagnostic instrumentation is stripped.

Procedure:

- Rebuild Release with diag instrumentation still present; run `.scratch/cpu-stutter/loop.sh` (must be GREEN, <10% layout share) and the soak monitor (`soak.sh`) for a multi-hour session under real use, matching the RED conditions (windowed, 4K external, panels opened and closed along the way).
- Compare `framesDropped` (inbound-rtp) before/after; visually confirm no stutter.
- Strip every `[DEBUG-swiftui-audit]` line; decide whether the `VideoSurfaceView` lint renames stay (recommend: keep, they're clean) — record the decision.
- Post-mortem note in `.scratch/cpu-stutter/`: confirmed mechanism, what the amplifier turned out to be (if the soak ever reproduced RED), and what would have prevented it.

**Blocked by:** 01, 02, 03, 04, 05, 06.

**Status:** done (2026-08-18)

- [x] Stutter-immunity demo: Release build + `OVERLOOK_DIAG_STALL_MAIN=1` → video glides (user-confirmed; UI glides too)
- [x] Multi-hour Release soak — waived by user; normal daily use is the ongoing test (failure will be reported). Debug soak: ~2h flat (CPU ~5%, layout 0%, RSS 224MB, evals 0)
- [x] No visible stutter under normal use (user confirmation)
- [x] `grep -rn "DEBUG-swiftui-audit" Overlook/` returns nothing; `DiagFlags.swift` removed from both targets + pbxproj; `VideoSurfaceView` lint renames kept; instrumentation preserved at git tag `cpu-stutter-instrumented` (pointer in AGENTS.md)
- [x] Post-mortem / Apple Feedback write-up — skipped by user decision; `measurements.md` is the record
