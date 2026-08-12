# 03 — H.265 decoder module decoding real Comet bitstreams

**What to build:** The hand-written VideoToolbox H.265 decoder and its decoder factory (per ADR-0001), proven offline against the real Comet fixtures before any live wiring. The decoder ports HackWebRTC's VTDecompressionSession wrapper (WebKit's implementation as cross-reference where behavior questions arise), carries shiguredo's `vps_max_num_reorder_pics` fix, and handles in-band VPS/SPS/PPS with Annex-B→hvcC conversion. The factory advertises H.265 with `profile-id=1` (matching the Comet's offer) alongside the existing H.264 support; the encoder side remains H.264-only. Everything compiles against the CURRENT WebRTC dependency (the decoder protocol exists there) — the dependency bump is a separate, later ticket, and this ticket's tests are its regression net.

**Blocked by:** 01 — Test scaffolding.

**Status:** ready-for-agent

- [ ] Decoder decodes the steady-state fixture on real VideoToolbox hardware: asserted decoded-frame count and 2560×1440 output dimensions
- [ ] Decoder decodes the rejoin fixture (exercises mid-stream parameter-set handling)
- [ ] Parameter-set changes mid-stream (new VPS/SPS/PPS before an IDR) recreate/reconfigure the decompression session rather than erroring
- [ ] The shiguredo VPS fix is present and noted with a comment explaining the time-to-first-frame symptom it prevents
- [ ] The factory's advertised codec list includes H.265 `profile-id=1` and is covered by a test
- [ ] Hardware-only decode: no software HEVC fallback of any kind (licensing posture per ADR-0001)
- [ ] All tests green via the command-line test invocation; app target still builds (module is not yet wired into the app)
