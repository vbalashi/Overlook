#!/usr/bin/env python3
"""Run the real paste implementation against a bounded, recording API stub."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Overlook/GLKVMClient.swift").read_text()
a = source.index("private actor HIDPrintQueue {")
b = source.index("\nfinal class GLKVMClient", a)
queue = source[a:b]
a = source.index("    static func hidPrintChunks(")
b = source.index("\n    func sendHidShortcut", a)
methods = source[a:b]
harness = r"""import Foundation
struct GLKVMEmptyResult {}
struct GLKVMResponse<T> {}
enum TestError: Error { case requestedFailure }
actor Recorder {
 var output = ""
 var calls = 0
 var failAt = 0
 var maxBody = 512
 var expectedSlow: String?
 func expect(size: Int, slow: String?) { maxBody = size; expectedSlow = slow }
 func accept(_ body: Data, query: [URLQueryItem]) async throws {
  calls += 1
  if calls == failAt { throw TestError.requestedFailure }
  precondition(body.count <= maxBody, "HTTP body exceeds bounded chunk size")
  precondition(query.first(where: { $0.name == "limit" })?.value == "0", "Missing explicit unlimited firmware parameter")
  if let expectedSlow { precondition(query.first(where: { $0.name == "slow" })?.value == expectedSlow) }
  try await Task.sleep(nanoseconds: 100_000)
  output += String(data: body, encoding: .utf8)!
 }
 func reset(failAt: Int = 0) { output = ""; calls = 0; self.failAt = failAt }
}
""" + queue + r"""
final class Harness: @unchecked Sendable {
 private let printQueue = HIDPrintQueue()
 let printSession = URLSession.shared
 let recorder = Recorder()
 func request<Response>(method: String, path: String, query: [URLQueryItem], body: Data, contentType: String, responseType: Response.Type, sessionOverride: URLSession? = nil) async throws -> Response {
  precondition(path == "api/hid/print")
  precondition(sessionOverride != nil, "Paste must use its dedicated long-timeout session")
  try await recorder.accept(body, query: query)
  return GLKVMResponse<GLKVMEmptyResult>() as! Response
 }
""" + methods + r"""
}
func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL:", message); exit(1) } }
func run() async throws {
 let h = Harness()
 let text = "  " + String(repeating: "abc абв 😀 e\u{301}\r\n", count: 1500) + "\n  "
 try await h.hidPrint(text: text)
 let output = await h.recorder.output
 check(output == text, "Large Unicode paste or whitespace was lost")
 check(await h.recorder.calls > 1, "Large paste was not chunked")
 await h.recorder.reset()
 try await h.hidPrint(text: "a😀e\u{301}z", limit: 3)
 check(await h.recorder.output == "a😀e", "Explicit limit must count Unicode scalar values like firmware")
 await h.recorder.reset()
 async let first: Void = h.hidPrint(text: String(repeating:"A",count:1500))
 async let second: Void = h.hidPrint(text: String(repeating:"B",count:1500))
 _ = try await (first,second)
 let actual = await h.recorder.output
 let aa = String(repeating:"A",count:1500), bb = String(repeating:"B",count:1500)
 check(actual == aa+bb || actual == bb+aa, "Concurrent pastes interleaved")
 await h.recorder.reset(failAt: 2)
 do { try await h.hidPrint(text: String(repeating:"C",count:1500)); check(false,"Failure was swallowed") } catch TestError.requestedFailure {}
 check(await h.recorder.calls == 2, "Paste continued after a failed chunk")
 try await h.hidPrint(text:"next")
 check(await h.recorder.output == String(repeating:"C",count:512)+"next", "Failed paste poisoned queue or duplicated text")
 for speed in HIDTypingSpeed.allCases {
  await h.recorder.reset()
  await h.recorder.expect(size: speed.chunkBytes, slow: speed.usesSlowKeys ? "true" : "false")
  let sample = String(repeating:"a😀?!", count:700)
  try await h.hidPrint(text:sample, speed:speed)
  check(await h.recorder.output == sample,"Speed changed text")
 }
 await h.recorder.reset()
 await h.recorder.expect(size:512,slow:"true")
 try await h.hidPrint(text:"override",slow:true,speed:.turbo)
 print("PASS: all four speeds and explicit slow override")
 print("PASS: large Unicode paste, exact whitespace, byte bounds, explicit limit, queue ordering and failure recovery")
}
let semaphore = DispatchSemaphore(value:0)
Task.detached {
 do { try await run(); semaphore.signal() } catch { print("FAIL:",error); exit(1) }
}
semaphore.wait()
"""
with tempfile.TemporaryDirectory(prefix="overlook-paste-") as directory:
    path = Path(directory) / "main.swift"
    path.write_text(harness)
    subprocess.run(["swift", str(path)], check=True)
