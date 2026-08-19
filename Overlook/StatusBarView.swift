import SwiftUI

struct StatusBarView: View {
    let deviceName: String
    let isConnected: Bool
    let negotiatedCodec: NegotiatedCodec?

    private var negotiatedCodecLabel: String? {
        switch negotiatedCodec {
        case .h265:
            return "H.265"
        case .h264:
            return "H.264"
        case .h264Fallback:
            return "H.264 (fallback)"
        case nil:
            return nil
        }
    }

    var body: some View {
        HStack {
            Text(deviceName)
                .font(.caption)

            Spacer()

            Text(isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(isConnected ? .green : .red)

            if isConnected, let negotiatedCodecLabel {
                Text(negotiatedCodecLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Latency observes the telemetry model itself, so a latency tick invalidates that
            // label alone rather than this whole bar.
            ConnectionLatencyLabel()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}
