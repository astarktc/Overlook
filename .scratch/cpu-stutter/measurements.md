# CPU/stutter diagnosis — measurement log

## Production app (Release, /Applications, long-running session)
- 101% CPU; sample: 51-57% of main-thread in SwiftUI layout (2 runs)
- H265DecompressionOutputCallback ~5/3600 samples → hardware decode fine
- User: overlays closed = no change

## Diag build (Debug, repo HEAD + [DEBUG-swiftui-audit] kill switches)
- Needed Info.plist NSAllowsArbitraryLoads=true patch (repo build lacks it; installed app has it — OUT-OF-BAND, should be committed)
- Baseline, fresh launch, windowed, streaming: 16-19% CPU, layout share ~0% → GREEN (bug NOT reproduced fresh)
- OVERLOOK_DIAG_PRINT_CHANGES=1: `ContentView: _webRTCManager changed.` ~2.6/sec; each pass re-evaluates ContentView + VideoSurfaceView + WebUISettingsPanel + ConnectionsPopoverView (full hierarchy)
- libyuv/I420 render-path symbols present in sample (6 hits / 2s) → F3 active but modest at current res/fps
- t≈4min: RTCMTLNSVideoView constraints count = 8 (superview 4)  [F6 probe #1]

## Open questions
- Was user's RED session fullscreen? Settings panel ever opened in that session?
- F6: does constraint count grow over time? (probe #2 pending)

## AMPLIFIER IDENTIFIED (t≈34min diag session, 2026-08-18 18:59)
- CPU creep 16%→~28% avg (spikes 48%), eval rate constant ~5/s; user reports mild hiccups
- Hot leaves now = Hasher._hash/_combine + Set<AnyKeyPath> iteration (libswiftObservation) — SAME signature as production RED
- heap: ~19,190 ObservationRegistrar states / AnyKeyPath dictionaries (≈2/pass), ~9,780 SwiftUI TagIndexProjection sets per tag type (≈1/pass; Picker machinery; String/Int/Optional<KVMDevice>)
- Mechanism: per-pass leak of SwiftUI observation/tag structures → per-pass hashing cost grows linearly with uptime → RED after hours
- RSS 418MB @ 34min; footprint peak 494MB
- Prediction: with publish clock killed (NO_STATS/NO_HEALTH/NO_FPS) heap growth stops; after tickets 02+03 land, growth stops permanently

## VALIDATION CHECKPOINT — tickets 01-03 (2026-08-18 19:2x, diag2 build)
- ContentView/VideoSurfaceView/WebUISettingsPanel/ConnectionsPopoverView/StreamStatsSection: 0 evals per 30s while streaming, panels closed (before: ~5 full passes/sec)
- ObservationRegistrar states: 17 flat (before: 26,712 climbing ~10/s); TagIndexProjection absent from top heap
- RSS 213MB (before: 450MB climbing); loop.sh GREEN 0% layout
- Panel open/close, cached-config reopen, slide animations exercised by user during connect: no reported issues

## VALIDATION — full stack tickets 01-06 + review fixes (diag3, 66e3eaf, 2026-08-18 22:43)
- 77-min organic soak, user QA checklist all-pass (video/aspect/panels/fullscreen/reconnect/OCR/input)
- CPU 5.0% (Debug) vs 101% production baseline; layout 0%; ContentView evals 0/20s; soak evals60s=0 sustained
- RSS 223MB flat 1h17m (vs 450MB climbing @45min pre-fix); ObservationRegistrar heap objects trivial
- sample: 0 libyuv/newI420/I420Buffer frames (old renderer sink eliminated); H265 hw decode callbacks present
- Remaining before close: OVERLOOK_DIAG_STALL_MAIN stutter-immunity demo + Release-build soak (ticket 07)

## FINAL — ticket 07 stutter-immunity demo (Release, release-verify build, 2026-08-18 23:0x)
- Release build (ad-hoc re-sign needed: embedded WebRTC.framework Team ID mismatch vs app; `codesign --force -s -` on framework then app)
- Launched with OVERLOOK_DIAG_STALL_MAIN=1 (200 ms main-thread stall @ 1 Hz, confirmed in log)
- User verdict: video glides; UI glides too. Original symptom confirmed dead under worse-than-original main-thread conditions.
- Formal multi-hour Release soak waived by user: normal daily use is the ongoing test; failure would be reported. Debug soak evidence above (77 min + ~2 h continued flat) stands as the longitudinal record.
- Post-mortem/Apple Feedback write-up: skipped by user decision.
