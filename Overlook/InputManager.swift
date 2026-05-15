import Foundation
import Cocoa
import CoreGraphics
import Combine
import SwiftUI

extension Notification.Name {
    static let overlookStartSnippet = Notification.Name("overlook.startSnippet")
    static let overlookCancelSnippet = Notification.Name("overlook.cancelSnippet")
}

@MainActor
class InputManager: ObservableObject {
    private var webRTCManager: WebRTCManager?
    private var glkvmClient: GLKVMClient?
    private var glkvmWebSocketClient: GLKVMClient.WebSocketClient?
    private var keyEventMonitor: Any?
    private var mouseEventMonitor: Any?
    private var appDeactivationObserver: NSObjectProtocol?
    private var isCapturing = false

    private struct PendingAbsoluteMouseMove {
        let toX: Int
        let toY: Int
    }

    private var pendingMouseMove: PendingAbsoluteMouseMove?
    private var lastSentMouseMove: PendingAbsoluteMouseMove?
    private var mouseMoveSenderTask: Task<Void, Never>?
    private static let mouseMoveSendIntervalNs: UInt64 = 4_166_667
    private static let defaultCommandKeyCode: UInt16 = 55

    private var lastCursorDiagLogTime: CFTimeInterval = 0

    private var pendingCommandKeyCode: UInt16?
    private var activeCommandKeyCode: UInt16?
    private var commandKeySentToRemote: Bool = false
    private var suppressedKeyUps: Set<UInt16> = []
    private var passthroughKeyCodes: Set<UInt16> = []
    private var remotePressedModifierKeyCodes: Set<UInt16> = []
    private var locallySuppressedModifierKeyCodes: Set<UInt16> = []
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0
    private static let commandModifierKeyCodes: Set<UInt16> = [55, 54]
    private static let releasableLocalShortcutModifierKeyCodes: Set<UInt16> = [56, 60, 58, 61, 59, 62]
    
    @Published var isKeyboardCaptureEnabled = false
    @Published var isMouseCaptureEnabled = false
    @Published var isSnippetModeActive: Bool = false
    @Published var lastMouseX: Int = 0
    @Published var lastMouseY: Int = 0

    var reverseScrollDirection: Bool {
        get { UserDefaults.standard.bool(forKey: "overlook.input.reverseScroll") }
        set { UserDefaults.standard.set(newValue, forKey: "overlook.input.reverseScroll") }
    }

