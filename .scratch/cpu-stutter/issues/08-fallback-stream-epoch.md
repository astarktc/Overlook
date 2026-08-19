# 08 — Codec-fallback stream epochs: a late old-codec frame can satisfy the new stream's first-frame window

**Found by:** adversarial review of ticket 06 (`AVSampleBufferDisplayLayer` renderer). Deliberately **not** fixed there because it is **pre-existing behavior, not a regression** — the `ConnectionGenerationVideoRenderer` that ticket 06 replaced had exactly the same gap.

**Status:** ready-for-agent

**Blocked by:** none

## The finding (as reviewed)

The H.265 → H.264 codec fallback re-issues a Watch Request *inside the same connection*, so `connectionGeneration` does not change. The render path's only staleness dimension is that generation, which means a frame decoded from the **abandoned** stream is still "current" after the fallback:

- `applyAndActOnCodecSelectionState(.reissueVideoWatchRequest)` clears the stream-health frame clock (`setLastVideoFrameTime(nil)`) to give the replacement stream its own initial-frame window, and flushes the display.
- `VideoRenderControl.admitFrame` reports `isFirstDecodedFrame` when that clock is nil. A frame that was decoded from the *old* codec's stream and lands a few milliseconds after the reissue is admitted (same generation) and reports itself as the replacement stream's first frame.
- That fires `videoRenderDidReceiveFirstFrame` → `handleFirstFrameWatchdogEvent(.firstDecodedFrameArrived)`, so the codec-selection policy can conclude the *new* codec is working when what actually arrived was the last frame of the codec being abandoned. It also resets `iceAutomaticReconnectAttempts` and stamps the health clock on the abandoned stream's behalf.

Symptom when it bites: fallback appears to succeed and the watchdog disarms, but no further frames arrive — a black stream with a green health signal, until the stall watchdog eventually notices.

How likely: needs a frame in flight in the fallback window. Rare but not synthetic — the fallback path exists precisely because H.265 frames may be arriving badly, and a decode-thread frame in flight during the reissue is the normal case rather than the exception.

## Why it is a separate ticket

It is a **stream**-identity problem, not a **connection**-identity problem. Fixing it means giving the render path a second epoch dimension that the codec-fallback path advances, and then deciding a policy question ticket 06 has no business deciding: *what counts as the first frame of a stream?* (Almost certainly: a frame decoded after the reissue, which in the general case can only be answered with something the wire gives us — SSRC, a decoder-instance identity, or a first-frame-after-flush marker rather than a wall-clock guess.)

## The foundation ticket 06 already built

Do not invent a new mechanism. Ticket 06's review fixes added exactly the epoch primitive this needs, in `Overlook/VideoRenderView.swift`:

- `VideoDisplayEngine.RenderToken` — an opaque monotonic epoch id.
- `VideoRenderView.RenderState` holds `(generation, token)` behind one unfair lock; the decode thread reads both atomically per frame in `renderFrame`.
- `beginRendering(generation:)`, `endRendering()` and **`flushDisplay()`** each advance the token; the enqueue queue validates the token *inside* the serialized enqueue operation, so a frame admitted before the transition is dropped rather than displayed.
- Crucially, **`flushDisplay()` already advances the token, and the codec-fallback path already calls it** (`applyAndActOnCodecSelectionState` → `videoView?.flushDisplay()`). So the abandoned stream's in-flight frames are already prevented from being *displayed*.

What is still missing is that the token is not consulted by the **signal** side: `VideoRenderControl.admitFrame` only knows about `generation`, so the abandoned stream's frame is still counted, still stamps the health clock, and can still claim `isFirstDecodedFrame`.

## Suggested shape

1. Give `VideoRenderControl` a stream epoch alongside `generation` (or pass the render token into `admitFrame` and have the control track the epoch it currently admits signals for), so the admission decision covers both dimensions in the same single lock acquisition. Keep the "one lock acquisition per frame, zero main-thread work" property — that is ticket 06's whole point.
2. Advance that stream epoch from the fallback path where `setLastVideoFrameTime(nil)` / `flushDisplay()` already happen, so the two stay in step by construction rather than by comment.
3. Decide and document what the replacement stream's first frame is, and make `isFirstDecodedFrame` mean exactly that — the watchdog/codec-selection policy depends on it.
4. Tests: a frame admitted in the pre-fallback epoch must not report `isFirstDecodedFrame`, must not stamp the health clock and must not be displayed, while the first frame of the new epoch does all three. The existing token-drop tests in `OverlookTests/VideoRenderViewTests.swift` (`testFramesFromThePreviousEpochAreDroppedAfterAFlushAdvancesTheToken`) are the pattern to extend.

## Verification

- Unit: the epoch tests above.
- Live: force a fallback (H.265 preferred against a stream that will not deliver) with a frame in flight, and confirm the watchdog does not disarm on the abandoned stream's frame. `OVERLOOK_FORCE_DECODE_STARVATION` is the existing hook for arming the first-frame watchdog deliberately.
