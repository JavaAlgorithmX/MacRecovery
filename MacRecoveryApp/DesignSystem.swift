import SwiftUI
import RecoveryCore

// MARK: - Brand colours
// Defined on both Color (for explicit use) and ShapeStyle where Self == Color
// so that .mrTeal etc. resolve correctly in foregroundStyle / tint contexts.

extension Color {
    /// Cyan-teal primary accent
    static let mrTeal    = Color(red: 0.00, green: 0.71, blue: 0.85)
    /// Mint green — success / .certain
    static let mrMint    = Color(red: 0.16, green: 0.84, blue: 0.64)
    /// Amber — warning / .medium
    static let mrAmber   = Color(red: 1.00, green: 0.72, blue: 0.08)
    /// Rose — danger / .low
    static let mrRose    = Color(red: 0.94, green: 0.27, blue: 0.44)
    /// Subtle card fill
    static let mrSurface = Color.primary.opacity(0.045)
    /// Hairline border
    static let mrBorder  = Color.primary.opacity(0.09)
}

extension ShapeStyle where Self == Color {
    static var mrTeal:    Color { Color(red: 0.00, green: 0.71, blue: 0.85) }
    static var mrMint:    Color { Color(red: 0.16, green: 0.84, blue: 0.64) }
    static var mrAmber:   Color { Color(red: 1.00, green: 0.72, blue: 0.08) }
    static var mrRose:    Color { Color(red: 0.94, green: 0.27, blue: 0.44) }
    static var mrSurface: Color { Color.primary.opacity(0.045) }
    static var mrBorder:  Color { Color.primary.opacity(0.09) }
}

// MARK: - RecoverabilityScore

extension RecoverabilityScore {
    var tintColor: Color {
        switch self {
        case .certain: return .mrMint
        case .high:    return .green
        case .medium:  return .mrAmber
        case .low:     return .mrRose
        }
    }
    var badgeIcon: String {
        switch self {
        case .certain: return "checkmark.seal.fill"
        case .high:    return "checkmark.circle.fill"
        case .medium:  return "exclamationmark.circle.fill"
        case .low:     return "xmark.circle.fill"
        }
    }
    var description: String {
        switch self {
        case .certain: return "Recovered from inode — original record intact"
        case .high:    return "Header + body + footer found in sequence"
        case .medium:  return "Intact header and body; may be truncated"
        case .low:     return "Signature found only; possibly fragmented"
        }
    }
}

// MARK: - FileCategory

extension FileCategory {
    var tintColor: Color {
        switch self {
        case .pictures:  return .mrTeal
        case .videos:    return Color(red: 0.58, green: 0.28, blue: 0.92)
        case .audio:     return Color(red: 0.90, green: 0.38, blue: 0.70)
        case .documents: return .mrAmber
        case .archives:  return Color(red: 0.35, green: 0.80, blue: 0.45)
        case .databases: return Color(red: 0.38, green: 0.62, blue: 1.00)
        case .others:    return Color.secondary
        }
    }
}

// MARK: - RecoveredFileType

extension RecoveredFileType {
    var sfSymbol: String {
        switch self {
        case .jpeg, .png, .gif, .tiff, .bmp, .heic, .webp, .raw:
            return "photo"
        case .mp4, .mov:
            return "film"
        case .avi, .mkv:
            return "play.rectangle"
        case .mp3, .aac, .flac, .wav, .aiff:
            return "waveform"
        case .pdf:
            return "doc.richtext"
        case .docx:
            return "doc.text"
        case .xlsx:
            return "tablecells"
        case .pptx:
            return "rectangle.on.rectangle"
        case .zip:
            return "archivebox"
        case .sqlite:
            return "cylinder.split.1x2"
        case .plist:
            return "list.bullet.rectangle"
        case .unknown:
            return "questionmark.square.dashed"
        }
    }
}

// MARK: - ScanCapability

extension ScanCapability {
    var badgeIcon: String {
        switch self {
        case .quickAndDeep:    return "bolt.fill"
        case .deepOnly:        return "archivebox.fill"
        case .lockedEncrypted: return "lock.fill"
        }
    }
    var tintColor: Color {
        switch self {
        case .quickAndDeep:    return .mrMint
        case .deepOnly:        return .mrAmber
        case .lockedEncrypted: return .mrRose
        }
    }
    var badgeLabel: String {
        switch self {
        case .quickAndDeep:    return "Quick+Deep"
        case .deepOnly:        return "Deep Only"
        case .lockedEncrypted: return "Locked"
        }
    }
}

// MARK: - Byte formatting

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// MARK: - Card surface

struct CardModifier: ViewModifier {
    var selected: Bool = false

    func body(content: Content) -> some View {
        content
            .background(selected ? Color.mrTeal.opacity(0.08) : Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        selected ? Color.mrTeal.opacity(0.55) : Color.mrBorder,
                        lineWidth: selected ? 1.5 : 0.5
                    )
            )
    }
}

extension View {
    func cardStyle(selected: Bool = false) -> some View {
        modifier(CardModifier(selected: selected))
    }
}

// MARK: - macOS visual-effect background

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .windowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material     = material
        v.blendingMode = blendingMode
    }
}
