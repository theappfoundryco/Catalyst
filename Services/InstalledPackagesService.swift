import Foundation

/// Single source of truth for listing installed pip / Homebrew packages.
///
/// The pip / formulae / cask listing logic was previously duplicated across
/// `PIPPackagesViewModel`, `BrewFormulaeCaskViewModel`, and
/// `PopularPackagesViewModel`. All three now delegate here. Results carry the
/// package name plus its version (when available) and use the safe array-args
/// execution path (no shell, no quoting).
final class InstalledPackagesService {
    static let shared = InstalledPackagesService()
    private init() {}

    /// A listed package: normalized name plus version when the source reports one.
    typealias Listed = (name: String, version: String?)

    /// Installed pip packages for a given interpreter. Names are PEP 503 normalized.
    func pipPackages(pythonPath: String) async -> [Listed] {
        do {
            // Bound the probe: a wedged `pip list` (broken interpreter, stuck index
            // lookup) must not hang the caller — e.g. Snapshot's "diffing this Mac"
            // awaits one of these per interpreter. On timeout `run` throws → caught
            // below → treated as "no packages" so the flow proceeds.
            let result = try await AsyncProcessRunner.shared.run(
                executable: pythonPath,
                arguments: ["-m", "pip", "list", "--format=freeze"],
                timeoutSeconds: 30
            )
            return result.stdout.split(separator: "\n").compactMap { line -> Listed? in
                // "name==version"; editable/url installs may lack "==".
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
    func formulae() async -> [Listed] {
        await brewList(cask: false)
    }

    /// Installed Homebrew casks (lowercased names + version).
    func casks() async -> [Listed] {
        await brewList(cask: true)
    }

    private func brewList(cask: Bool) async -> [Listed] {
        guard BrewPathManager.shared.isInstalled else { return [] }
        let brewPath = BrewPathManager.shared.brewPath
        guard FileManager.default.fileExists(atPath: brewPath) else { return [] }

        // `brew list --versions` prints "name 1.2.3".
        let args = cask ? ["list", "--cask", "--versions"] : ["list", "--formula", "--versions"]
        do {
            // Bounded so a wedged brew can't hang callers like Snapshot's diff.
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
