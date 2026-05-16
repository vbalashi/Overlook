import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var ocrManager: OCRManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    @EnvironmentObject var quickPasteManager: QuickPasteManager
    
    @State private var selectedDevice: KVMDevice?
    @State private var isConnected = false
    @State private var showingSettings = false

    @State private var showingManualConnect = false
    @State private var manualHostPort = ""
    @State private var manualPort = "443"

    @State private var manualPassword = ""

    @State private var showingPasswordPrompt = false
    @State private var pendingPasswordDevice: KVMDevice?
    @State private var pendingPassword = ""

    @State private var suppressDeviceAutoConnect = false

    @State private var showingConnections = false
    @State private var didAutoOpenConnections = false
    @State private var isConnectionBusy = false
    @State private var connectionErrorMessage: String?
    @State private var showingQuickPaste = false
    @State private var isStreamPaused = false
    @State private var pausedStreamDevice: KVMDevice?
    @State private var hiddenStreamSnapshot: HiddenStreamSnapshot?
    @State private var hiddenStreamTask: Task<Void, Never>?
    @State private var isWindowStreamVisible = true

    @State private var pausedCaptureKeyboardWasEnabled: Bool?
    @State private var pausedCaptureMouseWasEnabled: Bool?
    @State private var isInputCapturePausedForUI: Bool = false

    @State private var windowRef: NSWindow?

    @State private var isFullscreen: Bool = false

    @AppStorage("overlook.appAppearance") private var appAppearance: String = "system"
    @AppStorage("overlook.autoResumeLastConnection") private var autoResumeLastConnection: Bool = false
    @AppStorage("overlook.reduceHiddenStreamQuality") private var reduceHiddenStreamQuality: Bool = true

    private struct HiddenStreamSnapshot {
        let desiredFps: Int?
        let quality: Int?
        let h264Bitrate: Int?
        let h264Gop: Int?
        let zeroDelay: Bool?
        let resolution: String?
    }

    private var preferredColorScheme: ColorScheme? {
        switch appAppearance {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }

    private var windowTitle: String {
        let device = kvmDeviceManager.connectedDevice

        let deviceLabel: String
        if let device {
            if device.type == .glinetComet {
                deviceLabel = "GLKVM"
            } else {
                deviceLabel = device.type.displayName
            }
        } else {
            deviceLabel = "Overlook"
        }

        let connectionState: String
        if device == nil || isConnected == false {
            connectionState = "Disconnected"
        } else {
            connectionState = "Connected"
        }

        let resolution: String
        if let size = webRTCManager.videoSize {
            resolution = "\(Int(size.width))x\(Int(size.height))"
        } else {
            resolution = "—"
        }

        let kbps: String
        if let value = webRTCManager.inboundVideoKbps {
            kbps = "\(value) kbps"
        } else {
            kbps = "— kbps"
        }

        let fps: String
        if let value = webRTCManager.inboundFps {
            fps = "\(Int(value.rounded())) fps dynamic"
        } else {
            fps = "— fps dynamic"
        }

        return "Overlook - \(deviceLabel) / \(connectionState) / \(resolution) / \(kbps) / \(fps)"
    }

    private func applyAppAppearance() {
        switch appAppearance {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
    
    var body: some View {
        ZStack(alignment: .trailing) {
            if isFullscreen {
                VideoSurfaceView(
                    onReconnect: {
                        reconnectCurrentSession()
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(!showingSettings)
            } else {
                VideoSurfaceView(
                    onReconnect: {
                        reconnectCurrentSession()
                    }
                )
                .allowsHitTesting(!showingSettings)
            }

            if isStreamPaused {
                VStack(spacing: 10) {
                    Text("Stream Paused")
                        .font(.headline)

                    Text("The device session is still active.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button("Resume Stream") {
                        resumeStream()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnectionBusy)
                }
                .padding(14)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }

            if showingSettings || showingConnections {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSettings = false
                            showingConnections = false
                        }
                    }
            }

            WebUISettingsPanel(isPresented: $showingSettings)
                .frame(width: 360)
                .offset(x: showingSettings ? 0 : 360)
                .animation(Animation.easeInOut(duration: 0.2), value: showingSettings)
                .allowsHitTesting(showingSettings)

            VStack(spacing: 0) {
                ConnectionsPopoverView(
                    selectedDevice: $selectedDevice,
                    isConnected: isConnected,
                    isScanning: kvmDeviceManager.isScanning,
                    devices: kvmDeviceManager.availableDevices,
                    connectedDeviceName: kvmDeviceManager.connectedDevice?.name,
                    latency: webRTCManager.latency,
                    videoSize: webRTCManager.videoSize,
                    inboundVideoKbps: webRTCManager.inboundVideoKbps,
                    inboundFps: webRTCManager.inboundFps,
                    inboundVideoPlayoutDelayMs: webRTCManager.inboundVideoPlayoutDelayMs,
                    inboundVideoJitterMs: webRTCManager.inboundVideoJitterMs,
                    inboundVideoDecodeMs: webRTCManager.inboundVideoDecodeMs,
                    inboundVideoPacketsLost: webRTCManager.inboundVideoPacketsLost,
                    iceCurrentRoundTripTimeMs: webRTCManager.iceCurrentRoundTripTimeMs,
                    inboundAudioKbps: webRTCManager.inboundAudioKbps,
                    inboundAudioPlayoutDelayMs: webRTCManager.inboundAudioPlayoutDelayMs,
                    inboundAudioJitterMs: webRTCManager.inboundAudioJitterMs,
                    inboundAudioPacketsLost: webRTCManager.inboundAudioPacketsLost,
                    audioIceCurrentRoundTripTimeMs: webRTCManager.audioIceCurrentRoundTripTimeMs,
                    sessionVideoBytesReceived: webRTCManager.sessionVideoBytesReceived,
                    sessionAudioBytesReceived: webRTCManager.sessionAudioBytesReceived,
                    sessionAudioBytesSent: webRTCManager.sessionAudioBytesSent,
                    isConnectionBusy: isConnectionBusy,
                    connectionErrorMessage: connectionErrorMessage,
                    onScan: {
                        kvmDeviceManager.scanForDevices()
                    },
                    onManualConnect: {
                        showingManualConnect = true
                    },
                    onToggleConnection: {
                        toggleConnection()
                    },
                    onForgetSelectedDevice: {
                        guard let device = selectedDevice else { return }
                        guard device.id.hasPrefix("saved-") else { return }
                        kvmDeviceManager.forgetDevice(device)
                        selectedDevice = nil
                    }
                )
                .frame(width: 360)
                .background(.thickMaterial)
                .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .offset(x: showingConnections ? 0 : 360)
            .animation(.easeInOut(duration: 0.2), value: showingConnections)
            .allowsHitTesting(showingConnections)
        }
        .background(WindowAspectRatioSetter(videoSize: webRTCManager.videoSize))
        .background(WindowTitleSetter(title: windowTitle))
        .background(WindowReferenceSetter(window: $windowRef))
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            applyAppAppearance()
            inputManager.setup(with: webRTCManager)
            inputManager.setGLKVMClient(kvmDeviceManager.glkvmClient)

            updateInputCaptureForUIOverlays()
            updateWindowStreamVisibility()

            if autoResumeLastConnection, let lastDevice = kvmDeviceManager.lastConnectedDevice {
                didAutoOpenConnections = true
                connectToDevice(lastDevice)
            } else if !didAutoOpenConnections, !isConnected {
                didAutoOpenConnections = true
                showingConnections = true
            }
        }
        .onChange(of: showingSettings) { _, _ in
            updateInputCaptureForUIOverlays()
        }
        .onChange(of: showingConnections) { _, _ in
            updateInputCaptureForUIOverlays()
        }
        .onChange(of: showingQuickPaste) { _, _ in
            updateInputCaptureForUIOverlays()
        }
        .onChange(of: windowRef) { _, newValue in
            isFullscreen = newValue?.styleMask.contains(.fullScreen) ?? false
            updateWindowStreamVisibility()
        }
        .onChange(of: reduceHiddenStreamQuality) { _, _ in
            scheduleHiddenStreamQualityUpdate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            windowRef = window
            window.toolbar?.isVisible = true
            isFullscreen = true
            updateWindowStreamVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            windowRef = window
            window.toolbar?.isVisible = true
            isFullscreen = false
            updateWindowStreamVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { note in
            guard (note.object as? NSWindow) === windowRef else { return }
            updateWindowStreamVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { note in
            guard (note.object as? NSWindow) === windowRef else { return }
            updateWindowStreamVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard (note.object as? NSWindow) === windowRef else { return }
            updateWindowStreamVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            updateWindowStreamVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            updateWindowStreamVisibility()
        }
        .onReceive(kvmDeviceManager.$glkvmClient) { client in
            inputManager.setGLKVMClient(client)
            scheduleHiddenStreamQualityUpdate()
        }
        .onReceive(kvmDeviceManager.$connectedDevice) { device in
            Task { @MainActor in
                if let device {
                    suppressDeviceAutoConnect = true
                    selectedDevice = device
                    isConnected = true
                    DispatchQueue.main.async {
                        suppressDeviceAutoConnect = false
                    }
                } else {
                    isConnected = false
                    isStreamPaused = false
                    pausedStreamDevice = nil
                    hiddenStreamSnapshot = nil
                }
                scheduleHiddenStreamQualityUpdate()
            }
        }
        .onChange(of: appAppearance) { _, _ in
            applyAppAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlookShowSettings)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showingConnections = false
                showingSettings = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlookShowConnections)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showingSettings = false
                showingConnections = true
            }
        }
        .sheet(isPresented: $showingManualConnect) {
            ManualConnectSheet(
                isPresented: $showingManualConnect,
                hostPort: $manualHostPort,
                port: $manualPort,
                password: $manualPassword,
                onConnect: {
                    manualConnect()
                }
            )
        }
        .sheet(isPresented: $showingPasswordPrompt) {
            PasswordPromptSheet(
                isPresented: $showingPasswordPrompt,
                password: $pendingPassword,
                onCancel: {
                    pendingPasswordDevice = nil
                    pendingPassword = ""
                },
                onConnect: {
                    if let device = pendingPasswordDevice {
                        OverlookLog.info("Password prompt submitted host=\(device.host) port=\(device.port) passwordLength=\(pendingPassword.count)")
                        connectToDevice(device, password: pendingPassword)
                    }
                    pendingPasswordDevice = nil
                    pendingPassword = ""
                }
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { showingConnections.toggle() }) {
                    Image(systemName: "personalhotspot")
                }
                .help("Connections")

                Button(action: { setAudioOutputMuted(!webRTCManager.audioOutputMuted) }) {
                    Image(systemName: webRTCManager.audioOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(webRTCManager.audioOutputMuted ? Color.red : Color.primary)
                }
                .disabled(!webRTCManager.audioEnabled)
                .help(webRTCManager.audioEnabled ? (webRTCManager.audioOutputMuted ? "Unmute Audio Output" : "Mute Audio Output") : "Enable Audio in Settings first")

                Button(action: { setMicrophoneMuted(!webRTCManager.microphoneMuted) }) {
                    Image(systemName: webRTCManager.microphoneMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(webRTCManager.microphoneMuted ? Color.red : Color.primary)
                }
                .disabled(!webRTCManager.micEnabled)
                .help(webRTCManager.micEnabled ? (webRTCManager.microphoneMuted ? "Unmute Microphone" : "Mute Microphone") : "Enable Microphone in Settings first")

                Button(action: { isStreamPaused ? resumeStream() : pauseStream() }) {
                    Image(systemName: isStreamPaused ? "play.fill" : "pause.fill")
                }
                .disabled(kvmDeviceManager.connectedDevice == nil || isConnectionBusy)
                .help(isStreamPaused ? "Resume Stream" : "Pause Stream")

                Button(action: { showingQuickPaste.toggle() }) {
                    Image(systemName: "bolt.fill")
                }
                .help("Quick Paste")
                .popover(isPresented: $showingQuickPaste, arrowEdge: .bottom) {
                    QuickPasteView()
                }

                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() } }) {
                    Image(systemName: "gearshape")
                }
                .disabled(!isConnected)
                .help("Settings")
            }
        }
    }

    private func connectToDevice(_ device: KVMDevice, password: String? = nil) {
        guard isConnectionBusy == false else { return }

        OverlookLog.info("UI connect requested host=\(device.host) port=\(device.port) id=\(device.id) passwordProvided=\((password?.isEmpty == false))")
        isConnectionBusy = true
        connectionErrorMessage = nil

        Task { @MainActor in
            defer {
                isConnectionBusy = false
            }

            do {
                let connectedDevice = try await kvmDeviceManager.connectToDevice(device, password: password)
                OverlookLog.info("KVM API connect succeeded host=\(connectedDevice.host) port=\(connectedDevice.port)")
                suppressDeviceAutoConnect = true
                selectedDevice = connectedDevice
                isConnected = true
                isStreamPaused = false
                pausedStreamDevice = nil
                showingConnections = false
                DispatchQueue.main.async {
                    suppressDeviceAutoConnect = false
                }

                if let client = kvmDeviceManager.glkvmClient {
                    inputManager.setGLKVMClient(client)
                    inputManager.startFullInputCapture()
                    try? await client.setHidConnected(true)
                }

 #if canImport(WebRTC)
                do {
                    try await webRTCManager.connect(to: connectedDevice)
                    OverlookLog.info("WebRTC connect succeeded host=\(connectedDevice.host) port=\(connectedDevice.port)")
                } catch {
                    OverlookLog.error("WebRTC connect failed host=\(connectedDevice.host) port=\(connectedDevice.port) error=\(OverlookLog.describe(error))")
                    print("WebRTC connect failed (API is still connected): \(error)")
                }
 #endif
            } catch {
                if let kvmError = error as? KVMError, kvmError == .authenticationFailed {
                    pendingPasswordDevice = device
                    showingPasswordPrompt = true
                } else {
                    OverlookLog.error("UI connect failed host=\(device.host) port=\(device.port) error=\(OverlookLog.describe(error))")
                    print("Failed to connect: \(error)")
                    connectionErrorMessage = connectionFailureMessage(error, device: device)
                    isConnected = false
                }
                return
            }
        }
    }

    private func connectionFailureMessage(_ error: Error, device: KVMDevice) -> String {
        return "Failed to connect to \(device.host):\(device.port): \(connectionErrorDetail(error))"
    }

    private func connectionErrorDetail(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.localizedDescription
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(nsError.localizedDescription) (\(underlying.localizedDescription))"
        }

        return error.localizedDescription
    }

    private func reconnectCurrentSession() {
        guard let device = kvmDeviceManager.connectedDevice ?? deviceForConnection() else {
            connectionErrorMessage = "Select a device before reconnecting."
            return
        }

        let client = kvmDeviceManager.glkvmClient

        Task { @MainActor in
            await restoreHiddenStreamQualityIfNeeded()
            webRTCManager.disconnect()
            inputManager.setGLKVMClient(nil)
            inputManager.stopFullInputCapture()
            kvmDeviceManager.disconnectFromDevice()
            isConnected = false
            try? await client?.setHidConnected(false)
            try? await Task.sleep(nanoseconds: 300_000_000)
            connectToDevice(device)
        }
    }

    private func setAudioOutputMuted(_ muted: Bool) {
        webRTCManager.setAudioOutputMuted(muted)
    }

    private func setMicrophoneMuted(_ muted: Bool) {
        webRTCManager.setMicrophoneMuted(muted)
    }

    private func manualConnect() {
        let trimmed = manualHostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var host = trimmed
        var portString = manualPort.trimmingCharacters(in: .whitespacesAndNewlines)

        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }

        if let colonIndex = host.lastIndex(of: ":") {
            let maybeHost = String(host[..<colonIndex])
            let maybePort = String(host[host.index(after: colonIndex)...])
            if !maybeHost.isEmpty, !maybePort.isEmpty {
                host = maybeHost
                portString = maybePort
            }
        }

        let port = Int(portString) ?? 443
        let device = kvmDeviceManager.addManualDevice(host: host, port: port, type: .glinetComet)

        suppressDeviceAutoConnect = true
        selectedDevice = device
        DispatchQueue.main.async {
            suppressDeviceAutoConnect = false
        }

        let password = manualPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        connectToDevice(device, password: password.isEmpty ? nil : password)
    }

    private func toggleConnection() {
        if isConnected {
            connectionErrorMessage = nil
            isStreamPaused = false
            pausedStreamDevice = nil
            hiddenStreamTask?.cancel()
            hiddenStreamTask = nil

            let client = kvmDeviceManager.glkvmClient
            isConnectionBusy = true
            Task { @MainActor in
                defer { isConnectionBusy = false }
                await restoreHiddenStreamQualityIfNeeded()
                webRTCManager.disconnect()
                try? await client?.setHidConnected(false)
                kvmDeviceManager.disconnectFromDevice()
                inputManager.setGLKVMClient(nil)
                inputManager.stopFullInputCapture()
                isConnected = false
                showingConnections = true
            }
        } else if let device = deviceForConnection() {
            connectToDevice(device)
        } else {
            connectionErrorMessage = "Select a device before connecting."
        }
    }

    private func deviceForConnection() -> KVMDevice? {
        if let selectedDevice {
            return selectedDevice
        }
        if kvmDeviceManager.availableDevices.count == 1 {
            return kvmDeviceManager.availableDevices[0]
        }
        return nil
    }

    @MainActor
    private func pauseStream() {
        guard isStreamPaused == false else { return }
        guard let device = kvmDeviceManager.connectedDevice ?? selectedDevice else {
            connectionErrorMessage = "Select a device before pausing the stream."
            return
        }

        hiddenStreamTask?.cancel()
        hiddenStreamTask = nil
        pausedStreamDevice = device
        isStreamPaused = true
        OverlookLog.info("Manual stream pause requested; keeping KVM session active host=\(device.host) port=\(device.port)")

        Task { @MainActor in
            await restoreHiddenStreamQualityIfNeeded()
            webRTCManager.disconnect()
            inputManager.stopFullInputCapture()
        }
    }

    @MainActor
    private func resumeStream() {
        guard isStreamPaused else { return }
        guard let device = pausedStreamDevice ?? kvmDeviceManager.connectedDevice ?? selectedDevice else {
            connectionErrorMessage = "Select a device before resuming the stream."
            return
        }

        isConnectionBusy = true
        connectionErrorMessage = nil

        Task { @MainActor in
            defer { isConnectionBusy = false }
            do {
                try await webRTCManager.connect(to: device)
                if kvmDeviceManager.glkvmClient != nil {
                    inputManager.setGLKVMClient(kvmDeviceManager.glkvmClient)
                    inputManager.startFullInputCapture()
                }
                isStreamPaused = false
                pausedStreamDevice = nil
                isConnected = true
                scheduleHiddenStreamQualityUpdate()
                OverlookLog.info("Manual stream resume succeeded host=\(device.host) port=\(device.port)")
            } catch {
                connectionErrorMessage = "Failed to resume WebRTC stream: \(connectionErrorDetail(error))"
                OverlookLog.error("Manual stream resume failed host=\(device.host) port=\(device.port) error=\(OverlookLog.describe(error))")
            }
        }
    }

    @MainActor
    private func updateWindowStreamVisibility() {
        let window = windowRef ?? NSApp.keyWindow
        let isActuallyVisible = window?.isVisible == true
            && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
            && NSApp.isHidden == false

        guard isWindowStreamVisible != isActuallyVisible else { return }
        isWindowStreamVisible = isActuallyVisible
        scheduleHiddenStreamQualityUpdate()
    }

    @MainActor
    private func scheduleHiddenStreamQualityUpdate() {
        hiddenStreamTask?.cancel()
        hiddenStreamTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)

            guard reduceHiddenStreamQuality else {
                await restoreHiddenStreamQualityIfNeeded()
                return
            }

            guard isConnected, isStreamPaused == false, kvmDeviceManager.glkvmClient != nil else {
                await restoreHiddenStreamQualityIfNeeded()
                return
            }

            if isWindowStreamVisible {
                await restoreHiddenStreamQualityIfNeeded()
            } else {
                await reduceHiddenStreamQualityIfNeeded()
            }
        }
    }

    @MainActor
    private func reduceHiddenStreamQualityIfNeeded() async {
        guard hiddenStreamSnapshot == nil else { return }
        guard let client = kvmDeviceManager.glkvmClient else { return }

        do {
            let state = try await client.getStreamerState()
            guard let current = state.params else { return }

            hiddenStreamSnapshot = HiddenStreamSnapshot(
                desiredFps: current.desiredFps,
                quality: current.quality,
                h264Bitrate: current.h264Bitrate,
                h264Gop: current.h264Gop,
                zeroDelay: current.zeroDelay,
                resolution: current.resolution
            )

            var params: [String: String] = [:]
            if let limits = state.limits {
                params["desired_fps"] = String(clamp(5, min: limits.desiredFps.min, max: limits.desiredFps.max))
                if state.features?.h264 != false {
                    params["h264_bitrate"] = String(clamp(350, min: limits.h264Bitrate.min, max: limits.h264Bitrate.max))
                    params["h264_gop"] = String(clamp(30, min: limits.h264Gop.min, max: limits.h264Gop.max))
                }
            } else if current.desiredFps != nil {
                params["desired_fps"] = "5"
            }

            if state.features?.quality != false, current.quality != nil {
                params["quality"] = "20"
            }

            guard params.isEmpty == false else {
                hiddenStreamSnapshot = nil
                return
            }

            try await client.setStreamerParams(params)
            OverlookLog.info("Hidden window stream reduction applied params=\(params)")
        } catch {
            hiddenStreamSnapshot = nil
            OverlookLog.error("Hidden window stream reduction failed error=\(OverlookLog.describe(error))")
        }
    }

    @MainActor
    private func restoreHiddenStreamQualityIfNeeded() async {
        guard let snapshot = hiddenStreamSnapshot else { return }
        hiddenStreamSnapshot = nil
        guard let client = kvmDeviceManager.glkvmClient else { return }

        var params: [String: String] = [:]
        if let desiredFps = snapshot.desiredFps {
            params["desired_fps"] = String(desiredFps)
        }
        if let quality = snapshot.quality {
            params["quality"] = String(quality)
        }
        if let bitrate = snapshot.h264Bitrate {
            params["h264_bitrate"] = String(bitrate)
        }
        if let gop = snapshot.h264Gop {
            params["h264_gop"] = String(gop)
        }
        if let zeroDelay = snapshot.zeroDelay {
            params["zero_delay"] = zeroDelay ? "true" : "false"
        }
        if let resolution = snapshot.resolution?.trimmingCharacters(in: .whitespacesAndNewlines),
           resolution.isEmpty == false {
            params["resolution"] = resolution
        }

        guard params.isEmpty == false else { return }

        do {
            try await client.setStreamerParams(params)
            OverlookLog.info("Hidden window stream settings restored")
        } catch {
            OverlookLog.error("Hidden window stream settings restore failed error=\(OverlookLog.describe(error))")
            connectionErrorMessage = "Failed to restore stream quality after hidden-window reduction: \(connectionErrorDetail(error))"
        }
    }

    private func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
    
    @MainActor
    private func fitWindowToGuest() {
        guard let videoSize = webRTCManager.videoSize,
              videoSize.width > 0,
              videoSize.height > 0 else { return }
        guard let window = windowRef ?? NSApp.keyWindow else { return }

        let currentFrame = window.frame
        let currentLayout = window.contentLayoutRect

        let deltaW = currentFrame.size.width - currentLayout.size.width
        let deltaH = currentFrame.size.height - currentLayout.size.height

        var desiredLayoutW = CGFloat(videoSize.width)
        var desiredLayoutH = CGFloat(videoSize.height)

        if let screen = window.screen ?? NSScreen.main {
            let maxLayoutW = max(100, screen.visibleFrame.size.width - deltaW)
            let maxLayoutH = max(100, screen.visibleFrame.size.height - deltaH)
            let scale = min(1.0, maxLayoutW / desiredLayoutW, maxLayoutH / desiredLayoutH)
            desiredLayoutW = floor(desiredLayoutW * scale)
            desiredLayoutH = floor(desiredLayoutH * scale)
        }

        var newFrame = currentFrame
        newFrame.size = NSSize(width: desiredLayoutW + deltaW, height: desiredLayoutH + deltaH)
        newFrame.origin.y += currentFrame.size.height - newFrame.size.height
        window.setFrame(newFrame, display: true, animate: true)
    }

    @MainActor
    private func updateInputCaptureForUIOverlays() {
        let overlayOpen = showingSettings || showingConnections

        if overlayOpen {
            if isInputCapturePausedForUI == false {
                pausedCaptureKeyboardWasEnabled = inputManager.isKeyboardCaptureEnabled
                pausedCaptureMouseWasEnabled = inputManager.isMouseCaptureEnabled

                if inputManager.isKeyboardCaptureEnabled {
                    inputManager.stopKeyboardCapture()
                }
                if inputManager.isMouseCaptureEnabled {
                    inputManager.stopMouseCapture()
                }

                isInputCapturePausedForUI = true
            }
            return
        }

        guard isInputCapturePausedForUI else { return }

        if isConnected {
            if let wasKeyboard = pausedCaptureKeyboardWasEnabled {
                if wasKeyboard {
                    inputManager.startKeyboardCapture()
                }
            }
            if let wasMouse = pausedCaptureMouseWasEnabled {
                if wasMouse {
                    inputManager.startMouseCapture()
                }
            }
        }

        pausedCaptureKeyboardWasEnabled = nil
        pausedCaptureMouseWasEnabled = nil
        isInputCapturePausedForUI = false
    }
}

