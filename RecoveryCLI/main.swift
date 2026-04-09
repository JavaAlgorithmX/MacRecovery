import Foundation
import RecoveryCore

// MARK: - RecoveryCLI
// Usage:
//   recoverycli list
//   recoverycli scan <device-or-image> --mode quick|deep|both [--output path] [--types jpg,pdf]
//   recoverycli info <device-or-image>

let args = CommandLine.arguments.dropFirst()

func printUsage() {
    print("""
    recoverycli — MacRecovery

    Commands:
      list                          List user-facing drives (recommended)
      list --all                    List every raw partition
      info  <path>                  Print device info (size, sectors, FS type)
      scan  <path> [options]        Run a scan
      recover <results.json>        Extract files from a previous scan
      preview <results.json>        Show previews for candidates in a scan result

    Scan options:
      --mode  quick|deep|both       Scan mode (default: quick)
      --output <directory>          Where to write results.json
      --types jpg,pdf,png,...       Only look for these file types

    Recover options:
      --output <directory>          Where to write recovered files (default: ./recovered)
      --min-score low|medium|high|certain
                                    Minimum recoverability to extract (default: medium)
      --index <n>                   Recover only the Nth file shown by 'preview' (1-based)

    Preview options:
      --limit <n>                   Max candidates to preview (default: 20)
      --type  jpg,png,...           Only preview these file types

    Examples:
      recoverycli list
      recoverycli info /tmp/test.dmg
      recoverycli scan /tmp/test.dmg --mode deep --output /tmp/results
      recoverycli scan /dev/disk2s2 --mode both
      recoverycli recover /tmp/results/results.json --output /tmp/recovered
      recoverycli preview /tmp/results/results.json --limit 10
    """)
}

guard let command = args.first else {
    printUsage()
    exit(0)
}

