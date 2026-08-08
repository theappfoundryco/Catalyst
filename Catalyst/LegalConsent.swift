import SwiftUI
import AppKit
import Combine

/// Versioned Privacy Policy / Terms & Conditions consent.
///
/// WHY: legal docs change; when they do, every user must re-accept. This file owns:
///   • the "current" versions (fetched from a stable Vercel static JSON every 14 days, with a
///     build-bundled fallback so we work offline / before the first fetch),
///   • what the user has accepted on THIS Mac (persisted in ConfigStore → survives force-quit +
///     relaunch), and
///   • a full-window, non-dismissable gate (``LegalGateView``) that REPLACES the app until the
///     user accepts.
///
/// With no sign-in there is no consent checkbox, so the gate is the ONLY path and catches everyone:
/// fresh installs, existing installs with nothing stored yet, and later version bumps alike.
/// Version comparison is exact-match ("accepted != current" ⇒ must re-accept), so any change on
/// either axis re-prompts only for the doc(s) that changed.
///
/// NETWORK NOTE: the versions JSON is served from theappfoundry.co at a path OUTSIDE `/catalyst/*`,
/// so it never invokes the Vercel Edge Middleware — it's a plain static asset. That means one Edge
/// Request per check and ZERO Edge Config reads (Hobby caps: 1,000,000 Edge Requests / 100,000 Edge
/// Config reads per month). At a 14-day cadence this is negligible.
///
/// **Rationale:** Guaranteeing absolute consent capture at the UI root level protects the publisher against GDPR/CCPA liability without requiring a centralized user account database.

// MARK: - Config

enum LegalConfig {
    /// Versions shipped with THIS build — the floor for what the app considers current, used
    /// before the first successful remote check and while offline.
    ///
    /// THREE PLACES MUST AGREE, and this is one of them:
    ///   1. here,
    ///   2. `theappfoundryco/public/legal/catalyst.json` (what the remote check serves),
    ///   3. `theappfoundryco/src/consts.ts` → `LEGAL_VERSIONS.catalyst*` (what the page prints).
    /// A page that prints a version the JSON doesn't serve is the silent failure: the document
    /// reads as updated while nobody is ever re-prompted for it.
    /// 1.4 discloses the opt-in usage analytics added in app v1.4 (privacy §6). The Terms did not
    /// change, and are deliberately NOT bumped with it: `LegalConsentRequirement` tracks the two
    /// axes independently, so a privacy-only bump re-prompts for the privacy document alone rather
    /// than making everyone re-accept a Terms document whose text didn't move.
    static let bundledPrivacyVersion = "1.4"
    static let bundledTermsVersion   = "1.3"

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
    /// A single legal document definition enclosing a strict version string.
    struct Doc: Codable { let version: String }
    let privacy: Doc
    let terms: Doc
}

/// Describes which document(s) currently require (re)acceptance, and whether each is a fresh
/// first-time acceptance or an update to a previously-accepted version (drives the gate copy).
struct LegalConsentRequirement: Equatable {
    var needsPrivacy: Bool
    var needsTerms: Bool
    var privacyIsUpdate: Bool
    var termsIsUpdate: Bool
    var privacyVersion: String
    var termsVersion: String

    /// True if any required doc is an update (vs. a first-time acceptance) — headline says
    /// "We've updated…" instead of "Please review…".
    var anyUpdate: Bool { (needsPrivacy && privacyIsUpdate) || (needsTerms && termsIsUpdate) }
}

// MARK: - ViewModel

@MainActor
final class LegalConsentViewModel: ObservableObject {
    /// Non-nil ⇒ the blocking gate must be shown. Mirrored into `AppViewModel`, which `ContentView`
    /// branches on to swap ``LegalGateView`` in for the entire app.
    @Published private(set) var requirement: LegalConsentRequirement?

    private let config = ConfigStore.shared
    private let session = URLSession(configuration: .ephemeral)

