//
//  Validators.swift
//  Catalyst
//
//  The one place input rules live. Each returns a **user-facing reason** when invalid and `nil`
//  when valid — the same contract as `VirtualEnvCreationViewModel.venvNameError`, so every
//  screen can render errors identically (inline orange `Label`, confirm disabled until valid)
//  and nobody has to invent a second convention.
//
//  Why a shared type rather than a copy per view model: the venv rule already lives inline on
//  its VM, and duplicating that pattern for email would have put the same regex in two view
//  models with two chances to drift. See `goLive.md §9` — this is the extraction that item
//  called for; other fields (package names, aliases, PATH entries, SSH key names) move here next.
//

import Foundation

enum Validators {

    // MARK: - Email

    /// Pragmatic email shape check — deliberately NOT RFC 5322.
    ///
    /// A fully-compliant RFC regex accepts things no mail provider will (quoted locals, IP
    /// literals, comments) while being unreadable and unmaintainable. This targets the actual
    /// goal: catch typos before we spend an OTP send on an address that can't receive it. The
    /// server remains the authority — this is a courtesy check, not a security boundary.
    ///
    /// Requires: a non-empty local part of permitted characters, an `@`, a domain with at least
    /// one dot, and a TLD of 2+ letters.
    private static let emailPattern =
        #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}$"#

    /// Validate an email address. Returns a reason when invalid, else `nil`.
    ///
    /// Ordered from most-specific to most-generic so the message is actionable: "you're missing
    /// an @" beats a blanket "that doesn't look right" when we can tell exactly what's wrong.
    static func email(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.isEmpty { return "Enter your email address." }
        if value.count > 254 { return "That address is too long." }          // RFC 5321 limit
        if value.contains(" ") { return "Email addresses can’t contain spaces." }

        let parts = value.components(separatedBy: "@")
        if parts.count == 1 { return "Add the @ — e.g. you@example.com" }
        if parts.count > 2 { return "An email address can only have one @." }

        let local = parts[0], domain = parts[1]
        if local.isEmpty { return "Add the part before the @." }
        if domain.isEmpty { return "Add the part after the @ — e.g. gmail.com" }
        if !domain.contains(".") { return "The domain needs a dot — e.g. gmail.com" }
        if value.contains("..") { return "Remove the double dot." }
        if local.hasPrefix(".") || local.hasSuffix(".") { return "The part before the @ can’t start or end with a dot." }

        if value.range(of: emailPattern, options: .regularExpression) == nil {
            return "That doesn’t look like a valid email address."
        }
        return nil
    }

    /// True when `email` returns no complaint.
    static func isValidEmail(_ raw: String) -> Bool { email(raw) == nil }

    // MARK: - Academic addresses

    /// Mirrors the Worker's `isAcademicEmail` allowlist. Kept in sync BY HAND — the server is
    /// authoritative, this only exists so the app can warn before spending a request.
    ///
    /// Deliberately suffix-matched the same way, so `foo.ac.in` and `bar.edu` both match while
    /// `notanedu.com` doesn't.
    private static let academicSuffixes = [".edu", ".ac.in", ".edu.in", ".ac.uk"]

    static func isAcademicEmail(_ raw: String) -> Bool {
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: "@").last ?? ""
        guard !domain.isEmpty else { return false }
        return academicSuffixes.contains { domain == $0.dropFirst() || domain.hasSuffix($0) }
    }

    /// Validation for the PRIMARY account email: valid shape, and never academic.
    ///
    /// A university mailbox is deactivated after graduation, but a Catalyst licence is for life —
    /// so an academic primary would eventually lock the owner out of something they still own.
    /// The server enforces this (`academic_email_not_primary`); catching it here means the user
    /// finds out while typing rather than after waiting for a code that never arrives.
    static func primaryAccountEmail(_ raw: String) -> String? {
        if let problem = email(raw) { return problem }
        if isAcademicEmail(raw) {
            return "School emails stop working after you graduate — use a personal one you'll keep. You can add your school email later for the student discount."
        }
        return nil
    }

    /// Validation for the SECONDARY academic email used to claim the student discount — the
    /// exact inverse of `primaryAccountEmail`: here it MUST be academic.
    static func studentEmail(_ raw: String) -> String? {
        if let problem = email(raw) { return problem }
        if !isAcademicEmail(raw) {
            return "Use your school email (.edu, .ac.in, .ac.uk…) — that's what proves you're a student."
        }
        return nil
    }
}
