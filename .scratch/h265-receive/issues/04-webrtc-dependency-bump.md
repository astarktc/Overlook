# 04 — WebRTC dependency bump (109 → ≥150), zero behavior change

**What to build:** Bump the stasel WebRTC dependency from 109 to the newest release ≥150 (H.265 depacketizer and packet buffer are compiled into those binaries), landing the smallest possible diff with NO behavior change: the app builds, connects, and streams H.264 exactly as today. This is the riskiest step (40+ majors of API drift), which is why it lands alone, after ticket 03 — the decoder fixture tests green-before/green-after serve as the bump's regression net.

**Blocked by:** 03 — H.265 decoder module (its tests are this ticket's safety net).

**Status:** ready-for-agent

- [ ] Dependency pinned to the chosen ≥150 release; app and test targets build clean
- [ ] All existing tests (decoder fixtures, policy matrix if present) still green on the new binary
- [ ] H.264 live streaming to the Comet verified working end-to-end (connect, video, input, audio, stats)
- [ ] The reflection-based playout-delay-hint invocation re-verified against the new binary: confirm the selector still resolves and the hint still takes effect (it fails soft by design — silent loss would be an unnoticed latency regression)
- [ ] The post-build codesign recipe (re-sign embedded WebRTC framework, then the app) confirmed still working with the new framework
- [ ] Any API-drift adaptations documented in the ticket's comments for future bump reference
