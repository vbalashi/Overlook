# Direct H.264 Media Protocol Notes

This note tracks what Overlook knows about GLKVM's direct media websocket at
`/api/media/ws`.

Status: confirmed against a GLKVM device at `192.168.178.60` on 2026-05-29.
The raw capture is intentionally stored outside the repository under
`../diagnostics/direct-media-captures/`.

## Capture Tool

Use:

```bash
scripts/capture-direct-media.swift --host <host-or-ip> --password <password> --duration 10
```

or, when an auth token is already available:

```bash
printf '%s' '<auth_token>' > /tmp/glkvm-auth-token
chmod 600 /tmp/glkvm-auth-token
scripts/capture-direct-media.swift --host <host-or-ip> --token-file /tmp/glkvm-auth-token --duration 10
```

Optional flags:

- `--port <port>`: default `443`.
- `--token <token>`: use only for short local experiments; command-line
  arguments may be visible in process listings.
- `--token-file <path>`: preferred token input for local captures.
- `--token-env <name>`: read the token from an environment variable.
- `--user <user>`: default `admin`, used with `--password`.
- `--no-start`: capture only the initial media metadata and do not request H.264
  frames.
- `--no-heartbeat`: do not send the WebUI-style binary heartbeat.
- `--output <path>`: explicit capture path.
- `--strict-tls`: disable the default self-signed certificate allowance.

By default captures are written outside this repository checkout:

```text
../diagnostics/direct-media-captures/direct-media-<timestamp>.ovdm
../diagnostics/direct-media-captures/direct-media-<timestamp>.jsonl
```

Do not commit raw captures unless they are intentionally sanitized fixtures.

## Capture Format

The `.ovdm` file preserves websocket message boundaries:

```text
magic:   "OVDM1\n"
record:  1 byte message type
         8 byte big-endian payload length
         payload bytes
```

Message types:

- `1`: binary websocket message.
- `2`: text websocket message encoded as UTF-8.
- `3`: outbound text websocket message sent by the capture tool.

The `.jsonl` sidecar contains redacted message metadata:

- message index
- elapsed milliseconds since capture start
- websocket message type
- payload byte count
- first 32 bytes as hex

Auth tokens and passwords are never written by the capture tool.

## Observed Browser Behavior

The GLKVM WebUI direct mode connects to:

```text
wss://<host>/api/media/ws?auth_token=<token>
```

The first server message observed from `/api/media/ws` is text metadata:

```json
{"event_type":"media","event":{"video":{"h264":{"profile_level_id":"42E01F"}}}}
```

After receiving that metadata, the WebUI sends:

```json
{"event_type":"start","event":{"type":"video","format":"h264"}}
```

The capture tool sends this same H.264 start message by default unless
`--no-start` is passed.

The WebUI also sends a binary heartbeat payload every second:

```text
00
```

The WebUI code treats inbound binary payloads with byte `0 == 0` as heartbeat
responses. In the 2026-05-29 capture, this GLKVM device responded to outbound
heartbeats with one-byte `ff` control packets instead. The app-side Direct
parser should therefore decode only binary messages with `byte 0 == 1` as video
and ignore unknown one-byte control packets. The capture tool sends the same
outbound heartbeat by default unless `--no-heartbeat` is passed.

The WebUI direct renderer uses browser WebCodecs:

- codec string: `avc1.<profile_level_id>`
- `VideoDecoder.configure({ codec, optimizeForLatency: true })`
- incoming binary frame format:
  - byte `0`: message kind; `0` is heartbeat/pong, `1` is video frame
  - byte `1`: keyframe flag for video frame messages
  - bytes `2...`: H.264 payload passed to `EncodedVideoChunk`

## Observed Stream Format

Real-device capture:

```text
direct-media-20260529-122431.ovdm
duration: 5 seconds
records: 254
inbound text: 1
outbound text: 1
inbound binary: 252
video frames: 252
keyframes: 5
delta frames: 247
captured H.264 bytes: 876687
```

Follow-up heartbeat capture:

```text
direct-media-20260529-122723.ovdm
duration: 5 seconds
records: 249
video frames: 243
keyframes: 5
delta frames: 238
one-byte ff control packets: 4
```

Observed record sequence:

1. Inbound text media metadata.
2. Outbound text H.264 start request.
3. Inbound binary H.264 frames.

For binary video messages:

```text
byte 0:  01            video frame message
byte 1:  01 or 00      keyframe flag
byte 2+: Annex B H.264 access unit
```

The H.264 payload uses Annex B start codes (`00 00 00 01`). Each websocket video
message observed in this capture maps to one complete H.264 access unit.

Observed NAL behavior:

- keyframe access units contained SPS, PPS, and IDR NAL units: types `7`, `8`,
  and `5`;
- delta access units contained non-IDR slice NAL units: type `1`;
- SPS/PPS were present on the initial keyframe and repeated on later keyframes;
- no separate timestamp field was observed, matching the WebUI behavior of using
  local receive/decode timing;
- no mixed text/control messages were observed after the initial metadata in this
  short capture unless the client sent binary heartbeats, in which case one-byte
  `ff` control packets were observed.

One important mismatch was observed: metadata advertised `profile_level_id` as
`42E01F`, while the captured SPS bytes began with `67 64 10 28`. The Direct
decoder should prefer SPS/PPS-derived format descriptions for VideoToolbox and
should treat metadata as connection/setup information rather than the sole codec
truth.

## Remaining Observations

- Does the endpoint continue streaming while Janus/WebRTC video is also active?
- Does the same framing hold across all supported firmware versions?
- How does the stream behave across resolution, bitrate, GOP, or streamer reset
  changes?
- Does direct video require any streamer configuration changes on devices with
  different defaults?

## Expected Step 1 Exit Criteria

Step 1 is complete after the real-device capture confirms:

- websocket message framing: confirmed;
- H.264 payload format: Annex B access units confirmed;
- SPS/PPS/keyframe behavior: SPS/PPS repeated on keyframes confirmed;
- whether metadata or timestamps exist: metadata exists, timestamps were not
  observed;
- auth, Origin, and TLS behavior: use the same `/api/media/ws` endpoint as
  `GLKVMClient.mediaWebsocketURL()`, pass the existing `auth_token` cookie, set
  Origin to the device base URL, and allow the device's self-signed certificate
  when strict TLS is not enabled.
