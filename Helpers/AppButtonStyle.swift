/// The app-wide button styling system — a single source of truth for how every
/// button in Catalyst looks.

import SwiftUI

/// Semantic button roles for the whole app. Pick a button by *what it does*, not by
/// how it should be drawn; the concrete `ButtonStyle` for each role is resolved in
/// exactly one place (`View/appButton(_:)`), so the app's button design can evolve
/// by editing this file alone.
///
/// ## Roles
/// - ``primary``: the main call-to-action of a screen or card. Prominent, filled.
///   Combine with a call-site `.tint(_:)` to color it semantically (e.g. Homebrew's
///   per-operation blue/green/orange/red).
/// - ``neutral``: a secondary action that still needs a visible affordance (bordered
///   with native depth). The default for "Cancel", "Clear", "Choose…", etc.
/// - ``secondary``: a compact secondary action where the SF Symbol must share the
///   title's color (Copy, Reveal, inline row actions). Flat surface, icon == title.
///   See ``SecondaryActionButtonStyle``.
/// - ``destructive`` / ``destructiveProminent``: dangerous actions (Delete, Remove).
///   Solid red; the prominent variant is card-CTA scale. See
///   ``DestructiveActionButtonStyle``.
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
    /// Bordered secondary action with native depth (Cancel, Clear, Choose…).
    case neutral
    /// Compact flat secondary action; SF Symbol always matches the title color.
    case secondary
    /// Dangerous action at row scale. Solid red, light label.
    case destructive
    /// Dangerous action at card-CTA scale. Solid red, larger metrics.
    case destructiveProminent
    /// No chrome — bare icon buttons and tappable rows.
    case plain
    /// Inline, link-like affordance — toolbar glyphs and icon-only row controls.
    case borderless
    /// A text hyperlink (accent-colored, no chrome) — "Learn more", website links.
    case link
}

extension View {
    /// Applies the app's canonical `ButtonStyle` for a semantic ``AppButtonKind``.
    ///
    /// This is the ONLY place button roles map to concrete styles. Every button in
    /// the app should use this instead of `.buttonStyle(_:)` directly, so the whole
    /// app stays visually consistent and can be restyled from one location.
    ///
    /// ```swift
    /// Button("Delete", action: remove).appButton(.destructive)
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
        case .neutral:
            buttonStyle(.bordered)
        case .secondary:
            buttonStyle(.secondaryAction)
        case .destructive:
            buttonStyle(.destructiveAction)
        case .destructiveProminent:
            buttonStyle(.destructiveActionProminent)
        case .plain:
            buttonStyle(.plain)
        case .borderless:
            buttonStyle(.borderless)
        case .link:
            buttonStyle(.link)
        }
    }
}
