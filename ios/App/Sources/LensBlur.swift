import CoreImage
import CoreML
import CoreVideo
import ImageIO
import Metal
import UIKit
import Vision

/// A stroke of Lens Blur's Refine brushes, in the image's own coordinates (uncropped): it keeps
/// what it covers in focus (`focus`) or blurs it, whatever its depth.
struct RefineStroke: Equatable {
    var points: [CGPoint]
    /// Radius, a fraction of the image's long edge.
    var size: Double
    var feather: Double
    var flow: Double
    var focus: Bool

    var json: [String: Any] {
        ["points": points.map { [Double($0.x), Double($0.y)] }, "size": size, "feather": feather, "flow": flow, "focus": focus]
    }

    static func from(_ o: [String: Any]) -> RefineStroke? {
        let pts = (o["points"] as? [Any] ?? []).compactMap { p -> CGPoint? in
            guard let a = p as? [Any], a.count >= 2 else { return nil }
            return CGPoint(x: double(a[0]), y: double(a[1]))
        }
        guard !pts.isEmpty else { return nil }
        return RefineStroke(points: pts, size: double(o["size"]), feather: double(o["feather"]), flow: double(o["flow"]), focus: (o["focus"] as? Bool) ?? true)
    }
}

/// Lightroom's Lens Blur: what stays sharp (a band of depth around the focus), how much the rest
/// melts, the shape and glow of the out-of-focus highlights, and the parts painted in focus or
/// out of it. Kept in the photo's settings (`lens_blur`), so it travels with copy / paste, styles
/// and undo.
struct LensBlurState: Equatable {
    var enabled = false
    /// 0…100.
    var amount = 50.0
    /// The depth in focus, 0…1 (1 = nearest); nil: the subject (the nearest part of the scene).
    var focus: Double?
    /// How deep the sharp band is, 0…1.
    var range = 0.18
    /// Lightroom's Bokeh: "" (circle), "bubble", "blade5", "ring", "cateye".
    var bokeh = ""
    /// Lightroom's Boost, 0…100.
    var boost = 0.0
    var refine: [RefineStroke] = []

    static let shapes: [(String, String)] = [("", "Cerchio"), ("bubble", "Bolla"), ("blade5", "5 lamelle"), ("ring", "Anello"), ("cateye", "Occhio di gatto")]

    static func from(_ develop: [String: Any]) -> LensBlurState {
        let l = develop["lens_blur"] as? [String: Any] ?? [:]
        var s = LensBlurState()
        s.enabled = (l["enabled"] as? Bool) ?? false
        let amount = double(l["amount"]), focal = double(l["focal_distance"]), range = double(l["focal_range"])
        if amount > 0 { s.amount = amount }
        if focal > 0 { s.focus = focal / 100 }
        if range > 0 { s.range = range / 100 }
        s.bokeh = l.str("bokeh")
        s.boost = double(l["boost"])
        s.refine = (l["refine"] as? [[String: Any]] ?? []).compactMap(RefineStroke.from)
        return s
    }

    var settings: [String: Any] {
        ["lens_blur": [
            "enabled": enabled, "amount": amount, "focal_distance": (focus ?? 0) * 100, "focal_range": range * 100,
            "bokeh": bokeh, "boost": boost, "refine": refine.map(\.json),
        ] as [String: Any]]
    }

    /// The blur's radius at its strongest, in pixels of a picture whose long edge is `reference`.
    func radius(_ reference: CGFloat) -> Double { amount / 100 * Double(reference) * 0.025 }
}

/// A depth map: 0…1 per cell, 1 = nearest. (Also any map of the picture: the blur's own.)
struct DepthMap {
    let width: Int
    let height: Int
    let values: [Float]

    func at(_ u: CGPoint) -> Float {
        let x = max(0, min(width - 1, Int(u.x * CGFloat(width))))
        let y = max(0, min(height - 1, Int(u.y * CGFloat(height))))
        return values[y * width + x]
    }

