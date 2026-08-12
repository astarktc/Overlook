import XCTest

final class CodecSelectionPolicyTests: XCTestCase {
  private struct MatrixExpectation {
    let videoFormat: VideoFormat
    let negotiatedCodec: NegotiatedCodec
    let fallbackMemory: FallbackMemory
  }

  private struct MatrixGroup {
    let name: String
    let codecPreference: CodecPreference
    let connectionKind: ConnectionKind
    let inputFallbackMemory: FallbackMemory
    // Order: offer lacks H.265/frame arrived, offer lacks H.265/watchdog fired,
    // offer includes H.265/frame arrived, offer includes H.265/watchdog fired.
    let expectations: [MatrixExpectation]
  }

  func testCodecPreferenceConnectionKindOfferContentsAndWatchdogEventFullMatrix() throws {
    let fallback = MatrixExpectation(
      videoFormat: .h264, negotiatedCodec: .h264Fallback, fallbackMemory: .h264)
    let h265 = MatrixExpectation(videoFormat: .h265, negotiatedCodec: .h265, fallbackMemory: .none)
    let h264 = MatrixExpectation(videoFormat: .h264, negotiatedCodec: .h264, fallbackMemory: .none)

    // Every expectation below is a literal outcome from the feature specification.
    // The policy implementation is never called to derive expected values.
    let groups: [MatrixGroup] = [
      MatrixGroup(
        name: "Auto / device selection / no Fallback memory", codecPreference: .auto,
        connectionKind: .operatorInitiatedConnect(.deviceSelection), inputFallbackMemory: .none,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.265 / device selection / no Fallback memory", codecPreference: .h265,
        connectionKind: .operatorInitiatedConnect(.deviceSelection), inputFallbackMemory: .none,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.264 / device selection / no Fallback memory", codecPreference: .h264,
        connectionKind: .operatorInitiatedConnect(.deviceSelection), inputFallbackMemory: .none,
        expectations: [h264, h264, h264, h264]),
      MatrixGroup(
        name: "Auto / manual reconnect / no Fallback memory", codecPreference: .auto,
        connectionKind: .operatorInitiatedConnect(.manualReconnect), inputFallbackMemory: .none,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.265 / manual reconnect / no Fallback memory", codecPreference: .h265,
        connectionKind: .operatorInitiatedConnect(.manualReconnect), inputFallbackMemory: .none,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.264 / manual reconnect / no Fallback memory", codecPreference: .h264,
        connectionKind: .operatorInitiatedConnect(.manualReconnect), inputFallbackMemory: .none,
        expectations: [h264, h264, h264, h264]),
      MatrixGroup(
        name: "Auto / Codec Preference change / no Fallback memory", codecPreference: .auto,
        connectionKind: .operatorInitiatedConnect(.codecPreferenceChange),
        inputFallbackMemory: .none, expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.265 / Codec Preference change / no Fallback memory", codecPreference: .h265,
        connectionKind: .operatorInitiatedConnect(.codecPreferenceChange),
        inputFallbackMemory: .none, expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.264 / Codec Preference change / no Fallback memory", codecPreference: .h264,
        connectionKind: .operatorInitiatedConnect(.codecPreferenceChange),
        inputFallbackMemory: .none, expectations: [h264, h264, h264, h264]),
      MatrixGroup(
        name: "Auto / Automatic Reconnect / no Fallback memory", codecPreference: .auto,
        connectionKind: .automaticReconnect, inputFallbackMemory: .none,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.265 / Automatic Reconnect / no Fallback memory", codecPreference: .h265,
        connectionKind: .automaticReconnect, inputFallbackMemory: .none,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.264 / Automatic Reconnect / no Fallback memory", codecPreference: .h264,
        connectionKind: .automaticReconnect, inputFallbackMemory: .none,
        expectations: [h264, h264, h264, h264]),

      MatrixGroup(
        name: "Auto / device selection / remembered Fallback", codecPreference: .auto,
        connectionKind: .operatorInitiatedConnect(.deviceSelection), inputFallbackMemory: .h264,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.265 / device selection / remembered Fallback", codecPreference: .h265,
        connectionKind: .operatorInitiatedConnect(.deviceSelection), inputFallbackMemory: .h264,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.264 / device selection / remembered Fallback", codecPreference: .h264,
        connectionKind: .operatorInitiatedConnect(.deviceSelection), inputFallbackMemory: .h264,
        expectations: [h264, h264, h264, h264]),
      MatrixGroup(
        name: "Auto / manual reconnect / remembered Fallback", codecPreference: .auto,
        connectionKind: .operatorInitiatedConnect(.manualReconnect), inputFallbackMemory: .h264,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.265 / manual reconnect / remembered Fallback", codecPreference: .h265,
        connectionKind: .operatorInitiatedConnect(.manualReconnect), inputFallbackMemory: .h264,
        expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.264 / manual reconnect / remembered Fallback", codecPreference: .h264,
        connectionKind: .operatorInitiatedConnect(.manualReconnect), inputFallbackMemory: .h264,
        expectations: [h264, h264, h264, h264]),
      MatrixGroup(
        name: "Auto / Codec Preference change / remembered Fallback", codecPreference: .auto,
        connectionKind: .operatorInitiatedConnect(.codecPreferenceChange),
        inputFallbackMemory: .h264, expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.265 / Codec Preference change / remembered Fallback", codecPreference: .h265,
        connectionKind: .operatorInitiatedConnect(.codecPreferenceChange),
        inputFallbackMemory: .h264, expectations: [fallback, fallback, h265, fallback]),
      MatrixGroup(
        name: "H.264 / Codec Preference change / remembered Fallback", codecPreference: .h264,
        connectionKind: .operatorInitiatedConnect(.codecPreferenceChange),
        inputFallbackMemory: .h264, expectations: [h264, h264, h264, h264]),
      MatrixGroup(
        name: "Auto / Automatic Reconnect / remembered Fallback", codecPreference: .auto,
        connectionKind: .automaticReconnect, inputFallbackMemory: .h264,
        expectations: [fallback, fallback, fallback, fallback]),
      MatrixGroup(
        name: "H.265 / Automatic Reconnect / remembered Fallback", codecPreference: .h265,
        connectionKind: .automaticReconnect, inputFallbackMemory: .h264,
        expectations: [fallback, fallback, fallback, fallback]),
      MatrixGroup(
        name: "H.264 / Automatic Reconnect / remembered Fallback", codecPreference: .h264,
        connectionKind: .automaticReconnect, inputFallbackMemory: .h264,
        expectations: [h264, h264, h264, h264]),
    ]
    let scenarios: [(offerIncludesH265: Bool, watchdogEvent: WatchdogEvent)] = [
      (false, .firstDecodedFrameArrived),
      (false, .watchdogFired),
      (true, .firstDecodedFrameArrived),
      (true, .watchdogFired),
    ]

    XCTAssertEqual(groups.count * scenarios.count, 96)
    for group in groups {
      XCTAssertEqual(group.expectations.count, scenarios.count, group.name)
      for (index, scenario) in scenarios.enumerated() {
        var state = CodecSelectionPolicy.connect(
          codecPreference: group.codecPreference,
          connectionKind: group.connectionKind,
          fallbackMemory: group.inputFallbackMemory
        )
        state = CodecSelectionPolicy.handleOffer(
          OfferContents(includesH265: scenario.offerIncludesH265),
          state: state
        )
        state = CodecSelectionPolicy.handleWatchdog(scenario.watchdogEvent, state: state)

        let expected = group.expectations[index]
        let context =
          "\(group.name), offerIncludesH265=\(scenario.offerIncludesH265), watchdogEvent=\(scenario.watchdogEvent)"
        XCTAssertEqual(state.videoFormatForWatchRequest, expected.videoFormat, context)
        XCTAssertEqual(
          try XCTUnwrap(state.negotiatedCodec, context), expected.negotiatedCodec, context)
        XCTAssertEqual(state.fallbackMemory, expected.fallbackMemory, context)
      }
    }
  }

