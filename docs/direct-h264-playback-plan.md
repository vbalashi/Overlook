# Direct H.264 Playback Plan

This document is the execution plan for adding a production-grade Direct H.264
video playback pipeline to Overlook while keeping the existing WebRTC/Janus path
available.

The work must be done incrementally. Each implementation step must end with:

1. A focused verification pass.
2. A git commit containing only that step.
3. A clean working tree before the next step starts.
4. A short progress note explaining what changed, what was tested, and what is
   still intentionally pending.

## Goal

Add a second video playback backend:

```text
GLKVM /api/media/ws -> H.264 stream parser -> VideoToolbox decoder -> native
macOS render surface -> existing Overlook input, OCR, snapshot, health, and UI
integration
```

The Direct H.264 backend should be production quality for video-only GLKVM use on
LAN/VPN connections. It must be possible to compare it with the existing WebRTC
backend and safely fall back to WebRTC.

## Non-Goals

The first production Direct H.264 phase will not:

- Remove WebRTC from the project.
- Replace Janus/WebRTC audio playback.
- Replace Janus/WebRTC microphone transport.
- Rewrite HID input transport.
- Add a server-side component.
- Add generic RTSP, HLS, camera, or non-GLKVM stream support.
- Optimize for arbitrary WAN/NAT traversal beyond what direct LAN/VPN access
  provides.
- Make Direct H.264 the default before real-device stability and latency are
  verified.

Audio and microphone support should remain on the existing WebRTC path unless a
later plan explicitly scopes a direct audio transport.

## Current State

The current app uses one video path:

```text
Janus WebSocket signaling -> WebRTC PeerConnection -> RTP/H.264 -> WebRTC
decoder/rendering -> RTCMTLNSVideoView
```

Relevant code:

- `Overlook/WebRTCManager.swift` owns signaling, WebRTC state, reconnect logic,
  WebRTC stats, frame capture, audio/mic state, and current frame publication.
- `Overlook/VideoSurfaceView.swift` embeds `RTCMTLNSVideoView` and also handles
  mouse mapping, snippet OCR selection, status overlays, and frame capture.
- `Overlook/GLKVMClient.swift` already exposes `mediaWebsocketURL()` for
  `/api/media/ws`, but the endpoint is not currently used for playback.

## Architecture Principles

- Keep Direct H.264 behind an explicit backend boundary.
- Preserve WebRTC behavior until each Direct feature is verified.
- Prefer fresh-frame behavior over smooth playback of stale queued frames.
- Keep OCR and snapshot APIs backend-neutral by publishing `CVPixelBuffer`.
- Keep input mapping behavior stable across renderers.
- Keep failure modes visible in explicit Direct mode, and recoverable in Auto
  mode.
- Add diagnostic capture early so stream format bugs can be reproduced without
  guessing.

## Execution Steps

### Step 0: Planning Baseline

Deliverable:

- Add this plan document.

Verification:

- Confirm git tree was clean before the document change.
- Review the document diff.

Commit:

- `docs: plan direct h264 playback pipeline`

### Step 1: Direct Media Endpoint Investigation

Deliverables:

- Add a small diagnostic tool or app-internal diagnostic path that connects to
  `/api/media/ws` with the same auth/TLS behavior as `GLKVMClient`.
- Record a short binary capture from a real device.
- Log message boundaries, sizes, binary/text types, and first bytes without
  leaking auth tokens.
- Write a short protocol note under `docs/` describing the observed framing and
  stream format.

Verification:

- Run against a real GLKVM device.
- Confirm the capture can be reproduced.
- Confirm logs are redacted and useful.
- Confirm no existing WebRTC playback behavior changed.

Commit:

- `docs: document glkvm direct media stream`

Exit criteria:

- We know whether `/api/media/ws` carries Annex B H.264, length-prefixed H.264,
  or a different container/framing.
- We know where SPS/PPS and keyframes appear.
- We know whether timestamps or metadata exist.

### Step 2: Backend State Abstraction

Deliverables:

- Introduce a backend-neutral video state/protocol layer.
- Keep WebRTC as the only active backend.
- Move UI dependencies toward shared state where practical without changing
  behavior.
- Preserve existing published fields used by the UI: connection state,
  `currentFrame`, `videoSize`, stream health, disconnect reason, and stats.

Verification:

- Build the app.
- Smoke test existing WebRTC connect/disconnect if a device is available.
- Confirm OCR/snippet mode still reads `currentFrame`.

Commit:

- `refactor: introduce video playback backend state`

Exit criteria:

- Direct backend can be added without making `VideoSurfaceView` depend directly
  on two unrelated managers.
- Existing WebRTC behavior remains intact.

