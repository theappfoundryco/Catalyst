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
//  Firebase limits: name ≤ 24 chars [a-z0-9_], value ≤ 36 chars.
//

import Foundation

enum AppUserProperty {
    /// "pro" | "trial" | "none"
    case plan(String)
    /// "monthly" | "yearly" | "student" | "none"
    case billingInterval(String)
    case willCancel(Bool)
    case studentVerified(Bool)
    case brewInstalled(Bool)

    var name: String {
        switch self {
        case .plan:            return "plan"
        case .billingInterval: return "billing_interval"
        case .willCancel:      return "will_cancel"
        case .studentVerified: return "student_verified"
        case .brewInstalled:   return "brew_installed"
        }
    }

    var value: String {
        switch self {
        case .plan(let p):            return p
        case .billingInterval(let i): return i
        case .willCancel(let on), .studentVerified(let on), .brewInstalled(let on):
            return on ? "true" : "false"
        }
    }
}
