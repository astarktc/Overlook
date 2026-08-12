# 10 — Pin the device encoder format via kvmd set_params (fixes live H.265)

**What to build:** When Overlook connects (and on codec-preference change / fallback), set the device's actual encoder format through the authenticated kvmd API — `POST /api/streamer/set_params?video_format=N` via the existing `GLKVMClient.setStreamerParams` — so the encoder always matches the codec negotiated in the Janus watch/SDP.

**Status:** ready-for-human (implemented; formal live-verify pass pending)

**Why (root cause of the live H.265 failure, proven 2026-08-12):** the Janus watch's
`video_format` parameter shapes ONLY the SDP the GL plugin offers (`us_rtpv_make_sdp in
video_format N`); the encoder's real format is governed by kvmd (volatile
`/etc/kvmd/user/config.json` key, dropped silently by GL client rewrites). During every
failing live run the encoder emitted H.264 while the SDP declared H.265 — libwebrtc's
H.265 depacketizer parses the mislabeled packets without warnings, but H26xPacketBuffer
never sees an HEVC VPS and discards silently forever: `framesReceived=0`, endless PLIs,
watchdog fallback. Reproduced deterministically both ways in
`OverlookTests/H265LiveWireDiagnosticTests.swift` (encoder H.265 → 1000+ frames decoded
and rendered at 2560x1440@60 through the REAL WebRTCManager; encoder H.264 + watch H.265
→ exact live-failure signature). kvmd's `__streamer_set_params_handler` accepts
`video_format` (verified by pyc introspection on rm10-1.9.0) and kvmd restarts the
streamer on param changes, exactly like the existing quality/fps switching.

- [x] Decide placement: single chokepoint — `WebRTCManager.sendVideoWatchRequest` calls an injected `encoderFormatPinner` closure (wired in ContentView to `GLKVMClient.setStreamerParams`) BEFORE sending each video watch, so the offer and bits always match
- [x] Send `video_format` on: initial connect, codec-preference change, and H.264 fallback re-watch — all three flow through the chokepoint
- [x] Handle the encoder-restart window: kvmd only restarts the streamer when the param value actually CHANGES, so the unconditional pin is idempotent/gap-free in steady state; a genuine format change restarts the encoder while ICE/DTLS are still setting up, and the first-frame watchdog remains the safety net (pin is fail-soft: watch proceeds on pin failure, with a clear log line)
- [x] Writer-conflict + disconnect policy DECIDED: **leave-as-set on disconnect** (no restore write; restoring would need prior-state tracking plus a racy write during teardown, and other GL clients self-heal by writing their own format). Documented at the ContentView wiring. **LAB-29 sync DONE (BDA, 2026-08-12): no conflict** — since the pin runs on every connect and the operator's normal codec is H.265, the device's standing state self-maintains at H.265, which is what his interim Safari usage wants; LAB-29's remaining scope shrank to device-side cleanup (override.yaml redundant block disposition)
- [x] `-999 cancelled` interplay: one sequential awaited call per watch-triggering event (no rapid repetition introduced); the parked issue is about the settings-panel path and remains parked
- [x] Unit test: `testStreamerParamsPinEncoderFormatToTheWatchRequestWireValues` (kvmd key + wire values); pin-before-watch ordering asserted live in the env-gated `testRealWebRTCManagerAgainstLocalJanusTunnel` (recorder pinner; verified against the real device 2026-08-12: pin → watch → first rendered frame, running as a second watcher beside the operator's live session)
- [ ] Formal live-verify H.265 end-to-end with real set_params in the loop (tickets 04–08 checkboxes, BDA observing device-side)
- [x] Leave device codec state as found or report changes: verification used a recorder pinner only — no device state was touched

## Comments

- Discovered during the 2026-08-12 live-debug session; full evidence chain in
  `docs/handoffs/2026-08-12-h265-live-debug-handoff.md` (RESOLVED addendum). The GL
  packetizer is textbook-correct — all packetization hypotheses (H1/H2/H3) were refuted
  by on-wire capture (`.scratch/h265-receive/tools/rtp_trace.py`).
- With `video_format: 1` currently restored in the device config (BDA, 2026-08-12), live
  H.265 likely works TODAY with no code change — but the config key is volatile, so this
  ticket is the durable fix. Client-driven set_params also makes Overlook independent of
  what other GL clients do to the persisted config.
