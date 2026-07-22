//
//  AppEvent.swift
//  Catalyst
//
//  THE EVENT CATALOG — single source of truth for everything we track.
//
//  • To add an event:      add a `case` + its entry in `name` and `parameters`.
//  • To rename / retire:   change it here once; every call site updates with it.
//  • To audit all tracking: read this file top to bottom.
//
//  This file contains NO vendor types (no Firebase). It only describes events.
//  The actual sending happens in `Telemetry` — the one file that talks to Firebase.
//

import Foundation

/// Every analytics event the app can emit. Each case carries its own data and
/// knows its own wire `name` and `parameters`. Call sites stay one semantic line:
///
///     Telemetry.log(.subscribeStarted(plan: "yearly", currency: "INR"))
///
enum AppEvent {

    // MARK: Lifecycle & auth
    case appOpen
    case signInCompleted
    case signedOut

    // MARK: Feature usage (which sidebar screen was opened, not what happened inside)
    /// `feature`: the screen's display title, e.g. "Git Graph", "SmartShortcuts".
    case featureOpened(feature: String)

    // MARK: Monetization
    /// `context`: where the paywall was shown, "gate" | "profile".
    case paywallShown(context: String)
    case subscribeStarted(plan: String, currency: String)
    case purchaseCompleted(plan: String)
    case subscribeCancelled
    case restoreAttempted(found: Bool)

    // MARK: Student discount (P12)
    case studentVerifyStarted
    case studentVerified
    case studentPurchaseStarted

    // MARK: - Wire format ---------------------------------------------------

    /// snake_case event name sent to the backend. Keep ≤ 40 chars, [a-z0-9_].
    var name: String {
        switch self {
        case .appOpen:               return "app_open"
        case .signInCompleted:       return "sign_in_completed"
        case .signedOut:             return "signed_out"
        case .featureOpened:         return "feature_opened"
        case .paywallShown:          return "paywall_shown"
        case .subscribeStarted:      return "subscribe_started"
        case .purchaseCompleted:     return "purchase_completed"
        case .subscribeCancelled:    return "subscribe_cancelled"
        case .restoreAttempted:      return "restore_attempted"
        case .studentVerifyStarted:  return "student_verify_started"
        case .studentVerified:       return "student_verified"
        case .studentPurchaseStarted: return "student_purchase_started"
        }
    }

    /// Event parameters. Values must be `String` or `NSNumber`-compatible
    /// (Firebase Analytics rejects other types). Keep keys snake_case.
    var parameters: [String: Any] {
        switch self {
        case .featureOpened(let feature):
            return ["feature": feature]
        case .paywallShown(let context):
            return ["context": context]
        case .subscribeStarted(let plan, let currency):
            return ["plan": plan, "currency": currency]
        case .purchaseCompleted(let plan):
            return ["plan": plan]
        case .restoreAttempted(let found):
            return ["found": found ? 1 : 0]
        case .appOpen, .signInCompleted, .signedOut, .subscribeCancelled,
             .studentVerifyStarted, .studentVerified, .studentPurchaseStarted:
            return [:]
        }
    }
}
