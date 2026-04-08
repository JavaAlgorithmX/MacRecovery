import SwiftUI
import UniformTypeIdentifiers
import RecoveryCore

struct DrivePickerView: View {
    @EnvironmentObject var vm: ScanViewModel

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                Divider()

                Group {
                    if vm.volumesLoading {
                        loadingView
                    } else if let err = vm.volumeError {
                        errorView(err)
                    } else if vm.volumes.isEmpty {
                        emptyView
                    } else {
                        driveGrid
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                statusBar
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: openImageFile) {
                    Label("Open Image File…", systemImage: "doc.circle")
                }
                .help("Open a .dmg, .img, or .iso disk image (no Full Disk Access required)")

                Button(action: vm.loadVolumes) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh drive list")
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.mrTeal.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.mrTeal, .mrMint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("MacRecovery")
                    .font(.title.bold())
                Text("Select a drive or image to scan for recoverable files")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Stat pills when volumes are loaded
            if !vm.volumes.isEmpty {
                HStack(spacing: 8) {
                    StatPill(
                        icon: "internaldrive",
                        value: "\(vm.volumes.filter { $0.category == .internalDisk }.count)",
                        label: "Internal"
                    )
                    StatPill(
                        icon: "externaldrive",
                        value: "\(vm.volumes.filter { $0.category == .externalDisk }.count)",
                        label: "External"
                    )
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    // MARK: - Drive grid

    private var driveGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 14)],
                spacing: 14
            ) {
                ForEach(vm.volumes) { volume in
                    DriveCard(
                        volume:     volume,
                        isSelected: vm.selectedVolume?.id == volume.id
                    ) {
                        vm.selectVolume(volume)
                    }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
            .padding(22)
        }
        .animation(.spring(response: 0.35), value: vm.volumes.count)
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.mrTeal)
            Text("Scanning for drives…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.mrAmber)
            Text("Could not enumerate drives")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Try Again", action: vm.loadVolumes)
                .buttonStyle(.borderedProminent)
                .tint(.mrTeal)
        }
        .padding(40)
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 60))
                .foregroundStyle(.secondary.opacity(0.45))
            Text("No drives found")
                .font(.headline)
            Text("Connect an external drive and click Refresh,\nor open a disk image with File → Open.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - Image file picker

    private func openImageFile() {
        let panel = NSOpenPanel()
        panel.title               = "Open Disk Image"
        panel.message             = "Select a .dmg, .img, or .iso file to scan for recoverable files"
        panel.canChooseFiles      = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt              = "Open for Recovery"

        let imageTypes = ["dmg", "img", "iso", "dd", "raw"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = imageTypes.isEmpty ? [] : imageTypes
        panel.allowsOtherFileTypes = true  // fallback: let user pick any file

        if panel.runModal() == .OK, let url = panel.url {
            vm.openImageFile(url)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            if let err = vm.scanError {
                Label(err, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.mrRose)
                    .font(.caption)
            } else {
                Text(
                    vm.volumes.isEmpty
                        ? "No drives detected"
                        : "\(vm.volumes.count) volume\(vm.volumes.count == 1 ? "" : "s") — click a drive to configure and start a scan"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("MacRecovery  ·  v1.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }
}

// MARK: - StatPill

private struct StatPill: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.mrSurface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.mrBorder, lineWidth: 0.5))
    }
}
