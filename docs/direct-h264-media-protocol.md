# Direct H.264 Media Protocol Notes

This note tracks what Overlook knows about GLKVM's direct media websocket at
`/api/media/ws`.

Status: diagnostic tooling exists, but the actual stream framing still needs to
be confirmed against a real device.

## Capture Tool

Use:

```bash
scripts/capture-direct-media.swift --host <host-or-ip> --password <password> --duration 10
```

or, when an auth token is already available:

```bash
scripts/capture-direct-media.swift --host <host-or-ip> --token <auth_token> --duration 10
```

Optional flags:

- `--port <port>`: default `443`.
- `--user <user>`: default `admin`, used with `--password`.
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

The `.jsonl` sidecar contains redacted message metadata:

- message index
- elapsed milliseconds since capture start
- websocket message type
- payload byte count
- first 32 bytes as hex

Auth tokens and passwords are never written by the capture tool.

## Open Observations

The real stream still needs to answer:

- Is the payload Annex B H.264, AVCC/length-prefixed H.264, or another wrapper?
- Does each websocket message map to one H.264 access unit, one NAL unit, or an
  arbitrary byte chunk?
- Are SPS and PPS emitted on connect?
- Are SPS and PPS repeated before IDR frames or after resolution changes?
- How can IDR/keyframes be detected reliably in the observed stream?
- Are timestamps present, or should Direct playback use local receive/decode
  timing?
- Are there text/control messages mixed with binary media messages?
- Does the endpoint continue streaming while Janus/WebRTC video is also active?
- Does direct video require streamer configuration changes before connecting?

## Expected Step 1 Exit Criteria

Step 1 is complete only after a real-device capture confirms:

- websocket message framing;
- H.264 payload format;
- SPS/PPS/keyframe behavior;
- whether metadata or timestamps exist;
- whether any auth, Origin, or TLS differences are required from
  `GLKVMClient.mediaWebsocketURL()`.

If a real device is unavailable, this step may be committed as tooling only, but
the implementation steps that depend on the stream format must not proceed as if
the protocol were known.
