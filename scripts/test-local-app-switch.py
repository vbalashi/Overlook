#!/usr/bin/env python3
"""Extract the real shortcut classifier; macOS app switching stays local."""
import re,subprocess,tempfile
from pathlib import Path
s=(Path(__file__).resolve().parents[1]/'Overlook/InputManager.swift').read_text()
a=s.index('    private func localActionFor(');b=s.index('\n    private func clearPendingCommandKey',a)
f=s[a:b].replace('private func','func',1)
code='import Cocoa\nenum LocalKeyAction { case passthrough, pasteClipboard, startSnippet }\n'+f+'''
precondition(localActionFor(keyCode:48,modifiers:[.command]) == .passthrough, "Cmd-Tab must stay local")
precondition(localActionFor(keyCode:48,modifiers:[.command,.shift]) == .passthrough, "Cmd-Shift-Tab must stay local")
precondition(localActionFor(keyCode:9,modifiers:[.command,.shift]) == .pasteClipboard)
print("PASS: app switching stays local; clipboard shortcut preserved")
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'main.swift';p.write_text(code);subprocess.run(['swift',str(p)],check=True)
