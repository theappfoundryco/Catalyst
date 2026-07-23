/// The app-wide button styling system — a single source of truth for how every
/// button in Catalyst looks.

import SwiftUI

/// Semantic button roles for the whole app. Pick a button by *what it does*, not by
/// how it should be drawn; the concrete `ButtonStyle` for each role is resolved in
/// exactly one place (`View/appButton(_:)`), so the app's button design can evolve
/// by editing this file alone.
///
/// Every role resolves to a **native** SwiftUI button style, so the whole app shares
/// one coherent, depth-carrying button language — no bespoke flat surfaces that read
/// "cheap" next to the prominent ones. Colored actions are `.borderedProminent`
/// (optionally tinted); quieter actions are `.bordered`; the rest are chrome-free.
///
/// ## Roles
/// - ``primary``: the main call-to-action of a screen or card. Prominent, filled.
///   Combine with a call-site `.tint(_:)` to color it semantically (e.g. Homebrew's
///   per-operation blue/green/orange/red).
/// - ``destructive`` / ``destructiveProminent``: dangerous actions (Delete, Remove,
///   Uninstall). Prominent solid red — same depth as ``primary``, only the color
///   differs; the prominent variant is card-CTA scale.
/// - ``neutral``: a quieter secondary action that still needs a visible affordance
///   (bordered, native depth). The default for "Cancel", "Clear", "Choose…", "Retry".
/// - ``secondary``: a compact secondary action (Copy, Reveal, inline row actions).
///   Shares ``neutral``'s bordered treatment; kept as a distinct role for call-site
///   intent. Icon/title color matching is handled app-wide (see
///   `docs/CODING_STANDARDS.md` §4.2), so no bespoke style is needed here.
/// - ``plain``: no chrome at all — bare icon buttons and tappable rows/cells.
/// - ``borderless``: inline, link-like affordances (toolbar glyphs, "Move up").
/// - ``link``: a text hyperlink (accent-colored, no chrome).
///
/// ## Flags
/// Per-button variation stays at the call site and composes on top of the role:
/// `.tint(_:)` for color, `.controlSize(_:)` for scale, and
/// `.frame(maxWidth: .infinity)` for full-width. These are intentionally *not*
/// folded into the role so a colored prominent button is simply
/// `.appButton(.primary).tint(.green)`.
enum AppButtonKind {
    /// Main call-to-action. Prominent filled surface; tint at the call site to color it.
    case primary
    /// Dangerous action at row scale. Prominent solid red.
    case destructive
    /// Dangerous action at card-CTA scale. Prominent solid red, larger metrics.
    case destructiveProminent
    /// Quieter secondary action with a visible bordered affordance and native depth.
    case neutral
    /// Compact secondary action (Copy, Reveal, row actions). Shares ``neutral``'s look.
    case secondary
    /// No chrome — bare icon buttons and tappable rows.
    case plain
    /// Inline, link-like affordance — toolbar glyphs and icon-only row controls.
    case borderless
    /// A text hyperlink (accent-colored, no chrome) — "Learn more", website links.
    case link
}

extension View {
    /// Applies the app's canonical button style for a semantic ``AppButtonKind``.
    ///
    /// This is the ONLY place button roles map to concrete styles. Every button in
    /// the app uses this instead of `.buttonStyle(_:)` directly, so the whole app
    /// stays visually consistent and can be restyled from one location.
    ///
    /// ```swift
    /// Button("Uninstall", action: remove).appButton(.destructive)
    /// Button("Run", action: update).appButton(.primary).tint(.blue)
    /// ```
    ///
    /// - Parameter kind: The button's semantic role.
    /// - Returns: The button with the role's canonical style applied. Call-site
    ///   `.tint(_:)`, `.controlSize(_:)`, and framing still compose on top.
    @ViewBuilder
    func appButton(_ kind: AppButtonKind) -> some View {
        switch kind {
        case .primary:
            buttonStyle(.borderedProminent)
        case .destructive:
            buttonStyle(.borderedProminent)
                .tint(.red)
        case .destructiveProminent:
            buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
        case .neutral:
            buttonStyle(.bordered)
        case .secondary:
            buttonStyle(.bordered)
        case .plain:
            buttonStyle(.plain)
        case .borderless:
            buttonStyle(.borderless)
        case .link:
            buttonStyle(.link)
        }
    }
}
