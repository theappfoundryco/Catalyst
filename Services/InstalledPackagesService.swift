import Foundation

/// Single source of truth for listing installed pip / Homebrew packages.
///
/// The pip / formulae / cask listing logic was previously duplicated across
/// `PIPPackagesViewModel`, `BrewFormulaeCaskViewModel`, and
/// `PopularPackagesViewModel`. All three now delegate here. Results carry the
/// package name plus its version (when available) and use the safe array-args
/// execution path (no shell, no quoting).
///
/// ```swift
/// let pipPackages = await InstalledPackagesService.shared.pipPackages(pythonPath: "/usr/bin/python3")
/// let formulae = await InstalledPackagesService.shared.formulae()
/// ```
final class InstalledPackagesService {
    static let shared = InstalledPackagesService()
    private init() {}

    /// A listed package: normalized name plus version when the source reports one.
    typealias Listed = (name: String, version: String?)

    /// Installed pip packages for a given interpreter. Names are PEP 503 normalized.
    ///
    /// - Parameter pythonPath: Absolute path to the python executable (e.g. `/usr/bin/python3`).
    /// - Returns: A collection of `Listed` tuples containing parsed packages and versions.
    func pipPackages(pythonPath: String) async -> [Listed] {
        do {
            /// Bound the probe: a wedged `pip list` (broken interpreter, stuck index
            /// lookup) must not hang the caller — e.g. Snapshot's "diffing this Mac"
            /// awaits one of these per interpreter. On timeout `run` throws → caught
            /// below → treated as "no packages" so the flow proceeds.
            ///
            /// **Gotchas:** Treating a timeout identically to an empty list means temporary network latency might cause Catalyst to report a massive "missing packages" diff falsely.
            let result = try await AsyncProcessRunner.shared.run(
                executable: pythonPath,
                arguments: ["-m", "pip", "list", "--format=freeze"],
                timeoutSeconds: 30
            )
            return result.stdout.split(separator: "\n").compactMap { line -> Listed? in
                /// "name==version"; editable/url installs may lack "==".
                ///
                /// **Rationale:** Ensures Catalyst correctly tracks dependencies linked directly via GitHub SHAs or local developer pathways (`pip install -e .`).
                let parts = line.components(separatedBy: "==")
                guard let first = parts.first, !first.isEmpty else { return nil }
                let name = InputSanitizer.normalizePipPackageName(first)
                let version = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
                return (name, version)
            }
        } catch {
            return []
        }
    }

    /// Installed Homebrew formulae (lowercased names + version).
    ///
    /// - Returns: A collection of `Listed` tuples parsed from `brew list --formula --versions`.
    func formulae() async -> [Listed] {
        await brewList(cask: false)
    }

    /// Installed Homebrew casks (lowercased names + version).
    ///
    /// - Returns: A collection of `Listed` tuples parsed from `brew list --cask --versions`.
    func casks() async -> [Listed] {
        await brewList(cask: true)
    }

    /// Centralized dispatcher for resolving Homebrew inventory via standard `AsyncProcessRunner` APIs.
    ///
    /// - Parameter cask: If true, targets macOS GUI apps (`--cask`), otherwise CLI dependencies (`--formula`).
    /// - Returns: The extracted array of installed items.
    private func brewList(cask: Bool) async -> [Listed] {
        guard BrewPathManager.shared.isInstalled else { return [] }
        let brewPath = BrewPathManager.shared.brewPath
        guard FileManager.default.fileExists(atPath: brewPath) else { return [] }

        /// `brew list --versions` prints "name 1.2.3".
        ///
        /// **Gotchas:** Some legacy casks inject trailing beta identifiers (e.g. `1.2.3,beta`); tokenizing strictly by space risks dropping the version suffix.
        let args = cask ? ["list", "--cask", "--versions"] : ["list", "--formula", "--versions"]
        do {
            /// Bounded so a wedged brew can't hang callers like Snapshot's diff.
            ///
            /// **Rationale:** Homebrew natively triggers synchronous auto-updates before listing; a 25-second limit prevents Apple Silicon UI starvation during GitHub API outages.
            let result = try await AsyncProcessRunner.shared.run(executable: brewPath, arguments: args, timeoutSeconds: 25)
            return result.stdout.split(separator: "\n").compactMap { line -> Listed? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard let first = parts.first else { return nil }
                let version = parts.count > 1 ? String(parts[1]) : nil
                return (String(first).lowercased(), version)
            }
        } catch {
            return []
        }
    }
}
