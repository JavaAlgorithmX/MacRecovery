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
    @Published var appPhase: AppPhase = .driveSelection {
        didSet {
            log(AppLog.navigation, "appPhase: \(String(describing: oldValue)) → \(String(describing: appPhase))")
        }
    }
    @Published var showScanOptions  = false

    // ── Drive listing ─────────────────────────────────────────────────────────
    @Published var volumes:       [UIVolume] = []
    @Published var selectedVolume: UIVolume?
    @Published var volumesLoading  = false
    @Published var volumeError:    String?

    // ── Image-file mode (no FDA required) ─────────────────────────────────────
    @Published var imageFileURL: URL?

    // ── Scan configuration ────────────────────────────────────────────────────
    @Published var scanMode:    ScanMode               = .both
    @Published var targetTypes: Set<RecoveredFileType> = []

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

    // ── Permission ────────────────────────────────────────────────────────────
    @Published var hasFullDiskAccess = false

    // ── Private ───────────────────────────────────────────────────────────────
    private var activeEngine: RecoveryEngine?
    private var scanTask:     Task<Void, Never>?

    // MARK: - Derived helpers

    var effectiveDevicePath: String? {
        imageFileURL?.path ?? selectedVolume?.bsdPath
    }

    var effectiveDisplayName: String {
        if let url = imageFileURL { return url.lastPathComponent }
        return selectedVolume?.displayName ?? "Unknown"
    }

    var effectiveSymbol: String {
        imageFileURL != nil ? "doc.circle" : (selectedVolume?.category.symbolName ?? "externaldrive")
    }

    var effectiveSizeString: String? {
        if let url = imageFileURL,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return selectedVolume?.displaySize
    }

    // MARK: - Permission check

    @discardableResult
    func checkPermission() -> Bool {
        log(AppLog.permission, "checkPermission() called")

        let rawPaths = ["/dev/rdisk1", "/dev/rdisk2", "/dev/rdisk0"]
        for path in rawPaths {
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                log(AppLog.permission, "✅ FDA granted — opened \(path) successfully")
                hasFullDiskAccess = true
                return true
            }
            let err = errno
            log(AppLog.permission, "probe \(path) → errno=\(err) (\(String(cString: strerror(err))))")
            if err != EACCES && err != EPERM {
                log(AppLog.permission, "✅ FDA granted — \(path) returned non-permission errno (\(err))")
                hasFullDiskAccess = true
                return true
            }
        }

        // NOTE: Do NOT use secondary file probes (TCC.db, locationd, etc.)
        // Those paths can be readable without raw-device access, causing false
        // positives where the permission screen is skipped but the scan still
        // fails. Only raw disk nodes tell us if we can actually open /dev/rdisk*.
        log(AppLog.permission, "❌ FDA not granted — all raw disk probes returned EACCES/EPERM. Add MacRecovery in System Settings → Privacy & Security → Full Disk Access.", level: "WARN")
        hasFullDiskAccess = false
        return false
    }

    // MARK: - Drive listing

    func loadVolumes() {
        log(AppLog.volumes, "loadVolumes() called")
        volumesLoading = true
        volumeError    = nil
        Task {
            do {
                volumes = try VolumeEnumerator.listForUI()
                log(AppLog.volumes, "✅ loaded \(volumes.count) volume(s): \(volumes.map(\.bsdPath).joined(separator: ", "))")
            } catch {
                log(AppLog.volumes, "❌ loadVolumes failed: \(error.localizedDescription)", level: "ERROR")
                volumeError = error.localizedDescription
            }
            volumesLoading = false
        }
    }

    func selectVolume(_ vol: UIVolume) {
        log(AppLog.navigation, "selectVolume: \(vol.bsdPath) (\(vol.displayName)) fs=\(vol.fsType.rawValue) size=\(vol.displaySize)")
        imageFileURL    = nil
        selectedVolume  = vol
        showScanOptions = true
    }

    func openImageFile(_ url: URL) {
        log(AppLog.navigation, "openImageFile: \(url.path)")
        selectedVolume  = nil
        imageFileURL    = url
        showScanOptions = true
    }

    // MARK: - Scan lifecycle

    func startScan() {
        guard let rawPath = effectiveDevicePath else {
            log(AppLog.scan, "❌ startScan() called with no device path", level: "ERROR")
            return
        }

        let devicePath: String = {
            guard rawPath.hasPrefix("/dev/"),
                  let r = rawPath.range(of: #"s\d+$"#, options: .regularExpression)
            else { return rawPath }
            return String(rawPath[..<r.lowerBound])
        }()

        log(AppLog.scan, "startScan() — raw=\(rawPath) → scanPath=\(devicePath) mode=\(scanMode.rawValue) types=\(targetTypes.isEmpty ? "all" : targetTypes.map(\.rawValue).joined(separator: ","))")

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

            // Open device for preview
            if let dev = try? DiskDevice.open(path: devicePath) {
                self.device          = dev
                self.previewProvider = RecoveryCore.PreviewProvider(device: dev)
                log(AppLog.device, "✅ DiskDevice opened for preview: \(devicePath) (\(dev.totalBytes) bytes, \(dev.totalSectors) sectors)")
            } else {
                log(AppLog.device, "⚠️ DiskDevice.open failed for preview — previewProvider will be nil", level: "WARN")
            }

            let (stream, task) = engine.scanStream(devicePath: devicePath)
            log(AppLog.scan, "scan stream started")

            var lastLoggedPercent = -1
            for await p in stream {
                self.progress = p
                // Log every 10% to avoid flooding
                let pct = Int(p.percent / 10) * 10
                if pct != lastLoggedPercent {
                    lastLoggedPercent = pct
                    log(AppLog.scan, "progress: phase=\(p.phase.rawValue) \(Int(p.percent))% sector=\(p.currentSector) candidates=\(p.candidateCount) speed=\(String(format:"%.1f",p.speed))MB/s")
                }
            }

            do {
                let scanResult      = try await task.value
                self.result         = scanResult
                self.candidateIndex = CandidateIndex(result: scanResult)
                self.summary        = CategorySummary(candidates: scanResult.candidates)
                self.appPhase       = .results
                let duration = scanResult.duration.map { String(format: "%.1fs", $0) } ?? "?"
                log(AppLog.scan, "✅ scan complete — \(scanResult.candidates.count) candidates in \(duration), bad sectors=\(scanResult.badSectors.count)")
            } catch is CancellationError {
                log(AppLog.scan, "scan cancelled by user")
                self.appPhase = .driveSelection
            } catch {
                log(AppLog.scan, "❌ scan error: \(error.localizedDescription)", level: "ERROR")
                self.scanError = error.localizedDescription
                self.appPhase  = .driveSelection
            }
        }
    }

    func cancelScan() {
        log(AppLog.scan, "cancelScan() called")
        scanTask?.cancel()
        activeEngine?.cancel()
        appPhase = .driveSelection
    }

    func pauseScan() {
        log(AppLog.scan, "pauseScan() called")
        activeEngine?.requestPause()
    }

    func resetToStart() {
        log(AppLog.navigation, "resetToStart() — clearing scan state and returning to drive picker")
        result          = nil
        progress        = nil
        candidateIndex  = nil
        summary         = nil
        selectedVolume  = nil
        imageFileURL    = nil
        device          = nil
        previewProvider = nil
        scanMode        = .both
        targetTypes     = []
        appPhase        = .driveSelection
    }
}
