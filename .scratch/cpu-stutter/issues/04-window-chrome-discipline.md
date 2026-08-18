# 04 — Window chrome discipline (title + titlebar writers)

**What to build:** The window title is semantic and low-frequency (app name, device, connection state — no live kbps/fps), and no SwiftUI pass mutates window chrome as a side effect. Live telemetry appears only in the stats UI. This removes the audit's candidate self-sustaining invalidation loop (SwiftUI pass → `updateNSView` → async window mutation → geometry invalidation → another pass) and the ~1–2 Hz titlebar relayout churn.

Approach constraints (from the audit):

- Title changes only on connect/disconnect/device change; apply only when the string differs.
- No unconditional `titleVisibility` (or other chrome) writes; compare before writing; no `DispatchQueue.main.async` hop from `updateNSView` for same-value cases.
- Exactly one owner for `titleVisibility` / `toolbar.isVisible` (today both `WindowTitleSetter` and the aspect-ratio coordinator write them).

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] Window title contains no per-second telemetry; it changes only on connection/device state changes
- [ ] Fullscreen enter/leave still applies/restores chrome correctly (title visibility, toolbar, fullSizeContentView)
- [ ] Window aspect-ratio-on-first-video behavior unchanged
- [ ] With the diag build, `OVERLOOK_DIAG_NO_WINDOW_SETTERS=1` vs unset shows no measurable difference in SwiftUI eval rate (proves the setters are now inert passengers)
