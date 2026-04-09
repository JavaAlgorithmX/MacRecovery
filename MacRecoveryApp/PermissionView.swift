import SwiftUI

// MARK: - PermissionView

struct PermissionView: View {
    @EnvironmentObject var vm: ScanViewModel

    @State private var pulse         = false
    @State private var needsRestart  = false
    @State private var isChecking    = false
    @State private var lastAutoCheck = Date.distantPast

    // The exact binary path shown to user and used for relaunch
    private var executablePath: String {
        Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
    }

    // True when running from an Xcode DerivedData / Debug build.
    // FDA grants don't persist across rebuilds in this case.
    private var isDevBuild: Bool {
        executablePath.contains("DerivedData") || executablePath.contains("/Debug/")
    }

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // MARK: Icon
                ZStack {
                    Circle()
                        .fill(Color.mrAmber.opacity(0.12))
                        .frame(width: 110, height: 110)
                        .scaleEffect(pulse ? 1.08 : 1.0)
                        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)

                    Circle()
                        .fill(Color.mrAmber.opacity(0.06))
                        .frame(width: 140, height: 140)
                        .scaleEffect(pulse ? 1.06 : 1.0)
                        .animation(.easeInOut(duration: 1.8).delay(0.2).repeatForever(autoreverses: true), value: pulse)

                    Image(systemName: isDevBuild ? "hammer.fill" : "lock.shield.fill")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: isDevBuild
                                    ? [Color(red: 0.35, green: 0.65, blue: 1.0), Color.mrTeal]
                                    : [Color.mrAmber, Color(red: 1.0, green: 0.50, blue: 0.10)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
                .frame(width: 160, height: 160)
                .padding(.bottom, 28)

                if isDevBuild {
                    devBuildContent
                } else {
                    productionContent
                }

                Spacer()

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
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            guard !isDevBuild, !needsRestart, !isChecking else { return }
            let now = Date()
            guard now.timeIntervalSince(lastAutoCheck) > 2.0 else { return }
            lastAutoCheck = now
            log(AppLog.permission, "app became active — auto re-checking FDA")
            _ = vm.checkPermission()
        }
    }

    // MARK: - Dev build UI (Xcode / DerivedData)

    private var devBuildContent: some View {
        VStack(spacing: 0) {
            Text("Development Build Detected")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)

            Text("FDA grants don't persist for Xcode debug builds because the binary changes on every rebuild. You have two options:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.bottom, 24)

            // Options card
            VStack(alignment: .leading, spacing: 16) {
                // Option A — sudo CLI
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(Color.mrTeal.opacity(0.15)).frame(width: 28, height: 28)
                        Text("A").font(.system(size: 12, weight: .bold)).foregroundStyle(.mrTeal)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use the CLI with sudo (recommended for testing)")
                            .font(.subheadline.weight(.semibold))
                        Text("sudo .build/release/recoverycli scan /dev/disk6s1 --mode quick --output /tmp/results")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.mrTeal)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.mrTeal.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }

                Divider()

                // Option B — bypass for dev
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(Color.mrAmber.opacity(0.15)).frame(width: 28, height: 28)
                        Text("B").font(.system(size: 12, weight: .bold)).foregroundStyle(.mrAmber)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Continue in the UI (raw scans will fail, image files work)")
                            .font(.subheadline.weight(.semibold))
                        Text("Skip the permission check for this session. Use a .dmg or .img file instead of a raw disk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .background(Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mrBorder, lineWidth: 0.5))
            .frame(maxWidth: 480)
            .padding(.bottom, 24)

            // Buttons
            HStack(spacing: 12) {
                Button(action: openPrivacySettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.fill")
                        Text("Open System Settings")
                    }
                    .frame(width: 190)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: bypassForDev) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Continue Anyway")
                    }
                    .frame(width: 170)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.35, green: 0.65, blue: 1.0))
                .controlSize(.large)
            }
        }
    }

    // MARK: - Production build UI

    private var productionContent: some View {
        VStack(spacing: 0) {
            Text("Full Disk Access Required")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)

            Text("MacRecovery reads raw disk sectors to recover deleted files.\nmacOS requires Full Disk Access to allow this.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
                .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 14) {
                PermissionStep(number: "1",
                    text: "Open **System Settings → Privacy & Security → Full Disk Access**")
                PermissionStep(number: "2",
                    text: "Click **+** and navigate to this exact binary:")
                Text(executablePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.mrTeal)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.mrTeal.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 36)
                PermissionStep(number: "3",
                    text: "Toggle it **on**, then return here and click **Check Again**")
            }
            .padding(20)
            .background(Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mrBorder, lineWidth: 0.5))
            .frame(maxWidth: 440)
            .padding(.bottom, needsRestart ? 16 : 28)

            if needsRestart {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(Color.mrAmber)
                    Text("macOS requires MacRecovery to **restart** before the new permission takes effect.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.mrAmber.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.mrAmber.opacity(0.25), lineWidth: 1))
                .frame(maxWidth: 440)
                .padding(.bottom, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 12) {
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

                if needsRestart {
                    Button(action: relaunchApp) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Relaunch App")
                        }
                        .frame(width: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.35, green: 0.65, blue: 1.0))
                    .controlSize(.large)
                    .transition(.opacity)
                } else {
                    Button(action: checkAgain) {
                        HStack(spacing: 6) {
                            if isChecking {
                                ProgressView().scaleEffect(0.7).tint(.primary)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isChecking ? "Checking…" : "Check Again")
                        }
                        .frame(width: 140)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isChecking)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: needsRestart)
        }
    }

    // MARK: - Actions

    private func bypassForDev() {
        log(AppLog.permission, "⚠️ Dev build — bypassing FDA check for this session. Raw disk scans will fail; use image files or the CLI with sudo.", level: "WARN")
        vm.hasFullDiskAccess = true
    }

    private func checkAgain() {
        isChecking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let granted = vm.checkPermission()
            isChecking = false
            if !granted { withAnimation { needsRestart = true } }
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func relaunchApp() {
        let path = executablePath
        log(AppLog.permission, "relaunchApp() — relaunching: \(path)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = []
        do {
            try task.run()
            log(AppLog.permission, "relaunch process spawned — terminating current instance")
            NSApp.terminate(nil)
        } catch {
            log(AppLog.permission, "❌ relaunchApp failed: \(error.localizedDescription)", level: "ERROR")
        }
    }
}

// MARK: - PermissionStep

private struct PermissionStep: View {
    let number: String
    let text:   LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.mrAmber.opacity(0.18)).frame(width: 24, height: 24)
                Text(number).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.mrAmber)
            }
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}
