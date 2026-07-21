import Foundation
import SwiftUI
import Combine

@MainActor
final class NetworkDiagnosticsViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case ready
    }

    @Published var state: State = .idle
    @Published var report: NetworkDiagnosticsReport?
    @Published var dnsHost: String = "github.com"
    @Published var pingHost: String = "1.1.1.1"

    private let service = NetworkDiagnosticsService.shared
    private let logger = Logger.shared

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

    /// Clear results and return to the ready state.
    func reset() {
        report = nil
        state = .idle
        logger.log("🌐 Network diagnostics reset")
    }
}
