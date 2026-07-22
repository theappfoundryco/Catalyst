import Foundation
import SwiftUI
import Combine

/// A view model that fetches and manages the application's "About" and version information.
///
/// `AboutViewModel` reads from a bundled `about.json` file rather than hitting an external API.
/// This guarantees the about screen works offline and accurately reflects the exact build the user installed.
///
/// **Gotchas:**
/// - `about.json` MUST be updated manually during the release process. If the version string
///   is missing, it falls back to the `latest` key or a hardcoded stub.
///
/// ```swift
/// @StateObject private var vm = AboutViewModel()
/// // ...
/// await vm.loadAboutInfo()
/// if let info = vm.currentVersionInfo { Text(info.tagline) }
/// ```
@MainActor
final class AboutViewModel: ObservableObject {
    /// The full application info payload containing all version histories.
    @Published var appInfo: AppInfoResponse?
    /// The specific version info matching the current app version, or a fallback.
    @Published var currentVersionInfo: VersionInfo?
    /// Indicates whether the about info is actively being loaded from disk.
    @Published var isLoading = false
    /// A user-facing error message if the bundle read fails.
    @Published var error: String?
    
    /// The application's short version string (e.g., "1.2.0").
    let appVersion: String
    /// The application's build number (e.g., "42").
    let buildNumber: String
    
    /// Initializes the ``AboutViewModel`` and sets the static version identifiers.
    ///
    /// **Rationale:**
    /// Reads `CFBundleShortVersionString` and `CFBundleVersion` synchronously from the main bundle dictionary.
    /// These values are hardcoded at compile time and serve as keys into the `about.json` dictionary.
    init() {
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        self.buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    /// Loads the "What's new" + app info from a **bundled** `about.json` shipped inside the app.
    ///
    /// **Flow:**
    /// 1. Toggles ``isLoading``.
    /// 2. Resolves the internal `about.json` bundle URL.
    /// 3. Decodes into ``AppInfoResponse``.
    /// 4. Matches the current ``appVersion`` against the parsed dictionary keys, falling back to `.latest` or a hardcoded struct.
    ///
    /// **Rationale:**
    /// We specifically read from `(Resources)` rather than a remote API endpoint. This guarantees the content
    /// works completely offline and inherently matches the exact build the user installed without version skew.
    ///
    /// - Important: Keep `Catalyst/about.json` updated each release (see `RELEASING.md`).
    func loadAboutInfo() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        if let url = Bundle.main.url(forResource: "about", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let info = try? JSONDecoder().decode(AppInfoResponse.self, from: data) {
            appInfo = info
            currentVersionInfo = info.versions[appVersion] ?? info.versions[info.latest]
            return
        }

        // Bundled resource missing/corrupt — fall back to a minimal built-in card so the About
        // screen never renders empty.
        error = "Could not load app info"
        currentVersionInfo = VersionInfo(
            releaseDate: "",
            tagline: "Mission control for your Mac dev environment.",
            highlights: [
                "Manage Homebrew and pip packages across Python versions.",
                "Dr. Catalyst diagnostics, Cruft Sweeper, SSD & battery health.",
                "Snapshot & Migrate your whole dev environment to a new Mac."
            ],
            requirements: "macOS 14.6 or later"
        )
    }
}
