import SwiftUI
import AppKit

/// Full-screen lock/sign-in gate shown after the splash whenever the app isn't entitled.
/// In-app email → 6-digit code sign-in (no browser). The app stays behind this until
/// `state == .entitled`.
struct AuthGateView: View {
    @ObservedObject var vm: AuthViewModel
    /// Records versioned Privacy/Terms acceptance when the sign-in checkbox is used, so a brand-new
    /// user isn't re-prompted by the blocking consent sheet right after entitlement resolves.
    @ObservedObject var legal: LegalConsentViewModel
    @FocusState private var focused: Bool
    @State private var showGatePaywall = false
    @State private var acceptedTerms = false

    /// One fixed card size for every gate state, so the window doesn't resize as the user moves
    /// between entering an email, entering a code, and the locked/paywall screens.
    static let cardWidth: CGFloat = 540
    static let cardHeight: CGFloat = 660

    /// Room for the AppKit focus ring, which is drawn OUTSIDE a control's frame and is therefore
    /// clipped by any enclosing ScrollView. 4pt clears the ring at every control size we use.
    /// Shared so the gate, the profile sheet and the paywall inset identically.
    static let focusRingInset: CGFloat = 4

    /// The sign-in card. A FIXED-size container; anything too tall scrolls *inside* it.
    private var signInCard: some View {
        VStack(spacing: 24) {
            brandMark

            // The single scroll surface for the gate. Only the state content scrolls — the brand
            // mark stays put, and nothing wraps `PaywallView`, which brings its own ScrollView
            // (nesting the two is what produced the double scrollbar).
            ScrollView(.vertical) {
                VStack(spacing: 24) {
                    switch vm.state {
                    case .checking:
                        checking
                    case .enterEmail:
                        emailStep
                    case .enterCode(let email, let devCode):
                        codeStep(email: email, devCode: devCode)
                    case .locked(let reason, let kind):
                        locked(reason: reason, kind: kind)
                    case .deviceLimited(let email, _, let remaining):
                        deviceLimited(email: email, remaining: remaining)
                    case .entitled:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
                // Focus-ring inset. A ScrollView clips to its bounds, and AppKit draws the blue
                // focus ring OUTSIDE the control's frame — so a text field flush against the
                // scroll edge gets its ring shaved on the sides. This is the gap the ring needs;
                // it is not decorative spacing.
                .padding(.horizontal, Self.focusRingInset)
                .padding(.vertical, Self.focusRingInset)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 460)
        .padding(30)
        .background(Self.cardChrome)
    }

    /// Shared card chrome, so the sign-in states and the gate paywall sit in an identical shell.
    static var cardChrome: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color(NSColor.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.08)))
    }

