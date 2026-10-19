#!/usr/bin/env python3
"""Exercise actual Agent mouse transport selection without the physical KVM."""
from pathlib import Path
import tempfile,subprocess
s=(Path(__file__).resolve().parents[1]/'Overlook/InputManager.swift').read_text()
a=s.index('    func sendHidMouseMove(toX');b=s.index('    func setSnippetModeActive',a)
code='''import Foundation
final class Native {
 var ready=true; var calls=0
 func sendNativeHIDMouseMove(x:Int,y:Int)->Bool { calls += 1; return ready }
 func sendNativeHIDMouseButton(button:String,isDown:Bool)->Bool { calls += 1; return ready }
 func sendNativeHIDMouseWheel(deltaX:Int,deltaY:Int)->Bool { calls += 1; return ready }
}
final class HTTP {
 var calls=0
 func sendHidMouseMove(toX:Int,toY:Int) async throws { calls += 1 }
 func sendHidMouseButton(button:String,state:Bool) async throws { calls += 1 }
 func sendHidMouseWheel(deltaX:Int,deltaY:Int) async throws { calls += 1 }
}
final class Harness {
 var webRTCManager: Native? = Native()
 var glkvmClient: HTTP? = HTTP()
'''+s[a:b]+'''
}
func run() async throws {
 let h=Harness()
 try await h.sendHidMouseMove(toX:-100,toY:100)
 try await h.sendHidMouseButton(button:"left",state:true)
 try await h.sendHidMouseWheel(deltaX:0,deltaY:1)
 precondition(h.webRTCManager!.calls==3 && h.glkvmClient!.calls==0)
 h.webRTCManager!.ready=false
 try await h.sendHidMouseMove(toX:0,toY:0)
 try await h.sendHidMouseButton(button:"left",state:false)
 try await h.sendHidMouseWheel(deltaX:0,deltaY:-1)
 precondition(h.glkvmClient!.calls==3)
 h.glkvmClient=nil
 do { try await h.sendHidMouseMove(toX:0,toY:0);fatalError("Missing transport accepted") } catch {}
 print("PASS: native Agent mouse transport and HTTP fallback")
}
let semaphore=DispatchSemaphore(value:0)
Task { do { try await run();semaphore.signal() } catch { print(error);exit(1) } }
semaphore.wait()
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'main.swift';p.write_text(code);subprocess.run(['swift',str(p)],check=True)
