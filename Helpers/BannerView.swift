/// Standardized banner for warnings, tips, and information.

import SwiftUI

/// A standardized banner view for displaying contextual messages.
///
/// Supports four semantic styles (`.info`, `.warning`, `.tip`, `.critical`) and two size
/// variants (`.standard`, `.compact`). Each style provides its own color and SF Symbol icon.
///
/// ## Usage
///
/// ```swift
/// BannerView(.info, title: "Note", message: "This will take a moment.")
///
/// BannerView(.warning, message: "Python 3.12+ detected.", size: .compact)
/// ```
struct BannerView: View {
    /// The semantic style of the banner, determining its color and icon.
    enum Style {
        /// Blue info circle.
        case info
        /// Orange warning triangle.
        case warning
        /// Blue lightbulb.
        case tip
        /// Red octagon.
        case critical
        
        /// The tint color for the banner's background and icon.
        var color: Color {
            switch self {
            case .info, .tip: return .blue
            case .warning: return .orange
            case .critical: return .red
            }
        }
        
        /// The SF Symbol name for the banner's leading icon.
        var iconName: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .tip: return "lightbulb.fill"
            case .critical: return "xmark.octagon.fill"
            }
        }
    }
    
    /// The size variant for the banner layout.
    enum BannerSize {
        /// Full-width with generous padding (16×12) and 12pt corner radius.
        case standard
        /// Inline with tight padding (10×6) and 6pt corner radius.
        case compact
    }
    
    /// The semantic style of this banner.
    let style: Style
    
    /// Optional bold headline text.
    let title: String?
    
    /// The body message text.
    let message: String
    
    /// The size variant. Defaults to `.standard`.
    let size: BannerSize
    
    init(_ style: Style, title: String? = nil, message: String, size: BannerSize = .standard) {
        self.style = style
        self.title = title
        self.message = message
        self.size = size
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: size == .standard ? 12 : 6) {
            Image(systemName: style.iconName)
                .font(size == .standard ? .title3 : .caption)
                .foregroundColor(style.color)
                .frame(width: size == .standard ? 24 : nil)
            
            VStack(alignment: .leading, spacing: size == .standard ? 4 : 3) {
                if let title = title {
                    Text(title)
                        .font(size == .standard ? .headline : .caption.bold())
                        .foregroundColor(.primary)
                }
                
                Text(message)
                    .font(size == .standard ? .subheadline : .caption)
                    .foregroundColor(size == .standard ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding(.horizontal, size == .standard ? 16 : 10)
        .padding(.vertical, size == .standard ? 12 : 6)
        .background(
            RoundedRectangle(cornerRadius: size == .standard ? 12 : 6)
                .fill(style.color.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: size == .standard ? 12 : 6)
                        .strokeBorder(style.color.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, size == .standard ? 16 : 0)
    }
}
