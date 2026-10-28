import Photos
import SwiftUI

enum Screen { case connect, workspace, browser }

struct ExportState {
    let total: Int
    var done = 0
    var saved = 0
    var finished = false
    var message = ""
}

/// What an export writes: Capture One's process recipe.
struct ExportRecipe {
    enum Format { case jpeg, tiff8, tiff16, lightroom }
    var format: Format
    var quality: Int
    var edge: Int
    var toPhotos: Bool

    var ext: String {
        switch format {
        case .jpeg: return "jpg"
        case .tiff8, .tiff16: return "tif"
        case .lightroom: return "xmp"
        }
    }

    /// The engine's export options.
    var params: [String: Any] {
        var p: [String: Any]
        switch format {
        case .jpeg: p = ["format": "jpg", "quality": quality]
        case .tiff8: p = ["format": "tiff", "bitDepth": 8, "tiffCompression": "lzw"]
        case .tiff16: p = ["format": "tiff", "bitDepth": 16, "tiffCompression": "zip", "colorSpace": "adobeRGB"]
        case .lightroom: p = [:]
        }
        if edge > 0 { p["longEdge"] = edge }
        return p
    }
}

/// A thumbnail opening into the viewer: the picture and where it starts from (screen points).
struct Hero: Identifiable {
    let id = UUID()
    let image: CGImage
    let from: CGRect
}

