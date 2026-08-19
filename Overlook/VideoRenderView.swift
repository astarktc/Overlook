// swiftlint:disable file_length
//
// One file on purpose: the control, the throttles, the enqueue engine and the view are one
// subsystem — the render path — and splitting them would hide that the view's only job is to own
// the layer and route frames.
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

#if canImport(WebRTC)
@preconcurrency import WebRTC

// MARK: - Shared connection state

/// The per-frame connection state the video render path reads, safe to touch from the decode
/// thread.
///
/// `WebRTCManager` is `@MainActor`, but decoded frames arrive on WebRTC's decode/worker thread.
/// The old renderer hopped to the main actor on *every* frame just to read
/// `connectionGeneration`, `isFrameCaptureEnabled` and the watchdog-suppression flag, and stamped
/// the stream-health frame clock behind a `DispatchQueue.sync`. This type is that state behind one
/// `OSAllocatedUnfairLock`: the manager writes it from the main actor, and the decode thread reads
/// the gates *and* stamps the frame clock in a single uncontended lock acquisition per frame.
final class VideoRenderControl: Sendable {
    /// What one decoded frame is allowed to do, decided in one lock acquisition.
    struct FrameAdmission: Equatable {
        /// False when the frame belongs to a superseded connection: it is neither displayed,
        /// counted, nor allowed to stamp the stream-health clock.
        var isCurrentGeneration: Bool
        /// True while `OVERLOOK_FORCE_DECODE_STARVATION` suppresses frame-arrival signals for
        /// watchdog testing. The frame is still displayed — only the signals are withheld,
        /// which is exactly what the old main-actor `renderFrame` did.
        var signalsSuppressed: Bool
        /// True for the first frame of this connection (drives the first-frame watchdog event).
        var isFirstDecodedFrame: Bool
        /// Mirror of `WebRTCManager.isFrameCaptureEnabled` (OCR mode).
        var isFrameCaptureEnabled: Bool

        static let stale = FrameAdmission(
            isCurrentGeneration: false,
            signalsSuppressed: false,
            isFirstDecodedFrame: false,
            isFrameCaptureEnabled: false
        )
    }

    private struct State {
        /// `Int.min` until the manager publishes a real connection generation, so a frame that
        /// somehow arrives before a connection exists can never be admitted.
        var generation: Int = .min
        var isFrameCaptureEnabled = false
        var suppressFrameArrivalSignals = false
        var lastFrameTime: CFTimeInterval?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: Main-actor writers

    func setGeneration(_ generation: Int) {
        state.withLock { $0.generation = generation }
    }

    func setFrameCaptureEnabled(_ enabled: Bool) {
        state.withLock { $0.isFrameCaptureEnabled = enabled }
    }

    func setSuppressFrameArrivalSignals(_ suppress: Bool) {
        state.withLock { $0.suppressFrameArrivalSignals = suppress }
    }

    /// Resets the stream-health frame clock, e.g. when a replacement stream gets its own
    /// initial-frame window.
    func setLastFrameTime(_ time: CFTimeInterval?) {
        state.withLock { $0.lastFrameTime = time }
    }

    // MARK: Readers

    /// The time of the most recently admitted frame, or nil when none has arrived yet.
    var lastFrameTime: CFTimeInterval? {
        state.withLock { $0.lastFrameTime }
    }

    func isCurrentGeneration(_ generation: Int) -> Bool {
        state.withLock { $0.generation == generation }
    }

