# Remote Key Routing & Snippet OCR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward every `cmd+*` combo to the remote except `cmd+Tab`, `option+Tab`, and `cmd+shift+*`; replace the OCR-mode toggle with a one-shot `cmd+shift+C` snippet tool that OCRs a drag-selected region of the remote video and copies the text to the Mac clipboard.

**Architecture:** Extend the existing `NSEvent.addLocalMonitorForEvents`-based `InputManager` with a whitelist returning `passthrough | pasteClipboard | startSnippet` for the three exception classes. Replace the toggled OCR overlay with a transient `isSnippetModeActive` state in `VideoSurfaceView` that drives a simpler drag-rectangle overlay, runs `OCRManager.recognizeTextInRegion` on drag-end, and shows a brief HUD toast before auto-exiting. All other OCR UI (toolbar button, result sheet, live-text boxes, menu-bar shortcut, periodic detection task) is removed.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Apple Vision framework (`VNRecognizeTextRequest`), WebRTC video frames (`CVPixelBuffer`).

**Spec:** [docs/superpowers/specs/2026-05-07-remote-key-routing-and-snippet-ocr-design.md](../specs/2026-05-07-remote-key-routing-and-snippet-ocr-design.md)

**Note on testing:** The repo has no unit-test harness and the logic lives in event/view layers that are hard to isolate, so each task uses a build-then-manual-verify loop via `./build.sh -c debug` against a live GLKVM device. Where behavior can only be observed end-to-end, verification is deferred to the final smoke-test task.

---

## File Structure

Files modified:

- `Overlook/InputManager.swift` — key routing, new `setSnippetModeActive`, new notification names, new `localActionFor` helper.
- `Overlook/VideoSurfaceView.swift` — swap OCR-mode state for snippet-mode state, drop periodic detect-task, drop old OCR bindings, add HUD toast.
- `Overlook/ContentView.swift` — drop OCR-related `@State`/bindings/toolbar buttons/result sheet.
- `Overlook/MenuBarAgent.swift` — drop `cmd+shift+O` global shortcut handler and the "Enable OCR" menu item.
- `Overlook/OCRManager.swift` — trim to a single region-based OCR path.
- `Overlook/OCRViews.swift` — replace contents with `SnippetSelectionOverlay` + `SnippetHUD`. File name kept to avoid `project.pbxproj` edits.
- `README.md` — update the keyboard-shortcut and OCR sections.

No new files are created; no Xcode project-file edits are needed.

---

## Task 1: Extend InputManager with snippet-mode state and new notification names (additive)

**Purpose:** Land the API that later tasks depend on without changing any runtime behavior yet.

**Files:**
- Modify: `Overlook/InputManager.swift`

- [ ] **Step 1.1: Add the new notification names**

Edit `Overlook/InputManager.swift` lines 7–9. Replace:

```swift
extension Notification.Name {
    static let overlookToggleCopyMode = Notification.Name("overlook.toggleCopyMode")
}
```

with:

```swift
extension Notification.Name {
    // TODO(task 6): remove once no caller/listener references it.
    static let overlookToggleCopyMode = Notification.Name("overlook.toggleCopyMode")
    static let overlookStartSnippet = Notification.Name("overlook.startSnippet")
    static let overlookCancelSnippet = Notification.Name("overlook.cancelSnippet")
}
```

- [ ] **Step 1.2: Add the `isSnippetModeActive` published state and setter**

Inside the `InputManager` class, directly below the existing `@Published var isMouseCaptureEnabled = false` (around `Overlook/InputManager.swift:38`), add:

```swift
    @Published var isSnippetModeActive: Bool = false
```

Then, as a new public method immediately above the `func setup(with webRTCManager:` declaration (around `Overlook/InputManager.swift:47`), add:

```swift
    func setSnippetModeActive(_ active: Bool) {
        isSnippetModeActive = active
        if active {
            pendingCommandKeyCode = nil
            activeCommandKeyCode = nil
            commandKeySentToRemote = false
        }
    }
```

- [ ] **Step 1.3: Verify the project still compiles**

Run:

```bash
./build.sh -c debug
```

Expected: `BUILD SUCCEEDED` and `Copied Overlook Debug.app -> build/debug/`. No new warnings other than possible "unused" hints for `isSnippetModeActive` (it is `@Published`, so the warning should not fire).

- [ ] **Step 1.4: Commit**

```bash
git add Overlook/InputManager.swift
git commit -m "Add snippet-mode hook and notifications to InputManager"
```

---

## Task 2: Rewrite key-event routing with the local-whitelist rule

