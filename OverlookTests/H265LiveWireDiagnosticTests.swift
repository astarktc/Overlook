import Foundation
import WebRTC
import XCTest

/// DIAGNOSTIC (env-gated, not part of the regular suite): receives live H.265
/// from the Comet's Janus through the real stasel M150 libwebrtc binary and
/// Overlook's decoder factory, bypassing everything else. The device-side RTP
/// wire shape has been independently proven correct with an out-of-band
/// GStreamer tracer (.scratch/h265-receive/tools/rtp_trace.py), so this test
/// discriminates: framesReceived > 0 ⇒ libwebrtc assembles this wire (wall is
/// elsewhere in Overlook); framesReceived == 0 with packetsReceived climbing ⇒
/// the wall is INSIDE the stasel M150 binary's H.265 frame assembly.
///
/// Preconditions (outside this test):
///   1. ssh -N -L 8080:/run/kvmd/janus-ws.sock root@100.92.27.77
///   2. H.265 encoder running on the device (/tmp/run-encoder.sh)
///   3. OVERLOOK_H265_WIRE_DIAG=1 in the environment
final class H265LiveWireDiagnosticTests: XCTestCase {

    func testLiveH265ReceiveThroughLocalJanusTunnel() throws {
        guard ProcessInfo.processInfo.environment["OVERLOOK_H265_WIRE_DIAG"] == "1" else {
            throw XCTSkip("diagnostic; set OVERLOOK_H265_WIRE_DIAG=1 with tunnel+encoder up")
        }

        let client = JanusH265DiagClient(urlString: "ws://127.0.0.1:8080/janus/ws")
        client.start()

        let offerReceived = expectation(description: "janus offer received")
        client.onOffer = { offerReceived.fulfill() }
        wait(for: [offerReceived], timeout: 15)

        // Observation window: stats are logged every second by the client.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 15))

        let stats = client.lastStats
        NSLog("[DIAG-h265] FINAL: %@", stats.description)
        client.stop()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))

        XCTAssertGreaterThan(
            stats.packetsReceived, 100,
            "H.265 RTP never flowed — check tunnel + device encoder before interpreting"
        )
        // Deliberately NO assertion on framesReceived: zero vs nonzero is the
        // diagnostic verdict, read it from the [DIAG-h265] log lines.
    }

    /// Same preconditions, but drives the REAL WebRTCManager (full live
    /// pipeline: codec policy, watch request, answer flow, watchdog).
    /// Verdict comes from the [DIAG-h265-mgr] lines below plus the manager's
    /// permanent "[Overlook] encoder format pinned" log.
    @MainActor
    func testRealWebRTCManagerAgainstLocalJanusTunnel() throws {
        guard ProcessInfo.processInfo.environment["OVERLOOK_H265_WIRE_DIAG"] == "1" else {
            throw XCTSkip("diagnostic; set OVERLOOK_H265_WIRE_DIAG=1 with tunnel+encoder up")
        }

        let device = KVMDevice(
            id: "h265-mgr-diag",
            name: "h265-mgr-diag",
            host: "127.0.0.1",
            port: 8080,
            type: .generic,
            authToken: "",
            capabilities: []
        )

        let manager = WebRTCManager()

        // Issue 10 seam: record every encoder-format pin the manager issues.
        // (No kvmd API in this environment — the tunnel is auth-free — so the
        // recorder just proves the wiring and ordering.)
        final class PinRecorder: @unchecked Sendable {
            var formats: [VideoFormat] = []
        }
        let recorder = PinRecorder()
        manager.encoderFormatPinner = { format in
            recorder.formats.append(format)
            NSLog("[DIAG-h265-mgr] encoderFormatPinner called with video_format=%d", format.rawValue)
            return true
        }

        let connectTask = Task { @MainActor in
            do {
                try await manager.connect(to: device)
                NSLog("[DIAG-h265-mgr] connect() returned normally")
            } catch {
                NSLog("[DIAG-h265-mgr] connect() threw: %@", String(describing: error))
            }
        }

        // Pump the main run loop so the manager's Timers (stats probe,
        // watchdog, keepalive) fire. The fallback watchdog acting at ~5s IS
        // diagnostic signal — it mirrors the live failure exactly.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 20))

        connectTask.cancel()
        manager.disconnect()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        NSLog("[DIAG-h265-mgr] test window complete — grep [DIAG-h265] for verdict")

        XCTAssertEqual(
            recorder.formats.first, .h265,
            "the initial watch request must pin the encoder to the negotiated format first"
        )
    }
}

