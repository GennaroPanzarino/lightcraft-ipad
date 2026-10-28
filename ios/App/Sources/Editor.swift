import CoreGraphics
import Foundation

/// A line of the photo's metadata.
struct MetaLine: Identifiable, Equatable {
    let name: String
    let value: String
    var id: String { name }
}

/// Develop the shot on screen: every change goes to LightCraft in order (one queue, the latest slider
/// value wins), a drag as one undo step, drafts while a finger moves and the full render when it
/// lifts. The sliders' values live in `store` (UIKit, no SwiftUI on the way); what the panel shows
/// besides them is published here.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var key: String = ""
    @Published private(set) var photo: Int64 = 0
    @Published private(set) var wbMode = "asShot"
    @Published private(set) var bw = false
    @Published private(set) var profile = ""
    @Published private(set) var lensProfile = false
    @Published private(set) var removeCA = false
    @Published private(set) var upright = "off"
    @Published private(set) var vignetteStyle = "highlightPriority"
    @Published private(set) var cropAspect = ""
    @Published private(set) var disabled: Set<String> = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var history: [String] = []
    @Published private(set) var cursor = 0
    @Published private(set) var meta: [MetaLine] = []
    @Published private(set) var exposureLine = ""
    @Published private(set) var curvesVersion = 0
    @Published var picking = false
    /// The style tried on this photo (and how strongly).
    @Published var preset: String?
    @Published var presetAmount = 100
    @Published private(set) var variants: [String: CGImage] = [:]
    @Published private(set) var hasCopy = false

    let store = DevelopStore()
    private(set) var curves: [Channel: CurvePoints] = [:]
    private(set) var histogram: Histogram?
    private var histogramWatchers: [(owner: () -> AnyObject?, fn: (Histogram?) -> Void)] = []

    /// The size the photo is shown at (pixels).
    var viewport = (w: 1600, h: 1600)
    var onEdited: ((String) -> Void)?
    var presetsChanged: (() async -> Void)?
    /// A gesture ended (a new shot may take the screen now).
    var onIdle: (() -> Void)?
    private(set) var interacting = false

    private let engine: Engine
    private let loupe: Loupe
    private let lock: AsyncLock
    private let library: Library

    private enum Op {
        case begin(String), end
        case values([String: Double])
        case curve(Channel, CurvePoints)
        case preset(String, Int)
        case command(String, [String: Any])
        case create(String, [String], (String?) -> Void)
    }

    private var queue: [Op] = []
    private var running = false
    private var held = false
    private var base: [String: Any]?
    private var variantsTask: Task<Void, Never>?

    init(engine: Engine, loupe: Loupe, library: Library) {
        self.engine = engine
        self.loupe = loupe
        self.library = library
        lock = library.editLock
        store.onBegin = { [weak self] label in self?.send(.begin(label)) }
        store.onChange = { [weak self] id, v in self?.send(.values([id: v])) }
        store.onEnd = { [weak self] in self?.send(.end) }
    }

    var busy: Bool { interacting || running }

    func open(_ key: String) {
        guard let s = library.shot(key), s.photo != 0 else {
            if key != self.key { close() }
            return
        }
        if key == self.key && s.photo == photo { return }
        close()
        self.key = key
        photo = s.photo
        variants = [:]
        preset = nil
        meta = []
        exposureLine = ""
        store.enabled = true
        Task {
            await refresh()
            await loadMeta()
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
        picking = false
        loupe.held = nil
        key = ""
        photo = 0
        store.enabled = false
    }

    // ---- what the panel calls

    func curve(_ ch: Channel, _ pts: CurvePoints) {
        curves[ch] = pts
        send(.curve(ch, pts))
    }

    func begin(_ label: String) { send(.begin(label)) }
    func end() { send(.end) }

    func applyPreset(_ id: String, amount: Int) {
        preset = id
        presetAmount = amount
        send(.preset(id, amount))
    }

    /// An engine command on the photo (white balance, profile, a switch, undo…), then the panel shows
    /// what LightCraft has.
    func run(_ command: String, _ params: [String: Any] = [:]) { send(.command(command, params)) }

    func undo() { run("history.previous") }
    func redo() { run("history.next") }
    func reset() { preset = nil; run("develop.reset", ["ids": [photo]]) }
    func setBw(_ on: Bool) { run("develop.treatment", ["bw": on]) }
    func whiteBalance(_ mode: String) { picking = false; run("develop.wb", ["mode": mode]) }
    func setProfile(_ id: String) { run("develop.profile", ["id": id]) }
    func merge(_ settings: [String: Any], label: String) { run("develop.merge", ["settings": settings, "label": label]) }
    /// A tool's sliders back to their defaults, as one undo step.
    func resetControls(_ ids: [String]) {
        var v: [String: Double] = [:]
        for id in ids { if let c = store.control(id) { v[id] = c.def } }
        guard !v.isEmpty, photo != 0 else { return }
        var values = store.values
        for (k, x) in v { values[k] = x }
        store.load(values)
        send(.begin("Azzera"))
        send(.values(v))
        send(.end)
    }

    func setSection(_ section: String, enabled: Bool) { run("develop.sectionEnabled", ["section": section, "enabled": enabled]) }
    func resetSection(_ section: String) { run("develop.resetSection", ["section": section]) }

    /// The white balance from a neutral point of the photo (0…1 each way).
    func pickWhite(_ p: CGPoint) {
        picking = false
        run("develop.wbPick", ["x": Double(p.x), "y": Double(p.y)])
    }

    func copySettings() {
        guard photo != 0 else { return }
        let p = photo
        Task {
            _ = try? await engine.batch { e in
                _ = try e.execNow("library.select", ["ids": [p], "active": p])
                _ = try e.execNow("develop.copy")
            }
            hasCopy = true
        }
    }

    func pasteSettings() { run("develop.paste", ["ids": [photo]]) }

    func createPreset(name: String, groups: [String], done: @escaping (String?) -> Void) {
        send(.create(name, groups, done))
    }

    /// Thumbnails of the photo with each style.
    func loadVariants(_ ids: [String]) {
        variantsTask?.cancel()
        let p = photo
        variantsTask = Task {
            for id in ids {
                if Task.isCancelled || photo != p { break }
                if variants[id] != nil { continue }
                if let r = try? await engine.variant(p, preset: id, edge: 120) {
                    if photo == p { variants[id] = r.image }
                }
            }
        }
    }

    /// The photo before any edit, for the "before" button.
    func before() async -> CGImage? {
        guard photo != 0 else { return nil }
        let (w, h) = viewport
        return try? await engine.renderBefore(photo, w, h).image
    }

    // ---- the histogram (of the pictures the viewer gets)

    func observeHistogram(owner: AnyObject, _ fn: @escaping (Histogram?) -> Void) {
        histogramWatchers.removeAll { $0.owner() == nil || $0.owner() === owner }
        histogramWatchers.append((owner: { [weak owner] in owner }, fn: fn))
        fn(histogram)
    }

    func pictureShown(_ p: Pic) {
        guard p.key == key, !p.draft else { return }
        let img = p.image
        Task {
            let h = await Task.detached(priority: .utility) { Histogram.of(img) }.value
            guard p.key == key else { return }
            histogram = h
            histogramWatchers.removeAll { $0.owner() == nil }
            for w in histogramWatchers { w.fn(h) }
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
            if !interacting { onIdle?() }
        }
    }

    private func perform(_ op: Op) async {
        let photo = self.photo
        guard photo != 0 else { return }
        do {
            switch op {
            case .begin(let label):
                if !held {
                    await lock.lock()
                    held = true
                }
                loupe.held = key
                _ = try await engine.batch { e in
                    _ = try e.execNow("library.select", ["ids": [photo], "active": photo])
                    _ = try e.execNow("develop.beginInteraction", ["label": label])
                }
                interacting = true
            case .values(let v):
                let (w, h) = viewport
                let draft = interacting
                let wasHeld = held
                loupe.held = key
                let r = try await engine.batch { e -> Rendered in
                    if !wasHeld { _ = try e.execNow("library.select", ["ids": [photo], "active": photo]) }
                    _ = try e.execNow("develop.set", ["ids": [photo], "values": v])
                    return try e.renderNow(photo, w, h, draft: draft)
                }
                base = nil
                if draft { show(r.image, draft: true) } else { await after(r.image) }
            case .curve(let ch, let pts):
                let (w, h) = viewport
                let draft = interacting
                let wasHeld = held
                loupe.held = key
                let r = try await engine.batch { e -> Rendered in
                    if !wasHeld { _ = try e.execNow("library.select", ["ids": [photo], "active": photo]) }
                    _ = try e.execNow("develop.curve", ["channel": ch.rawValue, "points": pts.map { [Double($0.x), Double($0.y)] }])
                    return try e.renderNow(photo, w, h, draft: draft)
                }
                base = nil
                if draft { show(r.image, draft: true) } else { await after(r.image) }
            case .end:
                _ = try? await engine.exec("develop.endInteraction")
                if held {
                    held = false
                    await lock.unlock()
                }
                interacting = false
                await after(nil)
            case .preset(let id, let amount):
                let b: [String: Any]
                if let have = base { b = have } else { b = try await engine.object("develop.get", ["id": photo]); base = b }
                await lock.lock()
                loupe.held = key
                do {
                    _ = try await engine.batch { e in
                        _ = try e.execNow("library.select", ["ids": [photo], "active": photo])
                        _ = try e.execNow("develop.beginInteraction", ["label": "Stile"])
                        _ = try e.execNow("develop.merge", ["settings": b])
                        _ = try e.execNow("preset.apply", ["id": id, "amount": amount, "ids": [photo]])
                        _ = try e.execNow("develop.endInteraction")
                    }
                } catch {
                    await lock.unlock()
                    throw error
                }
                await lock.unlock()
                await refresh(keepVariants: true)
                await after(nil)
            case .command(let name, let params):
                await lock.lock()
                loupe.held = key
                do {
                    _ = try await engine.batch { e in
                        _ = try e.execNow("library.select", ["ids": [photo], "active": photo])
                        _ = try e.execNow(name, params)
                    }
                } catch {
                    await lock.unlock()
                    throw error
                }
                await lock.unlock()
                base = nil
                // undo, reset, paste… leave no style "tried"; a switch or the white balance keep it
                let keepsStyle = ["develop.sectionEnabled", "develop.wb", "develop.wbPick", "develop.profile", "develop.merge", "develop.treatment"].contains(name)
                if !keepsStyle { preset = nil }
                await refresh()
                await after(nil)
            case .create(let name, let groups, let done):
                var id: String?
                if let r = try? await engine.batch({ e -> Any? in
                    _ = try e.execNow("library.select", ["ids": [photo], "active": photo])
                    return try e.execNow("preset.create", ["name": name, "group": "User Presets", "groups": groups])
                }) as? [String: Any] {
                    id = (r["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
                if id != nil { await presetsChanged?() }
                done(id)
            }
        } catch {
            NSLog("lightcraft editor: \(error)")
            if loupe.held == key && !interacting {
                loupe.held = nil
                loupe.pump()
            }
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

    /// After a change has landed: the look changed (thumbnail, browser), the full picture, the undo
    /// state. `image`: a full render already made.
    private func after(_ image: CGImage?) async {
        onEdited?(key)
        if let image = image {
            show(image, draft: false)
        } else {
            let (w, h) = viewport
            if photo != 0, let r = try? await engine.render(photo, w, h, draft: false) { show(r.image, draft: false) }
        }
        if !interacting {
            loupe.held = nil
            loupe.pump()
        }
        await loadHistory()
    }

    /// The photo's values and the rest of its settings, as LightCraft has them.
    private func refresh(keepVariants: Bool = false) async {
        let photo = self.photo
        guard photo != 0, let got = try? await engine.batch({ e -> ([[String: Any]], [String: Any]) in
            _ = try e.execNow("library.select", ["ids": [photo], "active": photo])
            let c = try e.execNow("develop.controls") as? [[String: Any]] ?? []
            let d = try e.execNow("develop.get", ["id": photo]) as? [String: Any] ?? [:]
            return (c, d)
        }) else { return }
        guard photo == self.photo else { return }
        let (controls, d) = got
        store.load(Controls.values(controls))
        var cs: [Channel: CurvePoints] = [:]
        for ch in Channel.allCases { cs[ch] = curvePoints(d, ch) }
        curves = cs
        curvesVersion += 1
        bw = (d["treatment"] as? String) == "bw"
        wbMode = (d["wb"] as? [String: Any])?.str("mode") ?? "asShot"
        profile = (d["profile"] as? [String: Any])?.str("id") ?? ""
        let optics = d["optics"] as? [String: Any] ?? [:]
        lensProfile = (optics["lens_profile"] as? Bool) ?? false
        removeCA = (optics["remove_ca"] as? Bool) ?? false
        upright = (d["geometry"] as? [String: Any])?.str("upright") ?? "off"
        vignetteStyle = (d["vignette"] as? [String: Any])?.str("style") ?? "highlightPriority"
        let aspect = (d["crop"] as? [String: Any])?["aspect"]
        if let a = aspect as? String {
            cropAspect = a
        } else if let wh = aspect as? [Any], wh.count == 2 {
            cropAspect = "\(Int(double(wh[0])))x\(Int(double(wh[1])))"
        } else {
            cropAspect = ""
        }
        disabled = Set((d["disabled_sections"] as? [Any] ?? []).compactMap { $0 as? String })
        if !keepVariants {
            variantsTask?.cancel()
            variants = [:]
        }
        await loadHistory()
    }

    private func loadHistory() async {
        guard photo != 0, let h = try? await engine.object("history.list", ["id": photo]) else { return }
        let list = (h["history"] as? [Any] ?? []).map { item -> String in
            if let s = item as? String { return s }
            if let o = item as? [String: Any] { return o.str("label") }
            return ""
        }
        let n = list.count
        let c = Int(int64(h["cursor"] ?? NSNumber(value: n - 1)))
        history = list
        cursor = c
        canUndo = c > 0
        canRedo = c < n - 1
    }

    /// The EXIF a photographer reads (camera, lens, exposure), from the file.
    private func loadMeta() async {
        let p = photo
        guard p != 0, let m = try? await engine.object("photo.allMetadata", ["id": p]), p == photo else { return }
        var by: [String: String] = [:]
        for t in m["exif"] as? [[String: Any]] ?? [] {
            let n = t.str("tag").isEmpty ? t.str("name") : t.str("tag")
            let v = t["value"].map { "\($0)" } ?? ""
            if by[n] == nil { by[n] = v }
            let name = t.str("name")
            if !name.isEmpty && by[name] == nil { by[name] = v }
        }
        func pick(_ keys: [String]) -> String? {
            for k in keys { if let v = by[k], !v.isEmpty { return v } }
            return nil
        }
        let make = pick(["Make"]) ?? ""
        let model = pick(["Model", "Camera Model Name"]) ?? ""
        let camera = model.lowercased().hasPrefix(make.lowercased()) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        let shutter = pick(["ExposureTime", "Exposure Time"])
        let fnum = pick(["FNumber", "F Number"])
        let iso = pick(["ISO", "ISOSpeedRatings", "PhotographicSensitivity", "ISO Speed Ratings"])
        let focal = pick(["FocalLength", "Focal Length"])
        var lines: [MetaLine] = []
        func add(_ n: String, _ v: String?) { if let v = v, !v.isEmpty { lines.append(MetaLine(name: n, value: v)) } }
        add("Fotocamera", camera.isEmpty ? nil : camera)
        add("Obiettivo", pick(["LensModel", "Lens Model", "Lens"]))
        add("Tempo", shutter)
        add("Diaframma", fnum.map { $0.hasPrefix("f") ? $0 : "f/\($0)" })
        add("ISO", iso)
        add("Focale", focal)
        add("Scattata", pick(["DateTimeOriginal", "Date/Time Original"]))
        add("File", library.shot(key)?.name)
        meta = lines
        exposureLine = [iso.map { "ISO \($0)" }, shutter, fnum.map { $0.hasPrefix("f") ? $0 : "f/\($0)" }, focal].compactMap { $0 }.joined(separator: "  ·  ")
    }
}
