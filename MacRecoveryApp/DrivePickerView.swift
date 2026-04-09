import SwiftUI
import UniformTypeIdentifiers
import RecoveryCore

// MARK: - Sidebar selection

private enum SidebarItem: String, CaseIterable {
    case hardwareDisk = "Hardware Disk"
    case sdCard       = "SD Card"
}

// MARK: - DrivePickerView

struct DrivePickerView: View {
    @EnvironmentObject var vm: ScanViewModel

    @State private var sidebarItem: SidebarItem = .hardwareDisk

    // Volumes shown in the main panel based on sidebar selection
    private var filteredVolumes: [UIVolume] {
        switch sidebarItem {
        case .hardwareDisk:
            return vm.volumes.filter { $0.category != .virtualDisk }
        case .sdCard:
            // SD cards appear as external disks; show all externals here
            return vm.volumes.filter { $0.category == .externalDisk }
        }
    }

    private var externalVolumes: [UIVolume] {
        filteredVolumes.filter { $0.category == .externalDisk }
    }
    private var internalVolumes: [UIVolume] {
        filteredVolumes.filter { $0.category == .internalDisk }
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Left sidebar ──────────────────────────────────────────────────
            sidebar
                .frame(width: 170)

            Divider()

            // ── Main content ──────────────────────────────────────────────────
            VStack(spacing: 0) {
                contentHeader
                Divider()
                volumeContent
                Divider()
                bottomBar
            }
        }
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {

            // App title area
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.mrTeal, .mrMint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("MacRecovery")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            // Data Recovery section
            sidebarSectionHeader("Data Recovery")

            SidebarRow(
                icon:       "internaldrive",
                iconColor:  .mrTeal,
                label:      SidebarItem.hardwareDisk.rawValue,
                isSelected: sidebarItem == .hardwareDisk
            ) {
                sidebarItem = .hardwareDisk
            }

            SidebarRow(
                icon:       "sdcard",
                iconColor:  .mrTeal,
                label:      SidebarItem.sdCard.rawValue,
                isSelected: sidebarItem == .sdCard
            ) {
                sidebarItem = .sdCard
            }

            // Divider between sections
            Divider()
                .padding(.vertical, 6)
                .padding(.horizontal, 10)

            // Advanced Features section — disabled (future)
            sidebarSectionHeader("Advanced Features")

            SidebarRow(icon: "wrench.and.screwdriver", iconColor: .secondary,
                       label: "Video Repair",  isSelected: false, disabled: true) {}
            SidebarRow(icon: "arrow.clockwise.icloud", iconColor: .secondary,
                       label: "Disk Backup",   isSelected: false, disabled: true) {}
            SidebarRow(icon: "desktopcomputer", iconColor: .secondary,
                       label: "macOS Installer", isSelected: false, disabled: true) {}

            Spacer()

            // Open image file at the bottom of sidebar
            Button(action: openImageFile) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.circle")
                        .font(.caption)
                    Text("Open Image File…")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .buttonStyle(.plain)
        }
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Content header

