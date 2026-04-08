import SwiftUI
import RecoveryCore

struct ScanProgressView: View {
    @EnvironmentObject var vm: ScanViewModel

    private var p: ScanProgress? { vm.progress }
    private var pct: Double { p?.percent ?? 0 }

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Sub-title bar ─────────────────────────────────────────────
                HStack {
                    Label(vm.effectiveDisplayName, systemImage: vm.effectiveSymbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(vm.scanMode.rawValue.capitalized + " scan")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.mrSurface)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 40)
                .padding(.top, 28)

                Spacer()

                // ── Ring + percentage ─────────────────────────────────────────
                ZStack {
                    // Ambient glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.mrTeal.opacity(0.10), .clear],
                                center: .center,
                                startRadius: 60,
                                endRadius: 160
                            )
                        )
                        .frame(width: 320, height: 320)

                    ProgressRing(
                        progress:  pct / 100,
                        lineWidth: 9,
                        color:     .mrTeal
                    )
                    .frame(width: 200, height: 200)

                    VStack(spacing: 5) {
                        Text("\(Int(pct))%")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .contentTransition(.numericText(countsDown: false))
                            .animation(.spring, value: pct)

                        Text(p?.phase.rawValue ?? "Preparing…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 140)
                    }
                }

                Spacer().frame(height: 44)

                // ── Stats row ─────────────────────────────────────────────────
                statsRow
                    .padding(.horizontal, 52)

                Spacer().frame(height: 24)

                // ── Current path ──────────────────────────────────────────────
                if let path = p?.currentPath {
                    currentPathRow(path)
                        .padding(.horizontal, 52)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // ── Two-phase bars ────────────────────────────────────────────
                if let p, p.quickScanPercent > 0 || p.deepScanPercent > 0 {
                    VStack(spacing: 10) {
                        PhaseBar(label: "Quick", percent: p.quickScanPercent, color: .mrTeal)
                        PhaseBar(label: "Deep",  percent: p.deepScanPercent,  color: .mrMint)
                    }
                    .padding(.horizontal, 52)
                    .padding(.top, 18)
                    .transition(.opacity)
                }

                Spacer()

                // ── Candidate count ticker ────────────────────────────────────
                if let count = p?.candidateCount, count > 0 {
                    Text("\(count) file\(count == 1 ? "" : "s") found so far")
                        .font(.footnote)
                        .foregroundStyle(.mrMint)
                        .contentTransition(.numericText())
                        .animation(.spring, value: count)
                }

                Spacer().frame(height: 24)

                // ── Controls ──────────────────────────────────────────────────
                controls
                    .padding(.bottom, 44)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: p?.currentPath)
        .animation(.easeInOut(duration: 0.3), value: p?.quickScanPercent)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            StatCell(
                icon:  "speedometer",
                value: p.map { String(format: "%.1f", $0.speed) } ?? "—",
                unit:  "MB/s",
                color: .primary
            )
            Divider().frame(height: 36)
            StatCell(
                icon:  "clock",
                value: p.map { etaString($0.eta) } ?? "—",
                unit:  "ETA",
                color: .primary
            )
            Divider().frame(height: 36)
            StatCell(
                icon:  "doc.badge.plus",
                value: p.map { "\($0.candidateCount)" } ?? "0",
                unit:  "Found",
                color: .mrMint
            )
            Divider().frame(height: 36)
            StatCell(
                icon:  "exclamationmark.triangle",
                value: p.map { "\($0.badSectorCount)" } ?? "0",
                unit:  "Bad Sectors",
                color: (p?.badSectorCount ?? 0) > 0 ? .mrAmber : .secondary
            )
        }
        .frame(maxWidth: 520)
        .padding(.vertical, 16)
        .background(Color.mrSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.mrBorder, lineWidth: 0.5))
    }

    // MARK: - Current path

    private func currentPathRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.mrTeal)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 560)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Button(action: vm.cancelScan) {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Button(action: vm.pauseScan) {
                Label("Pause", systemImage: "pause.circle")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(.mrAmber)
        }
    }

    // MARK: - Helpers

    private func etaString(_ seconds: TimeInterval) -> String {
        guard seconds > 1 else { return "—" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - ProgressRing shape

struct ProgressRing: View {
    let progress:  Double    // 0–1
    let lineWidth: CGFloat
    let color:     Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.12), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, progress))))
                .stroke(
                    LinearGradient(
                        colors: [color, color.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint:   .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.6), value: progress)
        }
    }
}

// MARK: - StatCell

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
                        .frame(
                            width: geo.size.width * CGFloat(min(percent / 100, 1)),
                            height: 5
                        )
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
