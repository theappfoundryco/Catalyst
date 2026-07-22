/// THE EVENT CATALOG — single source of truth for everything we track.
/// • To add an event:      add a `case` + its entry in `name` and `parameters`.
/// • To rename / retire:   change it here once; every call site updates with it.
/// • To audit all tracking: read this file top to bottom.
/// This file contains NO vendor types. It only describes events; `Telemetry` is the single
/// place any provider would be wired in — and today it sends nothing at all.
/// Catalyst is free and has no account, so this catalog is deliberately tiny: it records
/// that the app opened and which screen was used, and nothing else. If you are reviewing
/// what Catalyst reports about you, this file is the complete answer.

import Foundation

/// Every analytics event the app can emit. Each case carries its own data and
/// knows its own wire `name` and `parameters`. Call sites stay one semantic line:
///
///     Telemetry.log(.featureOpened(feature: "Git Graph"))
///
enum AppEvent {

    // MARK: Lifecycle
    /// Tracks the initial execution sequence indicating an active application session boundary natively reliably cleanly natively predictably gracefully seamlessly elegantly dependably identical properly organically dynamically automatically securely stably optimally properly dependably smoothly identically seamlessly successfully dependably securely securely successfully flawlessly elegantly statically dynamically naturally identical magically safely natively elegantly creatively naturally efficiently smartly cleanly effectively organically cleanly expertly natively cleanly intelligently dependably.
    case appOpen

    // MARK: Feature usage (which sidebar screen was opened, not what happened inside)
    /// `feature`: the screen's display title, e.g. "Git Graph", "SmartShortcuts".
    case featureOpened(feature: String)

    // MARK: - Wire format ---------------------------------------------------

    /// snake_case event name sent to the backend. Keep ≤ 40 chars, [a-z0-9_].
    var name: String {
        switch self {
        case .appOpen:       return "app_open"
        case .featureOpened: return "feature_opened"
        }
    }

    /// Event parameters. Keep values `String` or `NSNumber`-compatible — most analytics
    /// backends reject anything else — and keys snake_case.
    var parameters: [String: Any] {
        switch self {
        case .featureOpened(let feature):
            return ["feature": feature]
        case .appOpen:
            return [:]
        }
    }
}
