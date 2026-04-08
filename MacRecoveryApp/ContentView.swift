import SwiftUI
import RecoveryCore

struct ContentView: View {
    @StateObject private var vm = ScanViewModel()

    var body: some View {
        Group {
            switch vm.appPhase {
            case .driveSelection:
                DrivePickerView()
                    .transition(.asymmetric(
                        insertion:  .opacity,
                        removal:    .opacity.combined(with: .move(edge: .leading))
                    ))
            case .scanning:
                ScanProgressView()
                    .transition(.asymmetric(
                        insertion:  .opacity.combined(with: .move(edge: .trailing)),
                        removal:    .opacity
                    ))
            case .results:
                ResultsView()
                    .transition(.asymmetric(
                        insertion:  .opacity.combined(with: .move(edge: .trailing)),
                        removal:    .opacity
                    ))
            }
        }
        .environmentObject(vm)
        .sheet(isPresented: $vm.showScanOptions) {
            ScanOptionsSheet()
                .environmentObject(vm)
        }
        .alert("Scan Failed", isPresented: Binding(
            get: { vm.scanError != nil },
            set: { if !$0 { vm.scanError = nil } }
        )) {
            Button("OK") { vm.scanError = nil }
        } message: {
            if let err = vm.scanError {
                Text(err)
                if err.lowercased().contains("permission") || err.lowercased().contains("operation not permitted") || err.lowercased().contains("eperm") || err.lowercased().contains("eacces") {
                    Text("\n\nGo to System Settings → Privacy & Security → Full Disk Access and enable MacRecovery (or Terminal if running via CLI).")
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: vm.appPhase)
        .onAppear { vm.loadVolumes() }
    }
}
