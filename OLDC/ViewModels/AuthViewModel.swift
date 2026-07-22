import Foundation
import SwiftUI
import Combine
import AppKit

/// Drives the auth gate. The app is locked until `state` is `.entitled`.
///
/// Flow (all in-app, no browser): launch → `bootstrap()` (restore Keychain session →
/// verify entitlement, offline fallback to the cached signed JWT). Sign in: enter email →
/// `sendCode()` emails a 6-digit code → enter it → `submitCode()` verifies, stores the
/// refresh token, **auto-starts the 5-day trial**, and resolves entitlement.
@MainActor
final class AuthViewModel: ObservableObject {
    enum State: Equatable {
        case checking
        case enterEmail
        case enterCode(email: String, devCode: String?)   // devCode shown pre-Resend
        case entitled(plan: String, daysLeft: Int)
        // Why the app is locked → drives the gate's headline/tone. `.trialEnded` (used up their
        // own trial), `.resubscribe` (previously paid, sub lapsed → "welcome back"), or
        // `.deviceTrialed` (a fresh account on a Mac that already spent its one free trial —
        // this account never had a trial to "end", so we say that honestly + goofily).
        enum LockKind: Equatable { case trialEnded, resubscribe, deviceTrialed }
        case locked(reason: String, kind: LockKind)
        // Single-seat: account is active on another Mac. `releaseToken` moves the seat here;
        // `remaining` = releases left in the rolling window (for the "used up" messaging).
        case deviceLimited(email: String, releaseToken: String, remaining: Int)

        var isEntitled: Bool { if case .entitled = self { return true } else { return false } }
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var entitlement: Entitlement?
    /// The verified account email — persisted so the profile sheet can show it across launches.
    @Published private(set) var accountEmail: String? = UserDefaults.standard.string(forKey: "auth.email")

    /// One free trial per Mac (hardware-bound server rule). Persisted per-Mac: once the server
    /// tells us this computer already spent its trial, we remember it so the locked gate stays
    /// honest across relaunches instead of falling back to the misleading "your trial has ended".
    private let deviceTrialedKey = "trial.deviceAlreadyUsed"
    private var deviceAlreadyTrialed: Bool {
        get { UserDefaults.standard.bool(forKey: deviceTrialedKey) }
        set { UserDefaults.standard.set(newValue, forKey: deviceTrialedKey) }
    }

    // Bound to the text fields.
    @Published var email = ""
    @Published var code = ""
    @Published private(set) var busy = false
    @Published var errorText: String?

    // Subscription checkout (paywall).
    @Published private(set) var subscribing = false
    @Published var subscribeError: String?
    @Published private(set) var checkoutStarted = false   // true once the browser checkout opened
    @Published private(set) var checkoutURL: String?       // the in-flight checkout — reopen it, never spawn a 2nd sub
    @Published private(set) var checkoutTimedOut = false   // poll window elapsed without a Pro flip
    @Published private(set) var restoring = false          // Restore purchases in progress (shows a spinner)

    /// A prominent status banner for manage/cancel actions (shown full-width in the profile sheet).
    enum ManageBanner: Equatable {
        case working(String)   // in progress (spinner)
        case success(String)   // completed OK
        case failure(String)   // something went wrong
    }
    @Published var manageBanner: ManageBanner?
    /// Set when a cancellation completes → drives a one-shot confirmation alert in the profile sheet.
    @Published var cancelDoneMessage: String?

    /// True when the active Pro subscription is scheduled to end (cancelled, but still in the paid period).
    var subscriptionWillCancel: Bool { entitlement?.willCancel ?? false }

    /// "Monthly" / "Yearly" / "Student" / "Complimentary" for an active paid plan, else nil.
    ///
    /// "Complimentary" is the chosen word for comped access: it's accurate for both a capped and
    /// a perpetual comp, and unlike "Limited" or "Trial" it doesn't imply a reduced product —
    /// a comp is the full licence. The *duration* is carried by the badge and banner, not here.
    var billingIntervalLabel: String? {
        switch entitlement?.interval {
        case "monthly": return "Monthly"
        case "yearly":  return "Yearly"
        case "student": return "Student"
        case "comp":    return "Complimentary"
        default:        return nil
        }
    }

    // MARK: Comped access

    /// True when Pro is backed by a comped grant (gift code), capped or perpetual.
    var isCompPro: Bool {
        if case .entitled(let p, _) = state, p == "pro" { return entitlement?.interval == "comp" }
        return false
    }

    /// True for a comp that never lapses. Gate on `isCompPro` first — a nil `compExpiresAt`
    /// means "no deadline" only once we already know this IS a comp.
    var isPerpetualComp: Bool { isCompPro && entitlement?.compExpiresAt == nil }

    /// The exact date comped access ends, or nil when it doesn't. nil for non-comp plans too.
    var compValidUntil: Date? {
        guard isCompPro else { return nil }
        return entitlement?.compExpiresAt.map { Date(timeIntervalSince1970: $0) }
    }

