import SwiftUI

/// The size variant for a card's visual style.
///
/// Use this enum to choose between two predefined card appearances:
/// - ``standard``: A full-width section container with generous padding, rounded corners (12pt), and a subtle drop shadow.
/// - ``compact``: A smaller inline element with tight padding, rounded corners (6pt), and a thin stroke border.
///
/// ```swift
/// let size: CardSize = .standard
/// ```
enum CardSize {
    /// A full-width section container.
    ///
    /// Applies 16pt inner padding on all sides, a 12pt corner radius,
    /// a `controlBackgroundColor` fill, and a subtle drop shadow.
    /// Best suited for top-level content sections.
    case standard
    
    /// A smaller inline element.
    ///
    /// Applies 10pt horizontal / 6pt vertical inner padding, a 6pt corner radius,
    /// a `controlBackgroundColor` fill, and a thin secondary stroke border.
    /// Best suited for text fields, list rows, code blocks, or inline chips.
    case compact
}

extension View {
    /// Applies a consistent card background style to the view.
    ///
    /// This is the **single source of truth** for card styling across the app.
    /// It handles inner padding, background shape, and optionally the outer horizontal margin.
    ///
    /// - Parameters:
    ///   - size: The visual variant to apply. Defaults to ``CardSize/standard``.
    ///   - padded: Whether to include outer horizontal margin (`.padding(.horizontal)`).
    ///             Defaults to `true`. Set to `false` when the parent already provides
    ///             its own horizontal padding, to avoid double-margin issues.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Standard card with outer margin (most common):
    /// SomeView()
    ///     .cardStyle()
    ///
    /// // Compact inline element:
    /// SomeView()
    ///     .cardStyle(.compact)
    ///
    /// // Standard card without outer margin (parent handles spacing):
    /// SomeView()
    ///     .cardStyle(padded: false)
    /// ```
    /// - Parameters:
    ///   - size: The targeted physical bound variant representing density.
    ///   - padded: Indicates whether internal content insets should apply.
    /// - Returns: The active presentation hierarchy for the detail view.
    func cardStyle(_ size: CardSize = .standard, padded: Bool = true) -> some View {
        self
            .modifier(CardStyleModifier(size: size, padded: padded))
    }
    
    /// Applies a recessed code-panel background for search bars, output logs, and code previews.
    ///
    /// This is the **single source of truth** for the inset text-area styling used throughout the app.
    /// It wraps the content with inner padding and a `textBackgroundColor` rounded rectangle.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Search bar:
    /// HStack {
    ///     Image(systemName: "magnifyingglass")
    ///     TextField("Search...", text: $query)
    /// }
    /// .codePanel()
    ///
    /// // Output console scroll area:
    /// ScrollView { Text(output).font(.caption.monospaced()) }
    ///     .frame(maxHeight: 200)
    ///     .codePanel()
    /// ```
    /// - Returns: The active presentation hierarchy for the detail view.
    func codePanel() -> some View {
        self
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor))
            )
    }

    /// The tinted fill + hairline border used by inline status banners.
    ///
    /// **Single source of truth** for banner chrome so the profile sheet's manage/cancel
    /// banners and the sign-in window's error banners look identical. Pair with ``StatusBanner``
    /// for the common icon + message layout, or apply directly to a custom banner body.
    /// - Parameters:
    ///   - tint: The color mapping for the banner.
    ///   - cornerRadius: The geometric softening applied to corners.
    /// - Returns: The active presentation hierarchy for the detail view.
    func statusBannerChrome(tint: Color, cornerRadius: CGFloat = 12) -> some View {
        self
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(tint.opacity(0.28), lineWidth: 1))
    }
}

/// A tinted, bordered inline status banner: an SF Symbol + a message on a `tint`-colored card.
///
/// **Single source of truth** for one-line status call-outs. Richer banners that need a spinner
/// or a dismiss button compose their own body and apply ``statusBannerChrome(tint:cornerRadius:)``
/// instead.
///
/// ```swift
/// StatusBanner(icon: "exclamationmark.triangle", tint: .orange, text: "Error")
/// ```
struct StatusBanner: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .statusBannerChrome(tint: tint)
    }
}

/// A page-level scroll container backed by `List` (`NSScrollView`) for smooth,
/// native macOS scrolling.
///
/// Drop-in replacement for a top-level `ScrollView { … }`. On macOS a plain
/// `ScrollView { VStack }` uses SwiftUI's own scroll engine, which scrolls in a
/// steppy/jerky way (worst in Release and large windows). `List` is
/// `NSScrollView`-backed and gives native momentum scrolling. The existing
/// content is placed as a single chrome-free row, so the layout is unchanged —
/// only the scroll engine differs.
///
/// ```swift
/// SmoothPageScroll {
///     VStack { Text("Content") }
/// }
/// ```
struct SmoothPageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        List {
            content()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }
        .listStyle(.plain)
        // `List` paints its own (lighter) background behind the clear rows, which
        // leaks as grey strips in the top/bottom scroll insets. Hide it so the
        // window background shows through instead.
        .scrollContentBackground(.hidden)
    }
}

/// Internal modifier that applies the card styling based on size and padding options.
private struct CardStyleModifier: ViewModifier {
    let size: CardSize
    let padded: Bool
    
    /// - Parameter content: The dynamic internal rendering hierarchy.
    /// - Returns: The active presentation hierarchy for the detail view.
    func body(content: Content) -> some View {
        Group {
            switch size {
            case .standard:
                content
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.controlBackgroundColor))
                            // Hairline opaque border replaces the drop shadow:
                            // shadows force an offscreen render pass per frame and
                            // jank during scroll (R5). The border keeps card edges
                            // defined at zero per-frame cost.
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
            case .compact:
                content
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    )
            }
        }
        .if(padded) { view in
            view.padding(.horizontal)
        }
    }
}

/// Conditional modifier helper used internally by CardStyleModifier.
private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

