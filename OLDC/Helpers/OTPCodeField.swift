//
//  OTPCodeField.swift
//  Catalyst
//
//  The app's one-time-code input: N separate boxes that fill left-to-right as you type,
//  with the active box highlighted and a blinking caret.
//
//  ## Why ONE hidden field, not N real fields
//  The obvious implementation is six `TextField`s that move focus on each keystroke. It looks
//  right and behaves badly: pasting a 6-digit code drops five characters, backspace at a box
//  boundary does nothing, and ⌘A / arrow keys / undo all break. Every one of those becomes a
//  bug you hand-patch afterwards.
//
//  Instead this draws six *labels* over a single real, invisible `TextField` that owns the
//  whole string. Paste, backspace, selection and undo work because they're handled by one
//  ordinary text field — the boxes are pure presentation derived from `code.count`, and
//  "auto-advance" is emergent: the highlight is just `index == code.count`.
//
//  Digits-only and the length cap are enforced here, so callers don't repeat that filter.
//

import SwiftUI

struct OTPCodeField: View {
    @Binding var code: String
    var length: Int = 6
    var disabled: Bool = false
    /// Fired when the user types the final digit — lets the caller submit without a button press.
    /// Declared LAST so trailing-closure syntax binds here rather than to `disabled`.
    var onComplete: (() -> Void)? = nil

    @FocusState private var focused: Bool
    /// Drives the caret blink in the active box only.
    @State private var caretVisible = true

    private var digits: [Character] { Array(code) }

    /// Show the "check your spam folder" hint under the boxes.
    ///
    /// Defaults to true and lives HERE rather than at each call site: this control is the app's
    /// single OTP surface (sign-in and student verification both use it), so the hint reaches
    /// every code screen — present and future — without anyone remembering to add it.
    var showsDeliveryHint: Bool = true

    var body: some View {
        VStack(spacing: 12) {
            field
            if showsDeliveryHint { deliveryHint }
        }
    }

    /// Light-hearted, but it earns its place: "no code arrived" is overwhelmingly a spam-folder
    /// problem, and saying so here saves a support message. Kept to one line so it reads as a
    /// footnote and never competes with the boxes above it.
    private var deliveryHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Peek in spam too — our mail occasionally hides there.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var field: some View {
        ZStack {
            // The real input. Invisible but present: it holds the string, the selection, and
            // the responder status. Never `.hidden()` — that would remove it from the
            // responder chain and it could no longer receive keystrokes or paste.
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .focused($focused)
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .onSubmit { if code.count == length { onComplete?() } }
                .onChange(of: code) { new in
                    let filtered = String(new.filter(\.isNumber).prefix(length))
                    if filtered != new { code = filtered }
                    if filtered.count == length { onComplete?() }
                }

            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { i in
                    box(at: i)
                }
            }
            // The boxes are decoration: any click on them focuses the one real field.
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .disabled(disabled)
        .onAppear { focused = true }
        // `.task` — NOT `.onAppear { Task { … } }`. SwiftUI cancels a `.task` when the view
        // disappears; a Task spawned from `onAppear` is never cancelled and never stored, so it
        // outlived the view AND a second one spawned on every re-appear (the student verify card
        // toggles between its email and code steps). Multiple immortal timers then wrote
        // `caretVisible` on the same beat and fought each other — erratic blinking that never
        // stopped, plus a leaked task per appearance.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(550))
                if Task.isCancelled { return }
                caretVisible = (focused && code.count < length) ? !caretVisible : true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(length)-digit verification code")
        .accessibilityValue(code.isEmpty ? "empty" : code.map(String.init).joined(separator: " "))
    }

    @ViewBuilder private func box(at index: Int) -> some View {
        // The "cursor" sits on the next empty box, clamped to the last one once the code is
        // full — otherwise the highlight would fall off the end and the field would look
        // inactive the moment the user finished typing.
        let cursorIndex = min(code.count, length - 1)
        let isActive = focused && !disabled && index == cursorIndex
        let filled = index < digits.count

        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: isActive ? 2 : 1)
            )
            .overlay {
                if filled {
                    Text(String(digits[index]))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                } else if isActive && caretVisible {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 22)
                }
            }
            .frame(width: 46, height: 56)
            .animation(.easeOut(duration: 0.12), value: filled)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}
