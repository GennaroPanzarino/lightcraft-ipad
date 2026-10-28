import CoreGraphics
import Foundation
import UIKit

/// The photo's crop as LightCraft keeps it: the image (after its orientation) turned by `angle`
/// about its centre, and an axis-aligned rectangle in that turned frame, normalized to the image's
/// size. Masks and spots live in the image's own frame (uncropped, unturned): `toImage` and `toView`
/// go between that and a point of the cropped photo as the viewer shows it.
struct CropState: Equatable {
    /// x0, y0, width, height in the turned frame (0…1 of the image when the angle is 0).
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Degrees, clockwise.
    var angle: Double = 0
    /// The uncropped image's width / height.
    var aspect: CGFloat = 1.5

    var isIdentity: Bool { abs(angle) < 0.001 && rect == CGRect(x: 0, y: 0, width: 1, height: 1) }

    /// A point of the cropped picture (0…1 each way) → the image's own coordinates (0…1).
    func toImage(_ u: CGPoint) -> CGPoint {
        let fx = rect.minX + u.x * rect.width
        let fy = rect.minY + u.y * rect.height
        let x = fx * aspect - aspect / 2, y = fy - 0.5
        let t = -angle * .pi / 180
        let ix = x * CGFloat(cos(t)) - y * CGFloat(sin(t)) + aspect / 2
        let iy = x * CGFloat(sin(t)) + y * CGFloat(cos(t)) + 0.5
        return CGPoint(x: ix / aspect, y: iy)
    }

    /// The image's own coordinates → a point of the cropped picture (0…1 each way, outside when cut off).
    func toView(_ p: CGPoint) -> CGPoint {
        let x = p.x * aspect - aspect / 2, y = p.y - 0.5
        let t = angle * .pi / 180
        let fx = (x * CGFloat(cos(t)) - y * CGFloat(sin(t)) + aspect / 2) / aspect
        let fy = x * CGFloat(sin(t)) + y * CGFloat(cos(t)) + 0.5
        return CGPoint(x: (fx - rect.minX) / max(rect.width, 1e-6), y: (fy - rect.minY) / max(rect.height, 1e-6))
    }

    /// A length as a fraction of the image's long edge → a fraction of the cropped picture's width.
    func toViewWidth(_ fraction: CGFloat) -> CGFloat {
        let long = max(aspect, 1)
        return fraction * long / max(aspect * rect.width, 1e-6)
    }

    static func from(_ develop: [String: Any], aspect: CGFloat) -> CropState {
        var s = CropState()
        s.aspect = aspect
        let c = develop["crop"] as? [String: Any] ?? [:]
        let g = c["geometry"] as? [String: Any] ?? [:]
        if let r = g["rect"] as? [String: Any] {
            let x0 = CGFloat(double(r["x0"])), y0 = CGFloat(double(r["y0"]))
            let x1 = CGFloat(r["x1"] == nil ? 1 : double(r["x1"])), y1 = CGFloat(r["y1"] == nil ? 1 : double(r["y1"]))
            if x1 > x0 && y1 > y0 { s.rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }
        }
        s.angle = double(g["angle"])
        return s
    }
}

/// A crop proportion as the menus name it: "4x5" → 4:5 (either orientation), "original", "free".
func aspectName(_ a: String) -> String {
    switch a {
    case "", "free": return "Libero"
    case "original": return "Originale"
    default: return a.replacingOccurrences(of: "x", with: ":")
    }
}

/// One of the photo's masks (Capture One's layers), as `develop.get` lists them.
struct MaskInfo: Identifiable, Equatable {
    let id: Int
    let name: String
    let kind: String
    let visible: Bool
    let invert: Bool
    let adjust: [String: Double]
    /// The first component's shape, as JSON.
    let shape: [String: Any]

    static func == (a: MaskInfo, b: MaskInfo) -> Bool {
        a.id == b.id && a.name == b.name && a.kind == b.kind && a.visible == b.visible && a.invert == b.invert && a.adjust == b.adjust
            && NSDictionary(dictionary: a.shape).isEqual(to: b.shape)
    }

