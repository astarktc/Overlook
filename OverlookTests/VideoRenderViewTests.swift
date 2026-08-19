// swiftlint:disable file_length
import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import XCTest

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)

/// An IOSurface-backed NV12 buffer shaped like decoder output, shared by both test classes.
private func makeNV12PixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attributes as CFDictionary,
        &pixelBuffer
    )
    return try XCTUnwrap(pixelBuffer, "CVPixelBufferCreate failed with \(status)")
}

private func makeFrameBuffer(width: Int = 320, height: Int = 240) throws -> RTCCVPixelBuffer {
    RTCCVPixelBuffer(pixelBuffer: try makeNV12PixelBuffer(width: width, height: height))
}

/// Unit coverage for the seams of the `AVSampleBufferDisplayLayer` video renderer that do not
/// need a live stream: the connection-generation guard, the fps/capture throttles and the
/// coalescing OCR capture slot.
///
/// Everything visual (does video actually appear, aspect, resolution change mid-stream,
/// reconnect, fullscreen, OCR, immunity to a stalled main thread) needs a real device and is
/// verified by hand.
final class VideoRenderViewTests: XCTestCase {
    private let tokenOne = VideoDisplayEngine.RenderToken(rawValue: 1)
    private let tokenTwo = VideoDisplayEngine.RenderToken(rawValue: 2)

    // MARK: - Generation guard

    func testAdmitFrameRejectsFramesFromASupersededConnection() {
        let control = VideoRenderControl()
        control.setGeneration(7)
        control.setAdmittedToken(tokenOne)

        let stale = control.admitFrame(generation: 6, token: tokenOne, fromH265Decoder: false, at: 100)

        XCTAssertEqual(stale, .stale)
        XCTAssertNil(
            control.lastFrameTime,
            "A frame from a torn-down connection must not stamp the stream-health clock"
        )
    }

    func testAdmitFrameRejectsFramesBeforeAnyConnectionGenerationIsPublished() {
        let control = VideoRenderControl()

        XCTAssertFalse(
            control.admitFrame(generation: 0, token: tokenOne, fromH265Decoder: false, at: 1).isAdmitted
        )
        XCTAssertFalse(control.isCurrentGeneration(0))
    }

    func testAdmitFrameReportsTheFirstDecodedFrameExactlyOncePerConnection() {
        let control = VideoRenderControl()
        control.setGeneration(1)
        control.setAdmittedToken(tokenOne)

        let first = control.admitFrame(generation: 1, token: tokenOne, fromH265Decoder: false, at: 10)
        let second = control.admitFrame(generation: 1, token: tokenOne, fromH265Decoder: false, at: 11)

        XCTAssertTrue(first.isFirstDecodedFrame)
        XCTAssertFalse(second.isFirstDecodedFrame)
        XCTAssertEqual(control.lastFrameTime, 11)

        // A new connection generation with a cleared clock starts a fresh initial-frame window.
        control.setGeneration(2)
        control.setAdmittedToken(tokenTwo)
        control.setLastFrameTime(nil)
        XCTAssertTrue(
            control.admitFrame(generation: 2, token: tokenTwo, fromH265Decoder: false, at: 12)
                .isFirstDecodedFrame
        )
    }

    func testAdmitFrameSuppressesSignalsWithoutStampingTheFrameClock() {
        let control = VideoRenderControl()
        control.setGeneration(3)
        control.setAdmittedToken(tokenOne)
        control.setSuppressFrameArrivalSignals(true)

        let admission = control.admitFrame(generation: 3, token: tokenOne, fromH265Decoder: false, at: 20)

        XCTAssertTrue(
            admission.isAdmitted,
            "The frame is still displayed while signals are suppressed"
        )
        XCTAssertTrue(admission.signalsSuppressed)
        XCTAssertFalse(admission.isFirstDecodedFrame)
        XCTAssertNil(control.lastFrameTime)
    }

    func testAdmitFrameMirrorsTheFrameCaptureGate() {
        let control = VideoRenderControl()
        control.setGeneration(4)
        control.setAdmittedToken(tokenOne)

        XCTAssertFalse(
            control.admitFrame(generation: 4, token: tokenOne, fromH265Decoder: false, at: 30)
                .isFrameCaptureEnabled
        )

        control.setFrameCaptureEnabled(true)
        XCTAssertTrue(
            control.admitFrame(generation: 4, token: tokenOne, fromH265Decoder: false, at: 31)
                .isFrameCaptureEnabled
        )

        control.setFrameCaptureEnabled(false)
        XCTAssertFalse(
            control.admitFrame(generation: 4, token: tokenOne, fromH265Decoder: false, at: 32)
                .isFrameCaptureEnabled
        )
    }

    // MARK: - FPS window

    func testFpsIsPublishedAtMostTwiceASecondAndQuantizedToWholeFrames() {
        var throttles = VideoFrameSignalThrottles()

        // 60 frames spaced 1/60 s apart span ~0.98 s, so exactly one 0.5 s window closes.
        var published: [Int] = []
        for index in 0..<60 {
            let now = 1_000.0 + Double(index) / 60.0
            if let fps = throttles.recordFrame(at: now) {
                published.append(fps)
            }
        }

        XCTAssertEqual(
            published,
            [62],
            "One publish per closed 0.5 s window: 31 frames in 0.5 s, rounded to whole frames"
        )
    }

