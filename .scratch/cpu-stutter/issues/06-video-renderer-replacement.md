# 06 — Replace RTCMTLNSVideoView with a zero-copy off-main video renderer

**What to build:** Decoded video frames reach the screen without any CPU pixel-format conversion and without presenting on the main thread, so heavy main-thread work can no longer drop video frames. This is the fix for the visible stutter.

Background (binary-verified by audit): the bundled `RTCMTLNSVideoView` converts every frame NV12→I420 on the CPU (`newI420VideoFrame`, ~190 MB/s at 1080p60), uploads 3 planes on the main thread from `drawInMTKView:`, and has an `updateConstraints` that appends duplicate constraints unbounded.

Approach constraints (from the audit):

- New `RTCVideoRenderer` hands `RTCCVPixelBuffer.pixelBuffer` (NV12 IOSurface, straight from VideoToolbox) to an `AVSampleBufferDisplayLayer` — zero-copy, composited off the main thread. (Own `CAMetalLayer` + NV12 shader is the fallback if AVSBDL proves unsuitable.)
- Merge `ConnectionGenerationVideoRenderer`'s duties into the new renderer: first-frame watchdog signal, frame-time recording, FPS accounting done thread-locally (atomic/unfair lock), hopping to the main actor only for the throttled publish (≤2 Hz) and the one-shot first-frame event — no per-frame `Task { @MainActor }`.
- Keep the tracking/input container behavior (mouse mapping against the video rect) and the OCR frame-capture path working.
- Aspect handling: the layer uses `videoGravity = .resizeAspect`; `videoSize` publish stays for window aspect + input mapping, equality-gated.

**Blocked by:** 02, 03 (only so its CPU effect can be measured in isolation — start after they merge).

**Status:** ready-for-agent

- [ ] `sample` of the streaming app shows no `newI420VideoFrame` / libyuv / I420 upload frames
- [ ] No per-frame main-actor task creation (code-level; spot-check with a sample showing no per-frame Task machinery)
- [ ] Video still renders correctly: aspect fit, resolution changes mid-stream, reconnect, fullscreen
- [ ] Mouse input mapping and OCR capture still work
- [ ] Under an artificial main-thread stall (e.g. 200 ms sleep on a timer in a diag flag), video keeps playing smoothly — the decisive stutter test
- [ ] First-frame watchdog and stream-health frame timestamps still fire correctly
