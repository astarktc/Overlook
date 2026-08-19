# 03 — H.265 decoder module decoding real Comet bitstreams

**What to build:** The hand-written VideoToolbox H.265 decoder and its decoder factory (per ADR-0001), proven offline against the real Comet fixtures before any live wiring. The decoder ports HackWebRTC's VTDecompressionSession wrapper (WebKit's implementation as cross-reference where behavior questions arise), carries shiguredo's `vps_max_num_reorder_pics` fix, and handles in-band VPS/SPS/PPS with Annex-B→hvcC conversion. The factory advertises H.265 with `profile-id=1` (matching the Comet's offer) alongside the existing H.264 support; the encoder side remains H.264-only. Everything compiles against the CURRENT WebRTC dependency (the decoder protocol exists there) — the dependency bump is a separate, later ticket, and this ticket's tests are its regression net.

**Blocked by:** 01 — Test scaffolding.

**Status:** done

- [x] Decoder decodes the steady-state fixture on real VideoToolbox hardware: asserted decoded-frame count and 2560×1440 output dimensions
- [x] Decoder decodes the rejoin fixture (exercises mid-stream parameter-set handling)
- [x] Parameter-set changes mid-stream (new VPS/SPS/PPS before an IDR) recreate/reconfigure the decompression session rather than erroring
- [x] The shiguredo VPS fix is present and noted with a comment explaining the time-to-first-frame symptom it prevents
- [x] The factory's advertised codec list includes H.265 `profile-id=1` and is covered by a test
- [x] Hardware-only decode: no software HEVC fallback of any kind (licensing posture per ADR-0001)
- [x] All tests green via the command-line test invocation; app target still builds (module is not yet wired into the app)

## Comments

- Added `RTCVideoDecoderH265`, conforming to the WebRTC 109 `RTCVideoDecoder` protocol. It extracts in-band VPS/SPS/PPS, creates an HEVC `CMVideoFormatDescription`, converts Annex-B access units to four-byte length-prefixed samples, and drains asynchronous VideoToolbox callbacks through a VPS-sized reorder queue.
- A byte change in any VPS/SPS/PPS combination causes the current `VTDecompressionSession` to finish/wait for outstanding frames, invalidate, and recreate against the new format. Repeated identical per-GOP parameter sets remain a no-op. The rejoin and sample-then-rejoin interface tests exercise repeated in-band parameter-set handling without inspecting decoder internals.
- Decode is hardware-only: session creation sets `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`, then verifies `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`; there is no software decoder dependency or fallback path.
- Added `OverlookVideoDecoderFactory`, which preserves every codec from `RTCDefaultVideoDecoderFactory`, adds `H265` with `profile-id=1`, creates the custom H.265 decoder, and delegates every other codec to the SDK default. `WebRTCFactoryBuilder.m` remains untouched for ticket 05.
- Ported-source provenance: decoder lifecycle and rewrite behavior were adapted from HackWebRTC/webrtc `sdk/objc/components/video_codec/RTCVideoDecoderH265.mm` and `nalu_rewriter.{h,cc}` at commit `7abfc990c00ab35090fff285fcf635d1d7892433`. VPS `vps_max_num_reorder_pics` parsing/reorder sizing was adapted from shiguredo-webrtc-build `patches/h265.patch` and `patches/h265_ios.patch` at commit `c0fba486c712cce45d32e5390b73934c53f0ce67`; the code comment records that reading the VPS depth avoids buffering a generic maximum before the first decoded-frame callback (long time-to-first-frame).
- Fixture results from the independent test-side Annex-B scan: `lab28-h265-sample.bin` decoded 358/358 slice NALUs at 2560×1440; `lab28-h265-rejoin.bin` decoded 478/478 at 2560×1440. The sample-then-rejoin continuity test decoded 122/122 through one decoder instance.
- Tests added: four H.265 decoder/factory XCTest methods. The two full-fixture tests use asynchronous expectations and count callbacks without assuming callback order.
- Test command (exit 0): `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Debug -derivedDataPath /tmp/overlook-tests -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test`
- Release build command (exit 0): `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Release -derivedDataPath /tmp/overlook-build -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build`
