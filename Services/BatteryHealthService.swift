import Foundation

/// Snapshot of battery state and long-term health.
struct BatteryReport: Sendable {
    let hasBattery: Bool
    /// Live charge level (0…100).
    let chargePercent: Int
    let isCharging: Bool
    /// "AC Power" or "Battery".
    let powerSource: String
    /// Human-readable time-to-full/empty (e.g. "4:32"), when estimable.
    let timeRemaining: String?

    let cycleCount: Int
    /// Maximum capacity as a percentage of design (battery "health").
    let maxCapacityPercent: Int
    /// The condition string as macOS itself words it — "Normal", "Good", "Service Recommended",
    /// and localized on a non-English Mac. **Display only.** Never branch on its value; use
    /// ``needsService``, which is computed once from signals that survive translation.
    let condition: String
    /// Whether the UI should present this battery as needing attention.
    ///
    /// **Gotchas:** The views used to derive this themselves with `condition == "Normal"`. That
    /// broke the moment the service started preferring Apple's own string over its own wording
    /// (#23): `sppower_battery_health` reports "Good" on plenty of healthy Macs, and anything at
    /// all on a localized one — so a perfectly fine battery rendered an orange warning triangle
    /// and "Consider servicing". Deciding it here, from the numbers, keeps the displayed wording
    /// Apple's and the judgement ours.
    let needsService: Bool
    let designCapacitymAh: Int?
    let fullChargeCapacitymAh: Int?
    let temperatureCelsius: Double?

    static let empty = BatteryReport(
        hasBattery: false, chargePercent: 0, isCharging: false, powerSource: "AC Power",
        timeRemaining: nil, cycleCount: 0, maxCapacityPercent: 0, condition: "Unknown",
        needsService: false,
        designCapacitymAh: nil, fullChargeCapacitymAh: nil, temperatureCelsius: nil
    )
}

/// Reads battery telemetry from `ioreg` (AppleSmartBattery) and `pmset`.
/// No dependencies, no privileges. Returns `hasBattery == false` on desktops.
///
/// ```swift
/// let report = await BatteryHealthService.shared.scan()
/// if report.hasBattery {
///     print("Charge: \(report.chargePercent)%")
/// }
/// ```
final class BatteryHealthService: Sendable {

    static let shared = BatteryHealthService()
    private init() {}

    private let runner = AsyncProcessRunner.shared