/// Minimal Janus ustreamer-plugin client: create → attach → watch(H.265) →
/// answer offer → trickle. Mirrors WebRTCManager's dialect exactly.
private final class JanusH265DiagClient: NSObject {
    struct Stats: CustomStringConvertible {
        var packetsReceived = 0
        var framesReceived = 0
        var framesDecoded = 0
        var keyFramesDecoded = 0
        var pliCount = 0
        var description: String {
            "packetsReceived=\(packetsReceived) framesReceived=\(framesReceived) "
                + "framesDecoded=\(framesDecoded) keyFramesDecoded=\(keyFramesDecoded) pliCount=\(pliCount)"
        }
    }

    var onOffer: (() -> Void)?
    private(set) var lastStats = Stats()

    private let urlString: String
    private var session: URLSession!
    private var ws: URLSessionWebSocketTask?
    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var sessionId: Int?
    private var handleId: Int?
    private var statsTimer: Timer?
    private static var logCaptureStarted = false
    private static let callbackLogger = RTCCallbackLogger()

    init(urlString: String) {
        self.urlString = urlString
        super.init()
    }

    func start() {
        if !Self.logCaptureStarted {
            Self.logCaptureStarted = true
            Self.callbackLogger.severity = .warning
            Self.callbackLogger.start { message in
                NSLog("[DIAG-webrtc-native] %@", message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // Same factory shape as WebRTCFactoryBuilder.makeFactory (no custom audio).
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = OverlookVideoDecoderFactory()
        let factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        self.factory = factory

        let configuration = RTCConfiguration()
        configuration.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["OfferToReceiveVideo": "true"]
        )
        pc = factory.peerConnection(with: configuration, constraints: constraints, delegate: self)

        session = URLSession(configuration: .default)
        guard let url = URL(string: urlString) else {
            NSLog("[DIAG-h265] bad url %@", urlString)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("janus-protocol", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = session.webSocketTask(with: request)
        ws = task
        task.resume()
        receiveLoop()

        sendJanus(["janus": "create", "transaction": txn()])

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
    }

    func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
        if let sessionId {
            sendJanus(["janus": "destroy", "session_id": sessionId, "transaction": txn()])
        }
        pc?.close()
        ws?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Janus signaling

    private func txn() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func sendJanus(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        ws?.send(.string(text)) { error in
            if let error {
                NSLog("[DIAG-h265] ws send error: %@", String(describing: error))
            }
        }
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                NSLog("[DIAG-h265] ws receive error: %@", String(describing: error))
                return
            case .success(let message):
                if case .string(let text) = message, let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handleJanus(obj)
                }
            }
            self.receiveLoop()
        }
    }

    private func handleJanus(_ msg: [String: Any]) {
        let jtype = msg["janus"] as? String
        switch jtype {
        case "success":
            if let data = msg["data"] as? [String: Any], let id = data["id"] as? Int {
                if sessionId == nil {
                    sessionId = id
                    sendJanus([
                        "janus": "attach",
                        "plugin": "janus.plugin.ustreamer",
                        "opaque_id": "oid-\(UUID().uuidString)",
                        "transaction": txn(),
                        "session_id": id,
                    ])
                } else if handleId == nil {
                    handleId = id
                    NSLog("[DIAG-h265] session=%d handle=%d — sending watch video_format=1", sessionId!, id)
                    sendJanus([
                        "janus": "message",
                        "body": [
                            "request": "watch",
                            "params": [
                                "orientation": 0,
                                "audio": false,
                                "video": true,
                                "mic": false,
                                "camera": false,
                                "video_format": 1,
                            ],
                        ],
                        "transaction": txn(),
                        "session_id": sessionId!,
                        "handle_id": id,
                    ])
                }
            }
        case "event":
            if let jsep = msg["jsep"] as? [String: Any],
               jsep["type"] as? String == "offer",
               let sdp = jsep["sdp"] as? String {
                NSLog("[DIAG-h265] offer received (%d chars)", sdp.count)
                onOffer?()
                answerOffer(sdp)
            }
        case "error":
            NSLog("[DIAG-h265] janus error: %@", String(describing: msg["error"]))
        case "webrtcup", "media", "hangup":
            NSLog("[DIAG-h265] janus %@", jtype ?? "?")
        default:
            break
        }
    }

    private func answerOffer(_ sdp: String) {
        guard let pc else { return }
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        pc.setRemoteDescription(offer) { [weak self] error in
            guard let self else { return }
            if let error {
                NSLog("[DIAG-h265] setRemoteDescription failed: %@", String(describing: error))
                return
            }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { [weak self] answer, error in
                guard let self, let answer else {
                    NSLog("[DIAG-h265] answer failed: %@", String(describing: error))
                    return
                }
                pc.setLocalDescription(answer) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        NSLog("[DIAG-h265] setLocalDescription failed: %@", String(describing: error))
                        return
                    }
                    let videoSection = answer.sdp
                        .components(separatedBy: "\r\n")
                        .drop(while: { !$0.hasPrefix("m=video") })
                        .joined(separator: " | ")
                    NSLog("[DIAG-h265] answer video section: %@", videoSection)
                    self.sendJanus([
                        "janus": "message",
                        "body": ["request": "start"],
                        "transaction": self.txn(),
                        "session_id": self.sessionId ?? 0,
                        "handle_id": self.handleId ?? 0,
                        "jsep": ["type": "answer", "sdp": answer.sdp],
                    ])
                }
            }
        }
    }

    // MARK: Stats

    private func pollStats() {
        pc?.statistics { [weak self] report in
            guard let self else { return }
            var stats = Stats()
            for (_, entry) in report.statistics where entry.type == "inbound-rtp" {
                guard (entry.values["kind"] as? String) == "video" else { continue }
                stats.packetsReceived = (entry.values["packetsReceived"] as? NSNumber)?.intValue ?? 0
                stats.framesReceived = (entry.values["framesReceived"] as? NSNumber)?.intValue ?? 0
                stats.framesDecoded = (entry.values["framesDecoded"] as? NSNumber)?.intValue ?? 0
                stats.keyFramesDecoded = (entry.values["keyFramesDecoded"] as? NSNumber)?.intValue ?? 0
                stats.pliCount = (entry.values["pliCount"] as? NSNumber)?.intValue ?? 0
            }
            self.lastStats = stats
            NSLog("[DIAG-h265] inbound-rtp video: %@", stats.description)
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension JanusH265DiagClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        NSLog("[DIAG-h265] iceConnectionState=%ld", newState.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            sendJanus([
                "janus": "trickle",
                "candidate": ["completed": true],
                "transaction": txn(),
                "session_id": sessionId ?? 0,
                "handle_id": handleId ?? 0,
            ])
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        sendJanus([
            "janus": "trickle",
            "candidate": [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "0",
                "sdpMLineIndex": Int(candidate.sdpMLineIndex),
            ],
            "transaction": txn(),
            "session_id": sessionId ?? 0,
            "handle_id": handleId ?? 0,
        ])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        NSLog("[DIAG-h265] didStartReceivingOn transceiver mid=%@", transceiver.mid)
    }
}