    /// One lock acquisition per decoded frame: applies the generation guard, reads the gates and
    /// stamps the stream-health clock.
    func admitFrame(generation: Int, at time: CFTimeInterval) -> FrameAdmission {
        state.withLock { state in
            guard state.generation == generation else { return .stale }

            if state.suppressFrameArrivalSignals {
                return FrameAdmission(
                    isCurrentGeneration: true,
                    signalsSuppressed: true,
                    isFirstDecodedFrame: false,
                    isFrameCaptureEnabled: false
                )
            }

            let isFirstDecodedFrame = state.lastFrameTime == nil
            state.lastFrameTime = time

            return FrameAdmission(
                isCurrentGeneration: true,
                signalsSuppressed: false,
                isFirstDecodedFrame: isFirstDecodedFrame,
                isFrameCaptureEnabled: state.isFrameCaptureEnabled
            )
        }
    }
}

// MARK: - Signal sink

/// The main-actor destinations for the render path's throttled signals.
///
/// The render path itself never touches the manager; it hops here at most twice a second for
/// fps, ~12 times a second while OCR capture is on, and exactly once per connection for the
/// first-frame watchdog event.
@MainActor
protocol VideoRenderSignalSink: AnyObject {
    func videoRenderDidReceiveFirstFrame(generation: Int)
    func videoRenderDidMeasureFps(_ fps: Int, generation: Int)
    func videoRenderDidCaptureFrame(_ pixelBuffer: CVPixelBuffer, generation: Int)
    func videoRenderDidChangeSize(_ size: CGSize, generation: Int)
}

// MARK: - Throttles

/// Frames-per-second accounting and the OCR capture throttle as pure value math, so the cadences
/// can be tested without a live stream.
///
/// The windows reproduce the ones the main-actor `renderFrame` used to run: fps is published when
/// at least 0.5 s has passed since the last publish (≤ 2 Hz), quantized to whole frames the way
/// the UI renders it; OCR capture is admitted at most 12 times a second.
struct VideoFrameSignalThrottles: Equatable {
    static let fpsPublishInterval: CFTimeInterval = 0.5
    static let frameCaptureInterval: CFTimeInterval = 1.0 / 12.0

    private(set) var windowStartTime: CFTimeInterval?
    private(set) var frameCount: Int = 0
    private(set) var lastFpsPublishTime: CFTimeInterval?
    private(set) var lastFrameCaptureTime: CFTimeInterval?

    /// Records one decoded frame. Returns the whole-frame fps when the publish window closed,
    /// nil while it is still filling.
    mutating func recordFrame(at now: CFTimeInterval) -> Int? {
        let windowStart = windowStartTime ?? now
        let lastPublish = lastFpsPublishTime ?? now
        windowStartTime = windowStart
        lastFpsPublishTime = lastPublish

        frameCount += 1

        guard now - lastPublish >= Self.fpsPublishInterval else { return nil }

        let elapsed = now - windowStart
        // `elapsed` is at least the publish interval for any monotonic clock; the guard only
        // exists so a degenerate window can never divide by zero.
        let fps = elapsed > 0 ? Int((Double(frameCount) / elapsed).rounded()) : nil

        windowStartTime = now
        frameCount = 0
        lastFpsPublishTime = now

        return fps
    }

    /// True at most 12 times a second, matching the old OCR capture cadence.
    mutating func shouldCaptureFrame(at now: CFTimeInterval) -> Bool {
        if let lastFrameCaptureTime, now - lastFrameCaptureTime < Self.frameCaptureInterval {
            return false
        }
        lastFrameCaptureTime = now
        return true
    }
}

/// Thread-safe holder for `VideoFrameSignalThrottles`: an unfair lock rather than a queue, because
/// this runs on the decode thread for every frame.
final class VideoFrameSignalGate: Sendable {
    private let throttles = OSAllocatedUnfairLock(initialState: VideoFrameSignalThrottles())

    func recordFrame(at now: CFTimeInterval) -> Int? {
        throttles.withLock { $0.recordFrame(at: now) }
    }

    func shouldCaptureFrame(at now: CFTimeInterval) -> Bool {
        throttles.withLock { $0.shouldCaptureFrame(at: now) }
    }

    func reset() {
        throttles.withLock { $0 = VideoFrameSignalThrottles() }
    }
}

// MARK: - Display engine

/// Turns decoded frames into `AVSampleBufferDisplayLayer` enqueues on a dedicated serial queue.
///
/// Zero-copy is the whole point: a hardware-decoded frame arrives as an `RTCCVPixelBuffer`
/// wrapping VideoToolbox's IOSurface-backed NV12 `CVPixelBuffer`, and that buffer is handed to
/// the display layer inside a `CMSampleBuffer` without touching a single pixel. Compositing then
/// happens in the window server, off our main thread — so a stalled main thread cannot drop
/// video frames.
final class VideoDisplayEngine: @unchecked Sendable {
    /// Caches the `CMVideoFormatDescription` describing the decoder's output.
    ///
    /// Creating one per frame is pure waste; `CMVideoFormatDescriptionMatchesImageBuffer` is the
    /// authoritative "does this description still describe this buffer" check (dimensions, pixel
    /// format *and* colorimetry attachments), so a resolution change mid-stream — and only a
    /// change — recreates it.
    struct FormatDescriptionCache {
        private(set) var formatDescription: CMVideoFormatDescription?
        /// Number of descriptions created; the seam the caching test asserts on.
        private(set) var creationCount = 0

