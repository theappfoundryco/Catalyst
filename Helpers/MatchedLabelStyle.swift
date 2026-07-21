//
//  MatchedLabelStyle.swift
//  Catalyst
//
//  Shared label style that keeps a button's SF Symbol the same color as its title.
//
import SwiftUI

/// Renders a `Label` so its SF Symbol always matches the title's color.
///
/// macOS renders several SF Symbols in their own multicolor/hierarchical palette
/// (or tints only the glyph), which leaves a mismatched "random" icon color next
/// to neutral title text on action buttons. Forcing `.monochrome` makes the
/// symbol adopt the same foreground the button assigns to the title, so icon and
/// text always match — in `.bordered` (tinted/neutral) and `.borderedProminent`
/// (white-on-fill) alike.
///
/// ## Usage
/// ```swift
/// Button { … } label: {
///     Label("Scan for Updates", systemImage: "arrow.clockwise")
/// }
/// .labelStyle(.matched)
/// ```
struct MatchedLabelStyle: LabelStyle {
    var spacing: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
        .symbolRenderingMode(.monochrome)
    }
}

extension LabelStyle where Self == MatchedLabelStyle {
    /// Icon color always follows the title color. See ``MatchedLabelStyle``.
    static var matched: MatchedLabelStyle { MatchedLabelStyle() }
}

/// App-standard **secondary** action button (Copy, Reveal, row actions).
///
/// Unlike `.bordered` — which tints the SF Symbol with the accent color while the
/// title stays neutral, giving a three-color mismatch — this style renders the
/// whole label in ONE color on a neutral surface. Icon == title, always. The
/// "button color reflects the button type" (neutral surface here) while primary
/// actions keep `.borderedProminent`.
struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.matched)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)                 // icon AND title, same color
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(NSColor.controlColor).opacity(configuration.isPressed ? 0.55 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SecondaryActionButtonStyle {
    /// Neutral secondary button; icon and title always share one color.
    static var secondaryAction: SecondaryActionButtonStyle { SecondaryActionButtonStyle() }
}

/// App-standard **destructive** action button (Remove, Delete, Sign Out).
///
/// A solid red fill with a white label — NOT `Button(role: .destructive)` and not
/// `.bordered` + `.tint(.red)`. Both of those hand the rendering to AppKit, which on macOS
/// produces a *tinted* button: red-ish text on a near-neutral surface, at a control height
/// that doesn't match `.secondaryAction`. Sitting next to two secondary buttons in a row,
/// that reads as a fourth visual language rather than "the dangerous one".
///
/// Geometry is deliberately IDENTICAL to ``SecondaryActionButtonStyle`` — same font, padding,
/// and corner radius — so a row of actions lines up exactly and only the color differs. If you
/// change the metrics in one, change them in the other; they are a matched pair, and the whole
/// point is that a destructive button differs in color alone.
/// Comes in two sizes because destructive actions appear at two scales in this app: inline row
/// actions sitting beside `.secondaryAction` buttons, and full-width card CTAs ("Delete Selected").
/// One style with a size knob keeps both rendering the same red, radius, and label treatment —
/// the alternative was converting the large CTAs to caption size, which would have quietly
/// demoted the most consequential buttons in the app.
struct DestructiveActionButtonStyle: ButtonStyle {
    enum Size {
        /// Matches ``SecondaryActionButtonStyle`` exactly. For rows of mixed actions.
        case regular
        /// For a card's primary destructive CTA. Mirrors `.controlSize(.large)` metrics.
        case prominent
    }

    var size: Size = .regular
    @Environment(\.isEnabled) private var isEnabled

    private var font: Font {
        switch size {
        case .regular:   return .caption.weight(.medium)
        case .prominent: return .body.weight(.semibold)
        }
    }
    private var hPad: CGFloat { size == .regular ? 10 : 16 }
    private var vPad: CGFloat { size == .regular ? 5 : 9 }
    private var radius: CGFloat { size == .regular ? 6 : 8 }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.matched)
            .font(font)
            .foregroundStyle(.white)                   // icon AND title, on red
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.red.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == DestructiveActionButtonStyle {
    /// Solid red, white label. Matches ``SecondaryActionButtonStyle`` in every dimension but color.
    static var destructiveAction: DestructiveActionButtonStyle { DestructiveActionButtonStyle() }

    /// Solid red at card-CTA scale. Use for a card's primary destructive action, not for row actions.
    static var destructiveActionProminent: DestructiveActionButtonStyle {
        DestructiveActionButtonStyle(size: .prominent)
    }
}
