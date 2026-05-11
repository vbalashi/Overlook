import SwiftUI

struct ContentControlBar: View {
    @EnvironmentObject var quickPasteManager: QuickPasteManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager

    @Binding var selectedDevice: KVMDevice?

    let devices: [KVMDevice]
    let isScanning: Bool
    let isConnected: Bool
    let isOCRModeEnabled: Bool

    @Binding var showingSettings: Bool
    @Binding var showingManualConnect: Bool

    let onDeviceChanged: (KVMDevice?) -> Void
    let onScan: () -> Void
    let onToggleOCR: () -> Void
    let onToggleConnection: () -> Void

    @State private var showingQuickPaste = false

    var body: some View {
        HStack {
            Picker("Device", selection: $selectedDevice) {
                Text("Select Device").tag(nil as KVMDevice?)
                ForEach(devices) { device in
                    Text(device.name).tag(device as KVMDevice?)
                }
            }
            .frame(width: 200)
            .onChange(of: selectedDevice) { _, newDevice in
                onDeviceChanged(newDevice)
            }

            Button("Scan") {
                onScan()
            }
            .disabled(isScanning)
            .help("Scan for devices on the network")

            Button("Manual Connect…") {
                showingManualConnect = true
            }
            .help("Manually enter a device host/IP")

            Spacer()

            Button(action: { showingQuickPaste.toggle() }) {
                Image(systemName: "bolt.fill")
            }
            .help("Quick Paste")
            .popover(isPresented: $showingQuickPaste, arrowEdge: .bottom) {
                QuickPasteView()
                    .environmentObject(quickPasteManager)
                    .environmentObject(kvmDeviceManager)
            }

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() } }) {
                Image(systemName: "gearshape")
            }
            .disabled(!isConnected)
            .help("Settings")

            Button(action: onToggleOCR) {
                Image(systemName: isOCRModeEnabled ? "text.viewfinder" : "doc.text")
            }
            .disabled(!isConnected)
            .help(isOCRModeEnabled ? "Disable OCR Selection (⌘⇧C)" : "Enable OCR Selection (⌘⇧C)")

            Button(action: onToggleConnection) {
                Image(systemName: isConnected ? "personalhotspot.slash" : "personalhotspot")
            }
            .disabled(selectedDevice == nil)
            .help(isConnected ? "Disconnect" : "Connect")
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}
