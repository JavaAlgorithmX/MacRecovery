import SwiftUI
import RecoveryCore

/// Compact or expanded recoverability score badge.
struct ScoreBadge: View {
    let score:    RecoverabilityScore
    var expanded: Bool = false

    var body: some View {
        if expanded {
            expandedView
        } else {
            compactView
        }
    }

    // MARK: - Compact (list row)

    private var compactView: some View {
        HStack(spacing: 3) {
            Image(systemName: score.badgeIcon)
            Text(score.label)
        }
        .font(.caption2.bold())
        .foregroundStyle(score.tintColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(score.tintColor.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Expanded (detail panel)

    private var expandedView: some View {
        HStack(spacing: 10) {
            Image(systemName: score.badgeIcon)
                .font(.title3)
                .foregroundStyle(score.tintColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(score.label + " recoverability")
                    .font(.subheadline.bold())
                    .foregroundStyle(score.tintColor)
                Text(score.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(score.tintColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(score.tintColor.opacity(0.22), lineWidth: 0.5)
        )
    }
}
