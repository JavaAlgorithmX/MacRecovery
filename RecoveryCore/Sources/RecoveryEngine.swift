import Foundation
import os.log

private let log = Logger(subsystem: "com.macrecovery", category: "RecoveryEngine")

// MARK: - ScanMode

public enum ScanMode: String, Codable {
    case quick = "quick"
    case deep  = "deep"
    case both  = "both"
}

// MARK: - ScanConfiguration

public struct ScanConfiguration {
    public var mode:           ScanMode     = .quick
    public var sectorsPerRead: UInt32       = 128    // 64KB at 512B sectors
    public var maxCandidates:  Int          = 50_000
    public var targetTypes:    Set<RecoveredFileType>? = nil  // nil = all types

    /// Output directory for recovered files. MUST be on a different volume.
    public var outputDirectory: URL?

    /// Directory used to save SectorMap + partial candidates when pausing.
    /// Defaults to a temp directory if nil.
    public var checkpointDirectory: URL?

    public init() {}
    public static var `default`: ScanConfiguration { ScanConfiguration() }
}

// MARK: - ScanPhase

public enum ScanPhase: String {
    case opening     = "Opening device"
    case quickScan   = "Quick scan (reading file system)"
    case deepScan    = "Deep scan (file carving)"
    case organising  = "Organising results"
    case complete    = "Complete"
    case paused      = "Paused"
    case failed      = "Failed"
}

// MARK: - ScanProgress

public struct ScanProgress {
    /// Current phase label.
    public let phase:             ScanPhase

    /// Overall 0–100 progress across all phases.
    public let percent:           Double

    /// Quick-scan phase progress 0–100 (100 once quick scan finishes).
    public let quickScanPercent:  Double

    /// Deep-scan phase progress 0–100 (0 until deep scan starts).
    public let deepScanPercent:   Double

    /// Throughput in MB/s (0 when not measurable).
    public let speed:             Double

    /// Estimated seconds remaining (0 when not measurable).
    public let eta:               TimeInterval

    public let candidateCount:    Int
    public let badSectorCount:    Int
    public let currentSector:     UInt64

    /// File path currently being examined (quick scan only; nil during carving).
    public let currentPath:       String?

    /// Sum of `estimatedSize` of all candidates found so far (bytes).
    public let totalFoundBytes:   UInt64
}

// MARK: - ScanCheckpoint

/// Persisted state that lets a paused scan be resumed from where it left off.
public struct ScanCheckpoint: Codable {
    public let devicePath:    String
    public let mode:          ScanMode
    public let resumeSector:  UInt64
    public let candidates:    [FileCandidate]

    /// Filename (not full path) of the SectorMap binary saved alongside this file.
    public let sectorMapFile: String
}

// MARK: - ScanResult

public struct ScanResult: Codable {
    public let devicePath:     String
    public let scanMode:       ScanMode
    public let startedAt:      Date
    public let completedAt:    Date?
    public let candidates:     [FileCandidate]
    public let sectorsScanned: UInt64
    public let badSectors:     [UInt64]

    /// True when the scan was paused before completion.
    public let isPaused:       Bool

    /// Location of the checkpoint directory — non-nil only when `isPaused` is true.
    public let checkpointURL:  URL?

    public var duration: TimeInterval? {
        completedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public var totalRecoverable: Int {
        candidates.filter { $0.recoverability >= .medium }.count
    }
}

// MARK: - RecoveryEngine

public final class RecoveryEngine {

    public let config: ScanConfiguration

    private var sectorMap:        SectorMap?
    private var startTime:        Date?

    /// Set to true to request cancellation. The running task is also checked
    /// via `Task.isCancelled` — callers should prefer `task.cancel()`.
    private var _cancelRequested  = false

    /// Set to true to request a pause at the next checkpoint in the deep scan.
    private var _pauseRequested   = false

    public init(config: ScanConfiguration = .default) {
        self.config = config
    }

    // MARK: - Cancellation & Pause

    /// Request cancellation. Prefer cancelling the enclosing `Task` directly;
    /// this method also works when the engine is run without structured concurrency.
    public func cancel() { _cancelRequested = true }

    /// Signal the engine to pause at the next safe checkpoint in the deep scan.
    /// The scan will save state and return a `ScanResult` with `isPaused = true`.
    public func requestPause() { _pauseRequested = true }

    // MARK: - Main scan entry point (async)

