import Foundation
import SwiftUI
import Combine

/// A view model that coordinates battery health diagnostics by interfacing with `BatteryHealthService`.
///
/// It exposes the state of the scan (idle, scanning, ready) and the resulting `BatteryReport`.
///
/// ```swift
/// @StateObject var vm = BatteryHealthViewModel()
/// await vm.scan()
/// if let report = vm.report { print(report.condition) }
/// ```
@MainActor
final class BatteryHealthViewModel: ObservableObject {
    /// The current phase of the battery diagnostic check.
    enum State: Equatable {
        case idle
        case scanning
        case ready
    }

    /// The active scanning state.
    @Published var state: State = .idle
    /// The finalized diagnostic report, available once `state == .ready`.
    @Published var report: BatteryReport?

    private let service = BatteryHealthService.shared
    private let logger = Logger.shared

    /// Executes a battery scan and updates the published state and report.
    ///
    /// **Flow:**
    /// 1. Toggles ``state`` to `.scanning`.
    /// 2. Defers to ``BatteryHealthService/scan()`` for the IOKit bindings.
    /// 3. Publishes the resulting ``BatteryReport`` and flips ``state`` to `.ready`.
    func scan() async {
        if report == nil { state = .scanning }
        logger.log("🔋 Scanning battery health…")
        let newReport = await service.scan()
        self.report = newReport
        self.state = .ready
        if newReport.hasBattery {
            logger.log("🔋 Battery: \(newReport.maxCapacityPercent)% capacity, \(newReport.cycleCount) cycles, \(newReport.condition)")
        } else {
            logger.log("🔋 No internal battery detected")
        }
    }
}
