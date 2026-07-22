import SwiftUI

/// A dismissible, critical-error banner for surfacing **install/uninstall
/// failures** prominently in the UI (P3) — distinct from the streamed console
/// log, which users shouldn't have to scan to learn something broke.
///
/// Renders nothing when `message` is `nil`. Tapping the dismiss button clears
/// the bound message. Follows the app form rules: filled SF Symbol, semantic
/// red, opaque-tinted fill + hairline border (no shadow).
///
/// ## Usage
/// ```swift
/// // VM:  @Published var installError: String?  (set on the failure branch)
/// // View, placed near the output console:
/// ErrorBanner(message: $vm.installError)
/// ```
struct ErrorBanner: View {
    @Binding var message: String?
    var title: String = "Installation failed"

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundColor(.red)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                Button {
                    self.message = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }
}