/// Everything the app holds: settings, the two LightCraft engines, the shots, the viewer, the editor
/// and the camera link. Views observe the parts they show (the library, the link, the editor), not
/// this: a shot arriving redraws the filmstrip, not the tools.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings { didSet { if settings != oldValue { settings.save() } } }
    @Published var screen: Screen
    @Published var current: String? { didSet { if current != oldValue { currentChanged() } } }
    @Published var selection = Set<String>()
    @Published private(set) var ready = false
    @Published private(set) var problem: String?
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var profiles: [Profile] = []
    @Published var export: ExportState?
    @Published var note: String?
    @Published var toolsShown = true
    /// The workspace's toolbar and tools (a tap on the photo hides and shows them).
    @Published var chrome = true
    @Published var openSettings = false
    @Published var hero: Hero?
    @Published private(set) var renderer = ""
    /// Where the viewer is on screen (the zoom of a thumbnail ends there), and how many times it was
    /// measured (the zoom waits for a fresh one).
    var viewerFrame: CGRect = .zero
    var viewerMeasures = 0

    let library: Library
    let loupe: Loupe
    let editor: EditorModel
    let tether = TetherLink()
    private let engine: Engine
    private let previews: Engine
    private let shotsDir: URL
    private var noteTask: Task<Void, Never>?
    private var pendingFollow: String?

    init() {
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let previewsDir = docs.appendingPathComponent("previews")
        try? FileManager.default.removeItem(at: previewsDir)
        let s = Settings.load()
        // the GPU (Metal) unless the settings say the CPU: read by the engines when they open
        if !s.gpu { setenv("LIGHTCRAFT_GPU", "0", 1) }
        engine = Engine(dir: docs.appendingPathComponent("library"), nice: 4)
        previews = Engine(dir: previewsDir.appendingPathComponent("library"), previews: true, maxEdge: 2560)
        shotsDir = docs.appendingPathComponent("shots")
        settings = s
        screen = s.login.complete ? .browser : .connect
        library = Library(engine: engine, previews: previews)
        loupe = Loupe(engine: engine)
        editor = EditorModel(engine: engine, loupe: loupe, library: library)
        if UserDefaults.standard.string(forKey: "screen") == "workspace" { screen = .workspace }
        wire()
        Task { await boot() }
        if s.login.complete { connect() }
    }

    private func wire() {
        library.settings = { [weak self] in self?.settings ?? Settings() }
        library.onPreviewPicture = { [weak self] key, image in
            guard let self = self else { return }
            let rev = self.library.shot(key)?.revision ?? 0
            let (w, h) = self.library.screen
            self.loupe.put(Pic(key: key, photo: Library.preview, revision: rev, boxW: w, boxH: h, image: image, draft: false))
        }
        library.onArrival = { [weak self] key in self?.arrived(key) }
        library.onReady = { [weak self] key in
            guard let self = self, key == self.current else { return }
            self.editor.open(key)
        }
        loupe.previewDue = { [weak self] in
            guard let t = self?.tether.transfer else { return false }
            return t.name.lowercased().hasSuffix(".arw") && (self?.library.shot(stem(t.name))?.stage ?? .arriving) == .arriving
        }
        loupe.onPicture = { [weak self] p in
            self?.library.developed(p.key, photo: p.photo, p.image)
            self?.editor.pictureShown(p)
        }
        editor.onEdited = { [weak self] key in self?.library.edited(key) }
        loupe.intercept = { [weak self] p in self?.editor.intercept(p) ?? false }
        editor.presetsChanged = { [weak self] in await self?.presetsChanged() }
        editor.onIdle = { [weak self] in
            guard let self = self, let k = self.pendingFollow else { return }
            self.pendingFollow = nil
            self.current = k
        }
        tether.onEvent = { [weak self] e in
            guard let self = self else { return }
            if e.str("type") == "fingerprint" {
                self.settings.login.fingerprint = e.str("value")
            } else {
                self.library.handle(e)
            }
            self.loupe.pump()
        }
    }

    private func boot() async {
        do {
            try await engine.open()
            try await previews.open()
            _ = try? await engine.exec("app.memoryBudget", ["mb": 1536])
            let list = try await engine.array("develop.controls")
            editor.store.setControls(Controls.from(list))
            presets = try await presetsOf(engine)
            profiles = ((try? await engine.array("profiles.list")) ?? []).map { Profile(id: $0.str("id"), name: $0.str("name"), group: $0.str("group")) }
            if let g = try? await engine.object("app.gpu") {
                let on = (g["enabled"] as? Bool) == true && (g["available"] as? Bool) == true
                renderer = on ? "GPU · \(g.str("adapter"))" : "CPU" + (g.str("reason").isEmpty ? "" : " (\(g.str("reason")))")
                NSLog("lightcraft renderer: \(renderer)")
            }
            DepthEstimator.shared.preload()
            await syncPreviews()
            await library.restore()
            ready = true
            if current == nil { current = library.shots.last?.key }
            if UserDefaults.standard.bool(forKey: "benchmark") { Task { await benchmark() } }
            if UserDefaults.standard.bool(forKey: "exportTest") { Task { await exportTest() } }
            if let t = UserDefaults.standard.string(forKey: "testTool") { Task { await testTool(t) } }
            if UserDefaults.standard.bool(forKey: "stress") { Task { await stress() } }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Tests (`-stress YES`): every heavy path in a row, at a finger's pace or faster; the log says
    /// how far it got (CI fails without "done").
    private func stress() async {
        func log(_ s: String) { NSLog("lightcraft stress: \(s)") }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        for _ in 0..<300 {
            if editor.photo != 0 { break }
            await wait(0.1)
        }
        guard editor.photo != 0 else { log("no photo"); return }
        await wait(2)
        let st = editor.store
        st.onBegin?("Esposizione")
        for i in 0..<60 {
            st.userSet("light.exposure", Double(i % 20) * 0.1, from: nil)
            await wait(0.008)
        }
        st.onEnd?()
        await wait(1)
        log("sliders ok")
        editor.begin("Curva")
        for i in 0..<40 {
            editor.curve(.master, [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5 + Double(i % 10) * 0.01), CGPoint(x: 1, y: 1)])
            await wait(0.01)
        }
        editor.end()
        await wait(1)
        log("curve ok")
        let full = CGSize(width: 6000, height: 4000)
        for (i, n) in [CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), CGRect(x: 0.6, y: 0.5, width: 0.1, height: 0.1), CGRect(x: 0, y: 0, width: 0.06, height: 0.06)].enumerated() {
            var got = false
            renderDetail(window: n, full: full) { _, _ in got = true }
            for _ in 0..<60 {
                if got { break }
                await wait(0.1)
            }
            log("region \(i) \(got ? "ok" : "none")")
        }
        var lb = editor.lensBlur
        lb.enabled = true
        lb.amount = 70
        editor.setLensBlur(lb, live: false)
        editor.commitLensBlur()
        await wait(4)
        for i in 0..<20 {
            var l = editor.lensBlur
            l.amount = Double(20 + i * 3)
            editor.setLensBlur(l, live: true)
            await wait(0.03)
        }
        editor.commitLensBlur()
        await wait(2)
        log("lens blur ok (\(editor.depthSource))")
        lb = editor.lensBlur
        lb.enabled = false
        editor.setLensBlur(lb, live: false)
        editor.commitLensBlur()
        await wait(1)
        editor.enterCrop()
        await wait(1)
        editor.begin("Ritaglio")
        for i in 0..<20 {
            editor.cropDrag("topLeft", from: CGPoint(x: 0, y: 0), to: CGPoint(x: Double(i) * 0.005, y: Double(i) * 0.004), start: CGRect(x: 0, y: 0, width: 1, height: 1))
            await wait(0.02)
        }
        editor.end()
        editor.exitCrop()
        await wait(1)
        log("crop ok")
        editor.addMask("brush")
        await wait(1)
        editor.stroke((0..<40).map { CGPoint(x: 0.3 + Double($0) * 0.005, y: 0.5) }, pressure: [Float](repeating: 0.7, count: 40))
        await wait(1)
        editor.localStore.onBegin?("Esposizione")
        for i in 0..<20 {
            editor.localStore.userSet("local.exposure", Double(i) * 0.05, from: nil)
            await wait(0.02)
        }
        editor.localStore.onEnd?()
        await wait(1)
        editor.addMask("radial")
        await wait(1.5)
        if let id = editor.selectedMask, let m = editor.masks.first(where: { $0.id == id }) {
            editor.begin("Maschera")
            for i in 0..<15 {
                var s = m.shape
                s["rx"] = 0.1 + Double(i) * 0.01
                editor.updateShape(id, s)
                await wait(0.03)
            }
            editor.end()
        }
        await wait(1)
        editor.addMask("linear")
        await wait(1)
        editor.addMask("luminanceRange")
        await wait(1)
        for m in editor.masks { editor.deleteMask(m.id) }
        await wait(1.5)
        log("layers ok")
        for i in 0..<4 {
            editor.addSpot(CGPoint(x: 0.2 + Double(i) * 0.15, y: 0.4))
            await wait(0.5)
        }
        log("spots ok (\(editor.spots.count))")
        editor.run("spot.findDust")
        await wait(6)
        log("dust ok (\(editor.spots.count) spots)")
        for p in presets.prefix(6) {
            editor.applyPreset(p.id, amount: 100)
            await wait(0.7)
        }
        log("styles ok")
        for _ in 0..<6 {
            editor.undo()
            await wait(0.3)
        }
        for _ in 0..<3 {
            editor.redo()
            await wait(0.3)
        }
        log("history ok")
        for _ in 0..<4 {
            step(-1)
            await wait(0.6)
            step(1)
            await wait(0.6)
        }
        log("paging ok")
        editor.reset()
        await wait(2)
        log("done")
    }

    /// Tests (`-testTool crop|radial|brush|spots`): a cursor tool on, for the screenshots.
    private func testTool(_ t: String) async {
        for _ in 0..<200 {
            if editor.photo != 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        switch t {
        case "crop":
            editor.run("crop.aspect", ["aspect": "4x5"])
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            editor.enterCrop()
        case "radial", "linear", "brush":
            editor.addMask(t)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            editor.localStore.userSet("local.exposure", 1.2, from: nil)
        case "lensblur":
            var s = editor.lensBlur
            s.enabled = true
            s.amount = 80
            editor.setLensBlur(s, live: false)
            editor.commitLensBlur()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            NSLog("lightcraft lensblur: depth from \(editor.depthSource)")
        case "spots":
            editor.cursorTool = .spot
            editor.addSpot(CGPoint(x: 0.3, y: 0.4))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            editor.addSpot(CGPoint(x: 0.6, y: 0.55))
        default: break
        }
    }

    /// Tests (`-exportTest YES`): the shot on screen exported every way, the results in the log.
    private func exportTest() async {
        for _ in 0..<200 {
            if let k = current, let p = library.shot(k)?.photo, p != 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let k = current else { return }
        let recipes = [
            ExportRecipe(format: .jpeg, quality: 90, edge: 0, toPhotos: true),
            ExportRecipe(format: .tiff16, quality: 90, edge: 0, toPhotos: true),
            ExportRecipe(format: .tiff8, quality: 90, edge: 2048, toPhotos: false),
            ExportRecipe(format: .lightroom, quality: 90, edge: 0, toPhotos: false),
        ]
        for r in recipes {
            export = nil
            let t = Date()
            exportShots([k], recipe: r)
            for _ in 0..<900 {
                if export?.finished == true { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            NSLog("lightcraft exporttest \(r.ext) \(r.toPhotos ? "photos" : "files"): saved \(export?.saved ?? -1) in \(Int(Date().timeIntervalSince(t) * 1000)) ms \(export?.message ?? "")")
        }
        export = nil
    }

    /// Tests (`-benchmark YES`): how long a slider step (a draft) and a full picture take at the
    /// viewer's size, in the log.
    private func benchmark() async {
        for _ in 0..<200 {
            if let k = current, let p = library.shot(k)?.photo, p != 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let k = current, let p = library.shot(k)?.photo, p != 0 else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let (w, h) = editor.viewport
        var drafts: [Double] = []
        for i in 0..<14 {
            let t = Date()
            _ = try? await engine.batch { e -> Rendered in
                _ = try e.execNow("library.select", ["ids": [p], "active": p])
                _ = try e.execNow("develop.set", ["ids": [p], "values": ["light.exposure": Double(i % 4) * 0.1]])
                return try e.renderNow(p, w, h, draft: true)
            }
            drafts.append(Date().timeIntervalSince(t) * 1000)
        }
        let t = Date()
        _ = try? await engine.render(p, w, h, draft: false)
        let full = Date().timeIntervalSince(t) * 1000
        let steady = drafts.dropFirst(2).sorted()
        NSLog("lightcraft bench: \(w)x\(h) draft median \(Int(steady[steady.count / 2])) ms (first \(Int(drafts[0])) ms), full \(Int(full)) ms, \(renderer)")
    }

    // ---- the camera

    func connect() {
        tether.start(settings, saveDir: shotsDir)
    }

    func disconnect() { tether.stop() }

    func connect(with login: CameraLogin) {
        var l = login
        // another camera (or login): its key is seen afresh
        if settings.login.ssid != l.ssid || settings.login.user != l.user { l.fingerprint = "" } else { l.fingerprint = settings.login.fingerprint }
        settings.login = l
        screen = .browser
        connect()
    }

    func setRaw(_ raw: Bool) {
        settings.raw = raw
        tether.setRaw(raw)
    }

    private func arrived(_ key: String) {
        if current == nil { current = key; return }
        guard settings.followNewest, screen == .workspace else { return }
        // a finger on a slider keeps the photo it is changing: the new shot comes when it lifts
        if editor.busy {
            pendingFollow = key
            return
        }
        Task {
            // go to it once its full picture is ready (rendered ahead as the next one), 2 s at most
            for _ in 0..<40 {
                if loupe.pics[key] != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if editor.busy { pendingFollow = key } else { current = key }
        }
    }

    private func currentChanged() {
        if let k = current { editor.open(k) } else { editor.close() }
    }

    /// A shot from the browser into the viewer, zooming out of its thumbnail (`from`, screen points).
    func open(_ key: String, from: CGRect?) {
        current = key
        if let f = from, let img = loupe.pics[key]?.image ?? library.shot(key)?.thumb {
            hero = Hero(image: img, from: f)
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { screen = .workspace }
    }

    /// A sharp window (`n`, 0…1 of the picture) of the shot on screen, as drawn whole at `full`
    /// pixels: the zoomed-in viewer. With the lens blur when it is on.
    func renderDetail(window n: CGRect, full: CGSize, done: @escaping (CGImage, CGRect) -> Void) {
        guard let k = current, let p = library.shot(k)?.photo, p != 0 else { return }
        let fw = Int(full.width), fh = Int(full.height)
        guard fw > 16, fh > 16 else { return }
        let x = max(0, min(fw - 1, Int((n.minX * full.width).rounded(.down))))
        let y = max(0, min(fh - 1, Int((n.minY * full.height).rounded(.down))))
        let w = max(1, min(fw - x, Int((n.width * full.width).rounded(.up))))
        let h = max(1, min(fh - y, Int((n.height * full.height).rounded(.up))))
        // a screen's worth at most (the window is what is on screen)
        guard w * h <= 3200 * 3200 else { return }
        let rect = CGRect(x: CGFloat(x) / full.width, y: CGFloat(y) / full.height, width: CGFloat(w) / full.width, height: CGFloat(h) / full.height)
        Task {
            guard let r = try? await engine.renderRegion(p, fullW: fw, fullH: fh, x: x, y: y, w: w, h: h), current == k else { return }
            let img = await editor.blurDetail(r.image, window: rect, full: full) ?? r.image
            if current == k { done(img, rect) }
        }
    }

    /// The picture of the shot `by` places from the one on screen (for the viewer's paging).
    func neighborPicture(_ by: Int) -> CGImage? {
        let list = library.shots.filter { $0.stage != .failed }
        guard let i = list.firstIndex(where: { $0.key == current }), i + by >= 0, i + by < list.count else { return nil }
        let s = list[i + by]
        return loupe.pics[s.key]?.image ?? s.thumb
    }

    func step(_ by: Int) {
        let list = library.shots.filter { $0.stage != .failed }
        guard let i = list.firstIndex(where: { $0.key == current }) else { return }
        let j = i + by
        if j >= 0 && j < list.count { current = list[j].key }
    }

    func go(_ s: Screen) {
        withAnimation(Motion.quick) { screen = s }
    }

    func say(_ text: String) {
        note = text
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled { note = nil }
        }
    }

    // ---- rating, colour tags, flags

    func rate(_ keys: Set<String>, _ n: Int) {
        Task { await library.rate(keys, n) }
    }

    func tag(_ keys: Set<String>, _ label: ColorTag?) {
        Task { await library.tag(keys, label) }
    }

    func flag(_ keys: Set<String>, _ f: String) {
        Task { await library.flag(keys, f) }
    }

    /// The photos an action is for: the selection in the browser, else the one on screen.
    var targets: Set<String> {
        if screen == .browser && !selection.isEmpty { return selection }
        return current.map { [$0] } ?? []
    }

    // ---- styles (presets)

    private func presetsOf(_ e: Engine) async throws -> [Preset] {
        let all = try await e.array("presets.list").map { Preset(id: $0.str("id"), name: $0.str("name"), group: $0.str("group"), builtin: ($0["builtin"] as? Bool) ?? false) }
        return all.filter { !$0.builtin } + all.filter { $0.builtin }
    }

    /// The previews' engine gets the user's presets too (a fresh library with them imported).
    private func syncPreviews() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("user-presets.lcpreset")
        try? FileManager.default.removeItem(at: file)
        let mine = presets.filter { !$0.builtin }
        var exported = false
        if !mine.isEmpty { exported = (try? await engine.exec("preset.export", ["path": file.path])) != nil && FileManager.default.fileExists(atPath: file.path) }
        try? await previews.reset()
        if exported { _ = try? await previews.exec("preset.import", ["paths": [file.path]]) }
        let theirs = exported ? ((try? await presetsOf(previews)) ?? []).filter { !$0.builtin } : []
        var ids: [String: String] = [:]
        for m in mine { ids[m.id] = theirs.first { $0.name == m.name && $0.group == m.group }?.id ?? m.id }
        library.previewPresetIds = ids
    }

    func presetsChanged() async {
        if let p = try? await presetsOf(engine) { presets = p }
        await syncPreviews()
    }

    /// Lightroom presets (XMP, .lrtemplate, zip, folders) and LightCraft's own.
    func importPresets(_ urls: [URL]) {
        Task {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preset-import")
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var files: [String] = []
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                let dst = dir.appendingPathComponent(u.lastPathComponent)
                if (try? FileManager.default.copyItem(at: u, to: dst)) != nil { files.append(dst.path) }
            }
            guard !files.isEmpty else { say("Nessun file leggibile"); return }
            do {
                let r = try await engine.object("preset.import", ["paths": files])
                let n = (r["imported"] as? [Any])?.count ?? 0
                let fx = (r["effects"] as? [Any])?.count ?? 0
                if n == 0 && fx == 0 { say("Nessuno stile trovato nei file"); return }
                await presetsChanged()
                say(n == 1 ? "1 stile importato" : "\(n) stili importati")
            } catch {
                say("Importazione non riuscita: \(error.localizedDescription)")
            }
        }
    }

    /// Styles as Lightroom presets (XMP), to the share sheet.
    func exportForLightroom(_ ids: [String]?) {
        Task {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Lightroom presets")
            try? FileManager.default.removeItem(at: dir)
            var params: [String: Any] = ["dir": dir.path]
            if let ids = ids { params["ids"] = ids }
            do {
                let r = try await engine.object("preset.exportXmp", params)
                let urls = (r["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
                if urls.isEmpty { say("Nessuno stile da esportare"); return }
                Share.present(urls)
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    func deletePreset(_ p: Preset) {
        Task {
            do {
                _ = try await engine.exec("preset.delete", ["id": p.id])
                if settings.preset == p.id { settings.preset = "" }
                await presetsChanged()
                say("«\(p.name)» eliminato")
            } catch {
                say("Non eliminato: \(error.localizedDescription)")
            }
        }
    }

    /// The style the browser's selection gets.
    func applyStyle(_ id: String, to keys: Set<String>) {
        let ids = library.shots.filter { keys.contains($0.key) && $0.photo != 0 }.map(\.photo)
        guard !ids.isEmpty else { return }
        Task {
            await library.editLock.lock()
            _ = try? await engine.exec("preset.apply", ["id": id, "amount": 100, "ids": ids])
            await library.editLock.unlock()
            for k in keys { library.edited(k) }
            if let c = current, keys.contains(c) { editor.open(c) }
        }
    }

    /// The copied adjustments onto the browser's selection.
    func paste(to keys: Set<String>) {
        let ids = library.shots.filter { keys.contains($0.key) && $0.photo != 0 }.map(\.photo)
        guard !ids.isEmpty else { return }
        Task {
            await library.editLock.lock()
            _ = try? await engine.exec("develop.paste", ["ids": ids])
            await library.editLock.unlock()
            for k in keys { library.edited(k) }
            say(ids.count == 1 ? "Regolazioni applicate" : "Regolazioni applicate a \(ids.count) foto")
        }
    }

    // ---- export, delete

    func toggle(_ key: String) {
        if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
    }

    /// The shots with their edits, as the recipe says: JPEG or TIFF into Photos or to the share sheet
    /// (Files, AirDrop…), or each one's look as a Lightroom preset.
    func exportShots(_ keys: Set<String>, recipe: ExportRecipe) {
        let list = library.shots.filter { keys.contains($0.key) && $0.photo != 0 }
        guard !list.isEmpty, export?.finished != false else { return }
        if recipe.format == .jpeg { settings.exportQuality = recipe.quality }
        settings.exportEdge = recipe.edge
        export = ExportState(total: list.count)
        Task {
            if recipe.toPhotos {
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    export = ExportState(total: list.count, done: list.count, saved: 0, finished: true, message: "Consenti l'accesso a Foto nelle Impostazioni dell'iPad.")
                    return
                }
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            var saved = 0
            var files: [URL] = []
            var failure = ""
            for (i, s) in list.enumerated() {
                export?.done = i
                let url = tmp.appendingPathComponent("\(s.key).\(recipe.ext)")
                do {
                    if recipe.format == .lightroom {
                        let settings = try await engine.object("develop.get", ["id": s.photo])
                        _ = try await engine.exec("preset.xmpFromSettings", ["settings": settings, "name": s.key, "group": "LightCraft", "path": url.path])
                    } else {
                        try await engine.export(s.photo, to: url, params: recipe.params)
                        await blurExport(s.photo, url, quality: recipe.quality)
                    }
                    if recipe.toPhotos {
                        try await AppModel.saveToPhotos(url, name: url.lastPathComponent)
                        try? FileManager.default.removeItem(at: url)
                    } else {
                        files.append(url)
                    }
                    saved += 1
                } catch {
                    failure = error.localizedDescription
                    NSLog("lightcraft export \(s.key): \(error)")
                }
            }
            let message: String
            if saved == 0 {
                message = failure.isEmpty ? "Esportazione non riuscita." : failure
            } else if recipe.toPhotos {
                message = "Le trovi nell'app Foto."
            } else {
                message = "Scegli dove salvarli nel pannello di condivisione."
            }
            export = ExportState(total: list.count, done: list.count, saved: saved, finished: true, message: message)
            NSLog("lightcraft export: \(saved) of \(list.count) saved \(recipe.ext)")
            if !recipe.toPhotos && !files.isEmpty { Share.present(files) }
        }
    }

    /// An exported photo with its lens blur (the engine's pipeline doesn't have one: the app adds it).
    private func blurExport(_ photo: Int64, _ url: URL, quality: Int) async {
        guard let d = try? await engine.object("develop.get", ["id": photo]) else { return }
        let s = LensBlurState.from(d)
        guard s.enabled, let small = try? await engine.render(photo, 1024, 1024).image, let depth = await DepthEstimator.shared.estimate(small) else { return }
        _ = await Task.detached(priority: .userInitiated) { LensBlurRenderer.apply(toFile: url, depth: depth, s, quality: quality) }.value
    }

    /// A file into the Photos library (off the main actor: Photos runs the change block on its own
    /// queue).
    nonisolated static func saveToPhotos(_ url: URL, name: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = name
            req.addResource(with: .photo, fileURL: url, options: opts)
        }
    }

    func delete(_ keys: Set<String>) {
        Task {
            keys.forEach { loupe.forget($0) }
            if let c = current, keys.contains(c) {
                let rest = library.shots.filter { !keys.contains($0.key) && $0.stage != .failed }
                current = rest.last?.key
            }
            await library.remove(keys)
            selection.subtract(keys)
        }
    }
}