private struct WindowReferenceSetter: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let w = nsView.window else { return }
        if window !== w {
            DispatchQueue.main.async {
                window = w
            }
        }
    }
}

private struct WindowAspectRatioSetter: NSViewRepresentable {
    let videoSize: CGSize?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        if context.coordinator.window !== window {
            context.coordinator.didConfigureWindow = true
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                window.titlebarAppearsTransparent = false
                window.styleMask.remove(.fullSizeContentView)
                coordinator.attach(to: window)
                coordinator.restoreSavedPlacementIfNeeded(window: window)
            }
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            if context.coordinator.lastAspect != nil {
                context.coordinator.lastAspect = nil
                context.coordinator.didInitialResizeForAspect = false
                context.coordinator.videoAspect = nil
            }
            return
        }

        let aspect = NSSize(width: videoSize.width, height: videoSize.height)
        if let last = context.coordinator.lastAspect {
            let dw = abs(last.width - aspect.width)
            let dh = abs(last.height - aspect.height)
            if dw < 1, dh < 1 {
                return
            }
        }

        context.coordinator.lastAspect = aspect
        context.coordinator.videoAspect = Double(aspect.width / aspect.height)

        if context.coordinator.didInitialResizeForAspect == false {
            context.coordinator.didInitialResizeForAspect = true

            let currentFrame = window.frame
            let currentLayout = window.contentLayoutRect.size
            let deltaH = currentFrame.size.height - currentLayout.height

            if currentLayout.width > 0 {
                let desiredLayoutHeight = currentLayout.width * (aspect.height / aspect.width)
                if desiredLayoutHeight.isFinite, desiredLayoutHeight > 0 {
                    var newFrame = currentFrame
                    newFrame.size.height = desiredLayoutHeight + deltaH
                    DispatchQueue.main.async {
                        window.setFrame(newFrame, display: true)
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject {
        var lastAspect: NSSize?
        var didInitialResizeForAspect: Bool = false
        var didConfigureWindow: Bool = false

        weak var window: NSWindow?
        weak var forwardedDelegate: NSWindowDelegate?
        var videoAspect: Double?

        private var storedWindowedTitlebarAppearsTransparent: Bool?
        private var storedWindowedStyleMaskHadFullSizeContentView: Bool?
        private var storedWindowedTitleVisibility: NSWindow.TitleVisibility?
        private var storedWindowedToolbarIsVisible: Bool?
        private var didRestoreSavedPlacement = false
        private var isClosingFromFullscreen = false

        private static let frameDefaultsKey = "overlook.window.frame"
        private static let screenIDDefaultsKey = "overlook.window.screenID"
        private static let fullscreenDefaultsKey = "overlook.window.fullscreen"

        func attach(to window: NSWindow) {
            if self.window === window {
                return
            }

            detach()
            self.window = window
            forwardedDelegate = window.delegate
            window.delegate = self

            if storedWindowedTitlebarAppearsTransparent == nil {
                storedWindowedTitlebarAppearsTransparent = window.titlebarAppearsTransparent
                storedWindowedStyleMaskHadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
                storedWindowedTitleVisibility = window.titleVisibility
                storedWindowedToolbarIsVisible = window.toolbar?.isVisible
            }
        }

        func restoreSavedPlacementIfNeeded(window: NSWindow) {
            guard didRestoreSavedPlacement == false else { return }
            didRestoreSavedPlacement = true

            window.setFrameAutosaveName("OverlookMainWindow")

            if let savedFrame = Self.savedFrame() {
                let screen = Self.savedScreen() ?? window.screen ?? NSScreen.main
                let restoredFrame = Self.constrainedFrame(savedFrame, on: screen)
                window.setFrame(restoredFrame, display: true, animate: false)
                didInitialResizeForAspect = true
            }

            guard UserDefaults.standard.bool(forKey: Self.fullscreenDefaultsKey) else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard window.isVisible, window.styleMask.contains(.fullScreen) == false else { return }
                window.toggleFullScreen(nil)
            }
        }

        func detach() {
            if let window, window.delegate === self {
                window.delegate = forwardedDelegate
            }
            self.window = nil
            forwardedDelegate = nil
        }

        deinit {
            detach()
        }

        private func applyFullscreenChrome(window: NSWindow) {
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar?.isVisible = true
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .automatic
            }
        }

        private func restoreWindowedChrome(window: NSWindow) {
            if let stored = storedWindowedTitlebarAppearsTransparent {
                window.titlebarAppearsTransparent = stored
            }
            if let hadFullSize = storedWindowedStyleMaskHadFullSizeContentView {
                if hadFullSize {
                    window.styleMask.insert(.fullSizeContentView)
                } else {
                    window.styleMask.remove(.fullSizeContentView)
                }
            }
            if let stored = storedWindowedTitleVisibility {
                window.titleVisibility = stored
            }
            if let stored = storedWindowedToolbarIsVisible {
                window.toolbar?.isVisible = stored
            }
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .automatic
            }
        }

        private func savePlacement(window: NSWindow, fullscreen: Bool? = nil) {
            let isFullscreen = fullscreen ?? window.styleMask.contains(.fullScreen)
            UserDefaults.standard.set(isFullscreen, forKey: Self.fullscreenDefaultsKey)

            if let screenID = Self.screenID(window.screen) {
                UserDefaults.standard.set(screenID, forKey: Self.screenIDDefaultsKey)
            }

            guard isFullscreen == false else { return }

            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
        }

        private static func savedFrame() -> NSRect? {
            guard let string = UserDefaults.standard.string(forKey: frameDefaultsKey) else { return nil }
            let frame = NSRectFromString(string)
            guard frame.width > 0, frame.height > 0 else { return nil }
            return frame
        }

        private static func savedScreen() -> NSScreen? {
            guard UserDefaults.standard.object(forKey: screenIDDefaultsKey) != nil else { return nil }
            let savedID = UserDefaults.standard.integer(forKey: screenIDDefaultsKey)
            return NSScreen.screens.first { screenID($0) == savedID }
        }

        private static func screenID(_ screen: NSScreen?) -> Int? {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen?.deviceDescription[key] as? NSNumber)?.intValue
        }

        private static func constrainedFrame(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
            guard let screen else { return frame }

            let visible = screen.visibleFrame
            let width = min(max(frame.width, 640), visible.width)
            let height = min(max(frame.height, 420), visible.height)
            let x = min(max(frame.minX, visible.minX), visible.maxX - width)
            let y = min(max(frame.minY, visible.minY), visible.maxY - height)

            return NSRect(x: x, y: y, width: width, height: height)
        }

        private func adjustFrameToVideoAspect(window: NSWindow) {
            guard let aspect = videoAspect, aspect.isFinite, aspect > 0 else { return }

            let currentFrame = window.frame
            let currentLayout = window.contentLayoutRect.size

            let deltaH = currentFrame.size.height - currentLayout.height

            guard currentLayout.width > 0 else { return }

            let desiredLayoutH = currentLayout.width / aspect
            guard desiredLayoutH.isFinite, desiredLayoutH > 0 else { return }

            var newFrame = currentFrame
            newFrame.size.height = desiredLayoutH + deltaH
            newFrame.origin.y += currentFrame.size.height - newFrame.size.height
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
}

extension WindowAspectRatioSetter.Coordinator: NSWindowDelegate {
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        var options = proposedOptions
        options.insert(.autoHideToolbar)
        return options
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        isClosingFromFullscreen = sender.styleMask.contains(.fullScreen)
        if isClosingFromFullscreen {
            savePlacement(window: sender, fullscreen: true)
        }

        if let forwardedDelegate,
           forwardedDelegate.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            return forwardedDelegate.windowShouldClose?(sender) ?? true
        }

        return true
    }

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            savePlacement(window: window)
        }
        forwardedDelegate?.windowDidMove?(notification)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let aspect = videoAspect else { return frameSize }

        let currentFrame = sender.frame.size
        let currentLayout = sender.contentLayoutRect.size

        let deltaW = currentFrame.width - currentLayout.width
        let deltaH = currentFrame.height - currentLayout.height

        let proposedLayoutW = frameSize.width - deltaW
        let proposedLayoutH = frameSize.height - deltaH

        guard proposedLayoutW > 0, proposedLayoutH > 0 else { return frameSize }

        let dw = abs(frameSize.width - currentFrame.width)
        let dh = abs(frameSize.height - currentFrame.height)

        let constrained: NSSize
        if dw >= dh {
            let desiredLayoutH = proposedLayoutW / aspect
            constrained = NSSize(width: frameSize.width, height: desiredLayoutH + deltaH)
        } else {
            let desiredLayoutW = proposedLayoutH * aspect
            constrained = NSSize(width: desiredLayoutW + deltaW, height: frameSize.height)
        }

        if let forwardedDelegate,
           forwardedDelegate.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))) {
            return forwardedDelegate.windowWillResize?(sender, to: constrained) ?? constrained
        }

        return constrained
    }

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            savePlacement(window: window)
        }
        forwardedDelegate?.windowDidResize?(notification)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            savePlacement(window: window, fullscreen: isClosingFromFullscreen ? true : nil)
        }
        forwardedDelegate?.windowWillClose?(notification)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            savePlacement(window: window, fullscreen: false)
        }
        forwardedDelegate?.windowWillEnterFullScreen?(notification)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            forwardedDelegate?.windowDidEnterFullScreen?(notification)
            return
        }
        savePlacement(window: window, fullscreen: true)
        applyFullscreenChrome(window: window)
        forwardedDelegate?.windowDidEnterFullScreen?(notification)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            savePlacement(window: window, fullscreen: isClosingFromFullscreen ? true : false)
        }
        forwardedDelegate?.windowWillExitFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            forwardedDelegate?.windowDidExitFullScreen?(notification)
            return
        }
        restoreWindowedChrome(window: window)
        savePlacement(window: window, fullscreen: isClosingFromFullscreen ? true : false)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.isClosingFromFullscreen == false else { return }
            self.adjustFrameToVideoAspect(window: window)
            self.savePlacement(window: window, fullscreen: false)
        }

        forwardedDelegate?.windowDidExitFullScreen?(notification)
    }
}

