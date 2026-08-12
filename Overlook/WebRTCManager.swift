// swiftlint:disable file_length type_body_length
import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(CoreAudio)
import CoreAudio
#endif
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
import Network
import Combine

struct InputEvent: Codable {
    let type: String
    let data: [String: JSONValue]
    
    enum CodingKeys: String, CodingKey {
        case type
        case data
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(data, forKey: .data)
    }
    
    init(type: String, data: [String: JSONValue]) {
        self.type = type
        self.data = data
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        data = try container.decode([String: JSONValue].self, forKey: .data)
    }
}

#if canImport(WebRTC)
@MainActor
class WebRTCManager: NSObject, ObservableObject {
    private final class SessionDelegate: NSObject, URLSessionDelegate {
        let allowInsecureTLS: Bool

        init(allowInsecureTLS: Bool) {
            self.allowInsecureTLS = allowInsecureTLS
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard allowInsecureTLS,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    @Published var videoView: RTCMTLNSVideoView?
    @Published var isConnected = false
    @Published var latency: Int = 0
    @Published var currentFrame: CVPixelBuffer?
    @Published var videoSize: CGSize?
    @Published var inboundVideoKbps: Int?
    @Published var inboundFps: Double?
    @Published var inboundVideoPlayoutDelayMs: Int?
    @Published var inboundVideoJitterMs: Int?
    @Published var inboundVideoDecodeMs: Int?
    @Published var inboundVideoPacketsLost: Int?
    @Published var iceCurrentRoundTripTimeMs: Int?
    @Published var inboundAudioKbps: Int?
    @Published var inboundAudioPlayoutDelayMs: Int?
    @Published var inboundAudioJitterMs: Int?
    @Published var inboundAudioPacketsLost: Int?
    @Published var audioIceCurrentRoundTripTimeMs: Int?
    @Published var audioEnabled = false
    @Published var micEnabled = false
    @Published var preferLowLatencyPlayout = true
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var lastVideoFrameAgeSeconds: Int?
    @Published var negotiatedCodec: NegotiatedCodec?
    
    private var peerConnection: RTCPeerConnection?
    private var audioPeerConnection: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var localAudioSender: RTCRtpSender?
    private var dataChannel: RTCDataChannel?
    private var factory: RTCPeerConnectionFactory?
    private var customAudioDevice: WebRTCAudioDevice?
    private var connectionTimer: Timer?
    private var latencyMeasurementStart: Date?

    private var lastConnectedDevice: KVMDevice?
    private var shouldMaintainConnection = false
    private var codecSelectionState: CodecSelectionState?
    private var fallbackMemory: FallbackMemory = .none
    private var suppressFrameArrivalSignalsForWatchdogTesting = false
    private let codecPreferenceStore = CodecPreferenceStore()

    private let audioDevicesListenerQueue = DispatchQueue(label: "com.overlook.audio-device-change")
    private var audioDevicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var audioDeviceChangeDebounceTask: Task<Void, Never>?
    private var isAutoReconnectInProgress: Bool = false
    private var lastAutoReconnectAt: Date?

    private var iceAutomaticReconnectTask: Task<Void, Never>?
    private var iceAutomaticReconnectGeneration = 0
    private var iceAutomaticReconnectAttempts = 0
    private let iceAutomaticReconnectRetryLimit = 3
    private let iceDisconnectedGracePeriodNanoseconds: UInt64 = 2_000_000_000
    private let iceAutomaticReconnectBackoffNanoseconds: [UInt64] = [
        500_000_000,
        1_000_000_000,
        2_000_000_000,
    ]

    private var lastInboundVideoBytesReceived: Int64?
    private var lastInboundVideoBytesTimestamp: TimeInterval?

    private var lastInboundAudioBytesReceived: Int64?
    private var lastInboundAudioBytesTimestamp: TimeInterval?

    private var lastJitterBufferDelaySeconds: Double?
    private var lastJitterBufferEmittedCount: Double?

    private var lastAudioJitterBufferDelaySeconds: Double?
    private var lastAudioJitterBufferEmittedCount: Double?

    private var lastPlayoutHintApplyTime: TimeInterval?

    private let audioInputDeviceUIDDefaultsKey = "overlook.audio.inputDeviceUID"
    private let audioOutputDeviceUIDDefaultsKey = "overlook.audio.outputDeviceUID"

    private var fpsWindowStartTime: CFTimeInterval = 0
    private var fpsFrameCount: Int = 0
    private var lastFpsPublishTime: CFTimeInterval = 0

    private let streamHealthQueue = DispatchQueue(label: "com.overlook.stream-health")
    private var lastVideoFrameTime: CFTimeInterval?
    private var connectedIceTime: CFTimeInterval?
    private var streamHealthTimer: Timer?

    private let streamStallThresholdSeconds: CFTimeInterval = 3.0
    // Five seconds matches the existing initial-frame health threshold: long enough for ICE and
    // hardware decoder startup, while keeping a decode-starved black screen bounded.
    private let initialFrameTimeoutSeconds: CFTimeInterval = 5.0

#if DEBUG
    // Launch with OVERLOOK_FORCE_DECODE_STARVATION=1 to suppress the first-frame signals only
    // while the policy has armed the H.265 watchdog. Fallback frames are observed normally.
    private let forceDecodeStarvationForWatchdogTesting =
        ProcessInfo.processInfo.environment["OVERLOOK_FORCE_DECODE_STARVATION"] == "1"
#else
    private let forceDecodeStarvationForWatchdogTesting = false
#endif
    
    private let allowInsecureTLS = true
    private var signalingSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?

    private var janusSessionId: Int?
    private var janusHandleId: Int?
    private var janusAudioHandleId: Int?
    private var janusKeepAliveTimer: Timer?
    private var janusWaiters: [String: CheckedContinuation<[String: Any], Error>] = [:]

    private var isFrameCaptureEnabled: Bool = false
    private var lastFrameCaptureTime: CFTimeInterval = 0
    
    override init() {
        super.init()
        setupWebRTC()
        startAudioDeviceChangeMonitoring()
    }

    deinit {
        if let block = audioDevicesListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioDevicesListenerQueue,
                block
            )
        }

        audioDevicesListenerBlock = nil
        shouldMaintainConnection = false
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
        iceAutomaticReconnectTask?.cancel()
        iceAutomaticReconnectTask = nil
    }

    private func setLastVideoFrameTime(_ time: CFTimeInterval?) {
        streamHealthQueue.sync {
            lastVideoFrameTime = time
        }
    }

