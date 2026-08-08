/// THE FACADE — the one place a telemetry provider is wired in.
///
/// **What Catalyst sends, in full:** two events — `app_open`, and `feature_opened` carrying a
/// screen title from a fixed list of 25 — and one user property, `brew_installed`. That is the
/// entire payload. It exists to answer one question: which screens are worth continuing to build.
///
/// **It is off until you turn it on.** ``isEnabled`` reads an explicit opt-in from `ConfigStore`
/// that defaults to absent, and absent means off. Nothing is buffered while disabled and nothing
/// is replayed if you later opt in — a session that ran without consent leaves no trace, because
/// there was nowhere for it to be kept.
///
/// **No identity.** There is no account, no device id, no hardware UUID, and no `setUser` call.
/// The privacy policy promises no device identifier or hardware fingerprint (§4) and this file is
/// where that promise is either kept or broken. Firebase mints its own app-instance id, which is
/// disclosed in the policy and resets when the app is deleted; nothing derived from the machine is
/// ever passed to it.
///
/// ## The two rules, both learned the hard way here
///
///  1. **Nothing user-identifying, ever.** No file paths, no package names, no email, no hostname.
///     `AppEvent` carries only a screen title for exactly this reason. Widening it is a policy
///     change requiring a version bump and re-consent — not an implementation detail.
///  2. **Telemetry must never be able to break launch.** The provider removed at v1.0 called
///     `FirebaseApp.configure()`, which **hard-crashes when its config plist is absent** — so
///     deleting the config would have killed the app on open rather than disabling analytics.
///     ``start()`` below resolves the plist by hand and returns quietly when it isn't there, which
///     is the normal state of any build from a public checkout. Test it by deleting the plist and
///     launching.
///
/// See `Telemetry/README.md`, `docs/ARCHITECTURE.md` §49.6, `docs/CODING_STANDARDS.md` 12.1/12.1b.

import Foundation

#if canImport(FirebaseCore) && canImport(FirebaseAnalytics)
import FirebaseCore
import FirebaseAnalytics
#endif

/// The single entry point for everything Catalyst reports about its own usage.
///
/// ```swift
/// Telemetry.start()
/// Telemetry.log(.featureOpened(feature: "Git Graph"))
/// ```
enum Telemetry {

    /// Set once by ``start()``. False whenever the provider isn't actually available — no SDK
    /// linked, or no config plist in the bundle — so every method below degrades to the no-op it
    /// was before v1.4 rather than pretending to send.
    private static var isConfigured = false

    /// Master switch: an explicit, recorded opt-in and nothing weaker.
    ///
    /// Deliberately a computed read of `ConfigStore` rather than a cached `Bool`. The Settings
    /// toggle and the consent gate both write the config directly, and a cached copy would let the
    /// two disagree — with the failure landing on the side of sending after someone opted out,
    /// which is the one direction that must be impossible.
    static var isEnabled: Bool { ConfigStore.shared.isAnalyticsAllowed }

    // MARK: - Lifecycle

