import CoreGraphics
import Foundation

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A picture the engine made, with how long it took.
struct Rendered {
    let image: CGImage
    let millis: Double
}

/// JSON numbers as the engine sends them.
func int64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
func double(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

/// LightCraft's engine (one library), on a queue of its own: everything it does runs there one thing at
/// a time, so a call waits its turn.
final class Engine: @unchecked Sendable {
    private let queue: DispatchQueue
    private var handle: UnsafeMutableRawPointer?
    private let dir: URL
    private let nice: Int32
    private let previews: Bool
    /// Where the pixels come back: grown to the largest picture asked for so far (a full-size one
    /// only when the viewer zooms in).
    private var buffer: UnsafeMutablePointer<UInt8>
    private var capacity: Int
    let maxEdge: Int

    init(dir: URL, nice: Int32 = 0, previews: Bool = false, maxEdge: Int = 4096) {
        self.dir = dir
        self.nice = nice
        self.previews = previews
        self.maxEdge = maxEdge
        queue = DispatchQueue(label: previews ? "lightcraft-previews" : "lightcraft-engine", qos: previews ? .userInitiated : .utility)
        capacity = 2560 * 2560 * 4
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    deinit {
        if let h = handle { lc_close(h) }
        buffer.deallocate()
    }

    // ---- the queue

    func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    func open() async throws { try await run { try self.openNow() } }

    private func openNow() throws {
        guard handle == nil else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        handle = dir.path.withCString { lc_open($0, nice, previews) }
        if handle == nil { throw EngineError(message: "LightCraft non riesce ad aprire la libreria in \(dir.path)") }
    }

    /// Close the library, delete it and start an empty one (the previews' engine).
    func reset() async throws {
        try await run {
            if let h = self.handle { lc_close(h) }
            self.handle = nil
            try? FileManager.default.removeItem(at: self.dir)
            try self.openNow()
        }
    }

    // ---- on the queue (for `run` and `batch`)

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p = p else { return "{}" }
        defer { lc_free(p) }
        return String(cString: p)
    }

    private func parse(_ s: String) throws -> [String: Any] {
        let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
        if (o["ok"] as? Bool) == false { throw EngineError(message: o["error"] as? String ?? "errore") }
        return o
    }

    func execNow(_ command: String, _ params: [String: Any] = [:]) throws -> Any? {
        let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        let p = String(data: data, encoding: .utf8) ?? "{}"
        let s = command.withCString { c in p.withCString { q in take(lc_execute(handle, c, q)) } }
        return try parse(s)["result"]
    }

    private func picture(_ json: String) throws -> Rendered {
        try picture(object: parse(json))
    }

    private func picture(object o: [String: Any]) throws -> Rendered {
        let w = Int(int64(o["width"]))
        let h = Int(int64(o["height"]))
        guard w > 0, h > 0, w * h * 4 <= capacity else { throw EngineError(message: "immagine vuota") }
        let data = Data(bytes: buffer, count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { throw EngineError(message: "immagine non valida") }
        return Rendered(image: image, millis: double(o["ms"]))
    }

    private func clamp(_ v: Int) -> UInt32 { UInt32(max(8, min(maxEdge, v))) }

    /// Room for a `w × h` picture (on the queue).
    private func room(_ w: Int, _ h: Int) {
        let need = Int(clamp(w)) * Int(clamp(h)) * 4
        guard need > capacity else { return }
        buffer.deallocate()
        capacity = need
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    func renderNow(_ photo: Int64, _ w: Int, _ h: Int, draft: Bool) throws -> Rendered {
        room(w, h)
        return try picture(take(lc_render(handle, UInt64(photo), clamp(w), clamp(h), draft, buffer, capacity)))
    }

    // ---- what the app calls

    func exec(_ command: String, _ params: [String: Any] = [:]) async throws -> Any? {
        try await run { try self.execNow(command, params) }
    }

    func object(_ command: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try await exec(command, params) as? [String: Any] ?? [:]
    }

    func array(_ command: String, _ params: [String: Any] = [:]) async throws -> [[String: Any]] {
        try await exec(command, params) as? [[String: Any]] ?? []
    }

    /// Several things in one turn of the queue (nothing squeezes in between).
    func batch<T>(_ work: @escaping (Engine) throws -> T) async throws -> T {
        try await run { try work(self) }
    }

    func render(_ photo: Int64, _ w: Int, _ h: Int, draft: Bool = false) async throws -> Rendered {
        try await run { try self.renderNow(photo, w, h, draft: draft) }
    }

    func renderBefore(_ photo: Int64, _ w: Int, _ h: Int) async throws -> Rendered {
        try await run {
            self.room(w, h)
            return try self.picture(self.take(lc_render_before(self.handle, UInt64(photo), self.clamp(w), self.clamp(h), self.buffer, self.capacity)))
        }
    }

    /// One window (`x, y, w, h` pixels) of the photo as drawn whole at `fullW × fullH`; past the
    /// photo's own resolution the engine develops it at 100 %. `rect`: the window it developed,
    /// 0…1 of the whole.
    func renderRegion(_ photo: Int64, fullW: Int, fullH: Int, x: Int, y: Int, w: Int, h: Int) async throws -> (Rendered, CGRect) {
        try await run {
            self.room(w, h)
            let o = try self.parse(self.take(lc_render_region(self.handle, UInt64(photo), UInt32(fullW), UInt32(fullH), UInt32(x), UInt32(y), UInt32(w), UInt32(h), self.buffer, self.capacity)))
            let r = try self.picture(object: o)
            var rect = CGRect(x: CGFloat(x) / CGFloat(fullW), y: CGFloat(y) / CGFloat(fullH), width: CGFloat(w) / CGFloat(fullW), height: CGFloat(h) / CGFloat(fullH))
            if let win = o["window"] as? [Any], win.count == 4, let full = o["full"] as? [Any], full.count == 2 {
                let fw = CGFloat(max(1, double(full[0]))), fh = CGFloat(max(1, double(full[1])))
                rect = CGRect(x: CGFloat(double(win[0])) / fw, y: CGFloat(double(win[1])) / fh, width: CGFloat(double(win[2])) / fw, height: CGFloat(double(win[3])) / fh)
            }
            return (r, rect)
        }
    }

    /// Where layer `mask` acts, white on black, fitted into `w × h`.
    func renderMask(_ photo: Int64, mask: Int, _ w: Int, _ h: Int) async throws -> Rendered {
        try await run {
            self.room(w, h)
            return try self.picture(self.take(lc_render_mask(self.handle, UInt64(photo), UInt64(max(0, mask)), self.clamp(w), self.clamp(h), self.buffer, self.capacity)))
        }
    }

    /// The photo without its crop and straightening (the crop tool draws the crop over it).
    func renderUncropped(_ photo: Int64, _ w: Int, _ h: Int, draft: Bool = false) async throws -> Rendered {
        try await run {
            self.room(w, h)
            return try self.picture(self.take(lc_render_uncropped(self.handle, UInt64(photo), self.clamp(w), self.clamp(h), draft, self.buffer, self.capacity)))
        }
    }

    func thumb(_ photo: Int64, edge: Int) async throws -> Rendered {
        try await run { try self.picture(self.take(lc_thumb(self.handle, UInt64(photo), UInt32(edge), self.buffer, self.capacity))) }
    }

    /// The photo with `preset` over its edits (`amount` in percent), long edge `edge` ≤ 512.
    func variant(_ photo: Int64, preset: String, amount: Int = 100, edge: Int = 220) async throws -> Rendered {
        try await run {
            try self.picture(preset.withCString { p in self.take(lc_render_variant(self.handle, UInt64(photo), p, Int32(amount), UInt32(edge), self.buffer, self.capacity)) })
        }
    }

    /// The photo as a file: `params` the engine's export options (format, quality, bitDepth, longEdge…).
    func export(_ photo: Int64, to url: URL, params: [String: Any]) async throws {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        _ = try await run {
            try self.parse(url.path.withCString { p in json.withCString { q in self.take(lc_export(self.handle, UInt64(photo), p, q)) } })
        }
    }

    func exportJpeg(_ photo: Int64, to url: URL, quality: Int, longEdge: Int) async throws {
        _ = try await run {
            try self.parse(url.path.withCString { self.take(lc_export_jpeg(self.handle, UInt64(photo), $0, Int32(quality), UInt32(longEdge))) })
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String { self[k] as? String ?? "" }
}
