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

Types a string of text on the remote machine using HID keyboard emulation. Supports Unicode and multi-line text.

**Request body**
```json
{
  "text": "Hello, World!"
}
```

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
  "key": "enter"
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

Coordinates use the HID absolute coordinate system: `0–32767` for both axes, where `(0, 0)` is top-left and `(32767, 32767)` is bottom-right.

**Request body**
```json
{
  "x": 16383,
  "y": 16383
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

### `GET /screenshot`

Captures the host Mac's screen and returns a PNG image. Useful for visual feedback when automating tasks.

**Response**

`Content-Type: image/png` — raw PNG binary.

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
