#!/usr/bin/env swift
import Foundation

private struct Arguments {
    var host: String?
    var port: Int = 443
    var user: String = "admin"
    var password: String?
    var token: String?
    var duration: TimeInterval = 10
    var output: String?
    var allowInsecureTLS: Bool = true
}

private enum CaptureError: Error, CustomStringConvertible {
    case missingHost
    case invalidArgument(String)
    case invalidURL
    case httpError(Int, String)
    case loginTokenMissing
    case websocketClosed

    var description: String {
        switch self {
        case .missingHost:
            return "missing required --host"
        case .invalidArgument(let message):
            return message
        case .invalidURL:
            return "invalid URL"
        case .httpError(let status, let body):
            return "HTTP \(status): \(body)"
        case .loginTokenMissing:
            return "login succeeded but no auth_token was found"
        case .websocketClosed:
            return "websocket closed before capture completed"
        }
    }
}

private final class SessionDelegate: NSObject, URLSessionDelegate {
    private let allowInsecureTLS: Bool

    init(allowInsecureTLS: Bool) {
        self.allowInsecureTLS = allowInsecureTLS
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowInsecureTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private func usage() -> String {
    """
    Usage:
      scripts/capture-direct-media.swift --host <host> [options]

    Options:
      --host <host>         GLKVM host or IP. Required.
      --port <port>         Device port. Default: 443.
      --token <token>       Existing auth_token cookie value.
      --password <password> Login password. Used only when --token is omitted.
      --user <user>         Login user for --password. Default: admin.
      --duration <seconds>  Capture duration. Default: 10.
      --output <path>       Capture output path. Default: ../diagnostics/direct-media-captures/<timestamp>.ovdm.
      --strict-tls          Do not allow self-signed device certificates.
      --help                Show this help.

    Output:
      The .ovdm file stores websocket message boundaries:
        magic "OVDM1\\n", then repeated records:
        1 byte type (1=binary, 2=text), 8 byte big-endian payload length, payload bytes.

      A .jsonl sidecar is written next to the capture with redacted per-message metadata.
    """
}

private func parseArguments(_ raw: [String]) throws -> Arguments {
    var args = Arguments()
    var index = 0

    func requireValue(after flag: String) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < raw.count else {
            throw CaptureError.invalidArgument("\(flag) requires a value")
        }
        return raw[valueIndex]
    }

    while index < raw.count {
        let arg = raw[index]
        switch arg {
        case "--host":
            args.host = try requireValue(after: arg)
            index += 2
        case "--port":
            let value = try requireValue(after: arg)
            guard let port = Int(value), port > 0, port <= 65535 else {
                throw CaptureError.invalidArgument("--port must be 1...65535")
            }
            args.port = port
            index += 2
        case "--user":
            args.user = try requireValue(after: arg)
            index += 2
        case "--password":
            args.password = try requireValue(after: arg)
            index += 2
        case "--token":
            args.token = try requireValue(after: arg)
            index += 2
        case "--duration":
            let value = try requireValue(after: arg)
            guard let duration = TimeInterval(value), duration > 0 else {
                throw CaptureError.invalidArgument("--duration must be a positive number")
            }
            args.duration = duration
            index += 2
        case "--output":
            args.output = try requireValue(after: arg)
            index += 2
        case "--strict-tls":
            args.allowInsecureTLS = false
            index += 1
        case "--help", "-h":
            print(usage())
            exit(0)
        default:
            throw CaptureError.invalidArgument("unknown argument: \(arg)")
        }
    }

    guard args.host?.isEmpty == false else {
        throw CaptureError.missingHost
    }

    return args
}

private func baseURL(host: String, port: Int) throws -> URL {
    let scheme = (port == 80 || port == 8080) ? "http" : "https"
    guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
        throw CaptureError.invalidURL
    }
    return url
}

private func mediaWebSocketURL(baseURL: URL) throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
        throw CaptureError.invalidURL
    }
    components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
    components.path = "/api/media/ws"
    guard let url = components.url else {
        throw CaptureError.invalidURL
    }
    return url
}

private func login(
    baseURL: URL,
    user: String,
    password: String,
    session: URLSession
) async throws -> String {
    guard let url = URL(string: "api/auth/login", relativeTo: baseURL)?.absoluteURL else {
        throw CaptureError.invalidURL
    }

    let boundary = "----OverlookBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append("Content-Disposition: form-data; name=\"user\"\r\n\r\n".data(using: .utf8) ?? Data())
    body.append("\(user)\r\n".data(using: .utf8) ?? Data())
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append("Content-Disposition: form-data; name=\"passwd\"\r\n\r\n".data(using: .utf8) ?? Data())
    body.append("\(password)\r\n".data(using: .utf8) ?? Data())
    body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())

    var request = URLRequest(url: url)
    request.assumesHTTP3Capable = false
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw CaptureError.invalidURL
    }

    guard (200...299).contains(http.statusCode) else {
        let body = String(data: data.prefix(512), encoding: .utf8) ?? "<\(data.count) bytes>"
        throw CaptureError.httpError(http.statusCode, body)
    }

    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let result = json["result"] as? [String: Any],
       let token = result["token"] as? String,
       !token.isEmpty {
        return token
    }

    let headers = http.allHeaderFields as? [String: String] ?? [:]
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
    if let token = cookies.first(where: { $0.name == "auth_token" })?.value, !token.isEmpty {
        return token
    }

    throw CaptureError.loginTokenMissing
}