    /// Whole days of comped access remaining; nil when there's no deadline or this isn't a comp.
    var compDaysLeft: Int? {
        guard isCompPro, let until = entitlement?.compExpiresAt else { return nil }
        let secs = until - Date().timeIntervalSince1970
        return secs > 0 ? max(1, Int(ceil(secs / 86400))) : 0
    }

    /// Warn inside the last 15 days — one grant unit, so every comp gets a full unit of notice
    /// no matter how short it was. Grants are sold in 15-day multiples, so this threshold can
    /// never be longer than the grant itself.
    static let compWarningWindowDays = 15

    /// True when the comp is close enough to lapsing that the profile should warn.
    var compExpiringSoon: Bool {
        guard let d = compDaysLeft else { return false }
        return d <= Self.compWarningWindowDays
    }

    // MARK: Gift redemption

    @Published var giftCodeInput: String = ""
    @Published var giftBanner: ManageBanner?
    @Published var redeemingGift: Bool = false

    /// Inline reason the entered code is unusable, or nil when it's well-formed.
    var giftCodeError: String? {
        giftCodeInput.isEmpty ? nil : BillingValidators.giftCode(giftCodeInput)
    }
    var isGiftCodeValid: Bool {
        !giftCodeInput.isEmpty && BillingValidators.giftCode(giftCodeInput) == nil
    }

    func redeemGiftCode() {
        guard isGiftCodeValid, !redeemingGift else { return }
        let code = BillingValidators.normalizeGiftCode(giftCodeInput)
        redeemingGift = true
        giftBanner = .working("Redeeming…")
        Task {
            defer { redeemingGift = false }
            guard let rt = await auth.loadRefresh() else {
                giftBanner = .failure("You're signed out. Sign in and try again.")
                return
            }
            do {
                let result = try await auth.redeemGift(code: code, refresh: rt)
                giftCodeInput = ""
                if let exp = result.expiresAt {
                    let f = DateFormatter(); f.dateStyle = .medium
                    giftBanner = .success("Redeemed — Pro until \(f.string(from: Date(timeIntervalSince1970: exp))).")
                } else {
                    giftBanner = .success("Redeemed — you now have a lifetime licence.")
                }
                // Re-read entitlement so the badge, validity row and paywall dismissal all
                // reflect the new grant immediately rather than waiting for the next 4-hourly poll.
                //
                // `resolveEntitlement`, NOT `recheckEntitlement`: the latter opens with
                // `guard state.isEntitled`, so from a LOCKED paywall (trial ended) it returns
                // without doing anything. That is precisely when a code is most likely to be
                // redeemed — the user would see "Redeemed", stay blocked, and have no way to
                // tell that the grant had in fact been created.
                await resolveEntitlement(refresh: rt)
            } catch {
                giftBanner = .failure(Self.giftErrorMessage(error))
            }
        }
    }

    /// Map server errors to copy. `invalid_code` covers "no such code" AND "already used up" —
    /// the server merges them to avoid handing out an enumeration oracle, so the app must NOT
    /// try to guess which one happened.
    private static func giftErrorMessage(_ error: Error) -> String {
        guard case AuthError.server(let code) = error else {
            return "Couldn't reach the server. Check your connection and try again."
        }
        switch code {
        case "invalid_code":     return "That code isn't valid, or it's already been used."
        case "already_redeemed": return "You've already redeemed this code."
        case "already_entitled": return "You already have a lifetime licence — no code needed."
        case "code_required":    return "Enter a code."
        // Both routes to Pro are open at once. Say which one to close, rather than a generic
        // refusal the user can't act on — the code is untouched and still redeemable after.
        case "checkout_in_progress":
            return "You have a purchase in progress. Finish or cancel that checkout first — your code is still valid."
        default:                 return "Couldn't redeem that code. Try again."
        }
    }

    func dismissGiftBanner() { giftBanner = nil }

    // MARK: Billing details (collected BEFORE payment)

    @Published var billing = BillingProfile()
    @Published var billingBanner: ManageBanner?
    @Published var savingBilling: Bool = false
    /// Set once the profile has been loaded/saved for THIS account, so the paywall knows
    /// whether to show the details form or go straight to checkout.
    @Published var billingReady: Bool = false

    var billingNameError: String?   { billing.name.isEmpty  ? nil : BillingValidators.name(billing.name) }
    var billingEmailError: String?  { billing.email.isEmpty ? nil : BillingValidators.email(billing.email) }
    // Empty → no error YET, matching every other field: an untouched form shouldn't pre-scold.
    // `isBillingValid` below runs the raw validator, so untouched still means "can't continue".
    var billingPhoneError: String?  { billing.phone.isEmpty ? nil : BillingValidators.phone(billing.phone) }
    var billingLine1Error: String?  { billing.line1.isEmpty ? nil : BillingValidators.line1(billing.line1) }
    var billingCityError: String?   { billing.city.isEmpty  ? nil : BillingValidators.city(billing.city) }
    var billingPostalError: String? {
        billing.postalCode.isEmpty ? nil : BillingValidators.postalCode(billing.postalCode, country: billing.country)
    }

