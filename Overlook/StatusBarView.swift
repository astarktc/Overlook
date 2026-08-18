import SwiftUI

struct StatusBarView: View {
    let deviceName: String
    let isConnected: Bool
    let latency: Int
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
        // [DEBUG-swiftui-audit]
        let _ = DiagFlags.printChanges ? Self._printChanges() : ()
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

            Text("Latency: \(latency)ms")
                .font(.caption)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}
