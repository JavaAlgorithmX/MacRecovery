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
    /// Name of the file currently being written (updated on every batch tick)
    @Published var currentFileName: String?

    func extract(_ candidates: [FileCandidate],
                 device: DiskDevice,
                 to url: URL) {
        guard !candidates.isEmpty else { return }
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
                    Task { @MainActor [weak self] in
                        self?.progress        = (d, t)
                        if let name { self?.currentFileName = name }
                    }
                }
                await MainActor.run { [weak self] in
                    self?.results       = extracted
                    self?.isDone        = true
                    self?.isExtracting  = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.extractionError = error.localizedDescription
                    self?.isDone          = true
                    self?.isExtracting    = false
                }
            }
        }
    }
}
