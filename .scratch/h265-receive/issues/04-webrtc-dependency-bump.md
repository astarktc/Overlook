# 04 — WebRTC dependency bump (109 → ≥150), zero behavior change

**What to build:** Bump the stasel WebRTC dependency from 109 to the newest release ≥150 (H.265 depacketizer and packet buffer are compiled into those binaries), landing the smallest possible diff with NO behavior change: the app builds, connects, and streams H.264 exactly as today. This is the riskiest step (40+ majors of API drift), which is why it lands alone, after ticket 03 — the decoder fixture tests green-before/green-after serve as the bump's regression net.

**Blocked by:** 03 — H.265 decoder module (its tests are this ticket's safety net).

**Status:** done pending live verification

- [x] Dependency pinned to the chosen ≥150 release; app and test targets build clean
- [x] All existing tests (decoder fixtures, policy matrix if present) still green on the new binary
- [ ] H.264 live streaming to the Comet verified working end-to-end (connect, video, input, audio, stats)
- [x] The reflection-based playout-delay-hint invocation re-verified against the new binary: confirm the selector still resolves and the hint still takes effect (it fails soft by design — silent loss would be an unnoticed latency regression)
- [x] The post-build codesign recipe (re-sign embedded WebRTC framework, then the app) confirmed still working with the new framework
- [x] Any API-drift adaptations documented in the ticket's comments for future bump reference

## Comments

- Chose stasel WebRTC `151.0.0`, the newest non-draft, non-prerelease release reported by the GitHub releases API on 2026-08-11 (`150.0.0` was the only other release meeting ≥150). Changed the Xcode package requirement from `upToNextMajorVersion` at 109.0.1 to an exact `151.0.0` pin for reproducibility. Package resolution selected revision `19aa8c1fc7120d50df987b7111f42d5024df3d54`.
- API drift adaptations: none. The app and test targets compiled against WebRTC 151.0.0 without source changes, preserving the zero-behavior-change scope.
- Regression net: the full command-line suite passed all 16 tests on the new framework. This includes both hardware H.265 full-fixture decode tests at 2560×1440, the decoder rejoin/parameter-set test, factory coverage, fixture hashes, and the exhaustive codec-policy matrix. Command: `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Debug -derivedDataPath /tmp/overlook-tests -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test` (`** TEST SUCCEEDED **`).
- Release build passed with WebRTC 151.0.0. Command: `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Release -derivedDataPath /tmp/overlook-build -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build` (`** BUILD SUCCEEDED **`).
- Playout-delay verification found that `setPlayoutDelayHint:` is absent from **both** the old 109.0.1 and new 151.0.0 macOS binaries. `nm -gU`, `strings`, headers, and `otool -ov` found no selector in cached 109.0.1 at `/tmp/webrtc109/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework` or resolved 151.0.0 at `/tmp/overlook-resolve/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework`; WebRTC 151's public `RTCRtpReceiver.h` has no delay setter. Thus the existing reflection helper was already taking its fail-soft no-op path before the bump, and 151 causes no new latency regression. Upstream M151's private C++ `RtpReceiverInterface` exposes the candidate modern API `SetJitterBufferMinimumDelay(std::optional<double>)`, but stasel does not ship that private/C++ interface. Per the zero-behavior-change constraint, no private ABI bridge was added and the harmless reflection code remains unchanged. Follow-up issue 09 tracks a deliberate repair and live latency proof.
- Post-build recipe passed on `/tmp/overlook-build/Build/Products/Release/Overlook.app`. The required ATS insertion produced `{"NSAllowsArbitraryLoads":true}`. Re-signing WebRTC and then the app each reported `replacing existing signature`; `codesign --verify --deep --strict --verbose=2` reported the embedded framework `--validated`, then `Overlook.app: valid on disk` and `Overlook.app: satisfies its Designated Requirement`.
- Pending operator verification: H.264 end-to-end streaming (connect, video, input, audio, and stats), actual app launch, and empirical playout latency remain unchecked. The Comet is a production tool attached to the operator's work Mac and currently in H.265 mode, so this agent did not launch the GUI, connect to it, SSH, reconfigure, or reboot it.
