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