        /// Returns the description to use for `pixelBuffer`, plus whether it *replaced* a
        /// previous one (the resolution-change case, which must flush the display layer).
        mutating func formatDescription(
            for pixelBuffer: CVPixelBuffer
        ) -> (description: CMVideoFormatDescription?, replacedPrevious: Bool) {
            if let formatDescription,
               CMVideoFormatDescriptionMatchesImageBuffer(formatDescription, imageBuffer: pixelBuffer) {
                return (formatDescription, false)
            }

            let hadPreviousDescription = formatDescription != nil
            var created: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created
            )

            guard status == noErr, let created else {
                return (nil, false)
            }

            formatDescription = created
            creationCount += 1
            return (created, hadPreviousDescription)
        }

        mutating func reset() {
            formatDescription = nil
        }
    }

    /// Our own dispatch backlog cap. The enqueue block is microseconds of work, so this only ever
    /// trips if the display layer itself blocks; dropping the newest frames then keeps the decoder
    /// from pinning every IOSurface in the pool.
    private static let maxPendingEnqueues = 6

    private let videoRenderer: AVSampleBufferVideoRenderer
    private let enqueueQueue = DispatchQueue(
        label: "com.overlook.video-enqueue",
        qos: .userInteractive
    )
    private let pendingEnqueues = OSAllocatedUnfairLock(initialState: 0)

    /// Touched only on `enqueueQueue`.
    private var formatCache = FormatDescriptionCache()

    init(videoRenderer: AVSampleBufferVideoRenderer) {
        self.videoRenderer = videoRenderer
    }

    /// Hands one decoded frame buffer to the display layer. Safe to call from any thread; the
    /// work itself is serialized on `enqueueQueue` and never touches the main thread.
    func display(_ buffer: RTCVideoFrameBuffer) {
        let admitted = pendingEnqueues.withLock { pending -> Bool in
            guard pending < Self.maxPendingEnqueues else { return false }
            pending += 1
            return true
        }
        guard admitted else { return }

        enqueueQueue.async { [self] in
            defer { pendingEnqueues.withLock { $0 -= 1 } }
            guard let pixelBuffer = Self.displayablePixelBuffer(for: buffer) else { return }
            enqueueOnQueue(pixelBuffer)
        }
    }

    /// Drops everything queued for display, keeping the last displayed image.
    func flush() {
        enqueueQueue.async { [self] in
            videoRenderer.flush()
        }
    }

    /// Flush plus a forget of the cached format description — used when a connection ends, so the
    /// next stream never inherits this one's format state.
    func reset() {
        enqueueQueue.async { [self] in
            videoRenderer.flush()
            formatCache.reset()
        }
    }

    // MARK: Sample buffer construction

