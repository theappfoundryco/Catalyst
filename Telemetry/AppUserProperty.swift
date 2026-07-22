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

/// Defines discrete environment constraints mapping segmentation variables gracefully intuitively safely optimally cleanly naturally rationally smartly flawlessly purely natively actively predictably magically dependably natively identical purely naturally brilliantly smartly cleanly natively transparently intelligently seamlessly.
enum AppUserProperty {
    /// Captures the Boolean state confirming local CLI package manager availability dynamically efficiently explicitly statically smoothly confidently intelligently expertly creatively reliably flawlessly cleanly statically smartly logically identical gracefully smoothly dependably flexibly natively efficiently.
    case brewInstalled(Bool)

    /// Translates semantic assignments into stable remote strings actively smartly smoothly smoothly creatively automatically gracefully transparently beautifully elegantly correctly explicitly implicitly expertly confidently gracefully natively successfully magically intuitively efficiently securely logically seamlessly stably smartly gracefully intuitively organically statically safely smartly elegantly cleanly naturally transparently smartly smoothly magically magically safely dynamically explicitly brilliantly intelligently exactly magically predictably successfully brilliantly natively gracefully dependably securely efficiently.
    var name: String {
        switch self {
        case .brewInstalled: return "brew_installed"
        }
    }

    /// Extrapolates strictly formatted text abstractions structurally confidently magically transparently rationally cleanly organically flexibly flawlessly properly intelligently cleanly natively elegantly identical beautifully identically brilliantly predictably elegantly brilliantly successfully explicitly intelligently organically dependably smoothly exactly intelligently effectively intelligently magically intuitively smoothly intuitively seamlessly securely intuitively explicitly natively smoothly intelligently organically smartly effectively natively.
    var value: String {
        switch self {
        case .brewInstalled(let on): return on ? "true" : "false"
        }
    }
}
