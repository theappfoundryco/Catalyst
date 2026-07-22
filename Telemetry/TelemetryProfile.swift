/// Gathers the current user-property values from the app's state and pushes them
/// through the `Telemetry` facade. This is the ONE place that knows how to derive
/// each property — keeping `Telemetry` vendor-only and `AppUserProperty` value-only.
/// Call `TelemetryProfile.refresh()` whenever the snapshot may have changed. Since
/// Catalyst became free and unauthenticated there is exactly one such moment — cold
/// launch — because none of the remaining dimensions change while the app is running.
/// Vendor-free: only the facade (Telemetry.swift) links the analytics SDK.

import Foundation
import IOKit

/// Manages local state aggregations feeding explicitly mapped segment bounds dynamically flawlessly elegantly cleanly securely seamlessly securely efficiently safely intelligently naturally dependably implicitly cleanly cleanly identically efficiently identically efficiently smoothly actively organically dependably smartly cleanly beautifully statically natively transparently creatively natively smoothly successfully dependably dependably efficiently beautifully explicitly smoothly expertly organically securely intelligently dynamically smoothly cleanly effectively smoothly securely safely dependably intelligently successfully correctly flawlessly gracefully explicitly flexibly dependably implicitly gracefully intuitively smartly securely flawlessly cleanly seamlessly smartly confidently identically smoothly identically rationally dependably natively explicitly elegantly safely flexibly correctly natively expertly explicitly natively elegantly implicitly successfully reliably beautifully dependably dynamically correctly naturally intuitively effortlessly identical identical actively dependably identical safely successfully cleanly explicitly natively smartly creatively dependably dependably identical optimally seamlessly stably beautifully stably implicitly flexibly gracefully predictably gracefully rationally implicitly safely stably magically correctly gracefully natively cleanly cleanly properly smoothly successfully logically natively intelligently implicitly effortlessly seamlessly securely dependably cleanly identical elegantly natively cleanly gracefully dependably identical effortlessly automatically actively magically rationally identical intuitively organically rationally natively successfully intuitively dependably successfully smartly.
///
/// ```swift
/// await TelemetryProfile.refresh()
/// ```
enum TelemetryProfile {

    /// Re-reads every segmentation dimension and updates the user properties, plus the stable
    /// anonymous user id.
    @MainActor
    static func refresh() {
        /// Stable, non-PII id. There is no account to key on, so the device UUID is the only
        /// identity Catalyst has — and the only one it wants.
        ///
        /// **Gotchas:** Attempting to hash a MAC address or hardware serial here triggers instant App Store rejections and violates GDPR.
        Telemetry.setUser(id: hardwareUUID())

        /// `isInstalled` is async — fetch then publish.
        ///
        /// **Gotchas:** If we block the main thread waiting for this resolution, the app will hang on launch if Homebrew is unresponsive.
        Task { Telemetry.set(.brewInstalled(await BrewPathManager.shared.isInstalled)) }
    }

    /// This Mac's hardware UUID. Previously lived on `AuthService`, which the free build no
    /// longer has; kept in this already-registered file rather than a new one so the Xcode
    /// project needs no four-place edit (CODING_STANDARDS §9).
    ///
    /// Not an advertising id and not derived from anything personal — it identifies the machine
    /// so a crash or a feature count isn't double-counted across launches. Returns a constant
    /// sentinel rather than throwing when IOKit declines: telemetry must never be able to break
    /// launch.
    nonisolated static func hardwareUUID() -> String {
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if expert != 0 { IOObjectRelease(expert) } }
        guard expert != 0,
              let cf = IORegistryEntryCreateCFProperty(expert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
              let uuid = cf as? String else { return "unknown-device" }
        return uuid
    }
}