    private func recordVideoFrame(at time: CFTimeInterval) -> Bool {
        streamHealthQueue.sync {
            let isFirstDecodedFrame = lastVideoFrameTime == nil
            lastVideoFrameTime = time
            return isFirstDecodedFrame
        }
    }

    private func getLastVideoFrameTime() -> CFTimeInterval? {
        streamHealthQueue.sync {
            lastVideoFrameTime
        }
    }
    
    private func setupWebRTC() {
        let inputUID = (UserDefaults.standard.string(forKey: audioInputDeviceUIDDefaultsKey) ?? "")
        let outputUID = (UserDefaults.standard.string(forKey: audioOutputDeviceUIDDefaultsKey) ?? "")
        let useCustomAudioDevice = !(inputUID.isEmpty && outputUID.isEmpty)

        let audioDevice: WebRTCAudioDevice? = useCustomAudioDevice
            ? WebRTCAudioDevice(inputDeviceUID: inputUID, outputDeviceUID: outputUID)
            : nil
        customAudioDevice = audioDevice

        factory = WebRTCFactoryBuilder.makeFactory(with: audioDevice)

        if videoView == nil {
            videoView = RTCMTLNSVideoView(frame: .zero)
        }
    }

    private func startAudioDeviceChangeMonitoring() {
        guard audioDevicesListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleAudioDevicesChanged()
            }
        }

        audioDevicesListenerBlock = block
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            audioDevicesListenerQueue,
            block
        )
    }

    private func stopAudioDeviceChangeMonitoring() {
        guard let block = audioDevicesListenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            audioDevicesListenerQueue,
            block
        )

        audioDevicesListenerBlock = nil
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
    }

    private func shouldAutoReconnectForMissingSelectedDevices() -> Bool {
        guard shouldMaintainConnection else { return false }
        guard peerConnection != nil else { return false }

        let inputUID = (UserDefaults.standard.string(forKey: audioInputDeviceUIDDefaultsKey) ?? "")
        let outputUID = (UserDefaults.standard.string(forKey: audioOutputDeviceUIDDefaultsKey) ?? "")

        let selectedInputMissing = !inputUID.isEmpty && CoreAudioDevices.deviceID(forUID: inputUID) == nil
        let selectedOutputMissing = !outputUID.isEmpty && CoreAudioDevices.deviceID(forUID: outputUID) == nil

        let inputRelevant = micEnabled
        let outputRelevant = audioEnabled

        if selectedInputMissing && inputRelevant { return true }
        if selectedOutputMissing && outputRelevant { return true }
        return false
    }

    private func handleAudioDevicesChanged() {
        guard shouldAutoReconnectForMissingSelectedDevices() else { return }
        guard peerConnection != nil else { return }
        guard lastConnectedDevice != nil else { return }

        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            await MainActor.run {
                self?.autoReconnectIfStillNeeded()
            }
        }
    }

    private func autoReconnectIfStillNeeded() {
        guard shouldMaintainConnection else { return }
        guard isAutoReconnectInProgress == false else { return }
        guard iceAutomaticReconnectTask == nil else { return }
        guard let device = lastConnectedDevice else { return }
        guard shouldAutoReconnectForMissingSelectedDevices() else { return }

        let now = Date()
        if let last = lastAutoReconnectAt, now.timeIntervalSince(last) < 3.0 {
            return
        }
        lastAutoReconnectAt = now

        isAutoReconnectInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAutoReconnectInProgress = false }
            await self.reconnect(
                to: device,
                codecPreference: self.codecPreferenceStore.preference(forDeviceID: device.id),
                connectionKind: .automaticReconnect
            )
            if self.shouldMaintainConnection == false {
                self.tearDownConnection()
            }
        }
    }
    
    private func cancelPendingICEAutomaticReconnect() {
        iceAutomaticReconnectGeneration &+= 1
        iceAutomaticReconnectTask?.cancel()
        iceAutomaticReconnectTask = nil
    }

    private func beginOperatorInitiatedConnect(to device: KVMDevice) {
        cancelPendingICEAutomaticReconnect()
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
        iceAutomaticReconnectAttempts = 0
        lastAutoReconnectAt = nil
        lastConnectedDevice = device
        shouldMaintainConnection = true
    }

    private func scheduleICEAutomaticReconnect(afterNanoseconds delay: UInt64) {
        guard shouldMaintainConnection else { return }
        guard iceAutomaticReconnectAttempts < iceAutomaticReconnectRetryLimit else { return }
        guard iceAutomaticReconnectTask == nil else { return }
        guard let device = lastConnectedDevice else { return }

        iceAutomaticReconnectGeneration &+= 1
        let generation = iceAutomaticReconnectGeneration
        iceAutomaticReconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, self.iceAutomaticReconnectGeneration == generation else { return }
            await self.performICEAutomaticReconnect(to: device, generation: generation)
        }
    }

    private func scheduleICEAutomaticReconnectAfterFailure() {
        let backoffIndex = min(
            iceAutomaticReconnectAttempts,
            iceAutomaticReconnectBackoffNanoseconds.count - 1
        )
        scheduleICEAutomaticReconnect(
            afterNanoseconds: iceAutomaticReconnectBackoffNanoseconds[backoffIndex]
        )
    }

    private func performICEAutomaticReconnect(to device: KVMDevice, generation: Int) async {
        guard iceAutomaticReconnectGeneration == generation else { return }
        guard shouldMaintainConnection, lastConnectedDevice?.id == device.id else { return }
        guard iceAutomaticReconnectAttempts < iceAutomaticReconnectRetryLimit else { return }
        if isAutoReconnectInProgress {
            iceAutomaticReconnectTask = nil
            scheduleICEAutomaticReconnect(
                afterNanoseconds: iceAutomaticReconnectBackoffNanoseconds[0]
            )
            return
        }

        iceAutomaticReconnectAttempts += 1
        isAutoReconnectInProgress = true
        let didStart = await reconnect(
            to: device,
            codecPreference: codecPreferenceStore.preference(forDeviceID: device.id),
            connectionKind: .automaticReconnect
        )
        isAutoReconnectInProgress = false

        if shouldMaintainConnection == false {
            tearDownConnection()
            return
        }
        guard iceAutomaticReconnectGeneration == generation else { return }
        iceAutomaticReconnectTask = nil
        guard shouldMaintainConnection, lastConnectedDevice?.id == device.id else { return }
        if didStart == false {
            scheduleICEAutomaticReconnectAfterFailure()
        }
    }

    func codecPreference(for device: KVMDevice) -> CodecPreference {
        codecPreferenceStore.preference(forDeviceID: device.id)
    }

    func setCodecPreference(_ codecPreference: CodecPreference, for device: KVMDevice) async {
        codecPreferenceStore.save(codecPreference, forDeviceID: device.id)
        guard shouldMaintainConnection, lastConnectedDevice?.id == device.id else { return }
        beginOperatorInitiatedConnect(to: device)
        await reconnect(
            to: device,
            codecPreference: codecPreferenceStore.preference(forDeviceID: device.id),
            connectionKind: .operatorInitiatedConnect(.codecPreferenceChange)
        )
    }

    func connect(to device: KVMDevice) async throws {
        beginOperatorInitiatedConnect(to: device)
        try await connect(
            to: device,
            codecPreference: codecPreferenceStore.preference(forDeviceID: device.id),
            connectionKind: .operatorInitiatedConnect(.deviceSelection)
        )
    }

    private func connect(
        to device: KVMDevice,
        codecPreference: CodecPreference,
        connectionKind: ConnectionKind
    ) async throws {
        let initialCodecSelectionState = CodecSelectionPolicy.connect(
            codecPreference: codecPreference,
            connectionKind: connectionKind,
            fallbackMemory: fallbackMemory
        )
        applyCodecSelectionState(initialCodecSelectionState)

        lastConnectedDevice = device
        setupWebRTC()

        guard let factory = factory else {
            throw WebRTCError.factoryNotInitialized
        }

        isConnecting = true
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        setLastVideoFrameTime(nil)
        connectedIceTime = nil
        hasEverConnectedToStream = false

        do {
            if videoView == nil {
                videoView = RTCMTLNSVideoView(frame: .zero)
            }
            
            // Create peer connection
            let configuration = RTCConfiguration()
            configuration.iceServers = [
                RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
            ]
            configuration.sdpSemantics = .unifiedPlan
            
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: ["OfferToReceiveVideo": "true"]
            )
            
            peerConnection = factory.peerConnection(
                with: configuration,
                constraints: constraints,
                delegate: self
            )

            if audioEnabled || micEnabled {
                let audioConstraints = RTCMediaConstraints(
                    mandatoryConstraints: nil,
                    optionalConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"]
                )
                audioPeerConnection = factory.peerConnection(
                    with: configuration,
                    constraints: audioConstraints,
                    delegate: self
                )
            }

            if micEnabled {
                let granted = await ensureMicrophoneAccess()
                if granted {
                    setupLocalMicrophoneTrackIfNeeded(factory: factory, peerConnection: audioPeerConnection ?? peerConnection)
                }
            }
            
            // Setup data channel for input events
            setupDataChannel()
            
            // Connect to signaling server
            try await connectToSignalingServer(
                device: device,
                videoFormat: initialCodecSelectionState.videoFormatForWatchRequest
            )
            
            // Start connection quality monitoring
            startLatencyMonitoring()
            startStreamHealthMonitoring()
        } catch {
            let reason = "Connect failed: \(String(describing: error))"
            tearDownConnection()
            lastDisconnectReason = reason
            throw error
        }
    }

    func reconnect(to device: KVMDevice) async {
        beginOperatorInitiatedConnect(to: device)
        await reconnect(
            to: device,
            codecPreference: codecPreferenceStore.preference(forDeviceID: device.id),
            connectionKind: .operatorInitiatedConnect(.manualReconnect)
        )
    }

    @discardableResult
    private func reconnect(
        to device: KVMDevice,
        codecPreference: CodecPreference,
        connectionKind: ConnectionKind
    ) async -> Bool {
        guard shouldMaintainConnection else { return false }
        tearDownConnection()
        do {
            try await connect(
                to: device,
                codecPreference: codecPreference,
                connectionKind: connectionKind
            )
            return true
        } catch {
            isConnecting = false
            lastDisconnectReason = "Reconnect failed: \(String(describing: error))"
            return false
        }
    }

    func setFrameCaptureEnabled(_ enabled: Bool) {
        isFrameCaptureEnabled = enabled

        if enabled == false {
            currentFrame = nil
        }
    }
    
    private func applyCodecSelectionState(_ state: CodecSelectionState) {
        codecSelectionState = state
        fallbackMemory = state.fallbackMemory
        negotiatedCodec = state.negotiatedCodec
        suppressFrameArrivalSignalsForWatchdogTesting =
            forceDecodeStarvationForWatchdogTesting && state.isFirstFrameWatchdogArmed
    }

    /// Publishes a policy transition and executes its one-shot command, if any.
    /// Returns true when the current offer/event was superseded by a new Watch Request.
    private func applyAndActOnCodecSelectionState(_ state: CodecSelectionState) async -> Bool {
        applyCodecSelectionState(state)

        guard let action = state.action else { return false }
        switch action {
        case .reissueVideoWatchRequest(let videoFormat):
            // Give the replacement stream its own initial-frame health window.
            setLastVideoFrameTime(nil)
            lastVideoFrameAgeSeconds = nil
            connectedIceTime = CACurrentMediaTime()
            isStreamStalled = false

            do {
                try await sendVideoWatchRequest(videoFormat: videoFormat)
            } catch {
                isConnecting = false
                lastDisconnectReason = "Fallback Watch Request failed: \(String(describing: error))"
            }
            return true
        }
    }

    private func handleFirstFrameWatchdogEvent(_ event: WatchdogEvent) async -> Bool {
        guard let codecSelectionState else { return false }
        let nextState = CodecSelectionPolicy.handleWatchdog(event, state: codecSelectionState)
        return await applyAndActOnCodecSelectionState(nextState)
    }

    private func setupDataChannel() {
        guard let peerConnection = peerConnection else { return }
        
        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = true
        dataChannelConfig.isNegotiated = false
        dataChannelConfig.channelId = 0
        
        dataChannel = peerConnection.dataChannel(
            forLabel: "input-events",
            configuration: dataChannelConfig
        )
        dataChannel?.delegate = self
    }

    func setPreferLowLatencyPlayout(_ enabled: Bool) {
        preferLowLatencyPlayout = enabled
        applyPlayoutDelayHintIfPossible()
    }

    private func applyPlayoutDelayHintIfPossible() {
        guard let peerConnection else { return }
        guard preferLowLatencyPlayout else { return }
        for receiver in peerConnection.receivers {
            guard let kind = receiver.track?.kind else { continue }
            guard kind == "video" || kind == "audio" else { continue }
            WebRTCFactoryBuilder.setPlayoutDelayHintIfSupportedFor(receiver, seconds: 0.0)
        }
    }
    
    private func connectToSignalingServer(
        device: KVMDevice,
        videoFormat: VideoFormat
    ) async throws {
        guard let rawURL = URL(string: device.webRTCURL) else {
            throw WebRTCError.invalidSignalingURL
        }

        let url = normalizedWebSocketURL(rawURL)
        print("WebRTC signaling connect: \(url.absoluteString)")

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: SessionDelegate(allowInsecureTLS: allowInsecureTLS), delegateQueue: nil)
        signalingSession = session

        var request = URLRequest(url: url)
        if !device.authToken.isEmpty {
            request.setValue("auth_token=\(device.authToken)", forHTTPHeaderField: "Cookie")
        }
        request.setValue(device.originURL, forHTTPHeaderField: "Origin")
        request.setValue("janus-protocol", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        webSocketTask = session.webSocketTask(with: request)
        
        webSocketTask?.resume()

        Task {
            await listenForSignalingMessages()
        }

        // Janus session setup
        let createTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "create",
            "transaction": createTransaction,
        ])

        let createResponse = try await waitForJanusTransaction(createTransaction)
        guard let data = createResponse["data"] as? [String: Any],
              let sessionId = data["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusSessionId = sessionId

        let attachTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "attach",
            "plugin": "janus.plugin.ustreamer",
            "opaque_id": "oid-\(UUID().uuidString)",
            "transaction": attachTransaction,
            "session_id": sessionId,
        ])

        let attachResponse = try await waitForJanusTransaction(attachTransaction)
        guard let attachData = attachResponse["data"] as? [String: Any],
              let handleId = attachData["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusHandleId = handleId

        // Video handle always requests video-only to avoid A/V sync causing video buffering.
        try await sendVideoWatchRequest(videoFormat: videoFormat)

        if (audioEnabled || micEnabled), let audioPeerConnection {
            let audioAttachTransaction = makeJanusTransaction()
            try await sendJanusMessage([
                "janus": "attach",
                "plugin": "janus.plugin.ustreamer",
                "opaque_id": "oid-audio-\(UUID().uuidString)",
                "transaction": audioAttachTransaction,
                "session_id": sessionId,
            ])

            let audioAttachResponse = try await waitForJanusTransaction(audioAttachTransaction)
            guard let audioAttachData = audioAttachResponse["data"] as? [String: Any],
                  let audioHandleId = audioAttachData["id"] as? Int else {
                throw WebRTCError.signalingConnectionLost
            }
            janusAudioHandleId = audioHandleId

            let audioWatchTransaction = makeJanusTransaction()
            try await sendJanusMessage([
                "janus": "message",
                "body": [
                    "request": "watch",
                    "params": [
                        "orientation": 0,
                        "audio": audioEnabled,
                        "video": false,
                        "mic": micEnabled,
                        "camera": false,
                    ],
                ],
                "transaction": audioWatchTransaction,
                "session_id": sessionId,
                "handle_id": audioHandleId,
            ])

            _ = audioPeerConnection
        }

        startJanusKeepAlive()
    }

    private func sendVideoWatchRequest(videoFormat: VideoFormat) async throws {
        guard let sessionId = janusSessionId,
              let handleId = janusHandleId else {
            throw WebRTCError.signalingConnectionLost
        }

        try await sendJanusMessage([
            "janus": "message",
            "body": [
                "request": "watch",
                "params": [
                    "orientation": 0,
                    "audio": false,
                    "video": true,
                    "mic": false,
                    "camera": false,
                    "video_format": videoFormat.rawValue,
                ],
            ],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ])
    }

    private func startJanusKeepAlive() {
        janusKeepAliveTimer?.invalidate()
        janusKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.sendJanusKeepAlive()
                } catch {
                    // Ignore keepalive errors, next user action will reconnect
                }
            }
        }
    }

    private func sendJanusKeepAlive() async throws {
        guard let sessionId = janusSessionId else { return }
        try await sendJanusMessage([
            "janus": "keepalive",
            "session_id": sessionId,
            "transaction": makeJanusTransaction(),
        ])
    }

    private func sendJanusTrickleCandidate(_ candidate: RTCIceCandidate, handleId: Int) async throws {
        guard let sessionId = janusSessionId else {
            return
        }

        try await sendJanusMessage([
            "janus": "trickle",
            "candidate": [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "0",
                "sdpMLineIndex": Int(candidate.sdpMLineIndex),
            ],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ])
    }

    private func sendJanusTrickleCompleted(handleId: Int) async throws {
        guard let sessionId = janusSessionId else {
            return
        }

        try await sendJanusMessage([
            "janus": "trickle",
            "candidate": ["completed": true],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ])
    }

    private func makeJanusTransaction() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func waitForJanusTransaction(_ transaction: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            janusWaiters[transaction] = continuation
        }
    }

    private func sendJanusMessage(_ message: [String: Any]) async throws {
        guard let webSocketTask = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            throw WebRTCError.signalingConnectionLost
        }
        try await webSocketTask.send(.string(text))
    }

    private func normalizedWebSocketURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        if comps.scheme == "https" {
            comps.scheme = "wss"
        } else if comps.scheme == "http" {
            comps.scheme = "ws"
        } else if comps.scheme == nil {
            comps.scheme = "wss"
        }

        return comps.url ?? url
    }
    
    private func listenForSignalingMessages() async {
        while let webSocketTask = webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                await handleSignalingMessage(message)
            } catch {
                print("WebSocket receive error: \(error)")
                isConnecting = false
                if isConnected || hasEverConnectedToStream || lastDisconnectReason == nil {
                    lastDisconnectReason = "Signaling connection lost"
                }
                break
            }
        }
    }
    
    private func handleSignalingMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let string):
            guard let data = string.data(using: .utf8),
                  let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            await handleJanusMessage(signalingMessage)
            
        case .data(let data):
            guard let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            await handleJanusMessage(signalingMessage)
            
        @unknown default:
            break
        }
    }

    private func handleJanusMessage(_ message: [String: Any]) async {
        if let transaction = message["transaction"] as? String,
           let waiter = janusWaiters.removeValue(forKey: transaction) {
            waiter.resume(returning: message)
            return
        }

        guard let janusType = message["janus"] as? String else { return }
        if janusType == "trickle" {
            guard let candidateObj = message["candidate"] as? [String: Any],
                  let candidateString = candidateObj["candidate"] as? String,
                  let videoPeerConnection = peerConnection else {
                return
            }

            let senderHandleId = message["sender"] as? Int
            let peerConnection: RTCPeerConnection
            if let senderHandleId, senderHandleId == janusAudioHandleId, let audioPeerConnection {
                peerConnection = audioPeerConnection
            } else {
                peerConnection = videoPeerConnection
            }

            if (candidateObj["completed"] as? Bool) == true {
                return
            }

            let sdpMid = candidateObj["sdpMid"] as? String
            let sdpMLineIndex: Int32
            if let idx32 = candidateObj["sdpMLineIndex"] as? Int32 {
                sdpMLineIndex = idx32
            } else if let idx = candidateObj["sdpMLineIndex"] as? Int {
                sdpMLineIndex = Int32(idx)
            } else {
                sdpMLineIndex = 0
            }
            let iceCandidate = RTCIceCandidate(sdp: candidateString, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            try? await peerConnection.add(iceCandidate)
            return
        }

        if janusType != "event" { return }

        let senderHandleId = message["sender"] as? Int
        guard let jsep = message["jsep"] as? [String: Any],
              let jsepType = jsep["type"] as? String,
              jsepType == "offer",
              let sdpString = jsep["sdp"] as? String else {
            return
        }

        await handleOfferSDP(sdpString, senderHandleId: senderHandleId)
    }
    
    private func handleOfferSDP(_ sdpString: String, senderHandleId: Int?) async {
        guard let videoHandleId = janusHandleId else { return }

        let peerConnection: RTCPeerConnection?
        let handleId: Int?
        if let senderHandleId, senderHandleId == janusAudioHandleId {
            peerConnection = audioPeerConnection
            handleId = janusAudioHandleId
        } else {
            peerConnection = self.peerConnection
            handleId = videoHandleId
        }

        guard let peerConnection, let handleId else { return }

        if peerConnection === self.peerConnection, let codecSelectionState {
            let nextState = CodecSelectionPolicy.handleOffer(
                SDPOfferParser.parse(sdpString),
                state: codecSelectionState
            )
            if await applyAndActOnCodecSelectionState(nextState) {
                // A Fallback Watch Request supersedes this offer. Its replacement offer is the
                // only one answered, which also makes the re-watch call flow terminate.
                return
            }
        }
        
        let sessionDescription = RTCSessionDescription(
            type: .offer,
            sdp: sdpString
        )
        
        do {
            try await peerConnection.setRemoteDescription(sessionDescription)
        } catch {
            print("Failed to set remote description: \(error)")
        }
        
        // Create and send answer
        await createAndSendAnswer(peerConnection: peerConnection, handleId: handleId)
    }

    private func createAndSendAnswer(peerConnection: RTCPeerConnection, handleId: Int) async {

        do {
            let sessionDescription = try await peerConnection.answer(
                for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            )
            try await peerConnection.setLocalDescription(sessionDescription)
        } catch {
            print("Failed to create/send answer: \(error)")
            return
        }
        
        // Send answer to Janus
        guard let localDescription = peerConnection.localDescription,
              let sessionId = janusSessionId else {
            return
        }

        let startTransaction = makeJanusTransaction()
        do {
            try await sendJanusMessage([
                "janus": "message",
                "body": ["request": "start"],
                "transaction": startTransaction,
                "session_id": sessionId,
                "handle_id": handleId,
                "jsep": [
                    "type": "answer",
                    "sdp": localDescription.sdp,
                ],
            ])
        } catch {
            print("Failed to send Janus answer: \(error)")
        }
    }
    
    private func startLatencyMonitoring() {
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task {
                await self.measureLatency()
                await self.measureStreamStats()
            }
        }
    }

    private func startStreamHealthMonitoring() {
        streamHealthTimer?.invalidate()
        streamHealthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let now = CACurrentMediaTime()

                if self.isConnected == false {
                    self.isStreamStalled = false
                    self.lastVideoFrameAgeSeconds = nil
                    return
                }

                let lastFrame = self.getLastVideoFrameTime()
                let age = lastFrame.map { now - $0 }

                if let age {
                    self.lastVideoFrameAgeSeconds = max(0, Int(age.rounded()))
                } else {
                    self.lastVideoFrameAgeSeconds = nil
                }

                if let age, age > self.streamStallThresholdSeconds {
                    if self.isStreamStalled == false {
                        self.isStreamStalled = true
                        self.lastDisconnectReason = "Video stream stalled"
                    }
                    return
                }

                if lastFrame == nil,
                   let connectedAt = self.connectedIceTime,
                   now - connectedAt > self.initialFrameTimeoutSeconds {
                    if await self.handleFirstFrameWatchdogEvent(.watchdogFired) {
                        return
                    }
                    if self.isStreamStalled == false {
                        self.isStreamStalled = true
                        self.lastDisconnectReason = "Video stream stalled"
                    }
                    return
                }

                if self.isStreamStalled {
                    self.isStreamStalled = false
                    self.lastDisconnectReason = nil
                }
            }
        }
    }

    // Existing stats collection is intentionally kept as one pass over the WebRTC report.
    // swiftlint:disable cyclomatic_complexity function_body_length identifier_name
    private func measureStreamStats() async {
        guard let peerConnection else {
            await MainActor.run {
                inboundVideoKbps = nil
                inboundVideoPlayoutDelayMs = nil
                inboundVideoJitterMs = nil
                inboundVideoDecodeMs = nil
                inboundVideoPacketsLost = nil
                iceCurrentRoundTripTimeMs = nil
                inboundAudioKbps = nil
                inboundAudioPlayoutDelayMs = nil
                inboundAudioJitterMs = nil
                inboundAudioPacketsLost = nil
                audioIceCurrentRoundTripTimeMs = nil
            }
            return
        }

        if preferLowLatencyPlayout {
            let now = Date().timeIntervalSince1970
            if lastPlayoutHintApplyTime == nil || (now - (lastPlayoutHintApplyTime ?? 0)) > 2.0 {
                applyPlayoutDelayHintIfPossible()
                lastPlayoutHintApplyTime = now
            }
        }

        let lastBytes = lastInboundVideoBytesReceived
        let lastTs = lastInboundVideoBytesTimestamp

        let report = await peerConnection.statistics()
        func numberValue(_ any: Any?) -> NSNumber? {
            any as? NSNumber
        }

        var bytesReceived: Int64?
        var jitterSeconds: Double?
        var jitterBufferDelaySeconds: Double?
        var jitterBufferEmittedCount: Double?
        var totalDecodeTimeSeconds: Double?
        var framesDecoded: Double?
        var packetsLost: Int?

        var currentRoundTripTimeSeconds: Double?

        for statistic in report.statistics.values {
            if statistic.type == "candidate-pair" {
                let selected = (statistic.values["selected"] as? Bool)
                    ?? (numberValue(statistic.values["selected"])?.boolValue)
                    ?? false
                guard selected else { continue }

                if let rtt = numberValue(statistic.values["currentRoundTripTime"])?.doubleValue {
                    currentRoundTripTimeSeconds = rtt
                }
                continue
            }

            guard statistic.type == "inbound-rtp" else { continue }

            if let kind = statistic.values["kind"] as? String, kind != "video" { continue }
            if let mediaType = statistic.values["mediaType"] as? String, mediaType != "video" { continue }

            if let n = numberValue(statistic.values["bytesReceived"]) {
                bytesReceived = n.int64Value
            }
            if let n = numberValue(statistic.values["jitter"]) {
                jitterSeconds = n.doubleValue
            }
            if let n = numberValue(statistic.values["jitterBufferDelay"]) {
                jitterBufferDelaySeconds = n.doubleValue
            }
            if let n = numberValue(statistic.values["jitterBufferEmittedCount"]) {
                jitterBufferEmittedCount = n.doubleValue
            }
            if let n = numberValue(statistic.values["totalDecodeTime"]) {
                totalDecodeTimeSeconds = n.doubleValue
            }
            if let n = numberValue(statistic.values["framesDecoded"]) {
                framesDecoded = n.doubleValue
            }
            if let n = numberValue(statistic.values["packetsLost"]) {
                packetsLost = n.intValue
            }

            break
        }

        let now = Date().timeIntervalSince1970

        guard let bytesReceived else {
            await MainActor.run {
                self.lastInboundVideoBytesReceived = nil
                self.lastInboundVideoBytesTimestamp = nil
                self.inboundVideoKbps = nil
                self.inboundVideoPlayoutDelayMs = nil
                self.inboundVideoJitterMs = nil
                self.inboundVideoDecodeMs = nil
                self.inboundVideoPacketsLost = nil
                self.iceCurrentRoundTripTimeMs = nil
            }
            return
        }

        var kbps: Int?
        if let lastBytes, let lastTs {
            let dt = now - lastTs
            let db = Double(bytesReceived - lastBytes)
            if dt > 0, db >= 0 {
                kbps = Int((db * 8.0 / dt) / 1000.0)
            }
        }

        let jitterMs: Int?
        if let jitterSeconds {
            jitterMs = Int((jitterSeconds * 1000.0).rounded())
        } else {
            jitterMs = nil
        }

        let playoutDelayMs: Int? = {
            guard let jitterBufferDelaySeconds,
                  let jitterBufferEmittedCount,
                  jitterBufferEmittedCount > 0 else {
                return nil
            }

            if let lastDelay = lastJitterBufferDelaySeconds,
               let lastEmitted = lastJitterBufferEmittedCount {
                let dDelay = jitterBufferDelaySeconds - lastDelay
                let dEmit = jitterBufferEmittedCount - lastEmitted
                if dDelay >= 0, dEmit > 0 {
                    return Int(((dDelay / dEmit) * 1000.0).rounded())
                }
            }

            return Int(((jitterBufferDelaySeconds / jitterBufferEmittedCount) * 1000.0).rounded())
        }()

        let decodeMs: Int?
        if let totalDecodeTimeSeconds,
           let framesDecoded,
           framesDecoded > 0 {
            decodeMs = Int(((totalDecodeTimeSeconds / framesDecoded) * 1000.0).rounded())
        } else {
            decodeMs = nil
        }

        let rttMs: Int?
        if let currentRoundTripTimeSeconds {
            rttMs = Int((currentRoundTripTimeSeconds * 1000.0).rounded())
        } else {
            rttMs = nil
        }

        await MainActor.run {
            self.lastInboundVideoBytesReceived = bytesReceived
            self.lastInboundVideoBytesTimestamp = now
            self.lastJitterBufferDelaySeconds = jitterBufferDelaySeconds
            self.lastJitterBufferEmittedCount = jitterBufferEmittedCount
            self.inboundVideoKbps = kbps
            self.inboundVideoPlayoutDelayMs = playoutDelayMs
            self.inboundVideoJitterMs = jitterMs
            self.inboundVideoDecodeMs = decodeMs
            self.inboundVideoPacketsLost = packetsLost
            self.iceCurrentRoundTripTimeMs = rttMs
        }

        guard let audioPeerConnection else {
            await MainActor.run {
                self.lastInboundAudioBytesReceived = nil
                self.lastInboundAudioBytesTimestamp = nil
                self.lastAudioJitterBufferDelaySeconds = nil
                self.lastAudioJitterBufferEmittedCount = nil
                self.inboundAudioKbps = nil
                self.inboundAudioPlayoutDelayMs = nil
                self.inboundAudioJitterMs = nil
                self.inboundAudioPacketsLost = nil
                self.audioIceCurrentRoundTripTimeMs = nil
            }
            return
        }

        let lastAudioBytes = lastInboundAudioBytesReceived
        let lastAudioTs = lastInboundAudioBytesTimestamp

        let audioReport = await audioPeerConnection.statistics()
        func audioNumberValue(_ any: Any?) -> NSNumber? {
            any as? NSNumber
        }

        var audioBytesReceived: Int64?
        var audioJitterSeconds: Double?
        var audioJitterBufferDelaySeconds: Double?
        var audioJitterBufferEmittedCount: Double?
        var audioPacketsLost: Int?
        var audioCurrentRoundTripTimeSeconds: Double?

        for statistic in audioReport.statistics.values {
            if statistic.type == "candidate-pair" {
                let selected = (statistic.values["selected"] as? Bool)
                    ?? (audioNumberValue(statistic.values["selected"])?.boolValue)
                    ?? false
                guard selected else { continue }

                if let rtt = audioNumberValue(statistic.values["currentRoundTripTime"])?.doubleValue {
                    audioCurrentRoundTripTimeSeconds = rtt
                }
                continue
            }

            guard statistic.type == "inbound-rtp" else { continue }

            if let kind = statistic.values["kind"] as? String, kind != "audio" { continue }
            if let mediaType = statistic.values["mediaType"] as? String, mediaType != "audio" { continue }

            if let n = audioNumberValue(statistic.values["bytesReceived"]) {
                audioBytesReceived = n.int64Value
            }
            if let n = audioNumberValue(statistic.values["jitter"]) {
                audioJitterSeconds = n.doubleValue
            }
            if let n = audioNumberValue(statistic.values["jitterBufferDelay"]) {
                audioJitterBufferDelaySeconds = n.doubleValue
            }
            if let n = audioNumberValue(statistic.values["jitterBufferEmittedCount"]) {
                audioJitterBufferEmittedCount = n.doubleValue
            }
            if let n = audioNumberValue(statistic.values["packetsLost"]) {
                audioPacketsLost = n.intValue
            }

            break
        }

        let audioNow = Date().timeIntervalSince1970

        guard let audioBytesReceived else {
            await MainActor.run {
                self.lastInboundAudioBytesReceived = nil
                self.lastInboundAudioBytesTimestamp = nil
                self.lastAudioJitterBufferDelaySeconds = nil
                self.lastAudioJitterBufferEmittedCount = nil
                self.inboundAudioKbps = nil
                self.inboundAudioPlayoutDelayMs = nil
                self.inboundAudioJitterMs = nil
                self.inboundAudioPacketsLost = nil
                self.audioIceCurrentRoundTripTimeMs = nil
            }
            return
        }

        var audioKbps: Int?
        if let lastAudioBytes, let lastAudioTs {
            let dt = audioNow - lastAudioTs
            let db = Double(audioBytesReceived - lastAudioBytes)
            if dt > 0, db >= 0 {
                audioKbps = Int((db * 8.0 / dt) / 1000.0)
            }
        }

        let audioJitterMs: Int?
        if let audioJitterSeconds {
            audioJitterMs = Int((audioJitterSeconds * 1000.0).rounded())
        } else {
            audioJitterMs = nil
        }

        let audioPlayoutDelayMs: Int? = {
            guard let audioJitterBufferDelaySeconds,
                  let audioJitterBufferEmittedCount,
                  audioJitterBufferEmittedCount > 0 else {
                return nil
            }

            if let lastDelay = lastAudioJitterBufferDelaySeconds,
               let lastEmitted = lastAudioJitterBufferEmittedCount {
                let dDelay = audioJitterBufferDelaySeconds - lastDelay
                let dEmit = audioJitterBufferEmittedCount - lastEmitted
                if dDelay >= 0, dEmit > 0 {
                    return Int(((dDelay / dEmit) * 1000.0).rounded())
                }
            }

            return Int(((audioJitterBufferDelaySeconds / audioJitterBufferEmittedCount) * 1000.0).rounded())
        }()

        let audioRttMs: Int?
        if let audioCurrentRoundTripTimeSeconds {
            audioRttMs = Int((audioCurrentRoundTripTimeSeconds * 1000.0).rounded())
        } else {
            audioRttMs = nil
        }

        await MainActor.run {
            self.lastInboundAudioBytesReceived = audioBytesReceived
            self.lastInboundAudioBytesTimestamp = audioNow
            self.lastAudioJitterBufferDelaySeconds = audioJitterBufferDelaySeconds
            self.lastAudioJitterBufferEmittedCount = audioJitterBufferEmittedCount
            self.inboundAudioKbps = audioKbps
            self.inboundAudioPlayoutDelayMs = audioPlayoutDelayMs
            self.inboundAudioJitterMs = audioJitterMs
            self.inboundAudioPacketsLost = audioPacketsLost
            self.audioIceCurrentRoundTripTimeMs = audioRttMs
        }
    }
    // swiftlint:enable cyclomatic_complexity function_body_length identifier_name
    
    private func measureLatency() async {
        latencyMeasurementStart = Date()
        
        // Send ping message through data channel
        let pingMessage: [String: Any] = ["type": "ping", "timestamp": Date().timeIntervalSince1970]
        
        guard let data = try? JSONSerialization.data(withJSONObject: pingMessage) else {
            return
        }
        
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        dataChannel?.sendData(buffer)
    }
    
    func sendInputEvent(_ event: InputEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let dataChannel = dataChannel,
              dataChannel.readyState == .open else {
            return
        }
        
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        dataChannel.sendData(buffer)
    }
    
    func disconnect() {
        shouldMaintainConnection = false
        lastConnectedDevice = nil
        iceAutomaticReconnectAttempts = 0
        cancelPendingICEAutomaticReconnect()
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
        isAutoReconnectInProgress = false
        tearDownConnection()
    }

    private func tearDownConnection() {
        connectionTimer?.invalidate()
        connectionTimer = nil

        streamHealthTimer?.invalidate()
        streamHealthTimer = nil

        janusKeepAliveTimer?.invalidate()
        janusKeepAliveTimer = nil
        janusSessionId = nil
        janusHandleId = nil
        janusAudioHandleId = nil
        let waiters = janusWaiters
        janusWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.resume(throwing: WebRTCError.signalingConnectionLost)
        }
        
        webSocketTask?.cancel()
        webSocketTask = nil
        
        dataChannel?.close()
        dataChannel = nil
        
        peerConnection?.close()
        peerConnection = nil

        audioPeerConnection?.close()
        audioPeerConnection = nil

        localAudioSender = nil
        localAudioTrack = nil
        
        videoView = nil
        isConnected = false
        isConnecting = false
        hasEverConnectedToStream = false
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        setLastVideoFrameTime(nil)
        connectedIceTime = nil
        latency = 0
        videoSize = nil
        negotiatedCodec = nil
        codecSelectionState = nil
        suppressFrameArrivalSignalsForWatchdogTesting = false
        isFrameCaptureEnabled = false
        inboundVideoKbps = nil
        inboundFps = nil
        inboundVideoPlayoutDelayMs = nil
        inboundVideoJitterMs = nil
        inboundVideoDecodeMs = nil
        inboundVideoPacketsLost = nil
        iceCurrentRoundTripTimeMs = nil
        inboundAudioKbps = nil
        inboundAudioPlayoutDelayMs = nil
        inboundAudioJitterMs = nil
        inboundAudioPacketsLost = nil
        audioIceCurrentRoundTripTimeMs = nil
        lastInboundVideoBytesReceived = nil
        lastInboundVideoBytesTimestamp = nil
        lastInboundAudioBytesReceived = nil
        lastInboundAudioBytesTimestamp = nil
        lastAudioJitterBufferDelaySeconds = nil
        lastAudioJitterBufferEmittedCount = nil
        fpsWindowStartTime = 0
        fpsFrameCount = 0
        lastFpsPublishTime = 0
    }

    private func ensureMicrophoneAccess() async -> Bool {
#if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
#else
        return false
#endif
    }

    private func setupLocalMicrophoneTrackIfNeeded(factory: RTCPeerConnectionFactory, peerConnection: RTCPeerConnection?) {
        guard localAudioTrack == nil else { return }
        guard let peerConnection else { return }

        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        localAudioTrack = audioTrack
        localAudioSender = peerConnection.add(audioTrack, streamIds: ["stream0"])
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: @preconcurrency RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor in
            print("Signaling state changed: \(stateChanged)")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            print("Media stream added")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor in
            print("Media stream removed")
        }
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Task { @MainActor in
            print("Should negotiate")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceConnectionState) {
        Task { @MainActor in
            // Drive UI connection state from the video peer connection only.
            // Audio may connect/disconnect independently when split into a separate PeerConnection.
            guard peerConnection === self.peerConnection else {
                print("(audio) ICE connection state changed: \(stateChanged)")
                return
            }

            isConnected = (stateChanged == .connected || stateChanged == .completed)
            if isConnected {
                cancelPendingICEAutomaticReconnect()
                isConnecting = false
                hasEverConnectedToStream = true
                connectedIceTime = CACurrentMediaTime()
                negotiatedCodec = codecSelectionState?.negotiatedCodec
                lastDisconnectReason = nil
            } else {
                if stateChanged == .disconnected {
                    negotiatedCodec = nil
                    lastDisconnectReason = "Video connection lost"
                    isConnecting = false
                    scheduleICEAutomaticReconnect(
                        afterNanoseconds: iceDisconnectedGracePeriodNanoseconds
                    )
                } else if stateChanged == .failed {
                    negotiatedCodec = nil
                    lastDisconnectReason = "Video connection failed"
                    isConnecting = false
                    cancelPendingICEAutomaticReconnect()
                    scheduleICEAutomaticReconnectAfterFailure()
                } else if stateChanged == .closed {
                    negotiatedCodec = nil
                    lastDisconnectReason = "Video connection closed"
                    isConnecting = false
                }
            }
            print("ICE connection state changed: \(stateChanged)")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceGatheringState) {
        Task { @MainActor in
            print("ICE gathering state changed: \(stateChanged)")

            if stateChanged == .complete {
                do {
                    if peerConnection === self.audioPeerConnection {
                        if let handleId = self.janusAudioHandleId {
                            try await sendJanusTrickleCompleted(handleId: handleId)
                        }
                    } else {
                        if let handleId = self.janusHandleId {
                            try await sendJanusTrickleCompleted(handleId: handleId)
                        }
                    }
                } catch {
                    // ignore
                }
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            do {
                if peerConnection === self.audioPeerConnection {
                    if let handleId = self.janusAudioHandleId {
                        try await sendJanusTrickleCandidate(candidate, handleId: handleId)
                    }
                } else {
                    if let handleId = self.janusHandleId {
                        try await sendJanusTrickleCandidate(candidate, handleId: handleId)
                    }
                }
            } catch {
                print("Failed to send Janus ICE candidate: \(error)")
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Task { @MainActor in
            print("ICE candidates removed")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in
            print("Data channel opened")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        applyPlayoutDelayHintIfPossible()
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        videoTrack = track
        if let videoView {
            track.add(videoView)
        }
        track.add(self)
    }
}

// MARK: - RTCDataChannelDelegate
extension WebRTCManager: @preconcurrency RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            print("Data channel state changed: \(dataChannel.readyState)")
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary,
              let message = try? JSONDecoder().decode(InputMessage.self, from: buffer.data) else {
            return
        }
        
        Task { @MainActor in
            await handleDataChannelMessage(message)
        }
    }
    
    private func handleDataChannelMessage(_ message: InputMessage) async {
        switch message.type {
        case "pong":
            if let startTime = latencyMeasurementStart {
                latency = Int(Date().timeIntervalSince(startTime) * 1000)
                latencyMeasurementStart = nil
            }
        case "video-frame":
            // Handle video frame metadata if needed
            break
        default:
            break
        }
    }
 }

// MARK: - RTCVideoRenderer
extension WebRTCManager: @preconcurrency RTCVideoRenderer {
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        guard suppressFrameArrivalSignalsForWatchdogTesting == false else { return }

        let now = CACurrentMediaTime()
        let isFirstDecodedFrame = recordVideoFrame(at: now)
        if isFirstDecodedFrame {
            Task { @MainActor in
                iceAutomaticReconnectAttempts = 0
                _ = await handleFirstFrameWatchdogEvent(.firstDecodedFrameArrived)
            }
        }

        if fpsWindowStartTime == 0 {
            fpsWindowStartTime = now
            lastFpsPublishTime = now
        }

        fpsFrameCount += 1

        if now - lastFpsPublishTime >= 0.5 {
            let dt = now - fpsWindowStartTime
            if dt > 0 {
                let fps = Double(fpsFrameCount) / dt
                Task { @MainActor in
                    inboundFps = fps
                }
            }
            fpsWindowStartTime = now
            fpsFrameCount = 0
            lastFpsPublishTime = now
        }

        guard isFrameCaptureEnabled else { return }

        let minInterval: CFTimeInterval = 1.0 / 12.0
        if now - lastFrameCaptureTime < minInterval {
            return
        }
        lastFrameCaptureTime = now

        if let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            let pb = cvBuffer.pixelBuffer
            Task { @MainActor in
                currentFrame = pb
            }
        }
    }
    
    func setSize(_ size: CGSize) {
        Task { @MainActor in
            if size.width > 0, size.height > 0 {
                videoSize = size
            }
        }
    }
}

// MARK: - Supporting Types
enum WebRTCError: Error {
    case factoryNotInitialized
    case invalidSignalingURL
    case signalingConnectionLost
    case peerConnectionFailed
}

struct InputMessage: Codable {
    let type: String
    let timestamp: TimeInterval?
}

#else

@MainActor
final class WebRTCManager: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var lastVideoFrameAgeSeconds: Int?
    @Published var latency: Int = 0
    @Published var currentFrame: CVPixelBuffer?
    @Published var audioEnabled = false
    @Published var micEnabled = false
    
    func connect(to device: KVMDevice) async throws {
        isConnected = false
    }

    func reconnect(to device: KVMDevice) async {
        disconnect()
    }
    
    func sendInputEvent(_ event: InputEvent) {
    }
    
    func disconnect() {
        isConnected = false
        isConnecting = false
        hasEverConnectedToStream = false
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        latency = 0
        currentFrame = nil
    }
}

#endif
