/// Shared label style that keeps a button's SF Symbol the same color as its title.

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

    /// Fuses the system icon and text components into a uniform visual hierarchy.
    /// - Parameter configuration: The active structural bridge mapping the style attributes.
    /// - Returns: The active presentation hierarchy for the detail view.
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

/// The bordered secondary/neutral button style, with a HARD guarantee that the SF
/// Symbol renders the same color as the title (both `.primary` — white in the app's
/// forced-dark UI). This backs the `.neutral` and `.secondary` roles in
/// ``AppButtonKind``.
///
/// Native `.bordered` cannot promise this: macOS accent-tints a control's glyph
/// (blue) while the title stays neutral, and neither `.tint(.primary)` nor a
/// foreground override reliably beats it (`docs/CODING_STANDARDS.md` §4.2). Rendering
/// the whole label in ONE color on a neutral surface is the only reliable fix, so an
/// icon+title button can never show a mismatched blue glyph.
///
/// Unlike the previous fixed-padding secondary style, this reads
/// `@Environment(\.controlSize)` so a `.controlSize(.large)` footer button still lines
/// up with the prominent button beside it, and compact row actions stay compact.
///
/// ```swift
/// Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
///     .appButton(.secondary)
/// ```
struct NeutralActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    /// Padding + font scaled to the ambient control size so the button matches native
    /// controls of the same size sitting next to it.
    private var metrics: (font: Font, hPad: CGFloat, vPad: CGFloat) {
        switch controlSize {
        case .large:      return (.body, 14, 7)
        case .small:      return (.caption, 8, 3)
        case .mini:       return (.caption2, 6, 2)
        default:          return (.caption.weight(.semibold), 10, 5)
        }
    }

    /// Renders the label in a single forced color (icon == title) on a neutral surface.
    /// - Parameter configuration: The active structural bridge mapping the style attributes.
    /// - Returns: The active presentation hierarchy for the detail view.
    func makeBody(configuration: Configuration) -> some View {
        let m = metrics
        return configuration.label
            .labelStyle(.matched)
            .font(m.font)
            .foregroundStyle(.primary)                 // icon AND title, same color
            .padding(.horizontal, m.hPad)
            .padding(.vertical, m.vPad)
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

extension ButtonStyle where Self == NeutralActionButtonStyle {
    /// Bordered secondary/neutral button; icon and title always share one color.
    /// See ``NeutralActionButtonStyle``.
    static var neutralAction: NeutralActionButtonStyle { NeutralActionButtonStyle() }
}
