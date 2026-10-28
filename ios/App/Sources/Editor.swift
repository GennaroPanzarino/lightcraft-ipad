import CoreGraphics
import Foundation

enum Tool: String, CaseIterable, Identifiable {
    case presets, white, light, color, hsl, grading, curve, effects, detail
    var id: String { rawValue }
    var label: String {
        ["presets": "Preset", "white": "Bianco", "light": "Luce", "color": "Colore", "hsl": "HSL", "grading": "Grading", "curve": "Curve", "effects": "Effetti", "detail": "Dettagli"][rawValue] ?? rawValue
    }
    var icon: String {
        switch self {
        case .presets: return "sparkles"
        case .white: return "thermometer.sun"
        case .light: return "sun.max"
        case .color: return "drop"
        case .hsl: return "paintpalette"
        case .grading: return "circle.lefthalf.filled"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .effects: return "camera.filters"
        case .detail: return "scope"
        }
    }
}

/// The RGB histogram of a picture (normalised to its tallest bars, the extremes clipped).
struct Histogram {
    let r: [CGFloat]
    let g: [CGFloat]
    let b: [CGFloat]

    static func of(_ image: CGImage) -> Histogram? {
        let w = 256, h = max(1, 256 * image.height / max(1, image.width))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var hr = [Int](repeating: 0, count: 256), hg = hr, hb = hr
        var i = 0
        while i < px.count {
            hr[Int(px[i])] += 1
            hg[Int(px[i + 1])] += 1
            hb[Int(px[i + 2])] += 1
            i += 4
        }
        let all = (hr[2..<254] + hg[2..<254] + hb[2..<254]).sorted()
        let cap = CGFloat(max(1, all[min(all.count - 1, Int(Double(all.count) * 0.995))]))
        func norm(_ a: [Int]) -> [CGFloat] { a.map { min(1, CGFloat($0) / cap) } }
        return Histogram(r: norm(hr), g: norm(hg), b: norm(hb))
    }
}