    func testFpsWindowResetsAfterEachPublish() {
        var throttles = VideoFrameSignalThrottles()

        XCTAssertNil(throttles.recordFrame(at: 100.0), "The first frame opens the window")
        XCTAssertNil(throttles.recordFrame(at: 100.4))
        // 3 frames over the 0.5 s window that just closed → 6 fps.
        XCTAssertEqual(throttles.recordFrame(at: 100.5), 6)
        XCTAssertEqual(throttles.frameCount, 0)
        XCTAssertEqual(throttles.windowStartTime, 100.5)

        XCTAssertNil(throttles.recordFrame(at: 100.9), "The next window has to fill again")
        XCTAssertEqual(throttles.recordFrame(at: 101.0), 4)
    }

    func testFpsAccountingDoesNotTreatTimeZeroAsAnUnopenedWindow() {
        // The old main-actor implementation used 0 as its "no window yet" sentinel, which made
        // the very first window's timing depend on the clock's origin. The window is explicitly
        // optional now, so a time base starting at 0 behaves like any other.
        var throttles = VideoFrameSignalThrottles()

        XCTAssertNil(throttles.recordFrame(at: 0.0))
        XCTAssertNil(throttles.recordFrame(at: 0.4))
        XCTAssertEqual(throttles.recordFrame(at: 0.5), 6)
    }

    // MARK: - Capture throttle

    func testFrameCaptureIsThrottledToTwelveHertz() {
        var throttles = VideoFrameSignalThrottles()

        XCTAssertTrue(throttles.shouldCaptureFrame(at: 100.0), "The first frame is always captured")
        XCTAssertFalse(throttles.shouldCaptureFrame(at: 100.02))
        XCTAssertFalse(throttles.shouldCaptureFrame(at: 100.08), "Still inside the 1/12 s window")
        XCTAssertTrue(throttles.shouldCaptureFrame(at: 100.09), "1/12 s has elapsed")
        XCTAssertFalse(throttles.shouldCaptureFrame(at: 100.1))
        XCTAssertTrue(throttles.shouldCaptureFrame(at: 100.18))
    }

    func testSignalGateSerializesThrottleStateForTheDecodeThread() {
        let gate = VideoFrameSignalGate()

        XCTAssertNil(gate.recordFrame(at: 100.0))
        XCTAssertEqual(gate.recordFrame(at: 100.5), 4)
        XCTAssertTrue(gate.shouldCaptureFrame(at: 100.5))
        XCTAssertFalse(gate.shouldCaptureFrame(at: 100.5))

        gate.reset()
        XCTAssertTrue(gate.shouldCaptureFrame(at: 100.5), "A reset gate captures again immediately")
        XCTAssertNil(gate.recordFrame(at: 100.5), "...and its fps window starts over")
    }

    // MARK: - OCR capture coalescing

    func testCaptureSlotSchedulesOneDrainAndKeepsOnlyTheNewestFrame() throws {
        let slot = VideoFrameCaptureSlot()
        let first = try makeNV12PixelBuffer(width: 320, height: 240)
        let second = try makeNV12PixelBuffer(width: 640, height: 480)

        XCTAssertTrue(
            slot.store(first, generation: 5),
            "The first capture has to schedule the main-actor drain"
        )
        XCTAssertFalse(
            slot.store(second, generation: 5),
            "A drain is already scheduled: replace the slot instead of spawning another task"
        )

        let drained = try XCTUnwrap(slot.take())
        XCTAssertTrue(
            drained.pixelBuffer === second,
            "OCR wants the newest frame; the superseded buffer must be released, not queued"
        )
        XCTAssertEqual(drained.generation, 5)
        XCTAssertNil(slot.take(), "Nothing is left behind after a drain")

        XCTAssertTrue(
            slot.store(first, generation: 6),
            "Once drained, the next capture schedules a fresh drain"
        )
    }

    func testCaptureSlotClearReleasesAFrameThatNeverGotDrained() throws {
        let slot = VideoFrameCaptureSlot()
        _ = slot.store(try makeNV12PixelBuffer(width: 320, height: 240), generation: 1)
        XCTAssertTrue(slot.hasPendingFrame)

        slot.clear()

        XCTAssertFalse(
            slot.hasPendingFrame,
            "Teardown must not leave an IOSurface retained for a connection that ended"
        )
        XCTAssertNil(slot.take())
    }

    @MainActor
    func testEndRenderingReleasesAPendingOCRCapture() throws {
        let control = VideoRenderControl()
        control.setGeneration(21)
        control.setFrameCaptureEnabled(true)
        let view = VideoRenderView(control: control, sink: nil)
        let frame = RTCVideoFrame(buffer: try makeFrameBuffer(), rotation: ._0, timeStampNs: 0)

        view.beginRendering(generation: 21)
        view.renderFrame(frame)
        view.endRendering()

        XCTAssertFalse(
            view.hasPendingCapturedFrameForTesting,
            "Teardown clears the capture slot instead of holding the last frame forever"
        )
    }

    // MARK: - View wiring

    @MainActor
    func testViewIsBackedByASampleBufferDisplayLayerThatFitsTheVideo() {
        let view = VideoRenderView(control: VideoRenderControl(), sink: nil)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)

