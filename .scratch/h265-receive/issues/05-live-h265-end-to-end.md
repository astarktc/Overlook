# 05 — Live H.265 end-to-end (the tracer bullet)

**What to build:** The complete happy path: Overlook connects to the Comet and live H.265 video flows at 2560×1440@60. The video Watch Request carries the Video Format decided by the policy module (Auto → request H.265); the custom decoder factory from ticket 03 is plugged in at the existing factory construction seam; the SDP answer negotiates H.265; frames decode in hardware. The Negotiated Codec is exposed as published, observable state (consumed by UI in ticket 07). The WebRTC manager contains no codec-selection branching of its own — it asks the policy module. The audio Watch Request and everything non-video is untouched.

**Blocked by:** 02 — Policy module · 03 — Decoder module · 04 — Dependency bump.

**Status:** ready-for-agent

- [ ] Connecting to the Comet in Auto negotiates and streams live H.265 at 2560×1440@60 (device follows the client's Watch Request; no persistent device configuration is read or written)
- [ ] Negotiated Codec published as observable state and correct (H.265 when negotiated, H.264 when the device offers only H.264)
- [ ] Existing stream stats (bitrate, fps, decode time, jitter, packet loss) report correctly under H.265
- [ ] Input, audio, and all non-video features verified unaffected
- [ ] Codec-selection decisions flow exclusively through the policy module
- [ ] All tests green; manual live verification against the Comet documented in the ticket's comments (coordinate any device-mode needs with the operator — never reconfigure the device from this repo's tooling)
