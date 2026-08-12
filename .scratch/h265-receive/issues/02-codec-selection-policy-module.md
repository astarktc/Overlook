# 02 — Codec-selection policy module, exhaustively tested

**What to build:** A pure, side-effect-free policy module owning every codec-selection decision, so the fallback matrix is verifiable with zero I/O. Inputs: the per-device Codec Preference (Auto / H.265 / H.264), the connection kind (Operator-Initiated Connect vs Automatic Reconnect), offer contents (does the offer include H.265?), and watchdog events (first decoded frame arrived / watchdog fired). Outputs: the Video Format to request in the Watch Request, the Negotiated Codec to display (including its fallback provenance), and fallback-memory transitions (session-scoped; consulted only by Automatic Reconnects; cleared by any Operator-Initiated Connect). Use the repo glossary's terms verbatim in the module's vocabulary and test names.

**Blocked by:** 01 — Test scaffolding.

**Status:** ready-for-agent

- [ ] The module is pure (no networking, no UI, no persistence, no timers — callers own all side effects)
- [ ] Table-driven tests cover the full matrix: preference × connection kind × offer content × watchdog outcome
- [ ] Covered explicitly: Auto negotiates H.265 happy path; offer-based fallback; watchdog fallback; fallback memory honored by Automatic Reconnect; memory cleared by each kind of Operator-Initiated Connect (device selection, manual reconnect, preference change); explicit H.265 pin falls back visibly; explicit H.264 pin never requests H.265
- [ ] The Negotiated Codec output distinguishes a fallback result from a natively-negotiated one (feeds the "(fallback)" display later)
- [ ] All tests green via the command-line test invocation
