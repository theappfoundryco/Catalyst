import Foundation

/// Filesystem/process work for the virtual-environment creation wizard,
/// extracted out of `VirtualEnvCreationViewModel` (R1). Stateless and holds no
/// view state: each method streams human-readable lines through an `onOutput`
/// callback and returns plain results, so the ViewModel keeps its `@Published`
/// state and orchestration. The streaming `python -m venv` / `pip install -r`
/// calls stay in the VM (their exit codes drive VM error messages directly).
struct VenvBuilder {

    /// Outcome of verifying which requested packages actually installed.
    enum VerifyOutcome {
        case success(successful: [String], failed: [String])
        case requirementsUnreadable
        case freezeFailed(stderr: String)
        case systemError(String)
    }

    /// Append the venv folder to `.gitignore` (creating the file if missing),
    /// streaming status lines. Best-effort — failures are reported via output.
    func writeGitignore(projectPath: URL, venvName: String, onOutput: (String) -> Void) {
        let gitignorePath = projectPath.appendingPathComponent(".gitignore").path
        let entry = "\n# Virtual Environment\n\(venvName)/\n"

        onOutput("📝 Updating .gitignore...\n")
        do {
            if FileManager.default.fileExists(atPath: gitignorePath) {
                let fileURL = URL(fileURLWithPath: gitignorePath)
                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } else {
                try entry.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
            }
            onOutput("✅ Added \(venvName)/ to .gitignore\n")
        } catch {
            onOutput("⚠️ Failed to update .gitignore: \(error.localizedDescription)\n")
        }
    }

    /// Verify installed packages against `requirements.txt` using a native set
    /// difference over `pip freeze` (no shell pipeline). Streams progress.
    func verify(venvPath: String, projectPath: String, onOutput: @escaping (String) -> Void) async -> VerifyOutcome {
        onOutput("\n🔎 Verifying installed packages...\n")
        onOutput("📂 Project Path: \(projectPath)\n")

        let reqPath = URL(fileURLWithPath: projectPath).appendingPathComponent("requirements.txt").path
        let pythonPath = venvPath + "/bin/python3"

        // 1. Parse requested package names natively.
        guard let contents = try? String(contentsOfFile: reqPath, encoding: .utf8) else {
            onOutput("❌ Could not read requirements.txt at \(reqPath)\n")
            return .requirementsUnreadable
        }
        let requested = Set(RequirementsParser.names(from: contents))

        // 2. Installed package names from the venv via array-args pip freeze.
        let installed: Set<String>
        do {
            onOutput("⚙️ Reading installed packages (pip freeze)...\n")
            let result = try await AsyncProcessRunner.shared.run(
                executable: pythonPath,
                arguments: ["-m", "pip", "freeze"]
            )
            guard result.succeeded else {
                onOutput("❌ pip freeze failed:\n\(result.stderr)\n")
                return .freezeFailed(stderr: result.stderr)
            }
            installed = Set(result.stdout.components(separatedBy: .newlines).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-") else { return nil }
                // "name==version" or "name @ url"
                let base = trimmed.components(separatedBy: "==").first ?? trimmed
                let name = base.components(separatedBy: " @").first ?? base
                let cleaned = name.trimmingCharacters(in: .whitespaces)
                return cleaned.isEmpty ? nil : RequirementsParser.normalize(cleaned)
            })
        } catch {
            onOutput("❌ Verification System Error: \(error.localizedDescription)\n")
            return .systemError(error.localizedDescription)
        }

        // 3. Native set difference.
        let failed = requested.subtracting(installed).sorted()
        let successful = requested.intersection(installed).sorted()

        if failed.isEmpty {
            onOutput("✅ All \(successful.count) requested packages are installed.\n")
        } else {
            onOutput("⚠️ Missing packages:\n\(failed.joined(separator: "\n"))\n")
        }
        onOutput("✅ Verification Complete. Success: \(successful.count), Failed: \(failed.count)\n")

        return .success(successful: successful, failed: failed)
    }

    /// Retry installing specific packages one at a time via the venv's pip.
    /// Streams per-package output.
    func retryInstall(packages: [String], pipPath: String, onOutput: @escaping (String) -> Void) async {
        for package in packages {
            guard let sanitizedPackage = InputSanitizer.sanitizePackageName(package) else {
                onOutput("❌ Invalid package name: \(package)\n")
                continue
            }

            onOutput("Installing \(sanitizedPackage)...\n")
            let command = "\(InputSanitizer.singleQuote(pipPath)) install \(InputSanitizer.singleQuote(sanitizedPackage))"

            do {
                let result = try await AsyncProcessRunner.shared.run(command: command)
                onOutput(result.combinedOutput + "\n")
                onOutput(result.succeeded ? "✅ \(package) installed\n" : "❌ \(package) install failed\n")
            } catch {
                onOutput("❌ Error: \(error.localizedDescription)\n")
            }
        }
    }
}
