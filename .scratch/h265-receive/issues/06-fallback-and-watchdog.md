# 06 — Fallback + first-frame watchdog integration

**What to build:** The self-healing paths, wired from policy-module decisions into the live connection flow. Offer-based Fallback: when the offer lacks H.265, re-watch with H.264. First-frame watchdog: when H.265 negotiates but no decoded frame arrives within the timeout, fall back to H.264 — composed with the existing stream-health/frame-age machinery rather than new monitoring. Fallback memory is app-session-scoped: Automatic Reconnects (stream drop, device blip) go straight to H.264 while remembered; any Operator-Initiated Connect (device selection, manual reconnect, Codec Preference change) clears the memory and retries H.265 fresh. No timed cooldown (deliberately out of scope). The worst failure mode — black screen on the operator's daily driver — becomes a visible, self-healing downgrade.

**Blocked by:** 05 — Live H.265 end-to-end.

**Status:** ready-for-agent

- [ ] Offer without H.265 results in a working H.264 stream with Negotiated Codec marked as a fallback
- [ ] Watchdog: an H.265 negotiation that produces no decoded frame within the timeout falls back to a working H.264 stream automatically (verifiable by forcing a decode-starved condition in a test or via a debug hook; document the method)
- [ ] Automatic Reconnect during remembered fallback goes straight to H.264 — no repeated watchdog-timeout black screen
- [ ] Each kind of Operator-Initiated Connect clears fallback memory and retries H.265
- [ ] Fallback memory does not survive an app restart
- [ ] Explicit H.265 preference on an H.264-only offer degrades visibly rather than failing
- [ ] All fallback branching lives in the policy module (already matrix-tested in 02); integration verified live and documented
