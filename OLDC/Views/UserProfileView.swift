import SwiftUI
import Combine
import AppKit

/// Local profile: a display name + a chosen bottts-neutral avatar (persisted in
/// UserDefaults). Identity/plan are server-authoritative (AuthViewModel); this is just
/// the cosmetic layer.
final class UserProfileStore: ObservableObject {
    static let shared = UserProfileStore()

    /// 100 bundled vector avatars (Assets.xcassets/Avatars/bottts-neutral-N).
    static let avatarNames: [String] = (1...100).map { "bottts-neutral-\($0)" }

    @Published var displayName: String { didSet { UserDefaults.standard.set(displayName, forKey: "profile.name") } }
    @Published var avatarName: String { didSet { UserDefaults.standard.set(avatarName, forKey: "profile.avatar") } }

    private init() {
        displayName = UserDefaults.standard.string(forKey: "profile.name") ?? "Developer"
        if let saved = UserDefaults.standard.string(forKey: "profile.avatar") {
            avatarName = saved
        } else {
            // First launch → assign a random avatar and persist it.
            let pick = Self.avatarNames.randomElement() ?? "bottts-neutral-1"
            avatarName = pick
            UserDefaults.standard.set(pick, forKey: "profile.avatar")
        }
    }
}

/// A circular avatar (vector PDF asset), with a soft backing so transparent bots read well.
struct AvatarView: View {
    let name: String
    var size: CGFloat = 30

    var body: some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .scaledToFill()                       // bottts SVGs are a full-bleed colored square
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// Sidebar row (below the system-status row): avatar + name → opens the profile sheet.
struct UserProfileRow: View {
    @ObservedObject private var store = UserProfileStore.shared
    @ObservedObject var authVM: AuthViewModel
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                AvatarView(name: store.avatarName, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    Text(planLabel).font(.caption2).foregroundStyle(planTint)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var planLabel: String {
        switch authVM.state {
        case .entitled(let plan, let days):
            if plan == "pro" {
                return "Pro" + (authVM.billingIntervalLabel.map { " · \($0)" } ?? "")
            }
            return "Trial · \(days) day\(days == 1 ? "" : "s") left"
        case .locked: return "Trial ended"
        default: return "Account"
        }
    }
    private var planTint: Color {
        switch authVM.state {
        case .entitled(let plan, _): return plan == "pro" ? .green : .orange
        case .locked: return .red
        default: return .secondary
        }
    }
}

/// The full UserView sheet: big avatar, editable name, plan/renewal, avatar picker.
struct UserProfileSheet: View {
    @ObservedObject private var store = UserProfileStore.shared
    @ObservedObject var authVM: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingAvatar = false
    @State private var editingName = false
    @State private var showPaywall = false
    @FocusState private var nameFocused: Bool

    private let grid = [GridItem(.adaptive(minimum: 56), spacing: 12)]

    private var isPro: Bool {
        if case .entitled(let plan, _) = authVM.state, plan == "pro" { return true }
        return false
    }
    /// Pro is active but scheduled to end (cancelled, still inside the paid period).
    private var willCancel: Bool { isPro && authVM.subscriptionWillCancel }

    /// One accent used for every detail-row glyph, so the card reads as a single unit.
    private let rowTint = Color.accentColor

    var body: some View {
        Group {
            if showPaywall {
                PaywallView(authVM: authVM, onBack: { showPaywall = false }, context: "profile")
            } else {
                // Scroll ONLY when the content genuinely doesn't fit.
                //
                // Deliberately NOT `ViewThatFits`. That re-runs its fit decision every time the
                // content's height changes — and here height changes constantly, because banners
                // (gift result, comp expiry, invoice result) appear and disappear on @Published
                // updates, under an .animation on the same container. That combination produced
                // an `AttributeGraph: cycle detected` when redeeming a code: mutate state → resize
                // → re-decide the branch → re-render → mutate.
                //
                // A single ScrollView has no branch to re-decide. `.scrollBounceBehavior
                // (.basedOnSize)` suppresses the rubber-banding when content fits, so a short
                // profile behaves exactly as it did before, and `minHeight: geo.size.height`
                // keeps the Spacer honest so Sign out still pins to the bottom.
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        profileContent
                            .frame(minHeight: geo.size.height - AuthGateView.focusRingInset * 2)
                            // See `AuthGateView.focusRingInset`: the ring is drawn outside the
                            // control frame and would otherwise be clipped by this ScrollView.
                            .padding(AuthGateView.focusRingInset)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .frame(width: 460, height: 580)
    }

    private var profileContent: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding([.top, .trailing], 12)

            // Identity
            VStack(spacing: 14) {
                Button { choosingAvatar.toggle() } label: {
                    AvatarView(name: store.avatarName, size: 104)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white, Color.accentColor)
                        }
                }
                .buttonStyle(.plain)
                .help("Change avatar")

                // Name is display-only by default; click (or the pencil) to edit. This
                // avoids macOS making the sheet's lone text field first-responder and
                // select-all'ing the name the instant the sheet opens.
                Group {
                    if editingName {
                        TextField("Your name", text: $store.displayName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .focused($nameFocused)
                            .onSubmit { editingName = false }
                            .onChange(of: nameFocused) { if !$0 { editingName = false } }
                    } else {
                        Text(store.displayName.isEmpty ? "Your name" : store.displayName)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(store.displayName.isEmpty ? .secondary : .primary)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "pencil")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .offset(x: 22)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editingName = true; nameFocused = true }
                            .help("Click to rename")
                    }
                }

                if let mail = authVM.accountEmail, !mail.isEmpty {
                    HStack(spacing: 6) {
                        Label(mail, systemImage: "envelope.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .labelStyle(.titleAndIcon)
                        CopyButton(value: mail)
                    }
                }

                planBadge
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)

