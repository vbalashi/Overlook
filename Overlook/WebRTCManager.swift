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
#if canImport(AppKit)
import AppKit
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
    @Published var sourceContentRectInVideo: CGRect?
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
    @Published var audioEnabled: Bool = UserDefaults.standard.bool(forKey: audioEnabledDefaultsKey) {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: Self.audioEnabledDefaultsKey)
        }
    }
    @Published var micEnabled: Bool = UserDefaults.standard.bool(forKey: micEnabledDefaultsKey) {
        didSet {
            UserDefaults.standard.set(micEnabled, forKey: Self.micEnabledDefaultsKey)
        }
    }
    @Published var audioOutputMuted: Bool = false {
        didSet {
            applyAudioMuteState()
        }
    }
    @Published var microphoneMuted: Bool = false {
        didSet {
            applyAudioMuteState()
        }
    }
    @Published var preferLowLatencyPlayout = true
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var lastVideoFrameAgeSeconds: Int?
    
    private var peerConnection: RTCPeerConnection?
    private var audioPeerConnection: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var remoteAudioTrack: RTCAudioTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var localAudioSender: RTCRtpSender?
    private var dataChannel: RTCDataChannel?
    private var factory: RTCPeerConnectionFactory?
    private var customAudioDevice: WebRTCAudioDevice?
    private var connectionTimer: Timer?
    private var latencyMeasurementStart: Date?

    private var lastConnectedDevice: KVMDevice?

    private let audioDevicesListenerQueue = DispatchQueue(label: "com.overlook.audio-device-change")
    private var audioDevicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var audioDeviceChangeDebounceTask: Task<Void, Never>?
    private var isAutoReconnectInProgress: Bool = false
    private var lastAutoReconnectAt: Date?
    private var autoReconnectTask: Task<Void, Never>?
    private var autoReconnectAttempt: Int = 0
    private var autoReconnectGeneration: Int = 0
    private var wakeReconnectTask: Task<Void, Never>?
    private var systemSleepObservers: [NSObjectProtocol] = []
    private var isSystemSleeping = false
    private var shouldReconnectAfterWake = false

    private var lastInboundVideoBytesReceived: Int64?
    private var lastInboundVideoBytesTimestamp: TimeInterval?
    private var lastInboundVideoFramesDecoded: Double?
    private var lastInboundVideoFramesTimestamp: TimeInterval?

    private var lastInboundAudioBytesReceived: Int64?
    private var lastInboundAudioBytesTimestamp: TimeInterval?

    private var lastJitterBufferDelaySeconds: Double?
    private var lastJitterBufferEmittedCount: Double?

    private var lastAudioJitterBufferDelaySeconds: Double?
    private var lastAudioJitterBufferEmittedCount: Double?

    private var lastPlayoutHintApplyTime: TimeInterval?

    private static let audioEnabledDefaultsKey = "overlook.audio.enabled"
    private static let micEnabledDefaultsKey = "overlook.audio.micEnabled"
    private let audioInputDeviceUIDDefaultsKey = "overlook.audio.inputDeviceUID"
    private let audioOutputDeviceUIDDefaultsKey = "overlook.audio.outputDeviceUID"

    private let streamHealthQueue = DispatchQueue(label: "com.overlook.stream-health")
    private var lastVideoFrameTime: CFTimeInterval?
    private var lastInboundVideoActivityTime: CFTimeInterval?
    private var connectedIceTime: CFTimeInterval?
    private var streamHealthTimer: Timer?

    private let streamStallThresholdSeconds: CFTimeInterval = 15.0
    private let initialFrameTimeoutSeconds: CFTimeInterval = 5.0
    
    private let allowInsecureTLS = true
    private var signalingSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var signalingListenTask: Task<Void, Never>?
    private var signalingGeneration: Int = 0

    private var janusSessionId: Int?
    private var janusHandleId: Int?
    private var janusAudioHandleId: Int?
    private var janusKeepAliveTimer: Timer?
    private var janusWaiters: [String: CheckedContinuation<[String: Any], Error>] = [:]

    private var isFrameCaptureEnabled: Bool = false
    private enum FrameCaptureReason: Hashable {
        case manual
        case letterbox
        case snapshot
    }

    private var frameCaptureReasons: Set<FrameCaptureReason> = []
    private var isFrameRendererAttached = false
    private var lastFrameCaptureTime: CFTimeInterval = 0

    private var letterboxDetectionTask: Task<Void, Never>?
    private static let letterboxDetectionIntervalSeconds: UInt64 = 2_000_000_000
    
    override init() {
        super.init()
        setupWebRTC()
        startAudioDeviceChangeMonitoring()
        startSystemSleepMonitoring()
    }

    deinit {
        wakeReconnectTask?.cancel()
        wakeReconnectTask = nil

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
        audioDeviceChangeDebounceTask?.cancel()
        audioDeviceChangeDebounceTask = nil
    }

    private func startSystemSleepMonitoring() {
#if canImport(AppKit)
        guard systemSleepObservers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        let mainQueue = OperationQueue.main

        systemSleepObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: mainQueue
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWillSleep()
            }
        })

        systemSleepObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: mainQueue
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemDidWake(reason: "system wake")
            }
        })

        systemSleepObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: mainQueue
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemDidWake(reason: "display wake")
            }
        })
