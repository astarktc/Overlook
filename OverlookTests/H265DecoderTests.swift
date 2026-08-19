import Foundation
import XCTest

final class H265DecoderTests: XCTestCase {
    private struct Nalu {
        let bytesWithStartCode: Data
        let type: UInt8
    }

    private struct Fixture {
        let name: String
        let accessUnits: [Data]
        let sliceCount: Int
    }

    func testSteadyStateCometFixtureDecodesEverySliceAtNativeDimensions() throws {
        let fixture = try loadFixture(named: "lab28-h265-sample")
        XCTAssertEqual(fixture.sliceCount, 358, "Independent Annex-B scan changed")
        try assertDecodesEverySlice(fixture)
    }

    func testRejoinCometFixtureDecodesEverySliceAtNativeDimensions() throws {
        let fixture = try loadFixture(named: "lab28-h265-rejoin")
        XCTAssertEqual(fixture.sliceCount, 478, "Independent Annex-B scan changed")
        try assertDecodesEverySlice(fixture)
    }

    func testDecoderAcceptsRepeatedInBandParameterSetsAcrossARejoin() throws {
        let sample = try loadFixture(named: "lab28-h265-sample")
        let rejoin = try loadFixture(named: "lab28-h265-rejoin")
        // Keep the test focused while crossing two independently captured streams.
        // Each prefix spans the first GOP boundary and therefore contains a second
        // in-band VPS/SPS/PPS/IDR sequence.
        let combinedAccessUnits = Array(sample.accessUnits.prefix(61))
            + Array(rejoin.accessUnits.prefix(61))
        let fixture = Fixture(
            name: "sample-then-rejoin",
            accessUnits: combinedAccessUnits,
            sliceCount: combinedAccessUnits.count
        )
        try assertDecodesEverySlice(fixture)
    }

    func testFactoryAdvertisesH265MainProfileAndCreatesHardwareDecoder() throws {
        let factory = OverlookVideoDecoderFactory()
        let h265 = try XCTUnwrap(
            factory.supportedCodecs().first(where: {
                $0.name.caseInsensitiveCompare("H265") == .orderedSame
                    && $0.parameters["profile-id"] == "1"
            })
        )

        let decoder = try XCTUnwrap(factory.createDecoder(h265))
        XCTAssertTrue(decoder is RTCVideoDecoderH265)
        XCTAssertEqual(decoder.implementationName(), "VideoToolbox-H265-Hardware")
    }

    private func assertDecodesEverySlice(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            fixture.accessUnits.count,
            fixture.sliceCount,
            "The splitter must produce exactly one access unit per VCL NALU",
            file: file,
            line: line
        )

        let callbackExpectation = expectation(
            description: "Decode every slice in \(fixture.name)"
        )
        callbackExpectation.expectedFulfillmentCount = fixture.sliceCount
        callbackExpectation.assertForOverFulfill = true

        let lock = NSLock()
        var dimensions: [(Int32, Int32)] = []
        var framesWithoutH265Provenance = 0
        let decoder = RTCVideoDecoderH265()
        decoder.setCallback { frame in
            lock.lock()
            dimensions.append((Int32(frame.width), Int32(frame.height)))
            if !(frame.buffer is OverlookH265PixelBuffer) {
                framesWithoutH265Provenance += 1
            }
            lock.unlock()
            callbackExpectation.fulfill()
        }
        XCTAssertEqual(
            decoder.startDecode(withNumberOfCores: Int32(ProcessInfo.processInfo.processorCount)),
            0,
            file: file,
            line: line
        )

        var decodeErrors: [(Int, Int)] = []
        for (index, accessUnit) in fixture.accessUnits.enumerated() {
            autoreleasepool {
                let image = RTCEncodedImage()
                image.buffer = accessUnit
                image.timeStamp = UInt32(index * 1_500)
                let result = decoder.decode(
                    image,
                    missingFrames: false,
                    codecSpecificInfo: nil,
                    renderTimeMs: Int64(index * 1_000 / 60)
                )
                if result != 0 {
                    decodeErrors.append((index, result))
                }
            }
        }

        // releaseDecoder drains asynchronous VideoToolbox work and the VPS-sized
        // reorder queue before clearing the callback.
        XCTAssertEqual(OverlookReleaseDecoder(decoder), 0, file: file, line: line)
        wait(for: [callbackExpectation], timeout: 60)

        lock.lock()
        let decodedDimensions = dimensions
        lock.unlock()
        XCTAssertTrue(decodeErrors.isEmpty, "Decode errors: \(decodeErrors)", file: file, line: line)
        XCTAssertEqual(decodedDimensions.count, fixture.sliceCount, file: file, line: line)
        lock.lock()
        let untagged = framesWithoutH265Provenance
        lock.unlock()
        XCTAssertEqual(
            untagged,
            0,
            "Every decoded frame must carry H.265 provenance (OverlookH265PixelBuffer) — the "
                + "codec-fallback admission guard depends on it",
            file: file,
            line: line
        )
        XCTAssertTrue(
            decodedDimensions.allSatisfy { $0 == (2560, 1440) },
            "Unexpected output dimensions: \(Set(decodedDimensions.map { "\($0.0)x\($0.1)" }))",
            file: file,
            line: line
        )
        print("H265 fixture \(fixture.name): decoded \(decodedDimensions.count)/\(fixture.sliceCount) frames at 2560x1440")
    }

    private func loadFixture(named name: String) throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "bin")
        )
        let data = try Data(contentsOf: url)
        let nalus = splitNalus(data)
        let sliceCount = nalus.filter { $0.type <= 31 }.count

        var pendingPrefix = Data()
        var accessUnits: [Data] = []
        for nalu in nalus {
            if nalu.type <= 31 {
                var accessUnit = pendingPrefix
                accessUnit.append(nalu.bytesWithStartCode)
                accessUnits.append(accessUnit)
                pendingPrefix.removeAll(keepingCapacity: true)
            } else {
                pendingPrefix.append(nalu.bytesWithStartCode)
            }
        }
        return Fixture(name: name, accessUnits: accessUnits, sliceCount: sliceCount)
    }

    /// Test-side source of truth, deliberately independent of H265NaluParser.
    private func splitNalus(_ data: Data) -> [Nalu] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count
                && bytes[index] == 0 && bytes[index + 1] == 0
                && bytes[index + 2] == 0 && bytes[index + 3] == 1
            {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }

        return starts.enumerated().compactMap { item in
            let (naluIndex, start) = item
            let payloadStart = start.offset + start.length
            guard payloadStart < bytes.count else { return nil }
            let end = naluIndex + 1 < starts.count ? starts[naluIndex + 1].offset : bytes.count
            return Nalu(
                bytesWithStartCode: data.subdata(in: start.offset..<end),
                type: (bytes[payloadStart] >> 1) & 0x3f
            )
        }
    }
}