            if let banner = authVM.manageBanner {
                manageBannerView(banner)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Comped access about to lapse. Driven ENTIRELY off `authVM` (which is reset in
            // `clearAccountState()`), never off local @State — a banner cached in view state is
            // exactly how the previous account's status leaked across a sign-out.
            if authVM.compExpiringSoon, let left = authVM.compDaysLeft {
                compExpiryBanner(daysLeft: left)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // SUCCESS ONLY. A successful redemption dismisses the paywall (entitlement flips to
            // Pro), so its confirmation has nowhere else to land and must appear here.
            //
            // A FAILURE deliberately does not: it belongs beside the code field that caused it,
            // on the paywall, and rendering it here is what let a rejected code follow the user
            // from the paywall to the profile and sit there after they'd moved on.
            if case .success = authVM.giftBanner {
                giftBannerView(authVM.giftBanner!)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let banner = authVM.invoiceBanner {
                invoiceBannerView(banner)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if choosingAvatar {
                avatarPicker
            } else {
                detailsCard
                if isPro {
                    // Perpetual licence: there is no renewal date, no cancellation, and
                    // nothing to re-verify. Say so plainly rather than leaving the user
                    // wondering when they'll be charged again.
                    Text(authVM.isStudentPro
                         ? "Student licence · paid once. Yours for good, including every future update."
                         : "Paid once. Yours for good, including every future update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.top, 2)
                }
                if !isPro {
                    Button { authVM.restorePurchases() } label: {
                        if authVM.restoring {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Restoring…")
                            }
                        } else {
                            Label("Restore purchases", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.secondaryAction)
                    .controlSize(.small)
                    .disabled(authVM.restoring)
                    .padding(.top, 2)
                }
            }

            // Code redemption lives ONLY on the Upgrade screen (`PaywallView`). It belongs next
            // to the price, where someone weighing how to get Pro is already looking — and
            // keeping it off this landing page leaves the profile as a status view rather than
            // a second place to take billing actions.
            Spacer(minLength: 0)

            HStack(spacing: 12) {
                if !isPro {
                    Button { showPaywall = true } label: { Label("Upgrade to Pro", systemImage: "crown.fill") }
                        .buttonStyle(.borderedProminent)
                } else if let invId = authVM.invoiceId, !invId.isEmpty {
                    // Takes the slot Upgrade vacates once the user is Pro — the primary action
                    // there stops being "buy" and becomes "get my receipt". Green rather than
                    // accent so it reads as a completed purchase, not another thing to pay for.
                    Button { authVM.downloadInvoice() } label: {
                        if authVM.downloadingInvoice {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Preparing…")
                            }
                        } else {
                            Label("Download invoice", systemImage: "arrow.down.doc.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(authVM.downloadingInvoice)
                }
                // isPro && (willCancel || student grant) → nothing to cancel/buy, so no billing button.
                Spacer()
                // Filled red, not the default bordered-destructive (which renders red text on a
                // grey chip). `.borderedProminent` + red tint gives white-on-red, matching the
                // weight of the primary action beside it.
                Button(role: .destructive) { authVM.signOut(); dismiss() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(16)
        }
        .animation(.easeInOut(duration: 0.22), value: authVM.manageBanner)
    }

    /// A full-width status banner (max-width infinity) that highlights a manage/cancel action.
    @ViewBuilder
    private func manageBannerView(_ banner: AuthViewModel.ManageBanner) -> some View {
        let (icon, tint, text, showSpinner): (String, Color, String, Bool) = {
            switch banner {
            case .working(let m): return ("hourglass", .accentColor, m, true)
            case .success(let m): return ("checkmark.circle.fill", .green, m, false)
            case .failure(let m): return ("exclamationmark.triangle.fill", .orange, m, false)
            }
        }()
        HStack(alignment: .center, spacing: 10) {
            if showSpinner {
                ProgressView().controlSize(.small).frame(width: 20)
            } else {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint).frame(width: 20)
            }
            Text(text).font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if case .working = banner {
                EmptyView()                       // in-progress banner isn't dismissible
            } else {
                Button { authVM.dismissManageBanner() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .statusBannerChrome(tint: tint)   // shared banner chrome (see StatusBanner)
    }

    /// Comped-access expiry warning. Not dismissible: unlike a manage/cancel result this is a
    /// standing fact about the account, and dismissing it would only hide a deadline that is
    /// still approaching. It disappears on its own when the comp is extended or converted.
    @ViewBuilder
    private func compExpiryBanner(daysLeft: Int) -> some View {
        let ended = daysLeft <= 0
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: ended ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(ended
                     ? "Your complimentary access has ended."
                     : "Your complimentary access ends in \(daysLeft) day\(daysLeft == 1 ? "" : "s").")
                    .font(.callout)
                    .foregroundStyle(.primary)
                if let until = authVM.compValidUntil, !ended {
                    Text("Full access until \(Self.mediumDate.string(from: until)). Buy a lifetime licence any time to keep it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .statusBannerChrome(tint: .orange)
    }

    @ViewBuilder
    private func giftBannerView(_ banner: AuthViewModel.ManageBanner) -> some View {
        simpleBanner(banner) { authVM.dismissGiftBanner() }
    }

    @ViewBuilder
    private func invoiceBannerView(_ banner: AuthViewModel.ManageBanner) -> some View {
        simpleBanner(banner) { authVM.dismissInvoiceBanner() }
    }

    /// Shared chrome for the dismissible result banners, so gift/invoice/manage can't drift.
    @ViewBuilder
    private func simpleBanner(_ banner: AuthViewModel.ManageBanner, dismiss: @escaping () -> Void) -> some View {
        let (icon, tint, text, spin): (String, Color, String, Bool) = {
            switch banner {
            case .working(let m): return ("hourglass", .accentColor, m, true)
            case .success(let m): return ("checkmark.circle.fill", .green, m, false)
            case .failure(let m): return ("exclamationmark.triangle.fill", .orange, m, false)
            }
        }()
        HStack(alignment: .center, spacing: 10) {
            if spin {
                ProgressView().controlSize(.small).frame(width: 20)
            } else {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint).frame(width: 20)
            }
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if case .working = banner {
                EmptyView()
            } else {
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .statusBannerChrome(tint: tint)
    }

    static let mediumDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()

    private var planBadge: some View {
        Group {
            switch authVM.state {
            case .entitled(let plan, let days):
                if plan == "pro" {
                    if willCancel {
                        chip("Pro · ends \(renewalValue)", "clock.badge.xmark.fill", .orange)
                    } else if authVM.isCompPro, let left = authVM.compDaysLeft {
                        // Capped comp: the countdown belongs ON the badge, because the badge is
                        // the one thing visible without opening the sheet. Turns orange only
                        // inside the warning window so it isn't permanently alarming.
                        chip("Pro · Complimentary · \(left) day\(left == 1 ? "" : "s") left",
                             authVM.compExpiringSoon ? "clock.badge.exclamationmark.fill" : "gift.fill",
                             authVM.compExpiringSoon ? .orange : .green)
                    } else {
                        chip("Pro" + (authVM.billingIntervalLabel.map { " · \($0)" } ?? ""), "checkmark.seal.fill", .green)
                    }
                } else {
                    chip("Free trial · \(days) day\(days == 1 ? "" : "s") left", "clock.fill", .orange)
                }
            case .locked:
                chip("Trial ended", "lock.fill", .red)
            default:
                chip("Account", "person.fill", .secondary)
            }
        }
    }

    private func chip(_ text: String, _ icon: String, _ tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            row(icon: "sparkles", label: "Plan", value: planValue)
            Divider().opacity(0.5)
            row(icon: (willCancel || authVM.isStudentPro) ? "clock.badge.xmark" : "calendar", label: renewalLabel, value: renewalValue)
            if let subId = authVM.subscriptionId, !subId.isEmpty {
                Divider().opacity(0.5)
                HStack(spacing: 11) {
                    Image(systemName: "number")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(rowTint)
                        .frame(width: 20)
                    Text("Subscription ID").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(subId)
                        .font(.callout.weight(.medium).monospaced())
                        .lineLimit(1)
                        .textSelection(.enabled)
                    CopyButton(value: subId)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .help("Your subscription reference — quote this if you contact support.")
            }
            if let grantId = authVM.grantId, !grantId.isEmpty {
                Divider().opacity(0.5)
                HStack(spacing: 11) {
                    // Not `checkmark.seal.fill` — that's already the Pro chip's glyph above.
                    Image(systemName: "key.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(rowTint)
                        .frame(width: 20)
                    Text("Licence ID").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(grantId)
                        .font(.callout.weight(.medium).monospaced())
                        .lineLimit(1)
                        .textSelection(.enabled)
                    CopyButton(value: grantId)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .help("Your licence reference — quote this if you contact support.")
            }
            // Invoice. Shown only once one has been ISSUED, which happens after payment settles
            // — not when the buyer's details were entered. Showing an id at details-entry time
            // would promise a document that doesn't exist yet and would be wrong if payment
            // never completed.
            if let invId = authVM.invoiceId, !invId.isEmpty {
                Divider().opacity(0.5)
                HStack(spacing: 11) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(rowTint)
                        .frame(width: 20)
                    Text("Invoice").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(invId)
                        .font(.callout.weight(.medium).monospaced())
                        .lineLimit(1)
                        .textSelection(.enabled)
                    // Download moved to the primary button in the footer — two affordances for
                    // the same action on one screen is one too many. This row is now purely the
                    // support handle: read it, copy it.
                    CopyButton(value: invId)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .help("Your invoice number — quote this if you contact support.")
            }
            if authVM.isStudentPro, let mail = authVM.studentEmail, !mail.isEmpty {
                Divider().opacity(0.5)
                HStack(spacing: 11) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 20)
                    Text("Student")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(mail)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    CopyButton(value: mail)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        )
        .padding(20)
    }

    private var avatarPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Choose an avatar").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { choosingAvatar = false }.font(.caption)
            }
            .padding(.horizontal, 20)
            ScrollView {
                LazyVGrid(columns: grid, spacing: 12) {
                    ForEach(UserProfileStore.avatarNames, id: \.self) { name in
                        Button { store.avatarName = name; choosingAvatar = false } label: {
                            AvatarView(name: name, size: 56)
                                .overlay(Circle().strokeBorder(store.avatarName == name ? Color.accentColor : .clear, lineWidth: 2.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
            }
        }
        .padding(.top, 8)
    }

    private func row(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(rowTint)
                .frame(width: 20)
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.weight(.medium)).textSelection(.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var planValue: String {
        switch authVM.state {
        case .entitled(let plan, _):
            if plan == "pro" { return "Pro" + (authVM.billingIntervalLabel.map { " · \($0)" } ?? "") }
            return "Free trial"
        case .locked: return "None"
        default: return "—"
        }
    }
    /// A perpetual licence has no renewal and no end date, so the row is "Validity / Lifetime".
    /// The trial and any legacy subscription still show real dates.
    private var isPerpetual: Bool {
        guard case .entitled(let plan, _) = authVM.state, plan == "pro" else { return false }
        // A CAPPED comp is grant-backed and has no subscription, so the old
        // `subscriptionId == nil` test alone would have called it perpetual and printed
        // "Validity / Lifetime" over access that genuinely lapses. Comps are excluded here and
        // handled below; a PERPETUAL comp falls through to the real "Lifetime" answer via
        // `isPerpetualComp`.
        if authVM.isCompPro { return authVM.isPerpetualComp }
        // A grant is what backs a perpetual licence; a legacy subscription still has a real
        // period end worth showing.
        return authVM.subscriptionId == nil
    }

    private var renewalLabel: String {
        if case .entitled(let plan, _) = authVM.state, plan == "trial" { return "Trial ends" }
        if case .locked = authVM.state { return "Ended" }
        if isPerpetual { return "Validity" }
        // A capped comp ends on a real date, and saying "Renews" would promise something that
        // will not happen — nothing renews a comp.
        if authVM.isCompPro { return "Complimentary until" }
        return willCancel ? "Access until" : "Renews"
    }

    private var renewalValue: String {
        // Never render the far-future sentinel (1 Jan 2100) — it's an implementation detail of
        // "never expires", not a date any user should be shown. Say the thing it means instead.
        if isPerpetual { return "Lifetime" }
        // Capped comp: read the comp's own expiry, not `entitlementEnd`. They agree today, but
        // `entitlementEnd` is max(trial, grant) — a longer running trial would otherwise print a
        // date the comp does not actually run to.
        if authVM.isCompPro, let until = authVM.compValidUntil {
            let f = DateFormatter(); f.dateStyle = .medium
            return f.string(from: until)
        }
        guard let end = authVM.entitlement?.entitlementEnd, end > 0 else { return "—" }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: end))
    }
}

// MARK: - Invoice document (non-GST)

/// A single-page A4 invoice, laid out as an ordinary SwiftUI view and rendered to a **vector**
/// PDF by `ImageRenderer` + `CGDataConsumer`.
///
/// Why this and not PDFKit: `ImageRenderer.render` hands back a `CGContext`, and drawing into a
/// PDF-backed context keeps text as text — selectable, searchable, and crisp at any zoom, rather
/// than a screenshot of a view. Hand-building the same layout in PDFKit would mean positioning
/// every string by hand for no gain.
///
/// `ImageRenderer` is `@MainActor`, so the render itself must run on the main thread. That's
/// fine for one page (single-digit milliseconds) PROVIDED the data is already in hand — which is
/// why `AuthViewModel` fetches first and only then renders. Fetching inside the render would
/// block the main thread on the network, which is exactly the UI hang the rules forbid.
struct InvoiceDocument: View {
    let data: InvoiceData

    // A4 at 72dpi. Fixed, because a PDF page needs a real physical size — not the window's.
    static let pageSize = CGSize(width: 595, height: 842)
    private static let ink = Color.black
    private static let muted = Color(white: 0.42)
    private static let hairline = Color(white: 0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Self.hairline).frame(height: 1).padding(.top, 18)
            partiesBlock
            lineItemsTable
            totalsBlock
            if data.isStudent { learnerBlock }
            paymentBlock
            Spacer(minLength: 0)
            footer
        }
        .padding(44)
        .frame(width: Self.pageSize.width, height: Self.pageSize.height, alignment: .topLeading)
        .background(Color.white)
        // The document must look identical regardless of the app's appearance. Without this a
        // user in Dark Mode would export white-on-white.
        .environment(\.colorScheme, .light)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    // Vector PDF asset → stays sharp at any scale.
                    Image("taf_logo")
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(Self.ink)
                    Text(data.seller.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Self.ink)
                }
                Text("\(data.seller.city), \(data.seller.country) \(data.seller.postal_code)")
                    .font(.system(size: 9)).foregroundStyle(Self.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("INVOICE")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Self.ink)
                labelled("Invoice no.", data.id, mono: true)
                labelled("Issued", Self.dateTime.string(from: Date(timeIntervalSince1970: data.issued_at)))
            }
        }
    }

    // MARK: Parties

    private var partiesBlock: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 5) {
                sectionLabel("Billed to")
                Text(data.buyer_name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.ink)
                ForEach(buyerAddressLines, id: \.self) { line in
                    Text(line).font(.system(size: 9.5)).foregroundStyle(Self.muted)
                }
                Text(data.buyer_email).font(.system(size: 9.5)).foregroundStyle(Self.muted)
                if let phone = data.buyer_phone, !phone.isEmpty {
                    Text(phone).font(.system(size: 9.5)).foregroundStyle(Self.muted)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                sectionLabel("Account")
                Text(data.account_email).font(.system(size: 9.5)).foregroundStyle(Self.muted)
                if let g = data.grant_id, !g.isEmpty {
                    // Never elided — the hidden characters are what a dispute turns on.
                    Text("Licence \(g)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Self.muted)
                }
            }
            .frame(width: 200, alignment: .leading)
        }
        .padding(.top, 18)
    }

    /// Only the lines the buyer actually filled in — an invoice with blank gaps where "line 2"
    /// would go looks like a rendering fault, not an optional field.
    private var buyerAddressLines: [String] {
        var out: [String] = []
        if let l = data.buyer_line1, !l.isEmpty { out.append(l) }
        if let l = data.buyer_line2, !l.isEmpty { out.append(l) }
        let cityLine = [data.buyer_city, data.buyer_state, data.buyer_postal]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if !cityLine.isEmpty { out.append(cityLine) }
        if let c = data.buyer_country, !c.isEmpty { out.append(c) }
        return out
    }

    // MARK: Line items

    private var lineItemsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                Text("Qty").frame(width: 44, alignment: .trailing)
                Text("Amount").frame(width: 96, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Self.muted)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) { Rectangle().fill(Self.hairline).frame(height: 1) }

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image("catalyst_logo")
                            .resizable().scaledToFit()
                            .frame(width: 13, height: 13)
                        Text(data.isStudent
                             ? "Catalyst Pro — Lifetime licence (Student rate)"
                             : "Catalyst Pro — Lifetime licence")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Self.ink)
                    }
                    Text("One-time purchase. Includes every future update, with no renewal.")
                        .font(.system(size: 8.5)).foregroundStyle(Self.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("1").font(.system(size: 10)).frame(width: 44, alignment: .trailing)
                    .foregroundStyle(Self.ink)
                Text(data.formattedAmount).font(.system(size: 10))
                    .frame(width: 96, alignment: .trailing).foregroundStyle(Self.ink)
            }
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Rectangle().fill(Self.hairline).frame(height: 1) }
        }
        .padding(.top, 22)
    }

    private var totalsBlock: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                totalRow("Subtotal", data.formattedAmount, bold: false)
                // Stated as an explicit zero rather than omitted. A missing tax line reads as an
                // oversight; a zero line is a statement.
                totalRow("GST", "—", bold: false)
                Rectangle().fill(Self.hairline).frame(width: 210, height: 1)
                totalRow("Total paid", data.formattedAmount, bold: true)
            }
        }
        .padding(.top, 13)
    }

    private func totalRow(_ label: String, _ value: String, bold: Bool) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: bold ? 11 : 9.5, weight: bold ? .semibold : .regular))
                .foregroundStyle(bold ? Self.ink : Self.muted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: bold ? 12 : 9.5, weight: bold ? .bold : .regular))
                .foregroundStyle(Self.ink)
                .frame(width: 100, alignment: .trailing)
        }
        .frame(width: 210)
    }

    // MARK: Learner

    private var learnerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.ink)
                Text("Verified learner")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Self.ink)
            }
            if let mail = data.student_email, !mail.isEmpty {
                kv("Learner ID", mail)
            }
            if let at = data.student_verified_at {
                kv("Verified on", Self.dateTime.string(from: Date(timeIntervalSince1970: at)))
            }
            Text("The academic rate was applied against a verified academic email at the time of purchase.")
                .font(.system(size: 8)).foregroundStyle(Self.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.965)))
        .padding(.top, 18)
    }

    // MARK: Payment

    private var paymentBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("Payment")
            if let m = data.payment_method, !m.isEmpty { kv("Method", m.uppercased()) }
            if let at = data.payment_at {
                kv("Paid on", Self.dateTime.string(from: Date(timeIntervalSince1970: at)))
            }
            if let ref = data.payment_ref, !ref.isEmpty { kv("Reference", ref, mono: true) }
        }
        .padding(.top, 18)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle().fill(Self.hairline).frame(height: 1)
            Text(data.seller.tax_note)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Self.ink)
                .padding(.top, 7)
            Text("Paid in full. Retain this document for your records — quote the invoice number above for any query.")
                .font(.system(size: 8)).foregroundStyle(Self.muted)
        }
    }

    // MARK: Bits

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Self.muted)
    }

    private func kv(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).font(.system(size: 9)).foregroundStyle(Self.muted)
                .frame(width: 72, alignment: .leading)
            Text(v)
                .font(.system(size: 9, design: mono ? .monospaced : .default))
                .foregroundStyle(Self.ink)
        }
    }

    private func labelled(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(k).font(.system(size: 8.5)).foregroundStyle(Self.muted)
            Text(v)
                .font(.system(size: 9.5, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(Self.ink)
        }
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Render to a single-page vector PDF.
    ///
    /// `@MainActor` because `ImageRenderer` is. Returns nil rather than throwing so the caller
    /// can show one honest failure message — there is no partial success worth reporting.
    @MainActor
    static func renderPDF(data: InvoiceData) -> Data? {
        let renderer = ImageRenderer(content: InvoiceDocument(data: data))
        // Render at 1× into a PDF context: the page is measured in points, and scaling here
        // would enlarge the PAGE rather than sharpen it — vector output has no pixel grid.
        renderer.scale = 1

        let pdf = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData) else { return nil }
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        var ok = false
        renderer.render { _, draw in
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ok = true
        }
        ctx.closePDF()
        return ok ? (pdf as Data) : nil
    }
}

