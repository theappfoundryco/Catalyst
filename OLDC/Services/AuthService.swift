import Foundation
import CryptoKit
import IOKit
import AppKit

/// Backend config. **Set `apiBaseURL` to the deployed Worker (`https://…workers.dev`)
/// before release.** For local dev against `wrangler dev`, use `http://localhost:8787`
/// (add an ATS exception, or prefer the deployed https URL).
enum AuthConfig {
    static let apiBaseURL = URL(string: "https://catalyst-api.shivanggulati817.workers.dev")!

    /// Ed25519 public key — the SPKI PEM body (base64). The raw 32-byte verifying key is
    /// the last 32 bytes of the decoded DER. Must match the Worker's `JWT_PRIVATE_KEY`.
    static let publicKeyPEMBody = "MCowBQYDK2VwAyEAE8DCRvga2/0F03NwwhmyWCMClJ4p3lazCiChH/fZiIg="
}

/// The verified entitlement the app trusts (parsed from the signed JWT).
struct Entitlement: Equatable {
    let plan: String        // "pro" | "trial" | "none"
    let exp: Double         // JWT expiry (offline-grace horizon)
    let entitlementEnd: Double
    let willCancel: Bool    // Pro is scheduled to end at entitlementEnd (won't renew)
    let interval: String?   // billing interval for a paid plan: "monthly" | "yearly" | "student" | nil
    var email: String?      // account email (server-provided; nil on the offline JWT path)
    var studentEligible: Bool = false   // academic email + not already entitled (server-provided)
    /// When the academic rate stops being available (epoch), or nil for "no deadline".
    /// nil is a REAL state, not missing data: an academic PRIMARY email is eligible by domain
    /// and never expires, while a verified SECONDARY email carries a one-year clock.
    var studentEligibleUntil: Double?
    /// Live licence prices in MINOR UNITS (paise/cents) plus the currency they're quoted in.
    ///
    /// Currency-agnostic on purpose: the app renders the symbol from `currency` and never a
    /// hardcoded one, so enabling a new currency is a server-side config change with NO app
    /// release. nil on the offline/cached-JWT path — callers fall back to a bundled default
    /// rather than showing a blank price.
    var priceStandardMinor: Int?
    var priceStudentMinor: Int?
    var currency: String?
    var studentEmail: String?           // verified academic email attached to this account, if any
    var subscriptionId: String?         // Razorpay subscription id while a subscription grants Pro (incl. cancelled-but-till-end); nil for trial / pure student grant / offline
    var grantId: String?                // one-time grant id (student/gift) while a grant grants Pro; nil otherwise / offline
    var formerSubscriber: Bool = false  // user has had a paid subscription before (server-provided) → show "resubscribe" gate when lapsed
    /// When comped ("complimentary") access runs out, or nil for "does not lapse".
    ///
    /// nil is a REAL state and not missing data, exactly as with `studentEligibleUntil`: a
    /// PERPETUAL comp never ends, so it has no date. Callers must gate on `interval == "comp"`
    /// first and only then read this — nil alone cannot distinguish "perpetual comp" from
    /// "not comped at all", and conflating them would either hide a real expiry warning or
    /// show a countdown to a paying customer.
    var compExpiresAt: Double?
    /// Invoice already issued for the licence backing this entitlement, if any. Surfaced in the
    /// profile as a copyable handle and as the target of the download button.
    var invoiceId: String?

    var isActive: Bool { (plan == "pro" || plan == "trial") && exp > Date().timeIntervalSince1970 }
    var daysLeft: Int { max(0, Int(ceil((entitlementEnd - Date().timeIntervalSince1970) / 86400))) }
}

enum AuthError: Error {
    case network, unauthorized, badResponse, invalidSignature, server(code: String)
    /// Single-seat: this token's device is no longer the bound one — the seat moved to another
    /// Mac. The server has revoked this refresh token (401 `device_released`); the app should
    /// sign out locally and explain why. Distinct from a plain `unauthorized`.
    case deviceReleased
    /// Single-seat licensing: this account is already active on another Mac. `releaseToken`
    /// authorizes moving the seat here (POST /auth/device/release); `remaining` is how many
    /// releases are left in the current rolling window.
    case deviceLimited(releaseToken: String, remaining: Int)
}

