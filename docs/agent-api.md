# Overlook Agent API

A local HTTP server built into the Overlook macOS app that allows LLM agents and automation tools to control the connected KVM device.

## Setup

1. Open Overlook → Settings (gear icon)
2. Expand the **Agent API** section
3. Toggle **Enable Agent HTTP API**
4. Copy your **API Key** from the settings panel

The server binds to `localhost` only and is never exposed to the network.

## Base URL

```
http://localhost:9876
```

The port is configurable in Settings → Agent API.

## Authentication

All requests require a Bearer token header:

```
Authorization: Bearer <your-api-key>
```

The API key is displayed in Settings → Agent API. You can regenerate it at any time.

---

## Endpoints

### `GET /status`

Returns the current connection state of the KVM device.

**Response**
```json
{
  "connected": true,
  "device": "GL.iNet Comet"
}
```

---

### `POST /type`

Types text on the remote machine using HID keyboard emulation. Multi-line text and whitespace are preserved. Characters must be supported by the device keymap and the remote keyboard layout; arbitrary Unicode is not guaranteed.

Text is sent sequentially in bounded UTF-8 chunks, with the firmware truncation limit disabled. The response waits for every chunk to finish. There is no overall character limit in the typing client; the Agent HTTP API accepts JSON bodies up to 16 MiB and requires `Content-Length` (chunked transfer encoding is unsupported). Use a sufficiently long caller timeout for large pastes. A failure stops further chunks and returns an error; do not automatically retry the entire text, since an earlier portion may already have been typed.

`ok: true` means the device completed the typing requests. It does not verify the receiving application or saved file; check the screen or file contents when exact delivery matters.

**Request body**
```json
{
  "text": "Hello, World!"
}
```

Optional fields: `speed` is `slow`, `balanced`, `fast`, or `turbo` and defaults to the saved **Keyboard settings → Paste speed** setting. `slow: true/false` is an explicit compatibility override selecting slow/fast. The same options are available on MCP `type_text`.

| Speed | Device key interval | Chunk size | Pause between chunks |
|---|---|---|---|
| Slow | 30 ms per key event | 512 bytes | none |
| Balanced | 5 ms per key event | 128 bytes | 200 ms |
| Fast (default) | 5 ms per key event | 512 bytes | none |
| Turbo | 5 ms per key event | 4096 bytes | none |

Turbo reduces request overhead; the device's physical typing limit remains. Balanced paces requests, but does not change intra-chunk key timing. Slow is the mode to try if characters are missed. Selection changes apply to the next paste; ongoing pastes retain their original speed. Effective speed depends on keymap, modifiers and round-trip time.

**Response**
```json
{ "ok": true }
```

---

### `POST /key`

Sends a single key press (down + up) to the remote machine.

**Request body**
```json
{
  "key": "Enter"
}
```

**Key names** (case-sensitive, Web KeyboardEvent format)

| Key | Value |
|-----|-------|
| Enter | `"Enter"` |
| Escape | `"Escape"` |
| Tab | `"Tab"` |
| Backspace | `"Backspace"` |
| Delete | `"Delete"` |
| Space | `"Space"` |
| Arrow Up | `"ArrowUp"` |
| Arrow Down | `"ArrowDown"` |
| Arrow Left | `"ArrowLeft"` |
| Arrow Right | `"ArrowRight"` |
| Home | `"Home"` |
| End | `"End"` |
| Page Up | `"PageUp"` |
| Page Down | `"PageDown"` |
| F1–F12 | `"F1"` – `"F12"` |
| Letters | `"KeyA"` – `"KeyZ"` |
| Digits | `"Digit0"` – `"Digit9"` |
| Left Ctrl | `"ControlLeft"` |
| Left Shift | `"ShiftLeft"` |
| Left Alt | `"AltLeft"` |
| Left Meta (⌘/Win) | `"MetaLeft"` |
| Caps Lock | `"CapsLock"` |

**Response**
```json
{ "ok": true }
```

---

### `POST /mouse/move`

Moves the mouse cursor to an absolute position on the remote screen.