    /// Effective "current" versions: the NEWER of this build's bundled value and the last-known
    /// remote value cached in ConfigStore. URLs are stable constants, so they never need caching.
    ///
    /// WHY `max` AND NOT `cached ?? bundled`: with the coalescing form, the first successful remote
    /// check set `cached` permanently and the bundled constant was never consulted again. Shipping a
    /// build with a bumped `bundledTermsVersion` therefore did nothing — the user kept the stale
    /// cached version and was not re-prompted until the 14-day remote check happened to fire. Since
    /// we publish new docs *with* the release, the build must be able to win. Taking the max also
    /// makes the value monotonic, so a bad/rolled-back remote payload can never walk a user's
    /// current version backwards and silently drop a consent requirement they already satisfied.
    ///
    /// **Gotchas:** Hardcoding dynamic URLs in the binary forces an app update every time a Notion page moves; caching only the version identifier keeps the routing fully dynamic.
    private var currentPrivacyVersion: String {
        Self.newer(LegalConfig.bundledPrivacyVersion, config.cachedPrivacyVersion)
    }
    private var currentTermsVersion: String {
        Self.newer(LegalConfig.bundledTermsVersion, config.cachedTermsVersion)
    }

    /// Picks the later of the build's bundled version and the cached remote one.
    ///
    /// NOT "cached else bundled". A release that ships new documents lands on machines whose
    /// cache still holds the PREVIOUS versions and whose 14-day timer may have up to two weeks
    /// left to run — preferring the cache there would leave every existing user un-prompted for
    /// the new documents for that whole window, which is the one thing this file exists to
    /// prevent. Taking the later value means a release re-prompts on first launch, and a document
    /// published between releases still re-prompts within 14 days.
    ///
    /// It also makes a remote regression harmless: if the JSON is ever rolled back or served
    /// stale, consent never silently walks backwards below what this build ships.
    /// - Parameters:
    ///   - bundled: The version compiled into this build. Acts as the floor.
    ///   - cached: The last version a successful remote check reported, if any.
    /// - Returns: Whichever version is later.
    /// **Gotchas:** `nil` is not the only "absent". A blank or whitespace-only cached value must
    /// fall back to the bundled floor too — caching `""` would make `accepted != current`
    /// permanently true and lock every user behind a gate they could never clear.
    private static func newer(_ bundled: String, _ cached: String?) -> String {
        guard let cached = cached?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cached.isEmpty else { return bundled }
        return isNewer(cached, than: bundled) ? cached : bundled
    }

    /// Compares dotted version strings component-wise as integers, so "1.10" correctly sorts
    /// above "1.9" — lexicographic comparison gets that backwards. Missing trailing components
    /// count as 0 ("1.3" == "1.3.0"); a non-numeric component counts as 0, which keeps a
    /// malformed remote value from ever outranking the bundled floor.
    /// - Parameters:
    ///   - lhs: The candidate version.
    ///   - rhs: The version to beat.
    /// - Returns: True when `lhs` is strictly later than `rhs`.
    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The DEBUG smoke-test reset lives HERE, not in ``start()``.
    ///
    /// `start()` runs from `ContentView`'s `.task`, i.e. after the first render. Resetting there
    /// would let the main app paint, *then* wipe consent and swap the gate in — so a debug build
    /// would exercise a different ordering than a real first launch, which is precisely the bug
    /// this smoke test exists to catch. Resetting in `init` (before `AppViewModel.init` calls
    /// `evaluate()`) makes a debug launch byte-for-byte identical to a virgin install.
    ///
    /// Opt OUT for a given run with `-KeepLegalConsent` in the scheme's launch arguments
    /// (Product → Scheme → Edit Scheme → Run → Arguments). Default is ON: the failure mode this
    /// guards (issue #20 — gate never appears for a new user) is invisible on any Mac that has
    /// already accepted, which is every developer's Mac.
    ///
    /// **Gotchas:** Wrapped in `#if DEBUG`, so a Release build can never reset a real user's consent.
    init() {
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("-KeepLegalConsent") {
            config.resetLegalConsentForDebug()
        }
        #endif
    }