        let layer = view.layer as? AVSampleBufferDisplayLayer
        XCTAssertNotNil(layer, "The backing layer is the display layer, not a Metal view")
        XCTAssertEqual(layer?.videoGravity, .resizeAspect)
        XCTAssertTrue(view.wantsLayer)
        XCTAssertTrue(view.isOpaque)
    }

    @MainActor
    func testRenderFrameDropsFramesUntilTheViewIsArmedForAGeneration() throws {
        let control = VideoRenderControl()
        control.setGeneration(11)
        let view = VideoRenderView(control: control, sink: nil)
        let frame = RTCVideoFrame(buffer: try makeFrameBuffer(), rotation: ._0, timeStampNs: 0)

        // Not attached to a track yet: nothing is admitted, so the health clock stays empty.
        view.renderFrame(frame)
        XCTAssertNil(control.lastFrameTime)

        view.beginRendering(generation: 11)
        view.renderFrame(frame)
        XCTAssertNotNil(control.lastFrameTime, "An armed view admits and stamps the frame")

        // Teardown is symmetric: a late frame from the finished connection is ignored.
        control.setLastFrameTime(nil)
        view.endRendering()
        view.renderFrame(frame)
        XCTAssertNil(control.lastFrameTime)
    }

    /// The closest thing to proving video actually renders without a live stream: put the view in
    /// a window, push decoded frames through `renderFrame` exactly as WebRTC's decode thread
    /// would, and ask the renderer for the image it is currently displaying.
    ///
    /// This is what pins down the sample-buffer contract — invalid timing plus
    /// `DisplayImmediately`, with no timebase or render synchronizer — as one that really
    /// presents frames rather than silently queueing them forever.
    @MainActor
    func testDecodedFramesReachTheDisplayedImage() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OVERLOOK_SKIP_WINDOW_TESTS"] == nil,
            "Window-backed rendering test disabled by OVERLOOK_SKIP_WINDOW_TESTS"
        )
        guard #available(macOS 14.4, *) else {
            throw XCTSkip("displayedPixelBuffer() needs macOS 14.4")
        }

        _ = NSApplication.shared
        let control = VideoRenderControl()
        control.setGeneration(1)
        let view = VideoRenderView(control: control, sink: nil)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)

        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        view.beginRendering(generation: 1)

        let pixelBuffer = try makeMidGrayNV12PixelBuffer(width: 320, height: 240)
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: 0
        )

        let renderer = try XCTUnwrap(view.layer as? AVSampleBufferDisplayLayer).sampleBufferRenderer
        var displayed: CVPixelBuffer?
        let deadline = Date().addingTimeInterval(5.0)
        while displayed == nil, Date() < deadline {
            view.renderFrame(frame)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            displayed = renderer.displayedPixelBuffer()
        }

        XCTAssertNotEqual(renderer.status, .failed, "\(String(describing: renderer.error))")
        let displayedBuffer = try XCTUnwrap(
            displayed,
            "The display layer never presented an enqueued frame"
        )
        XCTAssertEqual(CVPixelBufferGetWidth(displayedBuffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(displayedBuffer), 240)
    }

    private func makeMidGrayNV12PixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let pixelBuffer = try makeNV12PixelBuffer(width: width, height: height)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            memset(base, 128, bytes)
        }
        return pixelBuffer
    }
}

// MARK: - Stream epochs (codec fallback inside one connection)

/// Records first-frame deliveries exactly as `WebRTCManager` receives them, so the tests can
/// assert what actually crosses the main-actor boundary — including the token the receiver
/// revalidates at receipt.
@MainActor
private final class FirstFrameRecordingSink: VideoRenderSignalSink {
    private(set) var firstFrames: [(generation: Int, token: VideoDisplayEngine.RenderToken)] = []

    func videoRenderDidReceiveFirstFrame(generation: Int, token: VideoDisplayEngine.RenderToken) {
        firstFrames.append((generation, token))
    }

    func videoRenderDidMeasureFps(_ fps: Int, generation: Int) {}
    func videoRenderDidCaptureFrame(_ pixelBuffer: CVPixelBuffer, generation: Int) {}
    func videoRenderDidChangeSize(_ size: CGSize, generation: Int) {}

