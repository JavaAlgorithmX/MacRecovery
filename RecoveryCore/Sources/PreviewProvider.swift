import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import CoreMedia
import os.log

private let log = Logger(subsystem: "com.macrecovery", category: "PreviewProvider")

// MARK: - PreviewData

/// The result of a preview read — what the UI should render.
public enum PreviewData {
    /// Raw image bytes that can be passed to `NSImage(data:)` or `UIImage(data:)`.
    case image(Data)

    /// PNG-encoded thumbnail (always square, side = `thumbnailSize`).
    /// Generated from the first `maxPreviewBytes` of the file data.
    case thumbnail(Data)

    /// Plain-text content (plist, small readable files).
    case text(String)

    /// Hex dump of the first bytes — fallback for unrecognised types.
    case hex(Data)

    /// Preview could not be generated (no sector info, read error, etc.).
    case unavailable(reason: String)
}

// MARK: - PreviewProvider

/// Reads the first few KB of a candidate's sector range and produces a
/// `PreviewData` appropriate for the file type.
///
/// All reads are read-only and capped at `maxPreviewBytes` so previewing a
/// large video never pulls more than a small buffer.
///
/// Usage:
/// ```swift
/// let provider = PreviewProvider(device: device)
/// let preview  = provider.preview(for: candidate)
/// ```
public final class PreviewProvider {

    // MARK: Configuration

    /// Maximum bytes read from the device for any preview (default 512 KB).
    public var maxPreviewBytes: Int

    /// Pixel size of generated thumbnails (default 256 × 256).
    public var thumbnailSize: Int

    // MARK: Init

    public init(device: DiskDevice,
                maxPreviewBytes: Int = 512 * 1024,
                thumbnailSize:   Int = 256) {
        self.device          = device
        self.maxPreviewBytes = maxPreviewBytes
        self.thumbnailSize   = thumbnailSize
    }

    // MARK: - Public API

    /// Generate a preview for `candidate`.
    /// Never throws — returns `.unavailable` on any error.
    public func preview(for candidate: FileCandidate) -> PreviewData {
        guard candidate.sectorCount > 0 || candidate.estimatedSize > 0 else {
            return .unavailable(reason: "No sector information")
        }

        guard let raw = readPreviewBytes(for: candidate) else {
            return .unavailable(reason: "Cannot read sectors from device")
        }

        return makePreview(data: raw, type: candidate.fileType)
    }

    /// Read `maxPreviewBytes` from `candidate` and return raw `Data`.
    /// Returns nil only on a hard I/O error where zero bytes were readable.
    public func rawBytes(for candidate: FileCandidate) -> Data? {
        readPreviewBytes(for: candidate)
    }

    // MARK: - Private

    private let device: DiskDevice

    /// Read up to `maxPreviewBytes` from the candidate's first extent.
    private func readPreviewBytes(for candidate: FileCandidate) -> Data? {
        let sectorSize   = UInt64(device.sectorSize)
        let maxSectors   = UInt64((maxPreviewBytes + Int(sectorSize) - 1) / Int(sectorSize))
        let startSector  = candidate.startSector

        // Determine how many sectors to read
        let available: UInt64
        if candidate.sectorCount > 0 {
            available = min(candidate.sectorCount, maxSectors)
        } else if candidate.estimatedSize > 0 {
            let needed = (candidate.estimatedSize + sectorSize - 1) / sectorSize
            available = min(needed, maxSectors)
        } else {
            available = maxSectors
        }

        guard available > 0,
              startSector + available <= device.totalSectors else {
            return nil
        }

        // Read in one call; fall back to sector-by-sector on failure
        if let data = device.readSectors(startingSector: startSector,
                                          count: UInt32(available),
                                          into: nil) {
            let cap = min(data.count, maxPreviewBytes)
            return data.prefix(cap)
        }

        // Slow path — collect whatever sectors are readable
        var collected = Data()
        for i in 0..<available {
            if let s = device.readSector(startSector + i) {
                collected.append(s)
                if collected.count >= maxPreviewBytes { break }
            }
        }
        return collected.isEmpty ? nil : collected.prefix(maxPreviewBytes)
    }

