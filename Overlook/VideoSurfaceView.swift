import SwiftUI
import AppKit
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(WebRTC)
import WebRTC
#endif

struct VideoSurfaceView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var ocrManager: OCRManager

    let onReconnect: () -> Void

    @State private var isSnippetModeActive: Bool = false
    @State private var snippetDragStart: CGPoint?
    @State private var snippetDragCurrent: CGPoint?
    @State private var snippetHUDMessage: String?
    @State private var snippetHUDHideTask: Task<Void, Never>?
    @State private var snippetOCRTask: Task<Void, Never>?
    @State private var snippetOCRRequestID: UUID?

    @State private var isHoveringStream = false
    @AppStorage(TrackingContainerView.hideSystemCursorDefaultsKey) private var hideSystemCursorOverStream: Bool = false

    private var snippetSelectionRect: CGRect? {
        guard let start = snippetDragStart, let current = snippetDragCurrent else { return nil }
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let width = abs(start.x - current.x)
        let height = abs(start.y - current.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

#if canImport(WebRTC)
                if let videoView = webRTCManager.videoView {
                    VideoViewRepresentable(
                        videoView: videoView,
                        onMouseMove: { pointInView in
                            guard !isSnippetModeActive else { return }
                            inputManager.handleVideoMouseMove(
                                pointInView: pointInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize()
                            )
                        },
                        onMouseMoveWithLayerInfo: { pointInView, layerInfo in
                            guard !isSnippetModeActive else { return }
                            inputManager.handleVideoMouseMove(
                                pointInView: pointInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize(),
                                videoViewLayerInfo: layerInfo
                            )
                        },
                        onMouseButton: { button, isDown, pointInView in
                            guard !isSnippetModeActive else { return }
                            inputManager.handleVideoMouseButton(
                                button: button,
                                isDown: isDown,
                                pointInView: pointInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize()
                            )
                        },
                        onScrollWheel: { deltaX, deltaY in
                            guard !isSnippetModeActive else { return }
                            inputManager.handleVideoMouseScroll(deltaX: deltaX, deltaY: deltaY)
                        }
                    )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Text("No Video Stream")
                        .foregroundColor(.white)
                }
#else
                Text("WebRTC not installed")
                    .foregroundColor(.white)
#endif

                if isSnippetModeActive {
                    SnippetSelectionOverlay(
                        selectionRectInView: snippetSelectionRect,
                        viewSize: geometry.size
                    )

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if snippetDragStart == nil {
                                        snippetDragStart = value.startLocation
                                    }
                                    snippetDragCurrent = value.location
                                }
                                .onEnded { value in
                                    let location = value.location
                                    let start = snippetDragStart ?? value.startLocation
                                    let dx = location.x - start.x
                                    let dy = location.y - start.y
                                    let distance = hypot(dx, dy)

                                    if let rect = snippetSelectionRect,
                                       distance >= 8,
                                       rect.width > 4,
                                       rect.height > 4 {
                                        performSnippetOCR(inViewRect: rect, in: geometry)
                                    } else {
                                        exitSnippetMode()
                                    }

                                    snippetDragStart = nil
                                    snippetDragCurrent = nil
                                }
                        )
                }

                if let message = snippetHUDMessage {
                    VStack {
                        SnippetHUD(message: message)
                            .padding(.top, 24)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if isShowingStatusOverlay {
                    VStack(spacing: 10) {
                        Text(webRTCManager.isConnecting ? "Connecting…" : "Connection Lost")
                            .font(.headline)

                        if let reason = webRTCManager.lastDisconnectReason, !reason.isEmpty {
                            Text(reason)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        if let age = webRTCManager.lastVideoFrameAgeSeconds, webRTCManager.isConnecting == false {
                            Text("Last video frame: \(age)s ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Reconnect") {
                            onReconnect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(webRTCManager.isConnecting)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let rect = videoContentRect(viewSize: geometry.size)
                    let isInsideStream = rect.contains(location)
                    if isHoveringStream != isInsideStream {
                        isHoveringStream = isInsideStream
                        StreamCursorHider.shared.update(shouldHide: shouldHideCursor)
                    }
                case .ended:
                    if isHoveringStream {
                        isHoveringStream = false
                        StreamCursorHider.shared.update(shouldHide: shouldHideCursor)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlookStartSnippet)) { _ in
            if !isSnippetModeActive {
                enterSnippetMode()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlookCancelSnippet)) { _ in
            exitSnippetMode()
        }
        .onDisappear {
            exitSnippetMode()
            snippetHUDHideTask?.cancel()
            snippetHUDHideTask = nil
            snippetHUDMessage = nil
            isHoveringStream = false
            StreamCursorHider.shared.update(shouldHide: false)
        }
        .onChange(of: hideSystemCursorOverStream) { _, _ in
            StreamCursorHider.shared.update(shouldHide: shouldHideCursor)
        }
        .onChange(of: isShowingStatusOverlay) { _, _ in
            StreamCursorHider.shared.update(shouldHide: shouldHideCursor)
        }
    }

    private var isShowingStatusOverlay: Bool {
        webRTCManager.isConnecting
            || webRTCManager.isStreamStalled
            || (webRTCManager.hasEverConnectedToStream && !webRTCManager.isConnected)
    }

    private var shouldHideCursor: Bool {
        isHoveringStream && hideSystemCursorOverStream && !isShowingStatusOverlay
    }

    private func videoContentRect(viewSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0,
              let videoSize = currentVideoSize(),
              videoSize.width > 0, videoSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height
        if viewAspect > videoAspect {
            let contentWidth = viewSize.height * videoAspect
            let xOffset = (viewSize.width - contentWidth) / 2.0
            return CGRect(x: xOffset, y: 0, width: contentWidth, height: viewSize.height)
        } else {
            let contentHeight = viewSize.width / videoAspect
            let yOffset = (viewSize.height - contentHeight) / 2.0
            return CGRect(x: 0, y: yOffset, width: viewSize.width, height: contentHeight)
        }
    }

    private func enterSnippetMode() {
        snippetDragStart = nil
        snippetDragCurrent = nil
        isSnippetModeActive = true
        inputManager.setSnippetModeActive(true)
        webRTCManager.setFrameCaptureEnabled(true)
    }

    private func exitSnippetMode() {
        snippetOCRTask?.cancel()
        snippetOCRTask = nil
        snippetOCRRequestID = nil

        guard isSnippetModeActive else { return }
        isSnippetModeActive = false
        snippetDragStart = nil
        snippetDragCurrent = nil
        inputManager.setSnippetModeActive(false)
        webRTCManager.setFrameCaptureEnabled(false)
    }

    private func currentVideoSize() -> CGSize? {
        if let size = webRTCManager.videoSize, size.width > 0, size.height > 0 {
            return size
        }

        guard let pixelBuffer = webRTCManager.currentFrame else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if width <= 0 || height <= 0 {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func performSnippetOCR(inViewRect rect: CGRect, in geometry: GeometryProxy) {
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)

        let n1 = inputManager.normalizePointInViewToVideo(
            pointInView: topLeft,
            viewSize: geometry.size,
            videoSize: currentVideoSize()
        )
        let n2 = inputManager.normalizePointInViewToVideo(
            pointInView: bottomRight,
            viewSize: geometry.size,
            videoSize: currentVideoSize()
        )

        let v1 = CGPoint(x: n1.x, y: 1.0 - n1.y)
        let v2 = CGPoint(x: n2.x, y: 1.0 - n2.y)

        let minX = max(0, min(v1.x, v2.x))
        let minY = max(0, min(v1.y, v2.y))
        let maxX = min(1, max(v1.x, v2.x))
        let maxY = min(1, max(v1.y, v2.y))

        let region = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        guard region.width > 0.001, region.height > 0.001 else {
            exitSnippetMode()
            return
        }

        let frame = webRTCManager.currentFrame

        snippetOCRTask?.cancel()
        let requestID = UUID()
        snippetOCRRequestID = requestID

        snippetOCRTask = Task {
            do {
                let text = try await ocrManager.recognizeTextInRegion(region, in: frame)
                try Task.checkCancellation()
                await MainActor.run {
                    guard snippetOCRRequestID == requestID, isSnippetModeActive else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    snippetOCRTask = nil
                    snippetOCRRequestID = nil
                    guard !trimmed.isEmpty else {
                        showSnippetHUD("No text found")
                        exitSnippetMode()
                        return
                    }

                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trimmed, forType: .string)
                    showSnippetHUD("Text copied")
                    exitSnippetMode()
                }
            } catch is CancellationError {
                return
            } catch OCRError.noTextFound {
                await MainActor.run {
                    guard snippetOCRRequestID == requestID, isSnippetModeActive else { return }
                    snippetOCRTask = nil
                    snippetOCRRequestID = nil
                    showSnippetHUD("No text found")
                    exitSnippetMode()
                }
            } catch {
                print("Snippet OCR failed: \(error)")
                await MainActor.run {
                    guard snippetOCRRequestID == requestID, isSnippetModeActive else { return }
                    snippetOCRTask = nil
                    snippetOCRRequestID = nil
                    showSnippetHUD("OCR failed")
                    exitSnippetMode()
                }
            }
        }
    }

    private func showSnippetHUD(_ message: String) {
        snippetHUDHideTask?.cancel()
        withAnimation(.easeIn(duration: 0.1)) {
            snippetHUDMessage = message
        }
        snippetHUDHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                snippetHUDMessage = nil
            }
        }
    }
}

#if canImport(WebRTC)
struct VideoViewRepresentable: NSViewRepresentable {
    let videoView: RTCMTLNSVideoView
    let onMouseMove: (CGPoint) -> Void
    let onMouseMoveWithLayerInfo: ((CGPoint, String) -> Void)?
    let onMouseButton: (MouseButton, Bool, CGPoint) -> Void
    let onScrollWheel: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> TrackingContainerView {
        let container = TrackingContainerView()
        container.onMouseMove = onMouseMove
        container.onMouseMoveWithLayerInfo = onMouseMoveWithLayerInfo
        container.onMouseButton = onMouseButton
        container.onScrollWheel = onScrollWheel
        container.embedVideoViewIfNeeded(videoView)
        return container
    }

    func updateNSView(_ nsView: TrackingContainerView, context: Context) {
        nsView.onMouseMove = onMouseMove
        nsView.onMouseMoveWithLayerInfo = onMouseMoveWithLayerInfo
        nsView.onMouseButton = onMouseButton
        nsView.onScrollWheel = onScrollWheel
        nsView.embedVideoViewIfNeeded(videoView)
    }
}

final class TrackingContainerView: NSView {
    var onMouseMove: ((CGPoint) -> Void)?
    var onMouseMoveWithLayerInfo: ((CGPoint, String) -> Void)?
    var onMouseButton: ((MouseButton, Bool, CGPoint) -> Void)?
    var onScrollWheel: ((CGFloat, CGFloat) -> Void)?

    static let hideSystemCursorDefaultsKey = "overlook.hideSystemCursorOverStream"

    private var trackingAreaRef: NSTrackingArea?

    private weak var embeddedVideoView: RTCMTLNSVideoView?
    private var embeddedConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .inVisibleRect,
            .mouseMoved,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func embedVideoViewIfNeeded(_ videoView: RTCMTLNSVideoView) {
        guard embeddedVideoView !== videoView else { return }

        if !embeddedConstraints.isEmpty {
            NSLayoutConstraint.deactivate(embeddedConstraints)
            embeddedConstraints.removeAll()
        }

        embeddedVideoView?.removeFromSuperview()
        embeddedVideoView = videoView

        videoView.removeFromSuperview()
        addSubview(videoView)

        videoView.translatesAutoresizingMaskIntoConstraints = false
        embeddedConstraints = [
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(embeddedConstraints)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)

        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        if let cb = onMouseMoveWithLayerInfo {
            cb(flipped, describeVideoViewGeometry())
        } else {
            onMouseMove?(flipped)
        }
    }

    private func describeVideoViewGeometry() -> String {
        guard let videoView = embeddedVideoView else { return "noVideoView" }
        let vb = videoView.bounds
        var parts = ["videoBounds=\(Int(vb.width))x\(Int(vb.height))@(\(Int(vb.minX)),\(Int(vb.minY)))"]
        if let layer = videoView.layer {
            parts.append("layerFrame=\(Int(layer.frame.width))x\(Int(layer.frame.height))@(\(Int(layer.frame.minX)),\(Int(layer.frame.minY)))")
            parts.append("contentsGravity=\(layer.contentsGravity.rawValue)")
            for (i, sub) in (layer.sublayers ?? []).enumerated() {
                parts.append("subLayer[\(i)]=\(type(of: sub))/\(Int(sub.frame.width))x\(Int(sub.frame.height))@(\(Int(sub.frame.minX)),\(Int(sub.frame.minY)))/g=\(sub.contentsGravity.rawValue)")
            }
        }
        for (i, sub) in videoView.subviews.enumerated() {
            let f = sub.frame
            parts.append("subView[\(i)]=\(type(of: sub))/\(Int(f.width))x\(Int(f.height))@(\(Int(f.minX)),\(Int(f.minY)))")
        }
        return parts.joined(separator: " ")
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.left, true, flipped)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.left, false, flipped)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.right, true, flipped)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.right, false, flipped)
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        guard event.buttonNumber == 2 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.middle, true, flipped)
    }

    override func otherMouseUp(with event: NSEvent) {
        super.otherMouseUp(with: event)
        guard event.buttonNumber == 2 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.middle, false, flipped)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseMove?(flipped)
    }

    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseMove?(flipped)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScrollWheel?(event.scrollingDeltaX, event.scrollingDeltaY)
    }
}
#endif

@MainActor
final class StreamCursorHider {
    static let shared = StreamCursorHider()

    private var hidden = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.update(shouldHide: false) }
        }
    }

    func update(shouldHide: Bool) {
        if shouldHide && !hidden {
            NSCursor.hide()
            hidden = true
        } else if !shouldHide && hidden {
            NSCursor.unhide()
            hidden = false
        }
    }
}
