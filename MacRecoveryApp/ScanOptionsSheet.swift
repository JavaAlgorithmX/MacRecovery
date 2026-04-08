import SwiftUI
import RecoveryCore

struct ScanOptionsSheet: View {
    @EnvironmentObject var vm: ScanViewModel
    @Environment(\.dismiss) var dismiss

    // Quick-select grid: the most common types users look for
    private let quickTypes: [RecoveredFileType] = [
        .jpeg, .png, .heic, .raw,
        .mp4, .mov, .pdf, .docx,
        .xlsx, .zip, .sqlite, .mp3,
    ]

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    modeSection
                    Divider()
                    typesSection
                    if vm.effectiveDevicePath != nil {
                        Divider()
                        estimateSection
                    }
                }
                .padding(28)
            }

            Divider()
            sheetFooter
        }
        .frame(width: 460)
        .fixedSize(horizontal: true, vertical: false)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "gearshape.2.fill")
                .font(.title2)
                .foregroundStyle(.mrTeal)

            VStack(alignment: .leading, spacing: 2) {
                Text("Scan Options")
                    .font(.title3.bold())
                Label(vm.effectiveDisplayName, systemImage: vm.effectiveSymbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Scan mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Scan Mode", systemImage: "magnifyingglass.circle")
                .font(.headline)

            Picker("Mode", selection: $vm.scanMode) {
                Label("Quick",         systemImage: "bolt").tag(ScanMode.quick)
                Label("Deep",          systemImage: "archivebox").tag(ScanMode.deep)
                Label("Both (Best)",   systemImage: "arrow.triangle.2.circlepath").tag(ScanMode.both)
            }
            .pickerStyle(.segmented)

            Text(modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeDescription: String {
        switch vm.scanMode {
        case .quick:
            return "Reads the file system index. Completes in seconds. Best for recently deleted files whose metadata is still intact."
        case .deep:
            return "Scans every sector looking for file signatures. Slower (minutes to hours) but finds files even after formatting."
        case .both:
            return "Quick scan first to recover named files, then deep scan for anything else. Recommended for maximum recovery."
        }
    }

    // MARK: - File type filter

    private var typesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("File Types", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                if !vm.targetTypes.isEmpty {
                    Button("Clear filter") { vm.targetTypes.removeAll() }
                        .font(.caption)
                        .foregroundStyle(.mrTeal)
                } else {
                    Text("All 25+ types")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                spacing: 8
            ) {
                ForEach(quickTypes, id: \.self) { type in
                    TypeChip(
                        type:       type,
                        isSelected: vm.targetTypes.contains(type)
                    ) {
                        if vm.targetTypes.contains(type) {
                            vm.targetTypes.remove(type)
                        } else {
                            vm.targetTypes.insert(type)
                        }
                    }
                }
            }

            Text(
                vm.targetTypes.isEmpty
                    ? "Scanning for every supported file type"
                    : "\(vm.targetTypes.count) type\(vm.targetTypes.count == 1 ? "" : "s") selected — only these will be recovered"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Time estimate

    private var estimateSection: some View {
        // Derive byte count from either the volume or the image file on disk
        let byteCount: UInt64 = {
            if let vol = vm.selectedVolume {
                return vol.sizeBytes
            }
            if let url = vm.imageFileURL,
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                return UInt64(size)
            }
            return 0
        }()

        let sizeLabel = byteCount > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
            : vm.effectiveSizeString ?? "unknown size"

        let gbPerMin: Double = vm.scanMode == .quick ? 50 : 3
        let totalGB  = Double(byteCount) / 1_000_000_000
        let mins     = byteCount > 0 ? max(1, Int(totalGB / gbPerMin)) : 0

        return HStack(spacing: 12) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(mins > 0 ? "Estimated time: \(mins)+ min" : "Estimated time: calculating…")
                    .font(.subheadline.bold())
                Text("Based on \(sizeLabel) at typical drive speeds. Actual time varies by media health.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.mrSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mrBorder, lineWidth: 0.5))
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: vm.startScan) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass.circle.fill")
                    Text("Start Scan")
                }
                .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mrTeal)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }
}

// MARK: - TypeChip

struct TypeChip: View {
    let type:       RecoveredFileType
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: type.sfSymbol)
                    .font(.system(size: 15, weight: .medium))
                Text(type.rawValue)
                    .font(.caption2.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.mrTeal : Color.mrSurface)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.mrTeal : Color.mrBorder, lineWidth: 0.5)
            )
            .animation(.spring(response: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