### Step 3: Direct H.264 Connection Skeleton

Deliverables:

- Add `DirectH264Manager` or equivalent backend type.
- Connect to `/api/media/ws`.
- Implement lifecycle: connect, disconnect, cancellation, logging, and basic
  byte counters.
- Add an internal setting or compile-safe switch to select Direct mode for
  development.
- Do not decode or render yet.

Verification:

- Build the app.
- Connect to a real device and confirm bytes arrive.
- Disconnect cleanly.
- Confirm WebRTC mode still works.

Commit:

- `feat: add direct h264 connection backend`

Exit criteria:

- Direct mode can establish and tear down the media websocket without affecting
  WebRTC mode.

### Step 4: H.264 Parser

Deliverables:

- Add parser for the confirmed stream format.
- Detect SPS, PPS, IDR, non-IDR frames, and access unit boundaries.
- Add parser unit tests using captured sample data or a sanitized fixture.
- Add sync recovery behavior: after parse error, wait for a usable keyframe and
  parameter sets.

Verification:

- Run parser tests.
- Run build.
- Validate parser logs against real-device stream.

Commit:

- `feat: parse direct h264 media stream`

Exit criteria:

- Parser emits complete decode-ready H.264 access units with the required
  parameter sets.

### Step 5: VideoToolbox Decoder

Deliverables:

- Add a VideoToolbox decoder wrapper.
- Build `CMVideoFormatDescription` from SPS/PPS.
- Create and recreate `VTDecompressionSession` as stream format changes.
- Decode frames into `CVPixelBuffer`.
- Track decode errors, decode time, dropped frames, and last decoded frame time.

Verification:

- Add focused decoder tests where practical.
- Build the app.
- Decode a captured stream sample if tooling allows.
- Confirm decoder recovers after resolution or SPS/PPS changes.

Commit:

- `feat: decode direct h264 with videotoolbox`

Exit criteria:

- Direct backend can produce `CVPixelBuffer` frames without rendering them in the
  main UI yet.

### Step 6: Native Render Surface

Deliverables:

- Add a native macOS video render view for decoded `CVPixelBuffer` frames.
- Integrate it behind the backend abstraction.
- Preserve aspect-fit behavior and mouse coordinate mapping semantics.
- Avoid unbounded frame queues; drop stale frames when necessary.

Verification:

- Build the app.
- Direct mode displays live video from a real device.
- Mouse movement/click coordinate mapping is checked against the remote screen.
- Long enough smoke test to confirm memory does not grow continuously.

Commit:

- `feat: render direct h264 video`

Exit criteria:

- Direct mode provides visible, interactive video.

### Step 7: OCR, Snapshot, and Letterbox Integration

Deliverables:

- Ensure Direct mode publishes `currentFrame` for OCR and snapshot flows.
- Confirm snippet OCR selection maps to the same video coordinates as WebRTC.
- Ensure source content rect and video size updates work with the Direct render
  path.

Verification:

- Build the app.
- Run snippet OCR against Direct mode.
- Compare OCR region behavior against WebRTC mode.
- Check snapshot/current-frame capture behavior.

Commit:

- `feat: integrate direct h264 frame capture`

Exit criteria:

- OCR and snapshot workflows are backend-neutral.

### Step 8: UI Selection and Fallback

Deliverables:

- Add playback mode selection:
  - WebRTC
  - Direct H.264
  - Auto, if the previous steps are stable enough
- Show active backend in diagnostics/status UI.
- In explicit Direct mode, surface Direct failures clearly.
- In Auto mode, attempt Direct first and fall back to WebRTC with a visible
  reason.

Verification:

- Build the app.
- Toggle between modes.
- Confirm reconnect button targets the active backend.
- Confirm fallback does not hide useful Direct diagnostics.

Commit:

- `feat: add playback backend selection`

Exit criteria:

- Users can safely choose WebRTC or Direct H.264 without editing code.

### Step 9: Direct Health, Reconnect, and Stats

Deliverables:

- Add Direct-specific health monitoring:
  - websocket status
  - bytes received
  - input bitrate
  - decoded fps
  - render fps if available
  - decode latency
  - dropped/stale frames
  - last keyframe age
  - last frame age
- Add reconnect behavior for websocket errors, stalls, sleep/wake, and streamer
  reset.
- Keep logs actionable and redacted.

Verification:

- Build the app.
- Test streamer reset.
- Test disconnect/reconnect.
- Test sleep/wake.
- Run a 30-60 minute real-device session.

Commit:

- `feat: add direct h264 health monitoring`

Exit criteria:

- Direct mode has production-grade observability and recovery behavior.

### Step 10: Production Hardening

Deliverables:

- Tighten resource cleanup and thread isolation.
- Audit memory ownership around VideoToolbox, CoreMedia, and render surfaces.
- Ensure Direct mode cannot starve the main actor.
- Add or update docs for troubleshooting Direct H.264.
- Decide whether Auto mode is ready, or whether Direct remains opt-in.

Verification:

- Full release build.
- Long real-device session.
- Mode switching stress test.
- Resolution/bitrate/GOP setting changes.
- OCR after long session.
- Confirm git tree is clean after build artifacts are handled.

Commit:

- `chore: harden direct h264 playback`

Exit criteria:

- Direct H.264 is shippable as an opt-in production video backend.

## Testing Matrix

Each relevant implementation step should consider this matrix:

- Build:
  - Debug build.
  - Release build for final hardening.
- Existing behavior:
  - WebRTC video connect.
  - WebRTC audio/mic path unchanged.
  - HID keyboard/mouse input unchanged.
  - Snippet OCR unchanged in WebRTC mode.
- Direct behavior:
  - Connect.
  - Disconnect.
  - Reconnect.
  - Streamer reset.
  - Resolution change.
  - Bitrate/GOP change.
  - Sleep/wake.
  - 30-60 minute session.
  - OCR/snippet capture.
  - Fullscreen and window resize.
- Failure behavior:
  - Device offline.
  - Auth failure.
  - Websocket close.
  - Malformed frame or lost sync.
  - No SPS/PPS before frame data.
  - Decoder session failure.

## Commit Discipline

- Do not start the next step with uncommitted changes from the previous step.
- Keep commits scoped to one step.
- Do not include generated logs, raw captures, build products, or private device
  data unless they are sanitized fixtures intentionally added for tests.
- If a step reveals the plan is wrong, update this document in a separate
  planning commit before continuing implementation.
- If real-device testing is required and unavailable, stop at the nearest safe
  checkpoint and record exactly what remains unverified.

## Open Questions

- Does the same `/api/media/ws` framing hold across all supported firmware
  versions?
- Is Direct media available on all supported firmware versions?
- Can audio WebRTC run concurrently with Direct video without requesting Janus
  video?
- Should Auto mode be included in the first release or wait until Direct is
  proven stable on multiple firmware versions?

## Progress Log

### 2026-05-29: Step 1 Tooling Checkpoint

Done:

- Added a direct media capture tool for `/api/media/ws`.
- Added protocol notes documenting the capture format and required real-device
  observations.
- Verified the capture tool help/error paths.
- Verified the app still builds in Debug.

Pending:

- Run a production-length Direct session after the app backend exists.

### 2026-05-29: Step 1 Real-Device Capture

Done:

- Confirmed SSH access to the GLKVM host through the local `glkvm` SSH alias.
- Captured `/api/media/ws` from the real device using the saved Overlook auth
  token without exposing it in command-line arguments.
- Confirmed the Direct stream sends metadata first, then starts H.264 after the
  WebUI-compatible start message.
- Confirmed binary video messages carry one Annex B H.264 access unit with a
  two-byte GLKVM frame header.
- Confirmed keyframes include SPS, PPS, and IDR, with SPS/PPS repeated on later
  keyframes.
- Documented the WebUI heartbeat behavior and updated the capture tool to send
  the same heartbeat by default.

Pending:

- Verify Direct video and WebRTC audio can run concurrently once the app backend
  selection exists.
- Re-test stream behavior on resolution, bitrate, GOP, and streamer reset
  changes during later hardening steps.

### 2026-05-29: Step 2 Backend State Abstraction

Done:

- Added `VideoPlaybackBackendKind`, `VideoPlaybackFrameSource`,
  `VideoPlaybackStatusProviding`, and `VideoPlaybackBackend`.
- Marked the existing `WebRTCManager` as the active `.webRTC` backend without
  changing its connection behavior.
- Moved frame/snapshot consumers in `VideoSurfaceView` and
  `AgentServerManager` toward the backend-neutral frame-source interface.
- Verified the app still builds in Debug.

Pending:

- Step 3 will add the first Direct H.264 backend implementation behind this
  boundary.

### 2026-05-29: Step 3 Direct H.264 Connection Skeleton

Done:

- Added `DirectH264Manager` as a video-only backend skeleton.
- Implemented `/api/media/ws` websocket connect/disconnect lifecycle using the
  existing `GLKVMClient` URL, auth cookie, Origin, and TLS behavior.
- Implemented media metadata handling, WebUI-compatible H.264 start, binary
  heartbeat, byte/frame/keyframe counters, and basic stall stats.
- Kept Direct H.264 out of the visible UI path; WebRTC remains the active app
  backend.

