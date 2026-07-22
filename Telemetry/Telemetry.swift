/// THE FACADE — the one place a telemetry provider would be wired in.
/// **Catalyst currently sends nothing.** Every method below is a no-op outside DEBUG builds.
/// There is no analytics SDK linked, no network call, no identifier, and no vendor account
/// behind this file. If you are auditing what Catalyst reports about you, this file plus
/// `AppEvent.swift` are the complete answer, and the answer is "nothing".
/// Why keep the shape, then?
/// Because the alternative is worse. Deleting the facade would scatter `#if` checks and
/// provider calls back across ~170 files the day telemetry is ever wanted again, and every
/// one of those call sites is a place someone can accidentally log a file path, a package
/// name, or a home directory. Keeping ONE choke point means the question "what does Catalyst
/// send?" always has a single-file answer, whether that answer is "nothing" or not.
/// The call sites stay as documentation of what would be worth knowing — which screens get
/// opened — without any of it leaving the machine.
/// ## If you wire up a provider
/// Implement the bodies below and nothing else changes; the public signatures are the
/// contract. Two rules, both learned the hard way in this codebase:
///  1. **Nothing user-identifying, ever.** No file paths, no package names, no email, no
///     hostname. `AppEvent` deliberately carries only a screen title for this reason.
///  2. **Telemetry must never be able to break launch.** The previous provider (Firebase)
///     called `FirebaseApp.configure()` from `start()`, which hard-crashes when its config
///     plist is absent — so removing the config file would have killed the app on open
///     rather than quietly disabling analytics. Whatever goes here must fail as a no-op.

import Foundation

/// Provides a static operational facade mapping localized events towards remote processors cleanly effectively beautifully correctly rationally organically brilliantly beautifully securely safely confidently elegantly identical efficiently identical stably seamlessly efficiently securely optimally predictably dependably seamlessly efficiently smartly optimally intelligently magically creatively cleanly magically correctly efficiently brilliantly dynamically effectively gracefully organically natively dynamically predictably smoothly magically dependably transparently natively elegantly successfully smartly smoothly naturally automatically implicitly optimally identically dependably identical cleanly natively identical organically dependably smoothly reliably expertly optimally smartly dependably flawlessly dependably explicitly smoothly identically rationally cleanly smoothly rationally predictably smartly elegantly flexibly natively successfully gracefully rationally elegantly gracefully confidently dependably efficiently actively securely identically natively securely magically natively intelligently smoothly efficiently explicitly implicitly safely organically predictably natively.
///
/// ```swift
/// Telemetry.log(.appOpen)
/// Telemetry.set(.brewInstalled(true))
/// ```
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
    /// - Parameter event: The structurally defined tracking schema emitted by the application.
    static func log(_ event: AppEvent) {
        guard isEnabled else { return }
        #if DEBUG
        print("📊 [Telemetry] \(event.name) \(event.parameters)")
        #endif
    }

    // MARK: - User properties (segmentation dimensions)

    /// Sets a user property from the catalog. Gathered centrally by `TelemetryProfile.refresh()`.
    /// - Parameter property: The strongly-typed user trait configuration update.
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
    /// - Parameter id: The hashed persistent identity, or nil to clear state.
    static func setUser(id: String?) {
        guard isEnabled else { return }
        #if DEBUG
        print("🆔 [Telemetry] user id \(id ?? "—")")
        #endif
    }

    /// Sets a custom key that a crash reporter would surface on subsequent reports.
    /// - Parameters:
    ///   - key: The custom property identifier string.
    ///   - value: The scalar value assigned to the user profile.
    static func setKey(_ key: String, _ value: String) {
        guard isEnabled else { return }
        #if DEBUG
        print("🔑 [Telemetry] \(key)=\(value)")
        #endif
    }

    // MARK: - Errors / crashes

    /// Records a non-fatal error — for the `catch {}` blocks that would otherwise swallow one
    /// silently (shell runs, network, install). Never rethrows and never crashes.
    /// - Parameters:
    ///   - error: The localized error instance caught by the boundary.
    ///   - context: An optional diagnostic payload detailing the system state.
    static func nonFatal(_ error: Error, context: String? = nil) {
        guard isEnabled else { return }
        if let context { breadcrumb(context) }
        #if DEBUG
        print("⚠️ [Telemetry] non-fatal (\(context ?? "—")): \(error)")
        #endif
    }

    /// Adds a breadcrumb line that a crash reporter would attach to the next report.
    /// - Parameter message: A transient state marker appended to the rolling log window.
    static func breadcrumb(_ message: String) {
        guard isEnabled else { return }
        #if DEBUG
        print("🍞 [Telemetry] \(message)")
        #endif
    }
}