    /// Lets the decode path's queued `Task { @MainActor }` deliveries drain. Returns once
    /// `count` deliveries arrived or the budget ran out — the caller asserts the exact count,
    /// so waiting too long can only make the test slower, never wrong.
    func drainDeliveries(expecting count: Int) async {
        for _ in 0..<200 where firstFrames.count < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // One extra beat so an *unexpected* additional delivery would still be observed.
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Coverage for the stream-epoch machinery as a whole: the control's token and H.265
/// provenance predicates, the epoch transition's publication order, and the end-to-end
/// fallback shape through a real `VideoRenderView`.
final class VideoStreamEpochTests: XCTestCase {
    private let tokenOne = VideoDisplayEngine.RenderToken(rawValue: 1)
    private let tokenTwo = VideoDisplayEngine.RenderToken(rawValue: 2)

    // MARK: - Token predicate (isolated)
    //
    // These pin `VideoRenderControl`'s token predicate on its own. They deliberately do NOT
    // claim to cover the fallback behavior end to end — the token is read when a decode
    // callback *begins*, so a callback that starts after the fallback reads the new token and
    // this predicate alone cannot refuse it. The fallback shape as a whole is pinned by the
    // `VideoRenderView`-level tests below.

    func testAdmitFrameRejectsFramesBeforeAnyStreamEpochIsArmed() {
        let control = VideoRenderControl()
        control.setGeneration(1)

        XCTAssertEqual(
            control.admitFrame(generation: 1, token: .invalid, fromH265Decoder: false, at: 1),
            .stale,
            "No frame can ever be admitted against the invalid epoch"
        )
    }

    func testAdmitFrameRefusesATokenTheControlNoLongerAdmits() {
        let control = VideoRenderControl()
        control.setGeneration(5)
        control.setAdmittedToken(tokenOne)

        // A frame was flowing under the old token.
        XCTAssertTrue(
            control.admitFrame(generation: 5, token: tokenOne, fromH265Decoder: false, at: 10)
                .isFirstDecodedFrame
        )

        // The admitted token advances (same generation) and the clock is cleared.
        control.setAdmittedToken(tokenTwo)
        control.setLastFrameTime(nil)

        // A frame still carrying the old token — one whose decode callback began before the
        // transition — is refused.
        let stale = control.admitFrame(generation: 5, token: tokenOne, fromH265Decoder: false, at: 11)

        XCTAssertEqual(stale, .stale, "Neither displayed nor counted")
        XCTAssertFalse(stale.isFirstDecodedFrame)
        XCTAssertNil(control.lastFrameTime, "A refused frame must not stamp the health clock")
    }

    func testAdmitFrameTreatsTheFirstFrameOfTheNewTokenWithAClearedClockAsFirst() {
        let control = VideoRenderControl()
        control.setGeneration(5)
        control.setAdmittedToken(tokenOne)
        _ = control.admitFrame(generation: 5, token: tokenOne, fromH265Decoder: false, at: 10)

        // Token advances, clock cleared; a stray old-token frame is refused in between.
        control.setAdmittedToken(tokenTwo)
        control.setLastFrameTime(nil)
        _ = control.admitFrame(generation: 5, token: tokenOne, fromH265Decoder: false, at: 11)

        let first = control.admitFrame(generation: 5, token: tokenTwo, fromH265Decoder: false, at: 12)

        XCTAssertTrue(first.isAdmitted, "The new token's frame is displayed")
        XCTAssertTrue(first.isFirstDecodedFrame)
        XCTAssertEqual(control.lastFrameTime, 12, "… and it stamps the health clock")
    }

    // MARK: - H.265 provenance guard

    /// The guard the token cannot provide: a decode callback for an abandoned-H.265-stream
    /// frame that *begins* after the fallback reads the CURRENT token and would pass the epoch
    /// check. Provenance travels with the frame (`OverlookH265PixelBuffer`), so revocation
    /// refuses it even with the current token.
    func testAdmitFrameRefusesH265DecodedFramesAfterRevocationEvenWithTheCurrentToken() {
        let control = VideoRenderControl()
        control.setGeneration(5)
        control.setAdmittedToken(tokenOne)

        // The fallback revokes H.265 admission, advances the epoch, clears the clock.
        control.setAdmitsH265DecodedFrames(false)
        control.setAdmittedToken(tokenTwo)
        control.setLastFrameTime(nil)

        // Worst case: the abandoned stream's frame arrives carrying the CURRENT token.
        let stale = control.admitFrame(generation: 5, token: tokenTwo, fromH265Decoder: true, at: 11)

        XCTAssertEqual(stale, .stale)
        XCTAssertNil(control.lastFrameTime, "No clock stamp on the replacement stream's behalf")

        // The replacement (H.264) stream's frames are unaffected.
        let first = control.admitFrame(generation: 5, token: tokenTwo, fromH265Decoder: false, at: 12)
        XCTAssertTrue(first.isAdmitted)
        XCTAssertTrue(first.isFirstDecodedFrame, "The replacement stream still gets its first frame")
    }

    func testANewConnectionGenerationRearmsH265DecodedFrameAdmission() {
        let control = VideoRenderControl()
        control.setGeneration(5)
        control.setAdmittedToken(tokenOne)
        control.setAdmitsH265DecodedFrames(false)

        // A new connection restarts codec selection, so H.265 may be tried again.
        control.setGeneration(6)
        control.setAdmittedToken(tokenTwo)

        XCTAssertTrue(
            control.admitFrame(generation: 6, token: tokenTwo, fromH265Decoder: true, at: 20)
                .isAdmitted,
            "Revocation is scoped to the connection that fell back"
        )
    }

    // MARK: - Epoch revalidation at signal delivery

    /// A first-frame signal's main-actor hop cannot be retracted once queued, so the receiver
    /// revalidates the delivered token against this predicate at receipt.
    func testIsCurrentEpochTracksTheAdmittedTokenAndNeverAcceptsInvalid() {
        let control = VideoRenderControl()

        XCTAssertFalse(control.isCurrentEpoch(.invalid), "Invalid never validates, even when armed")

        control.setAdmittedToken(tokenOne)
        XCTAssertTrue(control.isCurrentEpoch(tokenOne))
        XCTAssertFalse(control.isCurrentEpoch(tokenTwo))

        control.setAdmittedToken(tokenTwo)
        XCTAssertFalse(
            control.isCurrentEpoch(tokenOne),
            "A delivery carrying the pre-fallback token is dropped at receipt"
        )
        XCTAssertTrue(control.isCurrentEpoch(tokenTwo))
    }

    // MARK: - Epoch transition publication order

    /// Pins the transition's publication order: the control's admitted token FIRST, the
    /// decode-thread-visible `renderState` SECOND (`VideoRenderView.advanceEpoch`).
    ///
    /// This exercises the vulnerable interleaving deterministically: a decode callback read
    /// the OLD `(generation, token)` just before the transition and reaches `admitFrame`
    /// mid-publication. With the reversed order the control would still hold the old token,
    /// so the stale frame would be WRONGLY admitted — stamping the freshly-cleared clock and
    /// firing first-frame. With the pinned order the control has already moved on and the
    /// frame is refused. The hook runs between the two publications, so this test fails if
    /// the order is ever swapped.
    @MainActor
    func testEpochTransitionPublishesTheControlTokenBeforeTheDecodeThreadVisibleState() throws {
        let control = VideoRenderControl()
        control.setGeneration(6)
        let view = VideoRenderView(control: control, sink: nil)
        view.beginRendering(generation: 6)

        // R: the decode callback's read, taken before the transition begins.
        let preTransitionRead = view.epochReadForTesting

        struct MidTransitionObservation {
            var controlMovedOn: Bool
            var viewStillOld: Bool
            var admission: VideoRenderControl.FrameAdmission
        }
        var midTransition: MidTransitionObservation?
        view.epochMidTransitionHookForTesting = { [weak view] in
            guard let view else { return }
            midTransition = MidTransitionObservation(
                controlMovedOn: control.isCurrentEpoch(preTransitionRead.token) == false,
                viewStillOld: view.epochReadForTesting.token == preTransitionRead.token,
                // A: the stale admission attempt, exactly mid-transition.
                admission: control.admitFrame(
                    generation: preTransitionRead.generation,
                    token: preTransitionRead.token,
                    fromH265Decoder: false,
                    at: 50
                )
            )
        }
        view.flushDisplay()
        view.epochMidTransitionHookForTesting = nil

        let observed = try XCTUnwrap(midTransition, "The transition must pass through the seam")
        XCTAssertTrue(observed.controlMovedOn, "C before P: the control token publishes first")
        XCTAssertTrue(observed.viewStillOld, "renderState still holds the old epoch mid-transition")
        XCTAssertEqual(
            observed.admission,
            .stale,
            "A frame whose read and admission straddle the transition is refused, never admitted"
        )
        XCTAssertNil(control.lastFrameTime, "… so it cannot stamp the clock either")
    }

    // MARK: - The fallback, end to end through the view

    /// `flushDisplay()` moves the display epoch *and* the signal epoch together: after the
    /// codec-fallback flush the view's own frames are still admitted (the two sides adopted
    /// the same new token), so the replacement stream's first frame is not lost to the guard.
    @MainActor
    func testFlushDisplayAdvancesTheSignalEpochInStepWithTheView() throws {
        let control = VideoRenderControl()
        control.setGeneration(9)
        let view = VideoRenderView(control: control, sink: nil)
        let frame = RTCVideoFrame(buffer: try makeFrameBuffer(), rotation: ._0, timeStampNs: 0)

        view.beginRendering(generation: 9)
        view.renderFrame(frame)
        XCTAssertNotNil(control.lastFrameTime, "The pre-fallback stream is flowing")

        // The codec-fallback sequence: flush (epoch advance), then a fresh health window.
        view.flushDisplay()
        control.setLastFrameTime(nil)

        view.renderFrame(frame)
        XCTAssertNotNil(
            control.lastFrameTime,
            "A frame decoded after the flush belongs to the new epoch and is admitted"
        )
    }

    /// The end-to-end fallback shape, through a real `VideoRenderView` and sink: one
    /// abandoned-stream (H.265) frame whose decode callback begins only AFTER the fallback —
    /// the worst case, because it reads the NEW epoch token — does none of {display,
    /// health-clock stamp, first-frame}, while the replacement stream's first frame does all
    /// three.
    @MainActor
    func testAFallbackAbandonedStreamFrameDoesNothingWhileTheReplacementsFirstFrameDoesEverything() async throws {
        let control = VideoRenderControl()
        control.setGeneration(3)
        let sink = FirstFrameRecordingSink()
        let view = VideoRenderView(control: control, sink: sink)
        view.beginRendering(generation: 3)

        let abandonedStreamFrame = RTCVideoFrame(
            buffer: OverlookH265PixelBuffer(
                pixelBuffer: try makeNV12PixelBuffer(width: 320, height: 240)
            ),
            rotation: ._0,
            timeStampNs: 0
        )
        let replacementFrame = RTCVideoFrame(buffer: try makeFrameBuffer(), rotation: ._0, timeStampNs: 0)

        // The H.265 stream delivered nothing (which is why the watchdog fired). The manager's
        // fallback sequence runs: revoke + flush + epoch advance, then a fresh health window.
        view.flushDisplayAbandoningH265Stream()
        control.setLastFrameTime(nil)
        view.waitForDisplayEngineForTesting()
        let statsAfterFallback = view.displayStatsForTesting

        // A queued decode callback for an abandoned-stream frame begins only NOW — after the
        // epoch advanced — so it reads the post-fallback token: the exact interleaving the
        // token alone cannot refuse. Provenance is what stops it.
        view.renderFrame(abandonedStreamFrame)
        view.waitForDisplayEngineForTesting()

        XCTAssertEqual(
            view.displayStatsForTesting,
            statsAfterFallback,
            "The abandoned stream's frame never reaches the display engine"
        )
        XCTAssertNil(control.lastFrameTime, "… does not stamp the health clock")

        // The replacement stream's first frame: displayed, stamped, signalled.
        view.renderFrame(replacementFrame)
        view.waitForDisplayEngineForTesting()

        XCTAssertEqual(
            view.displayStatsForTesting.enqueued,
            statsAfterFallback.enqueued + 1,
            "The replacement stream's frame is displayed"
        )
        XCTAssertNotNil(control.lastFrameTime, "… stamps the health clock")

        await sink.drainDeliveries(expecting: 1)
        XCTAssertEqual(
            sink.firstFrames.count,
            1,
            "Exactly one first-frame signal: the replacement's, never the abandoned stream's"
        )
        let delivered = try XCTUnwrap(sink.firstFrames.first)
        XCTAssertEqual(delivered.generation, 3)
        XCTAssertTrue(
            control.isCurrentEpoch(delivered.token),
            "The delivery carries the admitted token, so the receiver's revalidation accepts it"
        )
    }
}

// MARK: - Display engine

/// Coverage for what the enqueue queue itself decides: which epoch a frame belongs to, whether the
/// display layer can take another frame, how a failed renderer is retried, and the sample buffer
/// handed over.
final class VideoDisplayEngineTests: XCTestCase {
    /// A stand-in for `AVSampleBufferVideoRenderer`, so backpressure and failure recovery can be
    /// tested without a window, a display server or a live stream.
    ///
    /// Every member is touched on the engine's serial enqueue queue; tests read them only after
    /// `waitForPendingWork()`, which is what orders those accesses.
    private final class FakeSampleBufferRenderer: VideoSampleBufferRendering, @unchecked Sendable {
        var isReadyForMoreMediaData = true
        var requiresFlushToResumeDecoding = false
        var status: AVQueuedSampleBufferRenderingStatus = .rendering
        var error: Error?

        var enqueuedBuffers: [CMSampleBuffer] = []
        var flushCount = 0
        /// When true, every enqueue drops the renderer into `.failed`, like one whose decoder
        /// resources were revoked.
        var failsOnEnqueue = false

        func enqueue(_ sampleBuffer: CMSampleBuffer) {
            enqueuedBuffers.append(sampleBuffer)
            if failsOnEnqueue {
                status = .failed
            }
        }

        func flush() {
            flushCount += 1
            // A flush is what clears a failed renderer, on the real one too.
            if status == .failed {
                status = .rendering
            }
            error = nil
        }
    }

    private let firstToken = VideoDisplayEngine.RenderToken(rawValue: 1)
    private let secondToken = VideoDisplayEngine.RenderToken(rawValue: 2)

    // MARK: - Render tokens

    func testFramesCarryingASupersededTokenAreDroppedInsteadOfEnqueued() throws {
        let renderer = FakeSampleBufferRenderer()
        let engine = VideoDisplayEngine(videoRenderer: renderer)
        engine.begin(token: firstToken)

        // The teardown race: the decode thread read the token, was admitted, and only *then*
        // handed the frame over — after `end()` had already flushed.
        engine.end()
        engine.display(try makeFrameBuffer(), token: firstToken)
        engine.waitForPendingWork()

        XCTAssertTrue(
            renderer.enqueuedBuffers.isEmpty,
            "A frame admitted before teardown must not reach the layer after the flush"
        )
        XCTAssertEqual(engine.currentStats.droppedStaleToken, 1)
        XCTAssertEqual(engine.currentStats.enqueued, 0)
    }

    func testFramesFromThePreviousEpochAreDroppedAfterAFlushAdvancesTheToken() throws {
        let renderer = FakeSampleBufferRenderer()
        let engine = VideoDisplayEngine(videoRenderer: renderer)
        engine.begin(token: firstToken)

        engine.flush(token: secondToken)
        engine.display(try makeFrameBuffer(), token: firstToken)
        engine.display(try makeFrameBuffer(), token: secondToken)
        engine.waitForPendingWork()

        XCTAssertEqual(engine.currentStats.droppedStaleToken, 1, "The abandoned stream's frame")
        XCTAssertEqual(engine.currentStats.enqueued, 1, "The new epoch's frame still displays")
        XCTAssertEqual(renderer.enqueuedBuffers.count, 1)
    }

    func testNoFrameIsEnqueuedBeforeRenderingBegins() throws {
        let renderer = FakeSampleBufferRenderer()
        let engine = VideoDisplayEngine(videoRenderer: renderer)

        engine.display(try makeFrameBuffer(), token: firstToken)
        engine.waitForPendingWork()

        XCTAssertTrue(renderer.enqueuedBuffers.isEmpty)
        XCTAssertEqual(engine.currentStats.droppedStaleToken, 1)
    }

    func testBeginAdoptsTheNewEpochAndEnqueuesItsFrames() throws {
        let renderer = FakeSampleBufferRenderer()
        let engine = VideoDisplayEngine(videoRenderer: renderer)

        engine.begin(token: firstToken)
        engine.display(try makeFrameBuffer(), token: firstToken)
        engine.waitForPendingWork()

        XCTAssertEqual(renderer.enqueuedBuffers.count, 1)
        XCTAssertEqual(engine.currentStats.enqueued, 1)
        XCTAssertEqual(engine.currentStats.droppedStaleToken, 0)
    }

    // MARK: - Layer backpressure

    func testFramesAreDroppedWhileTheLayerIsNotReadyForMoreMediaData() throws {
        let renderer = FakeSampleBufferRenderer()
        let engine = VideoDisplayEngine(videoRenderer: renderer)
        engine.begin(token: firstToken)

        // An occluded or minimised window: the layer stops consuming, and every sample buffer it
        // retains pins an IOSurface out of the decoder pool.
        renderer.isReadyForMoreMediaData = false
        for _ in 0..<3 {
            engine.display(try makeFrameBuffer(), token: firstToken)
            engine.waitForPendingWork()
        }

        XCTAssertTrue(renderer.enqueuedBuffers.isEmpty, "Live video drops rather than queues")
        XCTAssertEqual(engine.currentStats.droppedNotReady, 3)

        // ...and it recovers on its own as soon as the layer consumes again.
        renderer.isReadyForMoreMediaData = true
        engine.display(try makeFrameBuffer(), token: firstToken)
        engine.waitForPendingWork()

        XCTAssertEqual(renderer.enqueuedBuffers.count, 1)
        XCTAssertEqual(engine.currentStats.enqueued, 1)
    }

    // MARK: - Failure backoff

    func testAPersistentlyFailingRendererIsRetriedOnABackoffRatherThanEveryFrame() throws {
        let renderer = FakeSampleBufferRenderer()
        renderer.failsOnEnqueue = true
        let engine = VideoDisplayEngine(videoRenderer: renderer)
        engine.begin(token: firstToken)

        // 30 frames ≈ half a second of 60 fps video arriving faster than the first backoff window.
        for _ in 0..<30 {
            engine.display(try makeFrameBuffer(), token: firstToken)
            engine.waitForPendingWork()
        }

        XCTAssertEqual(
            renderer.enqueuedBuffers.count,
            1,
            "One recovery attempt, not one per frame: the rest wait out the backoff"
        )
        XCTAssertEqual(engine.currentStats.enqueued, 0)
        XCTAssertEqual(engine.currentStats.droppedFailureBackoff, 29)
    }

    func testFailureBackoffEscalatesAndClearsOnSuccess() {
        var backoff = VideoDisplayEngine.FailureBackoff()

        XCTAssertTrue(backoff.shouldAttemptEnqueue(at: 100.0), "Nothing has failed yet")

        backoff.recordFailure(at: 100.0)
        XCTAssertFalse(backoff.shouldAttemptEnqueue(at: 100.05))
        XCTAssertTrue(backoff.shouldAttemptEnqueue(at: 100.1), "First delay is 0.1 s")

        backoff.recordFailure(at: 100.1)
        XCTAssertFalse(backoff.shouldAttemptEnqueue(at: 100.3), "Second delay is longer")
        XCTAssertTrue(backoff.shouldAttemptEnqueue(at: 100.35))

        backoff.recordSuccess()
        XCTAssertEqual(backoff.consecutiveFailures, 0)
        XCTAssertNil(backoff.retryAfter)
        XCTAssertTrue(backoff.shouldAttemptEnqueue(at: 100.36))
    }

    func testFailureBackoffCapsAtItsLongestDelay() throws {
        var backoff = VideoDisplayEngine.FailureBackoff()
        var now: CFTimeInterval = 0

        for _ in 0..<10 {
            _ = backoff.shouldAttemptEnqueue(at: now)
            backoff.recordFailure(at: now)
            now = try XCTUnwrap(backoff.retryAfter)
        }

        let longest = try XCTUnwrap(VideoDisplayEngine.FailureBackoff.delays.last)
        backoff.recordFailure(at: 500)
        XCTAssertEqual(backoff.retryAfter, 500 + longest)
    }

    func testAFailedRendererIsFlushedBeforeTheNextEnqueueAttempt() throws {
        let renderer = FakeSampleBufferRenderer()
        let engine = VideoDisplayEngine(videoRenderer: renderer)
        engine.begin(token: firstToken)
        let flushesFromBegin = { () -> Int in
            engine.waitForPendingWork()
            return renderer.flushCount
        }()

        renderer.requiresFlushToResumeDecoding = true
        engine.display(try makeFrameBuffer(), token: firstToken)
        engine.waitForPendingWork()

        XCTAssertGreaterThan(
            renderer.flushCount,
            flushesFromBegin,
            "A renderer that needs a flush to resume decoding gets one instead of freezing"
        )
        XCTAssertEqual(renderer.enqueuedBuffers.count, 1)
    }

    // MARK: - Format description cache

    func testFormatDescriptionIsCreatedOnceForAnUnchangingFormat() throws {
        var cache = VideoDisplayEngine.FormatDescriptionCache()
        let pixelBuffer = try makeNV12PixelBuffer(width: 640, height: 480)

        let first = cache.formatDescription(for: pixelBuffer)
        let second = cache.formatDescription(for: pixelBuffer)
        let third = cache.formatDescription(for: try makeNV12PixelBuffer(width: 640, height: 480))

        XCTAssertNotNil(first.description)
        XCTAssertFalse(first.replacedPrevious, "Nothing to flush on the very first description")
        XCTAssertTrue(first.description === second.description)
        XCTAssertTrue(first.description === third.description, "Same format ⇒ same description")
        XCTAssertFalse(second.replacedPrevious)
        XCTAssertFalse(third.replacedPrevious)
        XCTAssertEqual(cache.creationCount, 1)
    }

    func testFormatDescriptionIsRecreatedOnAResolutionChange() throws {
        var cache = VideoDisplayEngine.FormatDescriptionCache()

        let hd = try XCTUnwrap(
            cache.formatDescription(for: try makeNV12PixelBuffer(width: 1920, height: 1080)).description
        )
        let changed = cache.formatDescription(for: try makeNV12PixelBuffer(width: 1280, height: 720))
        let resized = try XCTUnwrap(changed.description)

        XCTAssertFalse(hd === resized)
        XCTAssertTrue(
            changed.replacedPrevious,
            "Replacing a description must tell the caller to flush the display layer"
        )
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(resized).width, 1280)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(resized).height, 720)
        XCTAssertEqual(cache.creationCount, 2)
    }

