#!/usr/bin/env python3
"""Test the real credential store using isolated disposable macOS Keychain items."""
from pathlib import Path
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
source = (root / "Overlook/KVMDeviceManager.swift").read_text()
start = source.index("enum DevicePasswordStore {")
end = source.index("\nenum TLSValidationPolicy", start)
service = "com.overlook.test.credentials." + uuid.uuid4().hex
helper = source[start:end].replace("com.overlook.app.device-passwords", service)
template = 'let cleanup: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "TEST_SERVICE"]\ndefer { SecItemDelete(cleanup as CFDictionary) }\nlet host = "regression.example.invalid"\nlet result51 = try DevicePasswordStore.load(host: host, port: 443, user: "admin") == nil\nprecondition(result51)\ntry DevicePasswordStore.save(" initial ü secret ", host: host, port: 443, user: "admin")\nlet result53 = try DevicePasswordStore.load(host: host.uppercased(), port: 443, user: "admin") == " initial ü secret "\nprecondition(result53)\ntry DevicePasswordStore.save("replacement", host: host, port: 443, user: "admin")\nlet result55 = try DevicePasswordStore.load(host: host, port: 443, user: "admin") == "replacement"\nprecondition(result55)\nlet result56 = try DevicePasswordStore.load(host: host, port: 8443, user: "admin") == nil\nprecondition(result56)\nlet result57 = try DevicePasswordStore.load(host: host, port: 443, user: "other") == nil\nprecondition(result57)\nprint("PASS: actual macOS Keychain create/read/update; host, port and user isolation; exact Unicode password")'
harness = "import Foundation\nimport Security\n" + helper + template.replace("TEST_SERVICE", service)
with tempfile.TemporaryDirectory(prefix="overlook-keychain-") as directory:
    path = Path(directory) / "main.swift"
    path.write_text(harness)
    subprocess.run(["swift", str(path)], check=True)