    var body: some View {
        // The flexible background — NOT the sign-in card — drives the window's size. The card
        // lives in an .overlay, so its (tall) content never becomes the window's MINIMUM height.
        // When the card was a ZStack sibling it pushed the window min-height to ~1015pt (taller
        // than the screen), so macOS marked the window `.fullScreenNone` and the green button
        // showed zoom "+" instead of the full-screen arrows (and vertical resize was locked).
        // With the card as an overlay the window min collapses to the titlebar, and SwiftUI
        // re-enables native full-screen on its own — no window/collectionBehavior hacks needed.
        // NOT ignoresSafeArea: the card stays below the native titlebar so the real traffic
        // lights remain visible. (See goLive 2026-07-14 changelog + Formrules §6.7.)
        Color(NSColor.windowBackgroundColor)
            .overlay(alignment: .center) {
                // FIXED size, centred. The card does NOT grow with its content and does NOT
                // scroll as a whole.
                //
                // It used to be wrapped in a ScrollView, which produced two scrollbars at once
                // on the gate paywall: this outer one plus `PaywallView`'s own. That's
                // toAvoid.md Rule 1 (never nest a vertical ScrollView inside a scrolling page).
                // Scrolling belongs to whichever content is actually too tall — the card is
                // just a fixed frame it lives in.
                //
                // Still inside the .overlay (see the note above): as a ZStack sibling this
                // frame would become the window's minimum height and break native full-screen.
                Group {
                    if showGatePaywall, case .locked = vm.state {
                        // PaywallView owns its OWN ScrollView, so it is deliberately NOT routed
                        // through `signInCard` — nesting the two is what produced two scrollbars.
                        PaywallView(authVM: vm, onBack: { showGatePaywall = false }, context: "gate")
                            .frame(maxWidth: 460)
                            .padding(.vertical, 8)
                            .background(Self.cardChrome)
                    } else {
                        signInCard
                    }
                }
                .frame(width: Self.cardWidth, height: Self.cardHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Give the sign-in window a toolbar so it uses the SAME (taller) unified titlebar
        // as the main app instead of the compact toolbar-less titlebar. The item is empty,
        // so only the height is reserved — traffic lights remain the sole visible chrome.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        // No .ignoresSafeArea(): the gate stays below the native titlebar, so the real
        // window traffic lights are visible and functional. (Custom TrafficLights removed.)
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

    // MARK: States

    /// Record versioned Privacy/Terms consent (the checkbox is the acceptance action), then send
    /// the sign-in code. Guarded by the disabled state — only reachable with `acceptedTerms == true`.
    private func sendCodeAccepting() {
        legal.recordSignInConsent()
        vm.sendCode()
    }

    private var checking: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Checking your access…").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Primary-account rule: valid shape AND not an academic address (a school mailbox dies
    /// after graduation, but the licence is for life). Server enforces the same rule; checking
    /// here means the user finds out while typing, not after waiting for a code.
    private var emailError: String? { Validators.primaryAccountEmail(vm.email) }

    private var emailStep: some View {
        VStack(spacing: 14) {
            Text("Sign in").font(.title3.weight(.semibold))

            TextField("you@example.com", text: $vm.email)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .textContentType(.emailAddress)
                .focused($focused)
                .onSubmit { if acceptedTerms && emailError == nil { sendCodeAccepting() } }

            // Same pattern as the venv creation sheet: inline reason, only once the user has
            // typed something (no scolding an empty field they haven't filled in yet), and the
            // confirm button stays disabled until it's valid.
            if let emailError, !vm.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(emailError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            errorLabel

            Toggle(isOn: $acceptedTerms) {
                Text("I agree to the [Terms & Conditions](https://theappfoundry.co/catalyst/terms) and [Privacy Policy](https://theappfoundry.co/catalyst/privacy).")
                    .font(.caption)
                    .tint(.accentColor)
            }
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: false, vertical: true)

            Button { sendCodeAccepting() } label: {
                Group { if vm.busy { ProgressView().controlSize(.small) } else { Text("Send code") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vm.busy || !acceptedTerms || emailError != nil)

            Text("Signing in starts your **5-day free trial** — no card required. We'll email you a 6-digit code.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Shown UP FRONT, not as an error after the fact: most people should never hit the
            // academic-email rejection at all. Framed as looking after them, and it names the
            // student discount here so nobody thinks choosing a personal email forfeits it.
            //
            // Purple, not orange/red — this is a friendly heads-up, not a warning. Reusing a
            // warning tint before the user has done anything wrong makes the sign-in screen
            // feel like it's scolding them.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "heart.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stick around — for good")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                    Text("Use a personal email you'll keep. School emails stop working after you graduate, and your licence shouldn't.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Students: add your school email later from your profile for the discount.")
                        .font(.caption2)
                        .foregroundStyle(.purple.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.purple.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.28), lineWidth: 1))
            .padding(.top, 4)
        }
        .onAppear { focused = true }
    }

    private func codeStep(email: String, devCode: String?) -> some View {
        VStack(spacing: 14) {
            Text("Enter your code").font(.title3.weight(.semibold))
            Text("We sent a 6-digit code to \(email).")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)

            // Six boxes with auto-advance. Digits-only + the 6-char cap live inside the
            // control now, so this call site no longer repeats that filter.
            OTPCodeField(code: $vm.code, disabled: vm.busy) { vm.submitCode() }

            if let devCode {
                Text("Dev mode — your code is **\(devCode)**")
                    .font(.caption2).foregroundStyle(.orange)
            }

            errorLabel

            Button { vm.submitCode() } label: {
                Group { if vm.busy { ProgressView().controlSize(.small) } else { Text("Verify") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vm.busy)

            HStack(spacing: 14) {
                Button("Resend code") { vm.resendCode() }.buttonStyle(.link)
                Button("Change email") { vm.changeEmail() }.buttonStyle(.link)
            }
            .font(.caption)
        }
        .onAppear { focused = true }
    }

    /// Per-reason gate copy. `.deviceTrialed` gets a warm, goofy "one golden ticket per Mac" tone,
    /// since a fresh account here never had a trial to "end" — pretending it did feels broken.
    private func lockedCopy(_ kind: AuthViewModel.State.LockKind)
        -> (icon: String, title: String, body: String, cta: String) {
        switch kind {
        case .resubscribe:
            return ("hand.wave.fill", "Welcome back",
                    "Resubscribe to pick up right where you left off — every feature, on this Mac and your next one. Your environments and settings are exactly as you left them.",
                    "Resubscribe")
        case .deviceTrialed:
            return ("ticket.fill", "One free trial per Mac",
                    "Every computer gets exactly one free 5-day spin — and this Mac already took it, no matter how many accounts sign in. No trial to end here, we're just being upfront! Go Pro and everything unlocks instantly.",
                    "Upgrade to Pro")
        case .trialEnded:
            return ("sparkles", "Your free trial has ended",
                    "Subscribe to keep everything running — every feature, on this Mac and your next one. Cancel anytime.",
                    "Upgrade to Pro")
        }
    }

    @ViewBuilder private func locked(reason: String, kind: AuthViewModel.State.LockKind) -> some View {
        let (icon, title, body, cta) = lockedCopy(kind)
        // The `showGatePaywall` branch used to live here, which put PaywallView inside the
        // card's ScrollView. It is now handled one level up in `body`, outside that scroll
        // surface — see the note there.
        if !showGatePaywall {
            VStack(spacing: 18) {
                // Warm, badge-style icon (welcoming, not a cold padlock).
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.accentColor.opacity(0.22), .accentColor.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 64, height: 64)
                    Image(systemName: icon)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.tint)
                }

                VStack(spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                Button { showGatePaywall = true } label: {
                    Text(cta)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 2)

                HStack(spacing: 12) {
                    Button("Restore purchases") { vm.restorePurchases() }.buttonStyle(.link)
                    Text("·").foregroundStyle(.tertiary)
                    Button("Sign out") { vm.signOut() }.buttonStyle(.link)
                }
                .font(.caption)
            }
        }
    }

    private func deviceLimited(email: String, remaining: Int) -> some View {
        VStack(spacing: 16) {
            Label("Already signed in on another Mac", systemImage: "desktopcomputer")
                .font(.title3.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .multilineTextAlignment(.center)
            Text("Your Catalyst account (\(email)) is active on a different Mac. Catalyst allows one Mac at a time. You can sign in here and sign the other Mac out.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)

            errorLabel

            if remaining > 0 {
                // Budget left → offer the seat move, and tell them how many switches remain so
                // frequent switchers understand the limit before they hit it.
                Button { vm.releaseThisDevice() } label: {
                    Group { if vm.busy { ProgressView().controlSize(.small) } else { Text("Sign in here & sign out the other Mac") } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(vm.busy)

                Text("You can switch Macs \(remaining) more time\(remaining == 1 ? "" : "s") in the next 90 days.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                // Switch budget exhausted → don't offer a move that would only fail server-side.
                // State the reason plainly (item 4: no login is entertained when switching too often).
                StatusBanner(icon: "clock.badge.exclamationmark",
                             tint: .orange,
                             text: "You've switched Macs the maximum number of times for now. To protect against sharing, Catalyst limits how often an account can move between Macs. Please try again later, or contact support if you need help.")
            }

            Button("Use a different email") { vm.changeEmail() }
                .buttonStyle(.link).font(.caption)
        }
    }

    @ViewBuilder private var errorLabel: some View {
        if let msg = vm.errorText {
            // Same tinted, bordered banner as the in-app status banners (single source of truth).
            StatusBanner(icon: "exclamationmark.triangle.fill", tint: .orange, text: msg)
        }
    }
}

// Custom TrafficLights + WindowChromeFix removed: the splash/auth no longer cover the
// native titlebar, so the window's real traffic lights are used directly.
