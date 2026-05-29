import Foundation
import CoreGraphics
#if canImport(CoreVideo)
import CoreVideo
#endif

enum VideoPlaybackBackendKind: String, CaseIterable, Identifiable {
    case webRTC = "webrtc"
    case directH264 = "direct-h264"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .webRTC:
            return "WebRTC"
        case .directH264:
            return "Direct H.264"
        }
    }
}

@MainActor
protocol VideoPlaybackFrameSource: AnyObject {
    var currentFrame: CVPixelBuffer? { get }
    var videoSize: CGSize? { get }
    var sourceContentRectInVideo: CGRect? { get }

    func setFrameCaptureEnabled(_ enabled: Bool)
    func captureCurrentFrame(timeout: TimeInterval) async -> CVPixelBuffer?
}

@MainActor
protocol VideoPlaybackStatusProviding: VideoPlaybackFrameSource {
    var backendKind: VideoPlaybackBackendKind { get }
    var isConnected: Bool { get }
    var isConnecting: Bool { get }
    var hasEverConnectedToStream: Bool { get }
    var isStreamStalled: Bool { get }
    var lastDisconnectReason: String? { get }
    var lastVideoFrameAgeSeconds: Int? { get }
    var latency: Int { get }

    var inboundVideoKbps: Int? { get }
    var inboundFps: Double? { get }
    var inboundVideoPlayoutDelayMs: Int? { get }
    var inboundVideoJitterMs: Int? { get }
    var inboundVideoDecodeMs: Int? { get }
    var inboundVideoPacketsLost: Int? { get }
    var iceCurrentRoundTripTimeMs: Int? { get }
    var sessionVideoBytesReceived: Int64? { get }
}

@MainActor
protocol VideoPlaybackBackend: VideoPlaybackStatusProviding {
    func connect(to device: KVMDevice) async throws
    func reconnect(to device: KVMDevice) async
    func disconnect()
}