/// Buyer details, collected before checkout so the invoice can be issued the moment payment
/// settles. In this already-registered file to avoid a new-file pbxproj entry (Formrules §9).
///
/// Every field validates through `BillingValidators` — one shared rule set rather than a copy
/// per view model (Formrules 12.27). Errors appear inline and only AFTER the field has been
/// touched, so an untouched form looks neutral rather than pre-scolding the user; the primary
/// button stays disabled until every required rule passes.
struct BillingDetailsSheet: View {
    @ObservedObject var authVM: AuthViewModel
    var isStudent: Bool
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Billing details").font(.title3.weight(.semibold))
                    // Naming the tier here is a last confirmation of WHAT is being bought,
                    // on the final screen before money moves.
                    Text(isStudent
                         ? "These appear on your invoice for the student licence."
                         : "These appear on your invoice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Full name", text: $authVM.billing.name, error: authVM.billingNameError,
                          prompt: "Name this invoice is made out to", required: true)
                    field("Email", text: $authVM.billing.email, error: authVM.billingEmailError,
                          prompt: "you@example.com", required: true)
                    field("Phone", text: $authVM.billing.phone, error: authVM.billingPhoneError,
                          prompt: "+91 98765 43210", required: true)
                    field("Address", text: $authVM.billing.line1, error: authVM.billingLine1Error,
                          prompt: "Street address", required: true)
                    field("Address line 2", text: $authVM.billing.line2, error: nil,
                          prompt: "Apartment, suite, etc.")
                    HStack(alignment: .top, spacing: 12) {
                        field("City", text: $authVM.billing.city, error: authVM.billingCityError,
                              prompt: "City", required: true)
                        field("State", text: $authVM.billing.state, error: nil, prompt: "State")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("Postal code", text: $authVM.billing.postalCode,
                              error: authVM.billingPostalError,
                              prompt: authVM.billing.country.uppercased() == "IN" ? "6-digit PIN" : "Postal code",
                              required: true)
                        field("Country", text: $authVM.billing.country, error: nil,
                              prompt: "IN", required: true)
                    }

