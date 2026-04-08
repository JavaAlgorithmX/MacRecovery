import Foundation
import RecoveryCore

// MARK: - ExtractionViewModel

@MainActor
final class ExtractionViewModel: ObservableObject {

    @Published var progress: (done: Int, total: Int) = (0, 0)
    @Published var results:      [ExtractionResult] = []
    @Published var isExtracting  = false
    @Published var isDone        = false
    @Published var extractionError: String?

    func extract(_ candidates: [FileCandidate],
                 device: DiskDevice,
                 to url: URL) {
        guard !candidates.isEmpty else { return }
        isExtracting     = true
        progress         = (0, candidates.count)
        extractionError  = nil

        Task.detached(priority: .userInitiated) { [weak self, candidates, url] in
            let extractor = FileExtractor(device: device)
            do {
                let extracted = try extractor.extractAll(candidates, to: url) { done, total, _ in
                    let d = done, t = total
                    Task { @MainActor [weak self] in self?.progress = (d, t) }
                }
                await MainActor.run { [weak self] in
                    self?.results      = extracted
                    self?.isDone       = true
                    self?.isExtracting = false
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