/// Develop one shot: every change goes to LightCraft in order (one queue), a slider drag as one undo
/// step, drafts while a finger moves and the full render when it lifts.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var key: String = ""
    @Published private(set) var photo: Int64 = 0
    @Published var values: [String: Double] = [:]
    @Published var curves: [Channel: CurvePoints] = [:]
    @Published var bw = false
    @Published var wbMode = "asShot"
    @Published var picking = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var histogram: Histogram?
    /// The preset tried in this run of the editor (and how strongly).
    @Published var preset: String?
    @Published var presetAmount = 100
    @Published private(set) var variants: [String: CGImage] = [:]

    /// The size the photo is shown at (pixels).
    var viewport = (w: 1600, h: 1600)
    var onEdited: ((String) -> Void)?
    var presetsChanged: (() async -> Void)?

    private let engine: Engine
    private let loupe: Loupe
    private let lock: AsyncLock
    private let library: Library

    private enum Op {
        case start(String), end
        case values([String: Double])
        case curve(Channel, CurvePoints)
        case preset(String, Int)
        case undo, redo, reset
        case bw(Bool)
        case wb(String)
        case pick(CGPoint)
        case create(String, [String], (String?) -> Void)
    }

    private var queue: [Op] = []
    private var running = false
    private var held = false
    private var interacting = false
    private var base: [String: Any]?
    private var variantsTask: Task<Void, Never>?

    init(engine: Engine, loupe: Loupe, library: Library) {
        self.engine = engine
        self.loupe = loupe
        self.library = library
        lock = library.editLock
    }

    func open(_ key: String) {
        guard let s = library.shot(key), s.photo != 0 else { return }
        close()
        self.key = key
        photo = s.photo
        values = [:]
        variants = [:]
        histogram = nil
        preset = nil
        Task {
            await refresh()
            await render(draft: false)
        }
    }

    func close() {
        variantsTask?.cancel()
        queue.removeAll()
        if held {
            held = false
            Task { await lock.unlock() }
        }
        interacting = false
        key = ""
        photo = 0
    }

    // ---- what the screen calls

    func start(_ label: String) { send(.start(label)) }
    func end() { send(.end) }

    func set(_ id: String, _ v: Double) {
        values[id] = v
        if id.hasPrefix("wb.") { wbMode = "custom" }
        send(.values([id: v]))
    }

    func curve(_ ch: Channel, _ pts: CurvePoints) {
        curves[ch] = pts
        send(.curve(ch, pts))
    }

    func applyPreset(_ id: String, amount: Int) {
        preset = id
        presetAmount = amount
        send(.preset(id, amount))
    }

    func undo() { send(.undo) }
    func redo() { send(.redo) }
    func reset() { send(.reset) }

    func setBw(_ on: Bool) {
        bw = on
        send(.bw(on))
    }

    func whiteBalance(_ mode: String) {
        wbMode = mode
        picking = false
        send(.wb(mode))
    }

    /// The white balance from a neutral point of the photo (0…1 each way).
    func pickWhite(_ p: CGPoint) {
        picking = false
        wbMode = "custom"
        send(.pick(p))
    }

    func createPreset(name: String, groups: [String], done: @escaping (String?) -> Void) {
        send(.create(name, groups, done))
    }

    /// Thumbnails of the photo with each preset.
    func loadVariants(_ ids: [String]) {
        variantsTask?.cancel()
        let p = photo
        variantsTask = Task {
            for id in [""] + ids {
                if Task.isCancelled || photo != p { break }
                if variants[id] != nil { continue }
                if let r = try? await engine.variant(p, preset: id) {
                    if photo == p { variants[id] = r.image }
                }
            }
        }
    }

    // ---- the queue

    private func send(_ op: Op) {
        if case .values(let v) = op, case .values(let old)? = queue.last {
            queue[queue.count - 1] = .values(old.merging(v) { $1 })
        } else if case .curve = op, case .curve? = queue.last {
            queue[queue.count - 1] = op
        } else {
            queue.append(op)
        }
        guard !running else { return }
        running = true
        Task {
            while !queue.isEmpty {
                let op = queue.removeFirst()
                await perform(op)
            }
            running = false
        }
    }

    private func select() -> [String: Any] { ["ids": [photo]] }

    private func perform(_ op: Op) async {
        let photo = self.photo
        guard photo != 0 else { return }
        do {
            switch op {
            case .start(let label):
                if !held {
                    await lock.lock()
                    held = true
                }
                _ = try await engine.batch { e in
                    _ = try e.execNow("library.select", ["ids": [photo]])
                    _ = try e.execNow("develop.beginInteraction", ["label": label])
                }
                interacting = true
            case .values(let v):
                let (w, h) = viewport
                let draft = interacting
                let r = try await engine.batch { e in
                    _ = try e.execNow("develop.set", ["ids": [photo], "values": v])
                    return try e.renderNow(photo, w, h, draft: draft)
                }
                show(r.image, draft: draft)
                base = nil
                if !draft { await after() }
            case .curve(let ch, let pts):
                let (w, h) = viewport
                let draft = interacting
                let wasHeld = held
                let r = try await engine.batch { e in
                    if !wasHeld { _ = try e.execNow("library.select", ["ids": [photo]]) }
                    _ = try e.execNow("develop.curve", ["channel": ch.rawValue, "points": pts.map { [Double($0.x), Double($0.y)] }])
                    return try e.renderNow(photo, w, h, draft: draft)
                }
                show(r.image, draft: draft)
                base = nil
                if !draft { await after() }
            case .end:
                _ = try? await engine.exec("develop.endInteraction")
                if held {
                    held = false
                    await lock.unlock()
                }
                interacting = false
                await after()
            case .preset(let id, let amount):
                let b: [String: Any]
                if let have = base { b = have } else { b = try await engine.object("develop.get", ["id": photo]); base = b }
                await lock.lock()
                defer { Task { await self.lock.unlock() } }
                _ = try await engine.batch { e in
                    _ = try e.execNow("library.select", ["ids": [photo]])
                    _ = try e.execNow("develop.beginInteraction", ["label": "Preset"])
                    _ = try e.execNow("develop.merge", ["settings": b])
                    _ = try e.execNow("preset.apply", ["id": id, "amount": amount, "ids": [photo]])
                    _ = try e.execNow("develop.endInteraction")
                }
                await refresh(keepVariants: true)
                await after()
            case .undo, .redo, .reset, .bw, .wb, .pick:
                _ = try await engine.batch { e in
                    _ = try e.execNow("library.select", ["ids": [photo]])
                    switch op {
                    case .undo: _ = try e.execNow("history.previous")
                    case .redo: _ = try e.execNow("history.next")
                    case .reset: _ = try e.execNow("develop.reset", ["ids": [photo]])
                    case .bw(let on): _ = try e.execNow("develop.treatment", ["bw": on])
                    case .wb(let mode): _ = try e.execNow("develop.wb", ["mode": mode])
                    case .pick(let p): _ = try e.execNow("develop.wbPick", ["x": Double(p.x), "y": Double(p.y)])
                    default: break
                    }
                }
                base = nil
                if case .bw = op {} else if case .wb = op {} else if case .pick = op {} else { preset = nil }
                await refresh()
                await after()
            case .create(let name, let groups, let done):
                var id: String?
                if let r = try? await engine.batch({ e in
                    _ = try e.execNow("library.select", ["ids": [photo]])
                    return try e.execNow("preset.create", ["name": name, "group": "User Presets", "groups": groups])
                }) as? [String: Any] {
                    id = (r["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
                if id != nil { await presetsChanged?() }
                done(id)
            }
        } catch {
            NSLog("lightcraft editor: \(error)")
            if case .end = op, held {
                held = false
                interacting = false
                await lock.unlock()
            }
        }
    }

    private func show(_ image: CGImage, draft: Bool) {
        let rev = library.shot(key)?.revision ?? 0
        let (w, h) = viewport
        loupe.put(Pic(key: key, photo: photo, revision: rev, boxW: max(w, h), boxH: max(w, h), image: image, draft: draft))
    }

    /// After a change has landed: the full render, the thumbnail, the undo state.
    private func after() async {
        onEdited?(key)
        await render(draft: false)
        await history()
    }

    private func render(draft: Bool) async {
        let (w, h) = viewport
        guard photo != 0, let r = try? await engine.render(photo, w, h, draft: draft) else { return }
        show(r.image, draft: draft)
        if !draft {
            let img = r.image
            histogram = await Task.detached { Histogram.of(img) }.value
        }
    }

    /// The photo's values and curves as LightCraft has them.
    private func refresh(keepVariants: Bool = false) async {
        let photo = self.photo
        guard photo != 0, let got = try? await engine.batch({ e -> ([[String: Any]], [String: Any]) in
            _ = try e.execNow("library.select", ["ids": [photo]])
            let c = try e.execNow("develop.controls") as? [[String: Any]] ?? []
            let d = try e.execNow("develop.get", ["id": photo]) as? [String: Any] ?? [:]
            return (c, d)
        }) else { return }
        let (controls, develop) = got
        values = Controls.values(controls)
        var cs: [Channel: CurvePoints] = [:]
        for ch in Channel.allCases { cs[ch] = curvePoints(develop, ch) }
        curves = cs
        bw = (develop["treatment"] as? String) == "bw"
        wbMode = ((develop["wb"] as? [String: Any])?["mode"] as? String) ?? "asShot"
        if !keepVariants {
            variantsTask?.cancel()
            variants = [:]
        }
        await history()
    }

    private func history() async {
        guard photo != 0, let h = try? await engine.object("history.list", ["id": photo]) else { return }
        let n = (h["history"] as? [Any])?.count ?? 0
        let cursor = Int(int64(h["cursor"] ?? NSNumber(value: n - 1)))
        canUndo = cursor > 0
        canRedo = cursor < n - 1
    }
}
