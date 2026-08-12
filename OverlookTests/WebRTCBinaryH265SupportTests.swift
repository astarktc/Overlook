import Foundation
import WebRTC
import XCTest

/// Guards against a WebRTC dependency bump silently losing native H.265 receive support.
///
/// stasel's prebuilt M151 xcframework shipped WITHOUT `rtc_use_h265` (verified 2026-08-12:
/// zero "H265" strings and no H26xPacketBuffer in any slice, while M146/M150 contain both).
/// The failure mode is nasty: SDP still negotiates H265 because the ObjC layer echoes the
/// app's decoder-factory codec list, but the native RTP pipeline has no H.265 depacketizer,
/// so packets are discarded before frame assembly, the decoder is never created, and the
/// first-frame watchdog falls the session back to H.264. This test scans the linked WebRTC
/// framework binary for the H.265 machinery so a regressed prebuilt fails CI instead of
/// failing live.
final class WebRTCBinaryH265SupportTests: XCTestCase {
    func testLinkedWebRTCBinaryContainsH265ReceiveMachinery() throws {
        let bundle = Bundle(for: RTCPeerConnectionFactory.self)
        let binaryURL = try XCTUnwrap(bundle.executableURL, "WebRTC framework executable not found")
        let data = try Data(contentsOf: binaryURL)

        func contains(_ marker: String) -> Bool {
            let needle = Data(marker.utf8)
            return data.range(of: needle) != nil
        }

        XCTAssertTrue(
            contains("H26xPacketBuffer"),
            "Linked WebRTC binary lacks H26xPacketBuffer — this prebuilt was compiled without rtc_use_h265 (like stasel M151); H.265 receive cannot work"
        )
        XCTAssertTrue(
            contains("H265"),
            "Linked WebRTC binary has no H265 references — this prebuilt was compiled without rtc_use_h265; H.265 receive cannot work"
        )
    }
}
