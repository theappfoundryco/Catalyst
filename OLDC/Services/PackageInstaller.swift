import Foundation

/// Builds and runs a single package install command (pip / brew formula / brew
/// cask), extracted out of `PopularPackagesViewModel` (R1). Stateless: it
/// sanitizes, constructs the right command for the package type, streams output
/// through `onOutput`, and returns a result that distinguishes "couldn't start"
/// from "ran and succeeded/failed" — the failure case carries a short message
/// the ViewModel can surface as an error banner (P3).
struct PackageInstaller {

    enum Result {
        case success
        case failure(message: String)
        case invalidName
        case noPython
    }

    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func install(name: String, type: PackageType, pythonPath: String?, pythonVersion: String? = nil, onOutput: @escaping (String) -> Void) async -> Result {
        let typeLabel: String
        switch type {
        case .pip: typeLabel = "🐍 PIP"
        case .brewFormula: typeLabel = "🍺 BREW FORMULA"
        case .brewCask: typeLabel = "🍺 BREW CASK"
        }

        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("       \(typeLabel) INSTALLATION", category: .terminal)
        logger.log("       Package: \(name)", category: .terminal)
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)

        logger.log("📦 Installing \(name)...")

        // Validate package name to prevent command injection.
        guard let sanitizedName = InputSanitizer.sanitizePackageName(name) else {
            logger.log("❌ Invalid package name: \(name)")
            return .invalidName
        }

        let command: String
        switch type {
        case .pip:
            guard let pythonPath else {
                logger.log("❌ No Python version selected")
                return .noPython
            }
            let flags = InstallPreferences.pipFlags(forPythonVersion: pythonVersion)
            command = "\(InputSanitizer.singleQuote(pythonPath)) -m pip install \(InputSanitizer.singleQuote(sanitizedName)) \(flags)"
        case .brewFormula:
            let pathBin = InputSanitizer.singleQuote(BrewPathManager.shared.homebrewPrefix + "/bin")
            let brewPath = InputSanitizer.singleQuote(BrewPathManager.shared.brewPath)
            command = "export PATH=\(pathBin):\"$PATH\" && \(brewPath) install \(InputSanitizer.singleQuote(sanitizedName))"
        case .brewCask:
            let pathBin = InputSanitizer.singleQuote(BrewPathManager.shared.homebrewPrefix + "/bin")
            let brewPath = InputSanitizer.singleQuote(BrewPathManager.shared.brewPath)
            command = "export PATH=\(pathBin):\"$PATH\" && \(brewPath) install --cask \(InputSanitizer.singleQuote(sanitizedName))"
        }

        return await run(command, packageName: name, onOutput: onOutput)
    }

    private func run(_ command: String, packageName: String, onOutput: @escaping (String) -> Void) async -> Result {
        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(command: command) { text in
                onOutput(text)
            }

            if exitCode == 0 {
                logger.log("✅ Installation completed")
                onOutput("\n\n✅ Installation completed successfully!")
                return .success
            } else {
                logger.log("❌ Installation failed")
                onOutput("\n\n❌ Installation failed")
                return .failure(message: "Failed to install \(packageName) (exit code \(exitCode)). See the output log for details.")
            }
        } catch {
            logger.log("❌ Error: \(error.localizedDescription)")
            onOutput("\n\n❌ Error: \(error.localizedDescription)")
            return .failure(message: "Error installing \(packageName): \(error.localizedDescription)")
        }
    }
}
