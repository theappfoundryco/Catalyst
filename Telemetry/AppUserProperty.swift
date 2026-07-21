//
//  AppUserProperty.swift
//  Catalyst
//
//  THE USER-PROPERTY CATALOG — the segmentation dimensions for analytics.
//
//  A user property is set once and then EVERY metric (DAU, retention, funnels)
//  can be sliced by it, e.g. "D30 retention for plan = trial".
//
//  • To add a property:  add a `case` + its `name` and `value`.
//  • Values are bucketed/normalised here so the dashboard stays clean.
//  • Like AppEvent, this file contains NO vendor types. Sending happens in
//    `Telemetry`; gathering happens in `TelemetryProfile`.
//
//  Keep names ≤ 24 chars [a-z0-9_] and values ≤ 36 chars — the common ceiling across
//  analytics backends, so the catalog stays portable.
//

import Foundation

enum AppUserProperty {
    case brewInstalled(Bool)

    var name: String {
        switch self {
        case .brewInstalled: return "brew_installed"
        }
    }

    var value: String {
        switch self {
        case .brewInstalled(let on): return on ? "true" : "false"
        }
    }
}