    /// Run a scan on `devicePath`.
    ///
    /// This method is `async` — it yields cooperatively during the deep-scan loop,
    /// allowing SwiftUI views and other tasks to remain responsive.
    ///
    /// ```swift
    /// // From a SwiftUI Task:
    /// let result = try await engine.scan(devicePath: path) { progress in
    ///     Task { @MainActor in self.scanProgress = progress }
    /// }
    ///
    /// // Or use the stream API for cleaner SwiftUI binding:
    /// let (stream, task) = engine.scanStream(devicePath: path)
    /// for await progress in stream { ... }
    /// let result = try await task.value
    /// ```
    public func scan(
        devicePath: String,
        onProgress: ((ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {

        startTime        = Date()
        _cancelRequested = false
        _pauseRequested  = false
        log.info("RecoveryEngine starting \(self.config.mode.rawValue) scan on \(devicePath)")

        report(.opening, qp: 0, dp: 0, pct: 0, candidates: 0,
               bad: 0, sector: 0, callback: onProgress)

        let device = try DiskDevice.open(path: devicePath)
        let map    = SectorMap(totalSectors: device.totalSectors,
                               sectorSize: device.sectorSize)
        self.sectorMap = map

        var allCandidates: [FileCandidate] = []

        // Quick scan
        if config.mode == .quick || config.mode == .both {
            report(.quickScan, qp: 0, dp: 0, pct: 2,
                   candidates: 0, bad: 0, sector: 0,
                   path: "Scanning \(devicePath)…", callback: onProgress)
            let quickResults = runQuickScan(device: device, map: map,
                                            onProgress: onProgress)
            allCandidates.append(contentsOf: quickResults)
            log.info("Quick scan: \(quickResults.count) candidates")
        }

        // Check for cancellation between phases
        if _cancelRequested || Task.isCancelled { throw CancellationError() }

        // Deep scan
        if config.mode == .deep || config.mode == .both {
            let (deepResults, pausedAt) = try await runDeepScan(
                device:             device,
                map:                map,
                existingCandidates: allCandidates,
                resumeSector:       0,
                onProgress:         onProgress
            )
            allCandidates.append(contentsOf: deepResults)
            log.info("Deep scan: \(deepResults.count) additional candidates")

            // Paused mid-scan — save checkpoint and return partial result
            if let pausedSector = pausedAt {
                let cpURL = try saveCheckpoint(
                    devicePath:   devicePath,
                    resumeSector: pausedSector,
                    candidates:   allCandidates,
                    map:          map
                )
                return ScanResult(
                    devicePath:     devicePath,
                    scanMode:       config.mode,
                    startedAt:      startTime!,
                    completedAt:    Date(),
                    candidates:     allCandidates,
                    sectorsScanned: map.progress().scanned,
                    badSectors:     map.badSectors(),
                    isPaused:       true,
                    checkpointURL:  cpURL
                )
            }
        }

        // Organising phase — deduplicate and sort
        report(.organising, qp: 100, dp: 100, pct: 98,
               candidates: allCandidates.count,
               bad: map.badSectors().count,
               sector: device.totalSectors, callback: onProgress)
        let organised = deduplicateCandidates(allCandidates)

        report(.complete, qp: 100, dp: 100, pct: 100,
               candidates: organised.count,
               bad: map.badSectors().count,
               sector: device.totalSectors, callback: onProgress)

        return ScanResult(
            devicePath:     devicePath,
            scanMode:       config.mode,
            startedAt:      startTime!,
            completedAt:    Date(),
            candidates:     organised,
            sectorsScanned: map.progress().scanned,
            badSectors:     map.badSectors(),
            isPaused:       false,
            checkpointURL:  nil
        )
    }

    // MARK: - Resume from checkpoint (async)

    /// Resume a previously paused scan from a saved checkpoint.
    public func resume(
        checkpointURL: URL,
        onProgress: ((ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {

        startTime        = Date()
        _cancelRequested = false
        _pauseRequested  = false

        // Load checkpoint JSON
        let cpData = try Data(contentsOf: checkpointURL)
        let cp     = try JSONDecoder().decode(ScanCheckpoint.self, from: cpData)

        // Load saved SectorMap
        let mapURL = checkpointURL.deletingLastPathComponent()
                                  .appendingPathComponent(cp.sectorMapFile)
        let device = try DiskDevice.open(path: cp.devicePath)
        let map    = try SectorMap.load(from: mapURL,
                                        totalSectors: device.totalSectors,
                                        sectorSize:   device.sectorSize)
        self.sectorMap = map

        log.info("Resuming scan from sector \(cp.resumeSector) with \(cp.candidates.count) prior candidates")

        var allCandidates = cp.candidates

        report(.deepScan, qp: 100, dp: 0, pct: 5,
               candidates: allCandidates.count, bad: 0,
               sector: cp.resumeSector,
               path: "Resuming from sector \(cp.resumeSector)…",
               callback: onProgress)

        let (deepResults, pausedAt) = try await runDeepScan(
            device:             device,
            map:                map,
            existingCandidates: allCandidates,
            resumeSector:       cp.resumeSector,
            onProgress:         onProgress
        )
        allCandidates.append(contentsOf: deepResults)

        if let pausedSector = pausedAt {
            let cpURL = try saveCheckpoint(
                devicePath:   cp.devicePath,
                resumeSector: pausedSector,
                candidates:   allCandidates,
                map:          map
            )
            return ScanResult(
                devicePath:     cp.devicePath,
                scanMode:       cp.mode,
                startedAt:      startTime!,
                completedAt:    Date(),
                candidates:     allCandidates,
                sectorsScanned: map.progress().scanned,
                badSectors:     map.badSectors(),
                isPaused:       true,
                checkpointURL:  cpURL
            )
        }

        report(.organising, qp: 100, dp: 100, pct: 98,
               candidates: allCandidates.count,
               bad: map.badSectors().count,
               sector: device.totalSectors, callback: onProgress)
        let organised = deduplicateCandidates(allCandidates)

        report(.complete, qp: 100, dp: 100, pct: 100,
               candidates: organised.count,
               bad: map.badSectors().count,
               sector: device.totalSectors, callback: onProgress)

        return ScanResult(
            devicePath:     cp.devicePath,
            scanMode:       cp.mode,
            startedAt:      startTime!,
            completedAt:    Date(),
            candidates:     organised,
            sectorsScanned: map.progress().scanned,
            badSectors:     map.badSectors(),
            isPaused:       false,
            checkpointURL:  nil
        )
    }

    // MARK: - AsyncStream API (SwiftUI)

    /// Launch a scan and receive progress as an `AsyncStream`.
    ///
    /// Designed for SwiftUI `@State` / `@Observable` view models:
    /// ```swift
    /// let (stream, task) = engine.scanStream(devicePath: path)
    /// for await progress in stream {
    ///     await MainActor.run { self.progress = progress }
    /// }
    /// let result = try await task.value
    /// ```
    ///
    /// Cancel by calling `task.cancel()`.
    public func scanStream(
        devicePath: String
    ) -> (stream: AsyncStream<ScanProgress>, task: Task<ScanResult, Error>) {
        var continuation: AsyncStream<ScanProgress>.Continuation!
        let stream = AsyncStream<ScanProgress> { cont in continuation = cont }
        let task = Task {
            let result = try await self.scan(devicePath: devicePath) { progress in
                continuation.yield(progress)
            }
            continuation.finish()
            return result
        }
        return (stream, task)
    }

    /// Launch a resume and receive progress as an `AsyncStream`.
    public func resumeStream(
        checkpointURL: URL
    ) -> (stream: AsyncStream<ScanProgress>, task: Task<ScanResult, Error>) {
        var continuation: AsyncStream<ScanProgress>.Continuation!
        let stream = AsyncStream<ScanProgress> { cont in continuation = cont }
        let task = Task {
            let result = try await self.resume(checkpointURL: checkpointURL) { progress in
                continuation.yield(progress)
            }
            continuation.finish()
            return result
        }
        return (stream, task)
    }

    // MARK: - Quick scan (sync — parsers are CPU-bound and fast)

    private func runQuickScan(device: DiskDevice,
                               map: SectorMap,
                               onProgress: ((ScanProgress) -> Void)?) -> [FileCandidate] {
        var results: [FileCandidate] = []
        let fsType = detectFileSystem(device)
        log.info("Detected file system: \(fsType.rawValue)")

        let pathCallback: (String) -> Void = { path in
            onProgress?(ScanProgress(
                phase: .quickScan, percent: 50,
                quickScanPercent: 50, deepScanPercent: 0,
                speed: 0, eta: 0,
                candidateCount: results.count, badSectorCount: 0,
                currentSector: 0, currentPath: path,
                totalFoundBytes: results.reduce(0) { $0 + $1.estimatedSize }
            ))
        }

        switch fsType {
        case .hfsPlus:
            do {
                results = try HFSParser.findDeletedFiles(device: device,
                                                         sectorMap: map,
                                                         onPath: pathCallback)
            } catch {
                log.warning("HFS+ quick scan failed: \(error.localizedDescription)")
            }
        case .apfs:
            do {
                results = try APFSParser.findFiles(device: device,
                                                   sectorMap: map,
                                                   onPath: pathCallback)
            } catch {
                log.warning("APFS quick scan failed: \(error.localizedDescription)")
            }
        case .fat32, .exFAT:
            do {
                results = try FATParser.findFiles(device: device,
                                                  sectorMap: map,
                                                  onPath: pathCallback)
            } catch {
                log.warning("FAT quick scan failed: \(error.localizedDescription)")
            }
        default:
            log.warning("Unrecognised file system — quick scan skipped, use deep scan")
        }

        return results
    }

    // MARK: - Deep scan (async — yields cooperatively every 256 sectors)

    /// Returns (candidates found, sector paused at — nil if scan ran to completion).
    private func runDeepScan(device: DiskDevice,
                              map: SectorMap,
                              existingCandidates: [FileCandidate],
                              resumeSector: UInt64,
                              onProgress: ((ScanProgress) -> Void)?) async throws
        -> (results: [FileCandidate], pausedAtSector: UInt64?) {

        // Build a sorted array of sector ranges already found by the quick scan.
        // Using ranges + binary search avoids materialising millions of individual
        // UInt64 values into a Set (a 1 GB file alone would produce ~2M entries).
        let claimedRanges: [Range<UInt64>] = existingCandidates
            .filter { $0.sectorCount > 0 }
            .map    { $0.startSector..<$0.endSector }
            .sorted { $0.lowerBound < $1.lowerBound }

        func isClaimed(_ sector: UInt64) -> Bool {
            // Binary-search for the last range whose lowerBound <= sector,
            // then check whether that range actually contains the sector.
            var lo = 0, hi = claimedRanges.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if claimedRanges[mid].lowerBound <= sector { lo = mid + 1 }
                else { hi = mid }
            }
            return lo > 0 && claimedRanges[lo - 1].contains(sector)
        }

        var results:      [FileCandidate] = []
        let readSize      = config.sectorsPerRead
        var sector        = resumeSector
        var bytesRead:    UInt64 = 0
        let totalBytes    = device.totalBytes
        let quickDone     = (config.mode == .both || config.mode == .quick)
        var speedSamples: [(time: Date, bytes: UInt64)] = []

        while sector < device.totalSectors {

            // Cooperative cancellation — check both the Task and the legacy flag
            if Task.isCancelled || _cancelRequested { throw CancellationError() }

            // Pause request
            if _pauseRequested {
                log.info("Scan paused at sector \(sector)")
                return (results, sector)
            }

            // Yield to the Swift concurrency runtime every 256 sectors (~128 KB),
            // keeping UI and other tasks responsive during a long scan.
            if sector % 256 == 0 { await Task.yield() }

            let data: Data
            if let d = device.readWithRetry(startingSector: sector,
                                             count: readSize,
                                             sectorMap: map) {
                data = d
            } else {
                sector += UInt64(readSize)
                continue
            }

            bytesRead += UInt64(data.count)

            let absoluteByte = sector * UInt64(device.sectorSize)
            let detections   = SignatureScanner.scan(buffer: data,
                                                      bufferStartByte: absoluteByte,
                                                      sectorSize: device.sectorSize)

            for detection in detections {
                let detSector = (absoluteByte + UInt64(detection.byteOffset))
                              / UInt64(device.sectorSize)
                if isClaimed(detSector) { continue }
                if let targets = config.targetTypes,
                   !targets.contains(detection.fileType) { continue }

                let (sectorCount, recoverability) = SignatureScanner.estimateSize(
                    detection:             detection,
                    buffer:                data,
                    device:                device,
                    detectionAbsoluteByte: absoluteByte + UInt64(detection.byteOffset),
                    sectorMap:             map
                )
                let candidate = FileCandidate.fromCarving(
                    fileType:       detection.fileType,
                    startSector:    detSector,
                    sectorCount:    sectorCount,
                    estimatedSize:  sectorCount * UInt64(device.sectorSize),
                    recoverability: recoverability
                )
                results.append(candidate)
                map.mark(sector: detSector, as: .candidate)
                if results.count >= config.maxCandidates { break }
            }

            let loopEnd = min(sector + UInt64(readSize), device.totalSectors)
            for i in sector..<loopEnd {
                if map.status(at: i) == .unread { map.mark(sector: i, as: .clean) }
            }
            sector = min(sector &+ UInt64(readSize), device.totalSectors)

            let progressEvery: UInt64 = 1024
            if sector % progressEvery == 0 {
                let p = map.progress()
                speedSamples.append((Date(), bytesRead))
                if speedSamples.count > 10 { speedSamples.removeFirst() }
                let speed     = calculateSpeed(samples: speedSamples)
                let remaining = speed > 0 ?
                    Double(totalBytes - bytesRead) / (speed * 1_048_576) : 0
                let deepPct   = p.percentComplete
                let overallPct = quickDone
                    ? 50 + deepPct * 0.48
                    : deepPct * 0.93
                let totalFound = (existingCandidates + results)
                    .reduce(UInt64(0)) { $0 + $1.estimatedSize }

                onProgress?(ScanProgress(
                    phase:            .deepScan,
                    percent:          overallPct,
                    quickScanPercent: quickDone ? 100 : 0,
                    deepScanPercent:  deepPct,
                    speed:            speed,
                    eta:              remaining,
                    candidateCount:   existingCandidates.count + results.count,
                    badSectorCount:   Int(p.badSectors),
                    currentSector:    sector,
                    currentPath:      nil,
                    totalFoundBytes:  totalFound
                ))
            }

            if results.count >= config.maxCandidates { break }
        }

        return (results, nil)
    }

    // MARK: - Organising (deduplication + sort)

    private func deduplicateCandidates(_ candidates: [FileCandidate]) -> [FileCandidate] {
        guard candidates.count > 1 else { return candidates }

        let sorted = candidates.sorted { $0.startSector < $1.startSector }
        var kept:   [FileCandidate] = []

        for candidate in sorted {
            let dominated = kept.contains { existing in
                existing.startSector <= candidate.startSector &&
                existing.endSector   >= candidate.endSector   &&
                existing.recoverability >= candidate.recoverability
            }
            if !dominated { kept.append(candidate) }
        }

        return kept.sorted {
            if $0.recoverability != $1.recoverability {
                return $0.recoverability > $1.recoverability
            }
            return $0.startSector < $1.startSector
        }
    }

    // MARK: - Checkpoint save

    private func saveCheckpoint(devicePath: String,
                                 resumeSector: UInt64,
                                 candidates: [FileCandidate],
                                 map: SectorMap) throws -> URL {
        let dir = (config.checkpointDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                 .appendingPathComponent("macrecovery_checkpoint"))
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)

        let mapFile  = "sectormap.bin"
        let mapURL   = dir.appendingPathComponent(mapFile)
        try map.save(to: mapURL)

        let checkpoint = ScanCheckpoint(
            devicePath:   devicePath,
            mode:         config.mode,
            resumeSector: resumeSector,
            candidates:   candidates,
            sectorMapFile: mapFile
        )
        let cpURL   = dir.appendingPathComponent("checkpoint.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(checkpoint).write(to: cpURL)

        log.info("Checkpoint saved to \(cpURL.path)")
        return cpURL
    }

    // MARK: - File system detection

    private func detectFileSystem(_ device: DiskDevice) -> FileSystemType {
        if let data = device.readSectors(startingSector: 0, count: 4, into: nil),
           data.count >= 1026 {
            let sig = data.readBigEndianUInt16(at: 1024)
            if sig == 0x482B || sig == 0x4858 { return .hfsPlus }
        }
        if let data = device.readSector(0), data.count >= 36 {
            let magic = data.readLittleEndianUInt32(at: 32)
            if magic == 0x4253584E { return .apfs }
        }
        if let data = device.readSector(0), data.count >= 512 {
            let oemName = String(bytes: data[3..<min(11, data.count)], encoding: .ascii) ?? ""
            if oemName.hasPrefix("EXFAT") { return .exFAT }
            if FATParser.isFAT32(boot: data) { return .fat32 }
        }
        return .unknown
    }

    // MARK: - Helpers

    private func report(_ phase: ScanPhase,
                        qp: Double, dp: Double, pct: Double,
                        candidates: Int, bad: Int, sector: UInt64,
                        path: String? = nil,
                        callback: ((ScanProgress) -> Void)?) {
        callback?(ScanProgress(
            phase: phase, percent: pct,
            quickScanPercent: qp, deepScanPercent: dp,
            speed: 0, eta: 0,
            candidateCount: candidates, badSectorCount: bad,
            currentSector: sector, currentPath: path,
            totalFoundBytes: 0
        ))
    }

    private func calculateSpeed(samples: [(time: Date, bytes: UInt64)]) -> Double {
        guard samples.count >= 2 else { return 0 }
        let first = samples.first!; let last = samples.last!
        let seconds = last.time.timeIntervalSince(first.time)
        guard seconds > 0.001 else { return 0 }
        return Double(last.bytes - first.bytes) / seconds / 1_048_576
    }
}

// MARK: - Data extensions

extension Data {
    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset])           |
               UInt32(self[offset + 1]) << 8  |
               UInt32(self[offset + 2]) << 16 |
               UInt32(self[offset + 3]) << 24
    }
}
