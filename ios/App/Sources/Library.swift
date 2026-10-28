import CoreGraphics
import Foundation
import ImageIO

enum Stage {
    /// On its way from the camera (nothing to show yet).
    case arriving
    /// Its camera JPEG is on screen, the raw still on its way.
    case preview
    /// Here whole (raw, or the camera's JPEG).
    case ready
    case failed
}

/// One shot of the session.
struct Shot: Identifiable {
    /// Its name without extension (`DSC09301`): the same for the raw and its preview.
    let key: String
    var name: String
    /// LightCraft's photo for it (the raw once here; 0 before).
    var photo: Int64 = 0
    var stage: Stage = .arriving
    var progress: Double = 0
    var thumb: CGImage?
    /// Width / height as shown.
    var aspect: Double = 1.5
    /// Bumped when its look changes (edits, preset, the raw replacing the preview).
    var revision = 0
    var id: String { key }
}

/// A lock for async code (a slider drag and an import both rely on LightCraft's active photo).
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

/// Long edge of a camera preview as LightCraft gets it.
let shrinkEdge = 2400

func stem(_ name: String) -> String {
    let n = name.drop(while: { $0 == "~" })
    return n.split(separator: ".").first.map(String.init) ?? String(n)
}

/// Shrinks a picture to a thumbnail (`edge` long).
func scaled(_ image: CGImage, edge: Int) -> CGImage {
    let s = Double(edge) / Double(max(image.width, image.height))
    guard s < 1 else { return image }
    let w = max(1, Int(Double(image.width) * s))
    let h = max(1, Int(Double(image.height) * s))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? image
}

