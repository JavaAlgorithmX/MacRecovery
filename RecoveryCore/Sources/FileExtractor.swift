import Foundation
import os.log

private let log = Logger(subsystem: "com.macrecovery", category: "FileExtractor")

// MARK: - FileExtractor

/// Reads raw sectors from a DiskDevice and writes recovered files to disk.
///
/// Usage:
///   1. Obtain a `[FileCandidate]` from `RecoveryEngine.scan()`
///   2. Create a `FileExtractor` with the same device
///   3. Call `extract(_:to:)` per file, or `extractAll(_:to:)` for a batch
///
/// Bad sectors are padded with zeros rather than aborting. The caller can
/// inspect `ExtractionResult.badSectors` and `ExtractionResult.status` to
/// decide how to present partial files to the user.
public final class FileExtractor {

    // MARK: - Public types

    /// Per-file progress: bytes written so far and the total expected.
    public typealias FileProgressCallback  = (_ written: UInt64, _ total: UInt64) -> Void

    /// Batch progress: index of the just-finished file (1-based), total count,
    /// and its result (nil on the first call when index == 0).
    public typealias BatchProgressCallback = (_ completed: Int, _ total: Int,
                                              _ latest: ExtractionResult?) -> Void

    // MARK: - Init

    /// - Parameters:
    ///   - device:    The source device opened read-only by `DiskDevice.open`.
    ///   - chunkSize: How many sectors to read in one `pread` call (default 64 = 32 KB).
    public init(device: DiskDevice, chunkSize: UInt32 = 64) {
        self.device    = device
        self.chunkSize = chunkSize
    }

    // MARK: - Public API

    /// Extract a single file candidate to `outputDirectory`.
    ///
    /// - The output filename is taken from `candidate.suggestedFileName`.
    /// - If a file with that name already exists, a numeric suffix is appended
    ///   (`name_1.jpg`, `name_2.jpg`, …).
    /// - If `candidate.estimatedSize > 0`, the output is truncated to that byte
    ///   count to strip trailing sector-alignment padding.
    ///
    /// - Returns: An `ExtractionResult` with status `.success`, `.partial`, or
    ///   `.failed`. Never throws for I/O errors on the source device — bad sectors
    ///   are zeroed and counted.
    /// - Throws: `ExtractionError.cannotCreateFile` if the output file cannot be
    ///   created (e.g. no write permission on `outputDirectory`).
    public func extract(
        _ candidate: FileCandidate,
        to outputDirectory: URL,
        onProgress: FileProgressCallback? = nil
    ) throws -> ExtractionResult {
        let extents = candidate.extents
        guard !extents.isEmpty else {
            log.warning("Candidate \(candidate.id) has no extents — skipping")
            return ExtractionResult(candidate: candidate, outputURL: nil,
                                    status: .failed, bytesWritten: 0, badSectors: [])
        }

        let outputURL = resolveOutputURL(for: candidate, in: outputDirectory)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw ExtractionError.cannotCreateFile(path: outputURL.path)
        }

        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        // Total bytes we expect to write (for progress reporting).
        let totalExpected: UInt64 = candidate.estimatedSize > 0
            ? candidate.estimatedSize
            : extents.reduce(0) { $0 + $1.sectorCount } * UInt64(device.sectorSize)

        var allBad:     [UInt64] = []
        var totalWritten: UInt64 = 0

        for extent in extents {
            let (written, bad) = try writeExtent(
                extent, to: handle,
                totalExpected: totalExpected,
                priorWritten: totalWritten,
                onProgress: onProgress
            )
            totalWritten += written
            allBad.append(contentsOf: bad)
        }

        // Trim trailing sector padding when we know the real file size.
        if candidate.estimatedSize > 0 && totalWritten > candidate.estimatedSize {
            try handle.truncate(atOffset: candidate.estimatedSize)
            totalWritten = candidate.estimatedSize
        }

        let status: ExtractionStatus = allBad.isEmpty    ? .success
                                     : totalWritten > 0  ? .partial
                                     : .failed

        log.info("Extracted \(candidate.suggestedFileName): \(totalWritten) bytes [\(status.rawValue)]")

