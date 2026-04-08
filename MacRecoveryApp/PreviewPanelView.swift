import SwiftUI
import RecoveryCore

struct PreviewPanelView: View {
    let candidate:       FileCandidate
    let previewProvider: RecoveryCore.PreviewProvider?
    let isQueued:        Bool
    let toggleQueued:    () -> Void

    @State private var previewData: PreviewData?
    @State private var isLoading   = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                previewArea
                    .frame(maxWidth: .infinity)
                    .frame(height: 230)
                    .background(Color.primary.opacity(0.03))
                    .clipped()

                Divider()

                metaSection
            }
        }
        .task(id: candidate.id) {
            isLoading   = true
            previewData = nil
            if let provider = previewProvider {
                let data = await Task.detached(priority: .userInitiated) { [provider, candidate] in
                    provider.preview(for: candidate)
                }.value
                previewData = data
            }
            isLoading = false
        }
    }

    // MARK: - Preview area

    @ViewBuilder
    private var previewArea: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().tint(.mrTeal)
                Text("Loading preview…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch previewData {

            case .image(let data), .thumbnail(let data):
                if let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .transition(.opacity)
                } else {
                    typeIconPlaceholder
                }

            case .text(let str):
                ScrollView {
                    Text(str)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }

            case .hex(let data):
                ScrollView {
                    Text(hexDump(data.prefix(256)))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.mrTeal)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }

            case .unavailable(let reason):
                VStack(spacing: 10) {
                    Image(systemName: candidate.fileType.sfSymbol)
                        .font(.system(size: 46, weight: .ultraLight))
                        .foregroundStyle(candidate.fileType.category.tintColor.opacity(0.38))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case nil:
                typeIconPlaceholder
            }
        }
    }

    private var typeIconPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: candidate.fileType.sfSymbol)
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(candidate.fileType.category.tintColor.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Metadata section

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 18) {

            // File name + path
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.suggestedFileName)
                    .font(.headline)
                    .textSelection(.enabled)
                if let path = candidate.originalPath {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }

            // Score
            ScoreBadge(score: candidate.recoverability, expanded: true)

            Divider()

            // Metadata grid
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                MetaCell(label: "Type",    value: candidate.fileType.kindLabel)
                MetaCell(label: "Size",    value: formatBytes(candidate.estimatedSize))
                MetaCell(label: "Sector",  value: "\(candidate.startSector)")
                MetaCell(label: "Source",  value: candidate.source.rawValue)
                if let date = candidate.modificationDate {
                    MetaCell(
                        label: "Modified",
                        value: date.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                MetaCell(label: "Extent", value: "\(candidate.sectorCount) sectors")
            }

            Divider()

            // Action button
            Button(action: toggleQueued) {
                Label(
                    isQueued ? "Remove from Recovery Queue" : "Add to Recovery Queue",
                    systemImage: isQueued ? "minus.circle.fill" : "plus.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isQueued ? Color(white: 0.5) : .mrTeal)
            .controlSize(.large)
            .animation(.spring(response: 0.2), value: isQueued)
        }
        .padding(20)
    }

    // MARK: - Hex dump

    private func hexDump(_ data: Data) -> String {
        let bytes = Array(data)
        var lines: [String] = []
        for i in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[i..<min(i + 16, bytes.count)]
            let hex   = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = chunk.map {
                $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "·"
            }.joined()
            lines.append(String(format: "%04X  %-48s  %@", i, hex, ascii))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - MetaCell

struct MetaCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(2)
        }
    }
}
