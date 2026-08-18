# 02 — Coalesce, equality-gate, and narrow telemetry publishing

**What to build:** While streaming with all overlays closed and the mouse still, the app's SwiftUI graph goes quiet: at most one invalidation per telemetry tick, zero when values are unchanged, and telemetry changes no longer re-evaluate the whole window — only the UI that displays them.

Scope (merged from former ticket 05):

- Remove the redundant `await MainActor.run` wrappers inside the already-`@MainActor` stats/latency paths so one polling tick is one transaction, not several.
- Collapse the ~15 scalar video/audio stats `@Published` vars into a single `Equatable` snapshot value published at most once per tick and only on change (with display-rounding tolerances so jittering decimals that render identically don't publish).
- Equality-gate the remaining periodic publishes: stream-health age/stall flags, `inboundFps`, `latency`, `videoSize`.
- Narrow observation: the snapshot lives on a stats-focused observable consumed only by the views that render stats (connections popover stats section, status bar if it shows telemetry). `ContentView` and `VideoSurfaceView` stop observing telemetry entirely — they keep only connection-state observation.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] With the diag build (`OVERLOOK_DIAG_PRINT_CHANGES=1`), steady-state streaming shows ≤1 `ContentView` body evaluation per second, and it is not caused by telemetry (target: ~0)
- [ ] Unchanged telemetry values produce no `objectWillChange` (verifiable by log or by eval counts while stream stats are steady)
- [ ] Stats UI still updates correctly when values genuinely change (open the connections popover and watch kbps/fps move)
- [ ] The negotiated codec / fallback status surface still updates per CONTEXT.md rules