switch command {

// MARK: list
case "list":
    let showAll = args.contains("--all")
    if showAll {
        // Raw view — every partition the engine can open
        print("Scanning for attached volumes (all)...")
        do {
            let volumes = try VolumeEnumerator.scannable()
            if volumes.isEmpty {
                print("No scannable volumes found.")
            } else {
                print(String(repeating: "─", count: 80))
                print(String(format: "%-14@ %-8@ %-22@ %-12@ %@",
                             "Device" as NSString, "FS" as NSString,
                             "Name" as NSString, "Size" as NSString, "Mount" as NSString))
                print(String(repeating: "─", count: 80))
                for v in volumes {
                    let size = ByteCountFormatter.string(
                        fromByteCount: Int64(v.sizeBytes), countStyle: .file)
                    print(String(format: "%-14@ %-8@ %-22@ %-12@ %@",
                                 v.bsdPath as NSString,
                                 v.fsType.rawValue as NSString,
                                 (v.volumeName ?? "(unnamed)") as NSString,
                                 size as NSString,
                                 (v.mountPoint ?? "(unmounted)") as NSString))
                }
                print(String(repeating: "─", count: 80))
                print("\(volumes.count) volume(s) found.")
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    } else {
        // UI-ready view — only drives the user cares about
        print("Scanning for attached volumes...")
        do {
            let volumes = try VolumeEnumerator.listForUI()
            if volumes.isEmpty {
                print("No user volumes found. Try 'list --all' to see everything.")
            } else {
                print(String(repeating: "─", count: 72))
                print(String(format: "  %-2@ %-22@ %-10@ %-8@ %-10@ %@",
                             "" as NSString,
                             "Name" as NSString,
                             "Size" as NSString,
                             "FS" as NSString,
                             "Type" as NSString,
                             "Scan" as NSString))
                print(String(repeating: "─", count: 72))
                for v in volumes {
                    let rec = v.isRecommended ? "★ " : "  "
                    let scan = v.scanCapability == .quickAndDeep ? "Quick+Deep"
                             : v.scanCapability == .deepOnly     ? "Deep only"
                             : "Locked"
                    print(String(format: "%@%@ %-22@ %-10@ %-8@ %-10@ %@",
                                 rec as NSString,
                                 v.emoji as NSString,
                                 v.displayName as NSString,
                                 v.displaySize as NSString,
                                 v.fsType.rawValue as NSString,
                                 v.category.rawValue as NSString,
                                 scan as NSString))
                    // Space bar (only when mounted)
                    if let fraction = v.usedFraction {
                        let bar  = spaceBar(fraction: fraction, width: 20)
                        let used = v.displayUsed ?? ""
                        let free = v.displayFree ?? ""
                        print(String(format: "     [%@] %@ / %@",
                                     bar as NSString, used as NSString, free as NSString))
                    }
                    if let mount = v.mountPoint {
                        print(String(format: "     %-14@ %@",
                                     v.bsdPath as NSString, mount as NSString))
                    } else {
                        print(String(format: "     %@", v.bsdPath as NSString))
                    }
                    print("")
                }
                print(String(repeating: "─", count: 72))
                print("\(volumes.count) drive(s) found.  ★ = recommended for recovery")
                print("Tip: run 'list --all' to see all raw partitions.")
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

// MARK: info
case "info":
    guard let path = args.dropFirst().first else {
        fputs("Usage: recoverycli info <path>\n", stderr); exit(1)
    }
    do {
        let device = try DiskDevice.open(path: path)
        let gb = Double(device.totalBytes) / 1_000_000_000
        print("Path:         \(device.path)")
        print("Total bytes:  \(device.totalBytes) (\(String(format: "%.2f", gb)) GB)")
        print("Sector size:  \(device.sectorSize) bytes")
        print("Total sectors:\(device.totalSectors)")
        print("Scan time est (deep, 200 MB/s): \(Int(Double(device.totalBytes) / 200_000_000 / 60)) min")
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

// MARK: scan
case "scan":
    var remainingArgs = Array(args.dropFirst())

    guard let devicePath = remainingArgs.first, !devicePath.hasPrefix("--") else {
        fputs("Usage: recoverycli scan <path> [--mode quick|deep|both]\n", stderr)
        exit(1)
    }
    remainingArgs.removeFirst()

    // Parse flags
    var mode: ScanMode = .quick
    var outputPath: String? = nil
    var targetTypes: Set<RecoveredFileType>? = nil

    var i = 0
    while i < remainingArgs.count {
        switch remainingArgs[i] {
        case "--mode":
            i += 1
            guard i < remainingArgs.count else { break }
            switch remainingArgs[i] {
            case "quick": mode = .quick
            case "deep":  mode = .deep
            case "both":  mode = .both
            default:
                fputs("Unknown mode '\(remainingArgs[i])'. Use quick, deep, or both.\n", stderr)
                exit(1)
            }
        case "--output":
            i += 1
            if i < remainingArgs.count { outputPath = remainingArgs[i] }
        case "--types":
            i += 1
            if i < remainingArgs.count {
                let exts = remainingArgs[i].split(separator: ",").map(String.init)
                targetTypes = Set(exts.compactMap { RecoveredFileType.from(extension: $0.lowercased()) })
            }
        default:
            break
        }
        i += 1
    }

    var config          = ScanConfiguration()
    config.mode         = mode
    config.targetTypes  = targetTypes

    let engine = RecoveryEngine(config: config)

    print("Starting \(mode.rawValue) scan on \(devicePath)...")
    print(String(repeating: "─", count: 70))

    // Progress bar
    var lastPhase = ScanPhase.opening
    func renderProgress(_ p: ScanProgress) {
        if p.phase != lastPhase {
            print("\n[\(p.phase.rawValue)]")
            lastPhase = p.phase
        }
        let bar   = progressBar(percent: p.percent, width: 28)
        let speed = p.speed > 0 ? String(format: "%.1f MB/s", p.speed) : "---"
        let eta   = p.eta > 0   ? formatETA(p.eta) : "--:--"
        let found = p.totalFoundBytes > 0
            ? "  Found: \(ByteCountFormatter.string(fromByteCount: Int64(p.totalFoundBytes), countStyle: .file))"
            : ""
        let path  = p.currentPath.map { "  \($0)" } ?? ""

        // Two-phase mini-bars when doing both scans
        let phaseInfo: String
        if p.quickScanPercent > 0 || p.deepScanPercent > 0 {
            let qBar = miniBar(percent: p.quickScanPercent, width: 8)
            let dBar = miniBar(percent: p.deepScanPercent,  width: 8)
            phaseInfo = "  Q:\(qBar) D:\(dBar)"
        } else {
            phaseInfo = ""
        }

        print("\r\(bar) \(String(format: "%5.1f", p.percent))%  \(speed)  ETA \(eta)  #\(p.candidateCount)\(found)\(phaseInfo)\(path)",
              terminator: "")
        fflush(stdout)
    }

    // engine.scan() is async — bridge to sync CLI context with a semaphore.
    var scanResult: ScanResult?
    var scanError:  Error?
    let sema = DispatchSemaphore(value: 0)
    Task {
        do    { scanResult = try await engine.scan(devicePath: devicePath,
                                                    onProgress: renderProgress) }
        catch { scanError = error }
        sema.signal()
    }
    sema.wait()

    if let error = scanError {
        print("")
        fputs("Scan failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    let result = scanResult!
    print("\n" + String(repeating: "─", count: 70))
    printResult(result)

    if let outPath = outputPath {
        do    { try saveResult(result, to: outPath) }
        catch { fputs("Could not save results: \(error.localizedDescription)\n", stderr) }
    }

// MARK: recover
case "recover":
    var remainingArgs = Array(args.dropFirst())

    guard let jsonPath = remainingArgs.first, !jsonPath.hasPrefix("--") else {
        fputs("Usage: recoverycli recover <results.json> [--output dir] [--min-score low|medium|high|certain]\n", stderr)
        exit(1)
    }
    remainingArgs.removeFirst()

    var outputPath: String = "./recovered"
    var minScore: RecoverabilityScore = .medium
    var recoverIndex: Int? = nil

    var i = 0
    while i < remainingArgs.count {
        switch remainingArgs[i] {
        case "--output":
            i += 1
            if i < remainingArgs.count { outputPath = remainingArgs[i] }
        case "--min-score":
            i += 1
            if i < remainingArgs.count {
                switch remainingArgs[i] {
                case "low":     minScore = .low
                case "medium":  minScore = .medium
                case "high":    minScore = .high
                case "certain": minScore = .certain
                default:
                    fputs("Unknown score '\(remainingArgs[i])'. Use low, medium, high, or certain.\n", stderr)
                    exit(1)
                }
            }
        case "--index":
            i += 1
            if i < remainingArgs.count, let n = Int(remainingArgs[i]), n >= 1 {
                recoverIndex = n
            } else {
                fputs("--index requires a positive integer (1-based, matching 'preview' output).\n", stderr)
                exit(1)
            }
        default:
            break
        }
        i += 1
    }

    do {
        // Load results.json
        let jsonURL  = URL(fileURLWithPath: jsonPath)
        let jsonData = try Data(contentsOf: jsonURL)
        let decoder  = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let scanResult = try decoder.decode(ScanResult.self, from: jsonData)

        // Build candidate list — same ordering as 'preview' so --index matches
        let index = CandidateIndex(result: scanResult)
        let allCandidates = index.search()

        let candidates: [FileCandidate]
        if let n = recoverIndex {
            guard n <= allCandidates.count else {
                fputs("--index \(n) is out of range (preview shows \(allCandidates.count) candidates).\n", stderr)
                exit(1)
            }
            candidates = [allCandidates[n - 1]]
            print("Recovering candidate #\(n): \(candidates[0].suggestedFileName)")
        } else {
            candidates = allCandidates.filter { $0.recoverability >= minScore }
            guard !candidates.isEmpty else {
                print("No candidates meet the minimum recoverability score '\(minScore.label)'. Nothing to recover.")
                exit(0)
            }
        }

        print(String(repeating: "─", count: 70))

        let device    = try DiskDevice.open(path: scanResult.devicePath)
        let extractor = FileExtractor(device: device)
        let outputDir = URL(fileURLWithPath: outputPath)

        let results = try extractor.extractAll(candidates, to: outputDir) { completed, total, latest in
            guard let r = latest else { return }
            let icon: String
            switch r.status {
            case .success: icon = "✓"
            case .partial: icon = "~"
            case .failed:  icon = "✗"
            }
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(r.bytesWritten), countStyle: .file)
            let dest = r.outputPath ?? "(none)"
            print("\(icon) [\(completed)/\(total)] \(r.candidate.suggestedFileName)  \(size)  → \(dest)")
        }

        print(String(repeating: "─", count: 70))
        printExtractionSummary(results, outputDir: outputDir)

    } catch let error as DecodingError {
        fputs("Failed to parse results.json: \(error.localizedDescription)\n", stderr)
        exit(1)
    } catch {
        fputs("Recovery failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

// MARK: preview
case "preview":
    var remainingArgs = Array(args.dropFirst())

    guard let jsonPath = remainingArgs.first, !jsonPath.hasPrefix("--") else {
        fputs("Usage: recoverycli preview <results.json> [--limit n] [--type jpg,png,...]\n", stderr)
        exit(1)
    }
    remainingArgs.removeFirst()

    var previewLimit = 20
    var previewTypes: Set<RecoveredFileType>? = nil

    var pi = 0
    while pi < remainingArgs.count {
        switch remainingArgs[pi] {
        case "--limit":
            pi += 1
            if pi < remainingArgs.count, let n = Int(remainingArgs[pi]) { previewLimit = n }
        case "--type":
            pi += 1
            if pi < remainingArgs.count {
                let exts = remainingArgs[pi].split(separator: ",").map(String.init)
                previewTypes = Set(exts.compactMap { RecoveredFileType.from(extension: $0.lowercased()) })
            }
        default:
            break
        }
        pi += 1
    }

    do {
        let jsonURL    = URL(fileURLWithPath: jsonPath)
        let jsonData   = try Data(contentsOf: jsonURL)
        let decoder    = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let scanResult = try decoder.decode(ScanResult.self, from: jsonData)

        // Build index and apply optional type filter
        let index = CandidateIndex(result: scanResult)
        var candidates: [FileCandidate]
        if let types = previewTypes, !types.isEmpty {
            candidates = index.search(query: CandidateQuery(fileTypes: types))
        } else {
            candidates = index.search()
        }
        candidates = Array(candidates.prefix(previewLimit))

        guard !candidates.isEmpty else {
            print("No candidates to preview.")
            exit(0)
        }

        let device   = try DiskDevice.open(path: scanResult.devicePath)
        let provider = PreviewProvider(device: device)

        print("Previewing \(candidates.count) candidate(s) from \(scanResult.devicePath)")
        print(String(repeating: "─", count: 70))

        for (idx, candidate) in candidates.enumerated() {
            let preview  = provider.preview(for: candidate)
            let size     = ByteCountFormatter.string(
                fromByteCount: Int64(candidate.estimatedSize), countStyle: .file)
            let score    = candidate.recoverability.label
            print("[\(idx + 1)/\(candidates.count)] \(candidate.suggestedFileName)")
            print("  Type: \(candidate.fileType.rawValue)  Size: \(size)  Score: \(score)  Sector: \(candidate.startSector)")
            print("  Preview: \(preview.summary)")
            print("")
        }

        print(String(repeating: "─", count: 70))
        print("Done. \(candidates.count) candidate(s) previewed.")

    } catch let error as DecodingError {
        fputs("Failed to parse results.json: \(error.localizedDescription)\n", stderr)
        exit(1)
    } catch {
        fputs("Preview failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

default:
    printUsage()
    exit(1)
}

// MARK: - Helpers

func printResult(_ result: ScanResult) {
    let duration = result.duration.map { String(format: "%.1f", $0) } ?? "?"
    print("Scan complete in \(duration)s")
    print("Sectors scanned:  \(result.sectorsScanned)")
    print("Bad sectors:      \(result.badSectors.count)")
    print("Total candidates: \(result.candidates.count)")
    print("Recoverable:      \(result.totalRecoverable)")
    print("")

    // Group by type
    let byType = Dictionary(grouping: result.candidates, by: \.fileType)
    let sorted = byType.sorted { $0.value.count > $1.value.count }

    print(String(format: "%-10@ %6@  %@", "Type" as NSString, "Count" as NSString, "Best recoverability" as NSString))
    print(String(repeating: "─", count: 40))
    for (type, candidates) in sorted {
        let best = candidates.max(by: { $0.recoverability < $1.recoverability })
        print(String(format: "%-10@ %6d  %@",
                     type.rawValue as NSString,
                     candidates.count,
                     (best?.recoverability.label ?? "-") as NSString))
    }

    print("")
    // Show top 10 candidates
    let top = result.candidates
        .sorted { $0.recoverability > $1.recoverability }
        .prefix(10)

    if !top.isEmpty {
        print("Top candidates:")
        for c in top {
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(c.estimatedSize), countStyle: .file)
            print("  [\(c.recoverability.label)] \(c.suggestedFileName)  \(size)  sector \(c.startSector)  (\(c.source.rawValue))")
        }
    }
}

func saveResult(_ result: ScanResult, to path: String) throws {
    let dir = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("results.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(result)
    try data.write(to: url)
    print("\nResults saved to \(url.path)")
}

func printExtractionSummary(_ results: [ExtractionResult], outputDir: URL) {
    let success = results.filter { $0.status == .success }.count
    let partial = results.filter { $0.status == .partial }.count
    let failed  = results.filter { $0.status == .failed  }.count
    let totalBytes = results.reduce(UInt64(0)) { $0 + $1.bytesWritten }
    let totalSize  = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)

    print("Extraction complete")
    print("  ✓ Success:  \(success)")
    if partial > 0 { print("  ~ Partial:  \(partial)  (bad sectors zeroed — file may be corrupt)") }
    if failed  > 0 { print("  ✗ Failed:   \(failed)") }
    print("  Total data: \(totalSize)")
    print("  Output dir: \(outputDir.path)")

    let badSectorFiles = results.filter { !$0.badSectors.isEmpty }
    if !badSectorFiles.isEmpty {
        print("\nFiles with bad sectors:")
        for r in badSectorFiles {
            print("  \(r.candidate.suggestedFileName): \(r.badSectors.count) bad sector(s)")
        }
    }
}

func progressBar(percent: Double, width: Int) -> String {
    let filled = Int(percent / 100 * Double(width))
    let bar = String(repeating: "█", count: filled) +
              String(repeating: "░", count: width - filled)
    return "[\(bar)]"
}

/// Compact bar for two-phase display, no brackets e.g. "████░░░░"
func miniBar(percent: Double, width: Int) -> String {
    let filled = Int((percent / 100 * Double(width)).rounded())
    return String(repeating: "█", count: filled) +
           String(repeating: "░", count: max(0, width - filled))
}

/// Drive-card used-space bar e.g. "████████████░░░░░░░░"
func spaceBar(fraction: Double, width: Int) -> String {
    let filled = Int((fraction * Double(width)).rounded())
    let clamped = min(max(filled, 0), width)
    return String(repeating: "█", count: clamped) +
           String(repeating: "░", count: width - clamped)
}

func formatETA(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%02d:%02d", m, s)
}
