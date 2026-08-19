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

/// Unit coverage for the seams of the `AVSampleBufferDisplayLayer` video renderer that do not
/// need a live stream: the connection-generation guard, the fps/capture throttles, the format
/// description cache, and the sample buffer handed to the display layer.
///
/// Everything visual (does video actually appear, aspect, resolution change mid-stream,
/// reconnect, fullscreen, OCR, immunity to a stalled main thread) needs a real device and is
/// verified by hand.
final class VideoRenderViewTests: XCTestCase {
    // MARK: - Helpers

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
        let buffer = try XCTUnwrap(pixelBuffer, "CVPixelBufferCreate failed with \(status)")
        return buffer
    }

    // MARK: - Generation guard

    func testAdmitFrameRejectsFramesFromASupersededConnection() {
        let control = VideoRenderControl()
        control.setGeneration(7)

        let stale = control.admitFrame(generation: 6, at: 100)

        XCTAssertEqual(stale, .stale)
        XCTAssertNil(
            control.lastFrameTime,
            "A frame from a torn-down connection must not stamp the stream-health clock"
        )
    }

    func testAdmitFrameRejectsFramesBeforeAnyConnectionGenerationIsPublished() {
        let control = VideoRenderControl()

        XCTAssertFalse(control.admitFrame(generation: 0, at: 1).isCurrentGeneration)
        XCTAssertFalse(control.isCurrentGeneration(0))
    }

    func testAdmitFrameReportsTheFirstDecodedFrameExactlyOncePerConnection() {
        let control = VideoRenderControl()
        control.setGeneration(1)

        let first = control.admitFrame(generation: 1, at: 10)
        let second = control.admitFrame(generation: 1, at: 11)

        XCTAssertTrue(first.isFirstDecodedFrame)
        XCTAssertFalse(second.isFirstDecodedFrame)
        XCTAssertEqual(control.lastFrameTime, 11)

        // A new connection generation with a cleared clock starts a fresh initial-frame window.
        control.setGeneration(2)
        control.setLastFrameTime(nil)
        XCTAssertTrue(control.admitFrame(generation: 2, at: 12).isFirstDecodedFrame)
    }

    func testAdmitFrameSuppressesSignalsWithoutStampingTheFrameClock() {
        let control = VideoRenderControl()
        control.setGeneration(3)
        control.setSuppressFrameArrivalSignals(true)

        let admission = control.admitFrame(generation: 3, at: 20)

        XCTAssertTrue(
            admission.isCurrentGeneration,
            "The frame is still displayed while signals are suppressed"
        )
        XCTAssertTrue(admission.signalsSuppressed)
        XCTAssertFalse(admission.isFirstDecodedFrame)
        XCTAssertNil(control.lastFrameTime)
    }

    func testAdmitFrameMirrorsTheFrameCaptureGate() {
        let control = VideoRenderControl()
        control.setGeneration(4)

        XCTAssertFalse(control.admitFrame(generation: 4, at: 30).isFrameCaptureEnabled)

        control.setFrameCaptureEnabled(true)
        XCTAssertTrue(control.admitFrame(generation: 4, at: 31).isFrameCaptureEnabled)

        control.setFrameCaptureEnabled(false)
        XCTAssertFalse(control.admitFrame(generation: 4, at: 32).isFrameCaptureEnabled)
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

    // MARK: - Display engine / view wiring

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
        let pixelBuffer = try makeNV12PixelBuffer(width: 320, height: 240)
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: 0
        )

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

    @MainActor
    func testDisplayEngineEnqueuesDecodedFramesWithoutFailing() throws {
        let layer = AVSampleBufferDisplayLayer()
        let engine = VideoDisplayEngine(videoRenderer: layer.sampleBufferRenderer)

        for size in [(width: 320, height: 240), (width: 640, height: 480)] {
            let pixelBuffer = try makeNV12PixelBuffer(width: size.width, height: size.height)
            engine.display(RTCCVPixelBuffer(pixelBuffer: pixelBuffer))
        }

        // The engine is asynchronous by design; drain its serial queue before asserting.
        let drained = expectation(description: "enqueue queue drained")
        engine.flush()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)

        let renderer = layer.sampleBufferRenderer
        XCTAssertNotEqual(
            renderer.status,
            .failed,
            "Enqueueing decoder output must not fail the renderer: \(String(describing: renderer.error))"
        )
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

#endif