    /// Network top-up at launch: refresh remote versions if the 14-day window has elapsed, then
    /// re-evaluate.
    ///
    /// Fired DETACHED from `startupChecks()`. It is not what gates the app — the decision that
    /// matters is made synchronously in `AppViewModel.init` via ``evaluate()``, because
    /// `startupChecks()` runs from `ContentView`'s `.task`, which fires after the first render and
    /// therefore cannot gate it. This call can only ever *add* a requirement (a newly published
    /// version), which is a correct mid-session re-prompt.
    ///
    /// (`Identifiable`/`id` were dropped from ``LegalConsentRequirement`` with the sheet —
    /// `removeDuplicates()` on the mirror uses `Equatable`, and nothing else consumed the id.)
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

    /// User accepted from the blocking gate — record BOTH current versions (harmless to re-write
    /// an already-current one) and clear the requirement.
    ///
    /// - Parameter analyticsOptIn: The separate, genuinely optional analytics choice made on the
    ///   same card. Recorded whichever way it went, because "declined" and "never asked" have to
    ///   stay distinguishable — see `ConfigStore.Config.analyticsOptIn`.
    func acceptCurrent(analyticsOptIn: Bool) {
        config.recordLegalAcceptance(privacy: currentPrivacyVersion, terms: currentTermsVersion)
        config.recordAnalyticsDecision(allowed: analyticsOptIn, privacyVersion: currentPrivacyVersion)
        /// Applies within this launch rather than the next one. `Telemetry.start()` already ran and
        /// returned early during `CatalystApp.init` — there was no consent to act on yet — so
        /// opting in here has to be what configures the provider.
        Telemetry.setCollectionEnabled(analyticsOptIn)
        evaluate()
    }

    // MARK: Remote fetch

    private func refreshIfDue() async {
        if let last = config.lastLegalCheck,
           Date().timeIntervalSince(last) < LegalConfig.checkInterval { return }
        await fetchRemote()
    }

    /// Fetches the latest published document versions from the remote configuration file.
    private func fetchRemote() async {
        var req = URLRequest(url: LegalConfig.versionsURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let v = try JSONDecoder().decode(LegalVersions.self, from: data)
            /// Reject a structurally-valid but empty payload (`{"privacy":{"version":""}}`). Caching
            /// a blank version would make `accepted != current` true forever and lock every user
            /// behind a gate they can never clear, since acceptance would record the blank too.
            guard !v.privacy.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !v.terms.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            /// Only stamps lastLegalCheck on success → a failed check retries next launch.
            ///
            /// **Rationale:** Ensures offline planes/trains don't artificially exhaust the 14-day cooldown timer without ever actually verifying the remote JSON state.
            config.recordLegalRemote(privacy: v.privacy.version, terms: v.terms.version)
        } catch {
            /// Offline / bad payload → keep cached versions, don't stamp; retry next launch.
            ///
            /// **Gotchas:** Wiping the cached versions on a 500 error would force users to agree to the baseline bundled version, and then agree AGAIN when the server recovers.
        }
    }
}

// MARK: - Blocking gate

/// Full-window consent gate — NOT a sheet. Replaces the app's entire content (sidebar, toolbar and
/// all) until the user accepts, exactly like the old `AuthGateView` sign-in gate did.
///
/// WHY NOT A SHEET: the previous `.sheet(item:)` was hosted on a zero-size `Color.clear` inside
/// `.background(...)` — a layout-only layer and an unreliable presentation anchor. Worse, the
/// requirement resolves at t≈0, before the `NSWindow` is key, and SwiftUI silently drops sheet
/// presentations requested before that. Net effect: brand-new users were never prompted at all
/// (issue #20). A view swap has no presentation machinery to race, so it cannot fail this way.
///
/// LAYOUT: the flexible background — not the card — drives the window's minimum size. The card
/// lives in an `.overlay` so its fixed height never becomes the window minimum (as a `ZStack`
/// sibling it would push the min height past the screen and disable native full-screen). No
/// `.ignoresSafeArea()`: the gate stays below the native titlebar so the real traffic lights stay
/// visible and functional.
struct LegalGateView: View {
    @ObservedObject var vm: LegalConsentViewModel
    let requirement: LegalConsentRequirement
    @State private var checked = false

