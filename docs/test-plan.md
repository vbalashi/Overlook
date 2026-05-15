# Overlook Integrated Build Test Plan

This plan covers the local `integrated-best-of-forks` branch.

## Prerequisites

- Full Xcode installed in `/Applications/Xcode.app`.
- `xcode-select -p` points to `/Applications/Xcode.app/Contents/Developer`.
- App can be built with `./build.sh -c debug`.
- A GL.iNet GLKVM / Comet-style device is reachable.
- macOS permissions are granted when prompted:
  - Local Network
  - Screen Recording if macOS asks for it
  - Accessibility/Input Monitoring if required for keyboard capture

## Build Checks

Run:

```bash
./build.sh -c debug
```

Expected:

- Xcode resolves the WebRTC package.
- Build succeeds.
- App is copied to `build/debug/Overlook.app`.
- Duplicate build-product guardrail passes:

```bash
scripts/cleanup-overlook-build-products.sh --keep "$PWD/build/debug/Overlook.app" --check
```

Expected: `No duplicate Overlook build products found.`

Use `./build.sh` for local builds. If you run raw `xcodebuild`, immediately run:

```bash
scripts/cleanup-overlook-build-products.sh --keep "$PWD/build/debug/Overlook.app"
```

If build fails, check first:

- `Overlook.xcodeproj/project.pbxproj` includes new Swift files:
  - `AgentServerManager.swift`
  - `QuickPasteManager.swift`
  - `QuickPasteView.swift`
- `OCRManager` exposes `detectTextRegions(in:)`.
- `ContentView` receives both `quickPasteManager` and `agentServerManager` environment objects.

## Manual App Smoke Test

1. Launch `build/debug/Overlook.app`.
2. Open the Connections popover.
3. Run scan.
4. Connect to a discovered device.
5. If auth is required, enter the password.

Expected:

- Connection busy state is visible while connecting.
- Failed auth prompts for password instead of silently failing.
- Connected device appears in the window title.
- Video stream appears.
- Connection status overlay disappears once stream is healthy.

## Keyboard/Input Test

Use a text editor or terminal on the remote machine.

Check:

- Plain typing works.
- `Cmd+C` reaches remote copy.
- `Cmd+V` reaches remote paste.
- `Cmd+Shift+C` enters snippet OCR mode locally.
- `Cmd+Shift+S` reaches the remote as `Meta+Shift+S` and opens Windows snipping.
- `Esc` exits snippet OCR mode.
- `Cmd` alone opens the remote Windows Start menu.
- `Cmd+Tab` reaches the remote as `Meta+Tab`.
- `Option+Tab` reaches the remote as `Alt+Tab`; verify explicitly on EU/UK keyboards.
- Releasing modifier keys after a local shortcut does not leave Shift/Command stuck on the remote.

Expected:

- Remote receives intended key actions.
- Local app controls still work.
- No stuck modifiers after using OCR or settings popovers.

## Mouse Mapping Test

Use a remote UI with clear corners and text/buttons.

Check:

- Move cursor to each corner.
- Click a small target near the center.
- Click targets near left/right letterbox boundaries if the stream is letterboxed.
- Scroll vertically.
- Toggle local reverse scroll and compare behavior.

Expected:

- Pointer lands under the visible cursor.
- Clicks match visual position.
- Letterboxed video does not offset clicks into black bars.

Regression check:

- Use a remote desktop with a black background and a bright, smaller window, such as Notepad, near the top center.
- Move the cursor across the bright window and the surrounding dark desktop.
- Watch for the local macOS cursor and the remote cursor drifting apart, then converging again after a few seconds.
- In logs, bright app content inside the remote desktop should not become the active mouse source rect. Live cursor `cursor-diag` should report `src=full`; mouse input is expected to map against the full remote framebuffer.

## Snippet OCR Manual Test

