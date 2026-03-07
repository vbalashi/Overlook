# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**Build from command line (no code signing):**
```bash
xcodebuild build \
  -project Overlook.xcodeproj \
  -scheme Overlook \
  -configuration Debug \
  -sdk macosx \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
```

**Resolve Swift package dependencies:**
```bash
xcodebuild -resolvePackageDependencies -project Overlook.xcodeproj -scheme Overlook
```

**Before building, ensure Preview Content directory exists:**
```bash
mkdir -p "Overlook/Preview Content"
```

Normal development is done via Xcode (`Overlook.xcodeproj`, scheme `Overlook`). There are no unit tests in this project.

## Architecture Overview

Overlook is a macOS 14+ SwiftUI app (AppKit delegate) for controlling GL.iNet GLKVM/Comet KVM-over-IP devices. The main dependency is `stasel/WebRTC` (Swift Package).

### Manager Layer (ObservableObject, all @MainActor)

- **`KVMDeviceManager`** — Device lifecycle: mDNS discovery, network scanning, probing common targets (192.168.200.x), saving/loading devices from UserDefaults, authentication (cookie token). Holds the active `GLKVMClient`.
- **`WebRTCManager`** — WebRTC peer connection via Janus signaling over WebSocket (`wss://<host>:<port>/janus/ws`). Manages separate audio/video peer connections. Collects receiver stats (bitrate, fps, jitter, decode time, packet loss, ICE RTT) published for the window title. Handles optional audio output and mic tracks via `WebRTCAudioDevice` / `CoreAudioDevices`.
- **`InputManager`** — Keyboard/mouse capture via `CGEvent` tap. Translates macOS events to HID WebSocket messages sent to the device. Intercepts `⌘V` for clipboard paste (calls GLKVM's "print text" HID API). Manages input capture state.
- **`OCRManager`** — Apple Vision OCR pipeline. Captures frames from the WebRTC video track, runs `VNRecognizeTextRequest`, returns recognized text and bounding boxes for overlay.

### UI Layer

- **`ContentView`** — Root SwiftUI view. Hosts the main window, toolbar, video surface, and fullscreen experience. Injects all managers via `@EnvironmentObject`.
- **`VideoSurfaceView`** — Wraps the WebRTC `RTCMTLVideoView`. Routes mouse/scroll events to `InputManager`. Implements OCR selection gestures (click and drag-rectangle).
- **`ContentControlBar`** — Toolbar/control bar shown in normal and fullscreen modes.
- **`ConnectionsPopoverView`** — Shows audio/video stream stats.
- **`ConnectSheets`** — Scan results, manual connect, and authentication password prompt sheets.
- **`MenuBarAgent`** — Status bar item with quick actions. Registers global shortcuts (`⌘⇧O/R/V`).
- **`WebUISettingsPanel`** — Settings UI: video quality presets, EDID selection/custom, audio/mic toggles. Mapped to GLKVM WebUI API parameters.

### Device API Layer

- **`GLKVMClient`** — All HTTP API calls to the device: streamer params, system config, EDID, HID "print text", auth. Uses `GLKVMResponse<T>` wrapper for JSON decoding. `JSONValue` handles heterogeneous JSON.
- **`HardwareControlManager`** — ATX power/reset controls via the device API.
- **`PluginManager`** — Plugin/extension hooks (currently minimal).
- **`TailscaleManager`** — Tailscale integration for device discovery over Tailnet.

### Bridging (Obj-C/C++)

- `WebRTCFactoryBuilder.h/.m` — Obj-C wrapper to configure the `RTCPeerConnectionFactory` with custom audio device.
- `RTCAudioDeviceShim.h` — Shim for the WebRTC audio device protocol.
- `Overlook-Bridging-Header.h` — Exposes the above to Swift.

## Key Patterns

- All managers are `@MainActor` `ObservableObject` singletons instantiated in `AppDelegate` and passed down via SwiftUI environment.
- Device connections allow insecure TLS (self-signed certs on KVM devices) — both `KVMDeviceManager` and `WebRTCManager` have `URLSessionDelegate` implementations that bypass cert validation when configured.
- Audio and video use **separate** WebRTC peer connections to allow independent reconnect and reduce playout latency.
- Stats from WebRTC receiver reports are surfaced in the window title via a timer loop in `WebRTCManager`.
