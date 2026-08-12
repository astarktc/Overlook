# Spec: H.265 (HEVC) WebRTC receive

Status: ready-for-agent

## Problem Statement

The operator's daily-driver KVM client (Overlook) can only decode H.264, while the GL.iNet Comet it connects to already encodes H.265 with visibly better picture quality — sharper text and less gradient banding, proven end-to-end via the GL web UI. Worse, the device currently sits in H.265 mode, so stock Overlook shows no video at all; the operator is stuck using the GL web UI in Safari as an interim client and losing Overlook's superior input handling, latency tuning, and macOS integration.

## Solution

Overlook gains an H.265 receive path: it asks the device for H.265 in its Watch Request, negotiates the codec over SDP, and decodes via VideoToolbox hardware. The operator gets a per-device Codec Preference (Auto / H.265 / H.264, defaulting to Auto), and the status bar always shows the Negotiated Codec. When H.265 can't be negotiated or doesn't produce frames, Overlook falls back to H.264 automatically and visibly — never a silent black screen, and never a hidden sticky downgrade: any Operator-Initiated Connect retries H.265 fresh.

## User Stories

1. As a KVM operator, I want Overlook to stream H.265 from the Comet, so that I get sharper text and less banding on my daily driver instead of only in the GL web UI.
2. As a KVM operator, I want Overlook to work against the device while it is in H.265 mode, so that the current "no video in stock Overlook" state is fixed and I can retire the web-UI workaround.
3. As a KVM operator, I want H.265 decode to run in hardware (VideoToolbox), so that latency and CPU usage stay at parity with today's H.264 path.
4. As a KVM operator, I want a Codec Preference of Auto / H.265 / H.264 per device, so that I can pin a codec when a device misbehaves without affecting my other devices.
5. As a KVM operator, I want Auto to be the default preference, so that I get the best codec the connection supports without configuring anything.
6. As a KVM operator, I want the preference picker to live beside the existing stream settings (bitrate/quality), so that all stream tuning is in one place.
7. As a KVM operator, I want Overlook to fall back to H.264 automatically when the device's offer lacks H.265, so that connecting to an H.264-only device just works.
8. As a KVM operator, I want a first-frame watchdog that falls back to H.264 when an H.265 stream never produces a decoded frame, so that a negotiation-succeeded-but-decode-starved failure heals itself instead of showing a black screen.
9. As a KVM operator, I want the status bar to show the Negotiated Codec, so that I always know what's actually flowing.
10. As a KVM operator, I want a fallback to display as "H.264 (fallback)" rather than plain "H.264", so that a downgraded session is never silent.
11. As a KVM operator, I want Automatic Reconnects to reuse the remembered fallback, so that a flaky device doesn't cost me a watchdog-timeout of black screen on every blip.
12. As a KVM operator, I want any Operator-Initiated Connect to retry H.265 fresh, so that my own action is the reset button and a transient failure never leaves me stuck on H.264 indefinitely.
13. As a KVM operator, I want Overlook to select the codec purely through its Watch Request, so that my client never edits persistent device configuration and other clients (e.g. the GL web UI) are unaffected.
14. As a KVM operator, I want existing stream stats (bitrate, fps, decode time, jitter) to keep working under H.265, so that I can compare codecs and diagnose issues the same way I do today.
15. As a KVM operator, I want audio, input, and every non-video feature to behave identically after this change, so that the codec work carries zero collateral risk to my production tool.
16. As a KVM operator, I want explicit H.265 preference on an H.264-only device to fall back visibly rather than fail, so that a wrong pin degrades gracefully.
17. As the fork maintainer, I want the WebRTC dependency bumped to a current release as part of this work, so that the codebase stops sitting 40+ majors behind and future codec/API work is unblocked.
18. As the fork maintainer, I want the decoder validated offline against real Comet bitstream fixtures, so that decode correctness is proven before any live WebRTC wiring and regressions are caught without a device on the desk.
19. As the fork maintainer, I want the codec-selection policy implemented as a pure, exhaustively-tested module, so that the fallback matrix is verifiable without a network or device.
20. As the fork maintainer, I want the fork to remain cleanly mergeable with upstream, so that future upstream improvements can be pulled without dependency-swap conflicts.

## Implementation Decisions

