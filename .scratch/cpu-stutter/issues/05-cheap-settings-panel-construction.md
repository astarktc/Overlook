# 05 — Cheap settings panel construction

**What to build:** Constructing a `WebUISettingsPanel` value is near-free: the `NumberFormatter` and the ~17 KB of EDID option tables/overrides are created once per process, not on every view-struct instantiation, and the panel body is split into section subviews so a change in one section doesn't re-evaluate the others.

**Blocked by:** None — can start immediately. (Complements 03; still worthwhile because the panel re-instantiates on every parent pass while open.)

**Status:** in-review

- [x] Formatter, EDID options, EDID overrides, and other immutable option tables are `static let` (or module-level constants) — no per-instantiation allocation
- [x] Panel body decomposed into per-section subviews with narrow inputs
- [ ] All settings functionality unchanged (spot-check: video quality preset, EDID selection incl. custom draft, streamer fields, codec preference) — code-level parity verified, live spot-check still owed (needs a connected GLKVM device)

## What landed

Four files instead of one 1248-line view:

- `Overlook/EDIDCatalog.swift` — `EDIDOption` (was a private nested struct) plus `EDIDCatalog.options` / `.overrides` / `.resolvedEdid(...)` as `static let`. All 19 EDID blobs are byte-identical to the originals (verified by hashing the literals out of `HEAD:Overlook/WebUISettingsPanel.swift`).
- `Overlook/WebUISettingsActions.swift` — all panel behaviour (load, debounced config apply, EDID push, streamer draft sync/commit/apply, the `GLKVMSystemConfig` bindings) as one small `@MainActor` value type holding the model plus the three managers. `@MainActor` on the type reproduces the isolation the old code got implicitly from `View` conformance.
- `Overlook/WebUISettingsSections.swift` — one view per `DisclosureGroup`: `VideoSettingsSection` (plus `StreamerParamsSection`), `RemoteSettingsSection`, `KeyboardSettingsSection`, `AudioSettingsSection`, `SystemSettingsSection`, `NetworkSettingsSection`, `AdvancedSettingsSection`, plus `NotImplementedRow`. Each takes its expansion `@Binding`, the actions value, the model only when it renders model state, and an `@EnvironmentObject` only for managers whose published state it actually reads (Network takes nothing but its binding).
- `Overlook/WebUISettingsPanel.swift` — 207 lines of chrome: header, section list, error strip, error-history sheet.

Static-ised tables: `integerFormatter`, `processingOptions`, `reverseScrollingOptions`, `appAppearanceOptions`, `themeOptions`, `panelBackground`, the streamer resolution preset `Set` (was rebuilt on every binding get), the EDID catalog, and the two video-quality tag constants (now `WebUISettingsPanelModel.videoQualityCustomTag` / `videoQualityInsaneTag`).

Instrumentation: the panel keeps its `[DEBUG-swiftui-audit]` `Self._printChanges()` line, and each new section view got the same line, so the audit now attributes invalidations per section.

One deliberate mechanism change: the streamer `@FocusState` moved into `StreamerParamsSection` and is mirrored into `WebUISettingsPanelModel.focusedStreamerField` (plain, non-`@Published`) so `syncStreamerDraft` still refuses to clobber a field being edited; the mirror is cleared in `onDisappear`.

## Verification

- `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Debug -derivedDataPath build/ticket05 build` → `** BUILD SUCCEEDED **`
- `xcodebuild -project Overlook.xcodeproj -scheme Overlook -destination 'platform=macOS' test` → `** TEST SUCCEEDED **`, 23 passed / 2 skipped / 0 failed (baseline unchanged)
- Grep audit: the only instance stored properties left on the settings view structs are `let actions`, `let title`, the `@Binding`s, `@ObservedObject`, `@EnvironmentObject`, `@AppStorage`, and `@FocusState`. No non-static option table or formatter remains.

Unverified: visual/interactive spot-check of each section against a live device (video quality preset switch, EDID selection plus custom draft apply, streamer field debounce, codec preference) — orchestrator's pass.