    /// Every required rule must pass — evaluated against the RAW values, not the "empty means
    /// no error yet" display variants above, so an untouched form is invalid rather than valid.
    var isBillingValid: Bool {
        BillingValidators.name(billing.name) == nil
        && BillingValidators.email(billing.email) == nil
        && BillingValidators.phone(billing.phone) == nil
        && BillingValidators.line1(billing.line1) == nil
        && BillingValidators.city(billing.city) == nil
        && BillingValidators.postalCode(billing.postalCode, country: billing.country) == nil
        && BillingValidators.country(billing.country) == nil
    }

    /// Pre-fill from the server, falling back to the account email so the commonest field is
    /// already filled. Safe to call repeatedly.
    func loadBillingProfile() {
        Task {
            guard let rt = await auth.loadRefresh() else { return }
            if let saved = try? await auth.fetchBillingProfile(refresh: rt) {
                billing = saved
            } else if billing.email.isEmpty {
                billing.email = accountEmail ?? entitlement?.email ?? ""
            }
            billingReady = true
        }
    }

    /// Persist before opening checkout. Returns true on success so the caller can chain into
    /// `startCheckout` only when the details actually landed — otherwise a failed save would
    /// produce a payment with no buyer record, which is the one ordering that can't be repaired
    /// after the fact.
    @discardableResult
    func saveBillingProfile() async -> Bool {
        guard isBillingValid, !savingBilling else { return false }
        savingBilling = true
        billingBanner = .working("Saving your details…")
        defer { savingBilling = false }
        guard let rt = await auth.loadRefresh() else {
            billingBanner = .failure("You're signed out. Sign in and try again.")
            return false
        }
        do {
            var trimmed = billing
            trimmed.name = BillingValidators.clean(billing.name)
            trimmed.email = BillingValidators.clean(billing.email)
            trimmed.phone = BillingValidators.clean(billing.phone)
            trimmed.line1 = BillingValidators.clean(billing.line1)
            trimmed.line2 = BillingValidators.clean(billing.line2)
            trimmed.city = BillingValidators.clean(billing.city)
            trimmed.state = BillingValidators.clean(billing.state)
            trimmed.postalCode = BillingValidators.clean(billing.postalCode)
            trimmed.country = BillingValidators.clean(billing.country).uppercased()
            try await auth.saveBillingProfile(trimmed, refresh: rt)
            billing = trimmed
            billingBanner = nil
            return true
        } catch {
            billingBanner = .failure("Couldn't save your details. Check your connection and try again.")
            return false
        }
    }

    func dismissBillingBanner() { billingBanner = nil }

    // MARK: Invoice

    /// Invoice id for the licence currently held, if one has been issued.
    var invoiceId: String? { entitlement?.invoiceId }

    @Published var invoiceBanner: ManageBanner?
    @Published var downloadingInvoice: Bool = false

    /// Download the PDF straight to ~/Downloads rather than previewing it in-app. A one-page
    /// receipt is something people file or forward, not something they read on screen — and an
    /// in-app viewer would need a PDF surface that earns nothing else.
    func downloadInvoice() {
        guard let id = invoiceId, !downloadingInvoice else { return }
        downloadingInvoice = true
        invoiceBanner = .working("Preparing your invoice…")
        Task {
            defer { downloadingInvoice = false }
            guard let rt = await auth.loadRefresh() else {
                invoiceBanner = .failure("You're signed out. Sign in and try again.")
                return
            }
            do {
                // FETCH first, RENDER second. `ImageRenderer` is @MainActor, so the render is
                // main-thread work — it must never be handed a task that also waits on the
                // network, or the window freezes for the duration of the request.
                let invoice = try await auth.fetchInvoice(id: id, refresh: rt)
                guard let pdf = InvoiceDocument.renderPDF(data: invoice) else {
                    invoiceBanner = .failure("Couldn't generate the invoice PDF.")
                    return
                }
                let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let url = dir.appendingPathComponent("\(invoice.id).pdf")
                // Off the main actor. This whole VM is @MainActor, so `Task { }` inherits it and
                // a synchronous `write(to:)` blocks the UI for as long as the disk takes. Small
                // file, usually invisible — but "usually" is doing the work there: an atomic
                // write to a slow or network-mounted Downloads folder stalls the window.
                // The RENDER above must stay on main (ImageRenderer is @MainActor); the write
                // has no such requirement.
                try await Task.detached(priority: .userInitiated) {
                    try pdf.write(to: url, options: .atomic)
                }.value
                invoiceBanner = .success("Saved to Downloads.")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                invoiceBanner = .failure("Couldn't download the invoice. Try again.")
            }
        }
    }

    func dismissInvoiceBanner() { invoiceBanner = nil }

