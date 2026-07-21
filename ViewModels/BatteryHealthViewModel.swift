import Foundation
import SwiftUI
import Combine

@MainActor
final class BatteryHealthViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case ready
    }

    @Published var state: State = .idle
    @Published var report: BatteryReport?

    private let service = BatteryHealthService.shared
    private let logger = Logger.shared

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
