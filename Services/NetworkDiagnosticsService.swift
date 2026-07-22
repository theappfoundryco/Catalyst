import Foundation

// MARK: - Result Models

/// Outcome of an ICMP reachability probe to a single host.
struct PingResult: Sendable {
    let host: String
    let reachable: Bool
    /// Average round-trip time in milliseconds, when the host replied.
    let avgLatencyMs: Double?
    /// Percentage of probe packets lost (0…100).
    let packetLossPercent: Double?

    var latencyLabel: String {
        guard let avgLatencyMs else { return "—" }
        return String(format: "%.0f ms", avgLatencyMs)
    }
}

/// Outcome of a forward-DNS lookup plus the resolvers the system is using.
struct DNSResult: Sendable {
    let host: String
    let resolvedIPs: [String]
    /// Wall-clock time for the lookup in milliseconds.
    let queryTimeMs: Double?
    /// The system's configured DNS servers.
    let servers: [String]

    var succeeded: Bool { !resolvedIPs.isEmpty }
    var queryLabel: String {
        guard let queryTimeMs else { return "—" }
        return String(format: "%.0f ms", queryTimeMs)
    }
}

/// A TCP socket currently in the LISTEN state.
struct ListeningPort: Identifiable, Sendable {
    let id = UUID()
    let port: Int
    let proto: String      // "IPv4" / "IPv6"
    let process: String
    let pid: Int
}

/// Active default-route interface and its addressing.
struct NetworkInterfaceInfo: Sendable {
    let interface: String
    let localIP: String
    let gateway: String
}

/// Aggregate snapshot rendered by the Network Diagnostics screen.
struct NetworkDiagnosticsReport: Sendable {
    let scanDate: Date
    let interfaceInfo: NetworkInterfaceInfo?
    let internetPing: PingResult
    let gatewayPing: PingResult?
    let dns: DNSResult
    let listeningPorts: [ListeningPort]
}

/// Runs lightweight, read-only network probes (reachability, DNS, listening
/// sockets, default-route interface) by shelling out to standard macOS tools
/// via the safe array-args exec path. No privileges required.
///
/// ```swift
/// let report = await NetworkDiagnosticsService.shared.runDiagnostics()
/// print(report.internetPing.reachable ? "Online" : "Offline")
/// ```
final class NetworkDiagnosticsService: Sendable {

    static let shared = NetworkDiagnosticsService()
    private init() {}

    private let runner = AsyncProcessRunner.shared

    /// Standard absolute tool paths (avoid PATH ambiguity).
    ///
    /// **Rationale:** Prevents malicious user-space overrides (e.g. `~/bin/ping`) from intercepting privileged diagnostic execution contexts.
    private let pingPath = "/sbin/ping"
    private let digPath = "/usr/bin/dig"
    private let scutilPath = "/usr/sbin/scutil"
    private let lsofPath = "/usr/sbin/lsof"
    private let routePath = "/sbin/route"
    private let ipconfigPath = "/usr/sbin/ipconfig"

    /// Runs all probes concurrently and assembles a full report.
    ///
    /// **Flow:**
    /// 1. Concurrently evaluates route, remote ping, DNS resolution, and TCP listening ports.
    /// 2. If a local gateway is found, initiates a secondary ping specifically for the router.
    ///
    /// - Parameters:
    ///   - pingHost: reachability target (default a public anycast resolver).
    ///   - dnsHost: hostname to resolve.
    /// - Returns: An aggregated `NetworkDiagnosticsReport`.
    func runDiagnostics(pingHost: String = "1.1.1.1", dnsHost: String = "github.com") async -> NetworkDiagnosticsReport {
        async let iface = interfaceInfo()
        async let net = ping(host: pingHost)
        async let dnsRes = resolveDNS(host: dnsHost)
        async let ports = listeningPorts()

        let interfaceInfo = await iface
        /// Ping the gateway too (LAN health) once we know it.
        ///
        /// **Gotchas:** Omitting the gateway probe makes it impossible to distinguish between a severed ISP cable and a dead local Wi-Fi router.
        let gatewayPing: PingResult?
        if let gw = interfaceInfo?.gateway, !gw.isEmpty, gw != "—" {
            gatewayPing = await ping(host: gw)
        } else {
            gatewayPing = nil
        }

        return NetworkDiagnosticsReport(
            scanDate: Date(),
            interfaceInfo: interfaceInfo,
            internetPing: await net,
            gatewayPing: gatewayPing,
            dns: await dnsRes,
            listeningPorts: await ports
        )
    }

    // MARK: - Ping

    /// Executes a standard `/sbin/ping` probe capped at 3 requests with a strict 5-second deadline.
    ///
    /// - Parameter host: The target domain or IP address.
    /// - Returns: A parsed ``PingResult`` structure.
    func ping(host: String) async -> PingResult {
        do {
            /// -c 3 probes, -t 5s deadline, -q quiet (summary only).
            ///
            /// **Rationale:** Enforces strict termination to prevent hanging network threads indefinitely if the routing table is blackholing traffic.
            let result = try await runner.run(
                executable: pingPath,
                arguments: ["-c", "3", "-t", "5", "-q", host],
                timeoutSeconds: 8
            )
            let out = result.stdout + "\n" + result.stderr

            var loss: Double? = nil
            if let r = out.range(of: #"([\d.]+)% packet loss"#, options: .regularExpression) {
                let frag = out[r]
                loss = Double(frag.replacingOccurrences(of: "% packet loss", with: "")
                    .trimmingCharacters(in: .whitespaces))
            }

            var avg: Double? = nil
            /// "round-trip min/avg/max/stddev = 12.3/13.4/14.5/0.8 ms"
            ///
            /// **Gotchas:** Apple's `ping` implementation localizes decimal separators; attempting to parse comma-based European floating points with `Double()` crashes unless sanitized.
            if let eq = out.range(of: "= ", options: .backwards),
               let msRange = out.range(of: " ms") {
                let stats = out[eq.upperBound..<msRange.lowerBound]
                let parts = stats.split(separator: "/")
                if parts.count >= 2 { avg = Double(parts[1]) }
            }

            let reachable = (loss ?? 100) < 100
            return PingResult(host: host, reachable: reachable, avgLatencyMs: avg, packetLossPercent: loss)
        } catch {
            return PingResult(host: host, reachable: false, avgLatencyMs: nil, packetLossPercent: 100)
        }
    }

