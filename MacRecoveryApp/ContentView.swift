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
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: vm.appPhase)
        .onAppear { vm.loadVolumes() }
    }
}
