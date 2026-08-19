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

    @Published var videoView: VideoRenderView?
    @Published var isConnected = false
    @Published var currentFrame: CVPixelBuffer?
    /// Guest resolution. Not telemetry: input mapping, the window aspect ratio and
    /// fit-to-guest all read it, so it stays here — equality-gated on write.
    @Published var videoSize: CGSize?
    @Published var audioEnabled = false
    @Published var micEnabled = false
    @Published var preferLowLatencyPlayout = true
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var lastVideoFrameAgeSeconds: Int?
    @Published var negotiatedCodec: NegotiatedCodec?

    /// The periodic video/audio statistics. Deliberately a plain `let`, not `@Published`:
    /// telemetry changes must not invalidate anything observing the manager itself, only the
    /// views that render stats.
    let telemetry = StreamTelemetryModel()

    private var peerConnection: RTCPeerConnection?
    private var audioPeerConnection: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var connectionGeneration = 0
    /// The connection state the (off-main) render path reads for every decoded frame: the current
    /// generation, the OCR capture gate, the watchdog-suppression flag, and the stream-health
    /// frame clock. Written here on the main actor, read on the decode thread under one unfair
    /// lock — which is what let the per-frame main-actor hop go away.
    private let renderControl = VideoRenderControl()
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

    /// What the UI asked for (OCR mode on/off). Survives teardown, so an automatic reconnect
    /// restores capture without needing SwiftUI to re-fire an `onChange`.
    private var isOCRCaptureDesired: Bool = false
    /// What the render path is currently allowed to do: the desire *and* a live rendering track.
    private var isFrameCaptureEnabled: Bool = false
    /// True between `startRenderingVideo` and `stopRenderingVideo`.
    private var isRenderingVideo: Bool = false
    
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

    /// The stream-health frame clock lives in `renderControl`: the decode thread stamps it as
    /// part of admitting a frame, and the 1 Hz health tick reads it from here.
    private func setLastVideoFrameTime(_ time: CFTimeInterval?) {
        renderControl.setLastFrameTime(time)
    }

    private func getLastVideoFrameTime() -> CFTimeInterval? {
        renderControl.lastFrameTime
    }

    /// Every generation bump must reach the render path, or frames from the connection just torn
    /// down would keep painting and counting.
    private func bumpConnectionGeneration() {
        connectionGeneration &+= 1
        renderControl.setGeneration(connectionGeneration)
    }

    private func makeVideoRenderViewIfNeeded() {
        guard videoView == nil else { return }
        videoView = VideoRenderView(control: renderControl, sink: self)
    }

    // MARK: - Testing seams (first-frame delivery revalidation)
    //
    // The receipt-side revalidation in `videoRenderDidReceiveFirstFrame` cannot be exercised
    // through the public surface without a live signaling server, so these expose exactly what
    // the end-to-end test needs: arming the render path the way a real connection does, the
    // fallback's epoch transition as `applyAndActOnCodecSelectionState` performs it, and the
    // two effects a stale delivery must NOT have (reconnect-budget reset, watchdog event).
    // See `OverlookTests/VideoRenderViewTests.swift`.

    /// Counts first-frame deliveries that survived receipt revalidation and reached the
    /// first-frame watchdog. Never read in production.
    private(set) var firstFrameWatchdogDeliveriesForTesting = 0

    var iceAutomaticReconnectAttemptsForTesting: Int {
        get { iceAutomaticReconnectAttempts }
        set { iceAutomaticReconnectAttempts = newValue }
    }

    /// Arms a fresh connection generation and rendering epoch exactly the way a real connection
    /// does, returning the view whose decode path delivers signals to this manager.
    func armRenderPathForTesting() -> VideoRenderView {
        makeVideoRenderViewIfNeeded()
        bumpConnectionGeneration()
        guard let videoView else { preconditionFailure("makeVideoRenderViewIfNeeded made no view") }
        videoView.beginRendering(generation: connectionGeneration)
        return videoView
    }

    /// The codec fallback's epoch transition, exactly as `applyAndActOnCodecSelectionState`
    /// performs it: revoke + flush + epoch advance, then a fresh health window.
    func runFallbackEpochTransitionForTesting() {
        videoView?.flushDisplayAbandoningH265Stream()
        setLastVideoFrameTime(nil)
    }

    // MARK: - Equality-gated stream-health publishing
    //
    // The health tick recomputes these every second, and re-publishing an unchanged value
    // costs a full SwiftUI transaction across every observer. Write through these setters.

    private func setLastVideoFrameAgeSeconds(_ value: Int?) {
        guard lastVideoFrameAgeSeconds != value else { return }
        lastVideoFrameAgeSeconds = value
    }

    private func setStreamStalled(_ value: Bool) {
        guard isStreamStalled != value else { return }
        isStreamStalled = value
    }

    private func setLastDisconnectReason(_ value: String?) {
        guard lastDisconnectReason != value else { return }
        lastDisconnectReason = value
    }
    
    private static var nativeLogCapture: RTCCallbackLogger?

    private static func startNativeLogCaptureOnce() {
        guard nativeLogCapture == nil else { return }
        let logger = RTCCallbackLogger()
        logger.severity = .warning
        logger.start { message in
            NSLog("[webrtc-native] %@", message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        nativeLogCapture = logger
    }

    private func setupWebRTC() {
        Self.startNativeLogCaptureOnce()
        let inputUID = (UserDefaults.standard.string(forKey: audioInputDeviceUIDDefaultsKey) ?? "")
        let outputUID = (UserDefaults.standard.string(forKey: audioOutputDeviceUIDDefaultsKey) ?? "")
        let useCustomAudioDevice = !(inputUID.isEmpty && outputUID.isEmpty)

        let audioDevice: WebRTCAudioDevice? = useCustomAudioDevice
            ? WebRTCAudioDevice(inputDeviceUID: inputUID, outputDeviceUID: outputUID)
            : nil
        customAudioDevice = audioDevice

        factory = WebRTCFactoryBuilder.makeFactory(with: audioDevice)

        makeVideoRenderViewIfNeeded()
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
        iceAutomaticReconnectTask?.cancel()
        iceAutomaticReconnectTask = nil
    }

    private func beginOperatorInitiatedConnect(to device: KVMDevice) {
        iceAutomaticReconnectGeneration &+= 1
        cancelPendingICEAutomaticReconnect()
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
        iceAutomaticReconnectAttempts = 0
        lastAutoReconnectAt = nil
        isAutoReconnectInProgress = false
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
            self.iceAutomaticReconnectTask = nil
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
        defer { isAutoReconnectInProgress = false }

        let didStart = await reconnect(
            to: device,
            codecPreference: codecPreferenceStore.preference(forDeviceID: device.id),
            connectionKind: .automaticReconnect
        )
        guard iceAutomaticReconnectGeneration == generation else { return }

        if shouldMaintainConnection == false {
            tearDownConnection()
            return
        }
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
        _ = try await connect(
            to: device,
            codecPreference: codecPreferenceStore.preference(forDeviceID: device.id),
            connectionKind: .operatorInitiatedConnect(.deviceSelection)
        )
    }

    private func connect(
        to device: KVMDevice,
        codecPreference: CodecPreference,
        connectionKind: ConnectionKind
    ) async throws -> Bool {
        tearDownConnection()
        bumpConnectionGeneration()
        let generation = connectionGeneration

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
        setStreamStalled(false)
        setLastDisconnectReason(nil)
        setLastVideoFrameAgeSeconds(nil)
        setLastVideoFrameTime(nil)
        connectedIceTime = nil
        hasEverConnectedToStream = false

        do {
            makeVideoRenderViewIfNeeded()

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
                guard connectionGeneration == generation else { return false }
                if granted {
                    setupLocalMicrophoneTrackIfNeeded(factory: factory, peerConnection: audioPeerConnection ?? peerConnection)
                }
            }
            
            // Setup data channel for input events
            setupDataChannel()
            
            // Connect to signaling server
            try await connectToSignalingServer(
                device: device,
                videoFormat: initialCodecSelectionState.videoFormatForWatchRequest,
                generation: generation
            )
            guard connectionGeneration == generation else { return false }
            
            // Start connection quality monitoring
            startLatencyMonitoring()
            startStreamHealthMonitoring()
            return true
        } catch {
            guard connectionGeneration == generation else { return false }
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
        do {
            return try await connect(
                to: device,
                codecPreference: codecPreference,
                connectionKind: connectionKind
            )
        } catch {
            isConnecting = false
            lastDisconnectReason = "Reconnect failed: \(String(describing: error))"
            return false
        }
    }

    func setFrameCaptureEnabled(_ enabled: Bool) {
        isOCRCaptureDesired = enabled
        applyFrameCaptureState()
    }

    /// The single place the capture gate is written: capture runs only while the UI wants it *and*
    /// a track is rendering, and turning it off always releases the retained frame.
    private func applyFrameCaptureState() {
        let enabled = isOCRCaptureDesired && isRenderingVideo
        if isFrameCaptureEnabled != enabled {
            isFrameCaptureEnabled = enabled
            renderControl.setFrameCaptureEnabled(enabled)
        }
        if enabled == false, currentFrame != nil {
            currentFrame = nil
        }
    }

    /// Attaches the render view to `track` and arms it for the current generation.
    ///
    /// Attach/detach is symmetric with `stopRenderingVideo`: a repeated `didAdd` for the same
    /// track is a no-op, and a *replacement* track detaches the previous one first — otherwise the
    /// view ends up added to two tracks at once, mixing frames and keeping the old track alive.
    private func startRenderingVideo(track: RTCVideoTrack) {
        makeVideoRenderViewIfNeeded()
        guard let videoView else { return }
        guard videoTrack !== track else { return }

        if let previousTrack = videoTrack {
            previousTrack.remove(videoView)
            videoView.endRendering()
        }

        videoTrack = track
        // The generation the view will accept frames for is armed before the track can deliver
        // anything.
        videoView.beginRendering(generation: connectionGeneration)
        track.add(videoView)
        isRenderingVideo = true
        // OCR mode may have been on since before this (re)connection.
        applyFrameCaptureState()
    }

    /// The single teardown path for the render side: detach from the track, stop the render path,
    /// and drop the capture gate together with the frame it retained.
    private func stopRenderingVideo() {
        if let videoTrack, let videoView {
            videoTrack.remove(videoView)
        }
        videoView?.endRendering()
        videoTrack = nil
        isRenderingVideo = false
        applyFrameCaptureState()
    }
    
    private func applyCodecSelectionState(_ state: CodecSelectionState) {
        codecSelectionState = state
        fallbackMemory = state.fallbackMemory
        negotiatedCodec = state.negotiatedCodec
        suppressFrameArrivalSignalsForWatchdogTesting =
            forceDecodeStarvationForWatchdogTesting && state.isFirstFrameWatchdogArmed
        renderControl.setSuppressFrameArrivalSignals(suppressFrameArrivalSignalsForWatchdogTesting)
    }

    /// Publishes a policy transition and executes its one-shot command, if any.
    /// Returns true when the current offer/event was superseded by a new Watch Request.
    private func applyAndActOnCodecSelectionState(
        _ state: CodecSelectionState,
        generation: Int
    ) async -> Bool {
        guard connectionGeneration == generation else { return true }
        applyCodecSelectionState(state)

        guard let action = state.action else { return false }
        switch action {
        case .reissueVideoWatchRequest(let videoFormat):
            // The replacement stream is a different codec (and possibly a different resolution);
            // anything still queued for display belongs to the H.265 stream being abandoned.
            // This revokes admission for H.265-decoded frames (provenance travels with the
            // frame's buffer, so an abandoned-stream decode callback that begins only after
            // this transition is still refused) and advances the stream epoch on the display
            // side *and* the signal side. It must happen *before* the health clock is cleared
            // below: otherwise a late in-flight frame from the abandoned stream could stamp
            // the freshly-nil clock and claim to be the replacement stream's first decoded
            // frame, disarming the first-frame watchdog.
            videoView?.flushDisplayAbandoningH265Stream()
            // Give the replacement stream its own initial-frame health window.
            setLastVideoFrameTime(nil)
            setLastVideoFrameAgeSeconds(nil)
            connectedIceTime = CACurrentMediaTime()
            setStreamStalled(false)

            do {
                try await sendVideoWatchRequest(videoFormat: videoFormat)
                guard connectionGeneration == generation else { return true }
            } catch {
                guard connectionGeneration == generation else { return true }
                isConnecting = false
                lastDisconnectReason = "Fallback Watch Request failed: \(String(describing: error))"
            }
            return true
        }
    }

    private func handleFirstFrameWatchdogEvent(
        _ event: WatchdogEvent,
        generation: Int
    ) async -> Bool {
        guard connectionGeneration == generation else { return true }
        guard let codecSelectionState else { return false }
        let nextState = CodecSelectionPolicy.handleWatchdog(event, state: codecSelectionState)
        return await applyAndActOnCodecSelectionState(nextState, generation: generation)
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
        videoFormat: VideoFormat,
        generation: Int
    ) async throws {
        guard connectionGeneration == generation else { return }
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

        let socketTask = session.webSocketTask(with: request)
        webSocketTask = socketTask
        socketTask.resume()

        Task {
            await listenForSignalingMessages(on: socketTask, generation: generation)
        }

        // Janus session setup
        let createTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "create",
            "transaction": createTransaction,
        ])
        guard connectionGeneration == generation else { return }

        let createResponse = try await waitForJanusTransaction(createTransaction)
        guard connectionGeneration == generation else { return }
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
        guard connectionGeneration == generation else { return }

        let attachResponse = try await waitForJanusTransaction(attachTransaction)
        guard connectionGeneration == generation else { return }
        guard let attachData = attachResponse["data"] as? [String: Any],
              let handleId = attachData["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusHandleId = handleId

        // Video handle always requests video-only to avoid A/V sync causing video buffering.
        try await sendVideoWatchRequest(videoFormat: videoFormat)
        guard connectionGeneration == generation else { return }

        if (audioEnabled || micEnabled), let audioPeerConnection {
            let audioAttachTransaction = makeJanusTransaction()
            try await sendJanusMessage([
                "janus": "attach",
                "plugin": "janus.plugin.ustreamer",
                "opaque_id": "oid-audio-\(UUID().uuidString)",
                "transaction": audioAttachTransaction,
                "session_id": sessionId,
            ])
            guard connectionGeneration == generation else { return }

            let audioAttachResponse = try await waitForJanusTransaction(audioAttachTransaction)
            guard connectionGeneration == generation else { return }
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
            guard connectionGeneration == generation else { return }

            _ = audioPeerConnection
        }

        startJanusKeepAlive()
    }

    /// Injected by the UI layer (ContentView): pins the device encoder's video
    /// format through the authenticated kvmd API (`streamer/set_params`) so the
    /// encoder always matches the codec our watch request negotiates in SDP.
    /// Returns false when pinning was skipped or failed. Fail-soft: the watch
    /// proceeds regardless, and the first-frame watchdog remains the safety net
    /// for a genuine mismatch. See issue 10 for the root-cause background.
    var encoderFormatPinner: ((VideoFormat) async -> Bool)?

    private func pinEncoderFormat(_ videoFormat: VideoFormat) async {
        guard let pinner = encoderFormatPinner else {
            NSLog("[Overlook] encoder format pinner not wired; watch proceeds unpinned (video_format=%d)",
                  videoFormat.rawValue)
            return
        }
        if await pinner(videoFormat) {
            NSLog("[Overlook] encoder format pinned to video_format=%d", videoFormat.rawValue)
        } else {
            NSLog("[Overlook] encoder format pin FAILED (video_format=%d); relying on watchdog fallback",
                  videoFormat.rawValue)
        }
    }

    private func sendVideoWatchRequest(videoFormat: VideoFormat) async throws {
        guard let sessionId = janusSessionId,
              let handleId = janusHandleId else {
            throw WebRTCError.signalingConnectionLost
        }

        // Issue 10: make the encoder's real format match the SDP this watch
        // will negotiate, BEFORE the device builds the offer/stream.
        await pinEncoderFormat(videoFormat)

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
    
    private func listenForSignalingMessages(
        on socketTask: URLSessionWebSocketTask,
        generation: Int
    ) async {
        while connectionGeneration == generation, webSocketTask === socketTask {
            do {
                let message = try await socketTask.receive()
                guard connectionGeneration == generation, webSocketTask === socketTask else { return }
                await handleSignalingMessage(message, generation: generation)
            } catch {
                guard connectionGeneration == generation, webSocketTask === socketTask else { return }
                print("WebSocket receive error: \(error)")
                isConnecting = false
                if isConnected || hasEverConnectedToStream || lastDisconnectReason == nil {
                    lastDisconnectReason = "Signaling connection lost"
                }
                break
            }
        }
    }
    
    private func handleSignalingMessage(
        _ message: URLSessionWebSocketTask.Message,
        generation: Int
    ) async {
        guard connectionGeneration == generation else { return }
        switch message {
        case .string(let string):
            guard let data = string.data(using: .utf8),
                  let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            await handleJanusMessage(signalingMessage, generation: generation)
            
        case .data(let data):
            guard let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            await handleJanusMessage(signalingMessage, generation: generation)
            
        @unknown default:
            break
        }
    }

    private func handleJanusMessage(_ message: [String: Any], generation: Int) async {
        guard connectionGeneration == generation else { return }
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

        await handleOfferSDP(sdpString, senderHandleId: senderHandleId, generation: generation)
    }
    
    private func handleOfferSDP(
        _ sdpString: String,
        senderHandleId: Int?,
        generation: Int
    ) async {
        guard connectionGeneration == generation else { return }
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
            let offerContents = SDPOfferParser.parse(sdpString)
            let nextState = CodecSelectionPolicy.handleOffer(
                offerContents,
                state: codecSelectionState
            )
            if await applyAndActOnCodecSelectionState(nextState, generation: generation) {
                // A Fallback Watch Request supersedes this offer. Its replacement offer is the
                // only one answered, which also makes the re-watch call flow terminate.
                return
            }
            guard connectionGeneration == generation else { return }
        }
        
        let sessionDescription = RTCSessionDescription(
            type: .offer,
            sdp: sdpString
        )
        
        do {
            try await peerConnection.setRemoteDescription(sessionDescription)
            guard connectionGeneration == generation else { return }
        } catch {
            guard connectionGeneration == generation else { return }
            print("Failed to set remote description: \(error)")
        }
        
        // Create and send answer
        await createAndSendAnswer(
            peerConnection: peerConnection,
            handleId: handleId,
            generation: generation
        )
    }

    private func createAndSendAnswer(
        peerConnection: RTCPeerConnection,
        handleId: Int,
        generation: Int
    ) async {

        do {
            let sessionDescription = try await peerConnection.answer(
                for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            )
            guard connectionGeneration == generation else { return }
            try await peerConnection.setLocalDescription(sessionDescription)
        } catch {
            guard connectionGeneration == generation else { return }
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
            guard connectionGeneration == generation else { return }
        } catch {
            guard connectionGeneration == generation else { return }
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
                    self.setStreamStalled(false)
                    self.setLastVideoFrameAgeSeconds(nil)
                    return
                }

                let lastFrame = self.getLastVideoFrameTime()
                let age = lastFrame.map { now - $0 }

                self.setLastVideoFrameAgeSeconds(age.map { max(0, Int($0.rounded())) })

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
                    let generation = self.connectionGeneration
                    if await self.handleFirstFrameWatchdogEvent(
                        .watchdogFired,
                        generation: generation
                    ) {
                        return
                    }
                    guard self.connectionGeneration == generation else { return }
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

    /// One polling tick: read both peer connections, then publish the whole tick as a single
    /// telemetry change. The class is already `@MainActor`, so no hops are needed — every
    /// extra hop used to split one tick into several SwiftUI transactions.
    private func measureStreamStats() async {
        guard let peerConnection else {
            telemetry.update { snapshot in
                snapshot.apply(video: .empty)
                snapshot.apply(audio: .empty)
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

        let video = await collectInboundVideoStats(from: peerConnection)

        guard let audioPeerConnection else {
            resetInboundAudioRateState()
            telemetry.update { snapshot in
                snapshot.apply(video: video)
                snapshot.apply(audio: .empty)
            }
            return
        }

        let audio = await collectInboundAudioStats(from: audioPeerConnection)

        telemetry.update { snapshot in
            snapshot.apply(video: video)
            snapshot.apply(audio: audio)
        }
    }

    // Kept as one pass over the report.
    // swiftlint:disable cyclomatic_complexity function_body_length identifier_name
    /// Reads one WebRTC report for the video connection and rounds it to display precision,
    /// advancing the byte/jitter counters the derived rates are computed from.
    private func collectInboundVideoStats(
        from peerConnection: RTCPeerConnection
    ) async -> VideoStatsSample {
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
            lastInboundVideoBytesReceived = nil
            lastInboundVideoBytesTimestamp = nil
            return .empty
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

        lastInboundVideoBytesReceived = bytesReceived
        lastInboundVideoBytesTimestamp = now
        lastJitterBufferDelaySeconds = jitterBufferDelaySeconds
        lastJitterBufferEmittedCount = jitterBufferEmittedCount

        return VideoStatsSample(
            kbps: kbps,
            playoutDelayMs: playoutDelayMs,
            jitterMs: jitterMs,
            decodeMs: decodeMs,
            packetsLost: packetsLost,
            roundTripTimeMs: rttMs
        )
    }

    /// Reads one WebRTC report for the audio connection and rounds it to display precision.
    private func collectInboundAudioStats(
        from audioPeerConnection: RTCPeerConnection
    ) async -> AudioStatsSample {
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
            resetInboundAudioRateState()
            return .empty
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

        lastInboundAudioBytesReceived = audioBytesReceived
        lastInboundAudioBytesTimestamp = audioNow
        lastAudioJitterBufferDelaySeconds = audioJitterBufferDelaySeconds
        lastAudioJitterBufferEmittedCount = audioJitterBufferEmittedCount

        return AudioStatsSample(
            kbps: audioKbps,
            playoutDelayMs: audioPlayoutDelayMs,
            jitterMs: audioJitterMs,
            packetsLost: audioPacketsLost,
            roundTripTimeMs: audioRttMs
        )
    }
    // swiftlint:enable cyclomatic_complexity function_body_length identifier_name

    private func resetInboundAudioRateState() {
        lastInboundAudioBytesReceived = nil
        lastInboundAudioBytesTimestamp = nil
        lastAudioJitterBufferDelaySeconds = nil
        lastAudioJitterBufferEmittedCount = nil
    }
    
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
        iceAutomaticReconnectGeneration &+= 1
        cancelPendingICEAutomaticReconnect()
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
        isAutoReconnectInProgress = false
        tearDownConnection()
    }

    private func tearDownConnection() {
        bumpConnectionGeneration()

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
            waiter.resume(throwing: CancellationError())
        }
        
        webSocketTask?.cancel()
        webSocketTask = nil
        
        dataChannel?.close()
        dataChannel = nil

        stopRenderingVideo()
        
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
        setStreamStalled(false)
        setLastDisconnectReason(nil)
        setLastVideoFrameAgeSeconds(nil)
        setLastVideoFrameTime(nil)
        connectedIceTime = nil
        videoSize = nil
        negotiatedCodec = nil
        codecSelectionState = nil
        suppressFrameArrivalSignalsForWatchdogTesting = false
        renderControl.setSuppressFrameArrivalSignals(false)
        telemetry.reset()
        lastInboundVideoBytesReceived = nil
        lastInboundVideoBytesTimestamp = nil
        resetInboundAudioRateState()
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
        Task { @MainActor in
            guard peerConnection === self.peerConnection else { return }
            applyPlayoutDelayHintIfPossible()
            guard let track = rtpReceiver.track as? RTCVideoTrack else { return }

            // The view *is* the renderer: attach exactly once per track, and never to two tracks.
            startRenderingVideo(track: track)
        }
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
                let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
                telemetry.update { $0.latencyMs = latencyMs }
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

// MARK: - VideoRenderSignalSink
//
// The render path itself runs entirely off the main actor (see `VideoRenderView`). These are the
// only points where it reaches the main actor: once per connection for the first-frame watchdog
// event, at most twice a second for fps, at most ~12 times a second while OCR capture is on, and
// whenever the track's frame size changes.
extension WebRTCManager: VideoRenderSignalSink {
    func videoRenderDidReceiveFirstFrame(generation: Int, token: VideoDisplayEngine.RenderToken) {
        guard connectionGeneration == generation else { return }
        // The render path queued this hop before the main actor got a turn, and it cannot be
        // retracted; a codec fallback may have advanced the stream epoch in between. So the
        // token is revalidated at receipt: a first frame admitted for a stream that has since
        // been abandoned must neither reset the reconnect budget nor disarm the watchdog.
        guard renderControl.isCurrentEpoch(token) else { return }

        iceAutomaticReconnectAttempts = 0
        Task { @MainActor [weak self] in
            guard let self, self.connectionGeneration == generation,
                  self.renderControl.isCurrentEpoch(token) else { return }
            self.firstFrameWatchdogDeliveriesForTesting += 1
            _ = await self.handleFirstFrameWatchdogEvent(
                .firstDecodedFrameArrived,
                generation: generation
            )
        }
    }

    func videoRenderDidMeasureFps(_ fps: Int, generation: Int) {
        guard connectionGeneration == generation else { return }
        // Already quantized to whole frames the way the UI renders it, so the ≤ 2 Hz window only
        // publishes when the displayed number actually moves.
        telemetry.update { $0.videoFps = fps }
    }

    func videoRenderDidCaptureFrame(_ pixelBuffer: CVPixelBuffer, generation: Int) {
        guard connectionGeneration == generation else { return }
        guard isFrameCaptureEnabled else { return }
        currentFrame = pixelBuffer
    }

    func videoRenderDidChangeSize(_ size: CGSize, generation: Int) {
        setVideoSize(size, generation: generation)
    }

    func setVideoSize(_ size: CGSize, generation: Int) {
        guard connectionGeneration == generation else { return }
        if size.width > 0, size.height > 0, videoSize != size {
            videoSize = size
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
    @Published var currentFrame: CVPixelBuffer?
    @Published var audioEnabled = false
    @Published var micEnabled = false

    let telemetry = StreamTelemetryModel()
    
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
        telemetry.reset()
        currentFrame = nil
    }
}

#endif
