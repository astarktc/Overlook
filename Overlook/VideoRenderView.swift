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
        /// False when the frame belongs to a superseded connection *or* a superseded stream
        /// epoch (a codec fallback re-issued the Watch Request inside the same connection): it
        /// is neither displayed, counted, nor allowed to stamp the stream-health clock.
        var isAdmitted: Bool
        /// True while `OVERLOOK_FORCE_DECODE_STARVATION` suppresses frame-arrival signals for
        /// watchdog testing. The frame is still displayed — only the signals are withheld,
        /// which is exactly what the old main-actor `renderFrame` did.
        var signalsSuppressed: Bool
        /// True for the first decoded frame of the current *stream*: the first frame admitted
        /// in the current stream epoch while the stream-health clock is nil.
        ///
        /// "First frame of the replacement stream" after a codec fallback rests on two guards
        /// with different reach (see `admitFrame` for the precise contract):
        /// - the epoch token orders *callbacks* against the transition — it does NOT identify
        ///   the stream that produced a frame's pixels, because a decode callback that begins
        ///   after the fallback reads the new token even when its frame came from the
        ///   abandoned stream;
        /// - the H.265 provenance marker (`OverlookH265PixelBuffer`) travels with the frame
        ///   itself, which is what actually refuses the abandoned stream's late frames.
        /// Nothing here inspects SSRCs. This flag drives the first-frame watchdog event, so
        /// the codec-selection policy depends on this meaning.
        var isFirstDecodedFrame: Bool
        /// Mirror of `WebRTCManager.isFrameCaptureEnabled` (OCR mode).
        var isFrameCaptureEnabled: Bool

        static let stale = FrameAdmission(
            isAdmitted: false,
            signalsSuppressed: false,
            isFirstDecodedFrame: false,
            isFrameCaptureEnabled: false
        )
    }

    private struct State {
        /// `Int.min` until the manager publishes a real connection generation, so a frame that
        /// somehow arrives before a connection exists can never be admitted.
        var generation: Int = .min
        /// The stream epoch signals are currently admitted for. `.invalid` until the view arms
        /// a real epoch, so a frame can never be admitted before rendering begins. The view
        /// advances this in lockstep with the display epoch (`begin`/`end`/`flushDisplay`), so
        /// the signal side and the display side agree by construction on which stream's frames
        /// count.
        var admittedToken: VideoDisplayEngine.RenderToken = .invalid
        /// False from the codec-fallback transition onward: every frame decoded by our H.265
        /// decoder is refused, no matter which epoch token its callback reads — the frame's
        /// buffer class is the one identity that survives however late the callback runs.
        /// Monotonic within a connection; only `setGeneration` (a new connection, which
        /// restarts codec selection) re-arms it.
        var admitsH265DecodedFrames = true
        var isFrameCaptureEnabled = false
        var suppressFrameArrivalSignals = false
        var lastFrameTime: CFTimeInterval?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: Main-actor writers

    func setGeneration(_ generation: Int) {
        state.withLock {
            $0.generation = generation
            // A new connection restarts codec selection from scratch (the fallback decision is
            // per-connection), so H.265-decoded frames are admissible again.
            $0.admitsH265DecodedFrames = true
        }
    }

    /// Adopts a new stream epoch: from here on only frames carrying `token` are counted.
    ///
    /// Called by `VideoRenderView` whenever the display epoch advances, which is what keeps a
    /// late frame from the abandoned stream (same connection, pre-fallback epoch) from
    /// stamping the health clock or claiming `isFirstDecodedFrame`.
    func setAdmittedToken(_ token: VideoDisplayEngine.RenderToken) {
        state.withLock { $0.admittedToken = token }
    }

    /// Arms or revokes admission for frames decoded by our H.265 decoder. The codec-fallback
    /// transition revokes (`VideoRenderView.flushDisplayAbandoningH265Stream`), and revocation
    /// must happen *before* the epoch advances: the marker — not the token — is what refuses an
    /// abandoned-stream frame whose decode callback begins after the fallback.
    func setAdmitsH265DecodedFrames(_ admits: Bool) {
        state.withLock { $0.admitsH265DecodedFrames = admits }
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

    /// True while `token` is still the admitted stream epoch.
    ///
    /// Signal *delivery* revalidates against this: a first-frame signal admitted a moment
    /// before a fallback queues a main-actor hop that cannot be retracted, so the receiver
    /// (`WebRTCManager.videoRenderDidReceiveFirstFrame`) checks the delivered token again at
    /// receipt and drops the stale delivery.
    func isCurrentEpoch(_ token: VideoDisplayEngine.RenderToken) -> Bool {
        state.withLock { $0.admittedToken == token && token != .invalid }
    }

    /// One lock acquisition per decoded frame: applies the generation, stream-epoch and H.265
    /// provenance guards, reads the gates and stamps the stream-health clock.
    ///
    /// What the two stream guards each deliver, precisely:
    /// - `token` is read by the decode thread when its callback begins, so it guards *callback
    ///   ordering*: an admission that completes before an epoch transition publishes anything
    ///   belongs to the old epoch, and one that overlaps the transition is refused (proof in
    ///   `VideoRenderView.advanceEpoch`). It does NOT identify the stream that produced the
    ///   frame's pixels — a callback that begins after the transition reads the new token even
    ///   when its frame was decoded from the abandoned stream.
    /// - `fromH265Decoder` is frame provenance: the marker class travels with the frame's
    ///   buffer, so once the fallback revokes H.265 admission the abandoned stream's frames
    ///   are refused regardless of when their callbacks run. The same-connection reissue only
    ///   ever abandons H.265 for H.264 and never returns to H.265 within a connection
    ///   (`CodecSelectionPolicy`), so provenance + token together close the fallback gap.
    ///   Residual limits, stated honestly: the marker relies on WebRTC handing the renderer
    ///   the decoder's own buffer instance (the property the zero-copy display path already
    ///   depends on — if that ever broke, this degrades to the token-only ordering guarantee),
    ///   and a hypothetical same-codec reissue inside one connection would be guarded by the
    ///   token alone (no such path exists today).
    func admitFrame(
        generation: Int,
        token: VideoDisplayEngine.RenderToken,
        fromH265Decoder: Bool,
        at time: CFTimeInterval
    ) -> FrameAdmission {
        state.withLock { state in
            guard state.generation == generation,
                  state.admittedToken == token,
                  token != .invalid,
                  fromH265Decoder == false || state.admitsH265DecodedFrames
            else { return .stale }

            if state.suppressFrameArrivalSignals {
                return FrameAdmission(
                    isAdmitted: true,
                    signalsSuppressed: true,
                    isFirstDecodedFrame: false,
                    isFrameCaptureEnabled: false
                )
            }

            let isFirstDecodedFrame = state.lastFrameTime == nil
            state.lastFrameTime = time

            return FrameAdmission(
                isAdmitted: true,
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
    /// `token` is the stream epoch the frame was admitted in. The main-actor hop cannot be
    /// retracted once queued, so the receiver must revalidate the token at receipt
    /// (`VideoRenderControl.isCurrentEpoch`): a codec fallback may have advanced the epoch
    /// while this delivery waited its turn.
    func videoRenderDidReceiveFirstFrame(generation: Int, token: VideoDisplayEngine.RenderToken)
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

/// Coalescing hand-off for OCR frame capture: one latest-frame slot plus at most one scheduled
/// main-actor drain.
///
/// The naive shape — one `Task { @MainActor }` per captured frame, each strongly retaining its
/// pixel buffer — turns a stalled main thread into an unbounded pile of retained IOSurfaces and
/// drains the decoder's buffer pool. OCR only ever wants the *newest* frame, so a new capture
/// replaces the slot's contents instead of queueing behind it, and the drain that is already
/// scheduled picks up whatever is there when the main actor gets a turn.
final class VideoFrameCaptureSlot: @unchecked Sendable {
    private struct Slot {
        var pixelBuffer: CVPixelBuffer?
        var generation: Int = .min
        /// True while a main-actor drain is scheduled but has not run yet.
        var isDrainScheduled = false
    }

    // `uncheckedState` because `CVPixelBuffer` is a CoreFoundation type and therefore not
    // `Sendable`; the lock is what makes the hand-off safe.
    private let slot = OSAllocatedUnfairLock(uncheckedState: Slot())

    /// Stores the newest captured frame, dropping any frame that has not been drained yet.
    /// Returns true exactly when the caller must schedule a drain, so at most one is in flight.
    ///
    /// `withLockUnchecked` throughout: `CVPixelBuffer` is a CoreFoundation type and so not
    /// `Sendable`: the lock, plus the fact that ownership is *moved* (a stored buffer is only ever
    /// read by the drain that clears the slot), is what makes the hand-off safe.
    func store(_ pixelBuffer: CVPixelBuffer, generation: Int) -> Bool {
        slot.withLockUnchecked { slot in
            slot.pixelBuffer = pixelBuffer
            slot.generation = generation
            guard slot.isDrainScheduled == false else { return false }
            slot.isDrainScheduled = true
            return true
        }
    }

    /// Takes the pending frame, if any, and clears the scheduled-drain flag so the next capture
    /// schedules a fresh drain.
    func take() -> (pixelBuffer: CVPixelBuffer, generation: Int)? {
        slot.withLockUnchecked { slot in
            slot.isDrainScheduled = false
            guard let pixelBuffer = slot.pixelBuffer else { return nil }
            slot.pixelBuffer = nil
            return (pixelBuffer, slot.generation)
        }
    }

    /// Releases a frame that is waiting for a drain — used by teardown, so a finished connection
    /// never leaves an IOSurface retained here.
    func clear() {
        slot.withLockUnchecked { $0.pixelBuffer = nil }
    }

    /// True while a frame is waiting to be drained; a test seam, not part of the frame path.
    var hasPendingFrame: Bool {
        slot.withLockUnchecked { $0.pixelBuffer != nil }
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

/// The slice of `AVSampleBufferVideoRenderer` the display engine uses.
///
/// It exists so the backpressure and failure-recovery decisions — "is the layer still consuming?",
/// "did the enqueue fail?" — are testable without a window, a display server or a live stream.
/// `AVSampleBufferVideoRenderer` satisfies it as-is; nothing is wrapped or copied.
protocol VideoSampleBufferRendering: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    var requiresFlushToResumeDecoding: Bool { get }
    var status: AVQueuedSampleBufferRenderingStatus { get }
    var error: Error? { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
}

extension AVSampleBufferVideoRenderer: VideoSampleBufferRendering {}

/// Turns decoded frames into `AVSampleBufferDisplayLayer` enqueues on a dedicated serial queue.
///
/// Zero-copy is the whole point: a hardware-decoded frame arrives as an `RTCCVPixelBuffer`
/// wrapping VideoToolbox's IOSurface-backed NV12 `CVPixelBuffer`, and that buffer is handed to
/// the display layer inside a `CMSampleBuffer` without touching a single pixel. Compositing then
/// happens in the window server, off our main thread — so a stalled main thread cannot drop
/// video frames.
final class VideoDisplayEngine: @unchecked Sendable {
    /// Identifies one rendering epoch — the unit the enqueue queue validates against.
    ///
    /// The generation guard alone cannot close the teardown race: the decode thread reads the
    /// generation, is admitted, and only *then* hands the frame to the enqueue queue. If teardown
    /// happens in between, the flush runs first and the already-admitted frame is enqueued after
    /// it. A token travels with the frame and is validated *inside* the serialized enqueue
    /// operation, so a frame from a superseded epoch is dropped rather than presented.
    struct RenderToken: Hashable, Sendable {
        let rawValue: UInt64

        /// No frame can ever carry this: it is what the engine holds before `begin` and after
        /// `end`.
        static let invalid = RenderToken(rawValue: 0)
    }

    /// Why frames were dropped, for tests and diagnosis. Never used to make decisions.
    struct Stats: Equatable, Sendable {
        var enqueued = 0
        /// Frames admitted in an epoch that ended before the enqueue block ran.
        var droppedStaleToken = 0
        /// Frames dropped because the display layer was not consuming (occluded window, stalled
        /// renderer).
        var droppedNotReady = 0
        /// Frames dropped while a failed renderer is backing off.
        var droppedFailureBackoff = 0
        /// Frames dropped because our own dispatch backlog was full.
        var droppedBacklog = 0
    }

    /// The retry schedule for a renderer that fails on enqueue, as pure value math.
    ///
    /// Without this, a permanently failed renderer is flushed and re-enqueued for *every* decoded
    /// frame — 60 Hz of futile recovery work plus a 60 Hz log flood. Recovery is still attempted,
    /// just at a rate that backs off as failures repeat.
    struct FailureBackoff: Equatable {
        static let delays: [CFTimeInterval] = [0.1, 0.25, 0.5, 1.0]

        private(set) var consecutiveFailures = 0
        private(set) var retryAfter: CFTimeInterval?

        /// True when the renderer may be touched again. Clears the deadline once it passes, so
        /// exactly one frame per backoff window gets a recovery attempt.
        mutating func shouldAttemptEnqueue(at now: CFTimeInterval) -> Bool {
            guard let retryAfter else { return true }
            guard now >= retryAfter else { return false }
            self.retryAfter = nil
            return true
        }

        mutating func recordFailure(at now: CFTimeInterval) {
            let index = min(consecutiveFailures, Self.delays.count - 1)
            retryAfter = now + Self.delays[index]
            consecutiveFailures += 1
        }

        mutating func recordSuccess() {
            guard consecutiveFailures != 0 || retryAfter != nil else { return }
            consecutiveFailures = 0
            retryAfter = nil
        }
    }

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

    private let videoRenderer: any VideoSampleBufferRendering
    private let enqueueQueue = DispatchQueue(
        label: "com.overlook.video-enqueue",
        qos: .userInteractive
    )
    private let pendingEnqueues = OSAllocatedUnfairLock(initialState: 0)
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    /// Touched only on `enqueueQueue`.
    private var formatCache = FormatDescriptionCache()
    /// Touched only on `enqueueQueue`: the epoch the engine currently accepts frames for.
    private var activeToken: RenderToken = .invalid
    /// Touched only on `enqueueQueue`.
    private var failureBackoff = FailureBackoff()

    init(videoRenderer: any VideoSampleBufferRendering) {
        self.videoRenderer = videoRenderer
    }

    /// Frame accounting; a diagnostic/test seam, safe to read from any thread.
    var currentStats: Stats {
        stats.withLock { $0 }
    }

    /// Hands one decoded frame buffer to the display layer. Safe to call from any thread; the
    /// work itself is serialized on `enqueueQueue` and never touches the main thread.
    ///
    /// `token` is the epoch the frame was admitted in. It is validated on the enqueue queue, not
    /// here, because that is the only place ordering against `begin`/`end`/`flush` is guaranteed.
    func display(_ buffer: RTCVideoFrameBuffer, token: RenderToken) {
        let admitted = pendingEnqueues.withLock { pending -> Bool in
            guard pending < Self.maxPendingEnqueues else { return false }
            pending += 1
            return true
        }
        guard admitted else {
            record { $0.droppedBacklog += 1 }
            return
        }

        enqueueQueue.async { [self] in
            defer { pendingEnqueues.withLock { $0 -= 1 } }
            // The epoch check is part of the serialized enqueue operation: a frame admitted a
            // moment before teardown lands here *after* the flush, and must be dropped instead of
            // presenting a stale IOSurface from a connection that no longer exists.
            guard token == activeToken else {
                record { $0.droppedStaleToken += 1 }
                return
            }
            guard let pixelBuffer = Self.displayablePixelBuffer(for: buffer) else { return }
            enqueueOnQueue(pixelBuffer)
        }
    }

    /// Starts a new rendering epoch: only frames carrying `token` are enqueued from here on.
    func begin(token: RenderToken) {
        adopt(token, resetFormatCache: true)
    }

    /// Ends rendering: drops everything queued for display and refuses every frame until the next
    /// `begin`, including frames already admitted by the decode thread.
    func end() {
        adopt(.invalid, resetFormatCache: true)
    }

    /// Drops everything queued for display and starts a new epoch, so frames already admitted for
    /// the stream being abandoned cannot land after the flush.
    func flush(token: RenderToken) {
        adopt(token, resetFormatCache: false)
    }

    /// Every epoch transition happens on the enqueue queue, in order with the frames themselves —
    /// that ordering is the whole mechanism.
    private func adopt(_ token: RenderToken, resetFormatCache: Bool) {
        enqueueQueue.async { [self] in
            activeToken = token
            videoRenderer.flush()
            // A flush is exactly what clears a failed renderer, so the new epoch starts without
            // inheriting the old one's backoff.
            failureBackoff.recordSuccess()
            if resetFormatCache {
                formatCache.reset()
            }
        }
    }

    /// Blocks until everything already submitted to the enqueue queue has run. A test seam: the
    /// frame path never calls this.
    func waitForPendingWork() {
        enqueueQueue.sync {}
    }

    private func record(_ mutation: (inout Stats) -> Void) {
        stats.withLock { mutation(&$0) }
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
        let now = CACurrentMediaTime()

        // A renderer that keeps failing is retried on a backoff instead of being flushed and
        // re-enqueued for every one of 60 frames a second.
        guard failureBackoff.shouldAttemptEnqueue(at: now) else {
            record { $0.droppedFailureBackoff += 1 }
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

        // Backpressure from the layer, not just from our own dispatch backlog: when the window is
        // occluded or minimised the renderer stops consuming, and every sample buffer it retains
        // pins an IOSurface out of the decoder's pool. Our queue would stay empty while the
        // layer's backlog grew without bound. This is a live KVM stream with no timeline, so the
        // honest answer is to drop the frame — a newer one is 16 ms away.
        guard videoRenderer.isReadyForMoreMediaData else {
            record { $0.droppedNotReady += 1 }
            return
        }

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

        videoRenderer.enqueue(sampleBuffer)

        if videoRenderer.status == .failed {
            Self.logOnceEvery5Seconds(
                "[Overlook] video renderer failed on enqueue: \(String(describing: videoRenderer.error))"
            )
            // Flush to clear the failure, then wait out the backoff rather than immediately
            // re-enqueueing this frame: the next decoded frame is milliseconds away and is a
            // better thing to show than a retry loop at frame rate.
            videoRenderer.flush()
            failureBackoff.recordFailure(at: now)
            return
        }

        failureBackoff.recordSuccess()
        record { $0.enqueued += 1 }
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
    private let captureSlot = VideoFrameCaptureSlot()

    /// What the decode thread needs to read atomically per frame: the generation this view is
    /// rendering for (`Int.min` until it is attached to a track, so nothing is displayed before or
    /// after a connection) and the render token that generation's frames travel with.
    private struct RenderState {
        var generation: Int = .min
        var token: VideoDisplayEngine.RenderToken = .invalid
        /// Monotonic; `RenderToken.invalid` is 0, so real tokens start at 1.
        var nextTokenValue: UInt64 = 1
    }

    private let renderState = OSAllocatedUnfairLock(initialState: RenderState())

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
        let token = advanceEpoch(generation: generation)
        signalGate.reset()
        captureSlot.clear()
        engine.begin(token: token)
    }

    /// Symmetric teardown: stop accepting frames, drop everything queued for display, and release
    /// any frame still waiting for an OCR drain.
    ///
    /// Advancing the token here is what closes the teardown race: a frame the decode thread
    /// admitted a moment ago carries the old token, so the enqueue queue drops it after the flush
    /// instead of presenting it.
    func endRendering() {
        _ = advanceEpoch(generation: .min)
        signalGate.reset()
        captureSlot.clear()
        engine.end()
    }

    /// Drops queued frames without changing the generation. The token still advances — on the
    /// display side *and* the signal side — so a frame already admitted for the stream being
    /// abandoned cannot land on the display after the flush, its clock stamp does not survive
    /// (the fallback caller clears the clock right after this returns), and its first-frame
    /// delivery is refused by token revalidation at receipt. Transient side effects that
    /// completed during its admission (`signalGate` accounting, an OCR capture decision) are
    /// NOT retracted — they are harmless within one connection and are not part of the
    /// stream-identity contract.
    func flushDisplay() {
        engine.flush(token: advanceEpoch())
    }

    /// The codec-fallback transition: revoke H.265-decoded frame admission, then
    /// `flushDisplay()` — in the only safe order.
    ///
    /// Revocation comes FIRST because the token cannot refuse an abandoned-stream frame whose
    /// decode callback begins after the epoch advances (it reads the new token; the frame's
    /// buffer class is what carries H.265 provenance, not the callback's timing). Revoking
    /// before the epoch advances leaves no instant at which such a frame can slip through:
    /// before this call it is a legitimately admitted old-epoch frame (flushed from display
    /// here, its clock stamp cleared by the caller right after, its first-frame delivery
    /// revalidated at receipt); from this call on, the marker refuses it outright.
    func flushDisplayAbandoningH265Stream() {
        control.setAdmitsH265DecodedFrames(false)
        flushDisplay()
    }

    /// Moves the view to a fresh epoch and returns its token, publishing the same token to the
    /// control so the display epoch and the signal epoch advance in step by construction.
    /// Callers are on the main actor — transitions never race each other; the decode thread
    /// only ever *reads* (`renderState` at callback start, the control inside `admitFrame`).
    ///
    /// The two publications cannot be atomic (two locks), so their ORDER is what makes the
    /// transition safe-fail: the control's admitted token is published FIRST (C), `renderState`
    /// SECOND (P). A decode callback performs R (read `renderState`) then A (`admitFrame`
    /// against the control). R always precedes A, and C always precedes P, so every
    /// interleaving is one of:
    ///
    ///   R A | C P — the admission completed before the transition published anything →
    ///               correctly admitted into the OLD epoch. (Its display is dropped by the
    ///               engine's serialized token check, its clock stamp is cleared by the
    ///               fallback caller right after this returns, and its first-frame delivery is
    ///               revalidated against the token at receipt.)
    ///   R | C A P — A sees the new control token, the frame carries the old one → refused.
    ///   R | C P A — same → refused.
    ///   C | R A P — R still reads the old `renderState` token; the control is new → refused.
    ///   C | R P A — same: R read the old token before P → refused.
    ///   C P | R A — R sees the fully published new state → correctly admitted into the NEW
    ///               epoch.
    ///
    /// So a frame is admitted only when its admission completes entirely before C or its read
    /// happens entirely after P — never across the transition. With the REVERSED order
    /// (`renderState` first) the interleaving R P A C wrongly admits: R reads the old token and
    /// A matches it against the control's not-yet-updated old token, so a stale frame is
    /// admitted mid-transition, stamps the clock (which the fallback only clears AFTER this
    /// returns — the stale stamp would then be wiped, but the queued first-frame event could
    /// not be retracted) and fires first-frame. That is the order
    /// `epochMidTransitionHookForTesting` exists to pin.
    private func advanceEpoch(generation: Int? = nil) -> VideoDisplayEngine.RenderToken {
        // Reserve the next token value without publishing it to the decode thread's read.
        let (token, newGeneration) = renderState.withLock { state in
            let token = VideoDisplayEngine.RenderToken(rawValue: state.nextTokenValue)
            state.nextTokenValue &+= 1
            return (token, generation ?? state.generation)
        }
        control.setAdmittedToken(token)
        #if DEBUG
        epochMidTransitionHookForTesting?()
        #endif
        renderState.withLock { state in
            state.generation = newGeneration
            state.token = token
        }
        return token
    }

    #if DEBUG
    /// Test seam: runs between the two epoch publications (control token first, `renderState`
    /// second), so a test can observe — and pin — the publication order `advanceEpoch` proves
    /// safe. Nil in production, compiled out of Release; the frame path never touches it.
    var epochMidTransitionHookForTesting: (() -> Void)?
    #endif

    /// The exact per-frame read `renderFrame` performs — a test seam for exercising the epoch
    /// transition's interleavings deterministically.
    var epochReadForTesting: (generation: Int, token: VideoDisplayEngine.RenderToken) {
        renderState.withLock { ($0.generation, $0.token) }
    }

    /// Display-engine seams for tests; the frame path never touches them.
    var displayStatsForTesting: VideoDisplayEngine.Stats { engine.currentStats }

    func waitForDisplayEngineForTesting() {
        engine.waitForPendingWork()
    }

    // MARK: RTCVideoRenderer

    /// Called on WebRTC's decode/worker thread for every decoded frame.
    ///
    /// Everything here is lock-local: no `Task`, no `DispatchQueue.sync`, no main-actor touch.
    /// The display hand-off is one `dispatch_async` onto the render path's own serial queue.
    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }

        let (generation, token) = renderState.withLock { ($0.generation, $0.token) }
        let now = CACurrentMediaTime()
        // Provenance is the frame's own buffer class — the one identity that survives however
        // late this callback runs (see `VideoRenderControl.admitFrame`). One `isKindOfClass`,
        // no lock, no main-thread work.
        let fromH265Decoder = frame.buffer is OverlookH265PixelBuffer
        let admission = control.admitFrame(
            generation: generation,
            token: token,
            fromH265Decoder: fromH265Decoder,
            at: now
        )
        guard admission.isAdmitted else { return }

        if frame.rotation != ._0 {
            VideoRenderView.logRotationOnce(frame.rotation)
        }

        engine.display(frame.buffer, token: token)

        // Watchdog testing (OVERLOOK_FORCE_DECODE_STARVATION) withholds the signals only; the
        // frame above is still displayed, exactly as before.
        guard admission.signalsSuppressed == false else { return }

        let measuredFps = signalGate.recordFrame(at: now)
        let shouldCaptureFrame = admission.isFrameCaptureEnabled
            && signalGate.shouldCaptureFrame(at: now)

        if admission.isFirstDecodedFrame {
            // The token travels with the delivery: this task can be queued a moment before a
            // fallback advances the epoch, and the sink revalidates the token at receipt.
            Task { @MainActor [weak self] in
                self?.sink?.videoRenderDidReceiveFirstFrame(generation: generation, token: token)
            }
        }

        if let measuredFps {
            Task { @MainActor [weak self] in
                self?.sink?.videoRenderDidMeasureFps(measuredFps, generation: generation)
            }
        }

        if shouldCaptureFrame, let pixelBufferFrame = frame.buffer as? RTCCVPixelBuffer {
            captureFrame(pixelBufferFrame.pixelBuffer, generation: generation)
        }
    }

    /// Hands the newest frame to OCR without spawning a task per frame: the slot keeps only the
    /// latest buffer and at most one main-actor drain is ever scheduled, so a stalled main thread
    /// cannot accumulate retained IOSurfaces.
    private nonisolated func captureFrame(_ pixelBuffer: CVPixelBuffer, generation: Int) {
        guard captureSlot.store(pixelBuffer, generation: generation) else { return }
        Task { @MainActor [weak self] in
            self?.drainCapturedFrame()
        }
    }

    @MainActor
    private func drainCapturedFrame() {
        guard let captured = captureSlot.take() else { return }
        sink?.videoRenderDidCaptureFrame(captured.pixelBuffer, generation: captured.generation)
    }

    /// True while a captured frame is waiting for its main-actor drain. A test seam; the frame
    /// path never reads it.
    var hasPendingCapturedFrameForTesting: Bool {
        captureSlot.hasPendingFrame
    }

    /// Called by WebRTC when the track's frame size changes. Rare, and the manager equality-gates
    /// the publish, so a plain hop is the right cost here.
    nonisolated func setSize(_ size: CGSize) {
        let generation = renderState.withLock { $0.generation }
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