    /// Executes `ioreg` and `pmset` concurrently to construct a unified battery health snapshot.
    ///
    /// **Flow:**
    /// 1. Concurrently launches async tasks for `runIoreg()` and `runPmset()`.
    /// 2. Validates if an internal battery physically exists on the logic board.
    /// 3. Extracts cycle count and raw capacity from `AppleSmartBattery` dictionary.
    /// 4. Merges `pmset` charge and time-remaining values to construct the `BatteryReport`.
    ///
    /// - Returns: A hydrated ``BatteryReport`` or `.empty` on desktop Macs.
    func scan() async -> BatteryReport {
        async let ioregTask = runIoreg()
        async let pmsetTask = runPmset()
        /// Third concurrent probe (#23). `system_profiler` is the slowest of the
        /// three (1–3s), so it MUST stay inside the `async let` fan-out — wall time
        /// is then max(ioreg, pmset, system_profiler), not their sum.
        async let profilerTask = runSystemProfilerCapacity()
        let ioreg = await ioregTask
        let pmset = await pmsetTask
        let apple = await profilerTask

        let installed = (ioregValue("BatteryInstalled", in: ioreg) == "Yes")
            || (ioregValue("ExternalChargeCapable", in: ioreg) != nil && pmset.batteryLinePresent)
        guard installed && (ioregValue("DesignCapacity", in: ioreg) != nil || pmset.batteryLinePresent) else {
            /// No internal battery (desktop Mac).
            ///
            /// **Rationale:** Prevents a fatal unwrap when running Catalyst on Mac minis or Mac Studios which entirely lack an `AppleSmartBattery` property tree.
            return BatteryReport.empty
        }

        /// Prefer Apple's cycle count — see `runSystemProfilerCapacity` for why the
        /// ioreg parse can silently miss the nested compact form and report 0.
        let cycleCount = apple.cycleCount ?? intValue("CycleCount", in: ioreg) ?? 0
        let design = intValue("DesignCapacity", in: ioreg)
        /// Full-charge capacity — the FALLBACK path only (#23).
        ///
        /// **Gotchas:** This arithmetic does not reproduce what macOS displays, and no ordering
        /// of these keys will. `NominalChargeCapacity / DesignCapacity` is the closest of the
        /// three and still landed ~2 points high on the reporter's Mac (87% computed vs 85% in
        /// System Information) because Apple smooths the figure with an algorithm that isn't
        /// public. That is why `runSystemProfilerCapacity()` exists and why its result overrides
        /// `healthPercent` below. Keep this block for Intel and for macOS versions that don't
        /// publish `sppower_battery_health_maximum_capacity` — don't promote it back to primary.
        ///
        /// Ordering, best-effort first:
        /// - `NominalChargeCapacity` — smoothed, stable, closest to Apple's number.
        /// - `AppleRawMaxCapacity` — *instantaneous measured* capacity. Drifts with temperature
        ///   and charge state; the same Mac read 88% in-app and 84% from `ioreg` minutes later.
        ///   Only for Apple Silicon Macs that don't expose the nominal key.
        /// - `MaxCapacity` — the Intel path (real mAh there; on M-series it's a synthesized
        ///   100% that would mask degradation entirely, so it goes last).
        let rawMax = intValue("NominalChargeCapacity", in: ioreg)
            ?? intValue("AppleRawMaxCapacity", in: ioreg)
            ?? intValue("MaxCapacity", in: ioreg)

        var healthPercent = 0
        /// Sanity ceiling: a healthy battery can read slightly above design (notably
        /// when cold), but never by half. 1.2× rejects garbage parses without
        /// discarding legitimate >100% readings, which the `min(100,…)` then clamps.
        if let design, design > 0, let rawMax, rawMax > 0, Double(rawMax) <= Double(design) * 1.2 {
            healthPercent = min(100, max(0, Int((Double(rawMax) / Double(design) * 100).rounded())))
        }

        /// Apple's own figure wins outright when available (#23).
        ///
        /// **Rationale:** `NominalChargeCapacity / DesignCapacity` is the *right*
        /// formula but still not what Settings displays — Apple applies proprietary
        /// smoothing on top, so the arithmetic lands ~2 points high (87% vs 85% on
        /// the reporter's Mac). Rather than reverse-engineer that, read the number
        /// macOS itself publishes. Parity then holds by construction: Catalyst and
        /// System Information are quoting the same source.
        ///
        /// **Gotchas:** `sppower_battery_health_maximum_capacity` only exists on
        /// recent macOS (Apple Silicon). The ioreg arithmetic above stays as the
        /// fallback for older/Intel Macs, so this must not overwrite it with 0.
        if let appleCapacity = apple.maxCapacityPercent, appleCapacity > 0 {
            healthPercent = min(100, max(0, appleCapacity))
        }

        let permanentFailure = intValue("PermanentFailureStatus", in: ioreg) ?? 0
        let condition: String = {
            /// A hardware permanent-failure flag overrides everything, including
            /// Apple's own string — it's the one case where we know more than the
            /// summary does.
            if permanentFailure != 0 { return "Service Recommended" }
            /// Otherwise defer to Apple's condition for the same parity reason as the
            /// capacity figure: users cross-check this against System Information.
            if let appleCondition = apple.condition, !appleCondition.isEmpty { return appleCondition }
            if healthPercent > 0 && healthPercent < 80 { return "Service Recommended" }
            return "Normal"
        }()

        /// Decided from numbers, not from `condition`'s wording (#23).
        ///
        /// **Gotchas:** Never invert this into "healthy unless the string says Normal". Apple
        /// returns "Good" on many healthy Macs and a translated word on every non-English one,
        /// so an allowlist of English strings marks good batteries as failing — which is exactly
        /// the bug that preferring Apple's string introduced downstream. The string is only ever
        /// consulted for tokens that unambiguously mean *bad*; absent one, the capacity and the
        /// permanent-failure flag decide, and both are locale-proof.
        let needsService: Bool = {
            if permanentFailure != 0 { return true }
            if healthPercent > 0 && healthPercent < 80 { return true }
            let lowered = condition.lowercased()
            return ["service", "replace", "poor", "check"].contains { lowered.contains($0) }
        }()

        var tempC: Double? = nil
        if let t = intValue("Temperature", in: ioreg), t > 0 {
            tempC = Double(t) / 100.0
        }

        return BatteryReport(
            hasBattery: true,
            chargePercent: pmset.percent ?? (intValue("CurrentCapacity", in: ioreg) ?? 0),
            isCharging: pmset.charging ?? (ioregValue("IsCharging", in: ioreg) == "Yes"),
            powerSource: pmset.powerSource,
            timeRemaining: pmset.timeRemaining,
            cycleCount: cycleCount,
            maxCapacityPercent: healthPercent,
            condition: condition,
            needsService: needsService,
            designCapacitymAh: design,
            fullChargeCapacitymAh: rawMax,
            temperatureCelsius: tempC
        )
    }