#endif
    }

    private func handleSystemWillSleep() {
        isSystemSleeping = true
        wakeReconnectTask?.cancel()
        wakeReconnectTask = nil

        shouldReconnectAfterWake = lastConnectedDevice != nil && (peerConnection != nil || isConnected || isConnecting)
        guard shouldReconnectAfterWake else { return }

        OverlookLog.info("System will sleep; closing WebRTC session for wake recovery")
        disconnect()
        lastDisconnectReason = "System slept. Reconnecting after wake..."
    }

    private func handleSystemDidWake(reason: String) {
        isSystemSleeping = false
        guard shouldReconnectAfterWake else { return }
        guard lastConnectedDevice != nil else {
            shouldReconnectAfterWake = false
            return
        }

        scheduleWakeReconnect(reason: reason)
    }

    private func scheduleWakeReconnect(reason: String) {
        guard let device = lastConnectedDevice else { return }

        wakeReconnectTask?.cancel()
        isConnecting = true
        lastDisconnectReason = "Woke from \(reason). Reconnecting..."

        OverlookLog.info("WebRTC wake reconnect scheduled reason=\(reason) delaySeconds=2.0 host=\(device.host) port=\(device.port)")

        wakeReconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.isSystemSleeping == false else { return }
                guard let device = self.lastConnectedDevice else { return }

                self.wakeReconnectTask = nil
                self.shouldReconnectAfterWake = false
                self.isAutoReconnectInProgress = true

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.isAutoReconnectInProgress = false }
                    await self.reconnect(to: device)
                }
            }
        }
    }

    private func setLastVideoFrameTime(_ time: CFTimeInterval?) {
        streamHealthQueue.sync {
            lastVideoFrameTime = time
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
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                self?.autoReconnectIfStillNeeded()
            }
        }
    }

    private func autoReconnectIfStillNeeded() {
        guard isAutoReconnectInProgress == false else { return }
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
            await self.reconnect(to: device)
        }
    }
    
    func connect(to device: KVMDevice) async throws {
        lastConnectedDevice = device
        setupWebRTC()

        guard let factory = factory else {
            throw WebRTCError.factoryNotInitialized
        }

        isConnecting = true
        autoReconnectAttempt = 0
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        setLastVideoFrameTime(nil)
        lastInboundVideoActivityTime = nil
        connectedIceTime = nil
        hasEverConnectedToStream = false

        do {
            if videoView == nil {
                videoView = RTCMTLNSVideoView(frame: .zero)
            }
            
            let configuration = await makeRTCConfiguration(for: device)
            
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
            try await connectToSignalingServer(device: device)
            
            // Start connection quality monitoring
            startLatencyMonitoring()
            startStreamHealthMonitoring()
        } catch {
            let reason = "Connect failed: \(String(describing: error))"
            disconnect()
            lastDisconnectReason = reason
            throw error
        }
    }

    private func makeRTCConfiguration(for device: KVMDevice) async -> RTCConfiguration {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan

        do {
            let client = try GLKVMClient(device: device, allowInsecureTLS: allowInsecureTLS)
            let credentials = try await client.getTurnCredentials()
            if credentials.uris.isEmpty == false {
                configuration.iceServers = [
                    RTCIceServer(
                        urlStrings: credentials.uris,
                        username: credentials.username,
                        credential: credentials.password
                    )
                ]
                OverlookLog.info("WebRTC ICE config using device TURN servers count=\(credentials.uris.count) ttl=\(credentials.ttl)")
                return configuration
            }
        } catch {
            OverlookLog.error("WebRTC ICE config could not load device TURN credentials; using host candidates only error=\(OverlookLog.describe(error))")
        }

        // On the local network, host candidates are enough and avoid depending on a public STUN server.
        configuration.iceServers = []
        OverlookLog.info("WebRTC ICE config using host candidates only")
        return configuration
    }

    func reconnect(to device: KVMDevice) async {
        disconnect()
        do {
            try await connect(to: device)
            OverlookLog.info("WebRTC reconnect succeeded host=\(device.host) port=\(device.port)")
        } catch {
            isConnecting = false
            lastDisconnectReason = "Reconnect failed: \(String(describing: error))"
            OverlookLog.error("WebRTC reconnect failed host=\(device.host) port=\(device.port) error=\(OverlookLog.describe(error))")
            scheduleAutoReconnect(reason: "Reconnect failed")
        }
    }

    private func scheduleAutoReconnect(reason: String) {
        guard let device = lastConnectedDevice else { return }
        guard isSystemSleeping == false else { return }
        guard isAutoReconnectInProgress == false else { return }

        autoReconnectTask?.cancel()
        autoReconnectAttempt += 1
        autoReconnectGeneration += 1

        let generation = autoReconnectGeneration
        let attempt = autoReconnectAttempt
        let delay = min(pow(2.0, Double(max(0, attempt - 1))), 8.0)

        isConnecting = true
        if lastDisconnectReason == nil || lastDisconnectReason == reason {
            lastDisconnectReason = "\(reason). Reconnecting…"
        }

        OverlookLog.info("WebRTC auto reconnect scheduled reason=\(reason) attempt=\(attempt) delaySeconds=\(String(format: "%.1f", delay)) host=\(device.host) port=\(device.port)")

        autoReconnectTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard generation == self.autoReconnectGeneration else { return }
                self.autoReconnectTask = nil
                self.isAutoReconnectInProgress = true

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.isAutoReconnectInProgress = false }
                    await self.reconnect(to: device)
                }
            }
        }
    }

    func setFrameCaptureEnabled(_ enabled: Bool) {
        isFrameCaptureEnabled = enabled
        setFrameCaptureActive(.manual, enabled)
    }

    func captureCurrentFrame(timeout: TimeInterval = 1.0) async -> CVPixelBuffer? {
        await captureCurrentFrame(reason: .snapshot, timeout: timeout)
    }

    private func captureCurrentFrame(reason: FrameCaptureReason, timeout: TimeInterval = 1.0) async -> CVPixelBuffer? {
        if let currentFrame {
            return currentFrame
        }

        setFrameCaptureActive(reason, true)
        defer { setFrameCaptureActive(reason, false) }

        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if let currentFrame {
                return currentFrame
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return currentFrame
    }

    private func setFrameCaptureActive(_ reason: FrameCaptureReason, _ active: Bool) {
        if active {
            frameCaptureReasons.insert(reason)
        } else {
            frameCaptureReasons.remove(reason)
        }

        updateFrameRendererSubscription()

        if frameCaptureReasons.isEmpty {
            currentFrame = nil
        }
    }

    private func updateFrameRendererSubscription() {
        guard let videoTrack else {
            isFrameRendererAttached = false
            return
        }

        let shouldAttach = !frameCaptureReasons.isEmpty
        if shouldAttach, !isFrameRendererAttached {
            videoTrack.add(self)
            isFrameRendererAttached = true
        } else if !shouldAttach, isFrameRendererAttached {
            videoTrack.remove(self)
            isFrameRendererAttached = false
        }
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

    @discardableResult
    func setAudioEnabled(_ enabled: Bool) -> Bool {
        let wasEnabled = audioEnabled
        audioEnabled = enabled
        applyAudioMuteState()
        guard wasEnabled != enabled else { return false }
        return shouldReconnectForAudioPreferenceChange()
    }

    @discardableResult
    func setMicEnabled(_ enabled: Bool) -> Bool {
        let wasEnabled = micEnabled
        micEnabled = enabled
        applyAudioMuteState()
        guard wasEnabled != enabled else { return false }
        return shouldReconnectForAudioPreferenceChange()
    }

    func setAudioOutputMuted(_ muted: Bool) {
        audioOutputMuted = muted
    }

    func setMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
    }

    private func shouldReconnectForAudioPreferenceChange() -> Bool {
        guard peerConnection != nil || isConnected || isConnecting else { return false }
        // Janus/uStreamer bakes audio and mic flags into the watch offer. Toggling
        // them after connect needs a fresh offer so the server opens/closes aplay
        // and so a local microphone sender exists when mic is enabled.
        return true
    }

    private func applyAudioMuteState() {
        let shouldPlayRemoteAudio = audioEnabled && !audioOutputMuted
        let shouldSendMicrophone = micEnabled && !microphoneMuted

        remoteAudioTrack?.isEnabled = shouldPlayRemoteAudio
        localAudioTrack?.isEnabled = shouldSendMicrophone

        audioPeerConnection?.receivers.forEach { receiver in
            guard receiver.track?.kind == "audio" else { return }
            receiver.track?.isEnabled = shouldPlayRemoteAudio
        }
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
    
    private func connectToSignalingServer(device: KVMDevice) async throws {
        guard let rawURL = URL(string: device.webRTCURL) else {
            throw WebRTCError.invalidSignalingURL
        }

        let url = normalizedWebSocketURL(rawURL)
        print("WebRTC signaling connect: \(url.absoluteString)")
        OverlookLog.info("WebRTC signaling connect url=\(OverlookLog.redactedURL(url)) host=\(device.host) port=\(device.port)")

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: SessionDelegate(allowInsecureTLS: allowInsecureTLS), delegateQueue: nil)
        signalingSession = session

        var request = URLRequest(url: url)
        if !device.authToken.isEmpty {
            request.setValue("auth_token=\(device.authToken)", forHTTPHeaderField: "Cookie")
        }
        let originScheme = (device.port == 80 || device.port == 8080) ? "http" : "https"
        request.setValue("\(originScheme)://\(device.host):\(device.port)", forHTTPHeaderField: "Origin")
        request.setValue("janus-protocol", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        webSocketTask = session.webSocketTask(with: request)
        
        webSocketTask?.resume()

        signalingGeneration += 1
        let generation = signalingGeneration
        signalingListenTask?.cancel()
        signalingListenTask = Task { [weak self] in
            await self?.listenForSignalingMessages(generation: generation)
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
        let watchTransaction = makeJanusTransaction()
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
                ],
            ],
            "transaction": watchTransaction,
            "session_id": sessionId,
            "handle_id": handleId,
        ])

        let shouldRequestJanusAudio = audioEnabled || micEnabled
        if shouldRequestJanusAudio, let audioPeerConnection {
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
                        // GLKVM's browser frontend only allows mic when audio is
                        // requested. Keep the local remote track muted when
                        // audioEnabled is false, but still request the Janus audio
                        // leg so mic RTP can flow to ustreamer/aplay.
                        "audio": shouldRequestJanusAudio,
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

    private func startJanusKeepAlive() {
        janusKeepAliveTimer?.invalidate()
        janusKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.sendJanusKeepAlive()
                } catch {
                    let reason = "Janus keepalive failed"
                    self.lastDisconnectReason = reason
                    OverlookLog.error("\(reason): \(OverlookLog.describe(error))")
                    self.scheduleAutoReconnect(reason: reason)
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
    
    private func listenForSignalingMessages(generation: Int) async {
        while !Task.isCancelled, generation == signalingGeneration, let webSocketTask = webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                guard generation == signalingGeneration else { break }
                await handleSignalingMessage(message)
            } catch {
                guard generation == signalingGeneration, !Task.isCancelled else { break }
                print("WebSocket receive error: \(error)")
                isConnecting = false
                if isConnected || hasEverConnectedToStream || lastDisconnectReason == nil {
                    lastDisconnectReason = "Signaling connection lost"
                }
                OverlookLog.error("WebSocket receive error generation=\(generation) error=\(OverlookLog.describe(error))")
                scheduleAutoReconnect(reason: "Signaling connection lost")
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
                let lastStatsActivity = self.lastInboundVideoActivityTime
                let lastActivity: CFTimeInterval?
                if let lastFrame, let lastStatsActivity {
                    lastActivity = max(lastFrame, lastStatsActivity)
                } else {
                    lastActivity = lastFrame ?? lastStatsActivity
                }

                let age = lastActivity.map { now - $0 }

                if let frameAge = lastFrame.map({ now - $0 }) {
                    self.lastVideoFrameAgeSeconds = max(0, Int(frameAge.rounded()))
                } else {
                    self.lastVideoFrameAgeSeconds = nil
                }

                if let age, age > self.streamStallThresholdSeconds {
                    if self.isStreamStalled == false {
                        self.isStreamStalled = true
                        self.lastDisconnectReason = "Video stream stalled"
                        OverlookLog.error("Video stream stalled ageSeconds=\(String(format: "%.1f", age)) kbps=\(self.inboundVideoKbps.map(String.init) ?? "nil") fps=\(self.inboundFps.map { String(format: "%.1f", $0) } ?? "nil") rttMs=\(self.iceCurrentRoundTripTimeMs.map(String.init) ?? "nil")")
                        self.scheduleAutoReconnect(reason: "Video stream stalled")
                    }
                    return
                }

                if lastActivity == nil,
                   let connectedAt = self.connectedIceTime,
                   now - connectedAt > self.initialFrameTimeoutSeconds {
                    if self.isStreamStalled == false {
                        self.isStreamStalled = true
                        self.lastDisconnectReason = "Video stream stalled"
                        OverlookLog.error("Initial video frame timeout after ICE connected")
                        self.scheduleAutoReconnect(reason: "Video stream stalled")
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
                self.lastInboundVideoFramesDecoded = nil
                self.lastInboundVideoFramesTimestamp = nil
                self.inboundVideoKbps = nil
                self.inboundFps = nil
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

        var fps: Double?
        if let framesDecoded,
           let lastFrames = lastInboundVideoFramesDecoded,
           let lastFrameTs = lastInboundVideoFramesTimestamp {
            let dt = now - lastFrameTs
            let df = framesDecoded - lastFrames
            if dt > 0, df >= 0 {
                fps = df / dt
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
            if lastBytes == nil || bytesReceived > (lastBytes ?? 0) {
                self.lastInboundVideoActivityTime = CACurrentMediaTime()
            }
            self.lastInboundVideoBytesReceived = bytesReceived
            self.lastInboundVideoBytesTimestamp = now
            self.lastInboundVideoFramesDecoded = framesDecoded
            self.lastInboundVideoFramesTimestamp = now
            self.lastJitterBufferDelaySeconds = jitterBufferDelaySeconds
            self.lastJitterBufferEmittedCount = jitterBufferEmittedCount
            self.inboundVideoKbps = kbps
            self.inboundFps = fps
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
        signalingGeneration += 1
        autoReconnectGeneration += 1
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        autoReconnectAttempt = 0

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
        
        signalingListenTask?.cancel()
        signalingListenTask = nil

        webSocketTask?.cancel()
        webSocketTask = nil

        signalingSession?.invalidateAndCancel()
        signalingSession = nil
        
        dataChannel?.close()
        dataChannel = nil

        if let videoTrack {
            if let videoView {
                videoTrack.remove(videoView)
            }
            if isFrameRendererAttached {
                videoTrack.remove(self)
            }
        }
        isFrameRendererAttached = false
        videoTrack = nil
        remoteAudioTrack = nil
        
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
        lastInboundVideoActivityTime = nil
        connectedIceTime = nil
        latency = 0
        videoSize = nil
        sourceContentRectInVideo = nil
        stopLetterboxDetectionTask()
        isFrameCaptureEnabled = false
        frameCaptureReasons.removeAll()
        isFrameRendererAttached = false
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
        lastInboundVideoFramesDecoded = nil
        lastInboundVideoFramesTimestamp = nil
        lastInboundAudioBytesReceived = nil
        lastInboundAudioBytesTimestamp = nil
        lastAudioJitterBufferDelaySeconds = nil
        lastAudioJitterBufferEmittedCount = nil
    }

    private func ensureMicrophoneAccess() async -> Bool {
#if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            OverlookLog.info("Microphone permission already authorized")
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            OverlookLog.info("Microphone permission requested granted=\(granted)")
            return granted
        default:
            OverlookLog.error("Microphone permission denied status=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
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
        audioTrack.isEnabled = micEnabled && !microphoneMuted
        localAudioTrack = audioTrack
        localAudioSender = peerConnection.add(audioTrack, streamIds: ["stream0"])
        OverlookLog.info("Local microphone track added enabled=\(self.micEnabled) muted=\(self.microphoneMuted)")
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
                OverlookLog.info("Audio ICE connection state changed: \(stateChanged)")
                return
            }

            isConnected = (stateChanged == .connected || stateChanged == .completed)
            if isConnected {
                isConnecting = false
                hasEverConnectedToStream = true
                connectedIceTime = CACurrentMediaTime()
                lastDisconnectReason = nil
                autoReconnectAttempt = 0
                startLetterboxDetectionTask()
            } else {
                stopLetterboxDetectionTask()
                if stateChanged == .disconnected {
                    lastDisconnectReason = "Video connection lost"
                    isConnecting = false
                    scheduleAutoReconnect(reason: "Video connection lost")
                } else if stateChanged == .failed {
                    lastDisconnectReason = "Video connection failed"
                    isConnecting = false
                    scheduleAutoReconnect(reason: "Video connection failed")
                } else if stateChanged == .closed {
                    lastDisconnectReason = "Video connection closed"
                    isConnecting = false
                }
            }
            print("ICE connection state changed: \(stateChanged)")
            OverlookLog.info("Video ICE connection state changed: \(stateChanged) connected=\(self.isConnected)")
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
        if let track = rtpReceiver.track as? RTCAudioTrack {
            remoteAudioTrack = track
            applyAudioMuteState()
            return
        }

        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        videoTrack = track
        if let videoView {
            track.add(videoView)
        }
        updateFrameRendererSubscription()
    }
}

// MARK: - RTCDataChannelDelegate
extension WebRTCManager: @preconcurrency RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            print("Data channel state changed: \(dataChannel.readyState)")
            OverlookLog.info("Data channel state changed: \(dataChannel.readyState)")
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

        let now = CACurrentMediaTime()

        setLastVideoFrameTime(now)

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

    private func startLetterboxDetectionTask() {
        guard letterboxDetectionTask == nil else { return }
        let intervalNs = Self.letterboxDetectionIntervalSeconds
        let initialDelayNs: UInt64 = 800_000_000
        let maxSampleAttempts = 6
        letterboxDetectionTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: initialDelayNs)
            let detector = LetterboxDetector()
            var attemptsRemaining = maxSampleAttempts
            while !Task.isCancelled, attemptsRemaining > 0 {
                guard let self else { return }
                let frame = await self.captureCurrentFrame(reason: .letterbox, timeout: 0.6)
                if let frame, let detected = detector.sample(frame) {
                    let resolved = Self.resolvedLetterboxContentRect(from: detected)
                    await MainActor.run {
                        if self.sourceContentRectInVideo != resolved {
                            self.sourceContentRectInVideo = resolved
                            if let r = resolved {
                                OverlookLog.info("letterbox-detect contentRectInVideo=(\(String(format: "%.4f", r.minX)),\(String(format: "%.4f", r.minY)),\(String(format: "%.4f", r.width)),\(String(format: "%.4f", r.height)))")
                            } else {
                                OverlookLog.info("letterbox-detect contentRectInVideo=full")
                            }
                        }
                        self.finishLetterboxDetectionTask()
                    }
                    return
                }
                attemptsRemaining -= 1
                try? await Task.sleep(nanoseconds: intervalNs)
            }
            if let self {
                await self.finishLetterboxDetectionTask()
            }
        }
    }

    nonisolated private static func resolvedLetterboxContentRect(from detected: CGRect) -> CGRect? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rect = detected.intersection(unit)
        guard rect.width > 0, rect.height > 0 else { return nil }

        let fullTolerance: CGFloat = 0.005
        let isFullFrame = abs(rect.minX) < fullTolerance &&
            abs(rect.minY) < fullTolerance &&
            abs(rect.maxX - 1) < fullTolerance &&
            abs(rect.maxY - 1) < fullTolerance
        guard !isFullFrame else { return nil }

        let edgeTolerance: CGFloat = 0.01
        let symmetryTolerance: CGFloat = 0.03

        let leftInset = rect.minX
        let rightInset = 1 - rect.maxX
        let topInset = rect.minY
        let bottomInset = 1 - rect.maxY

        let hasSymmetricPillarbox = topInset < edgeTolerance &&
            bottomInset < edgeTolerance &&
            abs(leftInset - rightInset) < symmetryTolerance &&
            (leftInset > edgeTolerance || rightInset > edgeTolerance)

        let hasSymmetricLetterbox = leftInset < edgeTolerance &&
            rightInset < edgeTolerance &&
            abs(topInset - bottomInset) < symmetryTolerance &&
            (topInset > edgeTolerance || bottomInset > edgeTolerance)

        guard hasSymmetricPillarbox || hasSymmetricLetterbox else { return nil }

        return rect
    }

    private func stopLetterboxDetectionTask() {
        letterboxDetectionTask?.cancel()
        finishLetterboxDetectionTask()
    }

    private func finishLetterboxDetectionTask() {
        letterboxDetectionTask = nil
        setFrameCaptureActive(.letterbox, false)
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
    @Published var videoSize: CGSize?
    @Published var audioEnabled: Bool = UserDefaults.standard.bool(forKey: audioEnabledDefaultsKey) {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: Self.audioEnabledDefaultsKey)
        }
    }
    @Published var micEnabled: Bool = UserDefaults.standard.bool(forKey: micEnabledDefaultsKey) {
        didSet {
            UserDefaults.standard.set(micEnabled, forKey: Self.micEnabledDefaultsKey)
        }
    }
    @Published var audioOutputMuted: Bool = false
    @Published var microphoneMuted: Bool = false

    private static let audioEnabledDefaultsKey = "overlook.audio.enabled"
    private static let micEnabledDefaultsKey = "overlook.audio.micEnabled"

    @discardableResult
    func setAudioEnabled(_ enabled: Bool) -> Bool {
        audioEnabled = enabled
        return false
    }

    @discardableResult
    func setMicEnabled(_ enabled: Bool) -> Bool {
        micEnabled = enabled
        return false
    }

    func setAudioOutputMuted(_ muted: Bool) {
        audioOutputMuted = muted
    }

    func setMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
    }
    
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

    func setFrameCaptureEnabled(_ enabled: Bool) {
        if enabled == false {
            currentFrame = nil
        }
    }

    func captureCurrentFrame(timeout: TimeInterval = 1.0) async -> CVPixelBuffer? {
        currentFrame
    }
}

#endif
