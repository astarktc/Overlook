import Foundation

/// Extracts the video codec capability needed by `CodecSelectionPolicy` from an SDP offer.
public enum SDPOfferParser {
  public static func parse(_ sdp: String) -> OfferContents {
    var isVideoMediaSection = false

    for rawLine in sdp.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard let firstField = fields.first else { continue }

      if firstField.lowercased().hasPrefix("m=") {
        let mediaKind = firstField.dropFirst(2)
        isVideoMediaSection = String(mediaKind).caseInsensitiveCompare("video") == .orderedSame
        continue
      }

      guard isVideoMediaSection,
            fields.count >= 2,
            firstField.lowercased().hasPrefix("a=rtpmap:") else {
        continue
      }

      let encodingName = fields[1].split(separator: "/", maxSplits: 1).first ?? fields[1]
      if String(encodingName).caseInsensitiveCompare("H265") == .orderedSame {
        return OfferContents(includesH265: true)
      }
    }

    return OfferContents(includesH265: false)
  }
}