/// All auth I/O: device-code flow, Keychain token storage, `/entitlement` fetch, and
/// **local Ed25519 JWT verification** with the embedded public key. Server is the source
/// of truth; this only caches a short-lived signed entitlement for offline grace.
actor AuthService {
    static let shared = AuthService()
    private init() {}

    private let logger = Logger.shared
    /// Bounded on purpose. `.ephemeral`'s defaults are 60s per request and **7 days** for the
    /// resource — so a stalled connection leaves a spinner running and an action flag stuck true
    /// for a minute or more. `/entitlement` was individually wrapped in an 8s `withTimeout`, but
    /// nothing else was, which meant redeem / save-billing / fetch-invoice could each hang the
    /// affected control long past the point a user would call it broken.
    ///
    /// Set on the SESSION so every call is covered, including ones added later that forget to
    /// wrap themselves. The per-call `withTimeout` on entitlement stays — it's tighter, and it
    /// guards launch specifically.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false     // fail fast offline rather than parking the task
        return URLSession(configuration: cfg)
    }()

    // MARK: Device identity

    nonisolated func hardwareUUID() -> String {
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if expert != 0 { IOObjectRelease(expert) } }
        guard expert != 0,
              let cf = IORegistryEntryCreateCFProperty(expert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
              let uuid = cf as? String else { return "unknown-device" }
        return uuid
    }

    // MARK: In-app email code (OTP) sign-in

    /// Ask the backend to email a 6-digit code. Returns the dev-echoed code when the
    /// Worker isn't in production (so sign-in works before Resend is wired), else nil.
    func requestEmailCode(email: String) async throws -> String? {
        struct R: Decodable { let dev_code: String? }
        return try await post("/auth/email/start",
                              body: ["email": email, "device_id": hardwareUUID()],
                              decode: R.self).dev_code
    }

    /// Verify the code (+ this Mac's UUID). Returns the app refresh token on success.
    /// Throws `.deviceLimited` when the account is already bound to another Mac (single-seat).
    func verifyEmailCode(email: String, code: String) async throws -> String {
        struct R: Decodable { let refresh_token: String? }
        let r = try await post("/auth/email/verify",
                               body: ["email": email, "code": code, "device_id": hardwareUUID()],
                               decode: R.self)
        guard let rt = r.refresh_token else { throw AuthError.unauthorized }
        return rt
    }

    /// Move the single seat to THIS Mac (after `.deviceLimited`). The old Mac is signed out on
    /// its next entitlement check. Returns the new refresh token. Throws `.server("delink_cap_reached")`
    /// when the rolling release budget is used up.
    func releaseDevice(releaseToken: String) async throws -> String {
        struct R: Decodable { let refresh_token: String? }
        let r = try await post("/auth/device/release",
                               body: ["release_token": releaseToken],
                               decode: R.self)
        guard let rt = r.refresh_token else { throw AuthError.unauthorized }
        return rt
    }

    /// Server-side sign-out: revoke THIS Mac's refresh token (keeps the seat bound to this Mac).
    /// Best-effort — a network hiccup shouldn't block the local sign-out that follows.
    func signOutServer(refresh: String) async {
        _ = try? await postRaw("/auth/signout", body: nil, bearer: refresh)
    }

    /// Best-effort: signing in for the first time starts the 5-day trial.
    /// Returns `true` when the server refused because THIS Mac already spent its one
    /// free trial (403 `device_already_trialed`), so the gate can say so honestly
    /// instead of the misleading "your trial has ended" (a brand-new account here
    /// never had a trial to end). All other outcomes return `false` — the backend
    /// stays the source of truth for trial rules.
    func startTrial(refresh: String) async -> Bool {
        do {
            _ = try await postRaw("/trial/start", body: nil, bearer: refresh)
            return false
        } catch AuthError.server(code: "device_already_trialed") {
            return true
        } catch {
            return false
        }
    }

    /// Create a one-time Payment Link for a **perpetual licence**; returns the hosted checkout
    /// URL the app opens in the browser. The webhook grants Pro (forever) after payment, and
    /// `/entitlement` self-heals if that webhook is ever missed.
    ///
    /// Catalyst is sold once — there is no subscription, no renewal, and nothing to cancel.
    /// The academic tier buys the identical licence at a lower price; only `tier` differs.
    func createLicenseCheckout(tier: LicenseTier = .standard, refresh: String) async throws -> URL {
        struct R: Decodable { let checkout_url: String? }
        let r = try await post(tier.endpoint, body: nil, decode: R.self, bearer: refresh)
        guard let s = r.checkout_url, let url = URL(string: s) else { throw AuthError.badResponse }
        return url
    }

    enum LicenseTier {
        case standard, student
        var endpoint: String {
            switch self {
            case .standard: return "/license/create"
            case .student:  return "/license/student/create"
            }
        }
    }

    /// Student verification step 1: email a one-time code to a claimed academic address.
    func studentVerifyStart(email: String, refresh: String) async throws -> String? {
        struct R: Decodable { let dev_code: String? }
        return try await post("/student/verify/start", body: ["student_email": email], decode: R.self, bearer: refresh).dev_code
    }

    /// Student verification step 2: confirm the code → attaches the verified academic email.
    func studentVerifyConfirm(code: String, refresh: String) async throws {
        struct R: Decodable { let ok: Bool? }
        let r = try await post("/student/verify/confirm", body: ["code": code], decode: R.self, bearer: refresh)
        guard r.ok == true else { throw AuthError.badResponse }
    }

    // The academic tier is just `createLicenseCheckout(tier: .student)` — no wrapper, so there's
    // one checkout call site and no chance of the two drifting.

    // MARK: Entitlement

    /// Fetch a fresh signed entitlement and verify it locally. Throws `.unauthorized`
    /// when the refresh token is rejected (caller should sign out).
    func fetchEntitlement(refresh: String) async throws -> Entitlement {
        struct Resp: Decodable { let entitlement_token: String; let plan: String; let entitlement_end: Double; let will_cancel: Bool?; let billing_interval: String?; let email: String?; let student_eligible: Bool?; let student_eligible_until: Double?; let price_standard_minor: Int?; let price_student_minor: Int?; let currency: String?; let student_email: String?; let subscription_id: String?; let grant_id: String?; let former_subscriber: Bool?; let comp_expires_at: Double?; let invoice_id: String? }
        let resp = try await get("/entitlement", bearer: refresh, decode: Resp.self)
        guard let ent = verify(jwt: resp.entitlement_token) else { throw AuthError.invalidSignature }
        cacheToken(resp.entitlement_token)
        // Advance the monotonic server-clock floor (rollback defense for the offline path).
        if let iat = Self.jwtField(jwt: resp.entitlement_token, key: "iat") { bumpServerClock(iat: iat) }
        // The JWT only carries the grace `exp`; the response carries the true end date.
        return Entitlement(plan: ent.plan, exp: ent.exp, entitlementEnd: resp.entitlement_end,
                           willCancel: resp.will_cancel ?? ent.willCancel,
                           interval: resp.billing_interval ?? ent.interval,
                           email: resp.email ?? ent.email,
                           studentEligible: resp.student_eligible ?? false,
                           studentEligibleUntil: resp.student_eligible_until,
                           priceStandardMinor: resp.price_standard_minor,
                           priceStudentMinor: resp.price_student_minor,
                           currency: resp.currency,
                           studentEmail: resp.student_email,
                           subscriptionId: resp.subscription_id,
                           grantId: resp.grant_id,
                           formerSubscriber: resp.former_subscriber ?? false,
                           compExpiresAt: resp.comp_expires_at,
                           invoiceId: resp.invoice_id)
    }

    // MARK: Gift codes / comped access

    /// Redeem a gift code. Returns the resulting expiry (nil = perpetual comp).
    ///
    /// The server answers `invalid_code` for BOTH an unknown code and an exhausted one — the
    /// app must not try to tell them apart or invent a friendlier distinction, because doing so
    /// would rebuild the enumeration oracle the server deliberately closed.
    func redeemGift(code: String, refresh: String) async throws -> (expiresAt: Double?, grantId: String?) {
        struct Resp: Decodable { let ok: Bool?; let grant_id: String?; let expires_at: Double?; let perpetual: Bool? }
        let resp = try await post("/gift/redeem", body: ["code": code], decode: Resp.self, bearer: refresh)
        return (resp.expires_at, resp.grant_id)
    }

    // MARK: Billing profile / invoices

    /// Save the buyer's details BEFORE checkout. Latest-wins; the invoice snapshots these at
    /// issue time, so editing later never rewrites an already-issued document.
    func saveBillingProfile(_ p: BillingProfile, refresh: String) async throws {
        struct Resp: Decodable { let ok: Bool? }
        _ = try await post("/billing/profile", body: p.asPayload, decode: Resp.self, bearer: refresh)
    }

    /// Fetch the saved billing profile so the form pre-fills instead of asking twice.
    func fetchBillingProfile(refresh: String) async throws -> BillingProfile? {
        struct Resp: Decodable {
            let name: String?; let email: String?; let phone: String?
            let line1: String?; let line2: String?; let city: String?
            let state: String?; let postal_code: String?; let country: String?
        }
        let r = try await get("/billing/profile", bearer: refresh, decode: Resp.self)
        guard let name = r.name, let email = r.email else { return nil }
        return BillingProfile(name: name, email: email, phone: r.phone ?? "",
                              line1: r.line1 ?? "", line2: r.line2 ?? "", city: r.city ?? "",
                              state: r.state ?? "", postalCode: r.postal_code ?? "",
                              country: r.country ?? "IN")
    }

    /// Fetch invoice DATA. The PDF is rendered on-device from this (see `InvoiceDocument`) —
    /// the server is the source of truth for the numbers, not the layout.
    func fetchInvoice(id: String, refresh: String) async throws -> InvoiceData {
        try await get("/invoice/\(id)", bearer: refresh, decode: InvoiceData.self)
    }

    /// Offline path: re-verify the last cached entitlement JWT locally (checks signature
    /// + `exp`). Returns nil when absent/expired/tampered — or when the system clock has been
    /// rolled back before the last server time we trust (the one way to stretch the signed
    /// offline grace, since `exp` is otherwise checked against local time).
    func cachedEntitlement() -> Entitlement? {
        if clockRolledBack() {
            logger.log("⚠️ Cached entitlement rejected: system clock is behind the last trusted server time (rollback guard).")
            return nil
        }
        guard let jwt = loadCachedToken() else { return nil }
        return verify(jwt: jwt)
    }

    // MARK: Monotonic server-clock guard (offline rollback defense)

    /// Highest server-issued `iat` we've ever seen, persisted in the Keychain (survives app
    /// deletion, unlike UserDefaults). The offline grace trusts the JWT `exp` against LOCAL time,
    /// so without this a user could set the clock back and keep an expired entitlement alive
    /// forever. We reject the cached token when local time is behind this floor beyond a small
    /// skew. Clearing the value can't extend anything past the JWT's own `exp`; it only removes
    /// the extra rollback protection.
    private let kcServerClock = "server_clock"
    private let clockSkewTolerance: Double = 600   // 10 min — tolerate mild, legitimate drift

    private func bumpServerClock(iat: Double) {
        let prior = Double(kcGet(kcServerClock) ?? "") ?? 0
        if iat > prior { kcSet(kcServerClock, String(iat)) }
    }

    private func clockRolledBack() -> Bool {
        guard let seen = Double(kcGet(kcServerClock) ?? "") else { return false }
        return Date().timeIntervalSince1970 + clockSkewTolerance < seen
    }

    /// Decode a numeric claim from a JWT payload without verifying the signature (used only for
    /// `iat` bookkeeping after `verify()` has already validated the token).
    private static func jwtField(jwt: String, key: String) -> Double? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let payload = base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return obj[key] as? Double
    }

    // MARK: JWT (Ed25519 / EdDSA)

    private lazy var publicKey: Curve25519.Signing.PublicKey? = {
        guard let der = Data(base64Encoded: AuthConfig.publicKeyPEMBody), der.count >= 32 else { return nil }
        let raw = der.suffix(32)   // strip the 12-byte SPKI prefix
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }()

    private func verify(jwt: String) -> Entitlement? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let key = publicKey else { return nil }
        let signingInput = "\(parts[0]).\(parts[1])"
        guard let sig = Self.base64urlDecode(String(parts[2])),
              key.isValidSignature(sig, for: Data(signingInput.utf8)),
              let payload = Self.base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let plan = obj["plan"] as? String,
              let exp = obj["exp"] as? Double else { return nil }
        if exp < Date().timeIntervalSince1970 { return nil }   // expired grace
        let willCancel = (obj["cancel"] as? Double) == 1 || (obj["cancel"] as? Int) == 1
        return Entitlement(plan: plan, exp: exp, entitlementEnd: (obj["exp"] as? Double) ?? exp,
                           willCancel: willCancel, interval: obj["interval"] as? String, email: nil)
    }

    // MARK: Keychain (refresh token + cached entitlement)

    private let kcService = "com.shivanggulati.catalyst.auth"

    func saveRefresh(_ token: String) { kcSet("refresh", token) }
    func loadRefresh() -> String? { kcGet("refresh") }
    func clear() { kcDelete("refresh"); kcDelete("entitlement") }
    private func cacheToken(_ jwt: String) { kcSet("entitlement", jwt) }
    private func loadCachedToken() -> String? { kcGet("entitlement") }

    // NOTE: We intentionally do NOT set `kSecUseDataProtectionKeychain` here. On macOS the
    // Data-Protection Keychain requires a code-signing entitlement (keychain-access-groups /
    // an application-identifier from a provisioning profile); an unsigned/ad-hoc dev build
    // doesn't have it, so `SecItemAdd` fails with errSecMissingEntitlement and the session
    // never persists (→ re-prompt for the code every launch). The default macOS login
    // keychain works for any non-sandboxed app. Revisit once the app is signed/notarized (P9)
    // — then keychain-access-groups + Data-Protection can come back if we want them.
    private func kcSet(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            logger.log("⚠️ Keychain write failed for '\(account)' (OSStatus \(status))")
        }
    }

    private func kcGet(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func kcDelete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ path: String, bearer: String?, decode: T.Type) async throws -> T {
        try decodeJSON(await request(path, method: "GET", body: nil, bearer: bearer), as: T.self)
    }
    private func post<T: Decodable>(_ path: String, body: [String: Any]?, decode: T.Type, bearer: String? = nil) async throws -> T {
        try decodeJSON(await request(path, method: "POST", body: body, bearer: bearer), as: T.self)
    }
    @discardableResult
    private func postRaw(_ path: String, body: [String: Any]?, bearer: String?) async throws -> Data {
        try await request(path, method: "POST", body: body, bearer: bearer)
    }

    private func request(_ path: String, method: String, body: [String: Any]?, bearer: String?) async throws -> Data {
        var req = URLRequest(url: AuthConfig.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthError.badResponse }
        if http.statusCode == 401 {
            // Single-seat eviction: `/entitlement` returns 401 `device_released` when the seat
            // moved to another Mac. Surface it distinctly so the app can show a specific reason
            // instead of a generic "please sign in".
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["error"] as? String == "device_released" {
                throw AuthError.deviceReleased
            }
            throw AuthError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            // Surface the server's error code (e.g. "email_reserved_student") so the UI can explain it.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = obj["error"] as? String {
                // Single-seat: carry the release ticket + remaining budget so the UI can offer
                // "sign in here instead" without a second OTP.
                if code == "device_limit", let token = obj["release_token"] as? String {
                    let remaining = (obj["delink_remaining"] as? Int) ?? Int((obj["delink_remaining"] as? Double) ?? 0)
                    throw AuthError.deviceLimited(releaseToken: token, remaining: remaining)
                }
                throw AuthError.server(code: code)
            }
            throw AuthError.badResponse
        }
        return data
    }

    private func decodeJSON<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AuthError.badResponse }
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// One issued invoice, exactly as the server recorded it.
///
/// Every buyer/learner field is a SNAPSHOT taken when the invoice was issued — not live account
/// state. If the user later corrects their address, or their learner verification lapses, this
/// document must keep saying what it said the day it was delivered.
struct InvoiceData: Decodable, Equatable {
    let id: String
    let issued_at: Double
    let currency: String
    let amount_minor: Int
    let tier: String                  // "perpetual" | "student"

