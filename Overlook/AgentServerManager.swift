import Foundation
import Network
import AppKit
import CoreImage

// MARK: - AgentServerManager

@MainActor
final class AgentServerManager: ObservableObject {
    static let defaultPort: UInt16 = 9876
    static let apiKeyDefaultsKey = "overlook.agentServer.apiKey"
    static let portDefaultsKey = "overlook.agentServer.port"
    static let enabledDefaultsKey = "overlook.agentServer.enabled"

    @Published var isRunning = false
    @Published var lastError: String?

    private var listener: NWListener?
    private weak var inputManager: InputManager?
    private weak var kvmDeviceManager: KVMDeviceManager?
    private weak var webRTCManager: WebRTCManager?
    private var ocrManager: OCRManager?

    func setup(inputManager: InputManager, kvmDeviceManager: KVMDeviceManager, webRTCManager: WebRTCManager) {
        self.inputManager = inputManager
        self.kvmDeviceManager = kvmDeviceManager
        self.webRTCManager = webRTCManager
        self.ocrManager = OCRManager()
        webRTCManager.setFrameCaptureEnabled(true)
    }

    // MARK: - API Key

    var apiKey: String {
        if let key = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !key.isEmpty {
            return key
        }
        let newKey = UUID().uuidString
        UserDefaults.standard.set(newKey, forKey: Self.apiKeyDefaultsKey)
        return newKey
    }

    func regenerateAPIKey() {
        UserDefaults.standard.set(UUID().uuidString, forKey: Self.apiKeyDefaultsKey)
        objectWillChange.send()
    }

