import Foundation

/// XPC contract between the Catalyst app and its privileged helper daemon.
///
/// This file is shared by **both** targets:
/// - the main app (so `PrivilegedHelperManager` can call the helper), and
/// - the `CatalystHelper` command-line target (so the helper can implement it).
///
/// When you create the helper target in Xcode, add this same file to its
/// target membership (see `PrivilegedHelper/README.md`).
@objc(CatalystHelperProtocol)
public protocol CatalystHelperProtocol {
    /// Runs a shell command as root and returns its exit code + combined output.
    func runShell(_ command: String, withReply reply: @escaping (Int32, String) -> Void)

    /// Returns the helper's version string — used to detect when an installed
    /// helper is older than the one bundled with the app and needs updating.
    func getVersion(withReply reply: @escaping (String) -> Void)
}

/// Constants shared by app and helper. Keep these in sync with the launchd
/// plist and bundle identifiers.
public enum CatalystHelperConstants {
    /// Mach service name the helper vends and the app connects to.
    public static let machServiceName = "com.shivanggulati.catalyst.helper"

    /// File name of the launchd plist embedded in the app at
    /// `Contents/Library/LaunchDaemons/`.
    public static let daemonPlistName = "com.shivanggulati.catalyst.helper.plist"

    /// Bump on every helper change so the app can re-install a newer build.
    public static let helperVersion = "1.0.0"
}
