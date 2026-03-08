import Foundation
import Network
import AppKit

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

    func setup(inputManager: InputManager, kvmDeviceManager: KVMDeviceManager) {
        self.inputManager = inputManager
        self.kvmDeviceManager = kvmDeviceManager
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

        case ("GET", "/screenshot"):
            guard let pngData = captureScreenshot() else {
                return .error("Screenshot failed", status: "500 Internal Server Error")
            }
            return HTTPResponse(status: "200 OK", contentType: "image/png", body: pngData)

        default:
            return .error("Not found", status: "404 Not Found")
        }
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