    /// True when the signed-in academic email can buy the discounted student plan (not already Pro).
    var studentEligible: Bool { entitlement?.studentEligible ?? false }

    /// Days left to claim the academic rate, or nil when there's no deadline.
    ///
    /// nil covers two genuinely different cases the UI must not conflate: not eligible at all,
    /// and eligible-forever (academic primary email — no verification date, so nothing expires).
    /// Callers should gate on `studentEligible` first, then treat nil as "no deadline".
    ///
    /// This clock is INDEPENDENT of the trial. A trial ending doesn't shorten it, and the app
    /// being gated doesn't hide it — someone who let the trial lapse can still buy at the
    /// student price for as long as their verification is valid.
    var studentDaysLeft: Int? {
        guard let until = entitlement?.studentEligibleUntil else { return nil }
        let secs = until - Date().timeIntervalSince1970
        return secs > 0 ? max(1, Int(ceil(secs / 86400))) : 0
    }

    /// The exact date the academic rate lapses, for "valid until <date>" copy. nil when there's
    /// no deadline (academic primary email) or the user isn't eligible.
    var studentValidUntil: Date? {
        entitlement?.studentEligibleUntil.map { Date(timeIntervalSince1970: $0) }
    }

    /// True when Pro comes from a one-time student grant (not a cancellable subscription).
    var isStudentPro: Bool {
        if case .entitled(let p, _) = state, p == "pro" { return entitlement?.interval == "student" }
        return false
    }
    /// The verified academic email attached to this account, if any.
    var studentEmail: String? { entitlement?.studentEmail }

    /// Razorpay subscription id for an active recurring sub — surfaced in the profile as a
    /// support handle. Nil for trials, one-time student grants, and offline/cached sessions.
    var subscriptionId: String? { entitlement?.subscriptionId }

    /// One-time grant id (student / gift) — surfaced in the profile as a support handle.
    /// Nil for subscriptions, trials, and offline/cached sessions.
    var grantId: String? { entitlement?.grantId }

    private let auth = AuthService.shared

    // MARK: Launch

    func bootstrap() async {
        state = .checking
        guard let refresh = await auth.loadRefresh() else { state = .enterEmail; return }
        await resolveEntitlement(refresh: refresh)
    }

    // MARK: Live re-check (multi-device eviction + renewal reflection)

    /// Background monitor: while the app is open and entitled, re-check entitlement so a seat
    /// taken on another Mac (single-seat eviction) or a subscription renewal/lapse is reflected
    /// without waiting for a cold launch. Idempotent; cancelled on sign-out/eviction.
    ///
    /// **Cadence is deliberately coarse (4h, was 60s).** This timer is a *backstop*, not the
    /// primary path: app-foreground already triggers an immediate `recheckEntitlement()`, which
    /// covers the realistic cases (open the lid, come back to the app). At 60s a single user
    /// left with the app open generated ~480 requests/day, which alone capped the whole product
    /// at roughly 200 daily active users on Cloudflare's free tier — an infrastructure ceiling
    /// set by a polling constant rather than by demand.
    ///
    /// 4h fires ~twice in a working day, keeps account-sharing impractical, and costs ~2
    /// requests/user/day. Going longer buys nothing measurable: the gap between 1h and 6h is
    /// under 7 requests/user/day, while anything beyond ~8h effectively never fires at all
    /// (few people keep a Mac app open that long continuously) — which would silently delete
    /// the backstop while leaving code that claims to provide it.
    private static let monitorInterval: Duration = .seconds(4 * 60 * 60)

    private var monitorTask: Task<Void, Never>?