    func testFormatDescriptionCacheResetForgetsThePreviousStream() throws {
        var cache = VideoDisplayEngine.FormatDescriptionCache()
        let pixelBuffer = try makeNV12PixelBuffer(width: 640, height: 480)

        _ = cache.formatDescription(for: pixelBuffer)
        cache.reset()
        let afterReset = cache.formatDescription(for: pixelBuffer)

        XCTAssertNotNil(afterReset.description)
        XCTAssertFalse(
            afterReset.replacedPrevious,
            "A reset cache has no previous description to flush for"
        )
        XCTAssertEqual(cache.creationCount, 2)
    }

    // MARK: - Sample buffer

    func testSampleBufferWrapsThePixelBufferWithoutCopyingAndDisplaysImmediately() throws {
        let pixelBuffer = try makeNV12PixelBuffer(width: 320, height: 240)
        var cache = VideoDisplayEngine.FormatDescriptionCache()
        let formatDescription = try XCTUnwrap(cache.formatDescription(for: pixelBuffer).description)

        let sampleBuffer = try XCTUnwrap(
            VideoDisplayEngine.makeSampleBuffer(
                pixelBuffer: pixelBuffer,
                formatDescription: formatDescription
            )
        )

        XCTAssertTrue(
            CMSampleBufferGetImageBuffer(sampleBuffer) === pixelBuffer,
            "The decoder's pixel buffer must reach the display layer un-copied"
        )
        XCTAssertTrue(CMSampleBufferDataIsReady(sampleBuffer))

        // Live video has no timeline to schedule against: invalid timing + DisplayImmediately.
        XCTAssertFalse(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).isValid)

