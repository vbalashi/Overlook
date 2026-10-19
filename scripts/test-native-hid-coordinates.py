#!/usr/bin/env python3
"""Exercise the real Swift HID encoder against GLKVM signed wire coordinates."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Overlook/WebRTCManager.swift").read_text()
start = source.index("    func sendNativeHIDMouseMove(x:")
end = source.index("\n    @discardableResult", start)
method = source[start:end]
harness = """import Foundation
final class Harness {
    var sent = Data()
    func sendNativeHIDPayload(_ data: Data) -> Bool { sent = data; return true }
""" + method + """
}
let h = Harness()
let cases: [(Int, [UInt8])] = [(-32768,[0x80,0]),(-1,[0xff,0xff]),(0,[0,0]),(32767,[0x7f,0xff]),(-40000,[0x80,0]),(40000,[0x7f,0xff])]
for (value, bytes) in cases {
    _ = h.sendNativeHIDMouseMove(x: value, y: 0)
    guard Array(h.sent) == [3] + bytes + [0,0] else {
        print("FAIL: horizontal HID coordinate", value); exit(1)
    }
    _ = h.sendNativeHIDMouseMove(x: 0, y: value)
    guard Array(h.sent) == [3,0,0] + bytes else {
        print("FAIL: vertical HID coordinate", value); exit(1)
    }
}
print("PASS: signed HID coordinates on both axes and boundary clamping")
"""
with tempfile.TemporaryDirectory(prefix="overlook-hid-") as directory:
    path = Path(directory) / "main.swift"
    path.write_text(harness)
    subprocess.run(["swift", str(path)], check=True)
