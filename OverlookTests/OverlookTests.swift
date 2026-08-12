import CryptoKit
import Foundation
import XCTest

final class OverlookTests: XCTestCase {
    func testSmoke() {
        XCTAssertTrue(true)
    }

    func testCometH265FixturesLoadWithExpectedHashes() throws {
        let fixtures = [
            (
                name: "lab28-h265-sample",
                expectedSHA256: "0d1897aa7ee6f566fb4b7c035f9de9f8eb5158f8b932f45007a6ea169f8c2664"
            ),
            (
                name: "lab28-h265-rejoin",
                expectedSHA256: "03cd6d6cbcda3bd7323842bf74f1db7e299d8a9882dbe3f6f6c7ff0ab662c2e5"
            ),
        ]

        for fixture in fixtures {
            let url = try XCTUnwrap(
                Bundle(for: Self.self).url(forResource: fixture.name, withExtension: "bin"),
                "Missing bundled fixture: \(fixture.name).bin"
            )
            let data = try Data(contentsOf: url)
            let actualSHA256 = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(
                actualSHA256,
                fixture.expectedSHA256,
                "Unexpected SHA-256 for \(fixture.name).bin"
            )
        }
    }
}