  func testCodecPreferenceAutoNegotiatesH265HappyPath() {
    var state = CodecSelectionPolicy.connect(
      codecPreference: .auto,
      connectionKind: .operatorInitiatedConnect(.deviceSelection),
      fallbackMemory: .none
    )
    XCTAssertEqual(state.videoFormatForWatchRequest, .h265)

    state = CodecSelectionPolicy.handleOffer(OfferContents(includesH265: true), state: state)
    state = CodecSelectionPolicy.handleWatchdog(.firstDecodedFrameArrived, state: state)

    XCTAssertEqual(state.videoFormatForWatchRequest, .h265)
    XCTAssertEqual(state.negotiatedCodec, .h265)
    XCTAssertEqual(state.fallbackMemory, .none)
  }

  func testFallbackWhenOfferLacksH265() {
    let initial = CodecSelectionPolicy.connect(
      codecPreference: .auto,
      connectionKind: .automaticReconnect,
      fallbackMemory: .none
    )
    let state = CodecSelectionPolicy.handleOffer(OfferContents(includesH265: false), state: initial)

    XCTAssertEqual(initial.videoFormatForWatchRequest, .h265)
    XCTAssertEqual(state.videoFormatForWatchRequest, .h264)
    XCTAssertEqual(state.negotiatedCodec, .h264Fallback)
    XCTAssertEqual(state.fallbackMemory, .h264)
  }

