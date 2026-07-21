//
//  TelemetryProfile.swift
//  Catalyst
//
//  Gathers the current user-property values from the app's state and pushes them
//  through the `Telemetry` facade. This is the ONE place that knows how to derive
//  each property — keeping `Telemetry` vendor-only and `AppUserProperty` value-only.
//
//  Call `TelemetryProfile.refresh()` whenever the snapshot may have changed. Since
//  Catalyst became free and unauthenticated there is exactly one such moment — cold
//  launch — because none of the remaining dimensions change while the app is running.
//
//  Vendor-free: only the facade (Telemetry.swift) links the analytics SDK.
//

import Foundation
import IOKit

enum TelemetryProfile {

    /// Re-reads every segmentation dimension and updates the user properties, plus the stable
    /// anonymous user id.
    @MainActor
    static func refresh() {
        // Stable, non-PII id. There is no account to key on, so the device UUID is the only
        // identity Catalyst has — and the only one it wants.
        Telemetry.setUser(id: hardwareUUID())

        // `isInstalled` is async — fetch then publish.
        Task { Telemetry.set(.brewInstalled(await BrewPathManager.shared.isInstalled)) }
    }

    /// This Mac's hardware UUID. Previously lived on `AuthService`, which the free build no
    /// longer has; kept in this already-registered file rather than a new one so the Xcode
    /// project needs no four-place edit (Formrules §9).
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