**Purpose:** Make `cmd+C`/`cmd+V` forward to the remote, keep `cmd+Tab`/`option+Tab`/`cmd+shift+*` local, and wire `cmd+shift+V`/`cmd+shift+C` to their local actions. No consumers of `.overlookStartSnippet` exist yet, so `cmd+shift+C` will appear to do nothing at runtime — that is expected until Task 4.

**Files:**
- Modify: `Overlook/InputManager.swift`

- [ ] **Step 2.1: Change the key-event monitor closure so it honors the new return value**

Replace the body of `startKeyboardCapture()` (currently `Overlook/InputManager.swift:177-192`) with:

```swift
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
```

- [ ] **Step 2.2: Rewrite `handleKeyEvent` so it returns `NSEvent?` and applies the new rule**

Replace the entire method body of `handleKeyEvent` (currently `Overlook/InputManager.swift:225-333`). The new method signature returns `NSEvent?` (`nil` = consume, `event` = pass through to the OS), and it delegates to two private helpers.

Paste in place of the existing method:

```swift
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
        return nil
    }

    private func handleKeyDownOrUp(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode
        let isKeyDown = event.type == .keyDown
        let modifiers = event.modifierFlags

        if !isKeyDown, suppressedKeyUps.contains(keyCode) {
            suppressedKeyUps.remove(keyCode)
            return nil
        }

        if isKeyDown {
            switch localActionFor(keyCode: keyCode, modifiers: modifiers) {
            case .some(.passthrough):
                clearPendingCommandKey()
                suppressedKeyUps.insert(keyCode)
                return event
            case .some(.pasteClipboard):
                clearPendingCommandKey()
                suppressedKeyUps.insert(keyCode)
                pasteClipboardToRemote()
                return nil
            case .some(.startSnippet):
                clearPendingCommandKey()
                suppressedKeyUps.insert(keyCode)
                NotificationCenter.default.post(name: .overlookStartSnippet, object: nil)
                return nil
            case .none:
                break
            }
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
            isDown = flags.contains(.shift)
        case "ControlLeft", "ControlRight":
            isDown = flags.contains(.control)
        case "AltLeft", "AltRight":
            isDown = flags.contains(.option)
        case "MetaLeft", "MetaRight":
            isDown = flags.contains(.command)
            if isDown {
                pendingCommandKeyCode = keyCode
                activeCommandKeyCode = nil
                commandKeySentToRemote = false
                return
            }

            if commandKeySentToRemote {
                let keyEvent = KeyEvent(
                    keyCode: activeCommandKeyCode ?? keyCode,
                    isKeyDown: false,
                    modifiers: flags,
                    timestamp: event.timestamp
                )
                sendKeyEvent(keyEvent)
            }

            clearPendingCommandKey()
            return
        case "CapsLock":
            isDown = flags.contains(.capsLock)
        default:
            return
        }

        let keyEvent = KeyEvent(
            keyCode: keyCode,
            isKeyDown: isDown,
            modifiers: flags,
            timestamp: event.timestamp
        )
        sendKeyEvent(keyEvent)
    }

    private enum LocalKeyAction {
        case passthrough
        case pasteClipboard
        case startSnippet
    }

    private func localActionFor(keyCode: UInt16,
                                modifiers: NSEvent.ModifierFlags) -> LocalKeyAction? {
        let tabKeyCode: UInt16 = 48
        let cKeyCode: UInt16 = 8
        let vKeyCode: UInt16 = 9

        let cmd = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)
        let control = modifiers.contains(.control)

        if keyCode == tabKeyCode, cmd, !shift, !control, !option {
            return .passthrough
        }

        if keyCode == tabKeyCode, option, !cmd, !shift, !control {
            return .passthrough
        }

        if cmd, shift {
            if keyCode == vKeyCode {
                return .pasteClipboard
            }
            if keyCode == cKeyCode {
                return .startSnippet
            }
            return .passthrough
        }

        return nil
    }
```

This preserves the existing `.flagsChanged` logic verbatim (now extracted into `handleFlagsChanged`) and keeps the cmd-buffering behavior so that local `cmd+shift+*` combos never forward cmd to the remote. Plain `cmd+C` and `cmd+V` fall through to the remote-forwarding path, exactly like every other `cmd+letter` combo already does today.

- [ ] **Step 2.3: Verify the build**

Run:

```bash
./build.sh -c debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2.4: Manual smoke test (routing only, not the snippet UI)**

Open the built app (`open build/debug/Overlook Debug.app`), connect to a GLKVM device, ensure keyboard capture is active, then:

- Press `cmd+C` with a terminal focused on the remote. Expected: remote receives `Meta+C` (observe via remote-side echo / selection-copy / etc., whatever fits your device). The Mac clipboard should NOT change.
- Press `cmd+V` with a remote text field focused. Expected: remote receives `Meta+V`. The old "type Mac clipboard as HID text" behavior is gone.
- Press `cmd+shift+V` with something in the Mac clipboard and a remote text field focused. Expected: the Mac clipboard text is typed into the remote (HID print path). This is the old `cmd+V` behavior, now on a new shortcut.
- Press `cmd+Tab`. Expected: macOS app switcher engages; remote should not receive a `Tab` key. (A transient cmd-down may be observed on some remotes — harmless; it clears when you release cmd.)
- Press `option+Tab`. Expected: passes through locally (may be captured by a third-party switcher like Raycast); remote should not receive it.
- Press `cmd+shift+O`. Expected: no effect (the old OCR toggle via the menu-bar agent only fires when Overlook is NOT focused; the menu item in the menu bar is still present but will be removed in Task 5).
- Press `cmd+shift+C`. Expected: nothing visible yet — the notification fires but nothing listens yet. This is wired in Task 4.

If any of the above fails, go back to Step 2.2 and fix before committing.

- [ ] **Step 2.5: Commit**

```bash
git add Overlook/InputManager.swift
git commit -m "Route cmd+C/cmd+V to remote; add local whitelist for cmd+Tab, option+Tab, cmd+shift+*"
```

---

## Task 3: Add `SnippetSelectionOverlay` and `SnippetHUD` views

**Purpose:** Land the two new SwiftUI views used by the snippet flow. They are unused until Task 4.

**Files:**
- Modify: `Overlook/OCRViews.swift`

- [ ] **Step 3.1: Append the new views without removing old types yet**

Open `Overlook/OCRViews.swift` and append, at the very end of the file:

```swift
struct SnippetSelectionOverlay: View {
    let selectionRectInView: CGRect?
    let viewSize: CGSize

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)

            if let selectionRectInView {
                Rectangle()
                    .fill(Color.blue.opacity(0.12))
                    .overlay(
                        Rectangle().stroke(Color.blue.opacity(0.9), lineWidth: 2)
                    )
                    .frame(width: selectionRectInView.width, height: selectionRectInView.height)
                    .position(x: selectionRectInView.midX, y: selectionRectInView.midY)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(false)
    }
}

struct SnippetHUD: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(radius: 4)
    }
}
```

Leave `OCRSelectionOverlay` and `OCRResultView` alone for now — they are removed in Task 6.

- [ ] **Step 3.2: Verify the build**

```bash
./build.sh -c debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3.3: Commit**

```bash
git add Overlook/OCRViews.swift
git commit -m "Add SnippetSelectionOverlay and SnippetHUD views"
```

---

## Task 4: Swap OCR-mode for snippet-mode in VideoSurfaceView and ContentView

**Purpose:** Replace the old toggleable OCR overlay + result sheet with the new one-shot snippet flow. The edits to `VideoSurfaceView.swift` and `ContentView.swift` have to ship together because the view's external API changes.

**Files:**
- Modify: `Overlook/VideoSurfaceView.swift`
- Modify: `Overlook/ContentView.swift`

- [ ] **Step 4.1: Rewrite the `VideoSurfaceView` struct header, state, and body**

Replace the contents of `Overlook/VideoSurfaceView.swift` from `struct VideoSurfaceView: View {` (line 10) through the end of its `body` property (ending at line 196 — the closing `}` right before `private var isShowingStatusOverlay: Bool {`). Paste:

```swift
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
                                videoSize: currentVideoSize(),
                                sourceContentRectInVideo: webRTCManager.sourceContentRectInVideo
                            )
                        },
                        onMouseMoveWithLayerInfo: { pointInView, layerInfo in
                            guard !isSnippetModeActive else { return }
                            inputManager.handleVideoMouseMove(
                                pointInView: pointInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize(),
                                sourceContentRectInVideo: webRTCManager.sourceContentRectInVideo,
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
                                videoSize: currentVideoSize(),
                                sourceContentRectInVideo: webRTCManager.sourceContentRectInVideo
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
```

- [ ] **Step 4.2: Replace `setOCRMode` / `performOCR(at:in:)` / `performOCR(inViewRect:in:)` with the new snippet helpers**

In `Overlook/VideoSurfaceView.swift`, find the block that starts with `private func setOCRMode(_ enabled: Bool) {` and extends through the closing `}` of the last `performOCR(inViewRect:in:)` method (old lines 227–321). Replace that whole block with:

```swift
    private func enterSnippetMode() {
        snippetDragStart = nil
        snippetDragCurrent = nil
        isSnippetModeActive = true
        inputManager.setSnippetModeActive(true)
        webRTCManager.setFrameCaptureEnabled(true)
    }

    private func exitSnippetMode() {
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

        Task {
            do {
                let text = try await ocrManager.recognizeTextInRegion(region, in: frame)
                await MainActor.run {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        showSnippetHUD("Kein Text erkannt")
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(trimmed, forType: .string)
                        showSnippetHUD("Text kopiert")
                    }
                    exitSnippetMode()
                }
            } catch OCRError.noTextFound {
                await MainActor.run {
                    showSnippetHUD("Kein Text erkannt")
                    exitSnippetMode()
                }
            } catch {
                print("Snippet OCR failed: \(error)")
                await MainActor.run {
                    showSnippetHUD("OCR fehlgeschlagen")
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
```

- [ ] **Step 4.3: Keep the `videoContentRect` and `isShowingStatusOverlay` / `shouldHideCursor` helpers unchanged**

Those helpers live right below the body in the existing file and are still used. Do not edit them. After the block replacement they should sit directly above `enterSnippetMode`.

- [ ] **Step 4.4: Update `ContentView` call sites to the new `VideoSurfaceView` signature**

Open `Overlook/ContentView.swift`.

Delete these three OCR `@State` declarations. They are interleaved with
a non-OCR `showingSettings` declaration — do NOT delete
`showingSettings`:

```swift
    @State private var isOCRModeEnabled = false
```

```swift
    @State private var isShowingOCRResult = false
```

```swift
    @State private var selectedText = ""
```

Keep `@State private var showingSettings = false` (currently between
`isShowingOCRResult` and `selectedText`).

Replace the two `VideoSurfaceView(...)` call sites (lines 117–124 and 128–135) with the bare constructor:

```swift
                VideoSurfaceView(
                    onReconnect: {
                        reconnectCurrentSession()
                    }
                )
```

— apply that same replacement in both the fullscreen and non-fullscreen branches.

Remove the two OCR toolbar buttons (lines 176–180 in the fullscreen hover toolbar and lines 380–384 in the main toolbar):

```swift
                            Button(action: { toggleOCR() }) {
                                Image(systemName: isOCRModeEnabled ? "text.viewfinder" : "doc.text")
                            }
                            .disabled(!isConnected)
                            .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")
```

— delete both block occurrences.

Remove the `.onReceive(...overlookToggleCopyMode)` modifier (lines 326–330):

```swift
        .onReceive(NotificationCenter.default.publisher(for: .overlookToggleCopyMode)) { _ in
            Task { @MainActor in
                isOCRModeEnabled.toggle()
            }
        }
```

Remove the OCR result sheet (lines 334–336):

```swift
        .sheet(isPresented: $isShowingOCRResult) {
            OCRResultView(selectedText: $selectedText)
        }
```

Remove the `toggleOCR()` method (lines 552–555):

```swift
    @MainActor
    private func toggleOCR() {
        isOCRModeEnabled.toggle()
    }
```

Leave the `@EnvironmentObject var ocrManager: OCRManager` declaration at line 8 in place — it is still needed because `VideoSurfaceView` consumes it via the same environment chain.

- [ ] **Step 4.5: Verify the build**

```bash
./build.sh -c debug
```

Expected: `BUILD SUCCEEDED`. If the compiler complains about unused `selectedText`, `isShowingOCRResult`, `isOCRModeEnabled`, or `toggleOCR`, you missed one of the deletions above — remove the offending reference.

- [ ] **Step 4.6: Manual smoke test of the snippet flow**

Run the app and connect to a device.

- Press `cmd+shift+C` with text visible on the remote screen. Expected: a dimmed overlay appears with a blue selection rectangle that follows the drag; remote keyboard/mouse does not receive input during the drag.
- Drag a rectangle around some readable text and release. Expected: overlay disappears, a small HUD at the top center of the video says `Text kopiert`, and the Mac clipboard contains the recognized text (verify with `pbpaste` in a terminal or `cmd+v` in a Mac app).
- Press `cmd+shift+C` again, drag across blank space. Expected: HUD says `Kein Text erkannt`, clipboard is untouched from its previous contents.
- Press `cmd+shift+C`, then press `Escape`. Expected: overlay disappears, no HUD, no OCR attempt.
- Press `cmd+shift+C`, click without dragging. Expected: overlay disappears, no HUD.

If any step misbehaves, fix before committing. Pay particular attention to the HUD auto-hide (~1.5 s) — it should not linger.

- [ ] **Step 4.7: Commit**

