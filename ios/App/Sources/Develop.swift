import SwiftUI

/// How a slider's track is drawn.
enum Track {
    case plain
    case centered
    case gradient([Color])
}

/// One of LightCraft's develop controls (its id, as `develop.set` takes it).
struct Control {
    let id: String
    let label: String
    let min: Double
    let max: Double
    let def: Double
    let step: Double
    let decimals: Int
    let track: Track

    var centered: Bool { min < 0 && max > 0 }

    func format(_ v: Double) -> String {
        if id == "wb.temp" { return "\(Int(v.rounded())) K" }
        let s = decimals > 0 ? String(format: "%.\(decimals)f", v) : "\(Int(v.rounded()))"
        return centered && v > 0 && Double(s) != 0 ? "+" + s : s
    }

    func snap(_ v: Double) -> Double {
        let s = step > 0 ? ((v - min) / step).rounded() * step + min : v
        return Swift.min(max, Swift.max(min, s))
    }
}

/// The HSL bands.
enum Band: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: String { rawValue }
    var label: String {
        ["red": "Rossi", "orange": "Arancioni", "yellow": "Gialli", "green": "Verdi", "aqua": "Acqua", "blue": "Blu", "purple": "Viola", "magenta": "Magenta"][rawValue] ?? rawValue
    }
    var color: Color {
        switch self {
        case .red: return Color(hex: 0xE5484D)
        case .orange: return Color(hex: 0xF08A3C)
        case .yellow: return Color(hex: 0xF2D14A)
        case .green: return Color(hex: 0x46B85A)
        case .aqua: return Color(hex: 0x3FC6C6)
        case .blue: return Color(hex: 0x3E7BE6)
        case .purple: return Color(hex: 0x8B5CE6)
        case .magenta: return Color(hex: 0xD94FB0)
        }
    }
}

/// The Color Grading wheels.
enum Zone: String, CaseIterable, Identifiable {
    case shadows, midtones, highlights, global
    var id: String { rawValue }
    var label: String { ["shadows": "Ombre", "midtones": "Mezzitoni", "highlights": "Luci", "global": "Globale"][rawValue] ?? rawValue }
}

/// A point curve channel.
enum Channel: String, CaseIterable, Identifiable {
    case master, red, green, blue
    var id: String { rawValue }
    var label: String { self == .master ? "RGB" : String(rawValue.prefix(1)).uppercased() }
    var color: Color {
        switch self {
        case .master: return Color(hex: 0xEDEDED)
        case .red: return Color(hex: 0xE5484D)
        case .green: return Color(hex: 0x46B85A)
        case .blue: return Color(hex: 0x3E7BE6)
        }
    }
}

typealias CurvePoints = [CGPoint]

/// A curve's points (0…1) from `develop.get` (none: the straight line).
func curvePoints(_ develop: [String: Any], _ ch: Channel) -> CurvePoints {
    let a = (develop["curve"] as? [String: Any])?[ch.rawValue] as? [Any] ?? []
    var pts: [CGPoint] = a.compactMap { p in
        if let o = p as? [String: Any] { return CGPoint(x: double(o["x"]), y: double(o["y"])) }
        if let l = p as? [Any], l.count >= 2 { return CGPoint(x: double(l[0]), y: double(l[1])) }
        return nil
    }
    pts.sort { $0.x < $1.x }
    return pts.count < 2 ? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)] : pts
}

/// The curve through `pts` at `x`: monotone cubic (no overshoot).
func curveAt(_ pts: CurvePoints, _ x: CGFloat) -> CGFloat {
    guard pts.count >= 2 else { return x }
    if x <= pts[0].x { return pts[0].y }
    if x >= pts[pts.count - 1].x { return pts[pts.count - 1].y }
    let n = pts.count
    var dx = [CGFloat](repeating: 0, count: n - 1)
    var m = [CGFloat](repeating: 0, count: n - 1)
    for i in 0..<(n - 1) {
        dx[i] = pts[i + 1].x - pts[i].x
        m[i] = (pts[i + 1].y - pts[i].y) / Swift.max(dx[i], 1e-6)
    }
    var t = [CGFloat](repeating: 0, count: n)
    t[0] = m[0]
    t[n - 1] = m[n - 2]
    if n > 2 {
        for i in 1..<(n - 1) { t[i] = m[i - 1] * m[i] <= 0 ? 0 : 2 / (1 / m[i - 1] + 1 / m[i]) }
    }
    var i = 0
    while i < n - 2 && x > pts[i + 1].x { i += 1 }
    let h = dx[i]
    let s = (x - pts[i].x) / h
    let h00 = 2 * s * s * s - 3 * s * s + 1
    let h10 = s * s * s - 2 * s * s + s
    let h01 = -2 * s * s * s + 3 * s * s
    let h11 = s * s * s - s * s
    return h00 * pts[i].y + h10 * h * t[i] + h01 * pts[i + 1].y + h11 * h * t[i + 1]
}

/// A preset of LightCraft's (`presets.list`).
struct Preset: Identifiable, Equatable {
    let id: String
    let name: String
    let group: String
    let builtin: Bool
}

func groupLabel(_ g: String) -> String {
    [
        "Color": "Colore", "Film": "Pellicola", "B&W": "B&N", "Landscape": "Paesaggio", "Portrait": "Ritratto",
        "Seasons": "Stagioni", "Style": "Stile", "Urban": "Città", "Food": "Cibo", "Vintage": "Vintage", "User Presets": "I miei preset",
    ][g] ?? g
}

