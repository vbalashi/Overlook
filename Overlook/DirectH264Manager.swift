import Foundation
import CoreGraphics
#if canImport(CoreVideo)
import CoreVideo
#endif

@MainActor
final class DirectH264Manager: NSObject, ObservableObject, VideoPlaybackBackend {
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

    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var hasEverConnectedToStream = false
    @Published private(set) var isStreamStalled = false
    @Published private(set) var lastDisconnectReason: String?
    @Published private(set) var lastVideoFrameAgeSeconds: Int?
    @Published private(set) var latency: Int = 0
    @Published private(set) var currentFrame: CVPixelBuffer?
    @Published private(set) var videoSize: CGSize?
    @Published private(set) var sourceContentRectInVideo: CGRect?
    @Published private(set) var inboundVideoKbps: Int?
    @Published private(set) var inboundFps: Double?
    @Published private(set) var inboundVideoPlayoutDelayMs: Int?
    @Published private(set) var inboundVideoJitterMs: Int?
    @Published private(set) var inboundVideoDecodeMs: Int?
    @Published private(set) var inboundVideoPacketsLost: Int?
    @Published private(set) var iceCurrentRoundTripTimeMs: Int?
    @Published private(set) var sessionVideoBytesReceived: Int64?

    let backendKind: VideoPlaybackBackendKind = .directH264

    private let allowInsecureTLS = true
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var generation = 0

    private var videoBytesReceived: Int64 = 0
    private var videoFramesReceived: Int64 = 0
    private var keyframesReceived: Int64 = 0
    private var controlMessagesReceived: Int64 = 0
    private var lastStatsAt = Date()
    private var lastStatsBytes: Int64 = 0
    private var lastStatsFrames: Int64 = 0
    private var lastFrameAt: Date?
    private var h264StartSent = false
    private var parser = DirectH264Parser()