    var label: String {
        switch kind {
        case "brush": return "Pennello"
        case "linear": return "Gradiente lineare"
        case "radial": return "Gradiente radiale"
        case "luminanceRange": return "Gamma luminanza"
        case "colorRange": return "Gamma colore"
        case "sky": return "Cielo"
        case "subject": return "Soggetto"
        default: return kind
        }
    }

    var icon: String {
        switch kind {
        case "brush": return "paintbrush.pointed"
        case "linear": return "square.split.diagonal"
        case "radial": return "circle.dashed"
        case "luminanceRange": return "sun.max"
        case "colorRange": return "eyedropper"
        default: return "square.on.square"
        }
    }

    static func list(_ develop: [String: Any]) -> [MaskInfo] {
        (develop["masks"] as? [[String: Any]] ?? []).map { m in
            let comps = m["components"] as? [[String: Any]] ?? []
            let shape = comps.first?["shape"] as? [String: Any] ?? [:]
            var adjust: [String: Double] = [:]
            for (k, v) in m["adjust"] as? [String: Any] ?? [:] { if let n = v as? NSNumber { adjust[k] = n.doubleValue } }
            return MaskInfo(
                id: Int(int64(m["id"])), name: m.str("name"), kind: shape.str("kind"),
                visible: (m["visible"] as? Bool) ?? true, invert: (m["invert"] as? Bool) ?? false,
                adjust: adjust, shape: shape
            )
        }
    }
}

/// A spot of the Remove tool: where (image coordinates), how big (fraction of the long edge).
struct SpotInfo: Equatable {
    let center: CGPoint
    let size: CGFloat
    let mode: String

    static func list(_ develop: [String: Any]) -> [SpotInfo] {
        (develop["spots"] as? [[String: Any]] ?? []).compactMap { s in
            let pts = s["points"] as? [Any] ?? []
            guard let first = pts.first else { return nil }
            let c: CGPoint
            if let o = first as? [String: Any] { c = CGPoint(x: double(o["x"]), y: double(o["y"])) }
            else if let l = first as? [Any], l.count >= 2 { c = CGPoint(x: double(l[0]), y: double(l[1])) }
            else { return nil }
            return SpotInfo(center: c, size: CGFloat(double(s["size"])), mode: s.str("mode"))
        }
    }
}

/// The local adjustments a mask can carry (Capture One's layer sliders), as controls the sliders take.
enum LocalControls {
    static let ids = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "temp", "tint", "saturation", "clarity", "texture", "dehaze", "sharpness", "noise", "moire", "defringe"]

    static let all: [String: Control] = {
        let names = [
            "exposure": "Esposizione", "contrast": "Contrasto", "highlights": "Alteluci", "shadows": "Ombre", "whites": "Bianco",
            "blacks": "Nero", "temp": "Temperatura", "tint": "Tinta", "saturation": "Saturazione", "clarity": "Chiarezza",
            "texture": "Struttura", "dehaze": "Dehaze", "sharpness": "Nitidezza", "noise": "Rumore", "moire": "Moiré", "defringe": "Frange",
        ]
        var m: [String: Control] = [:]
        for id in ids {
            let exp = id == "exposure"
            let track: Track
            switch id {
            case "temp": track = .gradient([UIColor(hex: 0x3B6FD8), UIColor(hex: 0xD8D8D8), UIColor(hex: 0xE8B83A)])
            case "tint": track = .gradient([UIColor(hex: 0x3FAE5A), UIColor(hex: 0xD8D8D8), UIColor(hex: 0xD94FB0)])
            default: track = .centered
            }
            m["local.\(id)"] = Control(id: "local.\(id)", label: names[id] ?? id, min: exp ? -4 : -100, max: exp ? 4 : 100, def: 0, step: exp ? 0.01 : 1, decimals: exp ? 2 : 0, track: track)
        }
        return m
    }()
}