/// The session's shots in LightCraft's library: the camera's JPEG of each one developed at once (by a
/// second LightCraft, with the tether preset), then the raw imported in its place.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var shots: [Shot] = []
    let engine: Engine
    let previews: Engine
    let editLock = AsyncLock()
    var settings: () -> Settings = { Settings() }
    /// The previews' engine has the user's presets under ids of its own: main id → its id.
    var previewPresetIds: [String: String] = [:]
    /// The size the viewer shows a shot at (pixels).
    var screen = (w: 2560, h: 2560)
    /// A preview developed with the tether preset (the viewer shows it until the raw is ready).
    var onPreviewPicture: ((String, CGImage) -> Void)?
    /// A shot got its first picture (the viewer may go to it).
    var onArrival: ((String) -> Void)?
    private var restoring = false
    private var previewChain: Task<Void, Never>?
    private var importChain: Task<Void, Never>?
    static let thumbEdge = 320
    static let preview: Int64 = -1

    init(engine: Engine, previews: Engine) {
        self.engine = engine
        self.previews = previews
    }

    func shot(_ key: String) -> Shot? { shots.first { $0.key == key } }

    private func edit(_ key: String, _ f: (inout Shot) -> Void) {
        guard let i = shots.firstIndex(where: { $0.key == key }) else { return }
        f(&shots[i])
    }

    // ---- the camera's events

    func handle(_ e: [String: Any]) {
        let name = e.str("name")
        let key = stem(name)
        switch e.str("type") {
        case "started":
            if shot(key) == nil { shots.append(Shot(key: key, name: name)) }
        case "progress":
            let size = double(e["size"])
            edit(key) { $0.progress = size > 0 ? double(e["got"]) / size : 0 }
        case "preview":
            let url = URL(fileURLWithPath: e.str("path"))
            let prev = previewChain
            previewChain = Task { await prev?.value; await self.importPreview(key, url) }
        case "shot":
            let url = URL(fileURLWithPath: e.str("path"))
            let prev = importChain
            importChain = Task { await prev?.value; await self.importWhole(key, url) }
        case "failed":
            edit(key) { if $0.photo == 0 && $0.stage == .arriving { $0.stage = .failed } }
        default: break
        }
    }

    // ---- into LightCraft

    private func importFile(_ url: URL, into e: Engine) async throws -> Int64 {
        let r = try await e.object("library.import", ["paths": [url.path]])
        for k in ["imported", "restored"] {
            if let a = r[k] as? [Any], let first = a.first, int64(first) > 0 { return int64(first) }
        }
        if let d = (r["duplicates"] as? [[String: Any]])?.first, int64(d["existing"]) > 0 { return int64(d["existing"]) }
        throw EngineError(message: "\(url.lastPathComponent) non importato")
    }

    /// The tether preset (if any) on `photo`.
    private func look(_ photo: Int64, on e: Engine) async {
        let s = settings()
        guard !s.preset.isEmpty else { return }
        let id = e === engine ? s.preset : previewPresetIds[s.preset] ?? s.preset
        _ = try? await e.exec("preset.apply", ["id": id, "amount": s.presetAmount, "ids": [photo]])
    }

    private func importPreview(_ key: String, _ url: URL) async {
        do {
            let small = await Task.detached { Library.shrink(url) }.value
            let id = try await importFile(small, into: previews)
            await look(id, on: previews)
            let pic = try await previews.render(id, screen.w, screen.h).image
            if shot(key)?.stage == .ready { return } // the raw was quicker
            edit(key) {
                $0.stage = .preview
                $0.aspect = Double(pic.width) / Double(pic.height)
            }
            onPreviewPicture?(key, pic)
            _ = try? await previews.exec("photo.deletePermanently", ["ids": [id]])
        } catch {
            NSLog("lightcraft: preview of \(key): \(error)")
        }
    }

    private func importWhole(_ key: String, _ url: URL) async {
        await editLock.lock()
        do {
            let id = try await importFile(url, into: engine)
            await look(id, on: engine)
            let isJpeg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
            if shot(key) == nil { shots.append(Shot(key: key, name: url.lastPathComponent)) }
            let hadThumb = shot(key)?.thumb != nil
            edit(key) {
                $0.name = url.lastPathComponent
                $0.photo = id
                $0.stage = .ready
                $0.progress = 1
                $0.revision += 1
            }
            await editLock.unlock()
            // a raw keeps its preview's thumbnail until the viewer develops it, which gives the new one
            if !hadThumb || isJpeg { await thumb(key) }
        } catch {
            await editLock.unlock()
            NSLog("lightcraft: \(key): \(error)")
            edit(key) { if $0.photo == 0 { $0.stage = .failed } }
        }
    }

    func thumb(_ key: String) async {
        guard let s = shot(key), s.photo != 0 else { return }
        guard let r = try? await engine.thumb(s.photo, edge: Library.thumbEdge) else { return }
        let first = shot(key)?.thumb == nil
        edit(key) {
            if $0.photo == s.photo {
                $0.thumb = r.image
                $0.aspect = Double(r.image.width) / Double(r.image.height)
            }
        }
        if first && !restoring { onArrival?(key) }
    }

    /// A picture of the shot as it looks now: its thumbnail is cut from it.
    func developed(_ key: String, photo: Int64, _ image: CGImage) {
        guard let s = shot(key), s.photo == photo || (photo == Library.preview && s.photo == 0) else { return }
        let first = s.thumb == nil
        let t = scaled(image, edge: Library.thumbEdge)
        edit(key) {
            $0.thumb = t
            $0.aspect = Double(t.width) / Double(t.height)
        }
        if first && !restoring { onArrival?(key) }
    }

    /// The photo was edited: its look changed.
    func edited(_ key: String) { edit(key) { $0.revision += 1 } }

    /// The shots already in the library (a session goes on after a restart).
    func restore() async {
        restoring = true
        defer { restoring = false }
        guard let r = try? await engine.object("catalog.query", ["limit": 100000]), let photos = r["photos"] as? [[String: Any]] else { return }
        var byKey: [String: [String: Any]] = [:]
        var order: [String] = []
        for p in photos.filter({ ($0["deleted"] as? Bool) != true }).sorted(by: { int64($0["id"]) < int64($1["id"]) }) {
            let key = stem(p.str("fileName"))
            if byKey[key] == nil { order.append(key) }
            if byKey[key] == nil || p.str("kind") == "raw" { byKey[key] = p }
        }
        shots = order.compactMap { key in
            guard let p = byKey[key] else { return nil }
            let w = double(p["width"]), h = double(p["height"])
            return Shot(key: key, name: p.str("fileName"), photo: int64(p["id"]), stage: .ready, progress: 1, aspect: h > 0 ? w / h : 1.5)
        }
        for s in shots { await thumb(s.key) }
    }

    func remove(_ keys: Set<String>) async {
        let ids = shots.filter { keys.contains($0.key) && $0.photo != 0 }.map(\.photo)
        if !ids.isEmpty { _ = try? await engine.exec("photo.deletePermanently", ["ids": ids]) }
        shots.removeAll { keys.contains($0.key) }
    }

    /// The camera's 7008×4672 JPEG cut to the size a screen shows (long edge 2400), its orientation
    /// kept: LightCraft develops it in a fraction of the time, the raw brings the detail a moment later.
    nonisolated static func shrink(_ url: URL) -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return url }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if max(w, h) <= shrinkEdge * 3 / 2 { return url }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: shrinkEdge,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return url }
        let out = url.deletingPathExtension().appendingPathExtension("screen.jpg")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.jpeg" as CFString, 1, nil) else { return url }
        var meta: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.94]
        if let o = props?[kCGImagePropertyOrientation] { meta[kCGImagePropertyOrientation] = o }
        CGImageDestinationAddImage(dest, small, meta as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out : url
    }
}