    var configuredPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
        guard stored >= 1024, stored <= 65535 else { return Self.defaultPort }
        return UInt16(stored)
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        let port = configuredPort
        print("[AgentServer] Starting on port \(port)")
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let listener = try NWListener(using: .tcp, on: nwPort)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                print("[AgentServer] New connection from \(connection.endpoint)")
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        print("[AgentServer] Listening on port \(port)")
                        self?.isRunning = true
                        self?.lastError = nil
                    case .failed(let error):
                        print("[AgentServer] Failed: \(error)")
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                        self?.listener = nil
                    case .cancelled:
                        print("[AgentServer] Cancelled")
                        self?.isRunning = false
                        self?.listener = nil
                    default:
                        print("[AgentServer] State: \(state)")
                    }
                }
            }
            listener.start(queue: .global(qos: .utility))
        } catch {
            print("[AgentServer] Error creating listener: \(error)")
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        accumulate(connection: connection, buffer: Data())
    }

    private func accumulate(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buf = buffer
            if let chunk, !chunk.isEmpty { buf.append(chunk) }

            // Wait until we have the full HTTP header (ends with \r\n\r\n)
            let headerSeparator = Data("\r\n\r\n".utf8)
            if let sepRange = buf.range(of: headerSeparator) {
                Task { @MainActor in
                    print("[AgentServer] Request received (\(buf.count) bytes)")
                    let response = await self.processRequest(data: buf)
                    self.send(response, on: connection)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.accumulate(connection: connection, buffer: buf)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let body = response.body ?? Data()
        let header = "HTTP/1.1 \(response.status)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        var data = header.data(using: .utf8)!
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - HTTP Parsing

    private struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func parse(_ data: Data) -> ParsedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let sepRange = data.range(of: separator) else { return nil }

        let headerData = data[data.startIndex..<sepRange.lowerBound]
        let body = data[sepRange.upperBound...]

        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let tokens = requestLine.components(separatedBy: " ")
        guard tokens.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.range(of: ": ") {
                headers[String(line[line.startIndex..<colon.lowerBound]).lowercased()] = String(line[colon.upperBound...])
            }
        }
        return ParsedRequest(method: tokens[0], path: tokens[1], headers: headers, body: Data(body))
    }

    // MARK: - Response

    private struct HTTPResponse {
        let status: String
        let contentType: String
        let body: Data?

        static func json(_ dict: [String: Any], status: String = "200 OK") -> HTTPResponse {
            HTTPResponse(status: status, contentType: "application/json",
                         body: try? JSONSerialization.data(withJSONObject: dict))
        }
        static func error(_ msg: String, status: String = "400 Bad Request") -> HTTPResponse {
            .json(["error": msg], status: status)
        }
        static let noContent = HTTPResponse(status: "204 No Content", contentType: "text/plain", body: nil)
    }

    // MARK: - Routing

    private func processRequest(data: Data) async -> HTTPResponse {
        guard let req = parse(data) else {
            print("[AgentServer] Failed to parse request")
            return .error("Bad request")
        }

        print("[AgentServer] \(req.method) \(req.path)")

        if req.method == "OPTIONS" { return .noContent }

        let bearer = req.headers["authorization"] ?? ""
        let token = bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : bearer
        guard token == apiKey else {
            print("[AgentServer] Auth failed — token: '\(token)'")
            return .error("Unauthorized", status: "401 Unauthorized")
        }

        let path = req.path.components(separatedBy: "?").first ?? req.path

        switch (req.method, path) {
        case ("GET", "/status"):
            return .json([
                "connected": kvmDeviceManager?.glkvmClient != nil,
                "device": kvmDeviceManager?.connectedDevice?.name ?? NSNull()
            ])

        case ("POST", "/type"):
            guard let body = jsonBody(req.body), let text = body["text"] as? String else {
                return .error("Missing 'text'")
            }
            guard let client = kvmDeviceManager?.glkvmClient else {
                return .error("Not connected", status: "503 Service Unavailable")
            }
            do {
                try await client.hidPrint(text: text)
                return .json(["ok": true])
            } catch {
                return .error(error.localizedDescription, status: "500 Internal Server Error")
            }

        case ("POST", "/key"):
            guard let body = jsonBody(req.body), let key = body["key"] as? String else {
                return .error("Missing 'key'")
            }
            guard let client = kvmDeviceManager?.glkvmClient else {
                return .error("Not connected", status: "503 Service Unavailable")
            }
            do {
                let keys = key.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
                if keys.count > 1 {
                    try await client.sendHidShortcut(keys: keys)
                } else {
                    try await client.sendHidKey(key: key)
                }
                return .json(["ok": true])
            } catch {
                return .error(error.localizedDescription, status: "500 Internal Server Error")
            }

        case ("GET", "/mouse/position"):
            let mx = inputManager?.lastMouseX ?? 0
            let my = inputManager?.lastMouseY ?? 0
            return .json(["x": mx, "y": my])

        case ("POST", "/mouse/move"):
            guard let body = jsonBody(req.body),
                  let x = body["x"] as? Int, let y = body["y"] as? Int else {
                return .error("Missing 'x' or 'y'")
            }
            guard let ws = inputManager?.agentWebSocketClient else {
                return .error("Not connected", status: "503 Service Unavailable")
            }
            do {
                try await ws.sendHidMouseMove(toX: x, toY: y)
                inputManager?.lastMouseX = x
                inputManager?.lastMouseY = y
                return .json(["ok": true])
            } catch {
                return .error(error.localizedDescription, status: "500 Internal Server Error")
            }

        case ("POST", "/mouse/click"):
            let body = jsonBody(req.body) ?? [:]
            let button = body["button"] as? String ?? "left"
            guard let ws = inputManager?.agentWebSocketClient else {
                return .error("Not connected", status: "503 Service Unavailable")
            }
            do {
                try await ws.sendHidMouseButton(button: button, state: true)
                try await Task.sleep(nanoseconds: 50_000_000)
                try await ws.sendHidMouseButton(button: button, state: false)
                return .json(["ok": true])
            } catch {
                return .error(error.localizedDescription, status: "500 Internal Server Error")
            }

        case ("POST", "/mouse/scroll"):
            guard let body = jsonBody(req.body) else {
                return .error("Missing 'deltaX' or 'deltaY'")
            }
            let dx = asInt(body["deltaX"]) ?? 0
            let dy = asInt(body["deltaY"]) ?? 0
            guard let ws = inputManager?.agentWebSocketClient else {
                return .error("Not connected", status: "503 Service Unavailable")
            }
            do {
                let stepsX = dx == 0 ? 0 : (dx > 0 ? 1 : -1)
                let stepsY = dy == 0 ? 0 : (dy > 0 ? 1 : -1)
                let count = max(abs(dx), abs(dy))
                for _ in 0..<count {
                    try await ws.sendHidMouseWheel(deltaX: stepsX, deltaY: stepsY)
                }
                return .json(["ok": true])
            } catch {
                return .error(error.localizedDescription, status: "500 Internal Server Error")
            }

        case ("POST", "/find-text"):
            guard let body = jsonBody(req.body), let searchText = body["text"] as? String else {
                return .error("Missing 'text'")
            }
            guard let pixelBuffer = webRTCManager?.currentFrame else {
                return .error("No video frame available", status: "503 Service Unavailable")
            }
            do {
                let regions = try await ocrManager?.detectTextRegions(in: pixelBuffer) ?? []
                let query = searchText.lowercased()
                let matches: [[String: Any]] = regions
                    .filter { $0.text.lowercased().contains(query) }
                    .map { region in
                        let normX = region.boundingBox.midX
                        let normY = 1.0 - region.boundingBox.midY
                        let cx = Int((normX * 2.0 - 1.0) * 32767)
                        let cy = Int((normY * 2.0 - 1.0) * 32767)
                        return ["text": region.text,
                                "x": cx, "y": cy,
                                "confidence": Double(region.confidence)]
                    }
                return .json(["matches": matches])
            } catch {
                return .error(error.localizedDescription, status: "500 Internal Server Error")
            }

        case ("GET", "/screenshot"):
            guard let pngData = captureScreenshot() else {
                return .error("Screenshot failed", status: "500 Internal Server Error")
            }
            return HTTPResponse(status: "200 OK", contentType: "image/png", body: pngData)

        case ("POST", "/mcp"):
            return await handleMCP(req.body)

        default:
            return .error("Not found", status: "404 Not Found")
        }
    }

    // MARK: - MCP (Model Context Protocol) — Streamable HTTP transport

    private func handleMCP(_ body: Data) async -> HTTPResponse {
        guard let rpc = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return mcpError(id: nil, code: -32700, message: "Parse error")
        }

        let id = rpc["id"]
        let method = rpc["method"] as? String ?? ""
        let params = rpc["params"] as? [String: Any] ?? [:]

        // Notifications have no id — acknowledge silently
        if id == nil {
            return HTTPResponse(status: "204 No Content", contentType: "application/json", body: nil)
        }

        switch method {
        case "initialize":
            return mcpResult(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "overlook-kvm", "version": "1.0.0"]
            ])

        case "ping":
            return mcpResult(id: id, result: [:])

        case "tools/list":
            return mcpResult(id: id, result: ["tools": mcpToolList()])

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return await mcpCallTool(id: id, name: toolName, args: args)

        default:
            return mcpError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func mcpToolList() -> [[String: Any]] {
        func schema(_ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var s: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { s["required"] = required }
            return s
        }
        func prop(_ type: String, _ description: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var p: [String: Any] = ["type": type, "description": description]
            p.merge(extra) { _, new in new }
            return p
        }
        return [
            ["name": "get_status",
             "description": "Check whether Overlook is connected to a KVM device",
             "inputSchema": schema()],

            ["name": "take_screenshot",
             "description": "Capture the current KVM video frame as a PNG image (base64-encoded)",
             "inputSchema": schema()],

            ["name": "type_text",
             "description": "Type text on the remote machine via HID",
             "inputSchema": schema(["text": prop("string", "The text to type")], required: ["text"])],

            ["name": "press_key",
             "description": "Press a key or shortcut on the remote machine. Examples: 'Enter', 'Escape', 'Tab', 'ctrl+c', 'meta+tab'",
             "inputSchema": schema(["key": prop("string", "Key name or shortcut, e.g. 'Enter' or 'ctrl+c'")], required: ["key"])],

            ["name": "get_mouse_position",
             "description": "Get current mouse position in HID coordinates (-32767 to +32767, center 0,0)",
             "inputSchema": schema()],

            ["name": "move_mouse",
             "description": "Move mouse to absolute HID coordinates. Range: -32767 (left/top) to +32767 (right/bottom), center 0,0",
             "inputSchema": schema([
                "x": prop("integer", "Horizontal HID position (-32767 to 32767)"),
                "y": prop("integer", "Vertical HID position (-32767 to 32767)")
             ], required: ["x", "y"])],

            ["name": "click_mouse",
             "description": "Click a mouse button at the current mouse position",
             "inputSchema": schema(["button": prop("string", "Mouse button: left, right, or middle", ["enum": ["left", "right", "middle"], "default": "left"])])],

            ["name": "scroll_mouse",
             "description": "Scroll the mouse wheel at the current position",
             "inputSchema": schema([
                "deltaX": prop("integer", "Horizontal scroll (positive=right, negative=left)"),
                "deltaY": prop("integer", "Vertical scroll (positive=down, negative=up)")
             ])],

            ["name": "find_text",
             "description": "OCR search for text on the KVM screen. Returns matches with HID coordinates usable with move_mouse.",
             "inputSchema": schema(["text": prop("string", "Text to search for (case-insensitive)")], required: ["text"])]
        ]
    }

    private func mcpCallTool(id: Any?, name: String, args: [String: Any]) async -> HTTPResponse {
        do {
            let content = try await executeMCPTool(name: name, args: args)
            return mcpResult(id: id, result: ["content": content])
        } catch {
            return mcpResult(id: id, result: [
                "content": [["type": "text", "text": error.localizedDescription]],
                "isError": true
            ])
        }
    }

    private func executeMCPTool(name: String, args: [String: Any]) async throws -> [[String: Any]] {
        switch name {
        case "get_status":
            let connected = kvmDeviceManager?.glkvmClient != nil
            let device = kvmDeviceManager?.connectedDevice?.name ?? "none"
            let msg = connected ? "Connected to device: \(device)" : "Not connected to any KVM device"
            return [["type": "text", "text": msg]]

        case "take_screenshot":
            guard let pngData = captureScreenshot() else { throw MCPError("Screenshot failed") }
            return [["type": "image", "data": pngData.base64EncodedString(), "mimeType": "image/png"]]

        case "type_text":
            guard let text = args["text"] as? String else { throw MCPError("Missing 'text'") }
            guard let client = kvmDeviceManager?.glkvmClient else { throw MCPError("Not connected") }
            try await client.hidPrint(text: text)
            return [["type": "text", "text": "Typed: \(text)"]]

        case "press_key":
            guard let key = args["key"] as? String else { throw MCPError("Missing 'key'") }
            guard let client = kvmDeviceManager?.glkvmClient else { throw MCPError("Not connected") }
            let keys = key.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            if keys.count > 1 {
                try await client.sendHidShortcut(keys: keys)
            } else {
                try await client.sendHidKey(key: key)
            }
            return [["type": "text", "text": "Pressed: \(key)"]]

        case "get_mouse_position":
            let x = inputManager?.lastMouseX ?? 0
            let y = inputManager?.lastMouseY ?? 0
            return [["type": "text", "text": "Mouse position: x=\(x), y=\(y)"]]

        case "move_mouse":
            guard let x = asInt(args["x"]), let y = asInt(args["y"]) else { throw MCPError("Missing 'x' or 'y'") }
            guard let ws = inputManager?.agentWebSocketClient else { throw MCPError("Not connected") }
            try await ws.sendHidMouseMove(toX: x, toY: y)
            inputManager?.lastMouseX = x
            inputManager?.lastMouseY = y
            return [["type": "text", "text": "Mouse moved to x=\(x), y=\(y)"]]

        case "click_mouse":
            let button = args["button"] as? String ?? "left"
            guard let ws = inputManager?.agentWebSocketClient else { throw MCPError("Not connected") }
            try await ws.sendHidMouseButton(button: button, state: true)
            try await Task.sleep(nanoseconds: 50_000_000)
            try await ws.sendHidMouseButton(button: button, state: false)
            return [["type": "text", "text": "Clicked \(button) mouse button"]]

        case "scroll_mouse":
            let dx = asInt(args["deltaX"]) ?? 0
            let dy = asInt(args["deltaY"]) ?? 0
            guard let ws = inputManager?.agentWebSocketClient else { throw MCPError("Not connected") }
            let stepsX = dx == 0 ? 0 : (dx > 0 ? 1 : -1)
            let stepsY = dy == 0 ? 0 : (dy > 0 ? 1 : -1)
            for _ in 0..<max(abs(dx), abs(dy)) {
                try await ws.sendHidMouseWheel(deltaX: stepsX, deltaY: stepsY)
            }
            return [["type": "text", "text": "Scrolled dx=\(dx), dy=\(dy)"]]

        case "find_text":
            guard let searchText = args["text"] as? String else { throw MCPError("Missing 'text'") }
            guard let pixelBuffer = webRTCManager?.currentFrame else { throw MCPError("No video frame available") }
            let regions = try await ocrManager?.detectTextRegions(in: pixelBuffer) ?? []
            let query = searchText.lowercased()
            let matches = regions.filter { $0.text.lowercased().contains(query) }
            if matches.isEmpty {
                return [["type": "text", "text": "No matches found for: \"\(searchText)\""]]
            }
            let lines = matches.map { r -> String in
                let normX = r.boundingBox.midX
                let normY = 1.0 - r.boundingBox.midY
                let cx = Int((normX * 2.0 - 1.0) * 32767)
                let cy = Int((normY * 2.0 - 1.0) * 32767)
                return "• \"\(r.text)\" at x=\(cx), y=\(cy) (confidence: \(String(format: "%.1f", r.confidence * 100))%)"
            }
            return [["type": "text", "text": "Found \(matches.count) match(es) for \"\(searchText)\":\n\(lines.joined(separator: "\n"))"]]

        default:
            throw MCPError("Unknown tool: \(name)")
        }
    }

    // MARK: - MCP JSON-RPC helpers

    private struct MCPError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func mcpResult(id: Any?, result: [String: Any]) -> HTTPResponse {
        var rpc: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { rpc["id"] = id }
        return HTTPResponse(status: "200 OK", contentType: "application/json",
                            body: try? JSONSerialization.data(withJSONObject: rpc))
    }

    private func mcpError(id: Any?, code: Int, message: String) -> HTTPResponse {
        var rpc: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { rpc["id"] = id }
        return HTTPResponse(status: "200 OK", contentType: "application/json",
                            body: try? JSONSerialization.data(withJSONObject: rpc))
    }

    // MARK: - Helpers

    private func jsonBody(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func asInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    private func captureScreenshot() -> Data? {
        // Prefer the live KVM video frame over the Mac display
        if let pixelBuffer = webRTCManager?.currentFrame {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                return rep.representation(using: .png, properties: [:])
            }
        }
        // Fallback: capture the Mac display
        let displayID = CGMainDisplayID()
        guard let cgImage = CGDisplayCreateImage(displayID) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