    func startEntitlementMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.monitorInterval)
                guard let self, !Task.isCancelled else { return }
                await self.recheckEntitlement()
            }
        }
    }

    func stopEntitlementMonitor() { monitorTask?.cancel(); monitorTask = nil }

    /// One bounded (≤8s) entitlement re-check, used by the 4h monitor and on app-foreground.
    /// Only acts while entitled, so it never interrupts sign-in. An authoritative eviction
    /// (`device_released`) or a rejected token locks the app gracefully with a reason; an
    /// offline/transient failure keeps the current cached-JWT state and retries next tick
    /// (satisfies the "fast, self-resolving, no long waits" requirement).
    /// Refresh the terms the paywall is quoting (price tier, student eligibility, its deadline).
    ///
    /// Deliberately NOT `recheckEntitlement()`: that one early-returns unless `state.isEntitled`,
    /// so it does nothing on the locked/gated screen — which is precisely where a stale student
    /// price is most likely to be sitting, since a gated user may have had the paywall open for
    /// a long time. This only needs a signed-in session, not an active entitlement.
    func refreshPurchaseTerms() async {
        guard let rt = await auth.loadRefresh() else { return }
        await resolveEntitlement(refresh: rt)
    }

    func recheckEntitlement() async {
        guard state.isEntitled, let rt = await auth.loadRefresh() else { return }
        do {
            let ent = try await Self.withTimeout(seconds: 8) { [auth] in try await auth.fetchEntitlement(refresh: rt) }
            apply(ent)
        } catch AuthError.deviceReleased {
            await signOutAfterEviction(
                "You were signed out here because your Catalyst account was opened on another Mac. Sign in again to move it back to this Mac.")
        } catch AuthError.unauthorized {
            await signOutAfterEviction("Your session expired. Please sign in again.")
        } catch {
            // Offline / transient — keep the current (cached-JWT) state; the next tick retries.
        }
    }

    /// Local sign-out triggered by the server (seat moved / token rejected). The server already
    /// revoked the token, so we just clear locally, stop the monitor, and return to the sign-in
    /// step with an explanation. Re-entering email → the single-seat `.deviceLimited` screen lets
    /// the user re-take the seat.
    private func signOutAfterEviction(_ message: String) async {
        stopEntitlementMonitor()
        await auth.clear()
        // Same full wipe as a manual sign-out. This path matters MORE, not less: the seat was
        // taken by someone else, so whoever signs in next is likely a different person — leaking
        // the previous account's state here would show them another user's status.
        clearAccountState()
        state = .enterEmail
        errorText = message   // set AFTER the wipe; this one is meant to survive
    }

    /// Race an async operation against a timeout so a slow/hung network never blocks a re-check
    /// (or launch) past a few seconds — falls through to the caller's offline handling.
    private static func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw AuthError.network }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Sign-in (email → code)

    func sendCode() {
        let addr = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard addr.contains("@"), addr.count >= 5 else { errorText = "Enter a valid email address."; return }
        busy = true; errorText = nil
        Task {
            do {
                let dev = try await auth.requestEmailCode(email: addr)
                code = ""
                state = .enterCode(email: addr, devCode: dev)
            } catch AuthError.server(code: "email_reserved_student") {
                errorText = "This is a school email already linked to another Catalyst account for the student discount. Sign in with your personal email instead."
            } catch AuthError.server(code: "academic_email_not_primary") {
                // NOT framed as "invalid email" — the address is perfectly valid, we're
                // protecting the user from a future lockout. Say why, and make clear the
                // student discount isn't being taken away, just moved one step later.
                errorText = "We'd love you to stick around for good — so let's not use your school email here. Universities switch those off after you graduate, and your Catalyst licence is yours for life. Sign up with a personal email you'll always have, then add your school email from your profile to claim the student discount. 🎓"
            } catch AuthError.server(code: "rate_limited") {
                errorText = "Too many attempts. Please wait a bit and try again."
            } catch {
                errorText = "Couldn't send the code. Please try again."
            }
            busy = false
        }
    }

    func submitCode() {
        guard case .enterCode(let addr, _) = state else { return }
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.count == 6 else { errorText = "Enter the 6-digit code."; return }
        busy = true; errorText = nil
        Task {
            do {
                let refresh = try await auth.verifyEmailCode(email: addr, code: c)
                await auth.saveRefresh(refresh)
                accountEmail = addr
                UserDefaults.standard.set(addr, forKey: "auth.email")
                Telemetry.log(.signInCompleted)
                if await auth.startTrial(refresh: refresh) { deviceAlreadyTrialed = true }   // first sign-in → trial begins (or Mac already used it)
                await resolveEntitlement(refresh: refresh)
            } catch AuthError.deviceLimited(let token, let remaining) {
                // Account is already active on another Mac — offer to move the seat here.
                state = .deviceLimited(email: addr, releaseToken: token, remaining: remaining)
                busy = false
            } catch {
                errorText = "That code is incorrect or has expired."
                busy = false
            }
        }
    }

    /// From the `.deviceLimited` screen: release the other Mac and sign in here (capped server-side).
    func releaseThisDevice() {
        guard case .deviceLimited(let addr, let token, _) = state else { return }
        busy = true; errorText = nil
        Task {
            do {
                let refresh = try await auth.releaseDevice(releaseToken: token)
                await auth.saveRefresh(refresh)
                accountEmail = addr
                UserDefaults.standard.set(addr, forKey: "auth.email")
                Telemetry.log(.signInCompleted)
                if await auth.startTrial(refresh: refresh) { deviceAlreadyTrialed = true }
                await resolveEntitlement(refresh: refresh)
            } catch AuthError.server(code: "delink_cap_reached") {
                errorText = "You've switched Macs too many times recently. Please try again later or contact support."
                busy = false
            } catch {
                errorText = "Couldn't move your account to this Mac. Please try again."
                busy = false
            }
        }
    }

    /// Re-send the code to the same address.
    func resendCode() {
        if case .enterCode(let addr, _) = state { email = addr; sendCode() }
    }

    /// Go back to the email step.
    func changeEmail() {
        code = ""; errorText = nil
        state = .enterEmail
    }

    // MARK: Session

    func refresh() {
        Task {
            guard let rt = await auth.loadRefresh() else { state = .enterEmail; return }
            await resolveEntitlement(refresh: rt)
        }
    }

    /// Wipe every piece of per-ACCOUNT state.
    ///
    /// This view model is long-lived — it survives sign-out and is reused by the next account
    /// signing in on the same Mac. Anything not cleared here leaks across that boundary and is
    /// shown to a different person as if it were theirs. That's how a stale
    /// "This school email is already linked to another Catalyst account" banner greeted a
    /// freshly signed-in user who had done nothing: `signOut()` cleared five fields and left
    /// the student-verify, checkout and banner state untouched.
    ///
    /// Rule: if a `@Published` property describes the signed-in ACCOUNT rather than the app,
    /// it belongs in here.
    private func clearAccountState() {
        // Sign-in form
        email = ""; code = ""; errorText = nil
        // Entitlement / identity
        entitlement = nil; accountEmail = nil
        // Checkout
        subscribeError = nil; checkoutStarted = false; checkoutURL = nil; checkoutTimedOut = false
        // Student verification — the leak that surfaced this
        resetStudentVerify()
        // Banners
        manageBanner = nil; cancelDoneMessage = nil
        // Gift redemption — code, in-flight flag and banner. A redemption banner surviving an
        // account switch is exactly the class of leak that surfaced this method: the next user
        // would be told THEIR code was redeemed.
        giftCodeInput = ""; giftBanner = nil; redeemingGift = false
        // Billing details. `billingReady` MUST reset too — leaving it true would let the paywall
        // skip the details form for the new account and then bill them against the previous
        // user's name and address.
        billing = BillingProfile(); billingBanner = nil; savingBilling = false; billingReady = false
        // Invoice
        invoiceBanner = nil; downloadingInvoice = false
    }

    func signOut() {
        Task {
            stopEntitlementMonitor()
            // Revoke this Mac's token server-side (keeps the seat bound to this Mac), then clear locally.
            if let rt = await auth.loadRefresh() { await auth.signOutServer(refresh: rt) }
            await auth.clear()
            clearAccountState()
            UserDefaults.standard.removeObject(forKey: "auth.email")
            state = .enterEmail
            Telemetry.log(.signedOut)
        }
    }

    func dismissManageBanner() { manageBanner = nil }

    // MARK: Paywall — perpetual licence

    /// Open Razorpay's hosted checkout for a one-time **perpetual licence**. Entitlement flips
    /// to `pro` via the webhook (with a server-side self-heal if that webhook is missed), and
    /// `startCheckoutPolling` detects the flip without the user confirming anything.
    ///
    /// There is deliberately no cancel/renew counterpart: the licence never expires, so the only
    /// billing action a user can take is buying it once.
    private var pollTask: Task<Void, Never>?

    func buyLicense(tier: AuthService.LicenseTier = .standard) {
        // One checkout path for both tiers — only the analytics event distinguishes them.
        Telemetry.log(tier == .student ? .studentPurchaseStarted
                                       : .subscribeStarted(plan: "perpetual", currency: "INR"))
        subscribing = true; subscribeError = nil
        Task {
            guard let rt = await auth.loadRefresh() else {
                subscribeError = "Please sign in again."; subscribing = false; return
            }

            // No price re-check here. The paywall already resolves on appear
            // (`refreshPurchaseTerms`), and prices change on a `wrangler deploy` — measured in
            // months, not minutes. Spending a round trip on every buy tap to guard a window
            // that narrow isn't worth it; if the number ever does move mid-session the user
            // simply pays the current price, which is the one the server quotes anyway.
            do {
                let url = try await auth.createLicenseCheckout(tier: tier, refresh: rt)
                checkoutURL = url.absoluteString
                openURL(url.absoluteString)
                checkoutStarted = true
                startCheckoutPolling()          // auto-detect the Pro flip — no button needed
            } catch AuthError.server(let code) {
                // The server rejected for a REASON. "Please try again" is wrong here — retrying
                // an ineligible or already-entitled account fails identically forever. Say what
                // happened, and re-resolve entitlement so the screen stops showing stale terms
                // (e.g. a student price whose verification lapsed while this view was open).
                switch code {
                case "not_eligible":
                    subscribeError = "Your student verification has expired — standard pricing now applies."
                case "already_entitled":
                    subscribeError = "You already have a licence on this account."
                case "price_not_configured":
                    subscribeError = "Catalyst isn't available for purchase in your region yet."
                case "razorpay_error":
                    // The payment provider rejected the request itself — retrying unchanged
                    // usually fails identically, so don't imply otherwise.
                    subscribeError = "The payment provider rejected this request. Check your billing details, or try again shortly."
                default:
                    // Surface the server's own code. The bare "try again" swallowed exactly the
                    // detail needed to tell a transient failure from a permanent one — a missing
                    // table reads identically to a flaky network, and retrying forever is the
                    // only advice it can give.
                    subscribeError = "Couldn't start checkout (\(code)). Please try again."
                }
                await resolveEntitlement(refresh: rt)
            } catch {
                subscribeError = "Couldn't start checkout. Please check your connection and try again."
            }
            subscribing = false
        }
    }

    // MARK: Student email verification (secondary academic email → eligibility)

    enum StudentVerifyStage: Equatable { case idle, code }
    @Published var studentVerifyStage: StudentVerifyStage = .idle
    @Published var studentVerifyEmail = ""
    @Published var studentVerifyCode = ""
    @Published private(set) var studentVerifyBusy = false
    @Published var studentVerifyError: String?

    /// Send a code to the claimed academic email.
    func studentVerifySendCode() {
        let addr = studentVerifyEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard addr.contains("@"), addr.count >= 5 else { studentVerifyError = "Enter your school email address."; return }
        Telemetry.log(.studentVerifyStarted)
        studentVerifyBusy = true; studentVerifyError = nil
        Task {
            guard let rt = await auth.loadRefresh() else { studentVerifyError = "Please sign in again."; studentVerifyBusy = false; return }
            do {
                _ = try await auth.studentVerifyStart(email: addr, refresh: rt)
                studentVerifyCode = ""
                studentVerifyStage = .code
            } catch AuthError.server(code: "email_already_linked") {
                studentVerifyError = "This school email is already linked to another Catalyst account. Each school email unlocks the student discount on one account only."
            } catch AuthError.server(code: "not_academic") {
                studentVerifyError = "That doesn't look like a supported school email. Use your .edu or .ac.in address."
            } catch AuthError.server(code: "rate_limited") {
                studentVerifyError = "Too many attempts. Please wait a bit and try again."
            } catch {
                studentVerifyError = "Couldn't send the code to that school email. Please try again."
            }
            studentVerifyBusy = false
        }
    }

    /// Confirm the code → attaches the academic email and refreshes eligibility.
    func studentVerifyConfirm() {
        let c = studentVerifyCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.count == 6 else { studentVerifyError = "Enter the 6-digit code."; return }
        studentVerifyBusy = true; studentVerifyError = nil
        Task {
            guard let rt = await auth.loadRefresh() else { studentVerifyError = "Please sign in again."; studentVerifyBusy = false; return }
            do {
                try await auth.studentVerifyConfirm(code: c, refresh: rt)
                Telemetry.log(.studentVerified)
                await resolveEntitlement(refresh: rt)   // studentEligible flips true → student option appears
                resetStudentVerify()
            } catch AuthError.server(code: "email_already_linked") {
                studentVerifyError = "This school email is already linked to another Catalyst account, so it can't be used for the student discount here."
            } catch AuthError.server(code: "too_many_attempts") {
                studentVerifyError = "Too many incorrect attempts. Request a new code and try again."
            } catch {
                studentVerifyError = "That code is incorrect or has expired. Please try again."
            }
            studentVerifyBusy = false
        }
    }

    func resetStudentVerify() {
        studentVerifyStage = .idle; studentVerifyEmail = ""; studentVerifyCode = ""; studentVerifyError = nil
    }

    // `subscribeStudent()` was here. It duplicated `buyLicense(tier: .student)` in full and
    // differed only in which Telemetry event it logged — now handled inside `buyLicense`, so
    // both tiers share one checkout path and can't drift apart.

    /// While the browser checkout is open, poll entitlement so the app flips to Pro the moment
    /// the webhook lands — gracefully, without any "I've paid" tap. Stops on Pro or after ~2 min.
    private func startCheckoutPolling() {
        pollTask?.cancel()
        checkoutTimedOut = false
        pollTask = Task { [weak self] in
            for _ in 0..<40 {                    // ~2 min at 3s intervals
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.checkoutStarted else { return }
                guard let rt = await self.auth.loadRefresh(),
                      let ent = try? await self.auth.fetchEntitlement(refresh: rt) else { continue }
                self.apply(ent)
                if ent.plan == "pro" { return }
            }
            // Window elapsed without a Pro flip (payment failed, abandoned, or webhook lag).
            self?.checkoutTimedOut = true
        }
    }

    /// Restore / re-check: entitlement is server-authoritative, so this recovers Pro on any
    /// device that has already paid (or after a stale/offline state).
    func restorePurchases() {
        guard !restoring else { return }
        restoring = true
        manageBanner = nil
        Task {
            guard let rt = await auth.loadRefresh() else {
                restoring = false; manageBanner = .failure("Please sign in again."); return
            }
            await resolveEntitlement(refresh: rt)
            restoring = false
            let restoredPro: Bool = { if case .entitled(let p, _) = state, p == "pro" { return true }; return false }()
            Telemetry.log(.restoreAttempted(found: restoredPro))
            if case .entitled(let plan, _) = state, plan == "pro" {
                manageBanner = .success("Purchases restored — you're on Pro.")
            } else if case .enterEmail = state {
                manageBanner = nil                       // couldn't reach server / signed out — errorText covers it
            } else if case .entitled(let plan, _) = state, plan == "trial" {
                // Nothing to restore is the NORMAL state on a trial, not a failure. The old copy
                // ("No active subscription found") was wrong twice over: it flagged an error where
                // none existed, and it named subscriptions — which Catalyst no longer sells.
                manageBanner = .success("You're on the free trial — there's no purchase to restore yet.")
            } else {
                manageBanner = .failure("No purchase found for this account. If you bought Catalyst with a different email, sign in with that one.")
            }
        }
    }

    /// Reset the paywall to the plan-picker state (on open / "back to plans").
    func resetCheckout() {
        pollTask?.cancel(); pollTask = nil
        subscribing = false; subscribeError = nil; checkoutStarted = false; checkoutTimedOut = false
        checkoutURL = nil
    }

    /// Clear the code field and its result banner.
    ///
    /// `giftBanner` lives on the view model so it survives the paywall dismissing itself on a
    /// SUCCESSFUL redemption — that confirmation has to land on the profile sheet. The cost is
    /// that a FAILED attempt outlives the screen that produced it and follows the user around,
    /// which is the leak this exists to close. Called when entering the paywall and when leaving
    /// it deliberately (Back), but NOT on the success path, where the banner is the payload.
    func resetGiftEntry() {
        giftCodeInput = ""
        giftBanner = nil
        redeemingGift = false
    }

    /// Re-open the in-flight checkout (the SAME subscription) instead of creating a second one —
    /// this is why, while a payment is pending, the paywall offers "Reopen checkout" rather than
    /// dropping back to the plan picker (which would spawn a duplicate Razorpay subscription).
    func reopenCheckout() {
        if let u = checkoutURL { openURL(u) }
    }

    /// "Check now" from the pending screen: re-check once, and if still not Pro, resume polling.
    func recheckCheckout() {
        checkoutTimedOut = false
        Task {
            guard let rt = await auth.loadRefresh() else { checkoutTimedOut = true; return }
            await resolveEntitlement(refresh: rt)
            if case .entitled(let plan, _) = state, plan == "pro" { return }
            startCheckoutPolling()
        }
    }

    // MARK: Internals

    private func resolveEntitlement(refresh: String) async {
        do {
            // Bound to ≤8s so a slow/hung network at launch can't trap the user on "Checking your
            // access…": a timeout throws `.network` → the offline cached-JWT fallback below.
            let ent = try await Self.withTimeout(seconds: 8) { [auth] in try await auth.fetchEntitlement(refresh: refresh) }
            apply(ent)
        } catch AuthError.deviceReleased {
            await signOutAfterEviction(
                "You were signed out here because your Catalyst account was opened on another Mac. Sign in again to move it back to this Mac.")
        } catch AuthError.unauthorized {
            await auth.clear()
            state = .enterEmail
        } catch {
            if let cached = await auth.cachedEntitlement(), cached.isActive {
                apply(cached)
            } else {
                errorText = "Couldn't reach the server. Check your connection."
                state = .enterEmail
            }
        }
        busy = false
    }

    private func apply(_ ent: Entitlement) {
        let wasPro: Bool = { if case .entitled(let p, _) = state, p == "pro" { return true }; return false }()
        entitlement = ent
        errorText = nil
        // Keep the shown account email fresh from the server (covers sessions created before we
        // started persisting it locally).
        if let mail = ent.email, !mail.isEmpty {
            accountEmail = mail
            UserDefaults.standard.set(mail, forKey: "auth.email")
        }
        switch ent.plan {
        case "pro":   state = .entitled(plan: "pro", daysLeft: ent.daysLeft)
        case "trial": state = .entitled(plan: "trial", daysLeft: ent.daysLeft)
        default:
            // Lapsed subscriber → "welcome back / resubscribe". Otherwise, distinguish a Mac
            // that already spent its one free trial (fresh account, never had a trial to end →
            // honest, friendly copy) from a genuine own-trial expiry.
            if ent.formerSubscriber {
                state = .locked(reason: "Your Catalyst subscription has ended.", kind: .resubscribe)
            } else if deviceAlreadyTrialed {
                state = .locked(reason: "…and this trusty Mac already cashed in its golden ticket.", kind: .deviceTrialed)
            } else {
                state = .locked(reason: "Your free trial has ended.", kind: .trialEnded)
            }
        }
        // Keep the live re-check running whenever we're entitled (started idempotently); it
        // catches a seat taken on another Mac and renewal/lapse without a relaunch.
        if state.isEntitled { startEntitlementMonitor() } else { stopEntitlementMonitor() }
        // Telemetry: refresh segmentation, and log a conversion the first time Pro is reached.
        TelemetryProfile.refresh(auth: self)
        if !wasPro, case .entitled(let p, _) = state, p == "pro" {
            Telemetry.log(.purchaseCompleted(plan: ent.interval ?? "pro"))
        }
    }

    private func openURL(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
