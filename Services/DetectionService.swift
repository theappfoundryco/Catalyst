import Foundation

/// Performs tool-presence detection (Command Line Tools, Homebrew, system &
/// installed Pythons, pip) by running shell probes off the main thread.
///
/// This is the detection *logic* extracted from `DashboardViewModel` (R1 / P2
/// god-VM decomposition, step 1). It owns no `@Published` view state and makes
/// no display decisions — it returns plain values, and the ViewModel maps those
/// to its status strings/colors. Keeping it `@MainActor` matches the VM's
/// isolation so the move stays mechanical and Sendable-clean.
///
/// ```swift
/// let service = DetectionService(brewService: brew, pythonService: python, logger: logger)
/// let toolsState = await service.detectCommandLineTools()
/// ```
@MainActor
final class DetectionService {
    private let brewService: BrewService
    private let pythonService: PythonService
    private let logger: Logger

    init(brewService: BrewService, pythonService: PythonService, logger: Logger) {
        self.brewService = brewService
        self.pythonService = pythonService
        self.logger = logger
    }

    /// System Python detection result: a version string plus an optional
    /// human-readable error explaining a "Not Available" outcome.
    struct SystemPython {
        let version: String
        let error: String?
    }

    /// pip detection outcome for the first installed Python. The VM maps each
    /// case to a display string + color.
    enum Pip {
        case version(String)   // resolved pip version (green)
        case available         // pip present but version unparsed (green)
        case notAvailable      // probe failed (red)
        case noPython          // no usable Python with pip (secondary)
    }

    /// Detect Apple/Xcode Command Line Tools via `xcode-select -p`, falling back
    /// to the well-known install path if the probe throws.
    ///
    /// - Returns: A boolean representation (mapped to ``DetectionState``) of Xcode CLT availability.
    func detectCommandLineTools() async -> DetectionState {
        do {
            let result = try await AsyncProcessRunner.shared.run(command: "xcode-select -p")
            if result.succeeded && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .installed
            }
            return .notInstalled
        } catch {
            /// Fallback: check the common installation path if xcode-select fails.
            ///
            /// **Rationale:** `xcode-select` intermittently fails inside tightly sandboxed daemon environments despite the CLI tools being perfectly usable.
            return FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools")
                ? .installed
                : .notInstalled
        }
    }

    /// Detect Homebrew presence via `BrewService`.
    ///
    /// - Returns: State enumerator denoting Homebrew's binary status.
    func detectBrew() async -> DetectionState {
        do {
            try await brewService.detectHomebrew()
            return .installed
        } catch {
            return .notInstalled
        }
    }

    /// Detect the OS-provided `/usr/bin/python3`. A missing binary makes the
    /// runner throw, which we surface cleanly as "Not Available".
    ///
    /// - Returns: A ``SystemPython`` response describing version or error.
    func detectSystemPython() async -> SystemPython {
        do {
            let result = try await AsyncProcessRunner.shared.run(command: "/usr/bin/python3 --version")
            if result.succeeded {
                if let version = result.combinedOutput.components(separatedBy: " ").dropFirst().first {
                    return SystemPython(version: version.trimmingCharacters(in: .whitespacesAndNewlines), error: nil)
                }
                return SystemPython(version: "Unknown", error: nil)
            }
            return SystemPython(version: "Not Available", error: "Exit code \(result.exitCode): \(result.stderr)")
        } catch {
            return SystemPython(version: "Not Available", error: error.localizedDescription)
        }
    }

    /// Detect all installed Python installations via `PythonService`.
    ///
    /// - Returns: An array of ``PythonInstallation`` models harvested globally.
    func detectInstalledPythons() async -> [PythonInstallation] {
        do {
            let pythons = try await pythonService.detectPythons()
            logger.log("✅ Found \(pythons.count) Python installation(s)")
            return pythons
        } catch {
            return []
        }
    }

    /// Probe pip for the first installed Python (if any reports pip available).
    ///
    /// - Parameter firstPython: The primary ``PythonInstallation`` to interrogate.
    /// - Returns: A ``Pip`` enum modeling availability, absence, or failure.
    func detectPip(for firstPython: PythonInstallation?) async -> Pip {
        guard let firstPython, firstPython.pipAvailable else {
            return .noPython
        }

        let command = "\(InputSanitizer.singleQuote(firstPython.path.path)) -m pip --version"
        do {
            /// Timeout: a wedged `pip --version` must not stall detection (see AsyncProcessRunner).
            ///
            /// **Gotchas:** A blocked `pip` process (e.g. waiting on a broken network mount) will permanently hang the entire Catalyst UI if left unbounded.
            let result = try await AsyncProcessRunner.shared.run(command: command, timeoutSeconds: 10)
            if result.succeeded,
               let versionPart = result.stdout.components(separatedBy: " ").dropFirst().first {
                return .version(versionPart)
            }
            return .available
        } catch {
            return .notAvailable
        }
    }

    /// The newest pip version actually INSTALLABLE on `python`, or `nil` if pip
    /// is already current there. Asks the interpreter's own pip via
    /// `pip list --outdated` — the single source of truth — rather than PyPI's
    /// absolute `info.version`. So the answer honors `Requires-Python` and
    /// reflects exactly what *this* interpreter would install, matching the pip
    /// Updates screen (see Understanding §7/§46). One global PyPI "latest"
    /// applied to every interpreter was the same over-reporting bug that offered
    /// numpy 2.5 on Python 3.11.
    ///
    /// - Parameter python: The exact python interpreter context to query.
    /// - Returns: The string representation of the next valid pip upgrade, or `nil` if current/incompatible.
    func detectPipUpgrade(for python: PythonInstallation) async -> String? {
        guard python.pipAvailable else { return nil }
        let command = "\(InputSanitizer.singleQuote(python.path.path)) -m pip list --outdated --format=json 2>/dev/null"
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            /// Standardized JSON schema for PyPI update checking results.
struct PipOutdated: Codable {
                let name: String
                let version: String
                let latest_version: String
            }
            guard let data = result.stdout.data(using: .utf8),
                  let packages = try? JSONDecoder().decode([PipOutdated].self, from: data),
                  let latest = packages.first(where: { $0.name.lowercased() == "pip" })?.latest_version else {
                return nil
            }
            /// Only surface it if it's genuinely newer than the version this
            /// interpreter actually runs (`pip --version`). Guards against pip's
            /// metadata reporting an "upgrade" to the SAME version — e.g. a stale
            /// duplicate dist-info left by an --ignore-installed reinstall over a
            /// RECORD-less Homebrew pip, where `pip list --outdated` reads the old
            /// dist-info while the interpreter imports the new one.
            ///
            /// **Gotchas:** Blindly trusting `pip list --outdated` creates an infinite upgrade loop where the stale dist-info is never purged, permanently pinning the UI in an "upgrade available" state.
            if let installed = python.pipVersion,
               !VersionComparator.isOlder(installed, than: latest) {
                return nil
            }
            return latest
        } catch {
            return nil
        }
    }
}
