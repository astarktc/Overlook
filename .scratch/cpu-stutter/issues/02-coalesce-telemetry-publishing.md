# 02 — Coalesce, equality-gate, and narrow telemetry publishing

**What to build:** While streaming with all overlays closed and the mouse still, the app's SwiftUI graph goes quiet: at most one invalidation per telemetry tick, zero when values are unchanged, and telemetry changes no longer re-evaluate the whole window — only the UI that displays them.

Scope (merged from former ticket 05):

- Remove the redundant `await MainActor.run` wrappers inside the already-`@MainActor` stats/latency paths so one polling tick is one transaction, not several.
- Collapse the ~15 scalar video/audio stats `@Published` vars into a single `Equatable` snapshot value published at most once per tick and only on change (with display-rounding tolerances so jittering decimals that render identically don't publish).
- Equality-gate the remaining periodic publishes: stream-health age/stall flags, `inboundFps`, `latency`, `videoSize`.
- Narrow observation: the snapshot lives on a stats-focused observable consumed only by the views that render stats (connections popover stats section, status bar if it shows telemetry). `ContentView` and `VideoSurfaceView` stop observing telemetry entirely — they keep only connection-state observation.

**Blocked by:** None — can start immediately.

**Status:** in-review

- [ ] With the diag build (`OVERLOOK_DIAG_PRINT_CHANGES=1`), steady-state streaming shows ≤1 `ContentView` body evaluation per second, and it is not caused by telemetry (target: ~0) — pending orchestrator runtime validation
- [ ] Unchanged telemetry values produce no `objectWillChange` (verifiable by log or by eval counts while stream stats are steady) — pending orchestrator runtime validation (structurally enforced: every telemetry write goes through `StreamTelemetryModel.publish`, which returns early on `==`)
- [ ] Stats UI still updates correctly when values genuinely change (open the connections popover and watch kbps/fps move) — pending orchestrator runtime validation
- [x] The negotiated codec / fallback status surface still updates per CONTEXT.md rules — the Negotiated Codec surface never went through telemetry: `negotiatedCodec` is still a `@Published` on `WebRTCManager`, still set only by `applyCodecSelectionState`, and `StatusBarView` still receives it directly. No connect/watchdog/fallback/reconnect code was touched; `CodecSelectionPolicyTests` pass.

## Comments

### Implementation (ticket 02)

Design:

- `Overlook/StreamTelemetry.swift` — `StreamTelemetry` (Equatable snapshot: latency, video kbps/fps/playout/jitter/decode/lost/RTT, audio kbps/playout/jitter/lost/RTT, all quantized to the precision the UI renders), the `VideoStatsSample`/`AudioStatsSample` per-tick collector results, and `StreamTelemetryModel` (`@MainActor ObservableObject`, one `@Published private(set) var snapshot`, single equality gate in `publish`, batch `update`, `reset`).
- `WebRTCManager` owns it as a plain `let telemetry` (deliberately not `@Published`), and its own interface lost 12 `@Published` vars (`latency`, `inboundVideoKbps`, `inboundFps`, `inboundVideo{PlayoutDelayMs,JitterMs,DecodeMs,PacketsLost}`, `iceCurrentRoundTripTimeMs`, `inboundAudio{Kbps,PlayoutDelayMs,JitterMs,PacketsLost}`, `audioIceCurrentRoundTripTimeMs`).
- `measureStreamStats` no longer hops: the four `await MainActor.run` blocks are gone (the class is already `@MainActor`) and it now splits into `collectInboundVideoStats` / `collectInboundAudioStats`, which return samples; the tick ends in exactly one `telemetry.update` → at most one transaction per tick, zero when nothing rendered changes.
- Equality-gated on `WebRTCManager`: `lastVideoFrameAgeSeconds`, `isStreamStalled`, `lastDisconnectReason` (new private `set…` helpers used by the 1 Hz health tick and teardown), `videoSize` (`videoSize != size`), and fps (now published as whole frames, so the 2 Hz window is usually a no-op).
- Observation narrowed: `ContentView` and `VideoSurfaceView` read only connection state (`isConnected`/`isConnecting`/`isStreamStalled`/`hasEverConnectedToStream`/`lastDisconnectReason`/`lastVideoFrameAgeSeconds`/`negotiatedCodec`/`videoView`/`videoSize`/`currentFrame`). `ConnectionsPopoverView` lost 14 stats params; telemetry is rendered by three leaves that observe `StreamTelemetryModel` themselves — `StreamStatsSection`, `ConnectionLatencyLabel` (reused by `StatusBarView`), and `WindowTitleTelemetryHost` (the `// ticket 04` stopgap that keeps kbps/fps in the window title without putting telemetry back into `ContentView`'s body).
- `OverlookApp` injects `webRTCManager.telemetry` as an environment object.
- The `[DEBUG-swiftui-audit]` kill switches were re-homed, not removed: `OVERLOOK_DIAG_NO_STATS` still short-circuits `measureStreamStats`/`measureLatency`, `NO_HEALTH` still gates the health writes, `NO_FPS` now gates the fps telemetry write, `NO_WINDOW_SETTERS`/`NO_RENDER_HOP` untouched, and every `Self._printChanges()` line is preserved (plus one in each new telemetry leaf). `DiagFlags` moved to `Overlook/DiagFlags.swift` so it also compiles into the test target — which fixes a pre-existing break: on this branch `xcodebuild … test` failed with "Cannot find 'DiagFlags' in scope" before this change.

Verification: `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Debug -derivedDataPath build/ticket02 build` → `** BUILD SUCCEEDED **`; `xcodebuild … -destination 'platform=macOS' test` → `** TEST SUCCEEDED **`. Runtime eval-rate/stat-freshness validation needs a live device stream and is left to the orchestrator.