        return ExtractionResult(
            candidate:    candidate,
            outputURL:    outputURL,
            status:       status,
            bytesWritten: totalWritten,
            badSectors:   allBad
        )
    }

    /// Extract a batch of candidates to `outputDirectory`.
    ///
    /// Each candidate is extracted independently; an I/O error on one file does
    /// not abort the rest. A `.failed` result is recorded for any candidate that
    /// throws during extraction.
    ///
    /// `outputDirectory` is created (including intermediate directories) if it
    /// does not exist.
    public func extractAll(
        _ candidates: [FileCandidate],
        to outputDirectory: URL,
        onProgress: BatchProgressCallback? = nil
    ) throws -> [ExtractionResult] {
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)

        var results: [ExtractionResult] = []
        results.reserveCapacity(candidates.count)

        for (index, candidate) in candidates.enumerated() {
            onProgress?(index, candidates.count, nil)

            let result: ExtractionResult
            do {
                result = try extract(candidate, to: outputDirectory)
            } catch {
                log.error("Failed to extract \(candidate.suggestedFileName): \(error.localizedDescription)")
                result = ExtractionResult(
                    candidate:    candidate,
                    outputURL:    nil,
                    status:       .failed,
                    bytesWritten: 0,
                    badSectors:   []
                )
            }

            results.append(result)
            onProgress?(index + 1, candidates.count, result)
        }

        return results
    }

    // MARK: - Private

    private let device:    DiskDevice
    private let chunkSize: UInt32

    /// Write one extent to `handle`.  Returns bytes written and the list of bad sector addresses.
    private func writeExtent(
        _ extent: FileExtent,
        to handle: FileHandle,
        totalExpected: UInt64,
        priorWritten: UInt64,
        onProgress: FileProgressCallback?
    ) throws -> (bytesWritten: UInt64, badSectors: [UInt64]) {
        var written: UInt64  = 0
        var bad:     [UInt64] = []
        var sector = extent.startSector
        // Cap at device boundary — inflated estimatedSize must not write zeros past end of device.
        let end    = min(extent.startSector + extent.sectorCount, device.totalSectors)

        while sector < end {
            let remaining = end - sector
            let count     = UInt32(min(UInt64(chunkSize), remaining))

            let (data, chunkBad) = readChunk(startingSector: sector, count: count)
            bad.append(contentsOf: chunkBad)
            try handle.write(contentsOf: data)
            written += UInt64(data.count)
            sector  += UInt64(count)

            onProgress?(priorWritten + written, totalExpected)
        }

        return (written, bad)
    }

    /// Read `count` sectors starting at `startingSector`.
    ///
    /// Always returns a Data buffer of exactly `count × sectorSize` bytes.
    /// Unreadable sectors are substituted with zero bytes and their addresses
    /// are returned in the second element of the tuple.
    private func readChunk(
        startingSector: UInt64,
        count: UInt32
    ) -> (data: Data, badSectors: [UInt64]) {
        let expectedBytes = Int(count) * Int(device.sectorSize)

        // Fast path — read the whole chunk in one syscall.
        if let data = device.readSectors(startingSector: startingSector,
                                         count: count, into: nil) {
            if data.count == expectedBytes {
                return (data, [])
            }
            // Short read (near device end) — pad the tail.
            let shortfall = expectedBytes - data.count
            let firstBadSector = startingSector + UInt64(data.count / Int(device.sectorSize))
            var padded = data
            padded.append(Data(count: shortfall))
            let badRange = firstBadSector..<(startingSector + UInt64(count))
            return (padded, Array(badRange))
        }

        // Slow path — sector-by-sector fallback.
        var result = Data()
        result.reserveCapacity(expectedBytes)
        var bad: [UInt64] = []

        for i in 0..<UInt64(count) {
            let s = startingSector + i
            if let sectorData = device.readSectors(startingSector: s, count: 1, into: nil) {
                result.append(sectorData)
            } else {
                result.append(Data(count: Int(device.sectorSize)))
                bad.append(s)
            }
        }

        return (result, bad)
    }

    /// Returns a file URL inside `directory` that does not already exist.
    /// Collisions are resolved by appending `_1`, `_2`, … before the extension.
    private func resolveOutputURL(for candidate: FileCandidate, in directory: URL) -> URL {
        let suggested = candidate.suggestedFileName
        let base      = URL(fileURLWithPath: suggested)
        let stem      = base.deletingPathExtension().lastPathComponent
        let ext       = base.pathExtension

        var url     = directory.appendingPathComponent(suggested)
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let name = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
            url = directory.appendingPathComponent(name)
            counter += 1
        }
        return url
    }
}

// MARK: - ExtractionError

public enum ExtractionError: Error, LocalizedError {
    case cannotCreateFile(path: String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let p):
            return "Cannot create output file at \(p)"
        }
    }
}
