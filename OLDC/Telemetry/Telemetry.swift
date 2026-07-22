//
//  Telemetry.swift
//  Catalyst
//
//  THE FACADE — the ONLY file in the app that imports or touches Firebase.
//
//  Everything else calls:
//      Telemetry.log(.featureOpened(feature: "Git Graph"))
//      Telemetry.setUser(id: deviceID, tier: "pro")
//      Telemetry.nonFatal(error, context: "shortcutInstall")
//      Telemetry.breadcrumb("opened paywall")
//
//  Single area of repair:
//   • Vendor API changes / swap analytics provider → edit this file's body only.
//     Public method signatures stay the same, so no call site changes.
//   • Global concerns (debug routing, consent/opt-out, sampling) → enforce here once.
//
//  No other file should `import FirebaseAnalytics` or `import FirebaseCrashlytics`.
//

import Foundation
import FirebaseCore
import FirebaseAnalytics
import FirebaseCrashlytics

enum Telemetry {

    /// Configures Firebase. Call once, first thing at app launch (CatalystApp.init).
    /// Keeping init here means the app entry point never imports Firebase either —
    /// the facade is absolute.
    static func start() {
        FirebaseApp.configure()
    }

    /// Master switch. Set to `false` (e.g. from a privacy toggle) to silence all
    /// analytics + crash collection in one place.
    static var isEnabled = true

    // MARK: - Events

    /// Logs an event from the catalog. The only entry point for analytics.
    static func log(_ event: AppEvent) {
        guard isEnabled else { return }
        #if DEBUG
        // Don't pollute production metrics from dev builds; print instead so the
        // event stream is still visible while developing.
        print("📊 [Telemetry] \(event.name) \(event.parameters)")
        #else
        Analytics.logEvent(event.name, parameters: event.parameters)
        #endif
    }

    // MARK: - User properties (segmentation dimensions)

    /// Sets a user property from the catalog. Gathered centrally by `TelemetryProfile.refresh()`.
    static func set(_ property: AppUserProperty) {
        guard isEnabled else { return }
        #if DEBUG
        print("👤 [Telemetry] property \(property.name)=\(property.value)")
        #else
        Analytics.setUserProperty(property.value, forName: property.name)
        #endif
    }

    // MARK: - User / context

    /// Associates crashes & events with a stable, non-PII id (the anonymous device
    /// id — never the email) and records the plan tier as a custom crash key.
    static func setUser(id: String?, tier: String?) {
        guard isEnabled else { return }
        Analytics.setUserID(id)
        Crashlytics.crashlytics().setUserID(id ?? "")
        if let tier { setKey("plan_tier", tier) }
    }

    /// Sets a custom key surfaced on every subsequent crash report.
    static func setKey(_ key: String, _ value: String) {
        guard isEnabled else { return }
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    // MARK: - Errors / crashes

    /// Records a non-fatal error — for the `catch {}` blocks we otherwise swallow
    /// (shell runs, network, install). Captured in Crashlytics without crashing.
    static func nonFatal(_ error: Error, context: String? = nil) {
        guard isEnabled else { return }
        if let context { breadcrumb(context) }
        #if DEBUG
        print("⚠️ [Telemetry] non-fatal (\(context ?? "—")): \(error)")
        #else
        Crashlytics.crashlytics().record(error: error)
        #endif
    }

    /// Adds a breadcrumb log line attached to the next crash report.
    static func breadcrumb(_ message: String) {
        guard isEnabled else { return }
        Crashlytics.crashlytics().log(message)
    }
}
