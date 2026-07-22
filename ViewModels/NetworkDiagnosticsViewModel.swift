import Foundation
import SwiftUI
import Combine

/// A view model governing the Network Diagnostics toolkit.
///
/// It aggregates a `NetworkDiagnosticsReport` containing open ports and external ping/dns
/// results via the `NetworkDiagnosticsService`.
///
/// ```swift
/// @StateObject var vm = NetworkDiagnosticsViewModel()
/// await vm.run()
/// ```
@MainActor
final class NetworkDiagnosticsViewModel: ObservableObject {
    /// The execution lifecycle of the diagnostic run.
    enum State: Equatable {
        case idle
        case running
        case ready
    }

    /// Current execution state.
    @Published var state: State = .idle
    /// The output of the latest diagnostic run.
    @Published var report: NetworkDiagnosticsReport?
    /// The target host to resolve during DNS checks (defaults to `github.com`).
    @Published var dnsHost: String = "github.com"
    /// The target IP/host to ping (defaults to `1.1.1.1`).
    @Published var pingHost: String = "1.1.1.1"

    private let service = NetworkDiagnosticsService.shared
    private let logger = Logger.shared

    /// Triggers a full diagnostic scan across ports, ping, and DNS.
    ///
    /// **Flow:**
    /// 1. Transitions ``state`` to `.running`.
    /// 2. Cleans whitespace from user inputs.
    /// 3. Awaits the bundled ``NetworkDiagnosticsService/runDiagnostics(pingHost:dnsHost:)``.
    /// 4. Pushes the result payload and returns ``state`` to `.ready`.
    func run() async {
        state = .running
        logger.log("🌐 Running network diagnostics…")

        let host = dnsHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = pingHost.trimmingCharacters(in: .whitespacesAndNewlines)

        let newReport = await service.runDiagnostics(
            pingHost: target.isEmpty ? "1.1.1.1" : target,
            dnsHost: host.isEmpty ? "github.com" : host
        )
        self.report = newReport
        self.state = .ready
        logger.log("🌐 Network diagnostics complete — \(newReport.listeningPorts.count) listening port(s), internet \(newReport.internetPing.reachable ? "reachable" : "unreachable")")
    }

    /// Clears results and returns to the `.idle` state.
    func reset() {
        report = nil
        state = .idle
        logger.log("🌐 Network diagnostics reset")
    }
}