                    Text("Fields marked \(Text("*").foregroundColor(.red)) are required.")
                        .font(.caption2).foregroundStyle(.secondary)

                    // Deliberately worded as a courtesy, not a warning. The user is about to pay;
                    // the goal is a careful glance, not anxiety about whether it's safe to buy.
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Please double-check these details before continuing — they're printed on your invoice, and having them right from the start makes any future query much easier to sort out.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)

                    if let banner = authVM.billingBanner, case .failure(let msg) = banner {
                        StatusBanner(icon: "exclamationmark.triangle.fill", tint: .orange, text: msg)
                    }
                }
                // Nine text fields, every one of them focusable — this is the screen where a
                // clipped focus ring is most obvious. See `AuthGateView.focusRingInset`.
                .padding(.horizontal, 22 - AuthGateView.focusRingInset)
                .padding(.vertical, AuthGateView.focusRingInset)
                .padding(.bottom, 8)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        // Chain: only open checkout if the details actually persisted. A payment
                        // whose buyer record failed to save cannot be repaired after the fact.
                        if await authVM.saveBillingProfile() { onSaved() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if authVM.savingBilling { ProgressView().controlSize(.small) }
                        Text(authVM.savingBilling ? "Saving…" : "Continue to payment").fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!authVM.isBillingValid || authVM.savingBilling)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 460, height: 560)
    }

    /// `required` drives BOTH the red marker and nothing else — the actual rule lives in
    /// `BillingValidators`. They're kept adjacent at each call site so a field can't be marked
    /// optional while still being enforced (or the reverse), which is the usual way these drift.
    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, error: String?,
                       prompt: String, required: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                Text(label)
                if required {
                    Text("*")
                        .foregroundStyle(.red)
                        // Not conveyed by colour alone — colour-blind users and greyscale
                        // printing both lose it, so the label is spoken to VoiceOver too.
                        .accessibilityHidden(true)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(required ? "\(label), required" : label)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(error == nil ? Color.clear : Color.orange.opacity(0.7), lineWidth: 1)
                )
            if let error {
                Text(error).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Redeem a gift code. Lives wherever a user might arrive with one: the profile sheet (already
/// signed in) and the paywall (deciding whether to buy).
struct GiftRedeemSection: View {
    @ObservedObject var authVM: AuthViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Have a code?").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Enter your code", text: $authVM.giftCodeInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(authVM.redeemingGift)
                    .onSubmit { authVM.redeemGiftCode() }
                Button {
                    authVM.redeemGiftCode()
                } label: {
                    if authVM.redeemingGift {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Redeem")
                    }
                }
                .disabled(!authVM.isGiftCodeValid || authVM.redeemingGift)
            }
            if let err = authVM.giftCodeError {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }
            // The SERVER's answer, shown next to the field that produced it.
            //
            // The profile sheet renders this banner too, and that is not duplication: on
            // SUCCESS the paywall dismisses itself (entitlement flips to pro), so the
            // confirmation has to land on the profile. On FAILURE the paywall stays put, and
            // the message has to be here — beside the input the user must correct. Only one is
            // ever on screen.
            if let banner = authVM.giftBanner {
                let (icon, tint, text): (String, Color, String) = {
                    switch banner {
                    case .working(let m): return ("hourglass", .accentColor, m)
                    case .success(let m): return ("checkmark.circle.fill", .green, m)
                    case .failure(let m): return ("exclamationmark.triangle.fill", .orange, m)
                    }
                }()
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: icon).font(.caption).foregroundStyle(tint)
                    Text(text).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, 1)
            }
        }
    }
}

