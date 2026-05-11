import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif
import Vision
import Network

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
