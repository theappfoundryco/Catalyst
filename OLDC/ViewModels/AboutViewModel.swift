import Foundation
import SwiftUI
import Combine

@MainActor
final class AboutViewModel: ObservableObject {
    @Published var appInfo: AppInfoResponse?
    @Published var currentVersionInfo: VersionInfo?
    @Published var isLoading = false
    @Published var error: String?
    
    let appVersion: String
    let buildNumber: String
    
    init() {
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        self.buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    /// Loads the "What's new" + app info from a **bundled** `about.json` shipped inside the app
    /// (Resources), NOT a remote endpoint — so the content always matches the installed build and
    /// works offline. Keep `Catalyst/about.json` updated each release (see RELEASING.md).
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
