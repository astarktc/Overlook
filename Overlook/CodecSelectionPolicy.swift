/// The operator's client-side Codec Preference for a device.
public enum CodecPreference: Equatable, Sendable {
  case auto
  case h265
  case h264
}

/// The device-side Video Format sent in a video Watch Request.
public enum VideoFormat: Int, Equatable, Sendable {
  case h264 = 0
  case h265 = 1
}

/// The Negotiated Codec displayed for the active stream.
///
/// `h264Fallback` preserves the visible Fallback provenance required by the status surface.
public enum NegotiatedCodec: Equatable, Sendable {
  case h265
  case h264
  case h264Fallback
}

/// Session-scoped memory of an H.264 Fallback.
public enum FallbackMemory: Equatable, Sendable {
  case none
  case h264
}

/// The operator action that produced an Operator-Initiated Connect.
public enum OperatorInitiatedConnect: CaseIterable, Equatable, Sendable {
  case deviceSelection
  case manualReconnect
  case codecPreferenceChange
}

/// Whether a connection is an Operator-Initiated Connect or an Automatic Reconnect.
public enum ConnectionKind: Equatable, Sendable {
  case operatorInitiatedConnect(OperatorInitiatedConnect)
  case automaticReconnect
}

/// The codec capability needed from the remote offer.
public struct OfferContents: Equatable, Sendable {
  public let includesH265: Bool

  public init(includesH265: Bool) {
    self.includesH265 = includesH265
  }
}

/// An event emitted by the first-frame watchdog owner.
public enum WatchdogEvent: Equatable, Sendable {
  case firstDecodedFrameArrived
  case watchdogFired
}

/// A pure codec-selection transition result.
public struct CodecSelectionState: Equatable, Sendable {
  /// The Video Format for the next video Watch Request.
  public let videoFormatForWatchRequest: VideoFormat

  /// The Negotiated Codec, once the offer or watchdog establishes an outcome.
  public let negotiatedCodec: NegotiatedCodec?

  /// Session-scoped Fallback memory to retain for a later Automatic Reconnect.
  public let fallbackMemory: FallbackMemory

  fileprivate let h264NegotiatedCodec: NegotiatedCodec
}

/// Pure, side-effect-free policy for Watch Request codec selection and Fallback transitions.
public enum CodecSelectionPolicy {
  /// Starts a connection and selects the Video Format for its first video Watch Request.
  ///
  /// An Operator-Initiated Connect always clears Fallback memory. An Automatic Reconnect
  /// consults remembered Fallback only for Auto or H.265 Codec Preferences.
  public static func connect(
    codecPreference: CodecPreference,
    connectionKind: ConnectionKind,
    fallbackMemory: FallbackMemory
  ) -> CodecSelectionState {
    let memoryAfterConnectionStarts: FallbackMemory
    switch connectionKind {
    case .operatorInitiatedConnect:
      memoryAfterConnectionStarts = .none
    case .automaticReconnect:
      memoryAfterConnectionStarts = fallbackMemory
    }

    switch codecPreference {
    case .h264:
      return CodecSelectionState(
        videoFormatForWatchRequest: .h264,
        negotiatedCodec: nil,
        fallbackMemory: .none,
        h264NegotiatedCodec: .h264
      )

    case .auto, .h265:
      if connectionKind == .automaticReconnect, memoryAfterConnectionStarts == .h264 {
        return CodecSelectionState(
          videoFormatForWatchRequest: .h264,
          negotiatedCodec: nil,
          fallbackMemory: .h264,
          h264NegotiatedCodec: .h264Fallback
        )
      }

      return CodecSelectionState(
        videoFormatForWatchRequest: .h265,
        negotiatedCodec: nil,
        fallbackMemory: memoryAfterConnectionStarts,
        h264NegotiatedCodec: .h264Fallback
      )
    }
  }

  /// Applies the remote offer and returns the next pure policy state.
  ///
  /// A Watch Request already selecting H.264 is natively negotiated for an explicit H.264
  /// Codec Preference, or retains Fallback provenance when selected from remembered memory.
  public static func handleOffer(
    _ offerContents: OfferContents,
    state: CodecSelectionState
  ) -> CodecSelectionState {
    guard state.videoFormatForWatchRequest == .h265 else {
      return CodecSelectionState(
        videoFormatForWatchRequest: .h264,
        negotiatedCodec: state.h264NegotiatedCodec,
        fallbackMemory: state.fallbackMemory,
        h264NegotiatedCodec: state.h264NegotiatedCodec
      )
    }

    guard offerContents.includesH265 else {
      return fallbackState()
    }

    return CodecSelectionState(
      videoFormatForWatchRequest: .h265,
      negotiatedCodec: .h265,
      fallbackMemory: state.fallbackMemory,
      h264NegotiatedCodec: .h264Fallback
    )
  }

  /// Applies a first-frame watchdog event and returns the next pure policy state.
  public static func handleWatchdog(
    _ watchdogEvent: WatchdogEvent,
    state: CodecSelectionState
  ) -> CodecSelectionState {
    guard state.videoFormatForWatchRequest == .h265 else {
      return state
    }

    switch watchdogEvent {
    case .firstDecodedFrameArrived:
      return CodecSelectionState(
        videoFormatForWatchRequest: .h265,
        negotiatedCodec: .h265,
        fallbackMemory: state.fallbackMemory,
        h264NegotiatedCodec: .h264Fallback
      )
    case .watchdogFired:
      return fallbackState()
    }
  }

  private static func fallbackState() -> CodecSelectionState {
    CodecSelectionState(
      videoFormatForWatchRequest: .h264,
      negotiatedCodec: .h264Fallback,
      fallbackMemory: .h264,
      h264NegotiatedCodec: .h264Fallback
    )
  }
}