```bash
git add Overlook/VideoSurfaceView.swift Overlook/ContentView.swift
git commit -m "Replace OCR toggle mode with cmd+shift+C snippet flow"
```

---

## Task 5: Drop OCR toggle from the menu-bar agent

**Purpose:** Remove the now-dead `cmd+shift+O` global shortcut and the "Enable OCR" menu item. Both paths still post `.overlookToggleCopyMode`, which has no listener after Task 4 — so they are currently no-ops, but they pollute the menu.

**Files:**
- Modify: `Overlook/MenuBarAgent.swift`

- [ ] **Step 5.1: Remove the menu item**

In `Overlook/MenuBarAgent.swift`, delete the "OCR toggle" block at lines 124–128:

```swift
        // OCR toggle
        let ocrItem = NSMenuItem(title: "Enable OCR", action: #selector(toggleOCR), keyEquivalent: "o")
        ocrItem.target = self
        ocrItem.tag = 200
        menu?.addItem(ocrItem)
```

If the immediately preceding `menu?.addItem(NSMenuItem.separator())` call becomes redundant (i.e., leaves two separators next to each other or a separator at the very top/bottom of a menu section), also remove that extra separator. Otherwise leave separators as-is.

- [ ] **Step 5.2: Remove the `toggleOCR` target method**

Delete the `@objc private func toggleOCR()` block at lines 460–467:

```swift
    @objc private func toggleOCR() {
        NotificationCenter.default.post(name: .overlookToggleCopyMode, object: nil)

        // Update menu item
        if let ocrItem = menu?.items.first(where: { $0.tag == 200 }) {
            ocrItem.title = ocrItem.title.contains("Enable") ? "Disable OCR" : "Enable OCR"
        }
    }
```

- [ ] **Step 5.3: Remove the `cmd+shift+O` case from the global key handler**

In `handleGlobalKeyEvent` (lines 556–569), delete the two lines:

```swift
        case 31: // O key - Toggle OCR
            toggleOCR()
```

The resulting `switch` should keep cases `9` (Quick Connect) and `15` (Scan Devices) plus the `default` branch.

- [ ] **Step 5.4: Verify the build**

```bash
./build.sh -c debug
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5.5: Manual smoke test**

- Click the Overlook menu-bar icon. Expected: no "Enable OCR" / "Disable OCR" menu item.
- Focus any app that is NOT Overlook and press `cmd+shift+O`. Expected: nothing happens (previously this toggled OCR).
- Focus any app that is NOT Overlook and press `cmd+shift+V`. Expected: Quick Connect popover still opens (regression check — you did not touch the wrong case).

- [ ] **Step 5.6: Commit**

```bash
git add Overlook/MenuBarAgent.swift
git commit -m "Remove menu-bar OCR toggle (cmd+shift+O) and menu item"
```

---

## Task 6: Trim `OCRManager`, remove legacy OCR views, remove old notification name

**Purpose:** Cut the unused live-detection pipeline and the result sheet. After this task the only OCR entry point is `recognizeTextInRegion`.

**Files:**
- Modify: `Overlook/OCRManager.swift`
- Modify: `Overlook/OCRViews.swift`
- Modify: `Overlook/InputManager.swift`

- [ ] **Step 6.1: Replace `OCRManager.swift` contents**

Overwrite `Overlook/OCRManager.swift` entirely with the trimmed version:

```swift
import Foundation
import Vision
import CoreImage
import AppKit
import Combine

@MainActor
class OCRManager: ObservableObject {
    @Published var isProcessing = false
    @Published var lastRecognizedText = ""

    nonisolated(unsafe) private var textRecognitionRequest: VNRecognizeTextRequest?
    nonisolated(unsafe) private var ocrQueue = DispatchQueue(label: "com.overlook.ocr", qos: .userInitiated)

    init() {
        setupOCRRequests()
    }

    private func setupOCRRequests() {
        textRecognitionRequest = VNRecognizeTextRequest { [weak self] request, error in
            Task { @MainActor in
                self?.handleTextRecognition(request: request, error: error)
            }
        }

        textRecognitionRequest?.recognitionLevel = .accurate
        textRecognitionRequest?.usesLanguageCorrection = true
        textRecognitionRequest?.recognitionLanguages = ["en-US", "en-GB"]
        textRecognitionRequest?.automaticallyDetectsLanguage = true
    }

