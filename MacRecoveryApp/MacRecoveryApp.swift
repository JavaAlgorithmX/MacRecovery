import SwiftUI

@main
struct MacRecoveryApp: App {

    init() {
        // Kick off file logger immediately so session header is written first
        _ = FileLogger.shared
        log(AppLog.general, "MacRecovery launched — pid=\(ProcessInfo.processInfo.processIdentifier)")
        log(AppLog.general, "Log file: \(FileLogger.shared.logFilePath)")
    }

    var body: some Scene {
        WindowGroup("MacRecovery") {
            ContentView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
