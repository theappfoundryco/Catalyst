import Foundation
import Combine

/// Manages the user's *default* Python — the version a bare `python` / `python3` / `pip` resolves
/// to in new shells — by owning a single, marker-delimited block in `~/.zshrc_catalyst`.
///
/// SAFETY MODEL (this touches the most sensitive file a dev has, so the rules are strict):
///   • We NEVER edit `~/.zshrc` itself. Catalyst only ever writes/replaces/removes its OWN block
///     via `ShellConfigManager.writeManagedBlock(id:)` / `removeManagedBlock(id:)`, which locate
///     the block by its `# CATALYST_BEGIN python-default … # CATALYST_END` sentinels — by MARKER
///     SEARCH, not line position — so the user reordering lines can never make us hit the wrong
///     line. `.zshrc_catalyst` is sourced by one line at the bottom of `.zshrc`, so our block runs
///     last and wins PATH precedence.
///   • If the user already pinned a default themselves in `~/.zshrc`, we DETECT it read-only and
///     surface a warning ("ours will override it") — we do not modify their line. Reset removes
///     only our block, so their setting cleanly resurfaces (no orphaned commented lines).
///   • Before writing we verify the target `libexec/bin` actually exists on disk, and after writing
///     we syntax-check the file (`zsh -n`) and roll our block back if it doesn't parse.
///
/// Intel vs Apple Silicon: the ONLY difference is the Homebrew prefix (`/opt/homebrew` vs
/// `/usr/local`), which `BrewPathManager` resolves at runtime (correct even under Rosetta). The
/// `python@X.Y` formula name and the `…/opt/python@X.Y/libexec/bin` layout are identical on both.
@MainActor
final class PythonDefaultManager: ObservableObject {

    /// The origin of the currently configured global Python version.
    enum Source: Equatable { case none, catalyst, external }

    /// Represents the active Python state extracted from the shell profile.
    struct Current: Equatable {
        var version: String?     // major.minor, e.g. "3.12"; nil = no default detected
        var source: Source
    }

    /// The effective default we detected.
    @Published private(set) var current = Current(version: nil, source: .none)
    /// A default the user set OUTSIDE Catalyst (in `~/.zshrc`) that ours would override. nil if none.
    @Published private(set) var externalVersion: String?
    /// Picker selection — the chosen formula key, e.g. "python@3.12".
    @Published var selection: String?
    @Published private(set) var isApplying = false
    /// Last result/error line for the status banner.
    @Published private(set) var status: String?
    @Published private(set) var statusIsError = false

    private let blockId = "python-default"
    private let shell = ShellConfigManager.shared

    // MARK: - Detection

    /// Recompute the current default: our managed block first, then any external pin in `~/.zshrc`.
    func refresh() async {
        if let block = shell.readManagedBlock(id: blockId),
           let v = Self.pythonVersion(in: block) {
            current = Current(version: v, source: .catalyst)
            externalVersion = nil
            return
        }
        if let raw = shell.readMainConfig(), let v = Self.detectDefaultVersion(inZshrc: raw) {
            current = Current(version: v, source: .external)
            externalVersion = v
        } else {
            current = Current(version: nil, source: .none)
            externalVersion = nil
        }
    }

    // MARK: - Apply / Reset