    var localScrollScale: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "overlook.input.localScrollScale")
            return stored > 0 ? stored : 0.25
        }
        set {
            let clamped = min(max(newValue, 0.05), 2.0)
            objectWillChange.send()
            UserDefaults.standard.set(clamped, forKey: "overlook.input.localScrollScale")
        }
    }

    init() {
        appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.releaseTrackedRemoteModifiersForCaptureStop()
                self.clearOneShotLocalShortcutState()
            }
        }
    }

    enum TransportMode: String, CaseIterable {
        case webRTC
        case glkvmWebSocket
    }

    @Published var transportMode: TransportMode = .glkvmWebSocket

    var agentWebSocketClient: GLKVMClient.WebSocketClient? { glkvmWebSocketClient }
    
    func setSnippetModeActive(_ active: Bool) {
        let wasActive = isSnippetModeActive
        isSnippetModeActive = active
        if active {
            let timestamp = CACurrentMediaTime()
            let modifiers = NSEvent.modifierFlags
            releaseRemoteCommandForLocalShortcut(timestamp: timestamp, modifiers: modifiers)
            releaseRemoteModifiersForLocalShortcut(modifiers: modifiers, timestamp: timestamp)
            clearPendingCommandKey()
        } else if wasActive {
            resyncModifiersAfterSnippetMode()
        }
    }

    func setup(with webRTCManager: WebRTCManager) {
        self.webRTCManager = webRTCManager
    }

    func setGLKVMClient(_ client: GLKVMClient?) {
        glkvmClient = client
        if client == nil {
            disconnectGLKVMWebSocket()
            return
        }
        Task { [weak self] in
            await self?.reconnectGLKVMWebSocketIfNeeded()
        }
    }

    func handleVideoMouseMove(pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?, sourceContentRectInVideo: CGRect? = nil, videoViewLayerInfo: String? = nil) {
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize, sourceContentRectInVideo: sourceContentRectInVideo)
        logCursorDiagnosticsIfDue(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize, sourceContentRectInVideo: sourceContentRectInVideo, normalized: normalized, layerInfo: videoViewLayerInfo)
        let moveEvent = MouseMoveEvent(position: normalized, timestamp: CACurrentMediaTime())
        if transportMode == .glkvmWebSocket {
            enqueueMouseMoveEvent(moveEvent)
        } else {
            sendMouseMoveEvent(moveEvent)
        }
    }

    private func logCursorDiagnosticsIfDue(pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?, sourceContentRectInVideo: CGRect?, normalized: CGPoint, layerInfo: String?) {
        let now = CACurrentMediaTime()
        guard now - lastCursorDiagLogTime >= 0.33 else { return }
        lastCursorDiagLogTime = now
        let (toX, toY) = glkvmAbsolutePoint(fromNormalized: normalized)
        let videoStr = videoSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
        let srcStr: String = sourceContentRectInVideo.map {
            "(\(String(format: "%.3f", $0.minX)),\(String(format: "%.3f", $0.minY)),\(String(format: "%.3f", $0.width)),\(String(format: "%.3f", $0.height)))"
        } ?? "full"
        let layer = layerInfo ?? "n/a"
        OverlookLog.info("cursor-diag view=\(Int(viewSize.width))x\(Int(viewSize.height)) video=\(videoStr) src=\(srcStr) point=(\(String(format: "%.1f", pointInView.x)),\(String(format: "%.1f", pointInView.y))) norm=(\(String(format: "%.4f", normalized.x)),\(String(format: "%.4f", normalized.y))) sent=(\(toX),\(toY)) layer=\(layer)")
    }

    private func enqueueMouseMoveEvent(_ event: MouseMoveEvent) {
        guard isNormalized(event.position) else { return }
        let (toX, toY) = glkvmAbsolutePoint(fromNormalized: event.position)
        pendingMouseMove = PendingAbsoluteMouseMove(toX: toX, toY: toY)
        if mouseMoveSenderTask == nil {
            startMouseMoveSender()
        }
    }

    private func startMouseMoveSender() {
        guard mouseMoveSenderTask == nil else { return }

        let sendIntervalNs = Self.mouseMoveSendIntervalNs

        mouseMoveSenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let snapshot: (move: PendingAbsoluteMouseMove?, mode: TransportMode, ws: GLKVMClient.WebSocketClient?) = await MainActor.run {
                    let e = self.pendingMouseMove
                    self.pendingMouseMove = nil
                    return (e, self.transportMode, self.glkvmWebSocketClient)
                }

                guard let move = snapshot.move else {
                    await MainActor.run {
                        self.mouseMoveSenderTask = nil
                    }
                    return
                }

                if snapshot.mode == .glkvmWebSocket, let ws = snapshot.ws {
                    let shouldSend = await MainActor.run {
                        if self.lastSentMouseMove?.toX == move.toX, self.lastSentMouseMove?.toY == move.toY {
                            return false
                        }
                        self.lastSentMouseMove = move
                        return true
                    }
                    guard shouldSend else { continue }
                    try? await ws.sendHidMouseMove(toX: move.toX, toY: move.toY)
                    await MainActor.run {
                        self.lastMouseX = move.toX
                        self.lastMouseY = move.toY
                    }
                }

                try? await Task.sleep(nanoseconds: sendIntervalNs)
            }
        }
    }

    private func stopMouseMoveSender() {
        pendingMouseMove = nil
        lastSentMouseMove = nil
        mouseMoveSenderTask?.cancel()
        mouseMoveSenderTask = nil
    }

    func handleVideoMouseButton(button: MouseButton, isDown: Bool, pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?, sourceContentRectInVideo: CGRect? = nil) {
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize, sourceContentRectInVideo: sourceContentRectInVideo)
        let buttonEvent = MouseButtonEvent(button: button, isDown: isDown, position: normalized, timestamp: CACurrentMediaTime())
        sendMouseButtonEvent(buttonEvent)
    }

    func handleVideoMouseScroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard isMouseCaptureEnabled else { return }
        let scrollEvent = MouseScrollEvent(deltaX: deltaX, deltaY: deltaY, timestamp: CACurrentMediaTime())
        sendMouseScrollEvent(scrollEvent)
    }

    func setTransportMode(_ mode: TransportMode) {
        transportMode = mode
        switch mode {
        case .webRTC:
            stopMouseMoveSender()
            disconnectGLKVMWebSocket()
        case .glkvmWebSocket:
            Task { [weak self] in
                await self?.reconnectGLKVMWebSocketIfNeeded()
            }
        }
    }

    func disconnectGLKVMWebSocket() {
        stopMouseMoveSender()
        let ws = glkvmWebSocketClient
        glkvmWebSocketClient = nil
        Task {
            await ws?.disconnect()
        }
    }
    
    func startKeyboardCapture() {
        guard keyEventMonitor == nil else {
            isCapturing = true
            isKeyboardCaptureEnabled = true
            return
        }

        isCapturing = true
        isKeyboardCaptureEnabled = true

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.isKeyboardCaptureEnabled else { return event }
            return self.handleKeyEvent(event)
        }
    }
    
    func stopKeyboardCapture() {
        isKeyboardCaptureEnabled = false
        releaseTrackedRemoteModifiersForCaptureStop()
        clearOneShotLocalShortcutState()
        
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        
        if !isMouseCaptureEnabled {
            isCapturing = false
        }
    }
    
    func startMouseCapture() {
        isCapturing = true
        isMouseCaptureEnabled = true
    }
    
    func stopMouseCapture() {
        isMouseCaptureEnabled = false
        
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
        
        if !isKeyboardCaptureEnabled {
            isCapturing = false
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard isKeyboardCaptureEnabled else { return event }

        if isSnippetModeActive {
            return handleKeyEventDuringSnippet(event)
        }

        switch event.type {
        case .keyDown, .keyUp:
            return handleKeyDownOrUp(event)
        case .flagsChanged:
            handleFlagsChanged(event)
            return nil
        default:
            return nil
        }
    }

    private func handleKeyEventDuringSnippet(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 { // Escape
            NotificationCenter.default.post(name: .overlookCancelSnippet, object: nil)
        }

        if event.type == .flagsChanged {
            trackSuppressedModifierDuringSnippet(event)
        }

        if event.type == .keyUp {
            passthroughKeyCodes.remove(event.keyCode)
            suppressedKeyUps.remove(event.keyCode)
        }
        return nil
    }

    private func handleKeyDownOrUp(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode
        let isKeyDown = event.type == .keyDown
        let modifiers = event.modifierFlags

        if !isKeyDown, passthroughKeyCodes.contains(keyCode) {
            passthroughKeyCodes.remove(keyCode)
            return event
        }

        if !isKeyDown, suppressedKeyUps.contains(keyCode) {
            suppressedKeyUps.remove(keyCode)
            return nil
        }

        if isKeyDown {
            switch localActionFor(keyCode: keyCode, modifiers: modifiers) {
            case .some(.passthrough):
                releaseRemoteCommandForLocalShortcut(timestamp: event.timestamp, modifiers: modifiers)
                releaseRemoteModifiersForLocalShortcut(modifiers: modifiers, timestamp: event.timestamp)
                passthroughKeyCodes.insert(keyCode)
                return event
            case .some(.pasteClipboard):
                releaseRemoteCommandForLocalShortcut(timestamp: event.timestamp, modifiers: modifiers)
                releaseRemoteModifiersForLocalShortcut(modifiers: modifiers, timestamp: event.timestamp)
                suppressedKeyUps.insert(keyCode)
                pasteMacClipboardToRemote()
                return nil
            case .some(.startSnippet):
                releaseRemoteCommandForLocalShortcut(timestamp: event.timestamp, modifiers: modifiers)
                releaseRemoteModifiersForLocalShortcut(modifiers: modifiers, timestamp: event.timestamp)
                suppressedKeyUps.insert(keyCode)
                startSnippetOCR()
                return nil
            case .none:
                break
            }
        }

        if isKeyDown {
            resyncSuppressedModifiersIfNeeded(modifiers: modifiers, timestamp: event.timestamp)
        }

        if isKeyDown, modifiers.contains(.command) {
            if let pending = pendingCommandKeyCode,
               commandKeySentToRemote == false,
               transportMode == .glkvmWebSocket,
               let ws = glkvmWebSocketClient,
               let metaKey = glkvmKeyForMacKeyCode(pending),
               let keyName = glkvmKeyForMacKeyCode(keyCode) {
                activeCommandKeyCode = pending
                pendingCommandKeyCode = nil
                commandKeySentToRemote = true
                remotePressedModifierKeyCodes.insert(pending)
                locallySuppressedModifierKeyCodes.remove(pending)

                Task {
                    try? await ws.sendHidKey(key: metaKey, state: true)
                    try? await ws.sendHidKey(key: keyName, state: true)
                }
                return nil
            }

            flushPendingCommandKeyIfNeeded(timestamp: event.timestamp, modifiers: modifiers)
        }

        let keyEvent = KeyEvent(
            keyCode: keyCode,
            isKeyDown: isKeyDown,
            modifiers: modifiers,
            timestamp: event.timestamp
        )

        sendKeyEvent(keyEvent)
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        guard let keyName = glkvmKeyForMacKeyCode(keyCode) else { return }

        let flags = event.modifierFlags
        let isDown: Bool
        switch keyName {
        case "ShiftLeft", "ShiftRight":
            isDown = modifierIsDown(keyCode: keyCode, aggregateFlag: .shift, flags: flags)
        case "ControlLeft", "ControlRight":
            isDown = modifierIsDown(keyCode: keyCode, aggregateFlag: .control, flags: flags)
        case "AltLeft", "AltRight":
            isDown = modifierIsDown(keyCode: keyCode, aggregateFlag: .option, flags: flags)
        case "MetaLeft", "MetaRight":
            isDown = modifierIsDown(keyCode: keyCode, aggregateFlag: .command, flags: flags)
            if isDown {
                pendingCommandKeyCode = nil
                activeCommandKeyCode = keyCode
                commandKeySentToRemote = true
                sendTrackedModifierKeyEvent(
                    keyCode: keyCode,
                    isDown: true,
                    modifiers: flags,
                    timestamp: event.timestamp
                )
                return
            }

            if commandKeySentToRemote {
                sendTrackedModifierKeyEvent(
                    keyCode: activeCommandKeyCode ?? keyCode,
                    isDown: false,
                    modifiers: flags,
                    timestamp: event.timestamp
                )
            }

            clearPendingCommandKey()
            return
        case "CapsLock":
            isDown = flags.contains(.capsLock)
        default:
            return
        }

        sendTrackedModifierKeyEvent(
            keyCode: keyCode,
            isDown: isDown,
            modifiers: flags,
            timestamp: event.timestamp
        )
    }

    private func modifierIsDown(keyCode: UInt16,
                                aggregateFlag: NSEvent.ModifierFlags,
                                flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(aggregateFlag) else { return false }

        if remotePressedModifierKeyCodes.contains(keyCode)
            || locallySuppressedModifierKeyCodes.contains(keyCode)
            || pendingCommandKeyCode == keyCode
            || activeCommandKeyCode == keyCode {
            return false
        }

        return true
    }

    private enum LocalKeyAction {
        case passthrough
        case pasteClipboard
        case startSnippet
    }

    private func localActionFor(keyCode: UInt16,
                                modifiers: NSEvent.ModifierFlags) -> LocalKeyAction? {
        let cKeyCode: UInt16 = 8
        let vKeyCode: UInt16 = 9

        let cmd = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)
        let control = modifiers.contains(.control)

        if cmd, shift {
            if !option, !control, keyCode == vKeyCode {
                return .pasteClipboard
            }
            if !option, !control, keyCode == cKeyCode {
                return .startSnippet
            }
        }

        return nil
    }

    private func clearPendingCommandKey() {
        pendingCommandKeyCode = nil
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func clearOneShotLocalShortcutState() {
        passthroughKeyCodes.removeAll()
        suppressedKeyUps.removeAll()
    }

    private func releaseTrackedRemoteModifiersForCaptureStop() {
        let modifiers = NSEvent.modifierFlags
        let timestamp = CACurrentMediaTime()

        for keyCode in remotePressedModifierKeyCodes.sorted() {
            sendTrackedModifierKeyEvent(
                keyCode: keyCode,
                isDown: false,
                modifiers: modifiers,
                timestamp: timestamp
            )
        }

        locallySuppressedModifierKeyCodes.removeAll()
        clearPendingCommandKey()
    }

    private func resyncModifiersAfterSnippetMode() {
        let modifiers = NSEvent.modifierFlags
        let timestamp = CACurrentMediaTime()
        resyncCommandModifierAfterSnippetMode(modifiers: modifiers)
        resyncSuppressedModifiersIfNeeded(modifiers: modifiers, timestamp: timestamp)
    }

    private func resyncCommandModifierAfterSnippetMode(modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            pendingCommandKeyCode = Self.defaultCommandKeyCode
            activeCommandKeyCode = nil
            commandKeySentToRemote = false
        } else {
            clearPendingCommandKey()
        }
    }

    private func releaseRemoteCommandForLocalShortcut(timestamp: TimeInterval, modifiers: NSEvent.ModifierFlags) {
        if commandKeySentToRemote, let code = activeCommandKeyCode {
            sendTrackedModifierKeyEvent(
                keyCode: code,
                isDown: false,
                modifiers: modifiers,
                timestamp: timestamp
            )
        }

        pendingCommandKeyCode = activeCommandKeyCode ?? pendingCommandKeyCode
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func releaseRemoteModifiersForLocalShortcut(modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        let keyCodes = remotePressedModifierKeyCodes
            .filter { keyCode in
                guard Self.releasableLocalShortcutModifierKeyCodes.contains(keyCode),
                      let flag = modifierFlag(for: keyCode) else { return false }
                return modifiers.contains(flag)
            }
            .sorted()

        for keyCode in keyCodes {
            sendTrackedModifierKeyEvent(
                keyCode: keyCode,
                isDown: false,
                modifiers: modifiers,
                timestamp: timestamp
            )
            locallySuppressedModifierKeyCodes.insert(keyCode)
        }
    }

    private func flushPendingCommandKeyIfNeeded(timestamp: TimeInterval, modifiers: NSEvent.ModifierFlags) {
        guard let pendingCommandKeyCode, commandKeySentToRemote == false else { return }
        activeCommandKeyCode = pendingCommandKeyCode
        self.pendingCommandKeyCode = nil
        commandKeySentToRemote = true

        sendTrackedModifierKeyEvent(
            keyCode: activeCommandKeyCode ?? pendingCommandKeyCode,
            isDown: true,
            modifiers: modifiers,
            timestamp: timestamp
        )
    }

    private func trackSuppressedModifierDuringSnippet(_ event: NSEvent) {
        let keyCode = event.keyCode
        if Self.commandModifierKeyCodes.contains(keyCode) {
            if event.modifierFlags.contains(.command) {
                pendingCommandKeyCode = keyCode
                activeCommandKeyCode = nil
                commandKeySentToRemote = false
            } else if pendingCommandKeyCode == keyCode {
                clearPendingCommandKey()
            }
            return
        }

        guard Self.releasableLocalShortcutModifierKeyCodes.contains(keyCode),
              let flag = modifierFlag(for: keyCode) else { return }

        if event.modifierFlags.contains(flag) {
            locallySuppressedModifierKeyCodes.insert(keyCode)
        } else {
            locallySuppressedModifierKeyCodes.remove(keyCode)
        }
    }

    private func resyncSuppressedModifiersIfNeeded(modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        for keyCode in locallySuppressedModifierKeyCodes.sorted() {
            guard let flag = modifierFlag(for: keyCode) else { continue }
            if modifiers.contains(flag) {
                sendTrackedModifierKeyEvent(
                    keyCode: keyCode,
                    isDown: true,
                    modifiers: modifiers,
                    timestamp: timestamp
                )
            } else {
                locallySuppressedModifierKeyCodes.remove(keyCode)
            }
        }
    }

    private func sendTrackedModifierKeyEvent(keyCode: UInt16,
                                             isDown: Bool,
                                             modifiers: NSEvent.ModifierFlags,
                                             timestamp: TimeInterval) {
        if isDown {
            guard !remotePressedModifierKeyCodes.contains(keyCode) else { return }
            remotePressedModifierKeyCodes.insert(keyCode)
            locallySuppressedModifierKeyCodes.remove(keyCode)
        } else {
            guard remotePressedModifierKeyCodes.contains(keyCode) else {
                locallySuppressedModifierKeyCodes.remove(keyCode)
                return
            }
            remotePressedModifierKeyCodes.remove(keyCode)
            locallySuppressedModifierKeyCodes.remove(keyCode)
        }

        let keyEvent = KeyEvent(
            keyCode: keyCode,
            isKeyDown: isDown,
            modifiers: modifiers,
            timestamp: timestamp
        )
        sendKeyEvent(keyEvent)
    }

    private func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 56, 60:
            return .shift
        case 59, 62:
            return .control
        case 58, 61:
            return .option
        case 55, 54:
            return .command
        case 57:
            return .capsLock
        default:
            return nil
        }
    }

    func startSnippetOCR() {
        NotificationCenter.default.post(name: .overlookStartSnippet, object: nil)
    }

    func pasteMacClipboardToRemote() {
        guard let client = glkvmClient else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                try await client.hidPrint(text: trimmed)
            } catch {
                print("Paste to remote failed: \(error)")
            }
        }
    }
    
    private func handleMouseEvent(_ event: NSEvent) {
        guard isMouseCaptureEnabled else { return }
        
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let mouseEvent = MouseButtonEvent(
                button: event.type == .leftMouseDown || event.type == .leftMouseUp ? .left : .right,
                isDown: event.type == .leftMouseDown || event.type == .rightMouseDown,
                position: CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y),
                timestamp: event.timestamp
            )
            sendMouseButtonEvent(mouseEvent)
            
        case .mouseMoved:
            let mouseEvent = MouseMoveEvent(
                position: CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y),
                timestamp: event.timestamp
            )
            sendMouseMoveEvent(mouseEvent)
            
        case .scrollWheel:
            let scrollEvent = MouseScrollEvent(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                timestamp: event.timestamp
            )
            sendMouseScrollEvent(scrollEvent)
            
        default:
            break
        }
    }
    
    func sendClick(at location: CGPoint, in geometry: GeometryProxy, videoSize: CGSize? = nil, sourceContentRectInVideo: CGRect? = nil) {
        let normalizedPosition = normalizePointInViewToVideo(
            pointInView: location,
            viewSize: geometry.size,
            videoSize: videoSize,
            sourceContentRectInVideo: sourceContentRectInVideo
        )
        
        let clickEvent = MouseButtonEvent(
            button: .left,
            isDown: true,
            position: normalizedPosition,
            timestamp: CACurrentMediaTime()
        )
        
        sendMouseButtonEvent(clickEvent)
        
        // Send release event after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let releaseEvent = MouseButtonEvent(
                button: .left,
                isDown: false,
                position: normalizedPosition,
                timestamp: CACurrentMediaTime()
            )
            self.sendMouseButtonEvent(releaseEvent)
        }
    }
    
    private func sendKeyEvent(_ event: KeyEvent) {
        if transportMode == .glkvmWebSocket,
           let key = glkvmKeyForMacKeyCode(event.keyCode),
           let ws = glkvmWebSocketClient {
            Task {
                try? await ws.sendHidKey(key: key, state: event.isKeyDown)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "keyboard",
            data: [
                "keyCode": .int(Int(event.keyCode)),
                "isKeyDown": .bool(event.isKeyDown),
                "modifiers": .int(Int(event.modifiers.rawValue)),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseButtonEvent(_ event: MouseButtonEvent) {
        if transportMode == .glkvmWebSocket,
           let button = glkvmMouseButtonName(event.button),
           isNormalized(event.position),
           let ws = glkvmWebSocketClient {
            let (toX, toY) = glkvmAbsolutePoint(fromNormalized: event.position)
            Task {
                try? await ws.sendHidMouseMove(toX: toX, toY: toY)
                try? await ws.sendHidMouseButton(button: button, state: event.isDown)
                await MainActor.run {
                    self.lastMouseX = toX
                    self.lastMouseY = toY
                }
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-button",
            data: [
                "button": .int(event.button.rawValue),
                "isDown": .bool(event.isDown),
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseMoveEvent(_ event: MouseMoveEvent) {
        if transportMode == .glkvmWebSocket, isNormalized(event.position), let ws = glkvmWebSocketClient {
            let (toX, toY) = glkvmAbsolutePoint(fromNormalized: event.position)
            Task {
                try? await ws.sendHidMouseMove(toX: toX, toY: toY)
                await MainActor.run {
                    self.lastMouseX = toX
                    self.lastMouseY = toY
                }
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-move",
            data: [
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseScrollEvent(_ event: MouseScrollEvent) {
        if transportMode == .glkvmWebSocket, let ws = glkvmWebSocketClient {
            let multiplier: CGFloat = reverseScrollDirection ? -1 : 1
            scrollRemainderX += event.deltaX * CGFloat(localScrollScale) * multiplier
            scrollRemainderY += event.deltaY * CGFloat(localScrollScale) * multiplier

            let dx = clampInt(Int(scrollRemainderX.rounded(.towardZero)), min: -127, max: 127)
            let dy = clampInt(Int(scrollRemainderY.rounded(.towardZero)), min: -127, max: 127)

            guard dx != 0 || dy != 0 else { return }

            scrollRemainderX -= CGFloat(dx)
            scrollRemainderY -= CGFloat(dy)

            Task {
                try? await ws.sendHidMouseWheel(deltaX: dx, deltaY: dy)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-scroll",
            data: [
                "deltaX": .double(event.deltaX),
                "deltaY": .double(event.deltaY),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    func sendKeyCombination(_ keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        for keyCode in keys {
            let keyDownEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: modifiers,
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyDownEvent)
        }
        
        // Send key up events after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for keyCode in keys.reversed() {
                let keyUpEvent = KeyEvent(
                    keyCode: keyCode,
                    isKeyDown: false,
                    modifiers: modifiers,
                    timestamp: CACurrentMediaTime()
                )
                self.sendKeyEvent(keyUpEvent)
            }
        }
    }
    
    func sendText(_ text: String) {
        for character in text {
            let keyCode = self.keyCodeForCharacter(character)
            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyEvent)
            
            // Send key up event
            let keyUpEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: false,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyUpEvent)
        }
    }
    
    private func keyCodeForCharacter(_ character: Character) -> UInt16 {
        // Basic mapping for common characters
        // In a real implementation, you'd want a more comprehensive mapping
        switch character {
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case " ": return 49
        case "\n": return 36
        case ",": return 43
        case ".": return 47
        case "/": return 44
        case ";": return 41
        case "'": return 39
        case "[": return 33
        case "]": return 30
        case "\\": return 42
        case "`": return 50
        case "-": return 27
        case "=": return 24
        default: return 0
        }
    }
    
    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }

        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }

        if let observer = appDeactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            appDeactivationObserver = nil
        }
    }

    private func reconnectGLKVMWebSocketIfNeeded() async {
        if transportMode != .glkvmWebSocket {
            return
        }
        guard let client = glkvmClient else {
            return
        }

        if glkvmWebSocketClient == nil {
            let ws = try? client.makeWebSocketClient(stream: false)
            glkvmWebSocketClient = ws
            await ws?.connect()
        }
    }

    private func isNormalized(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
    }

    private func glkvmAbsolutePoint(fromNormalized point: CGPoint) -> (Int, Int) {
        let clampedX = max(0, min(1, point.x))
        let clampedY = max(0, min(1, point.y))
        let maxAxis = 32767.0

        let signedX = (clampedX * 2.0 - 1.0) * maxAxis
        let signedY = (clampedY * 2.0 - 1.0) * maxAxis

        return (Int(signedX.rounded()), Int(signedY.rounded()))
    }

    func normalizePointInViewToVideo(pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?, sourceContentRectInVideo: CGRect? = nil) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            let clampedX = max(0, min(1, pointInView.x / viewSize.width))
            let clampedY = max(0, min(1, pointInView.y / viewSize.height))
            return CGPoint(x: clampedX, y: clampedY)
        }

        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height

        var videoRectInView = CGRect(origin: .zero, size: viewSize)
        if viewAspect > videoAspect {
            let contentWidth = viewSize.height * videoAspect
            let xOffset = (viewSize.width - contentWidth) / 2.0
            videoRectInView = CGRect(x: xOffset, y: 0, width: contentWidth, height: viewSize.height)
        } else {
            let contentHeight = viewSize.width / videoAspect
            let yOffset = (viewSize.height - contentHeight) / 2.0
            videoRectInView = CGRect(x: 0, y: yOffset, width: viewSize.width, height: contentHeight)
        }

        let contentRect: CGRect
        if let src = sourceContentRectInVideo,
           src.width > 0, src.height > 0,
           src.minX >= 0, src.minY >= 0,
           src.maxX <= 1.0001, src.maxY <= 1.0001 {
            contentRect = CGRect(
                x: videoRectInView.minX + src.minX * videoRectInView.width,
                y: videoRectInView.minY + src.minY * videoRectInView.height,
                width: src.width * videoRectInView.width,
                height: src.height * videoRectInView.height
            )
        } else {
            contentRect = videoRectInView
        }

        let clampedX = max(contentRect.minX, min(contentRect.maxX, pointInView.x))
        let clampedY = max(contentRect.minY, min(contentRect.maxY, pointInView.y))

        let normalizedX = (clampedX - contentRect.minX) / contentRect.width
        let normalizedY = (clampedY - contentRect.minY) / contentRect.height

        return CGPoint(x: max(0, min(1, normalizedX)), y: max(0, min(1, normalizedY)))
    }

    private func glkvmMouseButtonName(_ button: MouseButton) -> String? {
        switch button {
        case .left:
            return "left"
        case .right:
            return "right"
        case .middle:
            return "middle"
        }
    }

    private func glkvmKeyForMacKeyCode(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "KeyA"
        case 11: return "KeyB"
        case 8: return "KeyC"
        case 2: return "KeyD"
        case 14: return "KeyE"
        case 3: return "KeyF"
        case 5: return "KeyG"
        case 4: return "KeyH"
        case 34: return "KeyI"
        case 38: return "KeyJ"
        case 40: return "KeyK"
        case 37: return "KeyL"
        case 46: return "KeyM"
        case 45: return "KeyN"
        case 31: return "KeyO"
        case 35: return "KeyP"
        case 12: return "KeyQ"
        case 15: return "KeyR"
        case 1: return "KeyS"
        case 17: return "KeyT"
        case 32: return "KeyU"
        case 9: return "KeyV"
        case 13: return "KeyW"
        case 7: return "KeyX"
        case 16: return "KeyY"
        case 6: return "KeyZ"

        case 18: return "Digit1"
        case 19: return "Digit2"
        case 20: return "Digit3"
        case 21: return "Digit4"
        case 23: return "Digit5"
        case 22: return "Digit6"
        case 26: return "Digit7"
        case 28: return "Digit8"
        case 25: return "Digit9"
        case 29: return "Digit0"

        case 50: return "Backquote"
        case 27: return "Minus"
        case 24: return "Equal"
        case 33: return "BracketLeft"
        case 30: return "BracketRight"
        case 41: return "Semicolon"
        case 39: return "Quote"
        case 42: return "Backslash"
        case 43: return "Comma"
        case 47: return "Period"
        case 44: return "Slash"

        case 49: return "Space"
        case 48: return "Tab"
        case 36: return "Enter"
        case 51: return "Backspace"
        case 53: return "Escape"

        case 82: return "Digit0"
        case 83: return "Digit1"
        case 84: return "Digit2"
        case 85: return "Digit3"
        case 86: return "Digit4"
        case 87: return "Digit5"
        case 88: return "Digit6"
        case 89: return "Digit7"
        case 91: return "Digit8"
        case 92: return "Digit9"
        case 65: return "Period"
        case 67: return "NumpadMultiply"
        case 69: return "NumpadAdd"
        case 78: return "NumpadSubtract"
        case 75: return "NumpadDivide"
        case 76: return "Enter"
        case 81: return "NumpadEqual"

        case 114: return "Help"

        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 117: return "Delete"

        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"

        case 55: return "MetaLeft"
        case 54: return "MetaRight"
        case 56: return "ShiftLeft"
        case 60: return "ShiftRight"
        case 58: return "AltLeft"
        case 61: return "AltRight"
        case 59: return "ControlLeft"
        case 62: return "ControlRight"
        case 57: return "CapsLock"

        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"

        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"

        default:
            return nil
        }
    }

    private func clampInt(_ value: Int, min: Int, max: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}

// MARK: - Input Event Types
struct KeyEvent {
    let keyCode: UInt16
    let isKeyDown: Bool
    let modifiers: NSEvent.ModifierFlags
    let timestamp: CFTimeInterval
}

struct MouseButtonEvent {
    let button: MouseButton
    let isDown: Bool
    let position: CGPoint
    let timestamp: CFTimeInterval
}

struct MouseMoveEvent {
    let position: CGPoint
    let timestamp: CFTimeInterval
}

struct MouseScrollEvent {
    let deltaX: CGFloat
    let deltaY: CGFloat
    let timestamp: CFTimeInterval
}

enum MouseButton: Int, Codable {
    case left = 0
    case right = 1
    case middle = 2
}

// MARK: - Input Capture Extensions
extension InputManager {
    func toggleKeyboardCapture() {
        if isKeyboardCaptureEnabled {
            stopKeyboardCapture()
        } else {
            startKeyboardCapture()
        }
    }
    
    func toggleMouseCapture() {
        if isMouseCaptureEnabled {
            stopMouseCapture()
        } else {
            startMouseCapture()
        }
    }
    
    func startFullInputCapture() {
        startKeyboardCapture()
        startMouseCapture()
    }
    
    func stopFullInputCapture() {
        stopKeyboardCapture()
        stopMouseCapture()
    }
}

// MARK: - Accessibility Permissions Helper
extension InputManager {
    func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func showAccessibilityPermissionDialog() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Required"
        alert.informativeText = "Overlook needs accessibility permissions to capture keyboard and mouse input for remote control. Please grant permissions in System Preferences > Security & Privacy > Privacy > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Preferences to Accessibility section
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Input Validation and Filtering
extension InputManager {
    private func shouldCaptureKeyEvent(_ event: NSEvent) -> Bool {
        // Filter out system key combinations that should remain local
        let systemKeyCombinations: [UInt16] = [
            55, // Command
            56, // Shift
            57, // Option
            58, // Control
            59, // Caps Lock
            60, // Function
        ]
        
        return !systemKeyCombinations.contains(event.keyCode)
    }
    
    private func shouldCaptureMouseEvent(_ event: NSEvent) -> Bool {
        // Filter out mouse events that should remain local
        // This is a basic implementation - you might want to add more sophisticated filtering
        return true
    }
}
