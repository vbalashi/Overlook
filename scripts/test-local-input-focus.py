#!/usr/bin/env python3
"""Exercise the actual input router against a local AppKit text editor."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Overlook/InputManager.swift").read_text()
start = source.index("    private func handleKeyEvent(_ event:")
end = source.index("\n    private func handleKeyEventDuringSnippet", start)
method = source[start:end].replace("private func", "func", 1)
stubs = """import Cocoa
final class Harness {
 var isKeyboardCaptureEnabled = true
 var isSnippetModeActive = false
 var forwarded = 0
 func handleKeyEventDuringSnippet(_ event: NSEvent) -> NSEvent? { nil }
 func handleKeyDownOrUp(_ event: NSEvent) -> NSEvent? { forwarded += 1; return nil }
 func handleFlagsChanged(_ event: NSEvent) { forwarded += 1 }
"""
tail = 'let app = NSApplication.shared\napp.setActivationPolicy(.prohibited)\nlet window = NSWindow(contentRect: NSRect(x:0,y:0,width:200,height:100), styleMask:[.titled], backing:.buffered, defer:false)\nlet editor = NSTextView(frame:NSRect(x:0,y:0,width:100,height:30))\neditor.isEditable = true\nwindow.contentView!.addSubview(editor)\nwindow.makeFirstResponder(editor)\nlet event = NSEvent.keyEvent(with:.keyDown, location:.zero, modifierFlags:[], timestamp:0, windowNumber:window.windowNumber, context:nil, characters:"x", charactersIgnoringModifiers:"x", isARepeat:false, keyCode:7)!\nlet h = Harness()\nguard h.handleKeyEvent(event) === event && h.forwarded == 0 else {\n print("FAIL: local editor keystroke was intercepted"); exit(1)\n}\nwindow.makeFirstResponder(window.contentView)\nguard h.handleKeyEvent(event) == nil && h.forwarded == 1 else {\n print("FAIL: remote surface input was not forwarded"); exit(1)\n}\nprint("PASS: local editor keeps keystrokes; remote surface still receives input")\n'
with tempfile.TemporaryDirectory(prefix="overlook-focus-") as directory:
    path = Path(directory) / "main.swift"
    path.write_text(stubs + method + "\n}\n" + tail)
    subprocess.run(["swift", str(path)], check=True)
