//
//  EmptyStateView.swift
//  Catalyst
//
//  Centralized empty/no-results state placeholder.
//
import SwiftUI

/// A reusable placeholder view for empty or no-results states.
///
/// Displays a centered icon, a primary message, and an optional detail line.
/// Used throughout the app whenever a list, grid, or section has nothing to show.
///
/// ## Usage
///
/// ```swift
/// // Basic empty state:
/// EmptyStateView(icon: "tray", message: "No packages installed")
///
/// // With detail line:
/// EmptyStateView(
///     icon: "tray",
///     message: "No Aliases Found",
///     detail: "Create your first alias above to get started!"
/// )
///
/// // Custom icon color (e.g., for errors):
/// EmptyStateView(
///     icon: "exclamationmark.triangle",
///     message: "Something went wrong",
///     iconColor: .orange
/// )
/// ```
///
/// - Note: Wraps itself in `.frame(maxWidth: .infinity)` and vertical padding
///   so it fills the available width and centers naturally within a card or scroll view.
struct EmptyStateView: View {
    /// SF Symbol name for the icon.
    let icon: String
    
    /// Primary message displayed below the icon.
    let message: String
    
    /// Optional secondary detail text, shown in a smaller font below the message.
    var detail: String? = nil
    
    /// Icon color. Defaults to `.secondary`.
    var iconColor: Color = .secondary
    
    /// Icon font size. Defaults to `40`.
    var iconSize: CGFloat = 40
    
    /// Vertical padding around the content. Defaults to `40`.
    var verticalPadding: CGFloat = 40
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundColor(iconColor)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, verticalPadding)
    }
}