    /// Bilinear, (x, y) 0…1 of the picture.
    func sample(_ x: Double, _ y: Double) -> Float {
        let fx = max(0, min(Double(width - 1), x * Double(width) - 0.5)), fy = max(0, min(Double(height - 1), y * Double(height) - 0.5))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx
        let bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty
    }

    /// The subject's depth: what is nearest, ignoring the closest few percent (a foreground edge).
    var subject: Float {
        let s = values.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * 0.92))]
    }

    /// The part of the map under `n` (0…1 of the picture): the depth of a zoomed-in window.
    func sub(_ n: CGRect) -> DepthMap {
        let w = max(8, Int((Double(width) * Double(n.width)).rounded())), h = max(8, Int((Double(height) * Double(n.height)).rounded()))
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let sy = Double(n.minY) + (Double(y) + 0.5) / Double(h) * Double(n.height)
            for x in 0..<w {
                v[y * w + x] = sample(Double(n.minX) + (Double(x) + 0.5) / Double(w) * Double(n.width), sy)
            }
        }
        return DepthMap(width: w, height: h, values: v)
    }

    /// The share of the map at each of `bins` distances (0 = nearest … 1 = farthest), for the
    /// focal range's histogram.
    func histogram(_ bins: Int) -> [Float] {
        var h = [Float](repeating: 0, count: bins)
        for v in values { h[max(0, min(bins - 1, Int((1 - v) * Float(bins))))] += 1 }
        let top = max(h.max() ?? 1, 1)
        return h.map { $0 / top }
    }

    /// The map as a picture (near = light), for "show depth".
    var image: CGImage? {
        let px = values.map { UInt8(max(0, min(255, $0 * 255))) }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Lightroom's Visualize Depth: near warm and bright, far cool and dark; what lies in the
    /// focal band (`focus` ± `range` / 2, in nearness) drawn lighter.
    func colored(width w: Int, height h: Int, focus: Float?, range: Float) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        let stops: [(Float, (Float, Float, Float))] = [(0, (0.10, 0.05, 0.32)), (0.35, (0.36, 0.16, 0.62)), (0.65, (0.85, 0.32, 0.45)), (1, (1.0, 0.86, 0.35))]
        func color(_ t: Float) -> (Float, Float, Float) {
            for k in 1..<stops.count where t <= stops[k].0 {
                let (a, ca) = stops[k - 1], (b, cb) = stops[k]
                let u = (t - a) / max(b - a, 1e-6)
                return (ca.0 + (cb.0 - ca.0) * u, ca.1 + (cb.1 - ca.1) * u, ca.2 + (cb.2 - ca.2) * u)
            }
            return stops[stops.count - 1].1
        }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let d = sample((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h))
                var c = color(d)
                if let f = focus, abs(d - f) <= range / 2 {
                    c = (c.0 * 0.55 + 0.45, c.1 * 0.55 + 0.45, c.2 * 0.55 + 0.45)
                }
                let i = (y * w + x) * 4
                px[i] = UInt8(c.0 * 255)
                px[i + 1] = UInt8(c.1 * 255)
                px[i + 2] = UInt8(c.2 * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The scene's depth from one picture: Depth Anything V2 Small on the Neural Engine when the app has
/// the model (converted for iPadOS 15 in the build), else the people in it (Vision): a person is
/// near, the rest far.
final class DepthEstimator: @unchecked Sendable {
    static let shared = DepthEstimator()
    private let queue = DispatchQueue(label: "lightcraft-depth", qos: .userInitiated)
    private var model: MLModel?
    private var loaded = false
    private(set) var source = ""
    static let side = 518

    func estimate(_ image: CGImage) async -> DepthMap? {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.run(image)) }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "DepthAnything", withExtension: "mlmodelc") else { return }
        let cfg = MLModelConfiguration()
        // the GPU: ready in a moment (the Neural Engine would first compile the model for itself,
        // which can take a minute on the first use)
        cfg.computeUnits = .cpuAndGPU
        model = try? MLModel(contentsOf: url, configuration: cfg)
    }

    /// The model loaded ahead (at start, in the background), so the first blur doesn't wait for it.
    func preload() {
        queue.async { self.load() }
    }

    private func run(_ image: CGImage) -> DepthMap? {
        load()
        if let m = model, let px = DepthEstimator.buffer(image, DepthEstimator.side, DepthEstimator.side),
           let out = try? m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: px)])),
           let arr = out.featureValue(for: "depth")?.multiArrayValue {
            source = "GPU · Depth Anything V2"
            return DepthEstimator.normalized(arr)
        }
        if let p = people(image) {
            source = "Vision · persone"
            return p
        }
        source = "non disponibile"
        return nil
    }

    private static func buffer(_ image: CGImage, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let b = pb else { return nil }
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(b),
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return b
    }

    /// The model's relative inverse depth, stretched to 0…1.
    private static func normalized(_ a: MLMultiArray) -> DepthMap? {
        let shape = a.shape.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let h = shape[shape.count - 2], w = shape[shape.count - 1]
        let strides = a.strides.map(\.intValue)
        let sy = strides[strides.count - 2], sx = strides[strides.count - 1]
        var v = [Float](repeating: 0, count: w * h)
        if a.dataType == .float32 {
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            for y in 0..<h { for x in 0..<w { v[y * w + x] = p[y * sy + x * sx] } }
        } else {
            for y in 0..<h { for x in 0..<w { v[y * w + x] = a[y * sy + x * sx].floatValue } }
        }
        guard let lo = v.min(), let hi = v.max(), hi > lo else { return nil }
        let k = 1 / (hi - lo)
        for i in v.indices { v[i] = (v[i] - lo) * k }
        return DepthMap(width: w, height: h, values: v)
    }

    private func people(_ image: CGImage) -> DepthMap? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([req])) != nil, let mask = req.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var v = [Float](repeating: 0, count: w * h)
        var any = false
        for y in 0..<h {
            for x in 0..<w {
                let m = Float(p[y * row + x]) / 255
                v[y * w + x] = m
                if m > 0.5 { any = true }
            }
        }
        return any ? DepthMap(width: w, height: h, values: v) : nil
    }
}

