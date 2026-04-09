import SwiftUI
import RecoveryCore

// MARK: - Sidebar modes

private enum ScanSidebarMode { case path, type }

// MARK: - ScanProgressView
// Matches UI-Plan screens 4–8:
//   left sidebar (Path/Type) · breadcrumb bar · content area · bottom status bar

struct ScanProgressView: View {
    @EnvironmentObject var vm: ScanViewModel

    private var p: ScanProgress? { vm.progress }
    private var pct: Double       { p?.percent ?? 0 }

    @State private var sidebarMode:    ScanSidebarMode = .type
    @State private var showStopConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()

            HStack(spacing: 0) {
                scanSidebar
                Divider()
                scanContent
            }
            .frame(maxHeight: .infinity)

            Divider()
            statusBar
        }
        .background(VisualEffectBackground().ignoresSafeArea())
        .sheet(isPresented: $showStopConfirm) {
            StopScanDialog(
                filesScanned: p?.candidateCount ?? 0,
                eta:          p?.eta ?? 0,
                onStop:  { showStopConfirm = false; vm.cancelScan() },
                onCancel: { showStopConfirm = false }
            )
        }
    }

    // MARK: - Breadcrumb bar

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            // Home
            Button(action: vm.cancelScan) {
                Image(systemName: "house")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Return to drive selection")

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            // Device name
            Text(vm.effectiveDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            // Phase badge
            Text(p?.phase.rawValue ?? "Preparing…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.mrSurface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.mrBorder, lineWidth: 0.5))

            // Search field (non-functional during scan, matches plan layout)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Search")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mrBorder, lineWidth: 0.5))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - Left sidebar

    private var scanSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Path / Type toggle
            HStack(spacing: 0) {
                sidebarToggleButton("Path", selected: sidebarMode == .path) {
                    withAnimation(.easeInOut(duration: 0.18)) { sidebarMode = .path }
                }
                sidebarToggleButton("Type", selected: sidebarMode == .type) {
                    withAnimation(.easeInOut(duration: 0.18)) { sidebarMode = .type }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if sidebarMode == .type {
                        typeSidebar
                    } else {
                        pathSidebar
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 180)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    // MARK: Type sidebar rows

    @ViewBuilder
    private var typeSidebar: some View {
        let count = p?.candidateCount ?? 0

        ScanCategoryRow(icon: "photo",             color: .mrTeal,                         label: "Pictures",         count: count > 0 ? "—" : "0")
        ScanCategoryRow(icon: "film",              color: Color(red:0.58,green:0.28,blue:0.92), label: "Videos",      count: count > 0 ? "—" : "0")
        ScanCategoryRow(icon: "doc.text",          color: .mrAmber,                        label: "Documents",        count: count > 0 ? "—" : "0")
        ScanCategoryRow(icon: "waveform",          color: Color(red:0.90,green:0.38,blue:0.70), label: "Audio",       count: nil, disabled: true)
        ScanCategoryRow(icon: "archivebox",        color: Color(red:0.35,green:0.80,blue:0.45), label: "Archives",    count: count > 0 ? "—" : "0")
        ScanCategoryRow(icon: "envelope",          color: .secondary,                      label: "Emails",           count: nil, disabled: true)
        ScanCategoryRow(icon: "doc.badge.clock",   color: .secondary,                      label: "Unsaved Files",    count: nil, disabled: true)
        ScanCategoryRow(icon: "globe",             color: .secondary,                      label: "Browser Bookmarks",count: nil, disabled: true)
        ScanCategoryRow(icon: "questionmark.square.dashed", color: .secondary,             label: "Others",           count: count > 0 ? "—" : "0")
    }

    // MARK: Path sidebar rows

    @ViewBuilder
    private var pathSidebar: some View {
        let name = vm.effectiveDisplayName

        ScanCategoryRow(icon: vm.effectiveSymbol, color: .mrTeal,
                        label: name, count: p.map { "\($0.candidateCount)" })

        ScanCategoryRow(icon: "wand.and.stars", color: .mrMint,
                        label: "Reconstructed", count: "0")

        sidebarSectionLabel("Quick Access")
        ScanCategoryRow(icon: "trash", color: .mrRose, label: "Trash", count: "—")
    }

    private func sidebarSectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func sidebarToggleButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? Color.mrTeal : Color.clear)
                .foregroundStyle(selected ? .white : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main content (scanning animation)

    private var scanContent: some View {
        // When progress is nil the scan is running via elevated CLI (admin password prompt)
        if vm.progress == nil {
            return AnyView(elevatedScanWaitingView)
        }
        return AnyView(normalScanContent)
    }

    private var elevatedScanWaitingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.mrTeal)
            Text("Waiting for admin authorization…")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("A macOS password dialog will appear.\nEnter your admin password to start the scan.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var normalScanContent: some View {
        VStack(spacing: 0) {
            // "Select All" row
            HStack {
                Image(systemName: "square")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Text("Select All")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Central scanning animation
            Spacer()

            VStack(spacing: 20) {
                // Animated radar / ring
                ZStack {
                    Circle()
                        .stroke(Color.mrTeal.opacity(0.10), lineWidth: 8)
                        .frame(width: 100, height: 100)

                    Circle()
                        .trim(from: 0, to: CGFloat(max(0, min(1, pct / 100))))
                        .stroke(
                            LinearGradient(colors: [.mrTeal, .mrMint],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 100, height: 100)
                        .animation(.linear(duration: 0.6), value: pct)

                    VStack(spacing: 2) {
                        Text("\(Int(pct))%")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                            .animation(.spring, value: pct)
                        Text("Scanning")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Current file
                if let path = p?.currentPath {
                    VStack(spacing: 4) {
                        Text("Currently reading")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .transition(.opacity)
                }

                // Two-phase bars
                if let p, p.quickScanPercent > 0 || p.deepScanPercent > 0 {
                    VStack(spacing: 8) {
                        PhaseBar(label: "Quick", percent: p.quickScanPercent, color: .mrTeal)
                        PhaseBar(label: "Deep",  percent: p.deepScanPercent,  color: .mrMint)
                    }
                    .frame(maxWidth: 340)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: p?.currentPath)

            Spacer()
        }
    }

    // MARK: - Bottom status bar

    private var statusBar: some View {
        HStack(spacing: 0) {

            // ── Current path ──────────────────────────────────────────────────
            HStack(spacing: 5) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.mrTeal)
                Text(p?.currentPath.map { truncatePath($0) } ?? "Preparing…")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            .padding(.leading, 14)

            Spacer()

            // ── Small ring + pct ──────────────────────────────────────────────
            ZStack {
                Circle()
                    .stroke(Color.mrTeal.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(1, pct / 100))))
                    .stroke(Color.mrTeal,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: pct)
            }
            .frame(width: 28, height: 28)

            Text("\(Int(pct))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 34)

            // ── Pause / Stop ──────────────────────────────────────────────────
            HStack(spacing: 6) {
                Button(action: vm.pauseScan) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 22)
                        .background(Color.mrSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.mrBorder, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Pause scan")

                Button(action: { showStopConfirm = true }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 22)
                        .background(Color.mrRose)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Stop scan")
            }
            .padding(.horizontal, 10)

            // ── Scan stats ────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Advanced Scan:")
                        .foregroundStyle(.secondary)
                    Text("\(p?.candidateCount ?? 0)")
                        .foregroundStyle(.mrTeal)
                        .fontWeight(.semibold)
                    if let bytes = p?.totalFoundBytes, bytes > 0 {
                        Text("(\(formatBytes(bytes)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10).monospacedDigit())

                Text("Reading sector: \(p?.currentSector ?? 0)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 10)

            // ── ETA clock ─────────────────────────────────────────────────────
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(etaLabel)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 12)

            // ── Recover button ────────────────────────────────────────────────
            Button(action: {}) {
                Text("Recover")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mrTeal)
            .disabled(true)          // enabled in results view
            .padding(.trailing, 12)
        }
        .frame(height: 52)
        .background(Color.mrTeal.opacity(0.05))
    }

    // MARK: - Helpers

    private var etaLabel: String {
        guard let eta = p?.eta, eta > 1 else { return "—" }
        let h = Int(eta) / 3600
        let m = Int(eta) % 3600 / 60
        let s = Int(eta) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func truncatePath(_ path: String) -> String {
        guard path.count > 52 else { return "Searching: \(path)" }
        return "Searching: …\(path.suffix(48))"
    }
}

// MARK: - ScanCategoryRow

struct ScanCategoryRow: View {
    let icon:     String
    let color:    Color
    let label:    String
    let count:    String?        // nil = hide count
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : color)
                .frame(width: 18)

            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary)
                .lineLimit(1)

            Spacer()

            if let count {
                Text(count)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// MARK: - ProgressRing (reused by other views)

struct ProgressRing: View {
    let progress:  Double
    let lineWidth: CGFloat
    let color:     Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, progress))))
                .stroke(
                    LinearGradient(colors: [color, color.opacity(0.55)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.6), value: progress)
        }
    }
}

// MARK: - StatCell (reused by other views)

struct StatCell: View {
    let icon:  String
    let value: String
    let unit:  String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.headline, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - PhaseBar

struct PhaseBar: View {
    let label:   String
    let percent: Double
    let color:   Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.10)).frame(height: 5)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(percent / 100, 1)),
                               height: 5)
                        .animation(.linear(duration: 0.55), value: percent)
                }
            }
            .frame(height: 5)

            Text("\(Int(percent))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