  func testFallbackWhenFirstFrameWatchdogFires() {
    var state = CodecSelectionPolicy.connect(
      codecPreference: .auto,
      connectionKind: .automaticReconnect,
      fallbackMemory: .none
    )
    state = CodecSelectionPolicy.handleOffer(OfferContents(includesH265: true), state: state)
    state = CodecSelectionPolicy.handleWatchdog(.watchdogFired, state: state)

    XCTAssertEqual(state.videoFormatForWatchRequest, .h264)
    XCTAssertEqual(state.negotiatedCodec, .h264Fallback)
    XCTAssertEqual(state.fallbackMemory, .h264)
  }

  func testAutomaticReconnectHonorsFallbackMemory() {
    let state = CodecSelectionPolicy.connect(
      codecPreference: .auto,
      connectionKind: .automaticReconnect,
      fallbackMemory: .h264
    )

    XCTAssertEqual(state.videoFormatForWatchRequest, .h264)
    XCTAssertEqual(state.fallbackMemory, .h264)
  }

  func
    testOperatorInitiatedConnectClearsFallbackMemoryForDeviceSelectionManualReconnectAndCodecPreferenceChange()
  {
    let operatorInitiatedConnects: [OperatorInitiatedConnect] = [
      .deviceSelection,
      .manualReconnect,
      .codecPreferenceChange,
    ]

    for reason in operatorInitiatedConnects {
      let state = CodecSelectionPolicy.connect(
        codecPreference: .auto,
        connectionKind: .operatorInitiatedConnect(reason),
        fallbackMemory: .h264
      )
      XCTAssertEqual(state.videoFormatForWatchRequest, .h265, "\(reason)")
      XCTAssertEqual(state.fallbackMemory, .none, "\(reason)")
    }
  }

  func testCodecPreferenceH265PinFallsBackVisibly() {
    let initial = CodecSelectionPolicy.connect(
      codecPreference: .h265,
      connectionKind: .operatorInitiatedConnect(.manualReconnect),
      fallbackMemory: .none
    )
    let state = CodecSelectionPolicy.handleOffer(OfferContents(includesH265: false), state: initial)

    XCTAssertEqual(state.videoFormatForWatchRequest, .h264)
    XCTAssertEqual(state.negotiatedCodec, .h264Fallback)
    XCTAssertEqual(state.fallbackMemory, .h264)
  }

  func testCodecPreferenceH264NeverRequestsH265AndNeverUsesFallback() {
    var state = CodecSelectionPolicy.connect(
      codecPreference: .h264,
      connectionKind: .operatorInitiatedConnect(.codecPreferenceChange),
      fallbackMemory: .h264
    )
    XCTAssertEqual(state.videoFormatForWatchRequest, .h264)
    XCTAssertEqual(state.fallbackMemory, .none)

    state = CodecSelectionPolicy.handleOffer(OfferContents(includesH265: true), state: state)
    state = CodecSelectionPolicy.handleWatchdog(.watchdogFired, state: state)

    XCTAssertEqual(state.videoFormatForWatchRequest, .h264)
    XCTAssertEqual(state.negotiatedCodec, .h264)
    XCTAssertEqual(state.fallbackMemory, .none)
  }

  func testNegotiatedCodecDistinguishesNativeH264FromFallbackH264() {
    var native = CodecSelectionPolicy.connect(
      codecPreference: .h264,
      connectionKind: .operatorInitiatedConnect(.deviceSelection),
      fallbackMemory: .none
    )
    native = CodecSelectionPolicy.handleOffer(OfferContents(includesH265: false), state: native)

    var fallback = CodecSelectionPolicy.connect(
      codecPreference: .auto,
      connectionKind: .operatorInitiatedConnect(.deviceSelection),
      fallbackMemory: .none
    )
    fallback = CodecSelectionPolicy.handleOffer(OfferContents(includesH265: false), state: fallback)

    XCTAssertEqual(native.negotiatedCodec, .h264)
    XCTAssertEqual(fallback.negotiatedCodec, .h264Fallback)
    XCTAssertNotEqual(native.negotiatedCodec, fallback.negotiatedCodec)
  }

  func testVideoFormatWireValuesMatchWatchRequestContract() {
    XCTAssertEqual(VideoFormat.h264.rawValue, 0)
    XCTAssertEqual(VideoFormat.h265.rawValue, 1)
  }
}
