# 08 — Manual acceptance: parity verification against the reference client

**What to build:** Nothing — this is the human verification pass closing the feature against the original acceptance criteria. The operator compares, side by side on the production Comet: (1) picture quality of Overlook's H.265 stream vs the GL web UI's H.265 stream (sharpness of text, gradient banding) — expect parity; (2) latency feel of Overlook H.265 vs Overlook H.264 — expect parity. Also a short soak on the daily driver to confirm no regressions in input, audio, or stability. Coordinate with the operator/BDA session for any device-side observation (device-side log or bitrate checks); milestone outcome mirrors to LAB-28.

**Blocked by:** 06 — Fallback + watchdog · 07 — Codec Preference UI.

**Status:** ready-for-human

- [ ] Quality parity: Overlook H.265 visually matches the GL web UI's H.265 stream at 2560×1440@60 (text sharpness, banding)
- [ ] Latency parity: Overlook H.265 feels equivalent to Overlook H.264 for interactive use (typing, cursor)
- [ ] Fallback UX sanity-checked once in real use (visible "(fallback)", manual reconnect retries H.265)
- [ ] A working session survives a device stream blip without operator intervention (Automatic Reconnect path)
- [ ] Daily-driver soak (a real work session) with no regressions in input, audio, or stability
- [ ] Outcome recorded here and mirrored to LAB-28
