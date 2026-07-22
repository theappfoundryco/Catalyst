import Foundation

/// A minimal FIFO async semaphore that caps how many shell processes run concurrently.
///
/// Why this exists: a launch-time burst of detection probes (`fullRefresh` fans out ~10
/// view models, several of which shell out) would previously spawn dozens of `/bin/zsh -c`
/// processes at once. The shell path (`run(command:)`) drains its pipes with a **blocking**
/// `readToEnd` on the cooperative thread pool, so a big enough burst exhausts the pool —
/// after which even `Task.sleep`-based timeouts can't resume, and views like Git Graph spin
/// forever. Capping concurrent launches bounds the number of simultaneously-blocked reader
/// threads so the pool always has headroom.
///
/// Correctness: a fast-path acquire increments `active`; when at the limit the caller parks on
/// a continuation and a later `release()` transfers the permit directly (so `active` is
/// changed and the woken caller holds it). A caller cancelled while parked is still resumed
/// by the next `release()` (FIFO drains it) — it then proceeds or bails on `Task.isCancelled`,
/// so there's no permanent leak under normal churn.
///
/// ```swift
/// let limiter = AsyncConcurrencyLimiter(limit: 6)
/// await limiter.acquire()
/// // ...
/// await limiter.release()
/// ```
actor AsyncConcurrencyLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    /// Suspends the caller if the execution pool is at capacity until a slot frees up.
    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Relinquishes a concurrency slot, immediately resuming the next suspended waiter if any exist.
    func release() {
        if waiters.isEmpty { active = max(0, active - 1) }
        else { waiters.removeFirst().resume() }
    }
}

