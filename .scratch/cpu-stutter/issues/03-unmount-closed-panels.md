# 03 — Unmount the settings and connections panels when closed

**What to build:** When the settings panel or connections popover is closed, it costs nothing: its body is never evaluated and it participates in no layout pass. Opening still slides it in smoothly, and any state that must survive a close (loaded device config, in-progress drafts, expansion state) survives.

Approach constraints (from the audit): replace the always-mounted `.offset(x:)` pattern with conditional mounting plus `.transition(.move(edge: .trailing))`; hoist state that must outlive the view into parent-owned storage (e.g. a `@StateObject` view model) rather than keeping the view mounted.

**Blocked by:** None — can start immediately.

**Status:** in-review — code landed, runtime (diag-build) validation pending with the orchestrator.

- [ ] With the diag build (`OVERLOOK_DIAG_PRINT_CHANGES=1`), zero `WebUISettingsPanel` and zero `ConnectionsPopoverView` body evaluations while both are closed during steady-state streaming — **structurally guaranteed** (both views are now inside `if showingSettings` / `if showingConnections`, so SwiftUI cannot evaluate their bodies while closed), but not yet observed on a live stream: needs the orchestrator's runtime pass.
- [ ] Open/close animation still slides from the trailing edge (no visual regression) — implemented as `.transition(.move(edge: .trailing))` + container-level `.animation(.easeInOut(duration: 0.2), value:)` for both flags (covers the call sites that flip them without `withAnimation`). Needs a visual check.
- [x] Settings panel reopened after close shows previously loaded config without refetching-from-scratch flicker (state hoisted, not lost) — all survivable panel state moved to `WebUISettingsPanelModel` (`@MainActor ObservableObject`, owned by `ContentView` as `@StateObject`); `load()` still refreshes on mount and never nils cached state on the happy path, so the cached config renders immediately behind the spinner.
- [x] The auto-open-connections-on-launch behavior still works — `didAutoOpenConnections` logic untouched; it sets `showingConnections = true`, which now mounts the popover.

**Implementation notes**

- `Overlook/WebUISettingsPanelModel.swift` (new): loaded `config`/`keymaps`/`streamerState`, in-flight flags, error message + history, the seven section-expansion flags, EDID selection/draft state, video-quality preset, codec preference, streamer numeric + text drafts, debounced apply tasks, audio device lists.
- Left in the view: `@FocusState focusedStreamerField` (cannot live in an `ObservableObject`, and it is ephemeral by nature), the `@AppStorage` prefs, and all load/apply logic.
- `settingsLoadID` no longer includes `isPresented` (a mounted panel is by definition open); mounting runs `.task` once, which preserves load-on-open.
- `ConnectionsPopoverView` owns no `@State` — nothing to hoist (device list comes from `KVMDeviceManager`, selection is a `ContentView` binding).
- The `.allowsHitTesting(showingSettings)` / `.allowsHitTesting(showingConnections)` hacks were removed (only needed while the panels stayed mounted off-screen). `VideoSurfaceView`'s `.allowsHitTesting(!showingSettings)` is unrelated and kept.
- Verified: `xcodebuild … -derivedDataPath build/ticket03 build` → `** BUILD SUCCEEDED **`; `xcodebuild … -destination 'platform=macOS' test` → `** TEST SUCCEEDED **`, 23 passed / 2 skipped (unchanged from the pre-change baseline).
