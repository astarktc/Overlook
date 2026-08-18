# 03 — Unmount the settings and connections panels when closed

**What to build:** When the settings panel or connections popover is closed, it costs nothing: its body is never evaluated and it participates in no layout pass. Opening still slides it in smoothly, and any state that must survive a close (loaded device config, in-progress drafts, expansion state) survives.

Approach constraints (from the audit): replace the always-mounted `.offset(x:)` pattern with conditional mounting plus `.transition(.move(edge: .trailing))`; hoist state that must outlive the view into parent-owned storage (e.g. a `@StateObject` view model) rather than keeping the view mounted.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] With the diag build (`OVERLOOK_DIAG_PRINT_CHANGES=1`), zero `WebUISettingsPanel` and zero `ConnectionsPopoverView` body evaluations while both are closed during steady-state streaming
- [ ] Open/close animation still slides from the trailing edge (no visual regression)
- [ ] Settings panel reopened after close shows previously loaded config without refetching-from-scratch flicker (state hoisted, not lost)
- [ ] The auto-open-connections-on-launch behavior still works
