import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif
import Vision
import Network

extension Notification.Name {
    static let overlookShowSettings = Notification.Name("overlook.showSettings")
    static let overlookShowConnections = Notification.Name("overlook.showConnections")
}

@main
struct OverlookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.webRTCManager)
                .environmentObject(appDelegate.inputManager)
                .environmentObject(appDelegate.ocrManager)
                .environmentObject(appDelegate.kvmDeviceManager)
                .environmentObject(appDelegate.quickPasteManager)
                .environmentObject(appDelegate.agentServerManager)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
        .commands {
            RemoteCommands(
                kvmDeviceManager: appDelegate.kvmDeviceManager,
                inputManager: appDelegate.inputManager,
                showSettings: {
                    appDelegate.showSettings()
                },
                showConnections: {
                    appDelegate.showConnections()
                }
            )

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

struct RemoteCommands: Commands {
    @ObservedObject var kvmDeviceManager: KVMDeviceManager
    let inputManager: InputManager
    let showSettings: () -> Void
    let showConnections: () -> Void

    var body: some Commands {
        CommandMenu("Remote") {
            Button("New Connection...") {
                showConnections()
            }

            Button("Show Statistics") {
                showConnections()
            }

            Divider()

            Button("Paste Mac Clipboard to Remote") {
                inputManager.pasteMacClipboardToRemote()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("OCR Copy from Screen") {
                inputManager.startSnippetOCR()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Divider()

            Button("Settings...") {
                showSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Text("Send Remote Shortcut")

            if kvmDeviceManager.systemShortcuts.isEmpty {
                Text(kvmDeviceManager.glkvmClient == nil ? "Connect to a device first" : "No shortcuts available")
            } else {
                ForEach(kvmDeviceManager.systemShortcuts, id: \.self) { shortcut in
                    Button(shortcut.label) {
                        sendShortcut(shortcut)
                    }
                }
            }
        }
    }

    private func sendShortcut(_ shortcut: GLKVMSystemConfigShortcut) {
        guard let client = kvmDeviceManager.glkvmClient else { return }
        Task {
            do {
                try await client.sendHidShortcut(keys: shortcut.keys)
            } catch {
                OverlookLog.error("Failed to send menu shortcut \(shortcut.label): \(OverlookLog.describe(error))")
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarAgent: MenuBarAgent?

    let webRTCManager = WebRTCManager()
    let inputManager = InputManager()
    let ocrManager = OCRManager()
    let kvmDeviceManager = KVMDeviceManager()
    let quickPasteManager = QuickPasteManager()
    let agentServerManager = AgentServerManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        OverlookLog.info("Application launched. logPath=\(OverlookLog.fileURL.path)")
        agentServerManager.setup(inputManager: inputManager, kvmDeviceManager: kvmDeviceManager, webRTCManager: webRTCManager)
        if UserDefaults.standard.bool(forKey: AgentServerManager.enabledDefaultsKey) {
            agentServerManager.start()
        }

        menuBarAgent = MenuBarAgent(
            kvmDeviceManager: kvmDeviceManager,
            webRTCManager: webRTCManager,
            inputManager: inputManager,
            showMainWindow: { [weak self] in
                self?.showMainWindow()
            }
        )
        menuBarAgent?.setup()
        
        // Configure app for KVM control
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        showMainWindow()
        NotificationCenter.default.post(name: .overlookShowSettings, object: nil)
    }

    func showConnections() {
        showMainWindow()
        NotificationCenter.default.post(name: .overlookShowConnections, object: nil)
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let windows = NSApp.windows
        let candidate = windows.first(where: { $0.canBecomeKey && $0.isVisible }) ?? windows.first(where: { $0.canBecomeKey })
        candidate?.makeKeyAndOrderFront(nil)
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        menuBarAgent?.cleanup()
        agentServerManager.stop()
        return .terminateNow
    }
}