private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        DispatchQueue.main.async {
            if window.title != title {
                window.title = title
            }
            window.titleVisibility = .visible
        }
    }
}

struct ConnectionsPopoverView: View {
    @Binding var selectedDevice: KVMDevice?

    let isConnected: Bool
    let isScanning: Bool
    let devices: [KVMDevice]
    let connectedDeviceName: String?
    let latency: Int

    let videoSize: CGSize?
    let inboundVideoKbps: Int?
    let inboundFps: Double?
    let inboundVideoPlayoutDelayMs: Int?
    let inboundVideoJitterMs: Int?
    let inboundVideoDecodeMs: Int?
    let inboundVideoPacketsLost: Int?
    let iceCurrentRoundTripTimeMs: Int?

    let inboundAudioKbps: Int?
    let inboundAudioPlayoutDelayMs: Int?
    let inboundAudioJitterMs: Int?
    let inboundAudioPacketsLost: Int?
    let audioIceCurrentRoundTripTimeMs: Int?
    let sessionVideoBytesReceived: Int64?
    let sessionAudioBytesReceived: Int64?
    let sessionAudioBytesSent: Int64?
    let isConnectionBusy: Bool
    let connectionErrorMessage: String?

    let onScan: () -> Void
    let onManualConnect: () -> Void
    let onToggleConnection: () -> Void
    let onForgetSelectedDevice: () -> Void

