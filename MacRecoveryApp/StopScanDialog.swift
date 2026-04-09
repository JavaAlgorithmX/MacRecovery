import SwiftUI

// MARK: - StopScanDialog
// Shown when the user taps Stop during an active scan.
// Matches UI-Plan screen 7: icon · title · stats (files / ETA) · warning · Stop + Cancel.

struct StopScanDialog: View {
    let filesScanned: Int
    let eta:          TimeInterval
    let onStop:       () -> Void
    let onCancel:     () -> Void

    var body: some View {
        VStack(spacing: 0) {

            // ── Icon ──────────────────────────────────────────────────────────
            ZStack {
                // Stacked "file" tiles — visual shorthand for "files being searched"
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.40, green: 0.70, blue: 1.00))
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(-12))
                    .offset(x: -10, y: 4)

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.55, green: 0.85, blue: 0.45))
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(6))
                    .offset(x: 8, y: 6)

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 1.00, green: 0.72, blue: 0.08))
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(-3))

                // Pause badge on top
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                    Image(systemName: "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 1.00, green: 0.72, blue: 0.08))
                }
                .offset(x: 16, y: -16)
            }
            .frame(width: 72, height: 72)
            .padding(.top, 32)
            .padding(.bottom, 20)

            // ── Title ─────────────────────────────────────────────────────────
            Text("Stop searching for lost files?")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .padding(.bottom, 20)

            // ── Stats ─────────────────────────────────────────────────────────
            HStack(spacing: 0) {
                statCell(
                    value: "\(filesScanned)",
                    label: "Files scanned"
                )
                Divider()
                    .frame(height: 44)
                statCell(
                    value: etaString(eta),
                    label: "Remaining time"
                )
            }
            .background(Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.mrBorder, lineWidth: 0.5)
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            // ── Warning ───────────────────────────────────────────────────────
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.mrRose)
                    .padding(.top, 1)
                Text("Warning: the lost data may not be found completely if you stop.")
                    .font(.caption)
                    .foregroundStyle(.mrRose)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)

            Divider()

            // ── Buttons ───────────────────────────────────────────────────────
            HStack(spacing: 12) {
                Button(action: onStop) {
                    Text("Stop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.mrRose)
                .controlSize(.large)

                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mrTeal)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .frame(width: 400)
        .background(VisualEffectBackground().ignoresSafeArea())
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .rounded).bold().monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func etaString(_ seconds: TimeInterval) -> String {
        guard seconds > 1 else { return "—" }
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        let s = Int(seconds) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.opacity(0.35).ignoresSafeArea()
        StopScanDialog(
            filesScanned: 528,
            eta:          2 * 3600 + 22 * 60 + 42,
            onStop:       {},
            onCancel:     {}
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .padding(40)
    }
}
