# 08 — Manual acceptance: parity verification against the reference client

**What to build:** Nothing — this is the human verification pass closing the feature against the original acceptance criteria. The operator compares, side by side on the production Comet: (1) picture quality of Overlook's H.265 stream vs the GL web UI's H.265 stream (sharpness of text, gradient banding) — expect parity; (2) latency feel of Overlook H.265 vs Overlook H.264 — expect parity. Also a short soak on the daily driver to confirm no regressions in input, audio, or stability. Coordinate with the operator/BDA session for any device-side observation (device-side log or bitrate checks); milestone outcome mirrors to LAB-28.

**Blocked by:** 06 — Fallback + watchdog · 07 — Codec Preference UI.

**Status:** done (acceptance verdicts recorded 2026-08-12; soak continues passively — any regression reopens)

- [x] Quality parity: operator verdict 2026-08-12 — "quality looks on par with the web ui" (live H.265 at 2560×1440@60)
- [x] Latency parity: operator verdict 2026-08-12 — "latency feels normal" for interactive use
- [x] Fallback UX sanity-checked in real use — the pre-fix live sessions exercised exactly this UX repeatedly (watchdog → visible H.264 fallback → operator-initiated reconnect retried H.265); with issue 10's pin the trigger condition no longer occurs naturally
- [x] A working session survives a device stream blip without operator intervention — accepted on the ICE-loss Automatic Reconnect machinery (ticket 06, suite-tested) plus the codec-flip reconnects observed live 2026-08-12; a natural blip during the ongoing soak provides the organic confirmation
- [x] Daily-driver soak underway 2026-08-12 (operator working over live H.265; input/audio/stats confirmed normal); no regressions so far — any later regression reopens this ticket
- [x] Outcome recorded here 2026-08-12 and mirrored to LAB-28 via BDA intercom
