import SwiftUI
import AppKit
import Combine

// Versioned Privacy Policy / Terms & Conditions consent.
//
// WHY: legal docs change; when they do, every user must re-accept. This file owns:
//   • the "current" versions (fetched from a stable Vercel static JSON every 14 days, with a
//     build-bundled fallback so we work offline / before the first fetch),
//   • what the user has accepted on THIS Mac (persisted in ConfigStore → survives force-quit +
//     relaunch), and
//   • a blocking, non-dismissable sheet that gates the app until the user accepts.
//
// With no sign-in there is no consent checkbox, so the blocking sheet is the ONLY path and
// catches everyone: fresh installs, existing installs with nothing stored yet, and later version
// bumps alike. Version comparison is exact-match ("accepted != current" ⇒ must re-accept), so any
// change on either axis re-prompts only for the doc(s) that changed.
//
// NETWORK NOTE: the versions JSON is served from theappfoundry.co at a path OUTSIDE `/catalyst/*`,
// so it never invokes the Vercel Edge Middleware — it's a plain static asset. That means one Edge
// Request per check and ZERO Edge Config reads (Hobby caps: 1,000,000 Edge Requests / 100,000 Edge
// Config reads per month). At a 14-day cadence this is negligible.

// MARK: - Config

enum LegalConfig {
    /// Versions shipped with THIS build — used before the first successful remote check and while
    /// offline. Bump these in lock-step with the Vercel JSON when you publish new docs.
    static let bundledPrivacyVersion = "1.1"
    static let bundledTermsVersion   = "1.1"

    /// Canonical, stable URLs for the full documents (Catalyst-specific legal pages).
    static let privacyURL = URL(string: "https://theappfoundry.co/catalyst/privacy")!
    static let termsURL   = URL(string: "https://theappfoundry.co/catalyst/terms")!

    /// Static JSON on Vercel. NOT under `/catalyst/*`, so the Edge Middleware never runs for it.
    static let versionsURL = URL(string: "https://theappfoundry.co/legal/catalyst.json")!

    /// How often to re-check for new legal versions.
    static let checkInterval: TimeInterval = 14 * 24 * 60 * 60
}

// MARK: - Model

/// Shape of the remote versions JSON (see `theappfoundryco/public/legal/catalyst.json`).
struct LegalVersions: Codable {
    struct Doc: Codable { let version: String }
    let privacy: Doc
    let terms: Doc
}

/// Describes which document(s) currently require (re)acceptance, and whether each is a fresh
/// first-time acceptance or an update to a previously-accepted version (drives the sheet copy).
struct LegalConsentRequirement: Equatable, Identifiable {
    var needsPrivacy: Bool
    var needsTerms: Bool
    var privacyIsUpdate: Bool
    var termsIsUpdate: Bool
    var privacyVersion: String
    var termsVersion: String

    /// Stable identity for `.sheet(item:)` — identical requirements share an id so the sheet
    /// doesn't churn/re-present on re-evaluation.
    var id: String { "\(needsPrivacy)-\(needsTerms)-\(privacyVersion)-\(termsVersion)" }

    /// True if any required doc is an update (vs. a first-time acceptance) — headline says
    /// "We've updated…" instead of "Please review…".
    var anyUpdate: Bool { (needsPrivacy && privacyIsUpdate) || (needsTerms && termsIsUpdate) }
}

// MARK: - ViewModel

@MainActor
final class LegalConsentViewModel: ObservableObject {
    /// Non-nil ⇒ the blocking sheet must be shown. Mirrored into `AppViewModel` for presentation.
    @Published private(set) var requirement: LegalConsentRequirement?

    private let config = ConfigStore.shared
    private let session = URLSession(configuration: .ephemeral)

    // Effective "current" versions: last-known remote (cached in ConfigStore) else this build's
    // bundled values. URLs are stable constants, so they never need caching.
    private var currentPrivacyVersion: String { config.cachedPrivacyVersion ?? LegalConfig.bundledPrivacyVersion }
    private var currentTermsVersion: String { config.cachedTermsVersion ?? LegalConfig.bundledTermsVersion }

    /// Kick off at launch (behind the auth gate): refresh remote versions if the 14-day window has
    /// elapsed, then evaluate what still needs consent.
    func start() async {
        await refreshIfDue()
        evaluate()
    }

    /// Re-check on foreground/return (cheap — no-op unless 14 days have passed), then re-evaluate.
    func refreshDue() async {
        await refreshIfDue()
        evaluate()
    }

