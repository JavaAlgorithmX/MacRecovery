import SwiftUI
import RecoveryCore

struct DriveCard: View {
    let volume:     UIVolume
    let isSelected: Bool
    let action:     () -> Void

    private var isLocked: Bool { volume.scanCapability == .lockedEncrypted }
    private var isRecommended: Bool { volume.isRecommended }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {

                // ── Top row: icon + name + badge ──────────────────────────────
                HStack(alignment: .top, spacing: 12) {
                    driveIcon

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(volume.displayName)
                                .font(.headline)
                                .lineLimit(1)
                            if isRecommended {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.mrAmber)
                            }
                        }
                        HStack(spacing: 4) {
                            Text(volume.fsType.rawValue)
                            Text("·")
                            Text(volume.category.rawValue)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    CapabilityBadge(capability: volume.scanCapability)
                }

                // ── Size + used/free ──────────────────────────────────────────
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.displaySize)
                        .font(.system(.subheadline, design: .rounded).bold().monospacedDigit())
                    Spacer()
                    if let used = volume.displayUsed, let free = volume.displayFree {
                        Text("\(used)  /  \(free)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // ── Used-space bar ────────────────────────────────────────────
                if let fraction = volume.usedFraction {
                    UsedSpaceBar(fraction: fraction)
                }

                // ── Mount point ───────────────────────────────────────────────
                if let mount = volume.mountPoint {
                    Label(mount, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(16)
            .cardStyle(selected: isSelected)
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.46 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isSelected)
    }

    // MARK: - Drive icon

    private var driveIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(iconBackground)
                .frame(width: 44, height: 44)
            Image(systemName: volume.category.symbolName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isLocked ? Color.secondary : Color.mrTeal)
        }
    }

    private var iconBackground: Color {
        isLocked ? Color.primary.opacity(0.06) : Color.mrTeal.opacity(0.10)
    }
}

// MARK: - Used space bar

struct UsedSpaceBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 5)
                Capsule()
                    .fill(barColor)
                    .frame(width: geo.size.width * CGFloat(min(fraction, 1.0)), height: 5)
                    .animation(.spring(response: 0.5), value: fraction)
            }
        }
        .frame(height: 5)
    }

    private var barColor: Color {
        if fraction > 0.90 { return .mrRose  }
        if fraction > 0.70 { return .mrAmber }
        return .mrTeal
    }
}

// MARK: - Capability badge

struct CapabilityBadge: View {
    let capability: ScanCapability

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: capability.badgeIcon)
            Text(capability.badgeLabel)
        }
        .font(.caption2.bold())
        .foregroundStyle(capability.tintColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(capability.tintColor.opacity(0.12))
        .clipShape(Capsule())
    }
}
