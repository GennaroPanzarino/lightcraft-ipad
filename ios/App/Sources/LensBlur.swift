import CoreImage
import CoreML
import CoreVideo
import ImageIO
import UIKit
import Vision

/// Lightroom's Lens Blur: what stays sharp (a band of depth around the focus) and how much the rest
/// melts. Kept in the photo's settings (`lens_blur`, the fields Lightroom's presets carry), so it
/// travels with copy / paste, styles and undo.
struct LensBlurState: Equatable {
    var enabled = false
    /// 0…100.
    var amount = 50.0
    /// The depth in focus, 0…1 (1 = nearest); nil: the subject (the nearest part of the scene).
    var focus: Double?
    /// How deep the sharp band is, 0…1.
    var range = 0.18

    static func from(_ develop: [String: Any]) -> LensBlurState {
        let l = develop["lens_blur"] as? [String: Any] ?? [:]
        var s = LensBlurState()
        s.enabled = (l["enabled"] as? Bool) ?? false
        let amount = double(l["amount"]), focal = double(l["focal_distance"]), range = double(l["focal_range"])
        if amount > 0 { s.amount = amount }
        if focal > 0 { s.focus = focal / 100 }
        if range > 0 { s.range = range / 100 }
        return s
    }

    var settings: [String: Any] {
        ["lens_blur": ["enabled": enabled, "amount": amount, "focal_distance": (focus ?? 0) * 100, "focal_range": range * 100]]
    }
}

/// A depth map: 0…1 per cell, 1 = nearest.
struct DepthMap {
    let width: Int
    let height: Int
    let values: [Float]

    func at(_ u: CGPoint) -> Float {
        let x = max(0, min(width - 1, Int(u.x * CGFloat(width))))
        let y = max(0, min(height - 1, Int(u.y * CGFloat(height))))
        return values[y * width + x]
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
            let sy = min(height - 1, max(0, Int((Double(n.minY) + (Double(y) + 0.5) / Double(h) * Double(n.height)) * Double(height))))
            for x in 0..<w {
                let sx = min(width - 1, max(0, Int((Double(n.minX) + (Double(x) + 0.5) / Double(w) * Double(n.width)) * Double(width))))
                v[y * w + x] = values[sy * width + sx]
            }
        }
        return DepthMap(width: w, height: h, values: v)
    }

    /// The map as a picture (near = light), for "show depth".
    var image: CGImage? {
        let px = values.map { UInt8(max(0, min(255, $0 * 255))) }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A picture drawn at another size (the depth map shown with the photo's proportions).
func stretched(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
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

/// The blur itself: Core Image's masked variable blur on the GPU, the mask from the depth.
enum LensBlurRenderer {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The blur mask (white = most blur) for a depth map, as a Core Image picture of `size`.
    private static func mask(_ d: DepthMap, _ s: LensBlurState, size: CGSize, reference: CGFloat) -> CIImage? {
        let focus = Float(s.focus ?? Double(d.subject))
        let half = Float(s.range) / 2
        let soft: Float = 0.1
        var px = [UInt8](repeating: 0, count: d.width * d.height)
        for i in px.indices {
            let m = max(0, min(1, (abs(d.values[i] - focus) - half) / soft))
            px[i] = UInt8(m * 255)
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let g = CGImage(width: d.width, height: d.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: d.width, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        // a soft edge between sharp and blurred, made at the depth map's size (cheap), then
        // stretched to the picture's
        let k = size.width / CGFloat(max(1, d.width))
        let soft = CIImage(cgImage: g).clampedToExtent().applyingGaussianBlur(sigma: Double(reference) * 0.003 / Double(max(k, 0.01)))
        let t = CGAffineTransform(scaleX: k, y: size.height / CGFloat(max(1, d.height)))
        return soft.transformed(by: t).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// `input` disc-blurred by `radius` pixels, worked at a fraction of its size (a blur hides the
    /// difference, and it costs a fraction of the time).
    private static func disc(_ input: CIImage, radius: Double) -> CIImage? {
        let k: CGFloat = radius > 24 ? 0.25 : (radius > 8 ? 0.5 : 1)
        let small = input.clampedToExtent().transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let f = CIFilter(name: "CIDiscBlur") else { return nil }
        f.setValue(small, forKey: kCIInputImageKey)
        f.setValue(max(0.5, radius * Double(k)), forKey: kCIInputRadiusKey)
        return f.outputImage?.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k)).cropped(to: input.extent)
    }

    /// The mask's values stretched: `scale × m + bias`, kept within 0…1.
    private static func ramp(_ m: CIImage, scale: CGFloat, bias: CGFloat) -> CIImage {
        m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
    }

    /// The photo with the lens blur: half the blur where the mask is half, all of it where it is
    /// white. `reference`: the long edge of the whole photo at this scale (a window of a zoomed-in
    /// view blurs as much as the whole photo would).
    static func blurred(_ input: CIImage, depth: DepthMap, _ s: LensBlurState, reference: CGFloat? = nil) -> CIImage? {
        let size = input.extent.size
        let ref = reference ?? max(size.width, size.height)
        guard s.enabled, s.amount > 0, let m = mask(depth, s, size: size, reference: ref) else { return nil }
        let radius = s.amount / 100 * Double(ref) * 0.014
        guard let strong = disc(input, radius: radius), let medium = disc(input, radius: radius * 0.45),
              let a = CIFilter(name: "CIBlendWithMask"), let b = CIFilter(name: "CIBlendWithMask") else { return nil }
        a.setValue(medium, forKey: kCIInputImageKey)
        a.setValue(input, forKey: kCIInputBackgroundImageKey)
        a.setValue(ramp(m, scale: 2, bias: 0), forKey: kCIInputMaskImageKey)
        guard let half = a.outputImage else { return nil }
        b.setValue(strong, forKey: kCIInputImageKey)
        b.setValue(half, forKey: kCIInputBackgroundImageKey)
        b.setValue(ramp(m, scale: 2, bias: -1), forKey: kCIInputMaskImageKey)
        return b.outputImage?.cropped(to: input.extent)
    }

    /// A picture of the viewer with the blur; `scale` < 1 makes a smaller one (while a finger moves).
    static func apply(_ image: CGImage, depth: DepthMap, _ s: LensBlurState, reference: CGFloat? = nil, scale: CGFloat = 1) -> CGImage? {
        var input = CIImage(cgImage: image)
        var ref = reference
        if scale < 1 {
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            ref = (reference ?? CGFloat(max(image.width, image.height))) * scale
        }
        guard let out = blurred(input, depth: depth, s, reference: ref) else { return nil }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.createCGImage(out, from: input.extent, format: .RGBA8, colorSpace: space)
    }

    /// An exported JPEG or TIFF blurred in place, its metadata and depth kept.
    static func apply(toFile url: URL, depth: DepthMap, _ s: LensBlurState, quality: Int) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let type = CGImageSourceGetType(src) else { return false }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let input = CIImage(cgImage: image)
        guard let out = blurred(input, depth: depth, s) else { return false }
        let deep = image.bitsPerComponent > 8
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cg = context.createCGImage(out, from: input.extent, format: deep ? .RGBA16 : .RGBA8, colorSpace: space),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return false }
        var p = props
        p[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100
        CGImageDestinationAddImage(dest, cg, p as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