    private var contentHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Volume Recovery")
                .font(.title2.bold())
            Text("Select a volume from the list and click the Search for lost data button to start the recovery.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    // MARK: - Volume list

    @ViewBuilder
    private var volumeContent: some View {
        if vm.volumesLoading {
            loadingView
        } else if let err = vm.volumeError {
            errorView(err)
        } else if filteredVolumes.isEmpty {
            emptyView
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    if !externalVolumes.isEmpty {
                        volumeGroup(
                            title: "External Volume/Partition (\(externalVolumes.count))",
                            volumes: externalVolumes
                        )
                    }

                    if !internalVolumes.isEmpty {
                        volumeGroup(
                            title: "Internal Volume/Partition (\(internalVolumes.count))",
                            volumes: internalVolumes
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
    }

    private func volumeGroup(title: String, volumes: [UIVolume]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 6) {
                ForEach(volumes) { volume in
                    VolumeRow(
                        volume:     volume,
                        isSelected: vm.selectedVolume?.id == volume.id
                    ) {
                        vm.selectVolume(volume)
                    }
                }
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.3).tint(.mrTeal)
            Text("Scanning for drives…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.mrAmber)
            Text("Could not enumerate drives")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Try Again", action: vm.loadVolumes)
                .buttonStyle(.borderedProminent)
                .tint(.mrTeal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: sidebarItem == .sdCard
                  ? "sdcard" : "externaldrive.badge.questionmark")
                .font(.system(size: 52))
                .foregroundStyle(.secondary.opacity(0.4))
            Text(sidebarItem == .sdCard
                 ? "No SD cards detected"
                 : "No drives found")
                .font(.headline)
            Text(sidebarItem == .sdCard
                 ? "Insert an SD card and click Refresh."
                 : "Connect a drive and click Refresh, or open a disk image.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Help link
            Button(action: {}) {
                HStack(spacing: 4) {
                    Text("Can't find a location? Please click")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.mrTeal)
                }
            }
            .buttonStyle(.plain)
            .help("Open a disk image file instead of a physical drive")

            Spacer()

            // Refresh
            Button(action: vm.loadVolumes) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh drive list")
            .padding(.trailing, 12)

            // Search for lost data
            Button(action: searchForLostData) {
                HStack(spacing: 6) {
                    Text("Search for lost data")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mrTeal)
            .disabled(vm.selectedVolume == nil && vm.imageFileURL == nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func searchForLostData() {
        guard vm.selectedVolume != nil || vm.imageFileURL != nil else { return }
        vm.showScanOptions = true
    }

    private func openImageFile() {
        let panel = NSOpenPanel()
        panel.title                   = "Open Disk Image"
        panel.message                 = "Select a .dmg, .img, or .iso file"
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = false
        panel.prompt                  = "Open for Recovery"
        let imageTypes = ["dmg", "img", "iso", "dd", "raw"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes  = imageTypes.isEmpty ? [] : imageTypes
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            vm.openImageFile(url)
        }
    }
}

// MARK: - SidebarRow

private struct SidebarRow: View {
    let icon:       String
    let iconColor:  Color
    let label:      String
    let isSelected: Bool
    var disabled:   Bool = false
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : (disabled ? Color.secondary.opacity(0.5) : iconColor))
                    .frame(width: 18)

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : (disabled ? Color.secondary.opacity(0.5) : Color.primary))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.mrTeal : Color.clear)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - VolumeRow
// Horizontal list-style row matching the UI-Plan drive card design.

struct VolumeRow: View {
    let volume:     UIVolume
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {

                // Drive icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconBackground)
                        .frame(width: 42, height: 42)
                    Image(systemName: volume.category.symbolName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isLocked ? Color.secondary : Color.mrTeal)
                }

                // Name + filesystem + size
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(volume.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if volume.isRecommended {
                            Text("NEW")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.mrAmber)
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 4) {
                        Text(sizeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(volume.fsType.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.mrBorder)
                            .clipShape(Capsule())
                    }
                }

                Spacer(minLength: 8)

                // Selection checkmark
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.mrTeal)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.mrTeal.opacity(0.07) : Color.mrSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.mrTeal.opacity(0.5) : Color.mrBorder,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.45 : 1.0)
        .animation(.spring(response: 0.22), value: isSelected)
    }

    private var isLocked: Bool { volume.scanCapability == .lockedEncrypted }

    private var iconBackground: Color {
        isLocked ? Color.primary.opacity(0.06) : Color.mrTeal.opacity(0.10)
    }

    private var sizeLabel: String {
        if let free = volume.freeBytes {
            let used = volume.sizeBytes > free ? volume.sizeBytes - free : 0
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            fmt.allowsNonnumericFormatting = false
            return "\(fmt.string(fromByteCount: Int64(used)))/\(fmt.string(fromByteCount: Int64(volume.sizeBytes)))"
        }
        return volume.displaySize
    }
}