- **Route (ADR-0001)**: keep the existing stasel WebRTC dependency and bump it from 109 to ≥150 (H.265 depacketizer/packet buffer are in those binaries); hand-write the VideoToolbox H.265 decoder and a decoder factory. The LiveKit xcframework swap was explicitly rejected — see ADR-0001 for the evidence and reasons. Decode is hardware-only (VideoToolbox); never link a software HEVC decoder (patent-pool licensing posture).
- **Decoder module** (one deep module, interface = libwebrtc's decoder-factory protocol): ports HackWebRTC's VTDecompressionSession wrapper (WebKit's implementation as cross-reference), carries shiguredo's `vps_max_num_reorder_pics` fix (prevents long time-to-first-frame), performs Annex-B→hvcC parameter-set handling, and advertises H.265 with `profile-id=1` to match the Comet's offer. It plugs into the app at the existing factory-builder construction seam (a one-line change there); the encoder side keeps advertising H.264 only.
- **Codec-selection policy module** (the one new seam): a pure, side-effect-free state machine owning all Auto-mode logic — inputs are the per-device Codec Preference, connection kind (Operator-Initiated Connect vs Automatic Reconnect), offer contents, and watchdog events; outputs are the Video Format to request, the Negotiated Codec to display, and fallback-memory transitions. The WebRTC manager consumes its decisions at the watch-request, offer-handling, and watchdog points and contains no codec-selection branching of its own.
- **Signaling**: the video Watch Request gains a `video_format` param (H264 = 0, H265 = 1) driven by the policy module. The device follows the client; Overlook never reads or writes persistent device configuration. The audio Watch Request is untouched.
- **Fallback semantics**: Auto requests H.265; falls back to H.264 when the offer lacks H.265 or the first-frame watchdog fires (no decoded frame within a timeout after negotiation — build on the existing stream-health/frame-age machinery rather than new monitoring). Fallback memory is app-session-scoped and consulted only by Automatic Reconnects; Operator-Initiated Connects (device selection, manual reconnect, preference change) always retry H.265. No timed auto-retry/cooldown in v1.
- **UI**: Codec Preference picker (Auto / H.265 / H.264) added to the existing device settings panel alongside the stream/bitrate controls, persisted per device (keyed by device id, default Auto). Negotiated Codec displayed in the status bar view, with an explicit "(fallback)" suffix when a fallback produced it. Both consume new published state on the WebRTC manager — no new UI seams.
- **Dependency-bump verification**: the reflection-based `setPlayoutDelayHint:` invocation must be re-verified against the new binary (it fails soft by design, but silent loss of low-latency playout would be a regression). The post-build codesign and ATS steps are unchanged by this work and remain required.
- **Fixtures**: the two verified Comet bitstream captures (2560×1440@60, GOP 60, parameter sets before every IDR) move from the incoming drop zone into the test layout and are committed as test resources.

## Testing Decisions

- A good test exercises external behavior at a module's interface — decoded frames out for bitstream in, decisions out for events in — never internal state or implementation details.
- **A unit-test target is created** — the project currently has none. This is the feature's first test infrastructure; there is no prior art in the codebase, so these tests set the pattern.
- **Decoder module tests** (highest seam short of a live Janus session): feed the real Comet Annex-B fixtures through the full decoder interface (parameter-set handling, Annex-B→hvcC conversion, VTDecompressionSession) on real VideoToolbox hardware; assert decoded frame counts and 2560×1440 dimensions. Both fixtures run: the steady-state capture and the rejoin capture (exercises mid-stream parameter-set handling). No network, no WebRTC session, no device required.
- **Policy module tests**: exhaustive table-driven coverage of the fallback matrix — every preference × connection kind × offer content × watchdog outcome combination, including: Auto negotiating H.265; offer-based fallback; watchdog fallback; fallback memory honored by Automatic Reconnect; memory cleared by each kind of Operator-Initiated Connect; explicit H.265 pin falling back visibly; explicit H.264 pin never requesting H.265. Pure logic, zero I/O.
- **Not tested**: SwiftUI views (no prior art, declarative), live-device end-to-end (manual acceptance instead), the Janus signaling exchange (exercised manually; the policy seam isolates its logic).
- Manual acceptance (from the handoff): Overlook streams H.265 from the Comet at 2560×1440@60 with quality parity to the GL web UI's H.265 stream and latency parity to current Overlook H.264.

## Out of Scope

- H.265 **encode**/send (mic/camera paths) — receive only.
- Any audio-path changes; the custom audio device shim is untouched.
- Reading or writing persistent device configuration (the device's `video_format` config flag stays whatever it is).
- Timed auto-retry of H.265 after fallback (cooldown) — deliberately deferred; revisit only if the visible-fallback + manual-retry loop proves annoying in practice.
- Upstreaming to the parent repo (design stays upstream-friendly per ADR-0001, but no PR work).
- Other devices' H.265 quirks (JetKVM etc.) — the Comet is the only validated target; the fallback path is the safety net elsewhere.
- 10-bit / 4:4:4 formats — the device encodes 8-bit 4:2:0 for both codecs; chroma fringing on text is inherent and not addressable here.
- Bitrate/GOP tuning changes — encoder parameters stay device-driven as today.

## Further Notes

- **Both empirical gates from the handoff are closed with evidence**: (a) the rejected route's feasibility was verified by binary disassembly before rejection (see ADR-0001); (b) the Comet's in-band parameter sets were bitstream-verified — VPS+SPS+PPS immediately precede every IDR (14/14 across two captures, zero exceptions), satisfying the libwebrtc depacketizer's hard requirement.
- A real-world reminder of why the factory must advertise H.265 explicitly: Edge on this Mac reports no H.265 receive capability, so the GL web UI correctly fell back to H.264 there — capability gating in default factories is exactly what Overlook must not rely on.
- Sequencing intent: the decoder module + its fixture tests are buildable and provable **before** the dependency bump or any signaling work; the policy module likewise. The dependency bump is the riskiest step and should land with the smallest possible diff around it.
- Domain vocabulary (Codec Preference, Video Format, Watch Request, Negotiated Codec, Fallback, Operator-Initiated Connect, Automatic Reconnect) is defined in the repo glossary; use it in issue titles and test names.
- Lab-side tracking: milestone outcomes mirror to LAB-28 (handled by the BraindumpAssistant session); day-to-day tickets live in this directory per the issue-tracker convention.
