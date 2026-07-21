//
//  Telemetry.swift
//  Catalyst
//
//  THE FACADE — the one place a telemetry provider would be wired in.
//
//  **Catalyst currently sends nothing.** Every method below is a no-op outside DEBUG builds.
//  There is no analytics SDK linked, no network call, no identifier, and no vendor account
//  behind this file. If you are auditing what Catalyst reports about you, this file plus
//  `AppEvent.swift` are the complete answer, and the answer is "nothing".
//
//  Why keep the shape, then?
//
//  Because the alternative is worse. Deleting the facade would scatter `#if` checks and
//  provider calls back across ~170 files the day telemetry is ever wanted again, and every
//  one of those call sites is a place someone can accidentally log a file path, a package
//  name, or a home directory. Keeping ONE choke point means the question "what does Catalyst
//  send?" always has a single-file answer, whether that answer is "nothing" or not.
//
//  The call sites stay as documentation of what would be worth knowing — which screens get
//  opened — without any of it leaving the machine.
//
//  ## If you wire up a provider
//
//  Implement the bodies below and nothing else changes; the public signatures are the
//  contract. Two rules, both learned the hard way in this codebase:
//
//   1. **Nothing user-identifying, ever.** No file paths, no package names, no email, no
//      hostname. `AppEvent` deliberately carries only a screen title for this reason.
//   2. **Telemetry must never be able to break launch.** The previous provider (Firebase)
//      called `FirebaseApp.configure()` from `start()`, which hard-crashes when its config
//      plist is absent — so removing the config file would have killed the app on open
//      rather than quietly disabling analytics. Whatever goes here must fail as a no-op.
//

import Foundation

enum Telemetry {

    /// Called once at launch (`CatalystApp.init`). Intentionally does nothing.
    ///
    /// Kept as a call site so a provider can be initialised in exactly one place, at the one
    /// moment that is guaranteed to be before any UI exists.
    static func start() {}

    /// Master switch. A provider implementation must honour this, and a privacy toggle in
    /// Settings would flip it. With no provider linked it changes nothing.
    static var isEnabled = true

    // MARK: - Events

    /// Logs an event from the catalog. The only entry point for analytics.
    static func log(_ event: AppEvent) {
        guard isEnabled else { return }
        #if DEBUG
        print("📊 [Telemetry] \(event.name) \(event.parameters)")
        #endif
    }

    // MARK: - User properties (segmentation dimensions)

    /// Sets a user property from the catalog. Gathered centrally by `TelemetryProfile.refresh()`.
    static func set(_ property: AppUserProperty) {
        guard isEnabled else { return }
        #if DEBUG
        print("👤 [Telemetry] property \(property.name)=\(property.value)")
        #endif
    }

    // MARK: - User / context

    /// Would associate events with a stable, non-PII device id. There is no account, so the
    /// device id was the whole identity — and with no provider linked, nothing is associated
    /// with anything.
    static func setUser(id: String?) {
        guard isEnabled else { return }
        #if DEBUG
        print("🆔 [Telemetry] user id \(id ?? "—")")
        #endif
    }

    /// Sets a custom key that a crash reporter would surface on subsequent reports.
    static func setKey(_ key: String, _ value: String) {
        guard isEnabled else { return }
        #if DEBUG
        print("🔑 [Telemetry] \(key)=\(value)")
        #endif
    }

    // MARK: - Errors / crashes

    /// Records a non-fatal error — for the `catch {}` blocks that would otherwise swallow one
    /// silently (shell runs, network, install). Never rethrows and never crashes.
    static func nonFatal(_ error: Error, context: String? = nil) {
        guard isEnabled else { return }
        if let context { breadcrumb(context) }
        #if DEBUG
        print("⚠️ [Telemetry] non-fatal (\(context ?? "—")): \(error)")
        #endif
    }

    /// Adds a breadcrumb line that a crash reporter would attach to the next report.
    static func breadcrumb(_ message: String) {
        guard isEnabled else { return }
        #if DEBUG
        print("🍞 [Telemetry] \(message)")
        #endif
    }
}