    func recognizeTextInRegion(_ region: CGRect, in pixelBuffer: CVPixelBuffer?) async throws -> String {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let pixelBufferBox = PixelBufferBox(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async { [weak self] in
                self?.performRegionTextRecognition(region: region, in: pixelBufferBox.pixelBuffer) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    nonisolated private func performRegionTextRecognition(region: CGRect, in pixelBuffer: CVPixelBuffer, completion: @escaping (Result<String, Error>) -> Void) {
        guard let request = textRecognitionRequest else {
            completion(.failure(OCRError.requestNotInitialized))
            return
        }

        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let normalizedRegion = CGRect(
            x: region.origin.x * bufferSize.width,
            y: region.origin.y * bufferSize.height,
            width: region.size.width * bufferSize.width,
            height: region.size.height * bufferSize.height
        )

        let croppedBuffer = cropPixelBuffer(pixelBuffer, to: normalizedRegion)
        let handler = VNImageRequestHandler(cvPixelBuffer: croppedBuffer, options: [:])

        Task { @MainActor in
            isProcessing = true
        }

        do {
            try handler.perform([request])

            guard let observations = request.results else {
                completion(.failure(OCRError.noTextFound))
                return
            }

            let recognizedText = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: " ")

            Task { @MainActor in
                lastRecognizedText = recognizedText
                isProcessing = false
            }

            if recognizedText.isEmpty {
                completion(.failure(OCRError.noTextFound))
            } else {
                completion(.success(recognizedText))
            }
        } catch {
            Task { @MainActor in
                isProcessing = false
            }
            completion(.failure(error))
        }
    }

    nonisolated private func cropPixelBuffer(_ pixelBuffer: CVPixelBuffer, to rect: CGRect) -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = ciImage.extent.integral
        let requested = rect.integral
        let clipped = requested.intersection(sourceExtent)

        if clipped.isEmpty {
            return pixelBuffer
        }

        let croppedImage = ciImage
            .cropped(to: clipped)
            .transformed(by: CGAffineTransform(translationX: -clipped.origin.x, y: -clipped.origin.y))

        var croppedPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(clipped.width),
            Int(clipped.height),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            nil,
            &croppedPixelBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer = croppedPixelBuffer else {
            return pixelBuffer
        }

        let context = CIContext()
        context.render(croppedImage, to: outputBuffer)

        return outputBuffer
    }

    private func handleTextRecognition(request: VNRequest, error: Error?) {
        if let error = error {
            print("Text recognition error: \(error)")
            return
        }

        guard let request = request as? VNRecognizeTextRequest,
              let observations = request.results else {
            return
        }

        let recognizedText = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }.joined(separator: "\n")

        Task { @MainActor in
            lastRecognizedText = recognizedText
            isProcessing = false
        }
    }

    func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct PixelBufferBox: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

enum OCRError: Error, LocalizedError {
    case noVideoFrame
    case requestNotInitialized
    case noTextFound
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .noVideoFrame:
            return "No video frame available for OCR"
        case .requestNotInitialized:
            return "OCR request not properly initialized"
        case .noTextFound:
            return "No text found in the specified region"
        case .processingFailed:
            return "OCR processing failed"
        }
    }
}
```

This deletes `textObservationRequest`, `recognizedRegions`, `detectTextRegions`, `performTextDetection`, `getTextAtLocation`, `recognizeText(at:in:)`, `performTextRecognition(at:in:...)`, `handleTextObservation`, `createRegionOfInterest`, the `TextRegion` type, and the now-unused `extension OCRManager` configuration/optimization helpers. Every surviving symbol is exercised by `VideoSurfaceView.performSnippetOCR`.

- [ ] **Step 6.2: Replace `OCRViews.swift` contents**

Overwrite `Overlook/OCRViews.swift` with only the snippet views (drop `OCRSelectionOverlay` and `OCRResultView`):

```swift
import SwiftUI
import AppKit

struct SnippetSelectionOverlay: View {
    let selectionRectInView: CGRect?
    let viewSize: CGSize

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)

            if let selectionRectInView {
                Rectangle()
                    .fill(Color.blue.opacity(0.12))
                    .overlay(
                        Rectangle().stroke(Color.blue.opacity(0.9), lineWidth: 2)
                    )
                    .frame(width: selectionRectInView.width, height: selectionRectInView.height)
                    .position(x: selectionRectInView.midX, y: selectionRectInView.midY)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(false)
    }
}

