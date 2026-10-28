import SwiftUI
import UIKit

/// The palette: a graphite workroom (Capture One's), white for what is selected, one restrained
/// amber for what is active.
enum Lc {
    static let window = Color(hex: 0x161618)
    static let viewer = Color(hex: 0x111112)
    static let panel = Color(hex: 0x1E1E20)
    static let header = Color(hex: 0x252528)
    static let raised = Color(hex: 0x2F2F33)
    static let pressed = Color(hex: 0x3A3A3F)
    static let field = Color(hex: 0x141416)
    static let line = Color.black.opacity(0.6)
    static let hairline = Color.white.opacity(0.07)
    static let hairline2 = Color.white.opacity(0.13)
    static let text = Color(hex: 0xE4E4E7)
    static let text2 = Color(hex: 0xA4A4AA)
    static let text3 = Color(hex: 0x6C6C73)
    static let accent = Color(hex: 0xE8A33D)
    static let select = Color(hex: 0xD6D6DA)
    static let live = Color(hex: 0x3FCF7E)
    static let warn = Color(hex: 0xF0A92E)
    static let danger = Color(hex: 0xF2555A)
    static let star = Color(hex: 0xF2C14E)
}

/// The same palette for the UIKit controls.
enum Ux {
    static let panel = UIColor(hex: 0x1E1E20)
    static let field = UIColor(hex: 0x141416)
    static let track = UIColor(white: 1, alpha: 0.16)
    static let fill = UIColor(white: 1, alpha: 0.42)
    static let knob = UIColor(hex: 0xDADADE)
    static let text = UIColor(hex: 0xE4E4E7)
    static let text2 = UIColor(hex: 0xA4A4AA)
    static let text3 = UIColor(hex: 0x6C6C73)
    static let accent = UIColor(hex: 0xE8A33D)
    static let hairline = UIColor(white: 1, alpha: 0.08)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// `#rrggbb` as the engine writes slider tracks.
    convenience init?(css: String) {
        let s = css.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

/// The system's own type (San Francisco), small and dense like a desktop raw developer.
enum Typo {
    static let display = Font.system(size: 30, weight: .semibold)
    static let title = Font.system(size: 16, weight: .semibold)
    static let toolTitle = Font.system(size: 13, weight: .semibold)
    static let group = Font.system(size: 11, weight: .semibold)
    static let body = Font.system(size: 14)
    static let label = Font.system(size: 13)
    static let labelStrong = Font.system(size: 13, weight: .medium)
    static let value = Font.system(size: 12.5).monospacedDigit()
    static let caption = Font.system(size: 11)
    static let micro = Font.system(size: 10, weight: .medium)
}

/// UIKit fonts for the same roles.
enum UTypo {
    static let label = UIFont.systemFont(ofSize: 13)
    static let value = UIFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
    static let caption = UIFont.systemFont(ofSize: 11)
}

/// Motion: quick and damped, a tool's not a toy.
enum Motion {
    static let quick = Animation.easeOut(duration: 0.16)
    static let panel = Animation.spring(response: 0.28, dampingFraction: 0.94)
}

enum Haptics {
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func confirm() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

extension Text {
    /// A group or section title.
    func overline() -> Text {
        self.font(Typo.group).tracking(0.8).foregroundColor(Lc.text3)
    }
}

/// The colour tags (Capture One's five).
enum ColorTag: String, CaseIterable, Identifiable {
    case red, yellow, green, blue, purple
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .red: return Color(hex: 0xE5484D)
        case .yellow: return Color(hex: 0xF2D14A)
        case .green: return Color(hex: 0x46B85A)
        case .blue: return Color(hex: 0x3E7BE6)
        case .purple: return Color(hex: 0x9B5CE6)
        }
    }
    var label: String {
        switch self {
        case .red: return "Rosso"
        case .yellow: return "Giallo"
        case .green: return "Verde"
        case .blue: return "Blu"
        case .purple: return "Viola"
        }
    }
}