/// A small copy-to-clipboard button that flashes a green checkmark for ~2s, then reverts.
/// Kept in this already-registered file (Views/) so no new file needs pbxproj registration
/// (Formrules §9).
private struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy")
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}

/// The "Upgrade to Pro" view — rendered INLINE inside the profile sheet (not a nested sheet).
/// One perpetual licence, one price. "Buy Catalyst Pro" opens
/// Razorpay's hosted checkout; entitlement re-checks after payment. In this already-registered
/// file to avoid a new-file pbxproj entry (Formrules §9).
struct PaywallView: View {
    @ObservedObject var authVM: AuthViewModel
    var onBack: () -> Void
    var context: String = "app"   // where the paywall was shown, for analytics ("profile" | "gate")

    /// Catalyst is sold ONCE — one price, lifetime updates, nothing to choose between and
    /// nothing to cancel. Billing is INR-only while international payments are pending
    /// approval, so no currency switch is offered: quoting a price we can't actually charge
    /// was the previous behaviour and it left non-Indian users at a dead button.
    // Prices AND currency are SERVER-DRIVEN. `/entitlement` returns the live values from the
    // same `licensePrice()` the checkout uses, so displayed and charged can't disagree — and a
    // price change is a KV write (seconds, no deploy), while a NEW CURRENCY is server config
    // with no app release, because nothing here hardcodes a symbol.
    //
    // The constants below are only an OFFLINE FALLBACK for the cached-JWT path, when there's no
    // server response yet. A stale-but-plausible number beats a blank where a price should be.
    private static let fallbackPriceMinor = 599900      // ₹5,999 in paise
    private static let fallbackStudentPriceMinor = 249900
    private static let fallbackCurrency = "INR"