    /// Builds the `CMSampleBuffer` the display layer consumes.
    ///
    /// Timing is `kCMTimingInfoInvalid` plus `kCMSampleAttachmentKey_DisplayImmediately`: this is
    /// a live KVM stream with no timeline to schedule against, so every frame is shown as soon as
    /// it arrives instead of being held for a presentation timestamp.
    static func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        formatDescription: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo.invalid
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else { return nil }
        setDisplayImmediately(on: sampleBuffer)
        return sampleBuffer
    }

    static func setDisplayImmediately(on sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else {
            return
        }

        let attachment = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    /// Extracts a displayable `CVPixelBuffer` from a WebRTC frame buffer.
    ///
    /// The hardware decoders (our H.265 decoder and WebRTC's VideoToolbox H.264 decoder) both hand
    /// us an `RTCCVPixelBuffer`, which is returned as-is: no conversion, no copy.
    static func displayablePixelBuffer(for buffer: RTCVideoFrameBuffer) -> CVPixelBuffer? {
        if let pixelBufferFrame = buffer as? RTCCVPixelBuffer {
            // Our decoders never crop. If a cropping buffer ever shows up, showing the full frame
            // is the honest failure mode (the alternative is a scaling copy per frame).
            if pixelBufferFrame.requiresCropping() {
                logOnceEvery5Seconds("[Overlook] video frame requests cropping; displaying uncropped")
            }
            return pixelBufferFrame.pixelBuffer
        }

        // Fallback: a software decoder handed us planar I420 with no IOSurface behind it, so there
        // is nothing to hand the display layer directly. Convert I420 → NV12 into a fresh pixel
        // buffer, once per frame. Deliberately the simple correct implementation rather than a
        // fast one: this path only runs if a software decoder is ever selected, and correctness
        // there matters more than its cost.
        return makeNV12PixelBuffer(fromI420: buffer.toI420())
    }

    static func makeNV12PixelBuffer(fromI420 buffer: RTCI420BufferProtocol) -> CVPixelBuffer? {
        let width = Int(buffer.width)
        let height = Int(buffer.height)
        guard width > 0, height > 0 else { return nil }

        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }

        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let sourceStrideY = Int(buffer.strideY)
        let sourceStrideU = Int(buffer.strideU)
        let sourceStrideV = Int(buffer.strideV)

        for row in 0..<height {
            let source = buffer.dataY.advanced(by: row * sourceStrideY)
            let destination = luma.advanced(by: row * lumaStride)
            memcpy(destination, source, min(width, sourceStrideY))
        }

        let chromaWidth = Int(buffer.chromaWidth)
        let chromaHeight = Int(buffer.chromaHeight)
        for row in 0..<chromaHeight {
            let sourceU = buffer.dataU.advanced(by: row * sourceStrideU)
            let sourceV = buffer.dataV.advanced(by: row * sourceStrideV)
            let destination = chroma
                .advanced(by: row * chromaStride)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<chromaWidth {
                destination[column * 2] = sourceU[column]
                destination[column * 2 + 1] = sourceV[column]
            }
        }

        return pixelBuffer
    }

    // MARK: Enqueue

    private func enqueueOnQueue(_ pixelBuffer: CVPixelBuffer) {
        let (description, replacedPrevious) = formatCache.formatDescription(for: pixelBuffer)
        guard let description else {
            Self.logOnceEvery5Seconds("[Overlook] failed to create a video format description")
            return
        }

        // A resolution/format change: drop whatever is still queued in the old format so the new
        // stream starts clean instead of showing a stale frame at the wrong size.
        if replacedPrevious {
            videoRenderer.flush()
        }

        guard let sampleBuffer = Self.makeSampleBuffer(
            pixelBuffer: pixelBuffer,
            formatDescription: description
        ) else {
            Self.logOnceEvery5Seconds("[Overlook] failed to wrap a decoded frame in a sample buffer")
            return
        }

        // A failed renderer stays failed until flushed (and the same is true when the system
        // revokes decoder resources), so recover before enqueueing rather than silently freezing.
        if videoRenderer.status == .failed || videoRenderer.requiresFlushToResumeDecoding {
            Self.logOnceEvery5Seconds(
                "[Overlook] video renderer needs a flush (status=\(videoRenderer.status.rawValue)): flushing"
            )
            videoRenderer.flush()
        }

        videoRenderer.enqueue(sampleBuffer)

        if videoRenderer.status == .failed {
            Self.logOnceEvery5Seconds(
                "[Overlook] video renderer failed on enqueue: \(String(describing: videoRenderer.error))"
            )
            videoRenderer.flush()
            videoRenderer.enqueue(sampleBuffer)
        }
    }

    // MARK: Logging

    private static let sharedFailureLogTime = OSAllocatedUnfairLock<CFTimeInterval>(initialState: 0)

    /// Per-frame failures would otherwise produce a 60 Hz log flood.
    private static func logOnceEvery5Seconds(_ message: String) {
        let now = CACurrentMediaTime()
        let shouldLog = sharedFailureLogTime.withLock { last -> Bool in
            guard now - last >= 5.0 else { return false }
            last = now
            return true
        }
        guard shouldLog else { return }
        NSLog("%@", message)
    }
}

// MARK: - View

/// The video surface: an `NSView` backed by an `AVSampleBufferDisplayLayer` that is itself the
/// `RTCVideoRenderer` attached to the video track.
///
/// This replaces WebRTC's bundled `RTCMTLNSVideoView`, which converted every NV12 frame to I420
/// on the CPU and uploaded three planes **on the main thread** from `drawInMTKView:` — so any
/// main-thread work dropped video frames. Here the decode thread does bookkeeping only, the
/// pixel buffer goes to the display layer untouched, and the main actor is involved at most twice
/// a second.
final class VideoRenderView: NSView, RTCVideoRenderer {
    private let displayLayer: AVSampleBufferDisplayLayer
    private let engine: VideoDisplayEngine
    private let control: VideoRenderControl
    private let signalGate = VideoFrameSignalGate()

    /// The generation this view is currently rendering for; `Int.min` until it is attached to a
    /// track, so nothing is displayed before or after a connection.
    private let renderGeneration = OSAllocatedUnfairLock(initialState: Int.min)

    /// Set once, on the main actor, immediately after init. Read from the decode thread only to
    /// hop to the main actor, which is why the unchecked opt-out is safe here.
    private nonisolated(unsafe) weak var sink: VideoRenderSignalSink?

