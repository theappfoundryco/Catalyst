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
