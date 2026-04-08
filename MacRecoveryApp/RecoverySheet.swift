import SwiftUI
import AppKit
import RecoveryCore

struct RecoverySheet: View {
    @EnvironmentObject var vm:  ScanViewModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var extractVM = ExtractionViewModel()

    let candidates: [FileCandidate]

    @State private var outputURL: URL?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            if extractVM.isDone {
                doneView
            } else {
                setupView
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: true, vertical: false)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: extractVM.isDone ? "checkmark.circle.fill" : "arrow.down.doc.fill")
                .font(.title2)
                .foregroundStyle(extractVM.isDone ? .mrMint : .mrTeal)
                .animation(.spring, value: extractVM.isDone)

            VStack(alignment: .leading, spacing: 2) {
                Text(extractVM.isDone ? "Recovery Complete" : "Recover Files")
                    .font(.title3.bold())
                Text(
                    extractVM.isDone
                        ? "Your files have been written to the output folder."
                        : "\(candidates.count) file\(candidates.count == 1 ? "" : "s") queued for recovery"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !extractVM.isExtracting {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Setup view

    private var setupView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // File summary by category
                    let summary = CategorySummary(candidates: candidates)
                    if !summary.groups.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Files to recover")
                                .font(.headline)
                            ForEach(summary.groups, id: \.category) { group in
                                HStack {
                                    Image(systemName: group.category.symbolName)
                                        .foregroundStyle(group.category.tintColor)
                                        .frame(width: 18)
                                    Text(group.category.rawValue)
                                    Spacer()
                                    Text("\(group.count)")
                                        .foregroundStyle(.secondary)
                                    Text("·  \(formatBytes(group.totalSize))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding(16)
                        .background(Color.mrSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mrBorder, lineWidth: 0.5))
                    }

                    // Output folder picker
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Output Folder", systemImage: "folder.fill")
                            .font(.headline)

                        HStack {
                            Group {
                                if let url = outputURL {
                                    Label(url.path, systemImage: "folder")
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else {
                                    Text("No folder selected")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.subheadline)

                            Spacer()

                            Button("Choose…") { chooseFolder() }
                                .buttonStyle(.bordered)
                        }
                        .padding(14)
                        .background(Color.mrSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    outputURL == nil ? Color.mrBorder : Color.mrTeal.opacity(0.4),
                                    lineWidth: 0.5
                                )
                        )
                    }

                    // Progress bar during extraction
                    if extractVM.isExtracting {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(
                                value:  Double(extractVM.progress.done),
                                total:  Double(max(1, extractVM.progress.total))
                            )
                            .tint(.mrTeal)
                            Text("Recovering \(extractVM.progress.done) of \(extractVM.progress.total) files…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(extractVM.isExtracting)

                Spacer()

                Button(action: startExtraction) {
                    HStack(spacing: 6) {
                        if extractVM.isExtracting {
                            ProgressView().scaleEffect(0.75).tint(.white)
                        }
                        Text(extractVM.isExtracting ? "Recovering…" : "Recover \(candidates.count) Files")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.mrTeal)
                .disabled(outputURL == nil || extractVM.isExtracting || candidates.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .animation(.spring(response: 0.3), value: extractVM.isExtracting)
    }

    // MARK: - Done view

    private var doneView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    summaryCards
                    Divider()
                    resultList
                }
                .padding(24)
            }

            Divider()

            HStack {
                if let url = outputURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.mrTeal)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var summaryCards: some View {
        let success = extractVM.results.filter { $0.status == .success }.count
        let partial = extractVM.results.filter { $0.status == .partial }.count
        let failed  = extractVM.results.filter { $0.status == .failed  }.count
        let total   = extractVM.results.reduce(UInt64(0)) { $0 + $1.bytesWritten }

        return HStack(spacing: 16) {
            RecoveryStat(value: "\(success)", label: "Recovered",  color: .mrMint)
            if partial > 0 {
                RecoveryStat(value: "\(partial)", label: "Partial", color: .mrAmber)
            }
            if failed > 0 {
                RecoveryStat(value: "\(failed)", label: "Failed",   color: .mrRose)
            }
            RecoveryStat(value: formatBytes(total), label: "Total data", color: .primary)
        }
        .padding(16)
        .background(Color.mrSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mrBorder, lineWidth: 0.5))
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            ForEach(extractVM.results.prefix(30), id: \.candidate.id) { result in
                HStack(spacing: 8) {
                    Image(systemName: statusIcon(result.status))
                        .foregroundStyle(statusColor(result.status))
                        .frame(width: 16)
                    Text(result.candidate.suggestedFileName)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text(formatBytes(result.bytesWritten))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                if result.candidate.id != extractVM.results.prefix(30).last?.candidate.id {
                    Divider()
                }
            }
        }
    }

    // MARK: - Helpers

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles        = false
        panel.canChooseDirectories  = true
        panel.canCreateDirectories  = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder where recovered files will be saved"
        panel.prompt  = "Select"
        if panel.runModal() == .OK {
            outputURL = panel.url
        }
    }

    private func startExtraction() {
        guard let device = vm.device, let url = outputURL else { return }
        extractVM.extract(candidates, device: device, to: url)
    }

    private func statusIcon(_ status: ExtractionStatus) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .failed:  return "xmark.circle.fill"
        }
    }

    private func statusColor(_ status: ExtractionStatus) -> Color {
        switch status {
        case .success: return .mrMint
        case .partial: return .mrAmber
        case .failed:  return .mrRose
        }
    }
}

// MARK: - RecoveryStat

struct RecoveryStat: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