    func connect(to device: KVMDevice) async throws {
        disconnect()
        generation += 1
        let currentGeneration = generation

        isConnecting = true
        isStreamStalled = false
        lastDisconnectReason = nil
        resetCounters()

        let client = try GLKVMClient(device: device, allowInsecureTLS: allowInsecureTLS)
        let mediaURL = try client.mediaWebsocketURL()
        var request = URLRequest(url: mediaURL)
        request.assumesHTTP3Capable = false
        request.setValue(client.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        if let authToken = client.authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let session = URLSession(
            configuration: config,
            delegate: SessionDelegate(allowInsecureTLS: allowInsecureTLS),
            delegateQueue: nil
        )
        let task = session.webSocketTask(with: request)

        self.session = session
        webSocketTask = task
        task.resume()

        OverlookLog.info("Direct H.264 websocket connect start url=\(OverlookLog.redactedURL(mediaURL)) hasAuthCookie=\((client.authToken?.isEmpty == false))")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(generation: currentGeneration)
        }
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatLoop(generation: currentGeneration)
        }
        startStatsTimer(generation: currentGeneration)
    }

    func reconnect(to device: KVMDevice) async {
        do {
            try await connect(to: device)
        } catch {
            markDisconnected(reason: "Direct H.264 reconnect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        statsTimer?.invalidate()
        statsTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil

        isConnected = false
        isConnecting = false
        hasEverConnectedToStream = false
        isStreamStalled = false
        lastVideoFrameAgeSeconds = nil
        currentFrame = nil
        videoSize = nil
        sourceContentRectInVideo = nil
        inboundVideoKbps = nil
        inboundFps = nil
        inboundVideoPlayoutDelayMs = nil
        inboundVideoJitterMs = nil
        inboundVideoDecodeMs = nil
        inboundVideoPacketsLost = nil
        iceCurrentRoundTripTimeMs = nil
    }

    func setFrameCaptureEnabled(_ enabled: Bool) {
        if enabled == false {
            currentFrame = nil
        }
    }

    func captureCurrentFrame(timeout: TimeInterval = 1.0) async -> CVPixelBuffer? {
        currentFrame
    }

    private func receiveLoop(generation: Int) async {
        guard let webSocketTask else { return }

        while !Task.isCancelled, generation == self.generation {
            do {
                let message = try await webSocketTask.receive()
                handle(message)
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                markDisconnected(reason: "Direct H.264 websocket receive failed: \(error.localizedDescription)")
                return
            }
        }
    }

    private func heartbeatLoop(generation: Int) async {
        while !Task.isCancelled, generation == self.generation {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, generation == self.generation else { return }
            do {
                try await webSocketTask?.send(.data(Data([0])))
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                markDisconnected(reason: "Direct H.264 heartbeat failed: \(error.localizedDescription)")
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard !h264StartSent, shouldStartH264(from: text) else { return }
            h264StartSent = true
            Task { [weak self] in
                do {
                    try await self?.webSocketTask?.send(.string(Self.h264StartMessage))
                    OverlookLog.info("Direct H.264 start message sent")
                } catch {
                    await MainActor.run {
                        self?.markDisconnected(reason: "Direct H.264 start failed: \(error.localizedDescription)")
                    }
                }
            }
        case .data(let data):
            handleBinary(data)
        @unknown default:
            break
        }
    }

    private func handleBinary(_ data: Data) {
        guard let first = data.first else { return }
        if first != 1 {
            controlMessagesReceived += 1
            return
        }

        guard data.count >= 2 else {
            controlMessagesReceived += 1
            return
        }

        let isKeyframe = data[data.startIndex + 1] != 0
        let payloadBytes = max(0, data.count - 2)
        let parseResult = parser.parseGLKVMBinaryMessage(data)
        let parsedKeyframe: Bool
        switch parseResult {
        case .accessUnit(let accessUnit):
            parsedKeyframe = accessUnit.isKeyframe
        case .waitingForKeyframe:
            return
        case .control:
            controlMessagesReceived += 1
            return
        case .invalid(let reason):
            controlMessagesReceived += 1
            OverlookLog.error("Direct H.264 parser rejected frame reason=\(reason) bytes=\(data.count)")
            return
        }

        videoBytesReceived += Int64(payloadBytes)
        sessionVideoBytesReceived = videoBytesReceived
        videoFramesReceived += 1
        if parsedKeyframe {
            keyframesReceived += 1
        }
        lastFrameAt = Date()
        lastVideoFrameAgeSeconds = 0

        if !isConnected {
            isConnected = true
            isConnecting = false
            hasEverConnectedToStream = true
            OverlookLog.info("Direct H.264 first frame received keyframe=\(isKeyframe) parsedKeyframe=\(parsedKeyframe) payloadBytes=\(payloadBytes)")
        }
    }

    private func startStatsTimer(generation: Int) {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStats(generation: generation)
            }
        }
    }

    private func refreshStats(generation: Int) {
        guard generation == self.generation else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsAt)
        guard elapsed > 0 else { return }

        let byteDelta = videoBytesReceived - lastStatsBytes
        let frameDelta = videoFramesReceived - lastStatsFrames
        inboundVideoKbps = Int((Double(byteDelta) * 8.0 / 1000.0 / elapsed).rounded())
        inboundFps = Double(frameDelta) / elapsed
        lastStatsAt = now
        lastStatsBytes = videoBytesReceived
        lastStatsFrames = videoFramesReceived

        if let lastFrameAt {
            let age = Int(now.timeIntervalSince(lastFrameAt).rounded(.down))
            lastVideoFrameAgeSeconds = age
            isStreamStalled = age >= 5
        }
    }

    private func markDisconnected(reason: String) {
        OverlookLog.error(reason)
        lastDisconnectReason = reason
        isConnected = false
        isConnecting = false
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        statsTimer?.invalidate()
        statsTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func resetCounters() {
        videoBytesReceived = 0
        videoFramesReceived = 0
        keyframesReceived = 0
        controlMessagesReceived = 0
        sessionVideoBytesReceived = 0
        lastStatsAt = Date()
        lastStatsBytes = 0
        lastStatsFrames = 0
        lastFrameAt = nil
        h264StartSent = false
        parser.reset()
        inboundVideoKbps = nil
        inboundFps = nil
    }

    private func shouldStartH264(from text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["event_type"] as? String == "media",
              let event = object["event"] as? [String: Any],
              let video = event["video"] as? [String: Any] else {
            return false
        }
        return video["h264"] != nil
    }

    private static let h264StartMessage = #"{"event_type":"start","event":{"type":"video","format":"h264"}}"#
}
