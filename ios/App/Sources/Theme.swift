import SwiftUI
import UIKit

/// The palette: a dark room, one warm light.
enum Lc {
    static let ink = Color(hex: 0x09090B)
    static let night = Color(hex: 0x0E0E11)
    static let surface = Color(hex: 0x16161A)
    static let raised = Color(hex: 0x1E1E23)
    static let hairline = Color.white.opacity(0.08)
    static let hairline2 = Color.white.opacity(0.14)
    static let text = Color(hex: 0xF4F4F6)
    static let text2 = Color(hex: 0xA3A3AD)
    static let text3 = Color(hex: 0x6C6C77)
    static let amber = Color(hex: 0xF2B544)
    static let amberDeep = Color(hex: 0xD9932B)
    static let amberGlow = Color(hex: 0xF2B544).opacity(0.2)
    static let live = Color(hex: 0x3DDC84)
    static let warn = Color(hex: 0xFFB020)
    static let danger = Color(hex: 0xFF5A5F)

    static let amberGradient = LinearGradient(colors: [Color(hex: 0xF7C35E), amber, amberDeep], startPoint: .top, endPoint: .bottom)
    static let glass = LinearGradient(colors: [Color(hex: 0x1C1C21).opacity(0.85), Color(hex: 0x131316).opacity(0.9)], startPoint: .top, endPoint: .bottom)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Inter, as the Android app has it.
enum Typo {
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium: name = "Inter-Medium"
        case .semibold: name = "Inter-SemiBold"
        case .bold, .heavy, .black: name = "Inter-Bold"
        default: name = "Inter-Regular"
        }
        return Font.custom(name, size: size)
    }

    static let display = Font.custom("InterDisplay-SemiBold", size: 40)
    static let title = Font.custom("InterDisplay-SemiBold", size: 24)
    static let headline = inter(17, .semibold)
    static let body = inter(15)
    static let label = inter(14, .medium)
    static let caption = inter(12, .medium)
    static let overline = inter(11, .semibold)
    /// Numbers that change under the finger: tabular, so they don't jitter.
    static let value = inter(14, .medium).monospacedDigit()
}

/// The app's motion: soft springs, nothing linear.
enum Motion {
    static let soft = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let bouncy = Animation.spring(response: 0.38, dampingFraction: 0.62)
}

enum Haptics {
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func confirm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

extension Text {
    /// Small caps-like section titles.
    func overline() -> Text {
        self.font(Typo.overline).tracking(1.2).foregroundColor(Lc.text3)
    }
}