    /// Point the default at `formula` (e.g. "python@3.12"). Writes only Catalyst's managed block.
    func apply(formula: String) async {
        isApplying = true
        status = nil
        statusIsError = false
        defer { isApplying = false }

        let version = Self.majorMinor(fromFormula: formula)
        let prefix = await BrewPathManager.shared.homebrewPrefix
        let libexecBin = "\(prefix)/opt/\(formula)/libexec/bin"

        /// SAFETY: never write a PATH entry to a directory that doesn't exist.
        ///
        /// **Gotchas:** Exporting a non-existent directory into the `$PATH` causes subsequent Python invocations to fall back to the stale system interpreter.
        guard FileManager.default.fileExists(atPath: "\(libexecBin)/python3") else {
            status = "Couldn't find \(formula) at \(libexecBin). Is it installed via Homebrew?"
            statusIsError = true
            return
        }

        shell.backupCatalystConfig()

        /// Double-quote so a space in the prefix survives; the whole entry is a fixed, app-built
        /// path (no user input), and `$PATH` must stay unquoted-expanded, so this form is correct.
        ///
        /// **Rationale:** Prevents catastrophic Bash parsing failures if the user's home directory or Homebrew prefix contains whitespace.
        let line = "export PATH=\"\(libexecBin):$PATH\""
        do {
            try shell.writeManagedBlock(id: blockId, content: line)
        } catch {
            status = "Failed to update shell config: \(error.localizedDescription)"
            statusIsError = true
            return
        }

        /// Validate the file still parses; if our block somehow broke it, roll back just our block.
        ///
        /// **Gotchas:** Blindly writing to `.zshrc` without syntactic validation risks completely locking users out of their shell environments if an unclosed quote is injected.
        if await !configParsesCleanly() {
            shell.removeManagedBlock(id: blockId)
            status = "The change was reverted — the shell config failed a safety check."
            statusIsError = true
            return
        }

        await refresh()
        selection = nil
        status = "Default set to Python \(version). Open a new terminal tab for it to take effect."
    }

    /// Remove Catalyst's default block. Any default the user set themselves is left untouched.
    func reset() async {
        isApplying = true
        defer { isApplying = false }
        shell.removeManagedBlock(id: blockId)
        await refresh()
        selection = nil
        status = "Catalyst's default was removed."
        statusIsError = false
    }

    /// `zsh -n <file>` parses without executing — a cheap syntax check. Missing file ⇒ treat as OK.
    private func configParsesCleanly() async -> Bool {
        let path = shell.catalystConfigPath.path
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            let result = try await AsyncProcessRunner.shared.run(
                command: "zsh -n \(InputSanitizer.singleQuote(path)) 2>&1")
            return result.exitCode == 0
        } catch {
            /// Couldn't run the check → don't block the user; the block only adds a fixed export.
            ///
            /// **Rationale:** Fails open on validation timeouts to prevent blocking perfectly valid environment injections just because a background shell hung.
            return true
        }
    }

    // MARK: - Parsing helpers

    /// Extract "3.12" from a line that mentions `python@3.12` (our block / formula form).
    static func pythonVersion(in text: String) -> String? {
        firstCapture(#"python@([0-9]+\.[0-9]+)"#, in: text)
    }

    /// Best-effort read-only detection of a default-Python pin the user wrote in `~/.zshrc`.
    /// Conservative: only inspects non-comment lines that look like a PATH/alias Python pin, so we
    /// don't false-warn on unrelated `python3.x` mentions. Returns the major.minor, or nil.
    static func detectDefaultVersion(inZshrc raw: String) -> String? {
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            /// Homebrew formula form: `export PATH="…/opt/python@3.12/libexec/bin:$PATH"`.
            ///
            /// **Rationale:** Homebrew natively keg-only's secondary Python versions; injecting the specific `libexec/bin` path ensures the user's shell can prioritize it without symlink collision.
            if line.contains("python@"), let v = firstCapture(#"python@([0-9]+\.[0-9]+)"#, in: line) {
                return v
            }
            /// Versioned-bin / alias forms, only when the line is clearly a PATH or alias pin.
            ///
            /// **Gotchas:** Broadly stripping all lines containing `python3` destroys totally unrelated shell functions or aliases that simply happen to invoke the interpreter.
            let looksLikePin = line.contains("PATH") || line.hasPrefix("alias ")
            if looksLikePin, let v = firstCapture(#"/python([0-9]+\.[0-9]+)"#, in: line) {
                return v
            }
        }
        return nil
    }

    /// Strips the `python@` prefix from a formula name to yield a raw version string.
    static func majorMinor(fromFormula formula: String) -> String {
        formula.replacingOccurrences(of: "python@", with: "")
    }

    /// Helper to extract the first regex capture group from a string.
    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
