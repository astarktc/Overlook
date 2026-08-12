# 07 — UI: per-device Codec Preference picker + Negotiated Codec display

**What to build:** The operator-facing surface. A Codec Preference picker (Auto / H.265 / H.264, default Auto) in the device settings panel beside the existing stream/bitrate controls, persisted per device (keyed by device id) so one misbehaving device never forces a global downgrade. The status bar shows the Negotiated Codec, with an explicit "(fallback)" suffix when a Fallback produced it — a downgraded session is never silent. Changing the preference on a live connection acts as an Operator-Initiated Connect (clears fallback memory, reconnects with the new preference). Both surfaces consume the published state from tickets 05/06 — no new seams.

**Blocked by:** 06 — Fallback + watchdog (supplies the fallback-provenance state the display needs).

**Status:** ready-for-agent

- [ ] Picker appears beside the existing stream settings with Auto / H.265 / H.264; default is Auto for a device with no stored preference
- [ ] Preference persists per device across app restarts; a second device's preference is independent
- [ ] Changing the preference mid-connection reconnects with the new preference and clears fallback memory
- [ ] Status bar shows "H.265" / "H.264" when natively negotiated and "H.264 (fallback)" after a Fallback; empty/absent when disconnected
- [ ] Explicit H.264 preference never sends an H.265 Watch Request (observable via Negotiated Codec and device behavior)
- [ ] App builds and all tests remain green (views themselves are untested, per the spec's testing decisions)
