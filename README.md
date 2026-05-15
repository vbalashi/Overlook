# Overlook

[![Xcode - Build](https://github.com/vbalashi/Overlook/actions/workflows/objective-c-xcode.yml/badge.svg)](https://github.com/vbalashi/Overlook/actions/workflows/objective-c-xcode.yml)

This is a curated fork of [`rcawston/Overlook`](https://github.com/rcawston/Overlook), combining selected improvements from the `dh0er` and `moming2k` forks with focused macOS UX refinements.

Overlook is a macOS-native remote console for GL.iNet GLKVM / Comet-style KVM devices.

![Overlook Screenshot](./OverlookScreenshot.png)

It focuses on *fast*, *low-friction* day-to-day “reach over and fix it” workflows:

- Low-latency WebRTC video streaming (Janus signaling).
- Full keyboard + mouse input capture.
- **Clipboard bridging**:
  - **Local → Remote paste** with `⌘⇧V` (types the Mac clipboard into the remote machine via HID).
  - **Remote → Local snippet OCR** with `⌘⇧C`: drag a rectangle on the video, Overlook OCRs the region and copies the text to your Mac clipboard.

If you spend time in BIOS/UEFI, bootloaders, headless servers, or “the machine that’s *just* out of reach”, Overlook aims to make the remote console feel like a first-class Mac app.

---

## What is different in this fork?

Compared with the original `rcawston/Overlook`, this fork focuses on making Overlook more usable as a daily-driver Mac KVM console:

- **Better input workflow:** selected keyboard-routing and shortcut handling improvements from `dh0er`, including safer local shortcut passthrough and cleanup of modifier state.
- **Clipboard and OCR tools:** one-shot snippet OCR (`⌘⇧C`) and Mac-to-remote paste (`⌘⇧V`) for moving text in and out of machines that do not have normal clipboard integration.
- **Connection and diagnostics polish:** receiver stats surfaced in the UI, improved fullscreen controls, connection handling, and a WebUI-aligned settings panel.
- **Power-user additions:** selected automation/Agent API and Quick Paste pieces from `moming2k`, kept behind focused UI instead of broad feature sprawl.
- **Our local refinements:** flatter app menus for remote commands, menu access to settings/statistics/new connection, device-provided shortcuts in the app menu, app icon updates, and build-script cleanup so Spotlight sees a single app bundle.

The goal is not to rewrite Overlook, but to collect the most practical fork improvements into one coherent macOS app.

---

## Highlights

### 1) Copy from the remote screen with `⌘⇧C`

Overlook includes a **one-shot snippet OCR** for pulling text off the remote:

- Press `⌘⇧C` anywhere in the Overlook window.
- A selection overlay appears over the video.
- Drag a rectangle around the text you want.
- Overlook runs on-device OCR (Apple Vision framework) on that region,
  copies the recognized text straight to your Mac clipboard, and shows a
  brief “Text copied” HUD.

This is especially useful for:

- Capturing one-time passwords, serial numbers, IPs, MAC addresses.
- Copying terminal output from machines with no clipboard integration.
- Copying text in pre-boot environments.

**Note:** OCR is performed locally on your Mac.

### 2) Paste the Mac clipboard to the remote with `⌘⇧V`

When connected and input capture is active, `⌘⇧V` reads your macOS
clipboard and sends it to the remote machine via the device’s HID
text-entry API.

Plain `⌘V` is forwarded to the remote as-is (i.e. the remote OS
interprets it against its own clipboard).

### 3) Low-latency WebRTC video

Overlook uses WebRTC for streaming and collects receiver stats (bitrate, fps, jitter buffer / playout delay, decode time, packet loss, ICE RTT).

These stats are surfaced in the window title, which makes diagnosing latency issues and tuning quality settings much easier.

### 4) A focused Settings panel (WebUI-aligned)

The Settings UI is intentionally aligned with GLKVM’s WebUI behavior where it matters:

- **Video quality presets** (Low/Medium/High/Ultra-high/Insane/Custom).
- **EDID** selection and custom EDID entry.
- Audio + microphone toggles (reconnect required).

---

## What devices are supported?

Overlook is built around GL.iNet’s GLKVM/Comet HTTP + WebRTC stack.

In code, devices are modeled as `KVMDevice` and discovered/managed by `KVMDeviceManager`.

If you have:

- GL.iNet Comet / GLKVM
- A GLKVM-compatible device exposing Janus signaling at `wss://<host>:<port>/janus/ws`

…Overlook is intended to work.

For now, it's only designed for local network use or direct IP connections (e.g. over VPN).

---

## Installation

### Requirements

- macOS 14+ (deployment target in project is macOS 14.0).
- Xcode (use the repository’s `Overlook.xcodeproj`).
- Network access to your KVM device.

### WebRTC dependency

Overlook uses the Swift Package:

- `https://github.com/stasel/WebRTC` (pinned in `Package.resolved`)

### Build

1. Open `Overlook.xcodeproj` in Xcode.
2. Select the `Overlook` scheme.
3. Build + Run.

---

## Quick Start (How to use Overlook)

### 1) Discover or add a device

Overlook supports multiple discovery methods (mDNS + network scanning + common target probes) and also manual entry.

From the main window:

- Click **Scan** to search your network.
- Or click **Manual Connect…** to enter host/IP and port.

From the menu bar:

- Use the Overlook status item to scan and connect quickly.

### 2) Connect

Select a device, then connect.

On connect, Overlook will:

- Authenticate to the device API (cookie token).
- Enable HID on the device.
- Start WebRTC streaming.
- Start keyboard/mouse capture.

If authentication fails, you’ll be prompted for a password and Overlook will attempt a login.

### 3) Control the remote machine

Once connected:

- Mouse movement, clicks, dragging, and scroll are forwarded.
- Keyboard is captured and forwarded.
- Standard UX flows like fullscreen work well for “monitor replacement” usage.

---

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
  device’s HID text-entry API.

This is ideal for:

- Commands
- URLs
- Password-manager output (use responsibly)
- Small scripts / config snippets

### Tips

- Large pastes may take time for the remote to process. Paste in smaller
  chunks in BIOS/UEFI or slow boot environments.

---

## Keyboard shortcuts

Overlook forwards most key events to the remote while input capture is
enabled. A small local whitelist keeps common Mac shortcuts working.

### Local (stay on the Mac / consumed by Overlook)

- `⌘⇧C`: start the one-shot snippet OCR described above.
- `⌘⇧V`: type the Mac clipboard into the remote via HID.
- `Escape` while the snippet overlay is showing: cancel without OCR.

### Forwarded to the remote

Everything else, including `⌘C`, `⌘V`, `⌘Q`, `⌘W`, `⌘H`, `⌘M`, and so
on. `⌘` is forwarded as the remote Meta/Windows key, and `⌥Tab` is
forwarded as remote `Alt+Tab`. `⌘⇧S` reaches Windows as `Win+Shift+S` for the
snipping shortcut. If you need to quit Overlook via the keyboard, either disable
input capture first (open the Settings panel) or use `⌘⌥Esc` to force-quit.

### Menu bar global shortcuts

The menu bar agent listens for these when Overlook is NOT focused:

- `⌘⇧R`: Scan for devices.
- `⌘⇧V`: Open Quick Connect.

---

## Settings

Overlook’s settings UI lives in `Overlook/WebUISettingsPanel.swift` and is designed to map closely to the GLKVM WebUI.

### Video

- **Mode**: video processing mode (low-latency oriented).
- **Quality Presets**:
  - Low: `h264_bitrate=500`, `h264_gop=30`, `stream_quality=0`
  - Medium: `h264_bitrate=2000`, `h264_gop=30`, `stream_quality=1`
  - High: `h264_bitrate=5000`, `h264_gop=60`, `stream_quality=2`
  - Ultra-high: `h264_bitrate=8000`, `h264_gop=60`, `stream_quality=3`
  - Insane: `quality=100`, `h264_bitrate=20000`, `h264_gop=60`, `stream_quality=3`
  - Custom: unlocks the advanced streamer controls

- **EDID**:
  - Pick from known-good EDID presets.
  - Or choose “Custom” and paste your own EDID blob.

### Audio

- Audio output toggle.
- Microphone toggle.

**Important:** the UI indicates reconnect is required for audio/mic changes.

---

## Troubleshooting

### “I can’t find my device when scanning”

- Make sure your Mac is on the same network as the KVM.
- Try **Manual Connect…** with the host/IP and port.
- Some networks block mDNS; Overlook also does a best-effort port scan and probes common targets.

### “WebRTC connects but video is blank / unstable”

- Confirm the device’s WebUI works.
- Try toggling reconnect.
- Check the window title stats (bitrate/fps) to confirm frames are arriving.

### “Snippet OCR doesn’t detect text”

- Increase stream quality (higher bitrate helps OCR).
- Make the text larger on the remote side.
- Avoid heavy compression artifacts (try High/Ultra-high/Insane).

### “Paste doesn’t work”

- Ensure you’re connected.
- Ensure input capture is active.
- Confirm the remote cursor focuses a text field.

### “I see two cursors / the remote cursor drifts away”

- This usually means local view coordinates and remote HID coordinates are being mapped through different rectangles.
- Check whether the remote desktop has a dark background with a bright window centered inside it. That can look like letterboxing to automatic frame analysis.
- Overlook only applies automatic content-rect correction when the detected crop looks like symmetric letterbox/pillarbox bars. Asymmetric bright UI regions should be ignored and treated as a full-frame remote desktop.
- In app logs, compare `letterbox-detect` and `cursor-diag` entries. `src=full` should be used for normal desktop content; a non-full `src=(...)` should only appear for real stream letterboxing.

---

## Development notes

### Project structure

- `Overlook/ContentView.swift`
  - Main app UI and fullscreen experience.
- `Overlook/VideoSurfaceView.swift`
  - Hosts the WebRTC video view.
  - Routes mouse/scroll events.
  - Implements OCR selection gestures.
- `Overlook/WebRTCManager.swift`
  - WebRTC peer connection + Janus signaling.
  - Receiver stats collection.
  - Optional audio/mic track.
- `Overlook/InputManager.swift`
  - Keyboard/mouse capture.
  - Local→remote paste (`⌘⇧V`) and snippet OCR trigger (`⌘⇧C`).
  - HID transport via WebSocket to the device.
- `Overlook/OCRManager.swift` + `Overlook/OCRViews.swift`
  - Apple Vision OCR pipeline.
  - One-shot selection overlay + clipboard copy HUD.
- `Overlook/GLKVMClient.swift`
  - Device HTTP APIs (streamer params, system config, EDID, HID print, etc.).
- `Overlook/KVMDeviceManager.swift`
  - Discovery, saved devices, authentication.
- `Overlook/MenuBarAgent.swift`
  - Menu bar UI + quick actions.

### Security notes

- The app currently allows insecure TLS for device connections (useful for devices with self-signed certs).
- Treat your `auth_token` like a password.

---

## License

This project is licensed under the **GNU General Public License v3.0**.

See [`LICENSE.md`](./LICENSE.md).