    /// Presents the billing-details form. Local @State is fine here (it's a transient
    /// presentation flag, not account status) — the DATA behind it lives on `authVM` and is
    /// wiped by `clearAccountState()`.
    @State fileprivate var showBillingSheet = false

    /// Which tier this paywall is quoting. A PROPERTY, not a local, because three separate
    /// places now depend on it — the price shown, the tier sent to `buyLicense`, and the
    /// billing sheet. As a local inside `chooser` it was invisible to the sheet on `body`, and
    /// re-deriving it per call site is exactly how a user gets quoted one price and charged
    /// another.
    fileprivate var isStudent: Bool { authVM.studentEligible }

    private var currencyCode: String { authVM.entitlement?.currency ?? Self.fallbackCurrency }

    /// Minor units → major, for display. Zero-decimal currencies (JPY, KRW) would need a
    /// per-currency divisor; INR and USD are both 100, so this stays simple until one appears.
    private var priceMajor: Int {
        (authVM.entitlement?.priceStandardMinor ?? Self.fallbackPriceMinor) / 100
    }
    private var studentPriceMajor: Int {
        (authVM.entitlement?.priceStudentMinor ?? Self.fallbackStudentPriceMinor) / 100
    }

    /// Format an amount with the SERVER's currency — never a hardcoded symbol. That's the whole
    /// reason enabling USD needs no app release.
    private func money(_ major: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currencyCode
        f.maximumFractionDigits = 0
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: major)) ?? "\(currencyCode) \(fmt(major))"
    }

    var body: some View {
        // Scrolls only when it must — same reasoning as the profile sheet. This screen grew a
        // redeem section and a validity banner, so it now overflows on short windows where it
        // previously fit. `.scrollBounceBehavior(.basedOnSize)` keeps it feeling static when it
        // does fit; `minHeight` preserves the existing vertical distribution.
        GeometryReader { geo in
            ScrollView(.vertical) {
                paywallContent
                    .frame(minHeight: geo.size.height - AuthGateView.focusRingInset * 2)
                    // The code field and the student-email field both live here, and both
                    // showed a clipped focus ring against the scroll edge.
                    .padding(AuthGateView.focusRingInset)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var paywallContent: some View {
        VStack(spacing: 0) {
            HStack {
                // Once checkout is initiated, strip the Back control so the paywall can't be
                // dismissed mid-payment — a protective layer against abandoning an in-flight sub.
                if !authVM.checkoutStarted {
                    Button {
                        // Leaving deliberately discards the attempt. The SUCCESS path doesn't
                        // come through here — it dismisses via `.onChange(of: state)` — so the
                        // confirmation banner still survives to reach the profile sheet.
                        authVM.resetGiftEntry()
                        onBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left").font(.callout)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 22)
            .padding([.top, .leading], 14)

            VStack(spacing: 8) {
                Image(systemName: "crown.fill").font(.system(size: 34)).foregroundStyle(.yellow)
                Text("Catalyst Pro — Yours for Good").font(.title.bold())
                Text("One payment. Every future update. No subscription.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 2).padding(.bottom, 22)

            if authVM.checkoutStarted { pending } else { chooser }

            Spacer(minLength: 0)
        }
        // Entering the paywall is a fresh attempt: an old code and an old rejection from a
        // previous visit are noise, not context.
        .onAppear { authVM.resetCheckout(); authVM.resetGiftEntry(); Telemetry.log(.paywallShown(context: context)) }
        // Re-resolve on appear so the terms shown are current. Entitlement is otherwise only
        // refreshed on app-foreground or the 4h backstop, which meant the paywall could sit
        // there quoting a student price whose verification had since lapsed — and the user
        // would only discover it when checkout was rejected.
        .task { await authVM.refreshPurchaseTerms() }
        // Pre-load any saved billing details so a returning buyer sees a filled form rather
        // than being asked for the same address twice.
        .task { authVM.loadBillingProfile() }
        .onChange(of: authVM.state) { st in
            if case .entitled(let plan, _) = st, plan == "pro" { onBack() }
        }
        .sheet(isPresented: $showBillingSheet) {
            BillingDetailsSheet(authVM: authVM, isStudent: isStudent) {
                showBillingSheet = false
                // Only now does checkout open. Chained on the SAVE succeeding, so a payment can
                // never exist without the buyer record the invoice will be built from.
                authVM.buyLicense(tier: isStudent ? .student : .standard)
            }
        }
    }

    private var chooser: some View {
        // Eligible students see only their (lower) price — showing both would invite the
        // question "why am I being offered the expensive one?"
        let price = isStudent ? studentPriceMajor : priceMajor

        return VStack(spacing: 12) {
            // Validity banner sits ABOVE the price, because it qualifies the price: this number
            // is only yours until the date shown. Buried as a caption inside the card it read as
            // fine print; the user should see the condition before the offer.
            if isStudent { studentValidityBanner }

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(money(price)).font(.system(size: 40, weight: .bold))
                    Text("once").font(.callout).foregroundStyle(.secondary)
                }
                // Student pricing is THE price for an eligible user — shown here as the hero,
                // never alongside the standard price as a second option to weigh up.
                if isStudent {
                    // Only claim a discount when there actually is one: under test pricing the
                    // tiers are equal and "50% off · ₹2 standard" would read as a bug.
                    if studentPriceMajor < priceMajor {
                        Text("Student price\(studentDiscountPct > 0 ? " · \(studentDiscountPct)% off" : "") · \(money(priceMajor)) standard")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Text("Student price").font(.caption).foregroundStyle(.green)
                    }
                }
                Text("Lifetime licence — every future version included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .cardStyle()

            if let err = authVM.subscribeError {
                StatusBanner(icon: "exclamationmark.triangle.fill", tint: .orange, text: err)
                    .padding(.top, 2)
            }

            // Details are collected BEFORE money moves — the universal pattern, and the only
            // ordering that lets the invoice be issued the instant payment settles. It also
            // pre-fills Razorpay's own customer fields, so the buyer isn't asked twice.
            Button { showBillingSheet = true } label: {
                HStack(spacing: 8) {
                    if authVM.subscribing { ProgressView().controlSize(.small) }
                    Text(authVM.subscribing ? "Starting…" : "Buy Catalyst Pro").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(authVM.subscribing)
            .padding(.top, 6)

            Text("Secure checkout via Razorpay — opens in your browser.")
                .font(.caption2).foregroundStyle(.secondary)

            // Student discount (P12): buy if eligible, else verify a school email. INR only.
            studentSection

            // A comp is an alternative to paying, so the entry point belongs beside the price —
            // not buried in the profile where someone holding a code would never look.
            Divider().opacity(0.4).padding(.vertical, 2)
            GiftRedeemSection(authVM: authVM)
        }
        .padding(.horizontal, 24)
        // Bottom inset. This section is the LAST thing in the paywall and it grows downward —
        // an inline error under the code field had nothing beneath it and sat flush against the
        // sheet edge. Sized to clear the tallest case (a two-line error), not the empty one.
        .padding(.bottom, 22)
    }

    /// Discount actually implied by the two prices — never a hardcoded number, so it can't drift
    /// out of step with what the user is charged. 0 when the tiers are equal (test pricing).
    private var studentDiscountPct: Int {
        guard priceMajor > 0, studentPriceMajor < priceMajor else { return 0 }
        return Int(((Double(priceMajor - studentPriceMajor) / Double(priceMajor)) * 100).rounded())
    }

    /// "Student verification valid until <date>" — the condition attached to the price below.
    ///
    /// Renders nothing when there's no deadline: a user whose PRIMARY email is academic is
    /// eligible by domain and never expires, so inventing an end date would be a lie. Turns
    /// amber inside the last 30 days so the deadline stops being background information.
    /// Date → "20 Jul 2027". Lives OUTSIDE the `@ViewBuilder` on purpose: a `@ViewBuilder`
    /// treats every statement as a view, so a bare `f.dateStyle = .medium` there is an
    /// expression of type `()` and fails with "Type '()' cannot conform to 'View'".
    // `shortRef` lived here to middle-elide a 32-char hex id. Removed: reference ids are now
    // generated SHORT server-side (`refId` → TAPC-L-XXXX-XXXX), so the full value fits at the
    // normal row font. Eliding a support handle hid exactly the characters a payment dispute
    // turns on — the fix belonged at the source, not in the view.

    private func mediumDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    @ViewBuilder private var studentValidityBanner: some View {
        if let until = authVM.studentValidUntil {
            let days = authVM.studentDaysLeft ?? 0
            let urgent = days <= 30
            let tint: Color = urgent ? .orange : .green

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: urgent ? "exclamationmark.circle.fill" : "graduationcap.fill")
                    .font(.callout)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Student verification valid until \(mediumDate(until))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("After that, standard pricing applies unless you verify your school email again.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.30), lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

    /// School-email verification, shown ONLY to users who aren't already eligible.
    ///
    /// There is deliberately no second "buy at the student price" button here. When a user IS
    /// eligible the hero above already shows the student price, and the primary Buy button
    /// already purchases `.student` — a duplicate card offered the same purchase twice and,
    /// worse, sat directly beneath a hero quoting a different number, which read as two
    /// competing offers rather than one price.
    @ViewBuilder private var studentSection: some View {
        if !authVM.studentEligible {
            Divider().padding(.vertical, 6)
            studentVerifyCard
        }
    }

    /// Split into small sub-views on purpose. As one expression this hit
    /// "The compiler is unable to type-check this expression in reasonable time" — SwiftUI's
    /// type inference cost grows non-linearly with nesting, and this had a conditional header,
    /// a two-branch body and a conditional banner in a single `VStack`.
    private var studentVerifyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            studentVerifyHeader

            if authVM.studentVerifyStage == .idle {
                studentVerifyEmailStep
            } else {
                studentVerifyCodeStep
            }

            if let err = authVM.studentVerifyError {
                StatusBanner(icon: "exclamationmark.triangle.fill", tint: .orange, text: err)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1))
    }

    private var studentVerifyHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill")
                .font(.headline).foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(studentDiscountPct > 0 ? "Student? Get \(studentDiscountPct)% off" : "Student pricing")
                    .font(.subheadline.weight(.semibold))
                Text("Verify your school email — \(money(studentPriceMajor)) once")
                    .font(.caption2).foregroundStyle(.secondary)
                // Someone whose verification has LAPSED lands here (eligibility went false),
                // so say why rather than showing a bare "verify" prompt they've seen before.
                if authVM.studentDaysLeft == 0 {
                    Text("Your previous verification expired — verify again to claim it.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    /// The INVERSE of the sign-in rule: this address must be academic, because it's the thing
    /// that proves student status.
    private var studentEmailError: String? { Validators.studentEmail(authVM.studentVerifyEmail) }

    private var studentVerifyEmailStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("you@university.edu", text: $authVM.studentVerifyEmail)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if studentEmailError == nil { authVM.studentVerifySendCode() } }
                Button { authVM.studentVerifySendCode() } label: {
                    if authVM.studentVerifyBusy { ProgressView().controlSize(.small) } else { Text("Send code") }
                }
                .buttonStyle(.bordered)
                .disabled(authVM.studentVerifyBusy || studentEmailError != nil)
            }

            // Same inline pattern as the venv sheet — shown only once the field is non-empty.
            if let studentEmailError,
               !authVM.studentVerifyEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(studentEmailError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    private var studentVerifyCodeStep: some View {
        VStack(spacing: 10) {
            // Same six-box control as sign-in — one OTP interaction across the app.
            OTPCodeField(code: $authVM.studentVerifyCode,
                         disabled: authVM.studentVerifyBusy) {
                authVM.studentVerifyConfirm()
            }

            Button { authVM.studentVerifyConfirm() } label: {
                Group {
                    if authVM.studentVerifyBusy { ProgressView().controlSize(.small) }
                    else { Text("Verify") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(authVM.studentVerifyBusy || authVM.studentVerifyCode.count < 6)

            HStack(spacing: 14) {
                Button("Resend") { authVM.studentVerifySendCode() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                Button("Change email") { authVM.resetStudentVerify() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // `planCard` lived here to render the monthly/yearly chooser. With a single perpetual
    // licence there is nothing to choose between, so it and its `selected` state are gone.

    private var pending: some View {
        VStack(spacing: 16) {
            if authVM.checkoutTimedOut {
                Image(systemName: "exclamationmark.circle").font(.system(size: 34)).foregroundStyle(.orange)
                Text("Payment not confirmed").font(.headline)
                Text("If you completed payment, tap Check now. If it failed or you cancelled, go back and try again.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.large)
                Text("Waiting for payment confirmation…").font(.headline)
                Text("Finish checkout in your browser — this updates automatically once your payment is confirmed.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Check now") { authVM.recheckCheckout() }
                .buttonStyle(.bordered).controlSize(.large)
            // While a payment is in flight, only ever REOPEN the same checkout — never drop back to
            // the picker, which would create a second Razorpay subscription. Once the poll window
            // has elapsed (payment likely failed/cancelled), allow a genuine restart.
            if authVM.checkoutTimedOut {
                Button("Back to plans") { authVM.resetCheckout() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Reopen checkout") { authVM.reopenCheckout() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 40)
        .animation(.easeInOut(duration: 0.2), value: authVM.checkoutTimedOut)
    }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