    // MARK: - system_profiler (authoritative capacity)

    /// Reads the exact "Maximum Capacity" percentage macOS publishes for itself.
    ///
    /// This is the same value shown in  → About This Mac → System Report → Power,
    /// and in System Settings → Battery → Battery Health. Reading it instead of
    /// recomputing it is the only way to guarantee Catalyst never disagrees with the
    /// OS, because Apple's smoothing algorithm isn't public.
    ///
    /// **Flow:**
    /// 1. Runs `system_profiler -json SPPowerDataType`.
    /// 2. Walks the `SPPowerDataType` items for the one carrying
    ///    `sppower_battery_health_info`.
    /// 3. Reads `sppower_battery_health_maximum_capacity`, tolerating either a
    ///    bare number or a `"85%"`-style string.
    ///
    /// **Gotchas:** `-json` is used rather than the plain-text output because the
    /// human-readable labels are localized — "Maximum Capacity" becomes
    /// "Capacité maximale" on a French Mac and string matching silently fails. The
    /// JSON keys are stable identifiers and are not localized.
    ///
    /// - Returns: Apple's published health figures, each `nil` when unavailable on
    ///   this macOS version, on a desktop Mac, or on parse failure.
    private func runSystemProfilerCapacity() async -> ProfilerHealth {
        let empty = ProfilerHealth(maxCapacityPercent: nil, cycleCount: nil, condition: nil)
        /// Output goes to a temp FILE, never through a pipe.
        ///
        /// **Gotchas:** Reading `system_profiler` over `Pipe()` hangs the app forever.
        /// It forks helper reporters that inherit the write end of the pipe; when
        /// `system_profiler` itself exits, `terminationHandler` runs and calls
        /// `readToEnd()`, which then blocks indefinitely waiting for an EOF that
        /// can't arrive while a surviving grandchild still holds the descriptor. The
        /// runner's timeout can't rescue that — it only kills the process it
        /// launched, and by then the process has already exited. This is the
        /// "Reading battery telemetry…" spinner that never resolves.
        ///
        /// Redirecting inside the shell means the pipes carry nothing, zsh exits
        /// cleanly, and `readToEnd()` returns immediately.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalyst-power-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        /// 8s: generous for a healthy machine, short enough that a wedged
        /// `system_profiler` only delays the scan rather than defining it. On timeout
        /// we fall through to the ioreg arithmetic.
        let command = "/usr/sbin/system_profiler -json SPPowerDataType > "
            + "'\(tmp.path)' 2>/dev/null"
        guard (try? await runner.run(command: command, timeoutSeconds: 8)) != nil,
              let data = try? Data(contentsOf: tmp), !data.isEmpty else { return empty }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return empty }

        /// Accepts a bare number or a `"85%"`-style string — the key's type has
        /// changed between macOS releases, so don't bet on either.
        func number(_ raw: Any?) -> Int? {
            if let n = raw as? Int { return n }
            if let d = raw as? Double { return Int(d.rounded()) }
            if let s = raw as? String {
                let digits = s.prefix { $0.isNumber }
                return Int(digits)
            }
            return nil
        }

