import SwiftUI

/// A reusable view that displays a loading state with a progress indicator and an optional title.
///
/// Use `LoadingStateView` to indicate that a process is ongoing, such as loading data
/// or performing a background task. It centers a `ProgressView` and an optional text label
/// within its container.
///
/// ## Example Usage
/// ```swift
/// LoadingStateView(title: "Loading Packages...")
/// ```
struct LoadingStateView: View {
    /// The text to display below the progress indicator.
    var title: String?
    
    /// The vertical padding applied to the loading state container.
    var verticalPadding: CGFloat
    
    /// Initializes a new LoadingStateView.
    /// - Parameters:
    ///   - title: An optional message to display below the spinner.
    ///   - verticalPadding: Padding applied to top and bottom. Defaults to 16.
    init(_ title: String? = nil, verticalPadding: CGFloat = 16) {
        self.title = title
        self.verticalPadding = verticalPadding
    }
    
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            
            if let title = title {
                Text(title)
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, verticalPadding)
    }
}
