# Overlook Harness Notes

This file indexes operational findings that are useful when diagnosing Overlook
from a local developer machine.

## Local Logs

- App log: `/Users/khrustal/Library/Logs/Overlook/overlook.log`
- Previous app log: `/Users/khrustal/Library/Logs/Overlook/overlook.previous.log`
- macOS power timeline: `pmset -g log`
- macOS unified logs for the app:
  `/usr/bin/log show --style compact --predicate 'process == "Overlook"'`

The app writes its own log through `OverlookLog` in `GLKVMClient.swift`. That
file log is much cleaner than unified logging for WebRTC and device diagnostics.

## 2026-05-15 Display Sleep / Wake Reconnect Loop

User-visible symptom:

- Overlook was running on an external monitor.
- After the MacBook/display slept and the user woke it via keyboard, the window
  only showed `Connecting...` and periodic `Video stream stalled. Reconnecting...`.

Power timeline:

- `2026-05-15 13:49:51 CEST`: macOS reported `Display is turned off`.
- `2026-05-15 13:49:56 CEST`: machine entered sleep due to idle sleep.
- `2026-05-15 13:54:01 CEST`: full wake from deep idle due to HID activity from
  the NuPhy keyboard, then `Display is turned on`.

App log signature:

- Target device: `192.168.178.60:443`.
- Overlook successfully fetched TURN credentials and reopened Janus signaling
  over `wss://192.168.178.60:443/janus/ws`.
- Reconnect attempts logged `WebRTC reconnect succeeded`.
- Video ICE then moved to connected:
  `Video ICE connection state changed: RTCIceConnectionState(rawValue: 2) connected=true`.
- Roughly 16 seconds later, health monitoring repeatedly logged:
  `Video stream stalled ageSeconds=16.0 kbps=0 fps=nil rttMs=nil`.
- The reconnect loop repeated every ~20 seconds.

Working diagnosis:

- This is an app recovery bug, not intended behavior.
- After macOS sleep/display wake, the Janus/WebRTC session can appear connected
  while no decoded video frames or inbound video stats arrive.
- The current auto reconnect path tears down and recreates WebRTC, but it does
  not explicitly treat macOS sleep/wake as a hard session boundary.

Suggested fix direction:

- Observe macOS sleep/wake/display wake notifications.
- On sleep, explicitly disconnect WebRTC/Janus state.
- On wake, schedule a fresh reconnect after a short delay so Wi-Fi, USB-C
  display state, and the KVM endpoint have time to settle.
- Avoid multiple overlapping wake reconnect attempts.

