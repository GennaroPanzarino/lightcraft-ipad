import Compression
import CoreGraphics
import CoreImage
import Foundation
import Vision

/// A coverage map, 0…1 per cell over the uncropped photo (row by row).
struct Coverage {
    let width: Int
    let height: Int
    var values: [Float]

    func at(_ x: Double, _ y: Double) -> Float {
        // bilinear, (x, y) 0…1 of the photo
        let fx = max(0, min(Double(width - 1), x * Double(width) - 0.5)), fy = max(0, min(Double(height - 1), y * Double(height) - 0.5))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx
        let bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty
    }

    /// How much of the photo it covers (0…1).
    var share: Float { values.reduce(0, +) / Float(max(1, values.count)) }
}

/// Lightroom's one-tap selections made on the iPad itself: the people (Vision), the subject (what
/// stands out and stands nearest: Vision's saliency with the depth from Depth Anything), the sky (the
/// farthest, brightest part, open to the top), a band of depth. Each becomes a mask component the
/// engine draws at any size: a grid of edge-preserving logits stored with the photo (LightCraft's
/// segmentation format), so exports, copies and undo need nothing from here again.
enum Selections {
    /// Cells per side of the stored grid (over the photo stretched to a square).
    static let side = 512
    /// The kinds the app works out itself.
    static let kinds: Set<String> = ["subject", "sky", "background", "people", "depthRange"]

    // MARK: what is selected

