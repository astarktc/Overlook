# 02 — Codec-selection policy module, exhaustively tested

**What to build:** A pure, side-effect-free policy module owning every codec-selection decision, so the fallback matrix is verifiable with zero I/O. Inputs: the per-device Codec Preference (Auto / H.265 / H.264), the connection kind (Operator-Initiated Connect vs Automatic Reconnect), offer contents (does the offer include H.265?), and watchdog events (first decoded frame arrived / watchdog fired). Outputs: the Video Format to request in the Watch Request, the Negotiated Codec to display (including its fallback provenance), and fallback-memory transitions (session-scoped; consulted only by Automatic Reconnects; cleared by any Operator-Initiated Connect). Use the repo glossary's terms verbatim in the module's vocabulary and test names.

**Blocked by:** 01 — Test scaffolding.

**Status:** done

- [x] The module is pure (no networking, no UI, no persistence, no timers — callers own all side effects)
- [x] Table-driven tests cover the full matrix: preference × connection kind × offer content × watchdog outcome
- [x] Covered explicitly: Auto negotiates H.265 happy path; offer-based fallback; watchdog fallback; fallback memory honored by Automatic Reconnect; memory cleared by each kind of Operator-Initiated Connect (device selection, manual reconnect, preference change); explicit H.265 pin falls back visibly; explicit H.264 pin never requests H.265
- [x] The Negotiated Codec output distinguishes a fallback result from a natively-negotiated one (feeds the "(fallback)" display later)
- [x] All tests green via the command-line test invocation

## Comments

- Added `CodecSelectionPolicy.swift` as a pure transition module compiled directly into both the app and non-hosted test targets. Its `connect`, `handleOffer`, and `handleWatchdog` interface returns the next Watch Request Video Format, optional Negotiated Codec, and session-scoped Fallback memory without performing side effects.
- Modeled H.264 results as `.h264` versus `.h264Fallback`, preserving visible Fallback provenance. `VideoFormat` uses the required wire values (`h264 = 0`, `h265 = 1`).
- An Operator-Initiated Connect carries an explicit reason (`deviceSelection`, `manualReconnect`, or `codecPreferenceChange`) and always clears Fallback memory. Automatic Reconnect honors remembered Fallback for Auto and H.265. Explicit H.264 clears/ignores Fallback memory and never requests H.265.
- TDD evidence: the first test run failed as expected with exit 65 because the policy types did not exist; implementation then made the suite green.
- Tests: 10 new XCTest methods, including a table-driven 96-row matrix covering both Fallback-memory inputs across 3 Codec Preferences × 4 concrete connection cases (3 Operator-Initiated Connect reasons plus Automatic Reconnect) × 2 offer contents × 2 watchdog events.
- Test command (exit 0): `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Debug -derivedDataPath /tmp/overlook-tests -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test`
- Release build command (exit 0): `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Release -derivedDataPath /tmp/overlook-build -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build`