/// The blur itself: how much each part of the picture melts (its blur map: depth against the
/// focal band, then the Refine strokes), and a lens's bokeh drawn on the GPU from it.
enum LensBlurRenderer {
    static let context = CIContext(options: [.cacheIntermediates: false])
    /// The blur map's long edge (cells).
    static let mapEdge = 1024

    /// How much each part of a picture of proportions `aspect` (width / height) blurs, 0…1: the
    /// depth away from the focal band, then the Refine strokes (`crop` takes them from the
    /// image's own coordinates to the picture's).
    static func blurMap(_ d: DepthMap, _ s: LensBlurState, crop: CropState, aspect: CGFloat) -> DepthMap {
        let w = aspect >= 1 ? mapEdge : max(8, Int(CGFloat(mapEdge) * aspect))
        let h = aspect >= 1 ? max(8, Int(CGFloat(mapEdge) / aspect)) : mapEdge
        let focus = Float(s.focus ?? Double(d.subject))
        let half = Float(s.range) / 2
        let soft: Float = 0.1
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let fy = (Double(y) + 0.5) / Double(h)
            for x in 0..<w {
                let dv = d.sample((Double(x) + 0.5) / Double(w), fy)
                v[y * w + x] = max(0, min(1, (abs(dv - focus) - half) / soft))
            }
        }
        if !s.refine.isEmpty {
            let blur = strokes(s.refine.filter { !$0.focus }, crop: crop, w, h), keep = strokes(s.refine.filter(\.focus), crop: crop, w, h)
            for i in v.indices {
                var m = v[i]
                if let b = blur { m = max(m, b[i]) }
                if let k = keep { m *= 1 - k[i] }
                v[i] = m
            }
        }
        return DepthMap(width: w, height: h, values: v)
    }

    /// Refine strokes drawn at `w × h` over the picture (0…1 each cell; nil: none), each softened
    /// by its feather.
    private static func strokes(_ list: [RefineStroke], crop: CropState, _ w: Int, _ h: Int) -> [Float]? {
        guard !list.isEmpty else { return nil }
        var out = [Float](repeating: 0, count: w * h)
        // strokes of one feather are drawn and softened together
        for feather in Set(list.map { Int($0.feather.rounded()) }).sorted() {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            var widest: CGFloat = 0
            for st in list where Int(st.feather.rounded()) == feather {
                let width = max(1, 2 * crop.toViewWidth(CGFloat(st.size)) * CGFloat(w))
                widest = max(widest, width)
                ctx.setStrokeColor(gray: CGFloat(max(0.05, min(1, st.flow / 100))), alpha: 1)
                ctx.setLineWidth(width)
                let pts = st.points.map { p -> CGPoint in
                    let u = crop.toView(p)
                    return CGPoint(x: u.x * CGFloat(w), y: u.y * CGFloat(h))
                }
                ctx.beginPath()
                ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                if pts.count == 1 { ctx.addLine(to: CGPoint(x: pts[0].x + 0.1, y: pts[0].y)) }
                ctx.strokePath()
            }
            guard var img = ctx.makeImage() else { continue }
            let sigma = Double(widest) * Double(feather) / 100 * 0.3
            if sigma > 0.5 {
                let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
                if let b = context.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) { img = b }
            }
            guard let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            g.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = g.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            for i in out.indices { out[i] = max(out[i], Float(data[i]) / 255) }
        }
        return out
    }

    /// A picture of the viewer with the blur; `scale` < 1 makes a smaller one (while a finger
    /// moves). `reference`: the long edge of the whole photo at this scale (a window of a
    /// zoomed-in view blurs as much as the whole photo would).
    static func apply(_ image: CGImage, map: DepthMap, _ s: LensBlurState, reference: CGFloat? = nil, scale: CGFloat = 1, quality: Bokeh.Quality = .screen) -> CGImage? {
        guard s.enabled, s.amount > 0 else { return nil }
        var ref = reference ?? CGFloat(max(image.width, image.height))
        var input = image
        if scale < 1 {
            input = scaled(image, edge: Int(CGFloat(max(image.width, image.height)) * scale))
            ref *= scale
        }
        let radius = s.radius(ref)
        if let out = Bokeh.shared?.render(input, map: map, radius: radius, shape: s.bokeh, boost: s.boost / 100, quality: quality) { return out }
        return fallback(input, map: map, radius: radius)
    }

    /// An exported JPEG or TIFF blurred in place, its metadata kept.
    static func apply(toFile url: URL, map: DepthMap, _ s: LensBlurState, quality: Int) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let type = CGImageSourceGetType(src) else { return false }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        guard let cg = apply(image, map: map, s, quality: .export), let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return false }
        var p = props
        p[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100
        CGImageDestinationAddImage(dest, cg, p as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Without Metal: Core Image's disc blur at two strengths, blended by the map.
    private static func fallback(_ image: CGImage, map: DepthMap, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let size = input.extent.size
        let px = map.values.map { UInt8(max(0, min(255, $0 * 255))) }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let g = CGImage(width: map.width, height: map.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: map.width, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let m = CIImage(cgImage: g).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(map.width), y: size.height / CGFloat(map.height)))
        func disc(_ r: Double) -> CIImage? {
            let k: CGFloat = r > 24 ? 0.25 : (r > 8 ? 0.5 : 1)
            let f = CIFilter(name: "CIDiscBlur")
            f?.setValue(input.clampedToExtent().transformed(by: CGAffineTransform(scaleX: k, y: k)), forKey: kCIInputImageKey)
            f?.setValue(max(0.5, r * Double(k)), forKey: kCIInputRadiusKey)
            return f?.outputImage?.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k)).cropped(to: input.extent)
        }
        func ramp(_ scale: CGFloat, _ bias: CGFloat) -> CIImage {
            m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ]).applyingFilter("CIColorClamp")
        }
        guard let strong = disc(radius), let medium = disc(radius * 0.45) else { return nil }
        let half = medium.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: input, kCIInputMaskImageKey: ramp(2, 0)])
        let out = strong.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: half, kCIInputMaskImageKey: ramp(2, -1)])
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.createCGImage(out.cropped(to: input.extent), from: input.extent, format: .RGBA8, colorSpace: space)
    }
}

