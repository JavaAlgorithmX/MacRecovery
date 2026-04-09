import SwiftUI
import AppKit
import RecoveryCore

// MARK: - RecoverySheet
// Three-phase flow matching UI-Plan screens 10, 12, 11:
//   1. Location picker  →  2. Recovery in-progress  →  3. Recovery complete

struct RecoverySheet: View {
    @EnvironmentObject var vm: ScanViewModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var extractVM = ExtractionViewModel()

    let candidates: [FileCandidate]

    // Location picker state
    @State private var selectedVolumeID: String?  = nil   // nil = use customURL
    @State private var customURL:         URL?     = nil
    @State private var localCloudTab:     Int      = 0    // 0 = Local, 1 = Cloud
    @State private var showDeviceError    = false

    // MARK: - Resolved output URL

    private var outputURL: URL? {
        if let id = selectedVolumeID,
           let vol = vm.volumes.first(where: { $0.id == id }),
           let mount = vol.mountPoint {
            return URL(fileURLWithPath: mount)
        }
        return customURL
    }

    // Total size of queued candidates
    private var totalBytes: UInt64 {
        candidates.reduce(0) { $0 + $1.estimatedSize }
    }

    // True when the selected output volume is the same as the scan source
    private var isRecoveringToSource: Bool {
        guard let selectedID = selectedVolumeID else { return false }
        return selectedID == vm.selectedVolume?.id
    }

    // MARK: - Body

