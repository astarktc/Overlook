import XCTest

final class SDPOfferParserTests: XCTestCase {
  func testFindsH265RtpmapInVideoMediaSection() {
    let sdp = """
      v=0\r
      o=- 4611731400430051336 2 IN IP4 127.0.0.1\r
      s=-\r
      t=0 0\r
      m=audio 9 UDP/TLS/RTP/SAVPF 111\r
      a=rtpmap:111 opus/48000/2\r
      m=video 9 UDP/TLS/RTP/SAVPF 96 98\r
      a=rtpmap:96 H265/90000\r
      a=fmtp:96 profile-id=1\r
      a=rtpmap:98 H264/90000\r
      """

    XCTAssertEqual(SDPOfferParser.parse(sdp), OfferContents(includesH265: true))
  }

  func testReportsH265AbsentFromH264OnlyVideoOffer() {
    let sdp = """
      v=0
      m=video 9 UDP/TLS/RTP/SAVPF 96 97
      a=rtpmap:96 H264/90000
      a=rtpmap:97 rtx/90000
      a=fmtp:97 apt=96;note=H265-is-not-an-rtpmap
      """

    XCTAssertEqual(SDPOfferParser.parse(sdp), OfferContents(includesH265: false))
  }

  func testHandlesCaseVariationsAndIgnoresAudioRtpmap() {
    let mixedCaseVideoSDP = """
      v=0
      m=VIDEO 9 UDP/TLS/RTP/SAVPF 96
      A=RTPMAP:96 h265/90000
      """
    let audioOnlyH265SDP = """
      v=0
      m=audio 9 UDP/TLS/RTP/SAVPF 96
      a=rtpmap:96 H265/90000
      m=video 9 UDP/TLS/RTP/SAVPF 98
      a=rtpmap:98 H264/90000
      """

    XCTAssertEqual(
      SDPOfferParser.parse(mixedCaseVideoSDP), OfferContents(includesH265: true))
    XCTAssertEqual(SDPOfferParser.parse(audioOnlyH265SDP), OfferContents(includesH265: false))
  }
}
