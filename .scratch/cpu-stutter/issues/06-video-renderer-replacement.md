# 06 — Replace RTCMTLNSVideoView with a zero-copy off-main video renderer

**What to build:** Decoded video frames reach the screen without any CPU pixel-format conversion and without presenting on the main thread, so heavy main-thread work can no longer drop video frames. This is the fix for the visible stutter.

Background (binary-verified by audit): the bundled `RTCMTLNSVideoView` converts every frame NV12→I420 on the CPU (`newI420VideoFrame`, ~190 MB/s at 1080p60), uploads 3 planes on the main thread from `drawInMTKView:`, and has an `updateConstraints` that appends duplicate constraints unbounded.

Approach constraints (from the audit):

- New `RTCVideoRenderer` hands `RTCCVPixelBuffer.pixelBuffer` (NV12 IOSurface, straight from VideoToolbox) to an `AVSampleBufferDisplayLayer` — zero-copy, composited off the main thread. (Own `CAMetalLayer` + NV12 shader is the fallback if AVSBDL proves unsuitable.)
- Merge `ConnectionGenerationVideoRenderer`'s duties into the new renderer: first-frame watchdog signal, frame-time recording, FPS accounting done thread-locally (atomic/unfair lock), hopping to the main actor only for the throttled publish (≤2 Hz) and the one-shot first-frame event — no per-frame `Task { @MainActor }`.
- Keep the tracking/input container behavior (mouse mapping against the video rect) and the OCR frame-capture path working.
- Aspect handling: the layer uses `videoGravity = .resizeAspect`; `videoSize` publish stays for window aspect + input mapping, equality-gated.

**Blocked by:** 02, 03 (only so its CPU effect can be measured in isolation — start after they merge).

**Status:** in-review

- [ ] `sample` of the streaming app shows no `newI420VideoFrame` / libyuv / I420 upload frames — code-level: the conversion call site is gone (nothing references `RTCMTLNSVideoView`; hardware-decoded frames go to the display layer un-copied, asserted by `testSampleBufferWrapsThePixelBufferWithoutCopyingAndDisplaysImmediately`). A live `sample` still owed.
- [x] No per-frame main-actor task creation — `renderFrame` does lock-local bookkeeping plus one `dispatch_async`; the only `Task { @MainActor }`s are the once-per-connection first-frame signal, the ≤2 Hz fps publish and the ≤12 Hz OCR capture. Live `sample` spot-check still owed.
- [ ] Video still renders correctly: aspect fit, resolution changes mid-stream, reconnect, fullscreen — needs a live stream. Headless proxy: `testDecodedFramesReachTheDisplayedImage` proves enqueued frames really reach the displayed image through a window; `.resizeAspect` and format-description/flush-on-resolution-change are unit-asserted.
- [ ] Mouse input mapping and OCR capture still work — code-level preserved (container and `videoSize`/`currentFrame` semantics unchanged); live check owed.
- [ ] Under an artificial main-thread stall, video keeps playing smoothly — the decisive stutter test. Hook shipped: `OVERLOOK_DIAG_STALL_MAIN=1` (1 Hz × 200 ms main-thread sleep from app start). Running it is the orchestrator's pass.
- [ ] First-frame watchdog and stream-health frame timestamps still fire correctly — semantics preserved and unit-tested off-stream (generation guard, first-frame-once, suppression flag); live watchdog/fallback run owed.

## What landed

`Overlook/VideoRenderView.swift` (new, registered in both targets) holds four small types:

- **`VideoRenderControl`** — the connection state the render path needs per frame (current generation, OCR capture gate, watchdog-suppression flag, stream-health frame clock) behind one `OSAllocatedUnfairLock`. `admitFrame(generation:at:)` applies the generation guard, reads the gates and stamps the frame clock in a single acquisition. This replaced both the per-frame main-actor hop and the per-frame `streamHealthQueue.sync`.
- **`VideoFrameSignalThrottles` / `VideoFrameSignalGate`** — fps window (≤2 Hz publish, quantized to whole frames) and the 12 Hz OCR capture throttle as pure value math behind an unfair lock. The old `0` sentinel for "window not open" is now an optional, so the first window no longer depends on the clock's origin.
- **`VideoDisplayEngine`** — a serial `com.overlook.video-enqueue` queue that wraps the decoder's `CVPixelBuffer` in a `CMSampleBuffer` (`kCMTimingInfoInvalid` + `kCMSampleAttachmentKey_DisplayImmediately`) and enqueues it on `layer.sampleBufferRenderer`. The `CMVideoFormatDescription` is cached and recreated only when `CMVideoFormatDescriptionMatchesImageBuffer` fails (resolution/format change), which also flushes the layer. `status == .failed` / `requiresFlushToResumeDecoding` → flush and re-enqueue. A 6-deep dispatch backlog cap keeps a blocked layer from pinning the decoder's IOSurface pool. Software-decoded I420 (no IOSurface) is converted to NV12 once per frame — the rare, deliberately simple path.
- **`VideoRenderView`** — `NSView` whose backing layer *is* the `AVSampleBufferDisplayLayer` (`.resizeAspect`, black, opaque) and which conforms to `RTCVideoRenderer` itself. `beginRendering(generation:)` / `endRendering()` / `flushDisplay()` are its main-actor lifecycle.

`WebRTCManager`: `videoView` is a `VideoRenderView`, `ConnectionGenerationVideoRenderer` is deleted, the two `track.add` calls collapse to one, teardown removes the view and calls `endRendering()`, every `connectionGeneration` bump goes through `bumpConnectionGeneration()` so the render path sees it, and the frame-path duties moved out to a `VideoRenderSignalSink` conformance (first frame / fps / captured frame / size), each still generation-guarded and equality-gated. A Fallback Watch Request now also flushes the display.

`DiagFlags`: `OVERLOOK_DIAG_STALL_MAIN=1` plus `MainThreadStallInjector`, installed from `OverlookApp.init`. `OVERLOOK_DIAG_NO_RENDER_HOP` now gates the renderer's main-actor hops only — video keeps flowing under it.

## Verification

- `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Debug -derivedDataPath build/ticket06 build` → `** BUILD SUCCEEDED **`, zero new warnings (the two remaining warnings are pre-existing; verified by building the stashed tree).
- `xcodebuild -project Overlook.xcodeproj -scheme Overlook -destination 'platform=macOS' test` → `** TEST SUCCEEDED **`, 41 passed / 2 skipped / 0 failed (baseline 23/2; 18 new tests, no regressions).
- Grep audit: zero code references to `RTCMTLNSVideoView` (one doc-comment mention of what this replaces), `ConnectionGenerationVideoRenderer` gone, no `Task`/`DispatchQueue.sync` in the per-frame path.

Unverified (needs a live GLKVM stream — orchestrator's runtime pass): video appears at all, aspect fit, mid-stream resolution change, reconnect/teardown symmetry, fullscreen, mouse-position mapping, OCR selection/recognition, fps readout, first-frame watchdog + H.264 fallback, `OVERLOOK_DIAG_STALL_MAIN=1` stall immunity, and a `sample` confirming no libyuv/I420 conversion and no per-frame Task machinery.