1. Connect to a remote screen containing readable English text.
2. Press `Cmd+Shift+C`.
3. Drag a rectangle around text.
4. Release mouse.

Expected:

- Snippet mode starts.
- Selection overlay appears.
- Keyboard/mouse input to remote is paused while selecting.
- Recognized text is copied to the Mac clipboard.
- HUD shows success or "No text found".
- Snippet mode exits cleanly after OCR.

Negative checks:

- Press `Esc` during snippet mode.
- Select an empty region.
- Disconnect video and try OCR.

Expected:

- `Esc` exits without stuck input.
- Empty region reports no text.
- Missing frame reports failure without crashing.

## Quick Paste Test

1. Open the Quick Paste toolbar button.
2. Add/edit snippets if the UI supports it.
3. Trigger a snippet while a remote text field is focused.

Expected:

- Popover opens without permanently disabling input capture.
- Snippet text is sent to the remote through GLKVM HID text printing.
- Normal `Cmd+V` remote paste still works afterward.

## Agent API Setup

1. Open Settings.
2. Expand Agent API.
3. Enable Agent HTTP API.
4. Copy the API key.

Run:

```bash
OVERLOOK_AGENT_KEY="copied-key" scripts/agent-api-smoke.sh
```

Optional variables:

```bash
OVERLOOK_AGENT_BASE="http://localhost:9876"
OVERLOOK_AGENT_FIND_TEXT="Login"
OVERLOOK_AGENT_EXERCISE_INPUT=1
```

## Agent API Smoke Test

The harness checks:

- `GET /status`
- `GET /mouse/position`
- `POST /convert/pixel-to-hid`
- `GET /screenshot?format=jpeg`
- `POST /find-text`

If `OVERLOOK_AGENT_EXERCISE_INPUT=1`, it also checks:

- `POST /mouse/move`
- `POST /mouse/scroll`
- `POST /key`

Expected:

- Without a connected KVM, status works and connected-dependent calls return controlled `503` JSON.
- Without a current KVM video frame, screenshot returns controlled `503` JSON and must not fall back to a Mac display screenshot.
- With a connected KVM and video frame, screenshot writes an image to `tmp/agent-smoke/screenshot.jpg`.
- `/find-text` returns `matches`, `frame_width`, and `frame_height`.
- Pixel-to-HID conversion returns `hid_x`, `hid_y`, frame dimensions.

## Agent API OCR Test

Choose visible text on the remote screen, then run:

```bash
OVERLOOK_AGENT_KEY="copied-key" \
OVERLOOK_AGENT_FIND_TEXT="visible word" \
scripts/agent-api-smoke.sh
```

Expected:

- `/find-text` returns at least one match.
- Match includes:
  - `text`
  - `px`
  - `py`
  - `hid_x`
  - `hid_y`
  - `confidence`

Then click one match manually through API:

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $OVERLOOK_AGENT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"px":100,"py":100,"button":"left"}' \
  http://localhost:9876/mouse/move-and-click
```

Replace `100,100` with coordinates from the `/find-text` response.

Expected:

- Remote cursor moves to the text match.
- Click lands at the expected visual location.

## MCP Endpoint Smoke Test

Run:

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $OVERLOOK_AGENT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  http://localhost:9876/mcp
```

Expected:

- JSON-RPC response with available tools.

Then:

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $OVERLOOK_AGENT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_status","arguments":{}}}' \
  http://localhost:9876/mcp
```

Expected:

- Text result describing current connection status.

## Regression Checklist

Before calling the branch usable:

- App launches after quit/reopen.
- Auto-resume works when enabled and does nothing surprising when disabled.
- Settings panel can open/close repeatedly while connected.
- Connections popover can scan while disconnected.
- Reconnect button works after stream loss.
- Agent API can be disabled and re-enabled without restarting the app.
- API key regeneration invalidates old token.
- Screenshot endpoint returns current KVM frame, not a stale frame.
- OCR does not leave frame capture disabled for Agent API.