Pending:

- Wire backend selection into the app in a later step.
- Step 4 will add a real H.264 parser; the current Direct backend only counts
  frames and bytes.

### 2026-05-29: Step 4 H.264 Parser

Done:

- Added `DirectH264Parser` for the confirmed GLKVM binary message format.
- Added Annex B NAL scanning with SPS, PPS, IDR, and non-IDR detection.
- Added sync behavior: drop delta frames until a keyframe with parameter sets is
  observed; retain latest SPS/PPS for later access units.
- Integrated parser validation into `DirectH264Manager` so Direct counters only
  advance on parser-accepted access units.
- Added `scripts/test-direct-h264-parser.swift` with synthetic parser coverage.
- Verified parser tests and Debug build.

Pending:

- Step 5 will convert parser output into VideoToolbox decode input.

### 2026-05-29: Step 5 VideoToolbox Decoder

Done:

- Added `DirectH264VideoDecoder`.
- Builds `CMVideoFormatDescription` from parser-provided SPS/PPS.
- Recreates `VTDecompressionSession` when parameter sets change.
- Converts Annex B access units to length-prefixed samples for VideoToolbox.
- Decodes Direct access units to `CVPixelBuffer`.
- Integrated decoder output into `DirectH264Manager` state (`currentFrame` and
  `videoSize`) while keeping Direct out of the visible UI path.
- Added `scripts/test-direct-h264-decoder.swift` for external `.ovdm` capture
  smoke tests.
- Verified decoder smoke against the real-device capture:
  `252` decoded frames, `5` keyframes, final size `1920x1080`.
- Verified Debug build.

Pending:

- Step 6 will add the native render surface and visible Direct playback path.

### 2026-05-29: Step 6 Native Render Surface

Done:

- Added a native `AVSampleBufferDisplayLayer` render surface for decoded Direct
  `CVPixelBuffer` frames.
- Registered `DirectH264Manager` in the app environment.
- Wired the existing development backend preference into connection, status,
  window sizing, and `VideoSurfaceView` rendering.
- Kept WebRTC as the default backend; Direct H.264 remains opt-in until the UI
  selection step.
- Reused the existing tracking container so Direct mode keeps the same mouse
  move, click, scroll, aspect-fit, and letterbox coordinate path as WebRTC.

Pending:

- Step 7 will finish OCR/snapshot verification against the active backend.
- Step 8 will add a user-facing backend selector instead of the internal
  preference.

### 2026-05-29: Step 7 OCR, Snapshot, and Letterbox Integration

Done:

- Confirmed `VideoSurfaceView` snippet OCR reads frames and video dimensions
  through `VideoPlaybackFrameSource`, so Direct and WebRTC use the same region
  mapping path.
- Confirmed the Direct render path reuses `TrackingContainerView`, preserving
  the same aspect-fit and mouse-coordinate normalization behavior.
- Updated `AgentServerManager` screenshot/OCR helpers to resolve the active
  `VideoPlaybackFrameSource` from the backend preference instead of always
  reading WebRTC frames.

Pending:

- Real-device snippet OCR and Agent screenshot smoke in Direct mode.
- Step 8 will expose backend selection in the UI so this can be tested without
  editing defaults.

### 2026-05-29: Step 8 UI Selection and Fallback

Done:

- Added a Settings > Video playback selector for WebRTC and Direct H.264.
- Updated connection diagnostics to label and read video stats from the active
  backend instead of always showing WebRTC video stats.
- Reconnect overlays now disable against the active backend's connecting state.
- Changing playback backend during an active unpaused session triggers a normal
  reconnect so the selected backend owns the video websocket cleanly.

Pending:

- Auto fallback is intentionally deferred until Direct health/reconnect
  hardening exists; explicit Direct mode should surface Direct failures instead
  of silently hiding them.
- Real-device UI toggle smoke between WebRTC and Direct H.264.

### 2026-05-29: Step 9 Direct Health, Reconnect, and Stats

Done:

- Added Direct H.264 reconnect scheduling for websocket receive errors,
  heartbeat send errors, and start-message failures.
- Added stall recovery: if decoded Direct video stops advancing past the stall
  threshold, the backend tears down the media websocket and schedules reconnect.
- Kept the last decoded frame visible during transient Direct reconnects while
  surfacing the reconnect reason in backend state.
- Reused existing Direct stats for active backend diagnostics: bitrate, fps,
  frame age, stalled state, and session video bytes.

Pending:

- 30-60 minute real-device Direct session.
- Explicit streamer reset, sleep/wake, and network interruption tests.
- Render FPS and decode-error counters can be added in final hardening if the
  current diagnostics are not enough during soak testing.
