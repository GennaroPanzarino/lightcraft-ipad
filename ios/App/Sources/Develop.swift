import SwiftUI
import UIKit

/// How a slider's track is drawn.
enum Track {
    case plain
    case centered
    case gradient([UIColor])
}

/// One of LightCraft's develop controls (its id, as `develop.set` takes it), with the range the
/// engine gives and the name the app shows.
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
        let s = decimals > 0 ? String(format: "%.\(decimals)f", v) : "\(Int(v.rounded()))"
        let zero = Double(s) == 0
        if zero { return decimals > 0 ? String(format: "%.\(decimals)f", 0.0) : "0" }
        return centered && v > 0 ? "+" + s : s
    }

    func snap(_ v: Double) -> Double {
        let s = step > 0 ? ((v - min) / step).rounded() * step + min : v
        return Swift.min(max, Swift.max(min, s))
    }
}

/// The colour editor's bands.
enum Band: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: String { rawValue }
    var label: String {
        switch self {
        case .red: return "Rossi"
        case .orange: return "Arancioni"
        case .yellow: return "Gialli"
        case .green: return "Verdi"
        case .aqua: return "Acqua"
        case .blue: return "Blu"
        case .purple: return "Viola"
        case .magenta: return "Magenta"
        }
    }
    var hex: UInt32 {
        switch self {
        case .red: return 0xE5484D
        case .orange: return 0xF08A3C
        case .yellow: return 0xF2D14A
        case .green: return 0x46B85A
        case .aqua: return 0x3FC6C6
        case .blue: return 0x3E7BE6
        case .purple: return 0x8B5CE6
        case .magenta: return 0xD94FB0
        }
    }
    var color: Color { Color(hex: hex) }
    var ui: UIColor { UIColor(hex: hex) }
}

/// The colour balance zones.
enum Zone: String, CaseIterable, Identifiable {
    case shadows, midtones, highlights, global
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shadows: return "Ombre"
        case .midtones: return "Mezzitoni"
        case .highlights: return "Alteluci"
        case .global: return "Master"
        }
    }
}

/// A point curve channel.
enum Channel: String, CaseIterable, Identifiable {
    case master, red, green, blue
    var id: String { rawValue }
    var label: String {
        switch self {
        case .master: return "RGB"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        }
    }
    var ui: UIColor {
        switch self {
        case .master: return UIColor(hex: 0xE6E6E9)
        case .red: return UIColor(hex: 0xE5484D)
        case .green: return UIColor(hex: 0x46B85A)
        case .blue: return UIColor(hex: 0x3E7BE6)
        }
    }
}

typealias CurvePoints = [CGPoint]