    /// Recompute `requirement` from persisted acceptance vs. current versions.
    func evaluate() {
        let acceptedP = config.acceptedPrivacyVersion
        let acceptedT = config.acceptedTermsVersion
        let curP = currentPrivacyVersion
        let curT = currentTermsVersion

        let needP = acceptedP != curP   // nil (never accepted) OR mismatch (doc updated)
        let needT = acceptedT != curT

        guard needP || needT else { requirement = nil; return }
        requirement = LegalConsentRequirement(
            needsPrivacy: needP,
            needsTerms: needT,
            privacyIsUpdate: acceptedP != nil,
            termsIsUpdate: acceptedT != nil,
            privacyVersion: curP,
            termsVersion: curT
        )
    }

    /// User accepted from the blocking sheet — record BOTH current versions (harmless to re-write
    /// an already-current one) and clear the requirement.
    func acceptCurrent() {
        config.recordLegalAcceptance(privacy: currentPrivacyVersion, terms: currentTermsVersion)
        evaluate()
    }

    // MARK: Remote fetch

    private func refreshIfDue() async {
        if let last = config.lastLegalCheck,
           Date().timeIntervalSince(last) < LegalConfig.checkInterval { return }
        await fetchRemote()
    }

    private func fetchRemote() async {
        var req = URLRequest(url: LegalConfig.versionsURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let v = try JSONDecoder().decode(LegalVersions.self, from: data)
            // Only stamps lastLegalCheck on success → a failed check retries next launch.
            config.recordLegalRemote(privacy: v.privacy.version, terms: v.terms.version)
        } catch {
            // Offline / bad payload → keep cached versions, don't stamp; retry next launch.
        }
    }
}

// MARK: - Blocking sheet

/// Non-dismissable consent sheet. No close/cancel affordance and `interactiveDismissDisabled(true)`
/// (blocks Escape / click-away), so the only way forward is to agree. Because the requirement is
/// recomputed from persisted state on every launch, a force-quit mid-sheet simply re-shows it.
struct LegalConsentSheet: View {
    @ObservedObject var vm: LegalConsentViewModel
    let requirement: LegalConsentRequirement
    @State private var checked = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tint)

            Text(headline)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)

            Text(bodyText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                if requirement.needsPrivacy {
                    docRow(title: "Privacy Policy",
                           version: requirement.privacyVersion,
                           url: LegalConfig.privacyURL,
                           updated: requirement.privacyIsUpdate)
                }
                if requirement.needsTerms {
                    docRow(title: "Terms & Conditions",
                           version: requirement.termsVersion,
                           url: LegalConfig.termsURL,
                           updated: requirement.termsIsUpdate)
                }
            }

            Toggle(isOn: $checked) {
                Text(agreeLabel)
                    .font(.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .toggleStyle(.checkbox)

            Button { vm.acceptCurrent() } label: {
                Text("Agree & Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!checked)
        }
        .padding(36)
        .frame(width: 540)
        .interactiveDismissDisabled(true)
    }

    // MARK: Rows

    private func docRow(title: String, version: String, url: URL, updated: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(updated ? "Updated · v\(version)" : "Version \(version)")
                    .font(.caption)
                    .foregroundStyle(updated ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            Button("Read") { NSWorkspace.shared.open(url) }
                .buttonStyle(.link)
                .font(.body)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: Adaptive copy

    private var headline: String {
        switch (requirement.needsPrivacy, requirement.needsTerms) {
        case (true, true):
            return requirement.anyUpdate ? "We've updated our terms" : "Before you continue"
        case (true, false):
            return requirement.privacyIsUpdate ? "We've updated our Privacy Policy"
                                               : "Review our Privacy Policy"
        case (false, true):
            return requirement.termsIsUpdate ? "We've updated our Terms & Conditions"
                                             : "Review our Terms & Conditions"
        default:
            return "Before you continue"
        }
    }

    private var bodyText: String {
        let intro = requirement.anyUpdate
            ? "To keep using Catalyst, please review and accept the updated"
            : "To use Catalyst, please review and accept our"
        return "\(intro) \(docPhrase)."
    }

    private var agreeLabel: String {
        // Doc names are already listed in the rows above, so keep this short enough for one line.
        (requirement.needsPrivacy && requirement.needsTerms)
            ? "I have read and agree to both documents above."
            : "I have read and agree to the \(docPhrase) above."
    }

    /// "Privacy Policy", "Terms & Conditions", or "Privacy Policy and Terms & Conditions".
    private var docPhrase: String {
        switch (requirement.needsPrivacy, requirement.needsTerms) {
        case (true, true):  return "Privacy Policy and Terms & Conditions"
        case (true, false): return "Privacy Policy"
        case (false, true): return "Terms & Conditions"
        default:            return "Privacy Policy and Terms & Conditions"
        }
    }
}
