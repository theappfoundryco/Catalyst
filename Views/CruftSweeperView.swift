import SwiftUI
import UniformTypeIdentifiers

/// The main view for the Cruft Sweeper feature, managing the scan configuration and results display.
///
/// ```swift
/// CruftSweeperView(vm: cruftSweeperViewModel)
/// ```
struct CruftSweeperView: View {
    let vm: CruftSweeperViewModel
    
    var body: some View {
        // Pass the ViewModel to a subview that explicitly observes it
        CruftSweeperContent(vm: vm)
            .environmentObject(vm) // Inject for deeper subviews if needed
            .navigationTitle("Cruft Sweeper")
    }
}

/// The internal content view for the Cruft Sweeper, observing the view model and managing local scan state.
///
/// ```swift
/// CruftSweeperContent(vm: cruftSweeperViewModel)
/// ```
struct CruftSweeperContent: View {
    @ObservedObject var vm: CruftSweeperViewModel
    
    // Local state for scan settings
    @State private var scanType: ScanType = .quick
    @State private var skipGit: Bool = false
    @State private var showDeleteConfirmation = false
    
    enum ScanType {
        case quick, deep
        
        var title: String {
            switch self {
            case .quick: return "Quick Scan"
            case .deep: return "Deep Scan"
            }
        }
        
        var points: [String] {
            switch self {
            case .quick: 
                return [
                    "Scans Desktop, Downloads, Projects, Developer",
                    "Fast execution (~5-10 seconds)",
                    "Recommended for daily maintenance"
                ]
            case .deep: 
                return [
                    "Recursive scan of entire Home folder",
                    "Can take several minutes",
                    "Finds deep-nested artifacts in Library/Application Support"
                ]
            }
        }
    }
    
    var body: some View {
        Group {
            if vm.isScanning {
                ScanningView()
            } else if vm.foundCruft.isEmpty {
                StartScanView(
                    scanType: $scanType,
                    skipGit: $skipGit,
                    onStart: {
                        // Action
                        vm.startScan(deep: scanType == .deep, skipGit: skipGit)
                    }
                )
            } else {
                ResultsDashboard(showDeleteConfirmation: $showDeleteConfirmation)
            }
        }
    }
}