    /// Every person in the photo (nil: none found).
    static func people(_ image: CGImage) -> Coverage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])) != nil, let mask = req.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { v[y * w + x] = Float(base[y * row + x]) / 255 } }
        let c = Coverage(width: w, height: h, values: v)
        return c.share > 0.004 ? c : nil
    }

    /// The main subject: the people when there are any, else what Vision finds salient, cut out
    /// by depth (what stands at the salient part's distance or nearer).
    static func subject(_ image: CGImage, depth: DepthMap?) -> Coverage? {
        if let p = people(image), p.share > 0.01 { return p }
        let req = VNGenerateObjectnessBasedSaliencyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])) != nil, let obs = req.results?.first as? VNSaliencyImageObservation else { return nil }
        let heat = heatmap(obs.pixelBuffer)
        // the salient objects' box (Vision's origin is at the bottom), a little wider
        var box = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        if let objects = obs.salientObjects, !objects.isEmpty {
            box = objects.map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
                .reduce(CGRect.null) { $0.union($1) }
        }
        box = box.insetBy(dx: -box.width * 0.08, dy: -box.height * 0.08)
        let w = depth?.width ?? 256, h = depth?.height ?? 256
        var v = [Float](repeating: 0, count: w * h)
        // the subject's depth: the salient part's, its nearer half
        var subjectDepth: Float = 0
        if let d = depth {
            var inside: [Float] = []
            for y in 0..<h {
                for x in 0..<w {
                    let u = (Double(x) + 0.5) / Double(w), t = (Double(y) + 0.5) / Double(h)
                    if box.contains(CGPoint(x: u, y: t)), heat.at(u, t) > 0.35 { inside.append(d.values[y * w + x]) }
                }
            }
            inside.sort()
            subjectDepth = inside.isEmpty ? d.subject : inside[min(inside.count - 1, Int(Double(inside.count) * 0.55))]
        }
        for y in 0..<h {
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w), t = (Double(y) + 0.5) / Double(h)
                // inside the box, fading out over its edge
                let dx = max(box.minX - u, u - box.maxX, 0) / max(box.width, 0.01), dy = max(box.minY - t, t - box.maxY, 0) / max(box.height, 0.01)
                let inBox = Float(max(0, 1 - 8 * max(dx, dy)))
                let near: Float
                if let d = depth {
                    near = smooth(subjectDepth - 0.16, subjectDepth - 0.05, d.values[y * w + x])
                } else {
                    near = smooth(0.2, 0.6, heat.at(u, t))
                }
                v[y * w + x] = inBox * near
            }
        }
        let c = Coverage(width: w, height: h, values: v)
        return c.share > 0.004 ? c : nil
    }

    /// The sky: far away (the depth's farthest part), bright, and open to the top of the frame.
    static func sky(_ image: CGImage, depth: DepthMap?) -> Coverage? {
        let w = depth?.width ?? 256, h = depth?.height ?? 256
        guard let lum = luminance(image, w, h) else { return nil }
        var far = [Float](repeating: 0, count: w * h)
        for i in far.indices {
            let distant: Float = depth.map { 1 - smooth(0.05, 0.16, $0.values[i]) } ?? 1
            far[i] = distant * smooth(0.18, 0.4, lum[i])
        }
        // only what is open to the top: a flood from the first row through the far, bright cells
        var reach = [Bool](repeating: false, count: w * h)
        var stack: [Int] = (0..<w).filter { far[$0] > 0.5 }
        for i in stack { reach[i] = true }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let j = ny * w + nx
                if !reach[j] && far[j] > 0.5 {
                    reach[j] = true
                    stack.append(j)
                }
            }
        }
        var v = [Float](repeating: 0, count: w * h)
        for i in v.indices where reach[i] { v[i] = far[i] }
        let c = Coverage(width: w, height: h, values: blurred(v, w, h, radius: 1))
        return c.share > 0.004 ? c : nil
    }

    /// A band of distance: `near`…`far` (0 = nearest, 1 = farthest), softened by `feather`.
    static func depthRange(_ d: DepthMap, near: Double, far: Double, feather: Double) -> Coverage {
        let f = Float(max(0.005, feather)), lo = Float(min(near, far)), hi = Float(max(near, far))
        let v = d.values.map { dv -> Float in
            let dist = 1 - dv
            return smooth(lo - f, lo, dist) * (1 - smooth(hi, hi + f, dist))
        }
        return Coverage(width: d.width, height: d.height, values: v)
    }

    // MARK: the stored form

    /// The coverage as LightCraft's segmentation (`{side, data}`): logits on a `side × side` grid,
    /// quantized to eighths, raw deflate, base64.
    static func seg(_ c: Coverage) -> [String: Any]? {
        let n = side
        var q = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let p = Double(min(max(c.at((Double(x) + 0.5) / Double(n), (Double(y) + 0.5) / Double(n)), 0.0001), 0.9999))
                let logit = log(p / (1 - p))
                q[y * n + x] = UInt8(bitPattern: Int8(max(-127, min(127, (logit * 8).rounded()))))
            }
        }
        guard let z = deflate(q) else { return nil }
        return ["side": n, "data": z.base64EncodedString()]
    }

    /// The name a depth-range component carries its settings in ("Gamma profondità 20–60 % · 10").
    static func depthName(near: Double, far: Double, feather: Double) -> String {
        "\(MaskKinds.label("depthRange")) \(Int((near * 100).rounded()))–\(Int((far * 100).rounded())) % · \(Int((feather * 100).rounded()))"
    }

    static func depthSettings(_ name: String) -> (near: Double, far: Double, feather: Double) {
        let nums = name.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        guard nums.count >= 3 else { return (0, 0.3, 0.1) }
        return (nums[0] / 100, nums[1] / 100, nums[2] / 100)
    }

    // MARK: helpers

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / max(b - a, 1e-6)))
        return t * t * (3 - 2 * t)
    }

    private static func heatmap(_ pb: CVPixelBuffer) -> Coverage {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb) / 4
        var v = [Float](repeating: 0, count: w * h)
        if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: Float.self) {
            for y in 0..<h { for x in 0..<w { v[y * w + x] = base[y * row + x] } }
        }
        let top = max(v.max() ?? 1, 1e-6)
        return Coverage(width: w, height: h, values: v.map { $0 / top })
    }

    /// The picture's lightness at `w × h` (0…1).
    private static func luminance(_ image: CGImage, _ w: Int, _ h: Int) -> [Float]? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (0..<(w * h)).map { Float(data[$0]) / 255 }
    }

    private static func blurred(_ v: [Float], _ w: Int, _ h: Int, radius: Int) -> [Float] {
        var a = v, b = v
        for _ in 0..<2 {
            for y in 0..<h {
                for x in 0..<w {
                    var s: Float = 0, n: Float = 0
                    for k in -radius...radius where x + k >= 0 && x + k < w { s += a[y * w + x + k]; n += 1 }
                    b[y * w + x] = s / n
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    var s: Float = 0, n: Float = 0
                    for k in -radius...radius where y + k >= 0 && y + k < h { s += b[(y + k) * w + x]; n += 1 }
                    a[y * w + x] = s / n
                }
            }
        }
        return a
    }

    /// Raw deflate (RFC 1951, what LightCraft inflates).
    private static func deflate(_ bytes: [UInt8]) -> Data? {
        let cap = bytes.count + 1024
        var out = [UInt8](repeating: 0, count: cap)
        let n = compression_encode_buffer(&out, cap, bytes, bytes.count, nil, COMPRESSION_ZLIB)
        return n > 0 ? Data(out.prefix(n)) : nil
    }
}

/// Lightroom's Visualize Spots: the picture as its fine detail (each pixel against its surroundings),
/// white on black, `contrast` 0…100 how strongly. Dust, flat and round, stands out at once.
enum SpotMap {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func make(_ image: CGImage, contrast: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let grey = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let around = grey.clampedToExtent().applyingGaussianBlur(sigma: Double(max(image.width, image.height)) * 0.004).cropped(to: input.extent)
        let gain = 4 + contrast / 100 * 28
        let diff = around.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: grey])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .applyingFilter("CIColorClamp")
        return context.createCGImage(diff, from: input.extent)
    }
}