/// A lens's bokeh on the GPU (Metal): every pixel gathers the light of the pixels around it within
/// its own blur radius, through the aperture's shape, the bright ones weighing more (Boost); a
/// pixel only takes from those whose own blur reaches it, so a sharp subject never smears into
/// the blur behind it. Worked on a pyramid of the picture (the blur at a size where its radius is
/// a handful of pixels), then laid over the sharp picture where the map says, edge-aware.
final class Bokeh {
    enum Quality { case live, screen, export }

    static let shared: Bokeh? = Bokeh()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let prepare: MTLComputePipelineState
    private let gather: MTLComputePipelineState
    private let composite: MTLComputePipelineState
    private let lock = NSLock()

    private init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(),
              let lib = try? d.makeLibrary(source: Bokeh.source, options: nil),
              let a = lib.makeFunction(name: "prepare").flatMap({ try? d.makeComputePipelineState(function: $0) }),
              let b = lib.makeFunction(name: "gather").flatMap({ try? d.makeComputePipelineState(function: $0) }),
              let c = lib.makeFunction(name: "composite").flatMap({ try? d.makeComputePipelineState(function: $0) })
        else { return nil }
        device = d
        queue = q
        prepare = a
        gather = b
        composite = c
    }

    /// The aperture's shape as sample points (x, y in the unit disc) with weights.
    private static func taps(_ shape: String, count n: Int) -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = []
        let golden = Float.pi * (3 - sqrt(5))
        // area-even points (a sunflower), more than needed for the shapes that keep only some
        let total = shape == "blade5" ? n * 13 / 10 : (shape == "ring" ? n * 2 : n)
        for i in 0..<total {
            let r = sqrt((Float(i) + 0.5) / Float(total)), a = Float(i) * golden
            let p = SIMD2<Float>(r * cos(a), r * sin(a))
            var w: Float = 1
            switch shape {
            case "bubble":
                // a soap bubble: a bright rim
                w = 0.35 + 1.3 * r * r * r
            case "ring":
                // a mirror lens: a ring with a dark middle
                if r < 0.62 { continue }
            case "blade5":
                // five straight blades: inside a regular pentagon
                let sector = Float.pi * 2 / 5
                let t = (atan2(p.y, p.x) + Float.pi / 2).truncatingRemainder(dividingBy: sector)
                let edge = cos(sector / 2) / cos(abs(t - sector / 2))
                if r > edge { continue }
            default:
                break
            }
            out.append(SIMD4(p.x, p.y, w, 0))
        }
        return out
    }

    private func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, mips: Bool = false, write: Bool = true) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: mips)
        d.usage = write ? [.shaderRead, .shaderWrite] : [.shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    func render(_ image: CGImage, map: DepthMap, radius: Double, shape: String, boost: Double, quality: Quality) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let w = image.width, h = image.height
        guard w > 1, h > 1, radius > 0.5 else { return nil }
        // the picture, as RGBA8 sRGB
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        guard let sharp = texture(.rgba8Unorm, w, h, write: false), let out = texture(.rgba8Unorm, w, h) else { return nil }
        sharp.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
        // the blur map
        guard let mapTex = texture(.r32Float, map.width, map.height, write: false) else { return nil }
        map.values.withUnsafeBytes { mapTex.replace(region: MTLRegionMake2D(0, 0, map.width, map.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: map.width * 4) }
        // linear light at half size, with its pyramid
        let hw = max(1, w / 2), hh = max(1, h / 2)
        guard let half = texture(.rgba16Float, hw, hh, mips: true) else { return nil }
        // the level where the strongest blur is a few pixels across, and the work at that size
        let target: Double = quality == .export ? 22 : (quality == .live ? 10 : 16)
        let level = max(0, min(half.mipmapLevelCount - 1, Int(ceil(log2(max(1, radius / 2 / target))))))
        let lw = max(1, hw >> level), lh = max(1, hh >> level)
        guard let blurred = texture(.rgba16Float, lw, lh) else { return nil }
        let count = quality == .export ? 160 : (quality == .live ? 56 : 112)
        var taps = Bokeh.taps(shape, count: count)
        var params = Params(radius: Float(radius / 2) / Float(1 << level), fullRadius: Float(radius), boost: Float(boost), count: Int32(taps.count),
                            catEye: shape == "cateye" ? 1 : 0, level: Float(level))
        guard let cmd = queue.makeCommandBuffer(), let e1 = cmd.makeComputeCommandEncoder() else { return nil }
        func dispatch(_ e: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ gw: Int, _ gh: Int) {
            e.setComputePipelineState(p)
            let tw = p.threadExecutionWidth, th = max(1, p.maxTotalThreadsPerThreadgroup / tw)
            e.dispatchThreadgroups(MTLSize(width: (gw + tw - 1) / tw, height: (gh + th - 1) / th, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }
        e1.setTexture(sharp, index: 0)
        e1.setTexture(half, index: 1)
        dispatch(e1, prepare, hw, hh)
        e1.endEncoding()
        if half.mipmapLevelCount > 1, let b = cmd.makeBlitCommandEncoder() {
            b.generateMipmaps(for: half)
            b.endEncoding()
        }
        guard let e2 = cmd.makeComputeCommandEncoder() else { return nil }
        e2.setTexture(half, index: 0)
        e2.setTexture(mapTex, index: 1)
        e2.setTexture(blurred, index: 2)
        e2.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        e2.setBytes(&taps, length: MemoryLayout<SIMD4<Float>>.stride * taps.count, index: 1)
        dispatch(e2, gather, lw, lh)
        e2.endEncoding()
        guard let e3 = cmd.makeComputeCommandEncoder() else { return nil }
        e3.setTexture(sharp, index: 0)
        e3.setTexture(blurred, index: 1)
        e3.setTexture(mapTex, index: 2)
        e3.setTexture(out, index: 3)
        e3.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(e3, composite, w, h)
        e3.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        out.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: image.colorSpace ?? space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private struct Params {
        /// The strongest blur's radius at the working level (pixels), and at full size.
        var radius: Float
        var fullRadius: Float
        var boost: Float
        var count: Int32
        var catEye: Int32
        var level: Float
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { float radius; float fullRadius; float boost; int count; int catEye; float level; };

    inline float3 toLinear(float3 c) { return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878); }
    inline float3 toSRGB(float3 c) {
        c = max(c, 0.0);
        float3 s1 = sqrt(c), s2 = sqrt(s1), s3 = sqrt(s2);
        return 0.662002687 * s1 + 0.684122060 * s2 - 0.323583601 * s3 - 0.0225411470 * c;
    }

    // the sharp picture at half size, in linear light (each pixel the mean of four)
    kernel void prepare(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        uint2 m = uint2(src.get_width() - 1, src.get_height() - 1);
        uint2 p = gid * 2;
        float3 c = toLinear(src.read(min(p, m)).rgb) + toLinear(src.read(min(p + uint2(1, 0), m)).rgb)
                 + toLinear(src.read(min(p + uint2(0, 1), m)).rgb) + toLinear(src.read(min(p + uint2(1, 1), m)).rgb);
        dst.write(float4(c * 0.25, 1), gid);
    }

    kernel void gather(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::sample> map [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]], constant Params& p [[buffer(0)]],
                       constant float4* taps [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= uint(size.x) || gid.y >= uint(size.y)) return;
        constexpr sampler s(filter::linear, mip_filter::nearest, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / size;
        float b0 = map.sample(s, uv).r;
        float R = b0 * p.radius;
        float3 centre = src.sample(s, uv, level(p.level)).rgb;
        if (R < 0.35) { dst.write(float4(centre, b0), gid); return; }
        // the cat's eye: the disc cut by a second one, off towards the frame's centre
        float2 off = (uv - 0.5) * 2.0 * 0.6;
        float3 acc = 0.0;
        float wsum = 0.0;
        for (int i = 0; i < p.count; i++) {
            float4 t = taps[i];
            if (p.catEye != 0 && length(t.xy + off) > 1.0) continue;
            float2 suv = uv + t.xy * R / size;
            float bs = map.sample(s, suv).r * p.radius;
            float d = length(t.xy) * R;
            // only light whose own blur reaches this pixel
            float reach = clamp(bs - d + 1.0, 0.0, 1.0);
            if (reach <= 0.0) continue;
            float3 c = src.sample(s, suv, level(p.level)).rgb;
            float l = dot(c, float3(0.2126, 0.7152, 0.0722));
            float glow = 1.0 + p.boost * 40.0 * pow(clamp((l - 0.45) / 0.55, 0.0, 1.0), 3.0);
            float w = t.z * reach * glow;
            acc += c * w;
            wsum += w;
        }
        float3 c = wsum > 0.0001 ? acc / wsum : centre;
        dst.write(float4(c, b0), gid);
    }

    // the blur laid over the sharp picture: none where the map is sharp, all of it where a pixel
    // blurs by more than a couple of pixels; the blurred picture taken from its cells of like
    // blur (edge-aware), so a sharp subject's colour doesn't bleed out from under it
    kernel void composite(texture2d<float, access::read> sharp [[texture(0)]], texture2d<float, access::read> blurred [[texture(1)]],
                          texture2d<float, access::sample> map [[texture(2)]], texture2d<float, access::write> dst [[texture(3)]],
                          constant Params& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= uint(size.x) || gid.y >= uint(size.y)) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / size;
        float b = map.sample(s, uv).r;
        float3 a = sharp.read(gid).rgb;
        float t = clamp((b * p.fullRadius - 0.6) / 2.4, 0.0, 1.0);
        if (t <= 0.0) { dst.write(float4(a, 1), gid); return; }
        float2 bs = float2(blurred.get_width(), blurred.get_height());
        float2 f = uv * bs - 0.5;
        int2 i0 = int2(floor(f));
        float2 fr = f - float2(i0);
        int2 m = int2(bs) - 1;
        float3 acc = 0.0;
        float wsum = 0.0;
        for (int k = 0; k < 4; k++) {
            int2 o = int2(k & 1, k >> 1);
            int2 q = clamp(i0 + o, int2(0), m);
            float4 c = blurred.read(uint2(q));
            float wb = (o.x == 1 ? fr.x : 1.0 - fr.x) * (o.y == 1 ? fr.y : 1.0 - fr.y);
            float w = wb * exp(-abs(c.a - b) * 12.0) + 1e-5;
            acc += c.rgb * w;
            wsum += w;
        }
        float3 blur = toSRGB(acc / wsum);
        dst.write(float4(mix(a, blur, t), 1), gid);
    }
    """
}

/// A picture drawn at another size (the depth map shown with the photo's proportions).
func stretched(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}
