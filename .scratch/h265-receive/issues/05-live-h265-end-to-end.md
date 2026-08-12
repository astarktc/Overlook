# 05 — Live H.265 end-to-end (the tracer bullet)

**What to build:** The complete happy path: Overlook connects to the Comet and live H.265 video flows at 2560×1440@60. The video Watch Request carries the Video Format decided by the policy module (Auto → request H.265); the custom decoder factory from ticket 03 is plugged in at the existing factory construction seam; the SDP answer negotiates H.265; frames decode in hardware. The Negotiated Codec is exposed as published, observable state (consumed by UI in ticket 07). The WebRTC manager contains no codec-selection branching of its own — it asks the policy module. The audio Watch Request and everything non-video is untouched.

**Blocked by:** 02 — Policy module · 03 — Decoder module · 04 — Dependency bump.

**Status:** ready-for-human

- [ ] Connecting to the Comet in Auto negotiates and streams live H.265 at 2560×1440@60 (device follows the client's Watch Request; no persistent device configuration is read or written)
  - Pending operator verification against the production Comet.
- [x] Negotiated Codec published as observable state and correct (H.265 when negotiated, H.264 when the device offers only H.264)
- [ ] Existing stream stats (bitrate, fps, decode time, jitter, packet loss) report correctly under H.265
  - Pending operator verification against a live H.265 stream.
- [ ] Input, audio, and all non-video features verified unaffected
  - Pending operator verification; these paths were not changed by this ticket.
- [x] Codec-selection decisions flow exclusively through the policy module
- [ ] All tests green; manual live verification against the Comet documented in the ticket's comments (coordinate any device-mode needs with the operator — never reconfigure the device from this repo's tooling)
  - Automated suite is green; pending operator verification for the live portion.

## Comments

### Wiring decisions

- `WebRTCFactoryBuilder` now constructs `OverlookVideoDecoderFactory` for the decoder side while retaining `RTCDefaultVideoEncoderFactory`; H.265 remains receive-only.
- `WebRTCManager` starts every device-selection `connect` and manual `reconnect` by calling `CodecSelectionPolicy.connect`. Its existing audio-device recovery path is the only Automatic Reconnect and passes `.automaticReconnect`. Codec Preference defaults to `.auto` through a parameter that ticket 07 can supply per device later.
- The manager retains `CodecSelectionState` and app-session `FallbackMemory`, sends `videoFormatForWatchRequest.rawValue` as the video Watch Request's sole `video_format`, and publishes the policy state's `NegotiatedCodec`. Disconnect clears the published Negotiated Codec but intentionally retains app-session Fallback memory.
- Video SDP offers are parsed by the pure `SDPOfferParser`, which only recognizes an `a=rtpmap` H265 encoding inside an `m=video` media section (case-insensitive). The resulting `OfferContents` is passed to `CodecSelectionPolicy.handleOffer`. Audio offers are not parsed for video capability.
- Offer-based re-watch actions and the first-frame watchdog remain ticket 06 scope and are not implemented here.
- CLI verification on 2026-08-11: 19 tests passed, including three SDP parser tests; the Release app build also succeeded.

### Pending operator verification

Use the production Comet in its current H.265 mode; do not read, write, or reconfigure persistent device codec configuration from this repo's tooling. Coordinate any H.264-only device-mode need with the operator/device-side owner.

1. Build the Release artifact using the documented command, then apply the handoff's launch prerequisites to the app being tested (for example, `<app>` = `/tmp/overlook-build/Build/Products/Release/Overlook.app`):
   - `codesign --force -s - <app>/Contents/Frameworks/WebRTC.framework`
   - `codesign --force -s - <app>`
   - `plutil -insert NSAppTransportSecurity -json '{"NSAllowsArbitraryLoads":true}' <app>/Contents/Info.plist`
2. Make an Operator-Initiated Connect to the Comet with Auto (the current default). Confirm the video Watch Request carries `"video_format": 1`, no persistent device configuration changes, SDP offers `a=rtpmap ... H265/90000`, the published Negotiated Codec is H.265, and live video is 2560×1440@60.
3. Compare picture quality with the GL web UI's H.265 stream and latency with current Overlook H.264. Confirm bitrate, fps, decode time, jitter, packet loss, and frame-stall reporting remain plausible and live.
4. Exercise keyboard/mouse input, audio playback, microphone if used, reconnect, settings, OCR/frame capture, fullscreen/windowing, and other daily non-video flows for regressions.
5. Against an operator-approved H.264-only offer (without changing device state from repo tooling), confirm the published Negotiated Codec is H.264 (fallback provenance for Auto). Ticket 06 will add the re-watch action that acts on this policy result.
