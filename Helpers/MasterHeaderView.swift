/// Shared page header with icon, title, and subtitle.

import SwiftUI

/// A centered page header displaying a gradient icon, bold title, and secondary subtitle.
///
/// Used at the top of major sections to provide visual identity and context.
///
/// ## Usage
///
/// ```swift
/// MasterHeaderView(
///     title: "Brew Packages",
///     subtitle: "Manage your Homebrew formulae and casks",
///     image: "mug.fill",
///     color: .orange
/// )
/// ```
struct MasterHeaderView: View {
    /// The bold title text.
    let title: String
    
    /// The secondary description text.
    let subtitle: String
    
    /// SF Symbol name for the header icon.
    let image: String
    
    /// The gradient tint color for the icon.
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: image)
                .font(.system(size: 48))
                .foregroundStyle(color.gradient)
            
            Text(title)
                .font(.title2.bold())
            
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top)
        .padding(.horizontal)
    }
}
