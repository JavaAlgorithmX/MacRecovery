import Foundation
import SwiftUI
import RecoveryCore

// MARK: - App phase

enum AppPhase {
    case driveSelection
    case scanning
    case results
}

// MARK: - ScanViewModel

@MainActor
final class ScanViewModel: ObservableObject {

    // ── Navigation ────────────────────────────────────────────────────────────
    @Published var appPhase: AppPhase = .driveSelection
    @Published var showScanOptions  = false

    // ── Drive listing ─────────────────────────────────────────────────────────
    @Published var volumes:       [UIVolume] = []
    @Published var selectedVolume: UIVolume?
    @Published var volumesLoading  = false
    @Published var volumeError:    String?

    // ── Image-file mode (no FDA required) ─────────────────────────────────────
    /// Set when the user opens a .dmg / .img file directly instead of a device.
    @Published var imageFileURL: URL?

    // ── Scan configuration ────────────────────────────────────────────────────
    @Published var scanMode:    ScanMode               = .both
    @Published var targetTypes: Set<RecoveredFileType> = []   // empty = all types

    // ── Live scan state ───────────────────────────────────────────────────────
    @Published var progress:  ScanProgress?
    @Published var scanError: String?

    // ── Results ───────────────────────────────────────────────────────────────
    @Published var result:         ScanResult?
    @Published var candidateIndex: CandidateIndex?
    @Published var summary:        CategorySummary?

    // ── Resources kept alive after scan finishes ──────────────────────────────
    var device:          DiskDevice?
    var previewProvider: RecoveryCore.PreviewProvider?

    // ── Private ───────────────────────────────────────────────────────────────
    private var activeEngine: RecoveryEngine?
    private var scanTask:     Task<Void, Never>?

    // MARK: - Derived helpers

    /// The device path that will actually be opened — image file or BSD path.
    var effectiveDevicePath: String? {
        imageFileURL?.path ?? selectedVolume?.bsdPath
    }

    /// Display name shown in the scan-options sheet header.
    var effectiveDisplayName: String {
        if let url = imageFileURL {
            return url.lastPathComponent
        }
        return selectedVolume?.displayName ?? "Unknown"
    }

    /// SF Symbol for the active source.
    var effectiveSymbol: String {
        imageFileURL != nil ? "doc.circle" : (selectedVolume?.category.symbolName ?? "externaldrive")
    }

    /// Size string for the active source (image files: from file system).
    var effectiveSizeString: String? {
        if let url = imageFileURL,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return selectedVolume?.displaySize
    }

    // MARK: - Drive listing

    func loadVolumes() {
        volumesLoading = true
        volumeError    = nil
        Task {
            do {
                volumes = try VolumeEnumerator.listForUI()
            } catch {
                volumeError = error.localizedDescription
            }
            volumesLoading = false
        }
    }

    func selectVolume(_ vol: UIVolume) {
        imageFileURL    = nil
        selectedVolume  = vol
        showScanOptions = true
    }

    /// Open a disk image file (.dmg / .img / .iso) — no Full Disk Access needed.
    func openImageFile(_ url: URL) {
        selectedVolume  = nil
        imageFileURL    = url
        showScanOptions = true
    }

    // MARK: - Scan lifecycle

    func startScan() {
        guard let devicePath = effectiveDevicePath else { return }
        showScanOptions = false
        appPhase        = .scanning
        scanError       = nil
        progress        = nil
        result          = nil

        var config         = ScanConfiguration()
        config.mode        = scanMode
        config.targetTypes = targetTypes.isEmpty ? nil : targetTypes

        let engine = RecoveryEngine(config: config)
        activeEngine = engine

        scanTask = Task { [weak self] in
            guard let self else { return }

            self.device          = try? DiskDevice.open(path: devicePath)
            self.previewProvider = self.device.map { RecoveryCore.PreviewProvider(device: $0) }

            let (stream, task) = engine.scanStream(devicePath: devicePath)

            for await p in stream { self.progress = p }

            do {
                let scanResult      = try await task.value
                self.result         = scanResult
                self.candidateIndex = CandidateIndex(result: scanResult)
                self.summary        = CategorySummary(candidates: scanResult.candidates)
                self.appPhase       = .results
            } catch is CancellationError {
                self.appPhase = .driveSelection
            } catch {
                self.scanError = error.localizedDescription
                self.appPhase  = .driveSelection
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        activeEngine?.cancel()
        appPhase = .driveSelection
    }

    func pauseScan() { activeEngine?.requestPause() }

    func resetToStart() {
        result         = nil
        progress       = nil
        candidateIndex = nil
        summary        = nil
        imageFileURL   = nil
        appPhase       = .driveSelection
    }
}
