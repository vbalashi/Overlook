import Foundation
import Network
import Combine
import CryptoKit
import SystemConfiguration

@MainActor
final class KVMDeviceManager: NSObject, ObservableObject {
    @Published var availableDevices: [KVMDevice] = []
    @Published var connectedDevice: KVMDevice?
    @Published var glkvmClient: GLKVMClient?
    @Published var isScanning = false
    @Published var scanProgress: Double = 0.0
    @Published var autoScanEnabled: Bool = false
    
    private var networkMonitor: NWPathMonitor?
    private var scanTimer: Timer?
    private var deviceDiscoverySessions: [NWBrowser] = []

    private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config, delegate: InsecureTLSDelegate(), delegateQueue: nil)
    }()

    private static let savedDevicesKey = "overlook.saved_devices.v1"
    private static let lastConnectedDeviceKey = "overlook.lastConnectedDevice.v1"
    private static let sharedDefaults = UserDefaults(suiteName: "com.overlook.app") ?? .standard

    var lastConnectedDevice: KVMDevice? {
        guard let savedId = Self.sharedDefaults.string(forKey: Self.lastConnectedDeviceKey) else { return nil }
        return availableDevices.first { $0.id == savedId }
    }

    private struct PersistedDevice: Codable, Hashable {
        let host: String
        let port: Int
        let name: String
        let type: KVMDeviceType
        let authToken: String
        let capabilities: Set<KVMCapability>
    }
    
    override init() {
        super.init()
        Self.raiseOpenFileLimit()
        setupNetworkMonitoring()
        loadPersistedDevices()
    }

    private static func raiseOpenFileLimit() {
        // macOS default soft limit is 256. With concurrent scan probes plus
        // URLSession's own connections we hit EMFILE and probes silently fail.
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let desired: rlim_t = 4096
        if limit.rlim_cur >= desired { return }
        limit.rlim_cur = min(desired, limit.rlim_max)
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            OverlookLog.info("NWPath status=\(path.status) unsatisfiedReason=\(String(describing: path.unsatisfiedReason)) interfaces=\(path.availableInterfaces.map { $0.name }.joined(separator: ","))")
            Task { @MainActor in
                if path.status == .satisfied, self?.autoScanEnabled == true {
                    self?.scanForDevices()
                }
            }
        }
        
        let queue = DispatchQueue(label: "com.overlook.network")
        networkMonitor?.start(queue: queue)
    }
    
    func scanForDevices() {
        guard !isScanning else { return }
        
        isScanning = true
        scanProgress = 0.0
        let startedAt = Date()
        let pinnedDevices = availableDevices.filter { $0.id.hasPrefix("manual-") || $0.id.hasPrefix("saved-") }
        availableDevices = pinnedDevices
        OverlookLog.info("scan start pinned=\(pinnedDevices.count)")
        
        Task {
            await withTaskGroup(of: [KVMDevice].self) { group in
                group.addTask {
                    await self.discoverGLiNetDevices()
                }
                
                group.addTask {
                    await self.discoverGenericKVMDevices()
                }
                
                group.addTask {
                    await self.scanKnownPorts()
                }

                group.addTask {
                    await self.discoverTailscaleDevices()
                }
                
                var allDevices: [KVMDevice] = []
                let pinnedDevices = await MainActor.run {
                    self.availableDevices.filter { $0.id.hasPrefix("manual-") || $0.id.hasPrefix("saved-") }
                }

                for await devices in group {
                    OverlookLog.info("scan branch returned count=\(devices.count) devices=\(devices.map { "\($0.name)|\($0.host):\($0.port)" }.joined(separator: ","))")
                    allDevices.append(contentsOf: devices)

                    let uniqueDevices = self.removeDuplicates(from: allDevices)
                    await MainActor.run {
                        let combined = self.removeDuplicates(from: pinnedDevices + uniqueDevices)
                        self.availableDevices = combined.sorted { $0.name < $1.name }
                    }
                }

                await MainActor.run {
                    self.isScanning = false
                    self.scanProgress = 1.0
                    self.scanTimer?.invalidate()
                    self.scanTimer = nil
                    OverlookLog.info("scan complete devices=\(self.availableDevices.count) durationMs=\(Self.elapsedMilliseconds(since: startedAt))")
                }
            }
        }
        
        // Update progress
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if self.scanProgress < 0.9 {
                    self.scanProgress += 0.05
                }
            }
        }
    }
    
    private func discoverGLiNetDevices() async -> [KVMDevice] {
        actor DeviceCollector {
            private var devices: [KVMDevice] = []
            func add(_ device: KVMDevice) {
                devices.append(device)
            }
            func all() -> [KVMDevice] {
                devices
            }
        }

        let collector = DeviceCollector()
        
        // GL.iNet Comet uses mDNS/Bonjour discovery
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_comet._tcp", domain: nil), using: .tcp)
        
        return await withCheckedContinuation { continuation in
            browser.browseResultsChangedHandler = { results, changes in
                for result in results {
                    let device = Self.createGLiNetDevice(from: result.endpoint)
                    Task {
                        await collector.add(device)
                    }
                }
            }
            
            browser.start(queue: DispatchQueue(label: "com.overlook.glinet"))
            
            // Stop after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task {
                    let devices = await collector.all()
                    browser.cancel()
                    continuation.resume(returning: devices)
                }
            }
        }
    }
    
    nonisolated private static func createGLiNetDevice(from endpoint: NWEndpoint) -> KVMDevice {
        var name = "GL.iNet Comet"
        var host = ""
        let port = 443
        
        if case .service(let serviceName, let type, let domain, _) = endpoint {
            name = serviceName
            host = "\(serviceName).\(type).\(domain)"
        }
        
        return KVMDevice(
            id: "glinet-\(UUID().uuidString)",
            name: name,
            host: host,
            port: port,
            type: .glinetComet,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
        )
    }
    
    private func discoverGenericKVMDevices() async -> [KVMDevice] {
        actor DeviceCollector {
            private var devices: [KVMDevice] = []
            func add(_ device: KVMDevice) {
                devices.append(device)
            }
            func all() -> [KVMDevice] {
                devices
            }
        }

        let collector = DeviceCollector()
        
        // Generic KVM discovery via mDNS
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_kvm._tcp", domain: nil), using: .tcp)
        
        return await withCheckedContinuation { continuation in
            browser.browseResultsChangedHandler = { results, changes in
                for result in results {
                    let device = Self.createGenericKVMDevice(from: result.endpoint)
                    Task {
                        await collector.add(device)
                    }
                }
            }
            
            browser.start(queue: DispatchQueue(label: "com.overlook.generic"))
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task {
                    let devices = await collector.all()
                    browser.cancel()
                    continuation.resume(returning: devices)
                }
            }
        }
    }
    
    nonisolated private static func createGenericKVMDevice(from endpoint: NWEndpoint) -> KVMDevice {
        var name = "Generic KVM"
        var host = ""
        let port = 8080
        
        if case .service(let serviceName, let type, let domain, _) = endpoint {
            name = serviceName
            host = "\(serviceName).\(type).\(domain)"
        }
        
        return KVMDevice(
            id: "generic-\(UUID().uuidString)",
            name: name,
            host: host,
            port: port,
            type: .generic,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
    }
    
    private func scanKnownPorts() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        
        let knownPorts = [443, 8443, 80, 8080]
        let localNetwork = getLocalNetworkRange()
        let scanPrefixes = Set(localNetwork.compactMap { Self.ipv4Prefix(for: $0) })
        let arpHosts = Self.arpHosts(matching: scanPrefixes)
        let arpHostSet = Set(arpHosts)
        let orderedHosts = arpHosts + localNetwork.filter { !arpHostSet.contains($0) }

        let maxConcurrent = 64
        var targets: [(host: String, port: Int)] = []
        targets.reserveCapacity(orderedHosts.count * knownPorts.count)
        for host in orderedHosts {
            for port in knownPorts {
                targets.append((host: host, port: port))
            }
        }
        OverlookLog.info("scan known-ports hosts=\(localNetwork.count) arpHosts=\(arpHosts.joined(separator: ",")) targets=\(targets.count) maxConcurrent=\(maxConcurrent)")
        
        await withTaskGroup(of: KVMDevice?.self) { group in
            var nextIndex = 0
            var inFlight = 0

            while nextIndex < targets.count || inFlight > 0 {
                while inFlight < maxConcurrent && nextIndex < targets.count {
                    let target = targets[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        await self.checkKVMService(host: target.host, port: target.port)
                    }
                }

                if let device = await group.next() {
                    inFlight -= 1
                    if let device {
                        devices.append(device)
                        OverlookLog.info("scan found \(device.name) host=\(device.host) port=\(device.port)")
                    }
                }
            }
        }

        let foundKeys = Set(devices.map { "\($0.host):\($0.port)" })
        let currentARPHosts = Self.arpHosts(matching: scanPrefixes)
        let fallbackDevices = await scanARPResolvedHosts(
            hosts: currentARPHosts,
            ports: [443, 80],
            excluding: foundKeys
        )
        devices.append(contentsOf: fallbackDevices)
        
        OverlookLog.info("scan known-ports complete found=\(devices.count)")
        return devices
    }

    private func scanARPResolvedHosts(hosts: [String], ports: [Int], excluding existingKeys: Set<String>) async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        let targets = hosts.flatMap { host in
            ports.map { port in (host: host, port: port) }
        }.filter { !existingKeys.contains("\($0.host):\($0.port)") }

        guard !targets.isEmpty else { return [] }
        OverlookLog.info("scan arp-fallback hosts=\(hosts.joined(separator: ",")) targets=\(targets.count)")

        await withTaskGroup(of: KVMDevice?.self) { group in
            for target in targets {
                group.addTask {
                    await self.checkARPFallbackService(host: target.host, port: target.port)
                }
            }

            for await device in group {
                if let device {
                    devices.append(device)
                    OverlookLog.info("scan arp-fallback found \(device.name) host=\(device.host) port=\(device.port)")
                }
            }
        }

        return devices
    }

    private func checkARPFallbackService(host: String, port: Int) async -> KVMDevice? {
        guard await probeGLKVMQuick(host: host, port: port) else { return nil }
        OverlookLog.info("scan glkvm-match source=arp-fallback host=\(host) port=\(port)")
        return KVMDevice(
            id: "scanned-\(host)-\(port)",
            name: "GLKVM @ \(host):\(port)",
            host: host,
            port: port,
            type: .glinetComet,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
        )
    }
    
    private func getLocalNetworkRange() -> [String] {
        var prefixes: Set<String> = []
        var hosts: [String] = []
        var includedInterfaces: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }

            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let p = ptr {
                defer { ptr = p.pointee.ifa_next }
                guard let addr = p.pointee.ifa_addr else { continue }
                if addr.pointee.sa_family != UInt8(AF_INET) { continue }

                let name = String(cString: p.pointee.ifa_name)
                let flags = Int32(p.pointee.ifa_flags)
                if (flags & IFF_LOOPBACK) != 0 { continue }
                if (flags & IFF_POINTOPOINT) != 0 { continue }
                if (flags & IFF_UP) == 0 || (flags & IFF_RUNNING) == 0 { continue }
                if Self.isVirtualOrApplePeerInterface(name) { continue }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result != 0 { continue }
                let ip = String(cString: hostname)

                let parts = ip.split(separator: ".")
                guard parts.count == 4 else { continue }

                // Only scan typical private IPv4 ranges.
                let p0 = Int(parts[0]) ?? 0
                let p1 = Int(parts[1]) ?? 0
                let isPrivate = (p0 == 10) || (p0 == 192 && p1 == 168) || (p0 == 172 && (16...31).contains(p1))
                guard isPrivate else { continue }

                // Pragmatic /24 scan based on the interface IP.
                prefixes.insert("\(parts[0]).\(parts[1]).\(parts[2])")
                includedInterfaces.append("\(name)=\(ip)")
            }
        }

        if prefixes.isEmpty, let primary = primaryRouteIPv4Prefix() {
            prefixes.insert(primary)
        }

        if prefixes.isEmpty {
            prefixes = [
                "192.168.1",
                "192.168.0",
                "10.0.0",
            ]
        }

        let sortedPrefixes = prefixes.sorted()
        OverlookLog.info("scan prefixes=\(sortedPrefixes.joined(separator: ",")) interfaces=\(includedInterfaces.joined(separator: ","))")
        NSLog("[Overlook scan] scanning prefixes: \(sortedPrefixes)")

        for prefix in sortedPrefixes {
            for i in 1...254 {
                hosts.append("\(prefix).\(i)")
            }
        }

        return hosts
    }

    nonisolated private static func isVirtualOrApplePeerInterface(_ name: String) -> Bool {
        let skippedPrefixes = [
            "anpi",
            "ap",
            "awdl",
            "bridge",
            "gif",
            "llw",
            "lo",
            "stf",
            "utun",
            "vmenet",
        ]
        return skippedPrefixes.contains { name.hasPrefix($0) }
    }

    nonisolated private static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    nonisolated private static func ipv4Prefix(for host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    nonisolated private static func arpHosts(matching prefixes: Set<String>) -> [String] {
        guard !prefixes.isEmpty else { return [] }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-an"]

        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            OverlookLog.error("scan arp failed to launch error=\(OverlookLog.describe(error))")
            return []
        }

        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            OverlookLog.error("scan arp exited status=\(task.terminationStatus)")
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        var hosts: Set<String> = []

        for line in text.split(separator: "\n") {
            if line.contains("(incomplete)") { continue }
            guard let open = line.firstIndex(of: "("),
                  let close = line[line.index(after: open)...].firstIndex(of: ")") else {
                continue
            }

            let host = String(line[line.index(after: open)..<close])
            guard let prefix = ipv4Prefix(for: host), prefixes.contains(prefix) else { continue }
            if host.hasSuffix(".0") || host.hasSuffix(".255") { continue }
            hosts.insert(host)
        }

        return hosts.sorted(by: compareIPv4)
    }

    nonisolated private static func compareIPv4(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        guard left.count == 4, right.count == 4 else { return lhs < rhs }
        return zip(left, right).first { $0 != $1 }.map { $0 < $1 } ?? false
    }

    private func primaryRouteIPv4Prefix() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "com.overlook.scan" as CFString, nil, nil) else {
            return nil
        }
        guard let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primaryInterface = global["PrimaryInterface"] as? String else {
            return nil
        }
        let key = "State:/Network/Interface/\(primaryInterface)/IPv4" as CFString
        guard let ipv4 = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let addresses = ipv4["Addresses"] as? [String],
              let first = addresses.first else {
            return nil
        }
        let parts = first.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let p0 = Int(parts[0]) ?? 0
        let p1 = Int(parts[1]) ?? 0
        let isPrivate = (p0 == 10) || (p0 == 192 && p1 == 168) || (p0 == 172 && (16...31).contains(p1))
        guard isPrivate else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    private func probeTCPPortOpen(host: String, port: Int) async -> Bool {
        // Raw POSIX socket connect — NWConnection emits ~4 [connection] os_log
        // lines per failed probe and there's no way to silence them. With a
        // /24 subnet × 4 ports that's thousands of log entries per scan.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.rawTCPConnect(host: host, port: port, timeoutMs: 700))
            }
        }
    }

    nonisolated private static func rawTCPConnect(host: String, port: Int, timeoutMs: Int32) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        guard flags >= 0, fcntl(sock, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let ready = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, timeoutMs) }
        guard ready > 0 else { return false }

        let badFlags = Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)
        if (pfd.revents & badFlags) != 0 { return false }
        if (pfd.revents & Int16(POLLOUT)) == 0 { return false }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
    }
    
    private func checkKVMService(
        host: String,
        port: Int,
        requiresTCPProbe: Bool = true,
        source: String = "tcp-scan"
    ) async -> KVMDevice? {
        if requiresTCPProbe {
            guard await probeTCPPortOpen(host: host, port: port) else {
                return nil
            }
            OverlookLog.info("scan tcp-open host=\(host) port=\(port)")
        } else {
            OverlookLog.info("scan direct-http source=\(source) host=\(host) port=\(port)")
        }

        if await probeGLKVM(host: host, port: port, logFailures: !requiresTCPProbe) {
            OverlookLog.info("scan glkvm-match source=\(source) host=\(host) port=\(port)")
            return KVMDevice(
                id: "scanned-\(host)-\(port)",
                name: "GLKVM @ \(host):\(port)",
                host: host,
                port: port,
                type: .glinetComet,
                authToken: "",
                capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
            )
        }

        if await probeWebUIKeywords(host: host, port: port) {
            OverlookLog.info("scan webui-match source=\(source) host=\(host) port=\(port)")
            return KVMDevice(
                id: "scanned-\(host)-\(port)",
                name: "KVM @ \(host):\(port)",
                host: host,
                port: port,
                type: .generic,
                authToken: "",
                capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
            )
        }

        return nil
    }

    private func probeGLKVM(host: String, port: Int, logFailures: Bool = false) async -> Bool {
        let preferredSchemes: [String] = (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]

        let paths = [
            "api/auth/check",
            "api/init/is_inited",
        ]

        for scheme in preferredSchemes {
            for path in paths {
                guard let url = URL(string: "\(scheme)://\(host):\(port)/\(path)") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 3

                do {
                    let (data, response) = try await probeSession.data(for: request)
                    guard let http = response as? HTTPURLResponse else { continue }

                    if isPlausibleGLKVMProbeResponse(data: data, response: http) {
                        return true
                    } else {
                        if logFailures {
                            OverlookLog.info("scan glkvm-status host=\(host) port=\(port) status=\(http.statusCode) url=\(OverlookLog.redactedURL(url))")
                        }
                        continue
                    }
                } catch {
                    if logFailures {
                        OverlookLog.error("scan glkvm-error host=\(host) port=\(port) url=\(OverlookLog.redactedURL(url)) error=\(OverlookLog.describe(error))")
                    }
                    continue
                }
            }
        }

        return false
    }

    private func probeGLKVMQuick(host: String, port: Int) async -> Bool {
        let scheme = (port == 443 || port == 8443) ? "https" : "http"
        let paths = [
            "api/auth/check",
            "api/init/is_inited",
        ]

        for path in paths {
            guard let url = URL(string: "\(scheme)://\(host):\(port)/\(path)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 1

            do {
                let (data, response) = try await probeSession.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if isPlausibleGLKVMProbeResponse(data: data, response: http) {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }

    private func isPlausibleGLKVMProbeResponse(data: Data, response: HTTPURLResponse) -> Bool {
        switch response.statusCode {
        case 401, 403:
            return true
        case 301, 302, 307, 308:
            guard let location = response.value(forHTTPHeaderField: "Location")?.lowercased() else {
                return false
            }
            return location.contains("/api/auth/check") || location.contains("/api/init/is_inited")
        case 200:
            guard !data.isEmpty else { return false }
            let text = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
            return text.contains("\"ok\"")
                || text.contains("\"result\"")
                || text.contains("gl-kvm")
                || text.contains("glkvm")
                || text.contains("comet")
        default:
            return false
        }
    }

    private func probeWebUIKeywords(host: String, port: Int) async -> Bool {
        let preferredSchemes: [String] = (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]

        for scheme in preferredSchemes {
            guard let url = URL(string: "\(scheme)://\(host):\(port)/") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 2

            do {
                let (data, response) = try await probeSession.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200...399).contains(http.statusCode) else { continue }
                let text = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()

                if text.contains("kvmd") || text.contains("glkvm") || text.contains("comet") || text.contains("kvm") {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }
    
    private func discoverTailscaleDevices() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        
        // Check if Tailscale is available and discover devices on Tailscale network
        let tailscaleHosts = await getTailscaleHosts()
        
        for host in tailscaleHosts {
            if let device = await checkTailscaleKVM(host: host) {
                devices.append(device)
            }
        }
        
        return devices
    }
    
    private func getTailscaleHosts() async -> [String] {
        // Get Tailscale network hosts
        // This would typically involve calling tailscale API or parsing status output
        return []
    }
    
    private func checkTailscaleKVM(host: String) async -> KVMDevice? {
        // Check common KVM ports on Tailscale hosts
        let ports = [8443, 8080, 443]
        
        for port in ports {
            if let device = await checkKVMService(host: host, port: port) {
                var tailscaleDevice = device
                tailscaleDevice.type = .tailscale
                tailscaleDevice.name = "\(device.name) (Tailscale)"
                return tailscaleDevice
            }
        }
        
        return nil
    }
    
    private func removeDuplicates(from devices: [KVMDevice]) -> [KVMDevice] {
        // Pinned (manual/saved) entries always appear with their exact host:port.
        // Discovered entries collapse per host so HTTP redirects and HTTPS
        // endpoints for the same GLKVM do not show up as separate devices.
        func portRank(_ port: Int) -> Int {
            switch port {
            case 443: return 0
            case 8443: return 1
            case 80: return 2
            case 8080: return 3
            default: return 4
            }
        }

        var pinned: [KVMDevice] = []
        var pinnedKeys: Set<String> = []
        var bestDiscoveredPerHost: [String: KVMDevice] = [:]
        var pinnedHostPorts: [String: Set<Int>] = [:]

        for device in devices {
            let isPinned = device.id.hasPrefix("manual-") || device.id.hasPrefix("saved-")
            let key = "\(device.host):\(device.port)"
            if isPinned {
                if pinnedKeys.insert(key).inserted {
                    pinned.append(device)
                    pinnedHostPorts[device.host, default: []].insert(device.port)
                }
            } else {
                if let existing = bestDiscoveredPerHost[device.host] {
                    if portRank(device.port) < portRank(existing.port) {
                        bestDiscoveredPerHost[device.host] = device
                    }
                } else {
                    bestDiscoveredPerHost[device.host] = device
                }
            }
        }

        var result = pinned
        for device in bestDiscoveredPerHost.values {
            let key = "\(device.host):\(device.port)"
            if pinnedKeys.contains(key) { continue }
            // Also skip a discovered entry if a pinned entry for the same host
            // exists on a better-ranked port (saved :443 hides discovered :80).
            if let pinnedPorts = pinnedHostPorts[device.host],
               pinnedPorts.contains(where: { portRank($0) <= portRank(device.port) }) {
                continue
            }
            result.append(device)
        }

        return result
    }
    
    @discardableResult
    func addManualDevice(host: String, port: Int, type: KVMDeviceType, authToken: String = "") -> KVMDevice {
        let device = KVMDevice(
            id: "manual-\(UUID().uuidString)",
            name: "Manual KVM @ \(host):\(port)",
            host: host,
            port: port,
            type: type,
            authToken: authToken,
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
        
        availableDevices.append(device)
        return device
    }
    
    func removeDevice(_ device: KVMDevice) {
        availableDevices.removeAll { $0.id == device.id }
        
        if connectedDevice?.id == device.id {
            connectedDevice = nil
        }
    }

    func forgetDevice(_ device: KVMDevice) {
        let host = device.host
        let port = device.port

        var current = readPersistedDevices()
        current.removeAll { $0.host == host && $0.port == port }
        writePersistedDevices(current)

        availableDevices.removeAll { $0.host == host && $0.port == port }
        if connectedDevice?.host == host, connectedDevice?.port == port {
            connectedDevice = nil
            glkvmClient = nil
        }
    }
    
    @discardableResult
    func connectToDevice(_ device: KVMDevice, authToken: String? = nil, password: String? = nil, user: String = "admin") async throws -> KVMDevice {
        OverlookLog.info("KVMDeviceManager connect start host=\(device.host) port=\(device.port) type=\(device.type.rawValue) tokenLen=\(device.authToken.count) suppliedToken=\((authToken?.isEmpty == false)) passwordProvided=\((password?.isEmpty == false))")

        // Treat the raw TCP probe as advisory only. It can false-negative in
        // optimized/hardened builds, while the real GLKVM HTTP request below
        // still succeeds and gives us better errors when it does not.
        do {
            let isValid = try await validateDeviceConnection(device)
            if isValid == false {
                OverlookLog.error("TCP probe failed host=\(device.host) port=\(device.port); trying GLKVM API anyway")
                NSLog("[Overlook connect] TCP probe failed for %@:%d; trying GLKVM API anyway", device.host, device.port)
            } else {
                OverlookLog.info("TCP probe succeeded host=\(device.host) port=\(device.port)")
            }
        } catch {
            OverlookLog.error("TCP probe threw host=\(device.host) port=\(device.port) error=\(OverlookLog.describe(error)); trying GLKVM API anyway")
            NSLog("[Overlook connect] TCP probe threw for %@:%d: %@; trying GLKVM API anyway", device.host, device.port, "\(error)")
        }
        
        // Update device auth token if provided
        var finalDevice: KVMDevice
        if let token = authToken {
            var updatedDevice = device
            updatedDevice.authToken = token

            // Update in available devices
            if let index = availableDevices.firstIndex(where: { $0.id == device.id }) {
                availableDevices[index] = updatedDevice
            }

            finalDevice = updatedDevice
        } else {
            finalDevice = device
        }

        guard let client = try? GLKVMClient(device: finalDevice, allowInsecureTLS: true) else {
            OverlookLog.error("GLKVMClient init failed host=\(finalDevice.host) port=\(finalDevice.port)")
            throw KVMError.connectionFailed
        }
        OverlookLog.info("GLKVMClient ready baseURL=\(client.baseURL.absoluteString) tokenLen=\(finalDevice.authToken.count)")
        NSLog("[Overlook connect] %@:%d baseURL=%@ tokenLen=%d", finalDevice.host, finalDevice.port, client.baseURL.absoluteString, finalDevice.authToken.count)

        do {
            OverlookLog.info("authCheck start host=\(finalDevice.host) port=\(finalDevice.port)")
            try await client.authCheck()
            OverlookLog.info("authCheck OK host=\(finalDevice.host) port=\(finalDevice.port)")
            NSLog("[Overlook connect] authCheck OK")
        } catch {
            OverlookLog.error("authCheck threw host=\(finalDevice.host) port=\(finalDevice.port) error=\(OverlookLog.describe(error))")
            NSLog("[Overlook connect] authCheck threw: %@", "\(error)")
            if let password, !password.isEmpty {
                do {
                    OverlookLog.info("authLogin start host=\(finalDevice.host) port=\(finalDevice.port) user=\(user) passwordLength=\(password.count)")
                    let token = try await client.authLogin(user: user, password: password)
                    var updated = finalDevice
                    if let token, !token.isEmpty {
                        client.authToken = token
                        updated.authToken = token
                        if let index = availableDevices.firstIndex(where: { $0.id == updated.id }) {
                            availableDevices[index] = updated
                        }
                    }
                    finalDevice = updated
                    OverlookLog.info("authLogin OK host=\(finalDevice.host) port=\(finalDevice.port) tokenLen=\(token?.count ?? 0)")
                    NSLog("[Overlook connect] authLogin OK")
                } catch {
                    OverlookLog.error("authLogin threw host=\(finalDevice.host) port=\(finalDevice.port) error=\(OverlookLog.describe(error))")
                    NSLog("[Overlook connect] authLogin threw: %@", "\(error)")
                    throw error
                }
            } else {
                OverlookLog.info("authCheck failed and no password provided; requesting password host=\(finalDevice.host) port=\(finalDevice.port)")
                throw KVMError.authenticationFailed
            }
        }

        let persisted = persistDevice(finalDevice)
        connectedDevice = persisted
        glkvmClient = client
        Self.sharedDefaults.set(persisted.id, forKey: Self.lastConnectedDeviceKey)
        OverlookLog.info("KVMDeviceManager connect complete host=\(persisted.host) port=\(persisted.port) savedId=\(persisted.id)")
        return persisted
    }

    private func persistDevice(_ device: KVMDevice) -> KVMDevice {
        let record = PersistedDevice(
            host: device.host,
            port: device.port,
            name: device.name,
            type: device.type,
            authToken: device.authToken,
            capabilities: device.capabilities
        )

        var current = readPersistedDevices()
        if let index = current.firstIndex(where: { $0.host == device.host && $0.port == device.port }) {
            current[index] = record
        } else {
            current.append(record)
        }
        writePersistedDevices(current)

        var saved = device
        saved.id = savedDeviceId(host: device.host, port: device.port)

        availableDevices.removeAll { $0.host == device.host && $0.port == device.port }
        availableDevices.append(saved)
        availableDevices = removeDuplicates(from: availableDevices).sorted { $0.name < $1.name }
        return saved
    }

    private func loadPersistedDevices() {
        let records = readPersistedDevices()
        guard !records.isEmpty else { return }

        let devices: [KVMDevice] = records.map { record in
            KVMDevice(
                id: savedDeviceId(host: record.host, port: record.port),
                name: record.name,
                host: record.host,
                port: record.port,
                type: record.type,
                authToken: record.authToken,
                capabilities: record.capabilities
            )
        }
        availableDevices = removeDuplicates(from: devices).sorted { $0.name < $1.name }
    }

    private func savedDeviceId(host: String, port: Int) -> String {
        let safeHost = host.replacingOccurrences(of: ":", with: "_")
        return "saved-\(safeHost)-\(port)"
    }

    private func readPersistedDevices() -> [PersistedDevice] {
        guard let data = Self.sharedDefaults.data(forKey: Self.savedDevicesKey)
                ?? UserDefaults.standard.data(forKey: Self.savedDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([PersistedDevice].self, from: data)) ?? []
    }

    private func writePersistedDevices(_ devices: [PersistedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        Self.sharedDefaults.set(data, forKey: Self.savedDevicesKey)
        UserDefaults.standard.set(data, forKey: Self.savedDevicesKey)
    }
    
    private func validateDeviceConnection(_ device: KVMDevice) async throws -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(device.port)) else {
            return false
        }

        final class Flag {
            var value: Bool = false
        }

        let queue = DispatchQueue(label: "com.overlook.validate")
        let connection = NWConnection(host: NWEndpoint.Host(device.host), port: port, using: .tcp)

        return await withCheckedContinuation { continuation in
            let finished = Flag()

            let timeoutWorkItem = DispatchWorkItem {
                if finished.value { return }
                finished.value = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: false)
            }

            queue.asyncAfter(deadline: .now() + 5, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { (state: NWConnection.State) in
                OverlookLog.info("TCP probe state host=\(device.host) port=\(device.port) state=\(state)")
                switch state {
                case .ready:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
    
    func disconnectFromDevice() {
        connectedDevice = nil
        glkvmClient = nil
    }
    
    deinit {
        networkMonitor?.cancel()
        scanTimer?.invalidate()
        deviceDiscoverySessions.forEach { $0.cancel() }
    }
}

// MARK: - KVM Device Model
struct KVMDevice: Identifiable, Codable {
    var id: String
    var name: String
    let host: String
    let port: Int
    var type: KVMDeviceType
    var authToken: String
    let capabilities: Set<KVMCapability>
    
    var connectionString: String {
        return "\(host):\(port)"
    }
    
    var webRTCURL: String {
        let scheme = (port == 80 || port == 8080) ? "ws" : "wss"
        return "\(scheme)://\(host):\(port)/janus/ws"
    }
}

extension KVMDevice: Hashable {
    static func == (lhs: KVMDevice, rhs: KVMDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum KVMDeviceType: String, Codable, CaseIterable {
    case glinetComet = "glinet_comet"
    case generic = "generic"
    case tailscale = "tailscale"
    case custom = "custom"
    
    var displayName: String {
        switch self {
        case .glinetComet:
            return "GL.iNet Comet"
        case .generic:
            return "Generic KVM"
        case .tailscale:
            return "Tailscale KVM"
        case .custom:
            return "Custom KVM"
        }
    }
}

enum KVMCapability: String, Codable, CaseIterable {
    case videoStreaming = "video_streaming"
    case keyboardInput = "keyboard_input"
    case mouseInput = "mouse_input"
    case virtualMedia = "virtual_media"
    case powerManagement = "power_management"
    case ocrSupport = "ocr_support"
    
    var displayName: String {
        switch self {
        case .videoStreaming:
            return "Video Streaming"
        case .keyboardInput:
            return "Keyboard Input"
        case .mouseInput:
            return "Mouse Input"
        case .virtualMedia:
            return "Virtual Media"
        case .powerManagement:
            return "Power Management"
        case .ocrSupport:
            return "OCR Support"
        }
    }
}

enum KVMError: Error, LocalizedError {
    case deviceNotFound
    case connectionFailed
    case authenticationFailed
    case unsupportedCapability
    case networkUnavailable
    
    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "KVM device not found"
        case .connectionFailed:
            return "Failed to connect to KVM device"
        case .authenticationFailed:
            return "Authentication failed"
        case .unsupportedCapability:
            return "Device does not support this capability"
        case .networkUnavailable:
            return "Network is not available"
        }
    }
}
