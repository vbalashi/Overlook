# Overlook Fork Integration Review

This branch is a local "best of forks" integration of `rcawston/Overlook`.
It is intentionally not published yet. The goal is to get one runnable build,
then decide whether to keep it local, create our own fork, or split changes
into smaller upstreamable patches.

## Repository Map

- `Overlook/` - macOS SwiftUI app source.
- `Overlook/ContentView.swift` - main window, toolbar, connection popover, Quick Paste entry point.
- `Overlook/VideoSurfaceView.swift` - WebRTC video surface, mouse forwarding, snippet OCR selection overlay.
- `Overlook/InputManager.swift` - keyboard/mouse capture, GLKVM HID WebSocket routing, local shortcut handling.
- `Overlook/KVMDeviceManager.swift` - device discovery, saved devices, authentication, connection lifecycle.
- `Overlook/WebRTCManager.swift` - Janus/WebRTC signaling, video/audio stats, frame capture for OCR/API.
- `Overlook/OCRManager.swift` - Vision OCR for selected snippets and Agent API text region lookup.
- `Overlook/AgentServerManager.swift` - local HTTP/MCP automation API, imported from `moming2k`.
- `Overlook/QuickPasteManager.swift` and `Overlook/QuickPasteView.swift` - local snippet paste UI, imported from `moming2k`.
- `Overlook/WebUISettingsPanel.swift` - device/app settings, Agent API toggle, local scroll and auto-resume toggles.
- `build.sh` - Xcode build wrapper from `dh0er`.
- `scripts/agent-api-smoke.sh` - local smoke-test harness for Agent API.
- `scripts/cleanup-overlook-macos-state.sh` - cleanup helper from `dh0er`.
- `docs/agent-api.md` - Agent API reference.
- `docs/test-plan.md` - build, manual, OCR, Agent API, and regression test plan.
- `docs/superpowers/` - historical planning docs from `dh0er`; useful for context, but not the source of truth for our integrated branch.

## Forks Reviewed

- `dh0er/Overlook`: selected as the integration base after upstream. This is the most production-oriented fork.
- `moming2k/Overlook`: selected for automation and power-user features, but not used as the base.
- `iamjairo/Overlook`: only GitHub Actions workflow churn; not selected.
- `jimmynotjim/Overlook`, `LiquidInfinity/Overlook`, `gregcar/overlook`: effectively upstream snapshots or tiny metadata/README/workflow changes; not selected.

## What We Took

From `dh0er`:

- More robust GL.iNet discovery and connect flow for HTTP/HTTPS devices.
- Network scan hardening, including file descriptor limit handling and better diagnostics.
- WebRTC signaling cleanup and connection status/stall overlays.
- Letterbox detection and source-content coordinate correction for mouse mapping.
- Improved keyboard routing:
  - `Cmd+C` and `Cmd+V` go to the remote machine.
  - local app shortcuts use explicit allow-listing.
  - snippet OCR starts with `Cmd+Shift+C`.
  - modifier state is cleaned up when local shortcuts or snippet mode interrupt capture.
- Snippet OCR overlay and HUD.
- Build/debug support: shared Xcode scheme, `build.sh`, VS Code LLDB config.

From `moming2k`:

- Local Agent HTTP API and MCP endpoint.
- KVM video-frame screenshots through the app's frame capture path.
- `/find-text` OCR endpoint with pixel and HID coordinate output.
- Mouse automation endpoints that accept HID or pixel coordinates.
- Quick Paste snippets popover.
- Auto-resume last connection preference.
- Local reverse-scroll preference.
- Agent docs and Postman collection.

## What We Did Not Take

- `moming2k`'s old OCR selection UI. It conflicts with the newer `dh0er` snippet OCR flow.
- `moming2k`'s older keyboard handler as the primary implementation. `dh0er` handles command-key passthrough and local shortcut cleanup more carefully.
- Large feature branches from `moming2k` that were not merged into `moming2k/main`:
  - macro recorder
  - connection presets
  - status HUD
  - separate OCR clipboard branch

Those may still be useful later, but they should be reviewed one by one after the core build is stable.

## Integration Notes

- Current branch: `integrated-best-of-forks`.
- We merged `dh0er/main` first, then resolved `moming2k/main` conflicts manually.
- The most sensitive merged files are:
  - `Overlook/InputManager.swift`
  - `Overlook/VideoSurfaceView.swift`
  - `Overlook/WebRTCManager.swift`
  - `Overlook/OCRManager.swift`
  - `Overlook/AgentServerManager.swift`
- Agent API originally expected `OCRManager.detectTextRegions`; `dh0er` had removed that method. We restored a small compatible text-region API in `OCRManager`.
- Agent API is localhost-only and protected by a Bearer token stored in `UserDefaults`.
- Agent screenshots are intentionally KVM-frame-only. No-frame states return `503`; they must not capture the Mac display as a fallback.

## Current Risk Assessment

High-risk areas:

- Keyboard shortcuts and modifier release ordering. This is where both forks changed behavior.
- Mouse coordinate mapping. Letterbox correction, pixel coordinates, HID coordinates, and Agent API conversion all need real-device validation.
- OCR frame capture. It depends on WebRTC frames being available and recent.
- Agent API threading/lifetime. It holds weak references to managers and runs request handling through `NWListener`.

Medium-risk areas:

- Auto-resume last connection. It depends on saved-device load order and stored ids.
- Local reverse scroll. Needs comparison with the remote device's own reverse-scroll setting.
- Quick Paste. It should use GLKVM HID text printing and should not interfere with normal clipboard paste.

Low-risk areas:

- Build scripts and shared Xcode scheme.
- Documentation and Postman collection.
- VS Code launch/tasks config.

## TODO

Must do before trusting the build:

- Install full Xcode and run `./build.sh -c debug`.
- Fix any semantic compile errors that `swiftc -parse` cannot catch.
- Launch the app and connect to a real GLKVM / Comet device.
- Run the manual smoke checklist in `docs/test-plan.md`.
- Run `scripts/agent-api-smoke.sh` against a connected session.
- Verify OCR manually with `Cmd+Shift+C` and through `/find-text`.

Should do after first successful run:

- Add a tiny in-app diagnostics view or log export button for Agent API and input state.
- Make Agent API docs match exact current behavior for screenshot formats and `/find-text`.
- Decide whether to keep `CLAUDE.md`; it came from `moming2k` and may not be useful for us.
- Review `moming2k` feature branches individually:
  - connection presets first
  - status HUD second
  - macro recorder last

Will not do for now:

- Publish a fork or PR before a real-device smoke test.
- Replace `dh0er` keyboard routing with `moming2k` routing.
- Add public network binding for Agent API.
- Add background daemon behavior outside the app lifecycle.
