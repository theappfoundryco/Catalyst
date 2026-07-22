import Foundation
import ServiceManagement

/// Manages the lifecycle of the privileged helper daemon and the XPC channel to it.
///
/// With the helper installed (one approval ever, at registration time), the app
/// runs root commands over XPC with **no password prompts at all** — even across
/// launches. Until the helper target is built and this is enabled, the app falls
/// back to `PrivilegesService`'s per-launch password cache.
///
/// See `PrivilegedHelper/README.md` for the Xcode target + signing setup that
/// makes `register()` succeed.
///
/// ```swift
/// let manager = PrivilegedHelperManager.shared
/// if !manager.isInstalled {
///     try manager.install()
/// }
/// let (code, output) = try await manager.runShell("ls -la /var/root")
/// ```
final class PrivilegedHelperManager: @unchecked Sendable {

    static let shared = PrivilegedHelperManager()
    private init() {}

    private let lock = NSLock()
    private var _connection: NSXPCConnection?

    // MARK: - Registration (install / remove the daemon)

    /// Whether the helper daemon is registered and enabled with launchd.
    var isInstalled: Bool {
        let service = SMAppService.daemon(plistName: CatalystHelperConstants.daemonPlistName)
        return service.status == .enabled
    }

    /// Registers the bundled daemon with launchd. The user is asked to approve
    /// once (in System Settings › Login Items) — never again afterward.
    ///
    /// - Throws: Any error raised by `SMAppService` during the registration block.
    func install() throws {
        let service = SMAppService.daemon(plistName: CatalystHelperConstants.daemonPlistName)
        switch service.status {
        case .enabled:
            return
        default:
            try service.register()
        }
    }

    /// Removes the helper daemon.
    ///
    /// - Throws: Any error raised by `SMAppService` during the unregistration sequence.
    func uninstall() throws {
        let service = SMAppService.daemon(plistName: CatalystHelperConstants.daemonPlistName)
        try service.unregister()
        invalidateConnection()
    }

    // MARK: - XPC

    /// - Returns: A dedicated bridging connection mapped to the privileged daemon.
    private func connection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = _connection { return c }
        let c = NSXPCConnection(machServiceName: CatalystHelperConstants.machServiceName,
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: CatalystHelperProtocol.self)
        c.invalidationHandler = { [weak self] in self?.invalidateConnection() }
        c.interruptionHandler = { [weak self] in self?.invalidateConnection() }
        c.resume()
        _connection = c
        return c
    }

    /// Severs the active XPC connection and resets the internal listener proxy.
    private func invalidateConnection() {
        lock.lock(); defer { lock.unlock() }
        _connection = nil
    }

    /// Runs a shell command as root through the helper.
    ///
    /// - Parameter command: The raw string of the command line interface block.
    /// - Returns: A tuple of the termination `exitCode` and the raw `output` string.
    /// - Throws: the XPC error if the helper is unreachable.
    func runShell(_ command: String) async throws -> (exitCode: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let proxy = connection().remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            guard let helper = proxy as? CatalystHelperProtocol else {
                continuation.resume(throwing: PrivilegeError.failed("Helper proxy unavailable"))
                return
            }
            helper.runShell(command) { code, output in
                continuation.resume(returning: (code, output))
            }
        }
    }

    /// The installed helper's reported version (for staleness checks).
    ///
    /// - Returns: The version string, or `nil` if the daemon proxy is disconnected or non-responsive.
    func installedVersion() async -> String? {
        try? await withCheckedThrowingContinuation { continuation in
            let proxy = connection().remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            guard let helper = proxy as? CatalystHelperProtocol else {
                continuation.resume(throwing: PrivilegeError.failed("Helper proxy unavailable"))
                return
            }
            helper.getVersion { version in
                continuation.resume(returning: version)
            }
        }
    }
}