    var body: some View {
        Group {
            if extractVM.isDone {
                doneView
            } else if extractVM.isExtracting {
                progressView
            } else {
                locationPickerView
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: true, vertical: false)
        .background(VisualEffectBackground().ignoresSafeArea())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.25), value: extractVM.isExtracting)
        .animation(.easeInOut(duration: 0.25), value: extractVM.isDone)
        .alert("Device Unavailable", isPresented: $showDeviceError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The source device could not be opened. Please return to the drive picker and start a new scan.")
        }
    }

    // MARK: ── Phase 1: Location picker ────────────────────────────────────────

    private var locationPickerView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Text("Please select a target location to save")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("The current recovery will save \(candidates.count) file\(candidates.count == 1 ? "" : "s") (\(formatBytes(totalBytes)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)

            // Local | Cloud tab
            Picker("", selection: $localCloudTab) {
                Text("Local").tag(0)
                Text("Cloud").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            // Volume list
            VStack(spacing: 6) {
                if localCloudTab == 0 {
                    localVolumeList
                } else {
                    cloudPlaceholder
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: startExtraction)
                    .buttonStyle(.borderedProminent)
                    .tint(.mrTeal)
                    .disabled(outputURL == nil || isRecoveringToSource)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .onAppear { preselectDefaultVolume() }
    }

    @ViewBuilder
    private var localVolumeList: some View {
        let sourceID = vm.selectedVolume?.id

        // Available mounted volumes
        ForEach(vm.volumes.filter { $0.mountPoint != nil }) { vol in
            let isSelected = selectedVolumeID == vol.id
            let isSameAsSource = vol.id == sourceID

            Button(action: { selectedVolumeID = vol.id; customURL = nil }) {
                HStack(spacing: 12) {
                    // Radio button
                    Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.mrTeal : Color.secondary)

                    // Drive icon
                    Image(systemName: vol.category.symbolName)
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    // Name + info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vol.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("\(vol.category.rawValue) disk \(vol.displaySize)"
                             + (vol.freeBytes.map { " - \(formatBytes($0)) available" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Indicator: check or warning
                    if isSelected && !isSameAsSource {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.mrMint)
                    } else if isSameAsSource {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.mrAmber)
                            .help("Recovering to the same drive as the source may overwrite data")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.mrTeal.opacity(0.07) : Color.mrSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.mrTeal.opacity(0.4) : Color.mrBorder,
                                lineWidth: isSelected ? 1.2 : 0.5)
                )
            }
            .buttonStyle(.plain)
        }

        // Choose folder…
        Button(action: chooseCustomFolder) {
            HStack(spacing: 12) {
                Image(systemName: customURL != nil ? "circle.inset.filled" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(customURL != nil ? Color.mrTeal : Color.secondary)

                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.mrAmber)
                    .frame(width: 24)

                Text(customURL?.path ?? "Choose folder…")
                    .font(.system(size: 13, weight: customURL != nil ? .regular : .semibold))
                    .foregroundStyle(customURL != nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(customURL != nil ? Color.mrTeal.opacity(0.07) : Color.mrSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(customURL != nil ? Color.mrTeal.opacity(0.4) : Color.mrBorder,
                            lineWidth: customURL != nil ? 1.2 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var cloudPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 40))
                .foregroundStyle(.mrTeal.opacity(0.4))
            Text("Cloud recovery coming soon")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: ── Phase 2: In-progress ────────────────────────────────────────────

    private var progressView: some View {
        VStack(spacing: 0) {
            // Icon cluster
            ZStack {
                // Stacked file tiles (same style as StopScanDialog)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.40, green: 0.70, blue: 1.00))
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(-10))
                    .offset(x: -10, y: 4)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.55, green: 0.85, blue: 0.45))
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(6))
                    .offset(x: 8, y: 6)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mrTeal)
                    .frame(width: 32, height: 32)

                // Circular arrow badge
                ZStack {
                    Circle().fill(.white).frame(width: 24, height: 24)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.mrTeal)
                }
                .offset(x: 16, y: -16)
            }
            .frame(width: 72, height: 72)
            .padding(.top, 32)
            .padding(.bottom, 16)

            // Current filename
            if let name = extractVM.currentFileName {
                Text("Recovering: \(name)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                    .transition(.opacity)
                    .animation(.easeInOut, value: extractVM.currentFileName)
            }

            // Stats row
            HStack(spacing: 0) {
                progressStat(
                    value: "\(extractVM.progress.done)/\(extractVM.progress.total)"
                           + (totalBytes > 0 ? " (\(formatBytes(totalBytes)))" : ""),
                    label: "Recovered"
                )
                Divider().frame(height: 44)
                progressStat(
                    value: String(format: "%.2f%%",
                                  Double(extractVM.progress.done)
                                  / Double(max(1, extractVM.progress.total)) * 100),
                    label: "Completed"
                )
            }
            .background(Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mrBorder, lineWidth: 0.5))
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            // Progress bar
            ProgressView(
                value:  Double(extractVM.progress.done),
                total:  Double(max(1, extractVM.progress.total))
            )
            .tint(.mrTeal)
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            // Recover-to path
            if let url = outputURL {
                HStack(spacing: 4) {
                    Text("Recover to:")
                        .foregroundStyle(.secondary)
                    Text(url.path)
                        .foregroundStyle(.mrTeal)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }

            // View recovered (disabled while in progress)
            Button("View recovered") {}
                .buttonStyle(.borderedProminent)
                .tint(.mrTeal)
                .disabled(true)
                .padding(.bottom, 28)
        }
    }

    // MARK: ── Phase 3: Done ───────────────────────────────────────────────────

    private var doneView: some View {
        VStack(spacing: 0) {
            // Trophy icon
            ZStack {
                // Sparkle dots
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill([Color.mrAmber, Color.mrTeal, Color.mrMint,
                               Color.mrRose, .purple, .orange][i])
                        .frame(width: 5, height: 5)
                        .offset(sparkleOffset(index: i, radius: 44))
                }

                // Medal / trophy
                Image(systemName: "rosette")
                    .font(.system(size: 52))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.80, blue: 0.20),
                                     Color(red: 0.85, green: 0.55, blue: 0.10)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                // Green checkmark badge
                ZStack {
                    Circle().fill(.white).frame(width: 22, height: 22)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.mrMint)
                }
                .offset(x: 20, y: 20)
            }
            .frame(width: 80, height: 80)
            .padding(.top, 36)
            .padding(.bottom, 14)

            // Title
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.mrMint)
                Text("Recovery Completed!")
                    .font(.title3.bold())
            }
            .padding(.bottom, 20)

            // Stats
            let successCount = extractVM.results.filter { $0.status != .failed }.count
            let totalWritten = extractVM.results.reduce(UInt64(0)) { $0 + $1.bytesWritten }

            HStack(spacing: 0) {
                progressStat(value: "\(successCount)", label: "Files recovered")
                Divider().frame(height: 44)
                progressStat(value: formatBytes(totalWritten), label: "Size")
            }
            .background(Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mrBorder, lineWidth: 0.5))
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            // Recover-to path
            if let url = outputURL {
                HStack(spacing: 4) {
                    Text("Recover to:")
                        .foregroundStyle(.secondary)
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Text(url.path)
                            .foregroundStyle(.mrTeal)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }

            // View recovered
            Button(action: {
                if let url = outputURL { NSWorkspace.shared.open(url) }
                dismiss()
            }) {
                Text("View recovered")
                    .frame(width: 180)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mrTeal)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Shared sub-views

    private func progressStat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.headline, design: .rounded).bold().monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // Distribute sparkle dots evenly around a circle
    private func sparkleOffset(index: Int, radius: CGFloat) -> CGSize {
        let angle = Double(index) / 6.0 * 2 * .pi - .pi / 2
        return CGSize(width: radius * cos(angle), height: radius * sin(angle))
    }

    // MARK: - Actions

    private func preselectDefaultVolume() {
        // Auto-select the first non-source internal volume
        let sourceID = vm.selectedVolume?.id
        if let best = vm.volumes.first(where: {
            $0.id != sourceID &&
            $0.category == .internalDisk &&
            $0.mountPoint != nil
        }) {
            selectedVolumeID = best.id
        }
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles        = false
        panel.canChooseDirectories  = true
        panel.canCreateDirectories  = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder where recovered files will be saved"
        panel.prompt  = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            customURL        = url
            selectedVolumeID = nil
        }
    }

    private func startExtraction() {
        log(AppLog.recovery, "startExtraction() called — \(candidates.count) candidates")
        guard let url = outputURL else {
            log(AppLog.recovery, "❌ startExtraction aborted — outputURL is nil", level: "ERROR")
            return
        }
        guard let device = vm.device else {
            log(AppLog.recovery, "❌ startExtraction aborted — vm.device is nil (DiskDevice not open)", level: "ERROR")
            showDeviceError = true
            return
        }
        log(AppLog.recovery, "extracting to: \(url.path)")
        extractVM.extract(candidates, device: device, to: url)
    }
}