/// A curve's points (0…1) from `develop.get` (none: the straight line).
func curvePoints(_ develop: [String: Any], _ ch: Channel) -> CurvePoints {
    let a = (develop["curve"] as? [String: Any])?[ch.rawValue] as? [Any] ?? []
    var pts: [CGPoint] = a.compactMap { p -> CGPoint? in
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

/// A preset (a Capture One style) of LightCraft's (`presets.list`).
struct Preset: Identifiable, Equatable {
    let id: String
    let name: String
    let group: String
    let builtin: Bool
}

/// A camera profile (`profiles.list`): Capture One's base characteristics.
struct Profile: Identifiable, Equatable {
    let id: String
    let name: String
    let group: String
}

func groupLabel(_ g: String) -> String {
    let names = [
        "Color": "Colore", "Film": "Pellicola", "B&W": "Bianco e nero", "Landscape": "Paesaggio", "Portrait": "Ritratto",
        "Seasons": "Stagioni", "Style": "Stile", "Urban": "Città", "Food": "Cibo", "Vintage": "Vintage", "User Presets": "I miei stili",
        "Imported Presets": "Importati", "Basic": "Base", "Cinematic": "Cinema", "Muted": "Tenui",
    ]
    return names[g] ?? g
}

enum Controls {
    /// The app's names for the engine's controls (Capture One's, in Italian).
    static let names: [String: String] = {
        var m: [String: String] = [
            "light.exposure": "Esposizione", "light.contrast": "Contrasto", "light.highlights": "Alteluci",
            "light.shadows": "Ombre", "light.whites": "Bianco", "light.blacks": "Nero",
            "color.vibrance": "Vividezza", "color.saturation": "Saturazione", "wb.temp": "Kelvin", "wb.tint": "Tinta",
            "effects.texture": "Struttura", "effects.clarity": "Chiarezza", "effects.dehaze": "Quantità",
            "vignette.amount": "Quantità", "vignette.midpoint": "Punto medio", "vignette.roundness": "Rotondità",
            "vignette.feather": "Sfumatura", "vignette.highlights": "Alteluci",
            "grain.amount": "Impatto", "grain.size": "Granularità", "grain.roughness": "Ruvidezza",
            "detail.sharpenAmount": "Quantità", "detail.sharpenRadius": "Raggio", "detail.sharpenDetail": "Dettaglio",
            "detail.sharpenMasking": "Soglia", "detail.nrLuminance": "Luminanza", "detail.nrDetail": "Dettaglio",
            "detail.nrContrast": "Contrasto", "detail.nrColor": "Colore", "detail.nrColorDetail": "Dettaglio colore",
            "detail.nrColorSmoothness": "Uniformità",
            "curve.highlights": "Alteluci", "curve.lights": "Chiari", "curve.darks": "Scuri", "curve.shadows": "Ombre",
            "curve.splitShadows": "Divisione ombre", "curve.splitMid": "Divisione medi", "curve.splitHighlights": "Divisione luci",
            "curve.refineSaturation": "Saturazione",
            "optics.distortion": "Distorsione", "optics.vignetting": "Caduta di luce", "optics.vignettingMidpoint": "Punto medio",
            "optics.profileDistortion": "Distorsione", "optics.profileVignetting": "Caduta di luce",
            "optics.defringePurple": "Viola", "optics.defringePurpleHueLo": "Viola da", "optics.defringePurpleHueHi": "Viola a",
            "optics.defringeGreen": "Verde", "optics.defringeGreenHueLo": "Verde da", "optics.defringeGreenHueHi": "Verde a",
            "optics.caRed": "Rosso / ciano", "optics.caBlue": "Blu / giallo",
            "geometry.vertical": "Verticale", "geometry.horizontal": "Orizzontale", "geometry.rotate": "Rotazione",
            "geometry.aspect": "Proporzioni", "geometry.scale": "Scala", "geometry.offsetX": "Sposta X", "geometry.offsetY": "Sposta Y",
            "crop.angle": "Raddrizza",
            "calibration.shadowsTint": "Tinta ombre", "calibration.redHue": "Rosso tonalità", "calibration.redSat": "Rosso satur.",
            "calibration.greenHue": "Verde tonalità", "calibration.greenSat": "Verde satur.", "calibration.blueHue": "Blu tonalità",
            "calibration.blueSat": "Blu satur.",
            "profile.amount": "Quantità", "grading.blending": "Fusione", "grading.balance": "Bilanciamento",
        ]
        for b in Band.allCases {
            m["bw.\(b.rawValue)"] = b.label
            m["mixer.\(b.rawValue).hue"] = "Tonalità"
            m["mixer.\(b.rawValue).sat"] = "Saturazione"
            m["mixer.\(b.rawValue).lum"] = "Luminosità"
        }
        for z in Zone.allCases {
            m["grading.\(z.rawValue).hue"] = "Tonalità"
            m["grading.\(z.rawValue).sat"] = "Saturazione"
            m["grading.\(z.rawValue).lum"] = "Luminosità"
        }
        return m
    }()

    /// Tracks the app draws its own way (the engine's otherwise).
    static func track(_ id: String) -> Track? {
        let gray = UIColor(hex: 0x7A7A7A)
        if id == "wb.temp" { return .gradient([UIColor(hex: 0x3B6FD8), UIColor(hex: 0xD8D8D8), UIColor(hex: 0xE8B83A)]) }
        if id == "wb.tint" { return .gradient([UIColor(hex: 0x3FAE5A), UIColor(hex: 0xD8D8D8), UIColor(hex: 0xD94FB0)]) }
        for b in Band.allCases {
            if id == "mixer.\(b.rawValue).hue" { return .gradient([b.ui.withAlphaComponent(0.55), b.ui, b.ui.withAlphaComponent(0.55)]) }
            if id == "mixer.\(b.rawValue).sat" { return .gradient([gray, b.ui]) }
            if id == "mixer.\(b.rawValue).lum" { return .gradient([UIColor(hex: 0x151515), b.ui, UIColor(hex: 0xF5F5F5)]) }
        }
        if id.hasPrefix("grading.") && id.hasSuffix(".lum") { return .gradient([UIColor(hex: 0x151515), UIColor(hex: 0xF5F5F5)]) }
        return nil
    }

    static func engineTrack(_ t: Any?) -> Track {
        guard let o = t as? [String: Any] else { return .plain }
        switch o.str("kind") {
        case "centered": return .centered
        case "gradient":
            if let a = UIColor(css: o.str("from")), let b = UIColor(css: o.str("to")) { return .gradient([a, b]) }
            return .plain
        default: return .plain
        }
    }

    /// Every control the engine has, named and drawn the app's way.
    static func from(_ engine: [[String: Any]]) -> [String: Control] {
        var out: [String: Control] = [:]
        for o in engine {
            let id = o.str("id")
            guard !id.isEmpty else { continue }
            out[id] = Control(
                id: id, label: names[id] ?? o.str("label"), min: double(o["min"]), max: double(o["max"]), def: double(o["default"]),
                step: (o["step"] as? NSNumber)?.doubleValue ?? 1, decimals: Int(int64(o["decimals"])),
                track: track(id) ?? engineTrack(o["track"])
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

/// The photo's slider values, shared by every control that shows one: a change made on one reaches
/// the others and the engine without SwiftUI drawing anything again.
@MainActor
final class DevelopStore {
    private struct Observer {
        weak var owner: AnyObject?
        let ids: Set<String>
        let fn: (String, Double) -> Void
    }

    private(set) var controls: [String: Control] = [:]
    private(set) var values: [String: Double] = [:]
    private var observers: [Observer] = []
    /// A change by the user (a slider, a wheel): the engine gets it.
    var onChange: ((String, Double) -> Void)?
    /// A gesture starts (one undo step) and ends.
    var onBegin: ((String) -> Void)?
    var onEnd: (() -> Void)?
    /// Whether there is a photo to change.
    var enabled = false {
        didSet { if enabled != oldValue { notifyAll() } }
    }

    func setControls(_ c: [String: Control]) { controls = c }
    func control(_ id: String) -> Control? { controls[id] }
    func value(_ id: String) -> Double { values[id] ?? controls[id]?.def ?? 0 }

    func observe(_ ids: [String], owner: AnyObject, _ fn: @escaping (String, Double) -> Void) {
        observers.removeAll { $0.owner == nil || $0.owner === owner && $0.ids == Set(ids) }
        observers.append(Observer(owner: owner, ids: Set(ids), fn: fn))
        for id in ids { fn(id, value(id)) }
    }

    func forget(_ owner: AnyObject) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
    }

    /// The values as LightCraft has them (a new photo, undo, a preset).
    func load(_ v: [String: Double]) {
        values = v
        notifyAll()
    }

    /// The user changed `id` on `source`: the others showing it follow, the engine gets it.
    func userSet(_ id: String, _ v: Double, from source: AnyObject?) {
        values[id] = v
        for o in observers where o.ids.contains(id) && o.owner !== source { o.fn(id, v) }
        onChange?(id, v)
    }

    private func notifyAll() {
        observers.removeAll { $0.owner == nil }
        for o in observers {
            for id in o.ids { o.fn(id, value(id)) }
        }
    }
}