    /// Decide what kind of preview to build from the raw bytes + file type.
    private func makePreview(data: Data, type: RecoveredFileType) -> PreviewData {
        switch type {
        // ── Raster images: try thumbnail first, fall back to raw data ────────
        case .jpeg, .png, .gif, .tiff, .bmp, .heic, .webp:
            if let thumb = makeThumbnail(data: data) { return .thumbnail(thumb) }
            return .image(data)

        // ── RAW camera files: thumbnail from CGImageSource ───────────────────
        case .raw:
            if let thumb = makeThumbnail(data: data) { return .thumbnail(thumb) }
            return .hex(data.prefix(256))

        // ── Video: thumbnail from first-frame extraction ─────────────────────
        case .mp4, .mov, .avi, .mkv:
            if let thumb = makeVideoThumbnail(data: data) { return .thumbnail(thumb) }
            return .hex(data.prefix(256))

        // ── Audio: hex dump of header ────────────────────────────────────────
        case .mp3, .aac, .flac, .wav, .aiff:
            return .hex(data.prefix(256))

        // ── Documents ────────────────────────────────────────────────────────
        case .pdf:
            // Show first 1 KB of text content if PDF header is present
            if let text = pdfHeaderText(data: data) { return .text(text) }
            return .hex(data.prefix(256))

        case .docx, .xlsx, .pptx, .zip:
            return .hex(data.prefix(256))

        // ── Data files ───────────────────────────────────────────────────────
        case .plist:
            if let text = String(data: data.prefix(1024), encoding: .utf8) {
                return .text(text)
            }
            return .hex(data.prefix(256))

        case .sqlite:
            return .text("SQLite database\nHeader: \(hexString(data.prefix(16)))")

        case .unknown:
            return .hex(data.prefix(256))
        }
    }

    // MARK: - Thumbnail generation

    /// Decode image bytes and produce a square PNG thumbnail via CGImageSource.
    private func makeThumbnail(data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache:            false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize:  thumbnailSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb  = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return nil
        }

        return pngData(from: thumb)
    }

    /// Extract the first video frame from in-memory data via AVFoundation.
    /// Returns a PNG-encoded thumbnail or nil if extraction fails.
    private func makeVideoThumbnail(data: Data) -> Data? {
        // Write data to a temp file — AVFoundation requires a URL-based asset
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macrecovery_preview_\(UUID().uuidString).dat")
        do {
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            return videoThumbnailFromURL(tmp)
        } catch {
            log.warning("Cannot write video temp file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Use AVFoundation to pull the first decodable frame from `url`.
    private func videoThumbnailFromURL(_ url: URL) -> Data? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let gen   = AVAssetImageGenerator(asset: asset)
        gen.maximumSize = CGSize(width: thumbnailSize, height: thumbnailSize)
        gen.appliesPreferredTrackTransform = true

        do {
            let cgImage = try gen.copyCGImage(at: .zero, actualTime: nil)
            return pngData(from: cgImage)
        } catch {
            log.info("Video thumbnail extraction failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    /// Encode a `CGImage` to PNG `Data`.
    private func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Extract the first few lines of a PDF's raw text content.
    private func pdfHeaderText(data: Data) -> String? {
        guard let text = String(data: data.prefix(512), encoding: .ascii) else { return nil }
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(6)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Format bytes as uppercase hex pairs separated by spaces, e.g. "FF D8 FF E0"
    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: - PreviewData helpers

public extension PreviewData {

    /// True when the preview contains displayable content.
    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// Short description for CLI output.
    var summary: String {
        switch self {
        case .image:              return "Image data"
        case .thumbnail:          return "Thumbnail (PNG)"
        case .text(let s):        return String(s.prefix(120))
        case .hex(let d):         return hexDump(d)
        case .unavailable(let r): return "Unavailable: \(r)"
        }
    }

    private func hexDump(_ data: Data) -> String {
        let bytes = data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        return "Hex[\(data.count)B]: \(bytes)"
    }
}