/// Actor for running shell commands asynchronously without blocking the main thread.
///
/// `AsyncProcessRunner` solves UI freezing issues caused by `Process.waitUntilExit()`
/// on `@MainActor` contexts by isolating process execution in a dedicated actor.
///
/// ```swift
/// let result = try await AsyncProcessRunner.shared.run(command: "ls -la")
/// print(result.stdout)
/// ```
actor AsyncProcessRunner {
    /// Shared singleton instance.
    static let shared = AsyncProcessRunner()

    private init() {}

    /// NOTE: the old `AsyncConcurrencyLimiter(limit: 6)` throttle was REMOVED (2026-07-17).
    /// Its only job was to bound how many blocking `readToEnd` calls ran on the Swift cooperative
    /// pool at once, to avoid pool exhaustion. Now that `readToEnd` runs on a libdispatch queue
    /// (see `readToEnd` below), that exhaustion is impossible — and the throttle itself could STARVE
    /// a probe forever: a call parked at `acquire()` never spawns its process, so the safety
    /// timeout (which only guards a running child) can't rescue it. That was the intermittent
    /// launch freeze (a `sh REQUEST` with no matching `sh PERMIT` in the logs). Detection's ~40
    ///
    /// **Rationale:** Removing the application-level concurrency lock shifts thread lifecycle management back to the OS, which is far better equipped to handle IO multiplexing.
    /// short-lived probes run fine unthrottled; long installs already use `runWithStreaming`.
    ///
    /// **Rationale:** Prevents queue starvation during mass dependency resolution where hundreds of fast commands (like `which python3`) are fired simultaneously.

    /// The result of a process execution.
    ///
    /// ```swift
    /// if result.succeeded { print(result.stdout) }
    /// ```
    struct ProcessResult {
        /// Standard output from the process.
        let stdout: String
        /// Standard error from the process.
        let stderr: String
        /// Exit code of the process.
        let exitCode: Int32
        
        /// Whether the process exited successfully.
        var succeeded: Bool { exitCode == 0 }
        /// Combined standard output and standard error.
        var combinedOutput: String { stdout + stderr }
    }
    
    /// Errors thrown by the array-args execution path.
    ///
    /// ```swift
    /// catch AsyncProcessRunner.ProcessError.timedOut(let seconds) { ... }
    /// ```
    enum ProcessError: Error, LocalizedError {
        /// The process could not be launched.
        case failedToLaunch(String)
        /// The process exceeded its timeout and was terminated.
        case timedOut(seconds: Double)

        var errorDescription: String? {
            switch self {
            case .failedToLaunch(let msg): return "Failed to launch process: \(msg)"
            case .timedOut(let s): return "Process timed out after \(Int(s))s"
            }
        }
    }

    /// Executes an executable directly with an argument array — **no shell, no
    /// quoting**. Arguments are passed as argv, so package names and paths can
    /// never be reinterpreted by the shell. This is the safe path and should be
    /// preferred over `run(command:)` for any call that interpolates user or
    /// system values (package names, file paths, brew prefixes).
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the binary to run.
    ///   - arguments: Argument vector, passed verbatim to the process.
    ///   - environment: Extra environment variables merged onto the inherited environment.
    ///   - timeoutSeconds: If set, the child is SIGTERM'd (then SIGKILL'd) after this many seconds.
    /// - Returns: A `ProcessResult` with stdout, stderr, and exit code.
    /// - Throws: `ProcessError.failedToLaunch` or `ProcessError.timedOut`.
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeoutSeconds: Double? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment { env[key] = value }
            process.environment = env
        }
        return try await executeProcess(process, timeoutSeconds: timeoutSeconds)
    }

    /// Convenience for invoking the resolved Homebrew binary with a PATH that
    /// includes its prefix (brew shells out to git/curl), using the safe
    /// array-args path.
    /// - Parameters:
    ///   - arguments: The command-line flags array appended to the Homebrew invocation.
    ///   - extraEnvironment: Supplemental environment variables bound directly to the subshell.
    ///   - timeoutSeconds: An optional execution boundary triggering forced termination.
    /// - Returns: The aggregate execution state containing stdout, stderr, and exit codes.
    /// - Throws: Propagates process spawning exceptions or runtime timeouts.
    func runBrew(arguments: [String], extraEnvironment: [String: String] = [:], timeoutSeconds: Double? = nil) async throws -> ProcessResult {
        let prefix = BrewPathManager.shared.homebrewPrefix
        /// Setting `environment` REPLACES the whole env, so we must pass everything brew needs.
        /// `HOME` is required (brew is Ruby → uses ~/Library/Caches/Homebrew); without it brew
        /// misbehaves intermittently (a cause of first-launch load flakiness, worst under Xcode).
        ///
        /// **Gotchas:** Omitting `HOME` when explicitly constructing the `ProcessInfo` environment array will cause Homebrew to fail silently with opaque Ruby cache errors.
        var env: [String: String] = [
            "PATH": "\(prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
        for (k, v) in extraEnvironment { env[k] = v }
        return try await run(
            executable: BrewPathManager.shared.brewPath,
            arguments: arguments,
            environment: env,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Shared execution core: wires pipes, honours Task cancellation (kills the
    /// child) and an optional timeout (SIGTERM then SIGKILL). The continuation
    /// is resumed exactly once, from the termination handler.
    /// - Parameters:
    ///   - process: The explicitly configured Foundation Process instance ready for launch.
    ///   - timeoutSeconds: The optional wall-clock limit before raising a timeout abort.
    /// - Returns: The aggregate execution state containing stdout, stderr, and exit codes.
    /// - Throws: Propagates task cancellation errors or direct binary launch failures.
    private func executeProcess(_ process: Process, timeoutSeconds: Double?) async throws -> ProcessResult {
        /// 🐛 DEBUG: same REQUEST/PERMIT/DONE tracing as run(command:) for the argv path.
        ///
        /// **Rationale:** Ensures parity in diagnostic logging between simple shell invocations and explicit argv process execution.
        let dbg = "\(process.executableURL?.lastPathComponent ?? "?") \((process.arguments ?? []).prefix(4).joined(separator: " "))"
        let t0 = Date()
        Logger.shared.debugLog("🐛 px START   | \(dbg)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        let dataLock = NSLock()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { dataLock.lock(); stdoutData.append(data); dataLock.unlock() }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { dataLock.lock(); stderrData.append(data); dataLock.unlock() }
        }

        let stateLock = NSLock()
        var didTimeout = false
        var timeoutTask: Task<Void, Never>?

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { proc in
                    timeoutTask?.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let trailingOut = try? stdoutPipe.fileHandleForReading.readToEnd()
                    let trailingErr = try? stderrPipe.fileHandleForReading.readToEnd()

                    dataLock.lock()
                    if let trailingOut { stdoutData.append(trailingOut) }
                    if let trailingErr { stderrData.append(trailingErr) }
                    let out = String(data: stdoutData, encoding: .utf8) ?? ""
                    let err = String(data: stderrData, encoding: .utf8) ?? ""
                    dataLock.unlock()

                    stateLock.lock(); let timedOut = didTimeout; stateLock.unlock()
                    Logger.shared.debugLog("🐛 px DONE    | +\(Self.msSince(t0))ms exit=\(proc.terminationStatus)\(timedOut ? " (TIMEOUT)" : "") | \(dbg)")
                    if timedOut {
                        continuation.resume(throwing: ProcessError.timedOut(seconds: timeoutSeconds ?? 0))
                    } else {
                        continuation.resume(returning: ProcessResult(stdout: out, stderr: err, exitCode: proc.terminationStatus))
                    }
                }

                do {
                    try process.run()
                    if let timeoutSeconds {
                        timeoutTask = Task {
                            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                            if Task.isCancelled { return }
                            if process.isRunning {
                                stateLock.lock(); didTimeout = true; stateLock.unlock()
                                process.terminate()
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            }
                        }
                    }
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ProcessError.failedToLaunch(error.localizedDescription))
                }
            }
        } onCancel: {
            /// Only terminate a process that actually launched. If the task is cancelled
            /// before `process.run()` (e.g. a shortcuts search cancels an in-flight probe),
            /// calling terminate() on an unlaunched NSTask throws NSInvalidArgumentException
            /// ("task not launched") and crashes the app.
            ///
            /// **Gotchas:** Blindly sending SIGTERM to an unlaunched `Process` instance instantly crashes the parent application on macOS.
            if process.isRunning { process.terminate() }
        }
    }

    /// Executes a shell command and returns the execution result.
    ///
    /// - Parameters:
    ///   - command: The bash command to execute.
    ///   - useLoginShell: A Boolean value indicating whether to run as a login shell. Defaults to `false`.
    /// - Returns: A `ProcessResult` containing standard output, standard error, and the exit code.
    /// - Throws: An error if the process fails to start.
    func run(command: String, useLoginShell: Bool = false, timeoutSeconds: Double? = nil) async throws -> ProcessResult {
        /// 🐛 DEBUG instrumentation. REQUEST = call entered; PERMIT = concurrency slot acquired
        /// (a big REQUEST→PERMIT gap ⇒ limiter/pool starvation); DONE = returned. A REQUEST with no
        /// matching DONE is the hung call; a REQUEST with no PERMIT is a starved queue.
        ///
        /// **Rationale:** A deterministic lifecycle log makes it trivial to identify concurrency exhaustion deadlocks without attaching a debugger.
        let dbg = String(command.prefix(70))
        let t0 = Date()
        Logger.shared.debugLog("🐛 sh START   | \(dbg)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = useLoginShell ? ["-l", "-c", command] : ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        Logger.shared.debugLog("🐛 sh SPAWN   | pid=\(process.processIdentifier) | \(dbg)")

        /// Safety timeout (opt-in). A probe that never exits (e.g. a wedged `python -m pip
        /// --version`) would otherwise block `readToEnd` on EOF forever, hold its concurrency
        /// permit, and — via the single-flight Python scan — wedge all of detection. Killing it
        /// lets the pipes close so this call returns and the permit is released. The actor is
        /// suspended at the `await outData/errData` reads below, so this actor-inheriting Task runs
        /// freely (mirrors `executeProcess`). Cancelled once the process exits.
        ///
        /// **Gotchas:** Omitting this timeout acts as a timebomb; a single wedged `python` subprocess can exhaust the app's concurrency pool permanently.
        let timeoutTask: Task<Void, Never>? = timeoutSeconds.map { secs in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                if process.isRunning {
                    Logger.shared.debugLog("🐛 sh TIMEOUT | killing after \(Int(secs))s | \(dbg)")
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        defer { timeoutTask?.cancel() }

        /// Drain both pipes to EOF on background threads. The previous approach
        /// accumulated output in a `readabilityHandler` and snapshotted it in the
        /// `terminationHandler`, which run on different threads with no completion
        /// barrier: an in-flight readability callback could append the final chunk
        /// *after* the snapshot was taken, intermittently truncating output to
        /// empty. For tiny probes like `xcode-select -p` an empty result read as
        /// "Not Installed" even when the tool was present — most visible under the
        /// parallel-startup load where every VM probes at once. Reading each pipe
        /// to EOF removes that race, and reading them concurrently avoids the
        /// 64 KB pipe-buffer deadlock on large output.
        ///
        /// **Gotchas:** Attempting to read a pipe sequentially instead of concurrently guarantees a process hang when a child tool writes >64KB to stdout/stderr.
        async let outData = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let errData = Self.readToEnd(stderrPipe.fileHandleForReading)

        let out = String(data: await outData, encoding: .utf8) ?? ""
        let err = String(data: await errData, encoding: .utf8) ?? ""
        Logger.shared.debugLog("🐛 sh READ    | +\(Self.msSince(t0))ms drained pipes | \(dbg)")

        /// Pipes have hit EOF (the child closed them at exit), so this returns
        /// promptly and just harvests the exit status.
        ///
        /// **Rationale:** Synchronously awaiting `waitUntilExit()` only after the pipes drain avoids race conditions where the process dies before its buffers flush.
        process.waitUntilExit()

        Logger.shared.debugLog("🐛 sh DONE    | +\(Self.msSince(t0))ms exit=\(process.terminationStatus) | \(dbg)")
        return ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }

    /// Milliseconds since `from` (debug timing helper).
    nonisolated static func msSince(_ from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }

    /// Reads a file handle to EOF on a detached background thread. `readToEnd()`
    /// blocks until the writer closes its end (the child process exiting), so
    /// invoking it for stdout and stderr concurrently drains both without
    /// deadlocking on a full pipe buffer.
    ///
    /// Only the raw file descriptor — an `Int32`, which is `Sendable` — crosses
    /// the concurrency boundary; the non-`Sendable` `FileHandle` is rebuilt
    /// inside the detached task. `closeOnDealloc: false` leaves ownership of the
    /// descriptor with the original `Pipe` (kept alive by `process`), so the fd
    /// stays valid for the lifetime of the read.
    private nonisolated static func readToEnd(_ handle: FileHandle) async -> Data {
        let fd = handle.fileDescriptor
        /// Run the BLOCKING `readToEnd` on a libdispatch global queue — NOT `Task.detached`, which
        /// runs on the Swift cooperative thread pool (width ≈ core count). Under a detection burst,
        /// several concurrent `run(command:)` calls each block TWO of those pool threads on EOF;
        /// enough of them exhaust the pool, after which NO Swift-concurrency work can run — not the
        /// scan's continuation, and not even the safety-timeout Tasks that are supposed to rescue a
        /// wedged probe. That's a total deadlock (the 2-minute launch freeze). libdispatch grows
        /// threads on demand, so blocking one of ITS threads never starves the cooperative pool.
        ///
        /// **Gotchas:** Using Swift Concurrency (`Task.detached`) for blocking file IO during high-burst phases will completely lock up the UI thread by starving the cooperative pool.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                continuation.resume(returning: (try? reader.readToEnd()) ?? Data())
            }
        }
    }
    
    /// Executes a shell command with real-time output streaming.
    ///
    /// - Parameters:
    ///   - command: The bash command to execute.
    ///   - onOutput: A closure invoked on the main actor with each chunk of output.
    /// - Returns: The exit code of the process.
    /// - Throws: An error if the process fails to start.
    func runWithStreaming(
        command: String,
        environment: [String: String]? = nil,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> Int32 {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]

            /// Merge any caller-supplied variables onto the inherited environment.
            /// Setting process.environment replaces it entirely, so seed from the
            /// current environment first. Used to pass secrets (e.g. a sudo
            /// password) in-memory instead of writing them to disk.
            ///
            /// **Rationale:** Passing ephemeral credentials via environment injection prevents exposing sensitive keys in the unified system log.
            if let environment {
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment { env[key] = value }
                process.environment = env
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            var outputBuffer = ""
            let bufferLock = NSLock()
            var flushTimer: Timer?
            
            let flushBuffer = {
                bufferLock.lock()
                let bufferedText = outputBuffer
                outputBuffer = ""
                bufferLock.unlock()
                
                if !bufferedText.isEmpty {
                    Task { @MainActor in
                        onOutput(bufferedText)
                    }
                }
            }
            
            flushTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                flushBuffer()
            }
            
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    bufferLock.lock()
                    outputBuffer += text
                    bufferLock.unlock()
                }
            }
            
            process.terminationHandler = { process in
                flushTimer?.invalidate()
                flushTimer = nil
                
                flushBuffer()
                
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: process.terminationStatus)
            }
            
            do {
                try process.run()
            } catch {
                flushTimer?.invalidate()
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Executes a command with the PATH environment variable configured for Homebrew.
    ///
    /// - Parameter command: The bash command to execute.
    /// - Returns: A `ProcessResult` containing standard output, standard error, and the exit code.
    /// - Throws: An error if the process fails to start.
    func runWithBrewPath(command: String) async throws -> ProcessResult {
        let pathBin = InputSanitizer.singleQuote(BrewPathManager.shared.homebrewPrefix + "/bin")
        let fullCommand = "export PATH=\(pathBin):\"$PATH\" && \(command)"
        return try await run(command: fullCommand)
    }
}
