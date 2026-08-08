/// Gathers the current user-property values from the app's state and pushes them
/// through the `Telemetry` facade. This is the ONE place that knows how to derive
/// each property — keeping `Telemetry` vendor-only and `AppUserProperty` value-only.
///
/// Call `TelemetryProfile.refresh()` whenever the snapshot may have changed. Since
/// Catalyst is free and unauthenticated there is exactly one such moment — cold
/// launch — because none of the remaining dimensions change while the app is running.
///
/// Vendor-free: only the facade (Telemetry.swift) links the analytics SDK.

import Foundation

/// Derives the segmentation dimensions in ``AppUserProperty`` from live app state.
///
/// ```swift
/// TelemetryProfile.refresh()
/// ```
enum TelemetryProfile {

    /// Re-reads every segmentation dimension and updates the user properties.
    ///
    /// **No user id is set, and none should be added.** This previously called
    /// `Telemetry.setUser(id: hardwareUUID())`, passing the Mac's `IOPlatformUUID` — a permanent,
    /// machine-unique value that is personal data under GDPR, that §4 of the privacy policy
    /// promises Catalyst does not collect, and that a screen count has no use for. It was removed
    /// with the v1.4 analytics work along with the `hardwareUUID()` helper that fed it. If you find
    /// yourself needing to tell two installs apart, that is a policy change requiring a version
    /// bump and re-consent, not a helper function.
    @MainActor
    static func refresh() {
        /// `isInstalled` is async — fetch then publish.
        ///
        /// **Gotchas:** If we block the main thread waiting for this resolution, the app will hang
        /// on launch if Homebrew is unresponsive.
        Task { Telemetry.set(.brewInstalled(await BrewPathManager.shared.isInstalled)) }
    }
}