    var body: some View {
        let resolutionText: String = {
            guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return "—" }
            return "\(Int(videoSize.width))x\(Int(videoSize.height))"
        }()

        let kbpsText = inboundVideoKbps.map { "\($0) kbps" } ?? "— kbps"
        let fpsText = inboundFps.map { "\(Int($0.rounded())) fps" } ?? "— fps"
        let playoutDelayText = inboundVideoPlayoutDelayMs.map { "\($0) ms" } ?? "—"
        let jitterText = inboundVideoJitterMs.map { "\($0) ms" } ?? "—"
        let decodeText = inboundVideoDecodeMs.map { "\($0) ms" } ?? "—"
        let lossText = inboundVideoPacketsLost.map { String($0) } ?? "—"
        let rttText = iceCurrentRoundTripTimeMs.map { "\($0) ms" } ?? "—"

        let audioKbpsText = inboundAudioKbps.map { "\($0) kbps" } ?? "— kbps"
        let audioPlayoutDelayText = inboundAudioPlayoutDelayMs.map { "\($0) ms" } ?? "—"
        let audioJitterText = inboundAudioJitterMs.map { "\($0) ms" } ?? "—"
        let audioLossText = inboundAudioPacketsLost.map { String($0) } ?? "—"
        let audioRttText = audioIceCurrentRoundTripTimeMs.map { "\($0) ms" } ?? "—"
        let downstreamBytes = [sessionVideoBytesReceived, sessionAudioBytesReceived].compactMap { $0 }.reduce(Int64(0), +)
        let upstreamBytes = sessionAudioBytesSent ?? 0
        let hasTrafficStats = sessionVideoBytesReceived != nil || sessionAudioBytesReceived != nil || sessionAudioBytesSent != nil
        let totalTrafficText = hasTrafficStats ? Self.formatBytes(downstreamBytes + upstreamBytes) : "—"
        let trafficDetailText = hasTrafficStats
            ? "Down \(Self.formatBytes(downstreamBytes)) · Up \(Self.formatBytes(upstreamBytes))"
            : "Down — · Up —"
        let displayedDevice = selectedDevice ?? (devices.count == 1 ? devices[0] : nil)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connections")
                    .font(.headline)
                Spacer()
                Button(action: onToggleConnection) {
                    if isConnectionBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isConnected ? "personalhotspot.slash" : "personalhotspot")
                    }
                }
                .disabled(isConnectionBusy || (!isConnected && selectedDevice == nil && devices.count != 1))
                .help(isConnected ? "Disconnect" : "Connect")
            }

            Picker("Device", selection: $selectedDevice) {
                Text("Select Device").tag(nil as KVMDevice?)
                ForEach(devices) { device in
                    Text(device.name).tag(device as KVMDevice?)
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Button("Scan") { onScan() }
                    .disabled(isScanning)

                Button("Manual Connect…") { onManualConnect() }

                Button("Forget") { onForgetSelectedDevice() }
                    .disabled(isConnected || selectedDevice?.id.hasPrefix("saved-") != true)

                Spacer()

                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            if let connectionErrorMessage, !connectionErrorMessage.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(connectionErrorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(connectedDeviceName ?? (displayedDevice?.name ?? "No Device"))
                    .font(.caption)

                HStack {
                    Text(isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundColor(isConnected ? .green : .red)

                    Spacer()

                    Text("Latency: \(latency)ms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WebRTC")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Video")
                        .font(.caption)
                    Spacer()
                    Text("\(resolutionText) · \(fpsText) · \(kbpsText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Playout")
                        .font(.caption)
                    Spacer()
                    Text(playoutDelayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Jitter")
                        .font(.caption)
                    Spacer()
                    Text(jitterText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Decode")
                        .font(.caption)
                    Spacer()
                    Text(decodeText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Lost")
                        .font(.caption)
                    Spacer()
                    Text(lossText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("ICE RTT")
                        .font(.caption)
                    Spacer()
                    Text(rttText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Traffic")
                        .font(.caption)
                    Spacer()
                    Text(totalTrafficText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Traffic Detail")
                        .font(.caption)
                    Spacer()
                    Text(trafficDetailText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if inboundAudioKbps != nil || inboundAudioJitterMs != nil || inboundAudioPacketsLost != nil || audioIceCurrentRoundTripTimeMs != nil {
                    HStack {
                        Text("Audio")
                            .font(.caption)
                        Spacer()
                        Text(audioKbpsText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Audio Playout")
                            .font(.caption)
                        Spacer()
                        Text(audioPlayoutDelayText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Audio Jitter")
                            .font(.caption)
                        Spacer()
                        Text(audioJitterText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Audio Lost")
                            .font(.caption)
                        Spacer()
                        Text(audioLossText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Audio ICE RTT")
                            .font(.caption)
                        Spacer()
                        Text(audioRttText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(14)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        if value < 10 {
            return String(format: "%.1f %@", value, units[unitIndex])
        }
        return String(format: "%.0f %@", value, units[unitIndex])
    }
}

#Preview {
    ContentView()
        .environmentObject(WebRTCManager())
        .environmentObject(InputManager())
        .environmentObject(OCRManager())
        .environmentObject(KVMDeviceManager())
}
