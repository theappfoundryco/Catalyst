import Foundation
import Network
import SwiftUI
import Combine

/// A classification enumerating explicit states measuring external accessibility connectivity constraints.
enum ConnectionStatus: Equatable {
    /// Actively connected to the remote API.
    case connected
    /// Undergoing active retry operations attempting restoration bounds.
    case reconnecting
    /// Incapacitated infrastructure or routing blocking resolution vectors.
    case offline
    /// Presently diagnosing or authenticating verification thresholds.
    case checking
    
    /// The standardized UI chromatic identifier reflecting resolution states.
    var color: Color {
        switch self {
        case .connected: return .green
        case .reconnecting: return .yellow
        case .offline: return .red
        case .checking: return .gray
        }
    }
    
    /// A human-readable text block signaling immediate evaluation descriptors.
    var label: String {
        switch self {
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting..."
        case .offline: return "Offline"
        case .checking: return "Checking..."
        }
    }
    
    /// The sub-contextual guidance layout defining resolution definitions precisely.
    var tooltip: String {
        switch self {
        case .connected: return "API server is reachable"
        case .reconnecting: return "Attempting to reach API server"
        case .offline: return "Cannot reach API server. Check your internet connection."
        case .checking: return "Verifying connection"
        }
    }
}

/// A primary observability singleton governing automated external API connectivity.
///
/// `NetworkMonitor` periodically verifies connectivity toward application server resources, issuing asynchronous validations
/// maintaining UX synchronicity independent of manual refresh operations.
///
/// ```swift
/// @StateObject private var monitor = NetworkMonitor()
/// // ...
/// if monitor.status == .connected {
///     Text("API is reachable")
/// }
/// ```
@MainActor
final class NetworkMonitor: ObservableObject {
    /// The structural state metric representing resolution success.
    @Published var status: ConnectionStatus = .checking
    /// A boolean verification detailing independent Homebrew integration capabilities.
    @Published var isBrewInstalled: Bool = false
    /// The total count of detected Python versions installed on the system.
    @Published var pythonVersionCount: Int = 0
    /// Any primary long-running task operating asynchronously demanding user visibility constraints.
    @Published var activeBackgroundTask: String? = nil
    
    private var checkTask: Task<Void, Never>?
    private let checkInterval: TimeInterval = 30
    private let logger = Logger.shared
    
    /// Bootstraps native execution threads mapping monitoring cycles.
    ///
    /// **Gotchas:**
    /// Initialization triggers `startMonitoring()` automatically.
    init() {
        startMonitoring()
    }
    
    deinit {
        checkTask?.cancel()
    }
    
    /// Configures execution threads tracking standard monitoring checks cyclically against constant thresholds.
    ///
    /// **Flow:**
    /// Loops continuously on a detached `Task`, pausing for `checkInterval` (30s) between tests until cancelled.
    func startMonitoring() {
        checkTask?.cancel()
        checkTask = Task {
            await checkConnectivity()
            
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(checkInterval))
                if !Task.isCancelled {
                    await checkConnectivity()
                }
            }
        }
    }
    
    /// Asynchronously signals Cloudflare target pages affirming positive server capabilities over HTTP boundaries.
    /// Assigns `status` only when it actually changes. `@Published` fires
    /// `objectWillChange` on *every* assignment (even equal values), so without
    /// this guard the 30s poll re-rendered the always-visible sidebar each cycle
    /// even when nothing changed (R2).
    ///
    /// - Parameter newValue: The computed state enumeration defining current health.
    private func setStatus(_ newValue: ConnectionStatus) {
        if status != newValue { status = newValue }
    }

    /// Re-evaluates primary network paths using URLSession data tasks.
    ///
    /// **Flow:**
    /// 1. Issues a 10s timeout `GET` to the backend.
    /// 2. If it encounters a 2xx or 3xx HTTP response, flags as `.connected`.
    /// 3. Catches failures, delays for 2s, and triggers `retryConnection()`.
    func checkConnectivity() async {
        if status != .connected {
            setStatus(.checking)
        }

        let apiURL = NetworkConfig.APIEndpoint.healthURL
        guard let url = URL(string: apiURL) else {
            setStatus(.offline)
            return
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               (200...399).contains(httpResponse.statusCode) {
                setStatus(.connected)
            } else {
                if status != .offline {
                    logger.log("🌐 Network check: Server error")
                }
                setStatus(.offline)
            }
        } catch {
            if status == .connected {
                setStatus(.reconnecting)
                logger.log("🌐 Network check: Reconnecting...")

                try? await Task.sleep(for: .seconds(2))
                await retryConnection()
            } else {
                if status != .offline {
                    logger.log("🌐 Network check: Offline - \(error.localizedDescription)")
                }
                setStatus(.offline)
            }
        }
    }
    
    /// A secondary, shorter-timeout fallback probe triggered when the primary connection stalls.
    private func retryConnection() async {
        let apiURL = NetworkConfig.APIEndpoint.healthURL
        guard let url = URL(string: apiURL) else {
            status = .offline
            return
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 5
            
            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               (200...399).contains(httpResponse.statusCode) {
                setStatus(.connected)
            } else {
                setStatus(.offline)
            }
        } catch {
            setStatus(.offline)
        }
    }
    
    /// Updates the system environment status metrics based on local configuration checks.
    ///
    /// - Parameters:
    ///   - brewInstalled: A boolean indicating whether Homebrew is installed.
    ///   - pythonCount: The total number of valid Python versions discovered locally.
    func updateSystemStatus(brewInstalled: Bool, pythonCount: Int) {
        if isBrewInstalled != brewInstalled { isBrewInstalled = brewInstalled }
        if pythonVersionCount != pythonCount { pythonVersionCount = pythonCount }
    }
    
    /// Sets the label for a long-running background task to display in the UI.
    ///
    /// - Parameter task: An optional string describing the active task.
    func setBackgroundTask(_ task: String?) {
        activeBackgroundTask = task
    }
    
    /// Commands a non-cached evaluation testing external connectivity pathways.
    func forceCheck() async {
        await checkConnectivity()
    }
}
