import Foundation
import SwiftUI
import Combine

/// A view model that coordinates NVMe/SMART disk health monitoring.
///
/// It relies heavily on `SSDHealthService` to invoke `smartctl` with elevated privileges,
/// parses the output, and caches it locally so the UI doesn't force re-authentication
/// on every app launch.
///
/// ```swift
/// @StateObject var vm = SSDHealthViewModel(privileges: ...)
/// await vm.checkPrerequisites()
/// await vm.scan()
/// ```
@MainActor
final class SSDHealthViewModel: ObservableObject {
    // MARK: - Published State
    
    /// The execution lifecycle state (checking deps, scanning, error).
    @Published var setupState: SSDSetupState = .checking
    /// The decoded smartctl data model.
    @Published var report: SSDHealthReport?
    /// Raw terminal output collected when installing `smartmontools` (if missing).
    @Published var installationLog: String = ""

    /// A dismissible, non-destructive notice shown above the content (e.g. a
    /// re-scan was cancelled). Unlike `.error`, it never replaces the screen —
    /// the last good report (or the intro scan screen) stays visible beneath it.
    @Published var scanNotice: String?
    
    // MARK: - Dependencies
    
    private let service = SSDHealthService.shared
    private let logger = Logger.shared
    private let privileges: PrivilegesService
    
    // MARK: - Init
    
    init(privileges: PrivilegesService) {
        self.privileges = privileges
        
        // Load cached report immediately
        if let cached = service.loadCachedReport() {
            self.report = cached
        }
    }
    
    // MARK: - Prerequisite Checks
    
    /// Assesses whether `smartctl` (and Homebrew) are installed on the system.
    func checkPrerequisites() async {
        setupState = .checking
        
        // 1. Check Homebrew
        guard BrewPathManager.shared.isInstalled else {
            setupState = .brewMissing
            logger.log("💿 Disk Vitals: Homebrew not installed")
            return
        }
        
        // 2. Check smartmontools
        let hasSmartctl = await service.isSmartctlInstalled()
        if hasSmartctl {
            setupState = .ready
            logger.log("💿 Disk Vitals: Ready to scan")
        } else {
            setupState = .dependencyMissing
            logger.log("💿 Disk Vitals: smartmontools not installed")
        }
    }
    
    // MARK: - Install Dependency
    
    /// Initiates a Homebrew installation of `smartmontools`, streaming logs to the view.
    ///
    /// **Flow:**
    /// 1. Transitions to `.installing` state.
    /// 2. Asks ``SSDHealthService/installSmartmontools`` to run the brew command.
    /// 3. Re-runs ``checkPrerequisites()`` to confirm availability.
    func installDependency() async {
        setupState = .installing
        installationLog = ""
        // Clear any previous results to avoid confusion
        self.report = nil
        
        logger.log("💿 Installing diagnostic dependency...")
        
        let success = await service.installSmartmontools { [weak self] text in
            self?.installationLog += text
        }
        
        if success {
            logger.log("✅ Diagnostic dependency installed successfully")
            // Re-verify prerequisites to ensure everything is effectively ready
            await checkPrerequisites() 
        } else {
            logger.log("❌ Failed to install diagnostic dependency")
            setupState = .error("Failed to install diagnostic dependency. Check your Homebrew installation.")
        }
    }
    
    // MARK: - Scan
    
    /// Resolves the boot disk name and invokes the privileged `smartctl` sweep.
    ///
    /// **Flow:**
    /// 1. Robustness check: ensures `smartctl` wasn't uninstalled since the view opened.
    /// 2. Scrapes `diskutil` to find the physical boot drive volume.
    /// 3. Hands off to ``SSDHealthService/scan(disk:privileges:)``, throwing a macOS password prompt via the `PrivilegesService`.
    /// 4. Automatically persists the resulting NVMe blob to the local cache.
    func scan() async {
        setupState = .scanning
        scanNotice = nil

        // 0. Verify smartctl is still installed
        // Robustness: Handle case where user uninstalled it since last check
        let isInstalled = await service.isSmartctlInstalled()
        if !isInstalled {
            logger.log("💿 Robustness Check: smartmontools is missing")
            setupState = .dependencyMissing
            return
        }

        logger.log("💿 Starting SSD health scan...")

        // 1. Detect boot disk
        guard let disk = await service.detectBootDisk() else {
            handleScanFailure("Could not detect your boot disk. Please ensure macOS is running from an internal drive.",
                              isCancellation: false)
            return
        }

        logger.log("💿 Detected boot disk: \(disk)")

        // 2. Run smartctl scan (requires admin password)
        do {
            if let newReport = try await service.scan(disk: disk, privileges: privileges) {
                self.report = newReport
                service.saveReport(newReport)
                logger.log("✅ SSD health scan complete — Score: \(newReport.healthScore)/100")
                setupState = .ready
            } else {
                handleScanFailure("Scan returned no data. Your disk may not support NVMe SMART reporting.",
                                  isCancellation: false)
            }
        } catch {
            logger.log("❌ SSD scan failed: \(error.localizedDescription)")
            let isCancellation = error is PrivilegeError
            let message = isCancellation
                ? "Admin authentication was cancelled or failed. The scan requires your password to read disk health data."
                : "Scan failed: \(error.localizedDescription)"
            handleScanFailure(message, isCancellation: isCancellation)
        }
    }

    /// Resolves a failed scan without discarding usable context.
    ///
    /// **Priority order:**
    /// 1. If a prior report exists, keep showing it and surface the failure as a
    ///    dismissible `scanNotice` — a cancelled/failed re-scan never wipes good data.
    /// 2. Otherwise, a cancelled auth returns to the intro scan screen (`.ready`
    ///    with no report), not a dead-end error card.
    /// 3. Only a genuine failure with nothing to fall back on shows `.error`.
    ///
    /// - Parameters:
    ///   - message: The diagnostic error reason.
    ///   - isCancellation: True if the user dismissed the macOS Admin prompt.
    private func handleScanFailure(_ message: String, isCancellation: Bool) {
        if report != nil {
            scanNotice = isCancellation
                ? "Re-scan cancelled — showing your last saved results."
                : "Re-scan failed — showing your last saved results."
            setupState = .ready
            return
        }

        if isCancellation {
            scanNotice = "The scan needs your admin password. Select “Scan Your Disk” to try again."
            setupState = .ready
            return
        }

        setupState = .error(message)
    }
}
