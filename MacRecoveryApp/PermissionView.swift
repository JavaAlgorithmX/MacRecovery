import SwiftUI

// MARK: - PermissionView
// Shown when Full Disk Access has not been granted.
// Guides the user to System Settings and re-checks automatically when
// they return to the app.

struct PermissionView: View {
    @EnvironmentObject var vm: ScanViewModel

    // Pulse animation for the lock icon
    @State private var pulse = false

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()

            VStack(spacing: 0) {

                Spacer()

                // MARK: Icon cluster
                ZStack {
                    // Glowing ring
                    Circle()
                        .fill(Color.mrAmber.opacity(0.12))
                        .frame(width: 110, height: 110)
                        .scaleEffect(pulse ? 1.08 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                            value: pulse
                        )

                    Circle()
                        .fill(Color.mrAmber.opacity(0.06))
                        .frame(width: 140, height: 140)
                        .scaleEffect(pulse ? 1.06 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.8).delay(0.2).repeatForever(autoreverses: true),
                            value: pulse
                        )

                    // Lock icon
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.mrAmber, Color(red: 1.0, green: 0.50, blue: 0.10)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 160, height: 160)
                .padding(.bottom, 28)

                // MARK: Title
                Text("Full Disk Access Required")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 10)

                // MARK: Body
                Text("MacRecovery reads raw disk sectors to recover deleted files.\nmacOS requires Full Disk Access to allow this.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                    .padding(.bottom, 32)

                // MARK: Steps card
                VStack(alignment: .leading, spacing: 14) {
                    PermissionStep(
                        number: "1",
                        text: "Open **System Settings → Privacy & Security → Full Disk Access**"
                    )
                    PermissionStep(
                        number: "2",
                        text: "Click the **+** button and add **MacRecovery** (or **Terminal** if running via CLI)"
                    )
                    PermissionStep(
                        number: "3",
                        text: "Toggle it **on**, then return here and click **Check Again**"
                    )
                }
                .padding(20)
                .background(Color.mrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.mrBorder, lineWidth: 0.5)
                )
                .frame(maxWidth: 440)
                .padding(.bottom, 28)

                // MARK: Buttons
                HStack(spacing: 12) {
                    // Open System Settings — deep-links straight to Full Disk Access
                    Button(action: openPrivacySettings) {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.fill")
                            Text("Open System Settings")
                        }
                        .frame(width: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mrAmber)
                    .controlSize(.large)

                    // Re-check without restarting the app
                    Button(action: vm.checkPermission) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Check Again")
                        }
                        .frame(width: 140)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Spacer()

                // MARK: Footer note
                Text("Tip: you can also open a disk image (.dmg / .img) without Full Disk Access — use the sidebar option on the next screen.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 60)
        }
        .onAppear { pulse = true }
        // Re-check automatically when user switches back to the app
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in vm.checkPermission() }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - PermissionStep

private struct PermissionStep: View {
    let number: String
    let text:   LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Numbered circle
            ZStack {
                Circle()
                    .fill(Color.mrAmber.opacity(0.18))
                    .frame(width: 24, height: 24)
                Text(number)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.mrAmber)
            }

            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
