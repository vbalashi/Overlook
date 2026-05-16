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

## Local Build Contract

- Build local debug artifacts only through `./build.sh -c debug`.
- Launch local debug builds from `build/debug/Overlook Debug.app`.
- Do not use raw `xcodebuild` for day-to-day harness checks. The wrapper sets
  the debug product name and bundle id, stamps the git commit into the app, and
  unregisters/removes duplicate build products that would otherwise appear in
  Spotlight or LaunchServices.
- If a raw Xcode build was run accidentally, repair local app discovery with:
  `scripts/cleanup-overlook-build-products.sh --keep "$PWD/build/debug/Overlook Debug.app"`.
- Before trusting a harness result, the duplicate guardrail should pass:
  `scripts/cleanup-overlook-build-products.sh --keep "$PWD/build/debug/Overlook Debug.app" --check`.

## Git Hygiene Contract

- Before making any code, script, project, or documentation change, run
  `git status --short` and confirm whether the tree is clean.
- If the tree is not clean, inspect the existing diff first and either commit it
  as the baseline or explicitly preserve it as unrelated user work before
  starting new edits.
- After every completed change set, run the relevant verification, then commit
  the touched files before moving to the next task.
- Start each new task from a clean working tree whenever possible. This keeps
  harness results attributable to one change set and avoids accidentally mixing
  unrelated edits.

## 2026-05-16 GLKVM Microphone Passthrough

Device context:

- Target: `glkvm.local` / `192.168.178.60`.
- Firmware: GLKVM / GL.iNet KVM, Buildroot `rm10rc-1.8.1-release1`,
  kernel `6.1.141`.
- USB gadget audio is exposed as `uac2.usb0` with
  `function_name=Microsoft Microphone`, `idVendor=0x045e`,
  `idProduct=0x005f`.

Important finding:

- `UAC2Gadget` appears as ALSA playback-only on the KVM:
  `/dev/snd/pcmC1D0p`.
- That is expected for the browser-mic-to-Windows path: Janus/uStreamer writes
  browser microphone RTP to local ALSA playback, and the USB host sees that as
  microphone input.
- The configfs values were `c_chmask=0`, `c_srate=64000`, `p_chmask=3`,
  `p_srate=48000`.

Startup/order hazard:

- If `kvmd-janus` starts before `/run/kvmd/otg/uac2.usb0@meta.json` exists,
  uStreamer logs `No check file found, aplay will be disabled`.
- In that state, the browser/app can appear connected but `pcmC1D0p` remains
  closed and Windows receives no mic.
- A clean restart after the OTG meta file exists fixes the disabled aplay path:
  stop duplicate Janus processes, confirm the meta file, then start
  `/etc/init.d/S99kvmd-janus`.

Healthy signature:

- `kvmd-janus` logs `PCM capture is available`.
- There is no `aplay will be disabled` line.
- When mic is active, `fuser /dev/snd/pcmC1D0p` shows the Janus process and
  `/proc/asound/card1/pcm0p/sub0/status` moves to `RUNNING`.
- Logs include `ustreamer/aplay -- Playback opened, playing`.

Known instability:

- The UAC2 playback path can still report XRUNs:
  `Can't play to PCM playback: Resource temporarily unavailable`, followed by
  `Playing resumed (snd_pcm_recover)`.
- Browser mic passthrough works after a clean Janus start, though quality is
  not perfect.

Overlook-specific diagnosis:

- GLKVM's browser frontend treats microphone as dependent on audio: it only
  captures mic when audio is also requested.
- Overlook previously allowed mic to be toggled independently and did not
  reconnect when a pre-existing audio peer connection existed. That meant Janus
  did not receive a fresh `watch` request with `mic=true`, and no local mic
  sender was added if the session started with mic disabled.

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