    /// **Starts false, and the button below is never gated on it.** The privacy policy (§6.3)
    /// promised any future telemetry would be opt-in, so a pre-ticked box or a disabled Continue
    /// would break a commitment users have already accepted. Declining costs the user nothing and
    /// takes no extra click.
    @State private var analyticsOptIn = false

    /// One fixed card size regardless of how many documents need accepting, so the window doesn't
    /// resize between the one-doc and two-doc cases.
    static let cardWidth: CGFloat = 540
    static let cardHeight: CGFloat = 600

    /// Room for the AppKit focus ring, drawn OUTSIDE a control's frame and therefore clipped by the
    /// enclosing ScrollView. Matches the old auth gate's inset.
    static let focusRingInset: CGFloat = 4

    var body: some View {
        Color(NSColor.windowBackgroundColor)
            .overlay(alignment: .center) {
                consentCard.frame(width: Self.cardWidth, height: Self.cardHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            /// Empty principal item reserves the SAME taller unified titlebar the main app uses, so
            /// the window chrome doesn't jump height when the gate clears.
            ///
            /// **Gotchas:** Without a toolbar the window falls back to the compact toolbar-less titlebar, and the whole card visibly shifts up the moment the user accepts.
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
    }

    // MARK: Card

    /// Fixed-size card. Only the state content scrolls — the brand mark stays put.
    private var consentCard: some View {
        VStack(spacing: 24) {
            brandMark

            ScrollView(.vertical) {
                VStack(spacing: 18) {
                    Text(headline)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text(bodyText)
                        .font(.callout)
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
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)

                    analyticsOptInRow

                    Button { vm.acceptCurrent(analyticsOptIn: analyticsOptIn) } label: {
                        Text("Agree & Continue").frame(maxWidth: .infinity)
                    }
                    .appButton(.primary)
                    .controlSize(.large)
                    .disabled(!checked)

                    Text("Catalyst won't open until you accept. You can read either document in your browser first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.focusRingInset)
                .padding(.vertical, Self.focusRingInset)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 460)
        .padding(30)
        .background(Self.cardChrome)
    }

    // MARK: Analytics opt-in

    /// The optional half of the card, visually separated from the mandatory consent above it so
    /// nobody reads it as another box they have to tick to get in.
    ///
    /// The copy states the whole payload — two events, screen names, no identifier — because the
    /// claim is small enough to make in full, and a consent prompt that gestures vaguely at
    /// "improving your experience" is how you end up with a policy nobody believes.
    private var analyticsOptInRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 2)

            Toggle(isOn: $analyticsOptIn) {
                Text("Share anonymous usage analytics")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

            Text("Optional, and off unless you turn it on. Catalyst would report that it opened and "
                 + "which screen you opened — nothing else. No file paths, no package names, no "
                 + "device identifier. You can change this any time on the About screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    /// Shared card shell, mirroring the old auth gate so the two gates are visually identical.
    static var cardChrome: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color(NSColor.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: Brand

    private var brandMark: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
            Text("Catalyst")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Mission control for your Mac dev environment")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
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
                .appButton(.link)
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
        /// Doc names are already listed in the rows above, so this stays short. It may now wrap
        /// freely — the card's ScrollView absorbs any overflow, so a long label can no longer push
        /// the primary button below the fold on a 13-inch MacBook.
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