    let payment_ref: String?
    let payment_method: String?
    let payment_at: Double?

    let buyer_name: String
    let buyer_email: String
    let buyer_phone: String?
    let buyer_line1: String?
    let buyer_line2: String?
    let buyer_city: String?
    let buyer_state: String?
    let buyer_postal: String?
    let buyer_country: String?

    let account_email: String
    let student_email: String?
    let student_verified_at: Double?
    let grant_id: String?

    let seller: Seller

    struct Seller: Decodable, Equatable {
        let name: String
        let city: String
        let country: String
        let postal_code: String
        let tax_registered: Bool
        let tax_note: String
    }

    var isStudent: Bool { tier == "student" }

    /// Amount rendered from MINOR units with the server's currency — never a hardcoded symbol,
    /// so enabling a new currency stays a server-side change.
    var formattedAmount: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        let major = Double(amount_minor) / 100.0
        return f.string(from: NSNumber(value: major)) ?? "\(currency) \(major)"
    }
}

/// Buyer details captured BEFORE checkout, so the invoice can be issued the moment payment
/// lands and Razorpay's own form can be pre-filled rather than asked twice.
///
/// Deliberately a plain value type with no identity of its own: this is latest-known contact
/// info, NOT a record of a transaction. The invoice snapshots these fields at issue time, so
/// correcting an address later can never rewrite a document already delivered.
struct BillingProfile: Equatable {
    var name: String = ""
    var email: String = ""
    var phone: String = ""
    var line1: String = ""
    var line2: String = ""
    var city: String = ""
    var state: String = ""
    var postalCode: String = ""
    var country: String = "IN"     // ISO-3166 alpha-2

    var asPayload: [String: Any] {
        ["name": name, "email": email, "phone": phone, "line1": line1, "line2": line2,
         "city": city, "state": state, "postal_code": postalCode, "country": country]
    }
}
