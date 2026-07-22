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
    /// Apple-style condition: "Normal" / "Service Recommended".
    let condition: String
    let designCapacitymAh: Int?
    let fullChargeCapacitymAh: Int?
    let temperatureCelsius: Double?

    static let empty = BatteryReport(
        hasBattery: false, chargePercent: 0, isCharging: false, powerSource: "AC Power",
        timeRemaining: nil, cycleCount: 0, maxCapacityPercent: 0, condition: "Unknown",
        designCapacitymAh: nil, fullChargeCapacitymAh: nil, temperatureCelsius: nil
    )
}

/// Reads battery telemetry from `ioreg` (AppleSmartBattery) and `pmset`.
/// No dependencies, no privileges. Returns `hasBattery == false` on desktops.
final class BatteryHealthService: Sendable {

    static let shared = BatteryHealthService()
    private init() {}

    private let runner = AsyncProcessRunner.shared

    func scan() async -> BatteryReport {
        async let ioregTask = runIoreg()
        async let pmsetTask = runPmset()
        let ioreg = await ioregTask
        let pmset = await pmsetTask

        let installed = (ioregValue("BatteryInstalled", in: ioreg) == "Yes")
            || (ioregValue("ExternalChargeCapable", in: ioreg) != nil && pmset.batteryLinePresent)
        guard installed && (ioregValue("DesignCapacity", in: ioreg) != nil || pmset.batteryLinePresent) else {
            // No internal battery (desktop Mac).
            return BatteryReport.empty
        }

        let cycleCount = intValue("CycleCount", in: ioreg) ?? 0
        let design = intValue("DesignCapacity", in: ioreg)
        // Apple Silicon exposes the true full-charge capacity as AppleRawMaxCapacity;
        // older Intel reports it as MaxCapacity (mAh).
        let rawMax = intValue("AppleRawMaxCapacity", in: ioreg) ?? intValue("MaxCapacity", in: ioreg)

        var healthPercent = 0
        if let design, design > 0, let rawMax, rawMax > 0, rawMax <= design * 2 {
            healthPercent = min(100, max(0, Int((Double(rawMax) / Double(design) * 100).rounded())))
        }

        let permanentFailure = intValue("PermanentFailureStatus", in: ioreg) ?? 0
        let condition: String = {
            if permanentFailure != 0 { return "Service Recommended" }
            if healthPercent > 0 && healthPercent < 80 { return "Service Recommended" }
            return "Normal"
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
            designCapacitymAh: design,
            fullChargeCapacitymAh: rawMax,
            temperatureCelsius: tempC
        )
    }

    // MARK: - ioreg

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
    private func ioregValue(_ key: String, in text: String) -> String? {
        guard let r = text.range(of: "\"\(key)\" = ") else { return nil }
        let after = text[r.upperBound...]
        let value = after.prefix { $0 != "\n" }
        return value.trimmingCharacters(in: .whitespaces)
    }

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

            // "...-InternalBattery-0 (id=...)\t72%; discharging; 4:32 remaining present: true"
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