    // MARK: - DNS

    /// Submits a DNS query using `/usr/bin/dig` to measure lookup times and discover nameservers.
    ///
    /// - Parameter host: The domain to resolve (e.g. `github.com`).
    /// - Returns: The extracted resolution metadata as a ``DNSResult``.
    func resolveDNS(host: String) async -> DNSResult {
        let servers = await dnsServers()
        let start = Date()
        do {
            let result = try await runner.run(
                executable: digPath,
                arguments: ["+short", "+time=2", "+tries=1", host],
                timeoutSeconds: 6
            )
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            let ips = result.stdout
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { looksLikeIP($0) }
            return DNSResult(host: host, resolvedIPs: ips,
                             queryTimeMs: ips.isEmpty ? nil : elapsedMs, servers: servers)
        } catch {
            return DNSResult(host: host, resolvedIPs: [], queryTimeMs: nil, servers: servers)
        }
    }

    /// Resolves the active DNS configuration assigned by the host OS.
    /// - Returns: The active list of DNS servers mapped in system configurations.
    private func dnsServers() async -> [String] {
        do {
            let result = try await runner.run(
                executable: scutilPath, arguments: ["--dns"], timeoutSeconds: 5
            )
            var servers: [String] = []
            for line in result.stdout.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                /// "nameserver[0] : 1.1.1.1"
                ///
                /// **Rationale:** Scutil bypasses traditional `/etc/resolv.conf` mappings, directly querying macOS's dynamic DNS resolver cache for truth.
                if trimmed.hasPrefix("nameserver["), let colon = trimmed.lastIndex(of: ":") {
                    let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if looksLikeIP(value) && !servers.contains(value) { servers.append(value) }
                }
            }
            return servers
        } catch {
            return []
        }
    }

    /// Validates if a given string matches standard IPv4 or IPv6 formatting.
    /// - Parameter s: The candidate raw string payload.
    /// - Returns: True if structural syntax matches IPv4 or IPv6 conventions.
    private func looksLikeIP(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        /// IPv4
        ///
        /// **Gotchas:** IPv4 default routes may intermittently disappear while the interface negotiates DHCP renewals.
        if s.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return true }
        /// IPv6 (loose)
        ///
        /// **Rationale:** Corporate VPNs often intentionally blackhole IPv6 traffic; failing gracefully here prevents false positive "offline" warnings.
        if s.contains(":") && s.range(of: #"^[0-9a-fA-F:]+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - Listening ports

    /// Polls `/usr/sbin/lsof` to discover TCP sockets actively configured in a `LISTEN` state.
    ///
    /// - Returns: Deduplicated, ordered list of ``ListeningPort`` records.
    func listeningPorts() async -> [ListeningPort] {
        do {
            let result = try await runner.run(
                executable: lsofPath,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN"],
                timeoutSeconds: 8
            )
            var ports: [ListeningPort] = []
            var seen = Set<String>()
            for line in result.stdout.components(separatedBy: .newlines) {
                guard line.contains("(LISTEN)") else { continue }
                let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard fields.count >= 5, let pid = Int(fields[1]) else { continue }
                let process = fields[0]
                let proto = fields[4]  // IPv4 / IPv6
                /// Port: token before "(LISTEN)", e.g. "*:3000" or "127.0.0.1:8080" or "[::1]:631".
                ///
                /// **Gotchas:** IPv6 socket representations aggressively embed colons inside brackets; splitting natively on `:` breaks parsing.
                guard let portToken = fields.first(where: { $0.contains(":") && $0.last != ")" }) ?? fields.dropLast().last,
                      let portStr = portToken.split(separator: ":").last,
                      let port = Int(portStr) else { continue }
                let key = "\(port)-\(pid)"
                if seen.contains(key) { continue }
                seen.insert(key)
                ports.append(ListeningPort(port: port, proto: proto, process: process, pid: pid))
            }
            return ports.sorted { $0.port < $1.port }
        } catch {
            return []
        }
    }

    // MARK: - Interface / gateway

    /// Identifies the default route and its bound IPv4 interface using `/sbin/route` and `ipconfig`.
    ///
    /// - Returns: An optional ``NetworkInterfaceInfo`` populated with the gateway mapping.
    func interfaceInfo() async -> NetworkInterfaceInfo? {
        do {
            let route = try await runner.run(
                executable: routePath, arguments: ["-n", "get", "default"], timeoutSeconds: 5
            )
            var gateway = ""
            var iface = ""
            for line in route.stdout.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("gateway:") {
                    gateway = t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
                } else if t.hasPrefix("interface:") {
                    iface = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
            guard !iface.isEmpty else { return nil }

            var localIP = "—"
            let ip = try? await runner.run(
                executable: ipconfigPath, arguments: ["getifaddr", iface], timeoutSeconds: 5
            )
            if let ip, ip.succeeded {
                let trimmed = ip.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { localIP = trimmed }
            }
            return NetworkInterfaceInfo(interface: iface, localIP: localIP,
                                        gateway: gateway.isEmpty ? "—" : gateway)
        } catch {
            return nil
        }
    }
}
