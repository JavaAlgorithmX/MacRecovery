import Foundation
import RecoveryCore

// MARK: - ExtractionViewModel

@MainActor
final class ExtractionViewModel: ObservableObject {

    @Published var progress: (done: Int, total: Int) = (0, 0)
    @Published var results:         [ExtractionResult] = []
    @Published var isExtracting     = false
    @Published var isDone           = false
    @Published var extractionError: String?
    @Published var currentFileName: String?

    func extract(_ candidates: [FileCandidate],
                 device: DiskDevice,
                 to url: URL) {
        guard !candidates.isEmpty else {
            log(AppLog.extraction, "⚠️ extract() called with empty candidates list", level: "WARN")
            return
        }

        log(AppLog.extraction, "extract() started — \(candidates.count) file(s) → \(url.path)")
        log(AppLog.extraction, "candidates: \(candidates.map(\.suggestedFileName).prefix(5).joined(separator: ", "))\(candidates.count > 5 ? " + \(candidates.count - 5) more" : "")")

        isExtracting    = true
        progress        = (0, candidates.count)
        extractionError = nil
        currentFileName = nil

        Task.detached(priority: .userInitiated) { [weak self, candidates, url] in
            let extractor = FileExtractor(device: device)
            do {
                let extracted = try extractor.extractAll(candidates, to: url) { done, total, latest in
                    let d    = done
                    let t    = total
                    let name = latest?.candidate.suggestedFileName
                    let status = latest?.status

                    if let name, let status {
                        let icon: String
                        switch status {
                        case .success: icon = "✅"
                        case .partial: icon = "⚠️"
                        case .failed:  icon = "❌"
                        }
                        log(AppLog.extraction, "\(icon) [\(d)/\(t)] \(name) status=\(status)")
                    }

                    Task { @MainActor [weak self] in
                        self?.progress        = (d, t)
                        if let name { self?.currentFileName = name }
                    }
                }

                let success = extracted.filter { $0.status == .success }.count
                let partial = extracted.filter { $0.status == .partial }.count
                let failed  = extracted.filter { $0.status == .failed  }.count
                let bytes   = extracted.reduce(UInt64(0)) { $0 + $1.bytesWritten }
                log(AppLog.extraction, "✅ extraction complete — success=\(success) partial=\(partial) failed=\(failed) totalBytes=\(bytes)")

                await MainActor.run { [weak self] in
                    self?.results      = extracted
                    self?.isDone       = true
                    self?.isExtracting = false
                }
            } catch {
                log(AppLog.extraction, "❌ extraction error: \(error.localizedDescription)", level: "ERROR")
                await MainActor.run { [weak self] in
                    self?.extractionError = error.localizedDescription
                    self?.isDone          = true
                    self?.isExtracting    = false
                }
            }
        }
    }
}
