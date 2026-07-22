import Foundation

/// Represents errors that occur during Homebrew detection and installation processes.
enum BrewError: Error {
    /// Indicates that the Homebrew binary was not found in the expected system paths.
    case notFound
    /// Indicates that the Homebrew installation script failed to execute successfully.
    case installFailed(String)
}

/// A service responsible for detecting the presence of Homebrew and orchestrating its installation.
///
/// `BrewService` abstracts the detection logic and delegates the actual installation execution
/// to the `PrivilegesService` for secure, authenticated bash script execution.
///
/// ```swift
/// let service = BrewService(logger: logger, privileges: privileges)
/// do {
///     try await service.detectHomebrew()
/// } catch {
///     try await service.installHomebrew()
/// }
/// ```
final class BrewService {
    private let logger: Logger
    private let privileges: PrivilegesService
    
    /// Initializes a new instance of the service.
    ///
    /// - Parameters:
    ///   - logger: The `Logger` instance used to record application state.
    ///   - privileges: The `PrivilegesService` instance utilized to elevate and run shell commands.
    init(logger: Logger, privileges: PrivilegesService) {
        self.logger = logger
        self.privileges = privileges
    }
    
    /// Detects if Homebrew is currently installed on the user's base operating system.
    ///
    /// **Gotchas:**
    /// Relies on ``BrewPathManager/isInstalled`` rather than executing shell commands directly, ensuring synchronous and safe evaluation.
    ///
    /// - Throws: A `BrewError.notFound` exception if the Homebrew binary path is unresolved.
    func detectHomebrew() async throws {
        logger.log("🔍 Detecting Homebrew...")
        
        if BrewPathManager.shared.isInstalled {
            logger.log("✅ Homebrew found at: \(BrewPathManager.shared.brewPath)")
            return
        }
        
        logger.log("❌ Homebrew not found")
        throw BrewError.notFound
    }
    
    /// Initiates a Homebrew installation by launching an authenticated terminal script session.
    ///
    /// **Flow:**
    /// 1. Delegates to ``PrivilegesService/installHomebrew(onOutput:)``.
    /// 2. Relays streamed output to the centralized `logger`.
    /// 3. Injects an artificial 2-second delay post-installation to allow the filesystem to sync before subsequent logic fires.
    ///
    /// - Throws: An error if the installation script fails, gets cancelled, or encounters a privilege error.
    func installHomebrew() async throws {
        logger.log("📦 Starting Homebrew installation via osascript...")
        
        try await privileges.installHomebrew { line in
            self.logger.log("[brew-install] \(line)")
        }
        
        try await Task.sleep(for: .seconds(2))
        
        logger.log("✅ Homebrew installation complete")
    }
}