private func defaultOutputPath() throws -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.timeZone = TimeZone.current

    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .deletingLastPathComponent()
        .appendingPathComponent("diagnostics/direct-media-captures", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("direct-media-\(formatter.string(from: Date())).ovdm")
}

private func outputURL(from path: String?) throws -> URL {
    guard let path, !path.isEmpty else {
        return try defaultOutputPath()
    }

    let url = URL(fileURLWithPath: path)
    let absolute = url.path.hasPrefix("/") ? url : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
    try FileManager.default.createDirectory(at: absolute.deletingLastPathComponent(), withIntermediateDirectories: true)
    return absolute
}

private func appendRecordHeader(type: UInt8, length: Int, to data: inout Data) {
    data.append(type)
    var value = UInt64(length).bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func hexPrefix(_ data: Data, limit: Int = 32) -> String {
    data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
}

private func sidecarLine(index: Int, type: String, payload: Data, elapsed: TimeInterval) -> String {
    let object: [String: Any] = [
        "index": index,
        "elapsed_ms": Int(elapsed * 1000),
        "type": type,
        "bytes": payload.count,
        "hex_prefix": hexPrefix(payload),
    ]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
}

private func runCapture() async throws {
    let args = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let host = args.host ?? ""
    let base = try baseURL(host: host, port: args.port)
    let mediaURL = try mediaWebSocketURL(baseURL: base)
    let session = URLSession(
        configuration: .default,
        delegate: SessionDelegate(allowInsecureTLS: args.allowInsecureTLS),
        delegateQueue: nil
    )

    let authToken: String?
    if let token = args.token, !token.isEmpty {
        authToken = token
    } else if let password = args.password {
        print("Logging in to \(base.absoluteString) as \(args.user)...")
        authToken = try await login(baseURL: base, user: args.user, password: password, session: session)
    } else {
        authToken = nil
    }

    let captureURL = try outputURL(from: args.output)
    let sidecarURL = captureURL.deletingPathExtension().appendingPathExtension("jsonl")

    var request = URLRequest(url: mediaURL)
    request.assumesHTTP3Capable = false
    request.setValue("\(base.scheme ?? "https")://\(host):\(args.port)", forHTTPHeaderField: "Origin")
    if let authToken, !authToken.isEmpty {
        request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
    }

    print("Connecting to \(mediaURL.absoluteString)")
    print("Writing capture to \(captureURL.path)")
    print("Writing metadata to \(sidecarURL.path)")

    let task = session.webSocketTask(with: request)
    task.resume()
    defer {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    var capture = Data("OVDM1\n".utf8)
    var sidecar = Data()
    let started = Date()
    let deadline = started.addingTimeInterval(args.duration)
    var messageIndex = 0
    var binaryMessages = 0
    var textMessages = 0
    var payloadBytes = 0

    while Date() < deadline {
        let message = try await task.receive()
        let elapsed = Date().timeIntervalSince(started)
        messageIndex += 1

        switch message {
        case .data(let payload):
            binaryMessages += 1
            payloadBytes += payload.count
            appendRecordHeader(type: 1, length: payload.count, to: &capture)
            capture.append(payload)
            sidecar.append(Data(sidecarLine(index: messageIndex, type: "binary", payload: payload, elapsed: elapsed).utf8))
            print("#\(messageIndex) binary \(payload.count)B prefix=\(hexPrefix(payload))")
        case .string(let text):
            let payload = Data(text.utf8)
            textMessages += 1
            payloadBytes += payload.count
            appendRecordHeader(type: 2, length: payload.count, to: &capture)
            capture.append(payload)
            sidecar.append(Data(sidecarLine(index: messageIndex, type: "text", payload: payload, elapsed: elapsed).utf8))
            print("#\(messageIndex) text \(payload.count)B prefix=\(hexPrefix(payload))")
        @unknown default:
            throw CaptureError.websocketClosed
        }
    }

    try capture.write(to: captureURL, options: .atomic)
    try sidecar.write(to: sidecarURL, options: .atomic)

    print("Capture complete: messages=\(messageIndex) binary=\(binaryMessages) text=\(textMessages) payload_bytes=\(payloadBytes)")
}

var exitCode: Int32 = 0
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        try await runCapture()
    } catch {
        fputs("error: \(error)\n\n\(usage())\n", stderr)
        exitCode = 1
    }
    semaphore.signal()
}
semaphore.wait()

if exitCode != 0 {
    exit(exitCode)
}