        /// The array mixes battery, AC-adapter and power-settings entries — find the
        /// one that actually carries health info rather than assuming index 0.
        for item in items {
            guard let health = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            return ProfilerHealth(
                maxCapacityPercent: number(health["sppower_battery_health_maximum_capacity"]),
                /// Also taken from here as a safety net: `ioregValue` matches
                /// `"CycleCount" = ` with spaces, which misses the compact
                /// `"CycleCount"=505` form nested inside the `BatteryData` dict.
                cycleCount: number(health["sppower_battery_cycle_count"]),
                condition: health["sppower_battery_health"] as? String
            )
        }
        return empty
    }

    /// Apple's own published battery health figures, read from `system_profiler`.
    private struct ProfilerHealth: Sendable {
        /// Apple's displayed "Maximum Capacity", 0–100. `nil` on macOS versions that don't
        /// publish the key, on desktops, or when the probe failed.
        let maxCapacityPercent: Int?
        /// Charge cycles as macOS reports them — a safety net for the `ioreg` parse, which
        /// misses the compact `"CycleCount"=505` form nested inside `BatteryData`.
        let cycleCount: Int?
        /// Apple's condition string (e.g. "Normal"), already localized by the OS.
        let condition: String?
    }

    // MARK: - ioreg

    /// Retrieves raw telemetry directly from the I/O Kit registry for the `AppleSmartBattery` class.
    ///
    /// - Returns: A multi-line string payload, or an empty string if the `ioreg` binary fails.
    private func runIoreg() async -> String {
        do {
            let r = try await runner.run(
                executable: "/usr/sbin/ioreg",
                arguments: ["-r", "-c", "AppleSmartBattery", "-w0"],
                timeoutSeconds: 6
            )
            return r.stdout
        } catch {
            return ""
        }
    }

    /// Returns the raw string after `"KEY" = ` up to end of line.
    /// - Parameters:
    ///   - key: The exact Apple hardware dictionary key mapping to properties.
    ///   - text: The completely serialized `ioreg` target string.
    /// - Returns: The explicitly targeted substring assigned to the key, or nil.
    private func ioregValue(_ key: String, in text: String) -> String? {
        guard let r = text.range(of: "\"\(key)\" = ") else { return nil }
        let after = text[r.upperBound...]
        let value = after.prefix { $0 != "\n" }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// Extracts the integer value bound to a specific string key in the `ioreg` output.
    ///
    /// - Parameters:
    ///   - key: The dictionary key to search for (e.g. `CycleCount`).
    ///   - text: The full string dump of `ioreg`.
    /// - Returns: The parsed integer, or `nil` if absent or malformed.
    private func intValue(_ key: String, in text: String) -> Int? {
        guard let raw = ioregValue(key, in: text) else { return nil }
        let digits = raw.prefix { $0 == "-" || $0.isNumber }
        return Int(digits)
    }

    // MARK: - pmset

    private struct PmsetInfo {
        var percent: Int?
        var charging: Bool?
        var timeRemaining: String?
        var powerSource: String
        var batteryLinePresent: Bool
    }

    /// Executes `/usr/bin/pmset -g batt` to retrieve live macOS power management status.
    ///
    /// - Returns: A ``PmsetInfo`` struct populated via regex parsing of the console output.
    private func runPmset() async -> PmsetInfo {
        do {
            let r = try await runner.run(executable: "/usr/bin/pmset", arguments: ["-g", "batt"], timeoutSeconds: 5)
            let out = r.stdout
            let lines = out.components(separatedBy: .newlines)
            let powerSource = out.contains("'AC Power'") ? "AC Power" : "Battery"

            guard let battLine = lines.first(where: { $0.contains("%") }) else {
                return PmsetInfo(percent: nil, charging: nil, timeRemaining: nil,
                                 powerSource: powerSource, batteryLinePresent: false)
            }

            /// "...-InternalBattery-0 (id=...)\t72%; discharging; 4:32 remaining present: true"
            ///
            /// **Gotchas:** `pmset` outputs localizable string literals for battery states; relying on English string matching breaks parsing on international keyboards.
            var percent: Int?
            if let pr = battLine.range(of: #"(\d+)%"#, options: .regularExpression) {
                percent = Int(battLine[pr].dropLast())
            }

            let lower = battLine.lowercased()
            let charging: Bool? = lower.contains("; charging") ? true
                : (lower.contains("; discharging") || lower.contains("; charged") || lower.contains("; finishing") ? false : nil)

            var time: String?
            if let tr = battLine.range(of: #"\d+:\d+"#, options: .regularExpression) {
                time = String(battLine[tr])
            }

            return PmsetInfo(percent: percent, charging: charging, timeRemaining: time,
                             powerSource: powerSource, batteryLinePresent: true)
        } catch {
            return PmsetInfo(percent: nil, charging: nil, timeRemaining: nil,
                             powerSource: "Battery", batteryLinePresent: false)
        }
    }
}
