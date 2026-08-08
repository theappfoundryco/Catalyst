/// THE USER-PROPERTY CATALOG — the segmentation dimensions for analytics.
/// A user property is set once and then EVERY metric (DAU, retention, funnels)
/// can be sliced by it, e.g. "D30 retention for plan = trial".
/// • To add a property:  add a `case` + its `name` and `value`.
/// • Values are bucketed/normalised here so the dashboard stays clean.
/// • Like AppEvent, this file contains NO vendor types. Sending happens in
///   `Telemetry`; gathering happens in `TelemetryProfile`.
/// Keep names ≤ 24 chars [a-z0-9_] and values ≤ 36 chars — the common ceiling across
/// analytics backends, so the catalog stays portable.

import Foundation

/// Every segmentation dimension Catalyst sets. One, today.
enum AppUserProperty {
    /// Whether Homebrew is installed. Splits screen counts by the one environment difference that
    /// changes which screens are usable at all — a Mac without brew can't meaningfully "not use"
    /// the Brew screens.
    case brewInstalled(Bool)

    /// The wire name. snake_case, ≤ 24 chars.
    var name: String {
        switch self {
        case .brewInstalled: return "brew_installed"
        }
    }

    /// The wire value. Bucketed/normalised here so the dashboard stays clean; ≤ 36 chars.
    var value: String {
        switch self {
        case .brewInstalled(let on): return on ? "true" : "false"
        }
    }
}
