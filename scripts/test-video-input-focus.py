#!/usr/bin/env python3
"""A video click must release a previously focused local text editor."""
from pathlib import Path
import subprocess,tempfile,re
src=(Path(__file__).resolve().parents[1]/'Overlook/VideoSurfaceView.swift').read_text()
method=re.search(r'    override func mouseDown\(with event: NSEvent\) \{.*?\n    \}',src,re.S).group()
accept=re.search(r'    override var acceptsFirstResponder: Bool \{.*?\}',src)
code='''import Cocoa
enum MouseButton { case left }
final class Surface: NSView {
var onMouseButton: ((MouseButton,Bool,CGPoint)->Void)?
'''+(accept.group() if accept else '')+'\n'+method+'''
}
let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
let w=NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
let editor=NSTextView(frame:.zero)
let surface=Surface(frame:NSRect(x:0,y:0,width:200,height:100))
w.contentView!.addSubview(editor)
w.contentView!.addSubview(surface)
w.makeFirstResponder(editor)
let e=NSEvent.mouseEvent(with:.leftMouseDown,location:NSPoint(x:50,y:50),modifierFlags:[],timestamp:0,windowNumber:w.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
surface.mouseDown(with:e)
guard w.firstResponder === surface else { print("FAIL: video click leaves local editor focused");exit(1) }
print("PASS: video click takes keyboard focus")
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'main.swift';p.write_text(code)
 subprocess.run(['swift',str(p)],check=True)
