# 07 — UI: per-device Codec Preference picker + Negotiated Codec display

**What to build:** The operator-facing surface. A Codec Preference picker (Auto / H.265 / H.264, default Auto) in the device settings panel beside the existing stream/bitrate controls, persisted per device (keyed by device id) so one misbehaving device never forces a global downgrade. The status bar shows the Negotiated Codec, with an explicit "(fallback)" suffix when a Fallback produced it — a downgraded session is never silent. Changing the preference on a live connection acts as an Operator-Initiated Connect (clears fallback memory, reconnects with the new preference). Both surfaces consume the published state from tickets 05/06 — no new seams.

**Blocked by:** 06 — Fallback + watchdog (supplies the fallback-provenance state the display needs).

**Status:** done (live verification completed 2026-08-12)

- [x] Picker appears beside the existing stream settings with Auto / H.265 / H.264; default is Auto — operator used the picker live 2026-08-12 (flipped H.264 and back; initial connect defaulted to Auto → H.265); default behavior unit-tested
- [x] Preference persists per device across app restarts; a second device's preference is independent
- [x] Changing the preference mid-connection reconnects with the new preference and clears fallback memory
- [x] Status bar shows "H.265" / "H.264" when natively negotiated — operator observed both labels live 2026-08-12 across the preference flips; "(fallback)" provenance rendering is covered by the published-state tests (no fallback occurred live — the pin prevents the mismatch that used to cause it)
- [x] Explicit H.264 preference never sends an H.265 Watch Request — verified live 2026-08-12: preference flip pinned `video_format=0` and sent watch `video_format=0` (app log + device-side `set_params?video_format=0` POST), offer contained no H.265, native H.264 rendered
- [x] App builds and all tests remain green (views themselves are untested, per the spec's testing decisions)

## Comments

- Persistence is owned by `CodecPreferenceStore` and uses `UserDefaults` keys of the form `overlook.codecPreference.v1.<device-id>`, storing the enum raw values `auto`, `h265`, and `h264`. Missing or unrecognized values resolve to Auto.
- The store is deliberately separate from SwiftUI and from the pure codec-selection policy. Unit tests recreate the store over the same isolated defaults suite to cover restart-style persistence, default Auto behavior, and device-id independence.
- `WebRTCManager` loads the stored Codec Preference at every entry path: device selection, manual reconnect, Automatic Reconnect, and Codec Preference change. A live preference change is passed to `CodecSelectionPolicy.connect` as `.operatorInitiatedConnect(.codecPreferenceChange)`, so policy-owned Fallback memory clearing remains the single source of truth.
- The segmented Codec Preference picker is in the Video disclosure beside Mode and Quality. The status strip is hosted as a bottom safe-area inset and renders the manager's published Negotiated Codec only while WebRTC is connected.
- Automated verification: 21 tests passed in the Debug CLI suite; the Release build succeeded. Existing non-ticket Release warnings remain in `ContentView.swift` and `CoreAudioDevices.swift`.
- Pending operator verification: picker layout/labels, native H.265 and native H.264 status labels, visible `H.264 (fallback)` provenance, disconnected absence, and a live Comet observation that an explicit H.264 preference produces no H.265 Watch Request.
- Fixed Codec Preference changes after stream loss: saving still occurs unconditionally, but when the device remains the current connection target the change now always starts a full Operator-Initiated Connect classified as `.codecPreferenceChange`, even if ICE is disconnected. The policy therefore clears remembered Fallback and reconnects with the new preference; with no current target, the change remains persistence-only. Live verification after an ICE loss remains outstanding.
