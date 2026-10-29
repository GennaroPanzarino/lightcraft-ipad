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

/// What a mask (or one of its components) selects, as the panel names and draws it.
enum MaskKinds {
    static func label(_ kind: String) -> String {
        switch kind {
        case "brush": return "Pennello"
        case "linear": return "Gradiente lineare"
        case "radial": return "Gradiente radiale"
        case "luminanceRange": return "Gamma luminanza"
        case "colorRange": return "Gamma colore"
        case "depthRange": return "Gamma profondità"
        case "sky": return "Cielo"
        case "subject": return "Soggetto"
        case "background": return "Sfondo"
        case "people": return "Persone"
        case "object": return "Selezione"
        default: return kind
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "brush": return "paintbrush.pointed"
        case "linear": return "square.split.diagonal"
        case "radial": return "circle.dashed"
        case "luminanceRange": return "sun.max"
        case "colorRange": return "eyedropper"
        case "depthRange": return "square.3.layers.3d.down.right"
        case "sky": return "cloud.sun"
        case "subject": return "person.crop.square"
        case "background": return "photo"
        case "people": return "person.2"
        default: return "wand.and.stars"
        }
    }
}

/// One component of a mask: what it selects and how it joins the ones above it (Lightroom's Add,
/// Subtract, Intersect).
struct MaskPart: Equatable {
    let index: Int
    let name: String
    let op: String
    let invert: Bool
    let kind: String
    let shape: [String: Any]

    static func == (a: MaskPart, b: MaskPart) -> Bool {
        a.index == b.index && a.name == b.name && a.op == b.op && a.invert == b.invert && a.kind == b.kind
            && NSDictionary(dictionary: a.shape).isEqual(to: b.shape)
    }

    /// What the app made from a selection of its own (subject, sky, people, depth) is stored as a
    /// segmentation under that name.
    var shownKind: String {
        guard kind == "object" else { return kind }
        let n = name.lowercased()
        for k in ["subject", "sky", "background", "people", "depthRange"] where n.hasPrefix(MaskKinds.label(k).lowercased()) { return k }
        return kind
    }

    var label: String { name.isEmpty ? MaskKinds.label(kind) : name }
    var icon: String { MaskKinds.icon(shownKind) }
}

/// One of the photo's masks (Lightroom's), as `develop.get` lists them.
struct MaskInfo: Identifiable, Equatable {
    let id: Int
    let name: String
    let visible: Bool
    let invert: Bool
    let adjust: [String: Double]
    /// Refine Edges, 0…100.
    let refine: Double
    let parts: [MaskPart]

    /// The first component's kind and shape (what the mask is, at a glance).
    var kind: String { parts.first?.shownKind ?? "" }
    var shape: [String: Any] { parts.first?.shape ?? [:] }
    var label: String { MaskKinds.label(kind) }
    var icon: String { parts.first?.icon ?? "square.on.square" }

    /// The mask with `part`'s shape in front (the gradient handles on the photo are that one's).
    func part(_ i: Int?) -> MaskPart? {
        guard let i = i else { return parts.last }
        return parts.first { $0.index == i } ?? parts.last
    }

    static func list(_ develop: [String: Any]) -> [MaskInfo] {
        (develop["masks"] as? [[String: Any]] ?? []).map { m in
            let comps = m["components"] as? [[String: Any]] ?? []
            let parts = comps.enumerated().map { i, c -> MaskPart in
                let shape = c["shape"] as? [String: Any] ?? [:]
                return MaskPart(index: i, name: c.str("name"), op: c.str("op").isEmpty ? "add" : c.str("op"), invert: (c["invert"] as? Bool) ?? false,
                                kind: shape.str("kind"), shape: shape)
            }
            var adjust: [String: Double] = [:]
            for (k, v) in m["adjust"] as? [String: Any] ?? [:] { if let n = v as? NSNumber { adjust[k] = n.doubleValue } }
            return MaskInfo(
                id: Int(int64(m["id"])), name: m.str("name"),
                visible: (m["visible"] as? Bool) ?? true, invert: (m["invert"] as? Bool) ?? false,
                adjust: adjust, refine: double(m["refine"]), parts: parts
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

/// The local adjustments a mask can carry (Lightroom's mask sliders), as controls the sliders take.
enum LocalControls {
    static let ids = ["amount", "exposure", "contrast", "highlights", "shadows", "whites", "blacks", "temp", "tint", "hue", "saturation", "color_hue", "color_sat",
                      "clarity", "texture", "dehaze", "sharpness", "noise", "moire", "defringe"]

    /// What a slider shows before it is touched (the mask's Amount is 100 %).
    static func def(_ id: String) -> Double { id == "amount" ? 100 : 0 }

    static let all: [String: Control] = {
        let names = [
            "amount": "Quantità", "exposure": "Esposizione", "contrast": "Contrasto", "highlights": "Alteluci", "shadows": "Ombre", "whites": "Bianco",
            "blacks": "Nero", "temp": "Temperatura", "tint": "Tinta", "hue": "Tonalità", "saturation": "Saturazione", "color_hue": "Colore",
            "color_sat": "Intensità colore", "clarity": "Chiarezza", "texture": "Struttura", "dehaze": "Dehaze", "sharpness": "Nitidezza", "noise": "Rumore",
            "moire": "Moiré", "defringe": "Frange",
        ]
        var m: [String: Control] = [:]
        for id in ids {
            let c: Control
            switch id {
            case "amount":
                c = Control(id: "local.amount", label: "Quantità", min: 0, max: 200, def: 100, step: 1, decimals: 0, track: .plain)
            case "exposure":
                c = Control(id: "local.exposure", label: "Esposizione", min: -4, max: 4, def: 0, step: 0.01, decimals: 2, track: .centered)
            case "color_hue":
                let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { UIColor(hue: CGFloat($0), saturation: 0.8, brightness: 0.9, alpha: 1) }
                c = Control(id: "local.color_hue", label: "Colore", min: 0, max: 360, def: 0, step: 1, decimals: 0, track: .gradient(hues))
            case "color_sat":
                c = Control(id: "local.color_sat", label: "Intensità colore", min: 0, max: 100, def: 0, step: 1, decimals: 0, track: .plain)
            default:
                let track: Track
                switch id {
                case "temp": track = .gradient([UIColor(hex: 0x3B6FD8), UIColor(hex: 0xD8D8D8), UIColor(hex: 0xE8B83A)])
                case "tint": track = .gradient([UIColor(hex: 0x3FAE5A), UIColor(hex: 0xD8D8D8), UIColor(hex: 0xD94FB0)])
                case "hue": track = .gradient([UIColor(hex: 0x3E7BE6), UIColor(hex: 0x46B85A), UIColor(hex: 0xF2D14A), UIColor(hex: 0xE5484D), UIColor(hex: 0xD94FB0)])
                default: track = .centered
                }
                c = Control(id: "local.\(id)", label: names[id] ?? id, min: -100, max: 100, def: 0, step: 1, decimals: 0, track: track)
            }
            m["local.\(id)"] = c
        }
        return m
    }()
}
