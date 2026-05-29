# Direct H.264 Troubleshooting

Direct H.264 is an opt-in video backend for GLKVM devices on LAN or VPN
networks. WebRTC remains the default and still owns audio and microphone
transport.

## Selecting the Backend

Use Settings > Video > Playback:

- `WebRTC`: existing Janus/WebRTC video path.
- `Direct H.264`: `/api/media/ws` video path, decoded locally with
  VideoToolbox.

Changing playback while connected triggers a normal reconnect so only one video
backend owns the stream.

## Expected Direct Stream

The GLKVM Direct media websocket should:

1. Open `wss://<host>/api/media/ws` with the existing auth cookie and Origin.
2. Send media metadata containing H.264 support.
3. Accept `{"event_type":"start","event":{"type":"video","format":"h264"}}`.
4. Send binary video messages with a two-byte GLKVM header followed by one
   Annex B H.264 access unit.

The decoder waits for a keyframe containing SPS and PPS before publishing video.

## Common Failures

- `missing SPS/PPS parameter sets`: the stream has not delivered a usable
  keyframe yet, or the parser lost sync. Reconnect or reset the streamer.
- `websocket receive failed`: the media websocket closed or network transport
  failed. Direct mode schedules reconnect with backoff.
- `stream stalled`: frames stopped advancing. Direct mode keeps the last frame
  visible, tears down the media websocket, and reconnects.
- Black Direct video with WebRTC working: confirm the device firmware exposes
  `/api/media/ws` H.264 and that the stream metadata includes H.264.
- Audio missing in Direct mode: expected. Audio and microphone remain on WebRTC
  until a separate direct audio plan exists.

## Verification Checklist

- Connect in WebRTC mode and confirm existing behavior.
- Switch to Direct H.264 and confirm video appears after the first keyframe.
- Check mouse movement and clicks against the remote screen.
- Run snippet OCR and Agent screenshot/OCR against Direct mode.
- Reset the streamer or briefly interrupt the network and confirm reconnect.
- Run a 30-60 minute Direct session while watching frame age, fps, bitrate, and
  memory behavior.