    /// Called once at launch (`CatalystApp.init`), before any UI exists.
    ///
    /// Configuring here rather than lazily is what keeps the provider's own initialisation off the
    /// path of anything a user can trigger. It stays cheap when disabled: with no opt-in recorded
    /// this returns before touching the SDK at all.
    ///
    /// **Gotchas:** `FirebaseApp.configure()` — the no-argument form — reads `GoogleService-Info`
    /// from the bundle and calls `fatalError` when it is missing. That file is gitignored and is
    /// absent from every open-source checkout, so the no-argument form would turn "cloned the repo"
    /// into "app crashes on open". Resolving `FirebaseOptions` by path first makes the absent case
    /// an ordinary early return.
    static func start() {
        guard isEnabled else { return }

        #if canImport(FirebaseCore) && canImport(FirebaseAnalytics)
        guard FirebaseApp.app() == nil else { isConfigured = true; return }
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            /// The normal state of a build from source. Not an error, and not worth a log line on
            /// every launch — the app is simply the no-analytics build the public repo produces.
            return
        }
        FirebaseApp.configure(options: options)
        /// Belt and braces with `FIREBASE_ANALYTICS_COLLECTION_ENABLED = NO` in Info.plist: the
        /// plist key stops the SDK collecting anything before this line runs, and this line is the
        /// only thing that ever turns it on. Without the plist key, Firebase begins collecting at
        /// `configure()` — i.e. before consent — and an opt-in that starts by collecting is not one.
        Analytics.setAnalyticsCollectionEnabled(true)
        isConfigured = true
        #endif
    }

    /// Applies a consent change made while the app is running.
    ///
    /// Opting in from the gate or Settings must take effect without a relaunch, and opting out must
    /// take effect *immediately* — a user who turns this off and sees events continue until they
    /// quit has been ignored, whatever the config file says.
    /// - Parameter allowed: The user's new choice, already persisted by the caller.
    static func setCollectionEnabled(_ allowed: Bool) {
        #if canImport(FirebaseCore) && canImport(FirebaseAnalytics)
        if allowed && !isConfigured {
            /// First opt-in of the session: the SDK was never configured, because `start()` returned
            /// early. Configure now so the choice applies to this run rather than the next one.
            start()
            return
        }
        guard isConfigured else { return }
        Analytics.setAnalyticsCollectionEnabled(allowed)
        #endif
    }

    // MARK: - Events

    /// Logs an event from the catalog. The only entry point for analytics.
    /// - Parameter event: A case of ``AppEvent`` — the complete, auditable list of what may be sent.
    static func log(_ event: AppEvent) {
        guard isEnabled else { return }
        #if DEBUG
        print("📊 [Telemetry] \(event.name) \(event.parameters)")
        #endif
        #if canImport(FirebaseCore) && canImport(FirebaseAnalytics)
        guard isConfigured else { return }
        Analytics.logEvent(event.name, parameters: event.parameters)
        #endif
    }

    // MARK: - User properties (segmentation dimensions)

    /// Sets a user property from the catalog. Gathered centrally by `TelemetryProfile.refresh()`.
    /// - Parameter property: A case of ``AppUserProperty``.
    static func set(_ property: AppUserProperty) {
        guard isEnabled else { return }
        #if DEBUG
        print("👤 [Telemetry] property \(property.name)=\(property.value)")
        #endif
        #if canImport(FirebaseCore) && canImport(FirebaseAnalytics)
        guard isConfigured else { return }
        Analytics.setUserProperty(property.value, forName: property.name)
        #endif
    }

    // MARK: - Deliberately still no-ops

    /// **Not implemented, on purpose.** Catalyst has no account, so a user id could only ever be
    /// derived from the machine — and §4 of the privacy policy promises no device identifier and no
    /// hardware fingerprint. The previous implementation passed `IOPlatformUUID`, a permanent
    /// machine-unique value that is personal data under GDPR and buys nothing for a screen count.
    ///
    /// Kept as a signature so the removal is visible in the file people audit, rather than a blank
    /// space that reads as an oversight.
    /// - Parameter id: Ignored.
    @available(*, deprecated, message: "Catalyst sends no user identifier; see privacy policy §4.")
    static func setUser(id: String?) {}

    /// Crash-reporting surface, retained as no-ops.
    ///
    /// v1.4 added **usage analytics only**. No crash reporter is linked, so there is nothing behind
    /// these — and implementing them would widen what leaves the machine past what the policy now
    /// discloses. They stay as call sites so that if a crash reporter is ever wanted, it lands here
    /// and nowhere else.
    /// - Parameters:
    ///   - error: Ignored.
    ///   - context: Ignored.
    static func nonFatal(_ error: Error, context: String? = nil) {
        #if DEBUG
        print("⚠️ [Telemetry] non-fatal (\(context ?? "—")): \(error)")
        #endif
    }

    /// See ``nonFatal(_:context:)`` — no crash reporter is linked.
    /// - Parameter message: Ignored.
    static func breadcrumb(_ message: String) {
        #if DEBUG
        print("🍞 [Telemetry] \(message)")
        #endif
    }

    /// See ``nonFatal(_:context:)`` — no crash reporter is linked.
    /// - Parameters:
    ///   - key: Ignored.
    ///   - value: Ignored.
    static func setKey(_ key: String, _ value: String) {
        #if DEBUG
        print("🔑 [Telemetry] \(key)=\(value)")
        #endif
    }
}
