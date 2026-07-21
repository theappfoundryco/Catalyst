import SwiftUI

/// The app's single, reusable text-input control.
///
/// This is the **source of truth** for typing areas across Catalyst — the Alias
/// name/command fields, SSH key generation, network hosts, etc. all use it so
/// every input looks and behaves identically. It wraps an optional caption
/// label, a leading SF Symbol, and a plain `TextField`/`SecureField` in the
/// shared compact card style.
///
/// ## Usage
/// ```swift
/// // Labeled form field (Alias-style):
/// CompactInputField(label: "Alias Name", icon: "terminal",
///                   placeholder: "e.g., ll, gs", text: $name)
///
/// // Inline field without a label, fixed width:
/// CompactInputField(icon: "globe", placeholder: "DNS host",
///                   text: $host, width: 140)
///
/// // Secure entry (masked, with a trailing eye button to reveal):
/// CompactInputField(label: "Passphrase", icon: "lock",
///                   placeholder: "optional", text: $pass, isSecure: true)
///
/// // Secure entry with no reveal affordance:
/// CompactInputField(icon: "lock", placeholder: "PIN",
///                   text: $pin, isSecure: true, allowReveal: false)
/// ```
struct CompactInputField: View {
    /// Optional caption shown above the field. Omit for inline (label-less) use.
    var label: String? = nil
    /// Leading SF Symbol name.
    let icon: String
    let placeholder: String
    @Binding var text: String
    /// Use a `SecureField` (masked) instead of a `TextField`. Secure fields get a
    /// trailing eye button to reveal what's typed — see `isRevealed`.
    var isSecure: Bool = false
    /// Show the reveal (eye) toggle on secure fields. On by default: passphrases are
    /// easy to mistype and impossible to verify blind, and every one of them in this
    /// app is entered by a single local user on their own machine. Pass `false` for
    /// a field that might be typed in front of an audience.
    var allowReveal: Bool = true
    /// Optional fixed width for the text entry (nil = flexible).
    var width: CGFloat? = nil
    /// Optional action fired on Return.
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool
    /// Whether a secure field is currently showing its contents in the clear.
    /// Local to the control and always starts masked — revealing is a deliberate,
    /// per-entry act, never a state that persists across appearances.
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .font(.caption)

                Group {
                    if isSecure && !isRevealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                // SwiftUI treats SecureField and TextField as different views, so
                // swapping them would drop focus mid-typing. A stable identity keyed
                // to THIS field (not a shared constant — two sibling passphrase
                // fields must not share one) keeps it alive across the toggle.
                .id("compact-input-\(label ?? placeholder)")
                .focused($isFocused)
                .frame(width: width)
                // Extend the field's hit region to its whole frame so a click on the
                // blank area (not just the glyphs) focuses it — a bare .plain field
                // otherwise only accepts hits on the text itself.
                .contentShape(Rectangle())
                // ...and actually FOCUS on that click. `contentShape` alone only makes
                // the region hit-testable, so the trailing blank area of the field
                // *consumed* the tap and then did nothing with it — the outer gesture
                // below never saw it, so no caret appeared. A `TextField` with no
                // explicit `width` greedily fills the row, which is why the dead zone
                // was the whole right-hand side.
                .onTapGesture { isFocused = true }
                .onSubmit { onSubmit?() }

                // Fill the row so clicks anywhere in the field focus it.
                if width != nil { Spacer(minLength: 0) }

                if isSecure && allowReveal {
                    Button {
                        isRevealed.toggle()
                        // Toggling swaps the underlying view; put the caret back so
                        // the user can keep typing without re-clicking.
                        isFocused = true
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .help(isRevealed ? "Hide" : "Show")
                    .accessibilityLabel(isRevealed ? "Hide passphrase" : "Show passphrase")
                }
            }
            .padding(4)
            .cardStyle(.compact, padded: false)
            // The whole field (including padding/icon/border inset) is the tap
            // target, not just the text glyphs. This catches the areas the field
            // itself doesn't own — the leading icon, the 4pt padding, and the gap
            // before the eye button.
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
        }
    }
}