        let attachments = try XCTUnwrap(
            CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        )
        XCTAssertEqual(CFArrayGetCount(attachments), 1)
        let attachment = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFDictionary.self
        )
        let displayImmediately = (attachment as NSDictionary)[
            kCMSampleAttachmentKey_DisplayImmediately as String
        ] as? Bool
        XCTAssertEqual(displayImmediately, true)
    }

    func testDecoderOutputReachesTheLayerUncopied() throws {
        let renderer = FakeSampleBufferRenderer()
        let engine = VideoDisplayEngine(videoRenderer: renderer)
        engine.begin(token: firstToken)

        let frameBuffer = try makeFrameBuffer()
        engine.display(frameBuffer, token: firstToken)
        engine.waitForPendingWork()

        let enqueued = try XCTUnwrap(renderer.enqueuedBuffers.first)
        XCTAssertTrue(
            CMSampleBufferGetImageBuffer(enqueued) === frameBuffer.pixelBuffer,
            "The zero-copy path: the decoder's IOSurface goes straight to the layer"
        )
    }

    @MainActor
    func testDisplayEngineEnqueuesDecodedFramesWithoutFailingOnARealRenderer() throws {
        let layer = AVSampleBufferDisplayLayer()
        let engine = VideoDisplayEngine(videoRenderer: layer.sampleBufferRenderer)
        engine.begin(token: firstToken)

        for size in [(width: 320, height: 240), (width: 640, height: 480)] {
            let buffer = try makeFrameBuffer(width: size.width, height: size.height)
            engine.display(buffer, token: firstToken)
        }
        engine.waitForPendingWork()

        let renderer = layer.sampleBufferRenderer
        XCTAssertNotEqual(
            renderer.status,
            .failed,
            "Enqueueing decoder output must not fail the renderer: \(String(describing: renderer.error))"
        )
    }

    // MARK: - I420 fallback

    func testI420FallbackProducesAFullRangeNV12BufferWithInterleavedChroma() throws {
        // The software-decoder path: build an I420 buffer with distinguishable planes and check
        // the NV12 result keeps luma intact and interleaves U/V in the right order.
        let width = 16
        let height = 8
        let buffer = RTCMutableI420Buffer(width: Int32(width), height: Int32(height))
        let mutable = try XCTUnwrap(buffer as RTCMutableI420Buffer?)

        for row in 0..<height {
            let plane = mutable.mutableDataY.advanced(by: row * Int(mutable.strideY))
            for column in 0..<width {
                plane[column] = UInt8((row * width + column) % 251)
            }
        }
        for row in 0..<Int(mutable.chromaHeight) {
            let uPlane = mutable.mutableDataU.advanced(by: row * Int(mutable.strideU))
            let vPlane = mutable.mutableDataV.advanced(by: row * Int(mutable.strideV))
            for column in 0..<Int(mutable.chromaWidth) {
                uPlane[column] = 10
                vPlane[column] = 200
            }
        }

        let pixelBuffer = try XCTUnwrap(
            VideoDisplayEngine.makeNV12PixelBuffer(fromI420: mutable)
        )

        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), height)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        XCTAssertEqual(luma[0], 0)
        XCTAssertEqual(luma[width - 1], UInt8(width - 1))
        XCTAssertEqual(luma[lumaStride + 1], UInt8((width + 1) % 251))

        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(chroma[0], 10, "U first")
        XCTAssertEqual(chroma[1], 200, "then V")
        XCTAssertEqual(chroma[2], 10)
        XCTAssertEqual(chroma[3], 200)
    }
}

#endif
