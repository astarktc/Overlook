# 09 — Repair the fail-soft playout-delay hint no-op

**What to build:** Investigate and deliberately restore Overlook's low-latency receiver hint. The existing `setPlayoutDelayHint:` reflection path in `WebRTCFactoryBuilder.m` does not resolve in either stasel WebRTC 109.0.1 or 151.0.0, so the setting silently does nothing. Determine a supported, maintainable integration for the modern native API without coupling the app casually to libwebrtc's private C++ ABI.

**Status:** needs-triage

- [ ] Confirm the intended low-latency behavior and measurable acceptance threshold for video and audio
- [ ] Evaluate a supported stasel/ObjC API or an upstreamable wrapper before considering private ABI access
- [ ] If a native bridge is approved, use `webrtc::RtpReceiverInterface::SetJitterBufferMinimumDelay(std::optional<double>)` and document version/ABI coupling
- [ ] Add a regression test or instrumented verification that proves the hint reaches the receiver
- [ ] Verify latency against the production Comet with the operator

## Comments

- Discovered during ticket 04's WebRTC 109.0.1 → 151.0.0 bump. `nm -gU`, `strings`, framework headers, and `otool -ov` found no `setPlayoutDelayHint:` selector in either macOS framework binary. The current reflection helper therefore takes its fail-soft return path on both versions; this is a pre-existing no-op, not a bump regression.
- WebRTC 151's public `RTCRtpReceiver.h` exposes no playout-delay or jitter-buffer setter. Upstream M151's C++ `api/rtp_receiver_interface.h` does expose `SetJitterBufferMinimumDelay(std::optional<double>)`, and upstream's private Objective-C receiver wrapper has a `nativeRtpReceiver` property. stasel's xcframework does not ship those private/C++ headers, so bridging through it would introduce private ABI coupling and was intentionally excluded from the zero-behavior-change dependency bump.
- Ticket 04 evidence used the cached 109.0.1 artifact extracted to `/tmp/webrtc109/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework` and the resolved 151.0.0 artifact under `/tmp/overlook-resolve/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework`.
