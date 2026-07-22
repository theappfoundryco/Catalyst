//
//  TelemetryProfile.swift
//  Catalyst
//
//  Gathers the current user-property values from the app's state and pushes them
//  through the `Telemetry` facade. This is the ONE place that knows how to derive
//  each property — keeping `Telemetry` vendor-only and `AppUserProperty` value-only.
//
//  Call `TelemetryProfile.refresh(auth:)` whenever the snapshot may have changed:
//   • cold launch (after auth resolves)
//   • whenever entitlement changes (AuthViewModel.apply)
//
//  Vendor-free: only the facade (Telemetry.swift) links the analytics SDK.
//

import Foundation

enum TelemetryProfile {

    /// Re-reads every segmentation dimension and updates the user properties, plus
    /// the stable anonymous user id (the device UUID — never the email).
    @MainActor
    static func refresh(auth: AuthViewModel) {
        let (planTier, interval): (String, String) = {
            switch auth.state {
            case .entitled(let plan, _):
                return (plan, auth.billingIntervalLabel?.lowercased() ?? "none")
            case .locked:
                return ("none", "none")
            default:
                return ("none", "none")
            }
        }()

        // Stable, non-PII id — the same hardware UUID the entitlement flow uses.
        Telemetry.setUser(id: AuthService.shared.hardwareUUID(), tier: planTier)

        Telemetry.set(.plan(planTier))
        Telemetry.set(.billingInterval(interval))
        Telemetry.set(.willCancel(auth.subscriptionWillCancel))
        Telemetry.set(.studentVerified(auth.studentEmail != nil))

        // `isInstalled` is async — fetch then publish.
        Task { Telemetry.set(.brewInstalled(await BrewPathManager.shared.isInstalled)) }
    }
}
