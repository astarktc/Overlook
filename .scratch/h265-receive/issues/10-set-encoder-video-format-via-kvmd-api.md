# 10 — Pin the device encoder format via kvmd set_params (fixes live H.265)

**What to build:** When Overlook connects (and on codec-preference change / fallback), set the device's actual encoder format through the authenticated kvmd API — `POST /api/streamer/set_params?video_format=N` via the existing `GLKVMClient.setStreamerParams` — so the encoder always matches the codec negotiated in the Janus watch/SDP.

**Status:** ready-for-agent

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

- [ ] Decide placement: KVMDeviceManager connect flow and/or WebRTCManager codec-selection actions (set_params BEFORE the video watch request so the offer and bits match)
- [ ] Send `video_format` on: initial connect (per codec selection), codec-preference change, and H.264 fallback re-watch
- [ ] Handle the encoder-restart window (~1-2 s stream gap after a format change; the watchdog must not misfire during it)
- [ ] Consider interplay with the parked `-999 cancelled` set_params issue (rapid successive calls)
- [ ] Unit-test the policy wiring; live-verify H.265 end-to-end (tickets 04–08 checkboxes)
- [ ] Leave device codec state as found or report changes (operator guardrail)

## Comments

- Discovered during the 2026-08-12 live-debug session; full evidence chain in
  `docs/handoffs/2026-08-12-h265-live-debug-handoff.md` (RESOLVED addendum). The GL
  packetizer is textbook-correct — all packetization hypotheses (H1/H2/H3) were refuted
  by on-wire capture (`.scratch/h265-receive/tools/rtp_trace.py`).
- With `video_format: 1` currently restored in the device config (BDA, 2026-08-12), live
  H.265 likely works TODAY with no code change — but the config key is volatile, so this
  ticket is the durable fix. Client-driven set_params also makes Overlook independent of
  what other GL clients do to the persisted config.