Coordinates use signed HID absolute coordinates: `-32767–32767` for both axes. `(-32767, -32767)` is top-left, `(0, 0)` is the center, and `(32767, 32767)` is bottom-right. You may instead provide `px` and `py` in screenshot pixels.

**Request body**
```json
{
  "x": 0,
  "y": 0
}
```

**Response**
```json
{ "ok": true }
```

---

### `POST /mouse/click`

Clicks a mouse button at the current cursor position.

**Request body**
```json
{
  "button": "left"
}
```

| Field | Values | Default |
|-------|--------|---------|
| `button` | `"left"`, `"right"`, `"middle"` | `"left"` |

**Response**
```json
{ "ok": true }
```

---

### `POST /mouse/scroll`

Scrolls the mouse wheel.

**Request body**
```json
{
  "deltaX": 0,
  "deltaY": -3
}
```

Positive `deltaY` scrolls up, negative scrolls down. Positive `deltaX` scrolls right, negative scrolls left.

**Response**
```json
{ "ok": true }
```

---

### `GET /mouse/position`

Returns the last HID mouse position known to Overlook.

**Response**
```json
{
  "x": 0,
  "y": 0
}
```

---

### `POST /mouse/move-and-click`

Moves the cursor and clicks in one request. Accepts either HID coordinates (`x`, `y`) or KVM video-frame pixel coordinates (`px`, `py`).

**Request body**
```json
{
  "px": 640,
  "py": 360,
  "button": "left"
}
```

**Response**
```json
{
  "ok": true,
  "px": 640,
  "py": 360,
  "hid_x": 0,
  "hid_y": 0
}
```

---

### `POST /convert/pixel-to-hid`

Converts KVM video-frame pixel coordinates to HID absolute coordinates.

**Request body**
```json
{
  "x": 640,
  "y": 360
}
```

**Response**
```json
{
  "hid_x": 0,
  "hid_y": 0,
  "frame_width": 1280,
  "frame_height": 720
}
```

---

### `POST /find-text`

Runs OCR on the current KVM video frame and returns matches with pixel and HID coordinates.

**Request body**
```json
{
  "text": "Login"
}
```

**Response**
```json
{
  "matches": [
    {
      "text": "Login",
      "px": 120,
      "py": 80,
      "hid_x": -26623,
      "hid_y": -25486,
      "confidence": 0.92
    }
  ],
  "frame_width": 1280,
  "frame_height": 720
}
```

---

### `GET /screenshot`

Captures the current KVM video frame and returns an image. Useful for visual feedback when automating tasks.

Query parameters:

| Field | Values | Default |
|-------|--------|---------|
| `format` | `jpeg`, `png`, `webp` | `jpeg` |
| `quality` | `0.0`-`1.0`, JPEG/WebP only | `0.8` |

**Response**

Raw image bytes with the matching `Content-Type`.

---

### `POST /mcp`

MCP JSON-RPC endpoint over streamable HTTP. Useful for tool-based agents that prefer MCP-style discovery and calls.

Minimal smoke test:

```bash
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  $BASE/mcp
```

---

## Error Responses

All errors return JSON with an `"error"` field.

| Status | Meaning |
|--------|---------|
| `400 Bad Request` | Missing or invalid request body fields |
| `401 Unauthorized` | Missing or incorrect API key |
| `404 Not Found` | Unknown endpoint |
| `503 Service Unavailable` | No KVM device connected |
| `500 Internal Server Error` | Operation failed on the device |

**Example**
```json
{ "error": "Not connected" }
```

---

## Example: Automate Login

```bash
API_KEY="your-api-key-here"
BASE="http://localhost:9876"
AUTH="Authorization: Bearer $API_KEY"

# Check connection
curl -s -H "$AUTH" $BASE/status

# Type username
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"text":"admin"}' $BASE/type

# Press Tab
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"key":"Tab"}' $BASE/key

# Type password
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"text":"my-password"}' $BASE/type

# Press Enter
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"key":"Enter"}' $BASE/key

# Take a screenshot to verify
curl -s -H "$AUTH" $BASE/screenshot > result.png
```