    init(control: VideoRenderControl, sink: VideoRenderSignalSink?) {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor

        self.displayLayer = layer
        self.engine = VideoDisplayEngine(videoRenderer: layer.sampleBufferRenderer)
        self.control = control
        super.init(frame: .zero)
        self.sink = sink

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VideoRenderView is created in code, never from a nib")
    }

    override func makeBackingLayer() -> CALayer {
        displayLayer
    }

    override var isOpaque: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        displayLayer.contentsScale = window?.backingScaleFactor ?? 1.0
    }

    // MARK: Lifecycle (main actor)

    /// Starts accepting frames tagged with `generation`. Frames from any other generation — i.e.
    /// from a connection that has since been torn down — are dropped without being displayed,
    /// counted or allowed to stamp the stream-health clock.
    func beginRendering(generation: Int) {
        renderGeneration.withLock { $0 = generation }
        signalGate.reset()
        engine.reset()
    }

    /// Symmetric teardown: stop accepting frames and drop everything queued for display.
    func endRendering() {
        renderGeneration.withLock { $0 = .min }
        signalGate.reset()
        engine.reset()
    }

    /// Drops queued frames without changing the generation.
    func flushDisplay() {
        engine.flush()
    }

    // MARK: RTCVideoRenderer

    /// Called on WebRTC's decode/worker thread for every decoded frame.
    ///
    /// Everything here is lock-local: no `Task`, no `DispatchQueue.sync`, no main-actor touch.
    /// The display hand-off is one `dispatch_async` onto the render path's own serial queue.
    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }

        let generation = renderGeneration.withLock { $0 }
        let now = CACurrentMediaTime()
        let admission = control.admitFrame(generation: generation, at: now)
        guard admission.isCurrentGeneration else { return }

        if frame.rotation != ._0 {
            VideoRenderView.logRotationOnce(frame.rotation)
        }

        engine.display(frame.buffer)

        // Watchdog testing (OVERLOOK_FORCE_DECODE_STARVATION) withholds the signals only; the
        // frame above is still displayed, exactly as before.
        guard admission.signalsSuppressed == false else { return }

        let measuredFps = signalGate.recordFrame(at: now)
        let shouldCaptureFrame = admission.isFrameCaptureEnabled
            && signalGate.shouldCaptureFrame(at: now)

        // [DEBUG-swiftui-audit] OVERLOOK_DIAG_NO_RENDER_HOP=1 keeps video flowing and keeps the
        // accounting above, but drops every main-actor hop out of the render path.
        guard DiagFlags.noRenderHop == false else { return }

        if admission.isFirstDecodedFrame {
            Task { @MainActor [weak self] in
                self?.sink?.videoRenderDidReceiveFirstFrame(generation: generation)
            }
        }

        if let measuredFps {
            Task { @MainActor [weak self] in
                self?.sink?.videoRenderDidMeasureFps(measuredFps, generation: generation)
            }
        }

        if shouldCaptureFrame, let pixelBufferFrame = frame.buffer as? RTCCVPixelBuffer {
            let pixelBuffer = pixelBufferFrame.pixelBuffer
            Task { @MainActor [weak self] in
                self?.sink?.videoRenderDidCaptureFrame(pixelBuffer, generation: generation)
            }
        }
    }

    /// Called by WebRTC when the track's frame size changes. Rare, and the manager equality-gates
    /// the publish, so a plain hop is the right cost here.
    nonisolated func setSize(_ size: CGSize) {
        let generation = renderGeneration.withLock { $0 }
        guard control.isCurrentGeneration(generation) else { return }

        Task { @MainActor [weak self] in
            self?.sink?.videoRenderDidChangeSize(size, generation: generation)
        }
    }

    // MARK: Logging

    private nonisolated static let loggedRotation = OSAllocatedUnfairLock(initialState: false)

    /// The KVM stream always requests `orientation: 0`, so a rotated frame means an assumption
    /// broke. `AVSampleBufferDisplayLayer` has no rotation of its own, so say so once instead of
    /// silently showing it un-rotated.
    private nonisolated static func logRotationOnce(_ rotation: RTCVideoRotation) {
        let shouldLog = loggedRotation.withLock { logged -> Bool in
            guard logged == false else { return false }
            logged = true
            return true
        }
        guard shouldLog else { return }
        NSLog("[Overlook] video frame arrived rotated (%ld); displaying unrotated", rotation.rawValue)
    }
}

#endif
