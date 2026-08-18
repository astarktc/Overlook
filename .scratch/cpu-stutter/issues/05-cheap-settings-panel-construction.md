# 05 — Cheap settings panel construction

**What to build:** Constructing a `WebUISettingsPanel` value is near-free: the `NumberFormatter` and the ~17 KB of EDID option tables/overrides are created once per process, not on every view-struct instantiation, and the panel body is split into section subviews so a change in one section doesn't re-evaluate the others.

**Blocked by:** None — can start immediately. (Complements 03; still worthwhile because the panel re-instantiates on every parent pass while open.)

**Status:** ready-for-agent

- [ ] Formatter, EDID options, EDID overrides, and other immutable option tables are `static let` (or module-level constants) — no per-instantiation allocation
- [ ] Panel body decomposed into per-section subviews with narrow inputs
- [ ] All settings functionality unchanged (spot-check: video quality preset, EDID selection incl. custom draft, streamer fields, codec preference)
