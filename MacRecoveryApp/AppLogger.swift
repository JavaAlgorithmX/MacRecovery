import Foundation
import os.log

// MARK: - AppLog
// Unified logging for MacRecovery.
//
// HOW TO VIEW IN XCODE:
//   Run the app from Xcode → all log output appears in the Debug console
//   (bottom panel). Filter with the search box — e.g. type "SCAN" or "ERROR".
//
// HOW TO VIEW IN CONSOLE.APP (without Xcode):
//   1. Open Console.app (Spotlight → Console)
//   2. Select your Mac in the left sidebar
//   3. In the search bar enter:  subsystem:com.macrecovery.app
//   4. Press Start Streaming
//
// HOW TO VIEW THE FILE LOG:
//   The file log is always written to:
//     ~/Library/Logs/MacRecovery/macrecovery.log
//   In Terminal:
//     tail -f ~/Library/Logs/MacRecovery/macrecovery.log
//   Or open it in Console.app → File → Open…

// MARK: - Log category enum

enum AppLog: String, CaseIterable {
    case permission  = "permission"
    case scan        = "scan"
    case extraction  = "extraction"
    case navigation  = "navigation"
    case device      = "device"
    case volumes     = "volumes"
    case recovery    = "recovery"
    case preview     = "preview"
    case general     = "general"

    private static let subsystem = "com.macrecovery.app"

    var logger: Logger {
        Logger(subsystem: Self.subsystem, category: rawValue)
    }
}

// MARK: - Global log function
// Usage:
//   log(.scan, "Starting scan on \(path)")
//   log(.extraction, "Failed: \(error)", level: "ERROR")

func log(_ category: AppLog, _ message: String, level: String = "INFO") {
    FileLogger.shared.write(category: category.rawValue, level: level, message: message)

    switch level {
    case "ERROR": category.logger.error("\(message, privacy: .public)")
    case "WARN":  category.logger.warning("\(message, privacy: .public)")
    case "DEBUG": category.logger.debug("\(message, privacy: .public)")
    default:      category.logger.info("\(message, privacy: .public)")
    }
}

// MARK: - FileLogger
// Writes every entry to ~/Library/Logs/MacRecovery/macrecovery.log

final class FileLogger {

    static let shared = FileLogger()

    let logFilePath: String
    private let queue  = DispatchQueue(label: "com.macrecovery.filelog", qos: .utility)
    private var handle: FileHandle?

    private init() {
        let logDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacRecovery")

        try? FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true)

        let fileURL = logDir.appendingPathComponent("macrecovery.log")
        logFilePath = fileURL.path

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()

        let header = """

            ════════════════════════════════════════════════════════════
             MacRecovery session started \(ts())  pid=\(ProcessInfo.processInfo.processIdentifier)
            ════════════════════════════════════════════════════════════\n
            """
        writeRaw(header)
    }

    func write(category: String, level: String, message: String) {
        let line = "[\(ts())] [\(level)] [\(category.uppercased())] \(message)\n"
        print(line, terminator: "")          // Xcode debug console
        queue.async { [weak self] in
            self?.writeRaw(line)
        }
    }

    private func writeRaw(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        handle?.write(data)
    }

    private func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