struct SnippetHUD: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(radius: 4)
    }
}
```

- [ ] **Step 6.3: Remove the old notification name**

In `Overlook/InputManager.swift`, change the extension block at lines 7–12 (its shape after Task 1):

```swift
extension Notification.Name {
    // TODO(task 6): remove once no caller/listener references it.
    static let overlookToggleCopyMode = Notification.Name("overlook.toggleCopyMode")
    static let overlookStartSnippet = Notification.Name("overlook.startSnippet")
    static let overlookCancelSnippet = Notification.Name("overlook.cancelSnippet")
}
```

back down to:

```swift
extension Notification.Name {
    static let overlookStartSnippet = Notification.Name("overlook.startSnippet")
    static let overlookCancelSnippet = Notification.Name("overlook.cancelSnippet")
}
```

- [ ] **Step 6.4: Verify the build**

```bash
./build.sh -c debug
```

Expected: `BUILD SUCCEEDED`. If the compiler reports a reference to `TextRegion`, `OCRResultView`, `OCRSelectionOverlay`, `detectTextRegions`, `recognizedRegions`, `getTextAtLocation`, `recognizeText(at:in:)`, or `overlookToggleCopyMode`, there is a straggler that was not removed in Tasks 4–5 — fix the reference before moving on.

- [ ] **Step 6.5: Manual regression sweep**

- Snippet flow still works end-to-end (Task 4 test).
- `cmd+shift+V` clipboard-bridge still works (Task 2 test).
- `cmd+shift+C` still triggers the snippet overlay (Task 4 test).
- Launching the app, connecting, disconnecting, and reconnecting works without new warnings in the Xcode console.

- [ ] **Step 6.6: Commit**

```bash
git add Overlook/OCRManager.swift Overlook/OCRViews.swift Overlook/InputManager.swift
git commit -m "Drop legacy OCR pipeline, result sheet, and old notification name"
```

---

## Task 7: Update README

**Purpose:** Sync the user-facing docs with the new shortcuts and the snippet flow.

**Files:**
- Modify: `README.md`

- [ ] **Step 7.1: Update the "Highlights" bullets**

In `README.md`, replace the existing Highlight sections "1) Copy from the remote screen using ML OCR" (lines 23–37) and "2) Paste to the remote machine with `⌘V`" (lines 39–43) with:

```markdown
### 1) Copy from the remote screen with `⌘⇧C`

Overlook includes a **one-shot snippet OCR** for pulling text off the remote:

- Press `⌘⇧C` anywhere in the Overlook window.
- A selection overlay appears over the video.
- Drag a rectangle around the text you want.
- Overlook runs on-device OCR (Apple Vision framework) on that region,
  copies the recognized text straight to your Mac clipboard, and shows a
  brief "Text kopiert" HUD.

This is especially useful for:

- Capturing one-time passwords, serial numbers, IPs, MAC addresses.
- Copying terminal output from machines with no clipboard integration.
- Copying text in pre-boot environments.

**Note:** OCR is performed locally on your Mac.

### 2) Paste the Mac clipboard to the remote with `⌘⇧V`

When connected and input capture is active, `⌘⇧V` reads your macOS
clipboard and sends it to the remote machine via the device's HID
text-entry API.

Plain `⌘V` is forwarded to the remote as-is (i.e. the remote OS
interprets it against its own clipboard).
```

- [ ] **Step 7.2: Rewrite the "Keyboard shortcuts" section**

Replace lines 196–214 ("## Keyboard shortcuts" through the end of the "Menu bar global shortcuts" list) with:

```markdown
## Keyboard shortcuts

Overlook forwards most key events to the remote while input capture is
enabled. A small local whitelist keeps common Mac shortcuts working.

### Local (stay on the Mac / consumed by Overlook)

- `⌘⇧C`: start the one-shot snippet OCR described above.
- `⌘⇧V`: type the Mac clipboard into the remote via HID.
- `⌘⇧` + any other key: stays local (not forwarded).
- `⌘Tab`: macOS app switcher.
- `⌥Tab`: passes through locally (useful with third-party window
  switchers).
- `Escape` while the snippet overlay is showing: cancel without OCR.

### Forwarded to the remote

Everything else, including `⌘C`, `⌘V`, `⌘Q`, `⌘W`, `⌘H`, `⌘M`, and so
on. If you need to quit Overlook via the keyboard, either disable input
capture first (open the Settings panel) or use `⌘⌥Esc` to force-quit.

### Menu bar global shortcuts

The menu bar agent listens for these when Overlook is NOT focused:

- `⌘⇧R`: Scan for devices.
- `⌘⇧V`: Open Quick Connect.
```

- [ ] **Step 7.3: Update the "OCR Copy Mode" and "Clipboard Paste" sections**

Replace lines 138–193 (everything under `## OCR Copy Mode (Remote → Local)` through the end of `## Clipboard Paste (Local → Remote)`) with:

```markdown
## Snippet OCR (Remote → Local)

### Capture text with `⌘⇧C`

1. Press `⌘⇧C` inside the Overlook window.
2. Drag a rectangle around the text region you want.
3. Overlook OCRs the selection, copies the text to your Mac clipboard,
   and flashes a brief HUD. No result sheet — paste normally in any Mac
   app.

### Notes / limitations

- OCR accuracy depends on resolution, compression, font size, and
  contrast.
- OCR is tuned for English with automatic language detection.
- Press `Escape` during selection to cancel.

## Clipboard Paste (Local → Remote)

### Paste with `⌘⇧V`

When connected and input capture is active:

- Press `⌘⇧V` on your Mac.
- Overlook reads your Mac clipboard and types it to the remote via the
  device's HID text-entry API.

This is ideal for:

- Commands
- URLs
- Password-manager output (use responsibly)
- Small scripts / config snippets

### Tips

- Large pastes may take time for the remote to process. Paste in smaller
  chunks in BIOS/UEFI or slow boot environments.
```

- [ ] **Step 7.4: Drop the stale troubleshooting subsection and final sanity check**

If a subsection titled "OCR doesn't detect text" (lines 259–263) is still in `README.md`, replace it with:

```markdown
### "Snippet OCR doesn't detect text"

- Increase stream quality (higher bitrate helps OCR).
- Make the text larger on the remote side.
- Avoid heavy compression artifacts (try High/Ultra-high/Insane).
```

Re-read the file end-to-end and make sure no stray mention of "OCR mode", "OCR toggle", "text.viewfinder", "⌘C to toggle", or "`Enable OCR`" remains.

- [ ] **Step 7.5: Commit**

```bash
git add README.md
git commit -m "Update README for new keyboard routing and snippet OCR"
```

---

## Task 8: End-to-end smoke test

**Purpose:** Verify the whole feature set against a real GLKVM session before calling it done.

**Files:** none.

- [ ] **Step 8.1: Full checklist against the spec's "Testing" section**

Connect to a GLKVM device in the built app. Run through every bullet below; anything that fails is a bug to fix before closing out:

Keyboard routing:

- `cmd+C` (focused in remote terminal): remote sees `Meta+C`. Mac clipboard unchanged.
- `cmd+V` (focused in remote text field): remote sees `Meta+V`. Mac-clipboard-to-HID typing does NOT happen.
- `cmd+shift+V` (Mac clipboard has "hello world"): the phrase `hello world` is typed into the remote.
- `cmd+shift+C`: snippet overlay appears, dim background, blue rectangle follows drag.
- `cmd+Tab`: Mac app switcher engages; remote does not receive a `Tab` keystroke.
- `option+Tab`: no HID event reaches the remote.
- `cmd+shift+K` (any arbitrary letter): remote does not receive `K`. (Local app may ignore it — that is fine.)
- `cmd+Q`: remote receives `Meta+Q`. (Overlook itself is NOT quit — this is expected per spec.)
- Toggle keyboard capture off via Settings panel; every shortcut above returns to normal local Mac behavior.

Snippet flow:

- Drag over recognizable text → Mac clipboard contains the text, HUD "Text kopiert" shows for ~1.5 s, overlay closes.
- Drag over blank area → HUD "Kein Text erkannt", clipboard untouched, overlay closes.
- Click without drag → overlay closes silently.
- Escape during selection → overlay closes silently.
- Start snippet, disconnect mid-selection → app does not crash; overlay eventually closes.

Regressions:

- Fullscreen toggle still works; the top hover toolbar no longer shows an OCR button but still shows Connections/Fit/Settings.
- Menu-bar icon menu no longer contains "Enable OCR" / "Disable OCR".
- Scan (`cmd+shift+R`) and Quick Connect (`cmd+shift+V`, when Overlook is not focused) still work.
- WebRTC video, audio, mouse routing are unchanged.

- [ ] **Step 8.2: If everything passes, create a final summary commit (optional)**

Only run this if the test sweep turned up any touch-ups you made since the last per-task commit. Otherwise skip.

```bash
git status
# If there are changes:
git add <modified files>
git commit -m "Polish based on end-to-end smoke test"
```

---

## Notes for the implementer

- The spec is authoritative. If you hit a situation where this plan contradicts `docs/superpowers/specs/2026-05-07-remote-key-routing-and-snippet-ocr-design.md`, trust the spec.
- Frame capture is expensive — the snippet flow toggles it on only while the overlay is active, and `exitSnippetMode()` is the only place that toggles it back off. Do not re-introduce a long-lived capture task.
- `cmd+V` no longer has any special handling in `InputManager`. Do not reintroduce the `keyCode == 9` short-circuit there, even "just for testing".
- The menu-bar `cmd+shift+V` Quick Connect shortcut only fires when Overlook is NOT focused (it uses `addGlobalMonitorForEvents`). Do not route the in-app `cmd+shift+V` to it.