enum Controls {
    private static let rainbow: [Color] = [0xFF4D4D, 0xFFB34D, 0xFFFF4D, 0x4DFF4D, 0x4DFFFF, 0x4D4DFF, 0xFF4DFF, 0xFF4D4D].map { Color(hex: $0) }

    /// Every control the app shows, with its Italian name and look; ranges come from the engine.
    private static let local: [String: (String, Track)] = {
        var m: [String: (String, Track)] = [:]
        func c(_ id: String, _ label: String, _ track: Track = .centered) { m[id] = (label, track) }
        c("light.exposure", "Esposizione")
        c("light.contrast", "Contrasto")
        c("light.highlights", "Luci")
        c("light.shadows", "Ombre")
        c("light.whites", "Bianchi")
        c("light.blacks", "Neri")
        c("wb.temp", "Temperatura", .gradient([Color(hex: 0x3B6FD8), Color(hex: 0xDADADA), Color(hex: 0xE8B83A)]))
        c("wb.tint", "Tinta", .gradient([Color(hex: 0x3FAE5A), Color(hex: 0xDADADA), Color(hex: 0xD94FB0)]))
        c("color.vibrance", "Vividezza", .gradient([Color(hex: 0x7A7A7A), Color(hex: 0xD8406A)]))
        c("color.saturation", "Saturazione", .gradient([Color(hex: 0x7A7A7A), Color(hex: 0xE04A3A)]))
        c("effects.texture", "Texture")
        c("effects.clarity", "Chiarezza")
        c("effects.dehaze", "Rimuovi foschia")
        c("vignette.amount", "Vignettatura")
        c("vignette.midpoint", "Punto medio", .plain)
        c("vignette.roundness", "Rotondità")
        c("vignette.feather", "Sfumatura", .plain)
        c("grain.amount", "Grana", .plain)
        c("grain.size", "Dimensione", .plain)
        c("grain.roughness", "Ruvidezza", .plain)
        c("detail.sharpenAmount", "Nitidezza", .plain)
        c("detail.sharpenRadius", "Raggio", .plain)
        c("detail.sharpenDetail", "Dettaglio", .plain)
        c("detail.sharpenMasking", "Mascheratura", .plain)
        c("detail.nrLuminance", "Riduzione rumore", .plain)
        c("detail.nrDetail", "Dettaglio", .plain)
        c("detail.nrContrast", "Contrasto", .plain)
        c("detail.nrColor", "Rumore colore", .plain)
        c("detail.nrColorDetail", "Dettaglio", .plain)
        c("detail.nrColorSmoothness", "Uniformità", .plain)
        c("curve.highlights", "Luci")
        c("curve.lights", "Chiari")
        c("curve.darks", "Scuri")
        c("curve.shadows", "Ombre")
        for b in Band.allCases {
            c("mixer.\(b.rawValue).hue", "Tonalità", .gradient([b.color.opacity(0.6), b.color, b.color.opacity(0.6)]))
            c("mixer.\(b.rawValue).sat", "Saturazione", .gradient([Color(hex: 0x808080), b.color]))
            c("mixer.\(b.rawValue).lum", "Luminanza", .gradient([Color(hex: 0x151515), b.color, Color(hex: 0xF5F5F5)]))
        }
        for z in Zone.allCases {
            c("grading.\(z.rawValue).hue", "Tonalità", .gradient(rainbow))
            c("grading.\(z.rawValue).sat", "Saturazione", .plain)
            c("grading.\(z.rawValue).lum", "Luminanza", .gradient([Color(hex: 0x151515), Color(hex: 0xF5F5F5)]))
        }
        c("grading.blending", "Fusione", .plain)
        c("grading.balance", "Bilanciamento")
        return m
    }()

    static let light = ["light.exposure", "light.contrast", "light.highlights", "light.shadows", "light.whites", "light.blacks"]
    static let effects = ["effects.texture", "effects.clarity", "effects.dehaze"]
    static let vignette = ["vignette.amount", "vignette.midpoint", "vignette.roundness", "vignette.feather"]
    static let grain = ["grain.amount", "grain.size", "grain.roughness"]
    static let sharpen = ["detail.sharpenAmount", "detail.sharpenRadius", "detail.sharpenDetail", "detail.sharpenMasking"]
    static let noise = ["detail.nrLuminance", "detail.nrDetail", "detail.nrContrast"]
    static let colorNoise = ["detail.nrColor", "detail.nrColorDetail", "detail.nrColorSmoothness"]
    static let parametric = ["curve.highlights", "curve.lights", "curve.darks", "curve.shadows"]

    /// The controls from `develop.controls`, named and drawn the app's way.
    static func from(_ engine: [[String: Any]]) -> [String: Control] {
        var out: [String: Control] = [:]
        for o in engine {
            let id = o.str("id")
            guard let entry = local[id] else { continue }
            let (label, track) = entry
            out[id] = Control(
                id: id, label: label, min: double(o["min"]), max: double(o["max"]), def: double(o["default"]),
                step: (o["step"] as? NSNumber)?.doubleValue ?? 1, decimals: Int(int64(o["decimals"])), track: track
            )
        }
        return out
    }

    static func values(_ engine: [[String: Any]]) -> [String: Double] {
        var out: [String: Double] = [:]
        for o in engine { out[o.str("id")] = double(o["value"]) }
        return out
    }
}
