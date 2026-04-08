import SwiftUI
import RecoveryCore

struct CandidateRow: View {
    let candidate:  FileCandidate
    let isQueued:   Bool        // true = selected for recovery

    var body: some View {
        HStack(spacing: 10) {

            // ── Type icon ──────────────────────────────────────────────────
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(candidate.fileType.category.tintColor.opacity(0.11))
                    .frame(width: 36, height: 36)
                Image(systemName: candidate.fileType.sfSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(candidate.fileType.category.tintColor)
            }

            // ── File info ──────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.suggestedFileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(candidate.fileType.kindLabel)
                    Text("·")
                    Text(formatBytes(candidate.estimatedSize))
                    if let date = candidate.modificationDate {
                        Text("·")
                        Text(date, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // ── Score badge ────────────────────────────────────────────────
            ScoreBadge(score: candidate.recoverability)

            // ── Recovery queue indicator ───────────────────────────────────
            Image(systemName: isQueued ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(isQueued ? Color.mrMint : Color.secondary.opacity(0.35))
                .animation(.spring(response: 0.2), value: isQueued)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
