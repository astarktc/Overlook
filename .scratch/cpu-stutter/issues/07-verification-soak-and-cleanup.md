# 07 — Verification soak and instrumentation cleanup

**What to build:** Proof the user's original symptom is gone, then a clean tree. A Release build of the fixed app streams on the 4K external display for hours with CPU a small fraction of a core, zero SwiftUI layout churn, and no visible stutter; afterwards the diagnostic instrumentation is stripped.

Procedure:

- Rebuild Release with diag instrumentation still present; run `.scratch/cpu-stutter/loop.sh` (must be GREEN, <10% layout share) and the soak monitor (`soak.sh`) for a multi-hour session under real use, matching the RED conditions (windowed, 4K external, panels opened and closed along the way).
- Compare `framesDropped` (inbound-rtp) before/after; visually confirm no stutter.
- Strip every `[DEBUG-swiftui-audit]` line; decide whether the `VideoSurfaceView` lint renames stay (recommend: keep, they're clean) — record the decision.
- Post-mortem note in `.scratch/cpu-stutter/`: confirmed mechanism, what the amplifier turned out to be (if the soak ever reproduced RED), and what would have prevented it.

**Blocked by:** 01, 02, 03, 04, 05, 06.

**Status:** ready-for-agent

- [ ] Multi-hour Release soak on 4K external: `loop.sh` GREEN throughout, `soak.log` shows no upward CPU/layout trend
- [ ] No visible stutter under normal use (user confirmation)
- [ ] `grep -rn "DEBUG-swiftui-audit" Overlook/` returns nothing
- [ ] Post-mortem note written
