import Photos
import SwiftUI
import UIKit
import os

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

/// A photo flying between its tile in the library and the viewer: the picture and where it starts
/// from (screen points); `back`: from the viewer into the library.
struct Hero: Identifiable {
    let id = UUID()
    let key: String
    let image: CGImage
    let from: CGRect
    let back: Bool
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
    /// Photos being brought in (from Photos, Files, a drop): how many are in, of how many.
    @Published var importing: (done: Int, total: Int)?
    @Published var note: String?
    @Published var toolsShown = true
    /// The workspace's toolbar and tools (a tap on the photo hides and shows them).
    @Published var chrome = true
    @Published var openSettings = false
    @Published var hero: Hero?
    /// The flight under way: the screen it leaves faded, the one it reaches shown.
    @Published var heroFade = false
    /// Where the tile of the shot on screen is in the library (screen points), and how many times it
    /// was measured: a photo flying back lands there.
    var tileFrame: (key: String, frame: CGRect)?
    var tileMeasures = 0
    @Published private(set) var renderer = ""
    /// The app ended without leaving last time: what it was doing.
    @Published var lastEnd: String?
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
        // the library, camera or not: the camera joins in when asked (the status in the corner)
        screen = .browser
        library = Library(engine: engine, previews: previews)
        loupe = Loupe(engine: engine)
        editor = EditorModel(engine: engine, loupe: loupe, library: library)
        if UserDefaults.standard.string(forKey: "screen") == "workspace" { screen = .workspace }
        lastEnd = Breadcrumbs.launched()
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
        editor.onNotice = { [weak self] text in self?.say(text) }
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
            _ = try? await engine.exec("app.memoryBudget", ["mb": AppModel.cacheBudget()])
            NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.memoryWarning() }
            }
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.leftForeground() }
            }
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.backInForeground() }
            }
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
        // zoomed in, the window is as blurred as the whole photo: it must differ from the same
        // window undeveloped by the lens blur
        var zoomedIn: CGImage?
        renderDetail(window: CGRect(x: 0.05, y: 0.05, width: 0.3, height: 0.3), full: CGSize(width: 5000, height: 3333)) { img, _ in zoomedIn = img }
        for _ in 0..<100 {
            if zoomedIn != nil { break }
            await wait(0.1)
        }
        if let z = zoomedIn, let k = current, let p = library.shot(k)?.photo,
           let plain = try? await engine.renderRegion(p, fullW: 5000, fullH: 3333, x: 250, y: 166, w: 1500, h: 1000).0.image {
            log("zoom keeps the blur: difference \(String(format: "%.1f", AppModel.difference(z, plain)))")
        } else {
            log("zoom keeps the blur: none")
        }
        // Lightroom's bokeh, its glow, a box of focus, a Refine stroke each way
        for shape in ["bubble", "blade5", "ring", "cateye"] {
            var l = editor.lensBlur
            l.bokeh = shape
            l.boost = 60
            editor.setLensBlur(l, live: false)
            editor.commitLensBlur()
            await wait(0.8)
        }
        editor.focus(box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        await wait(0.8)
        editor.refineFocus = true
        editor.refineStroke((0..<30).map { CGPoint(x: 0.3 + Double($0) * 0.01, y: 0.3) })
        await wait(0.8)
        editor.refineFocus = false
        editor.refineStroke((0..<30).map { CGPoint(x: 0.3 + Double($0) * 0.01, y: 0.7) })
        await wait(1.5)
        log("bokeh and refine ok (\(editor.lensBlur.refine.count) strokes)")
        // far past 100 %: developed at the photo's own size, enlarged on screen
        var deep = false
        renderDetail(window: CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05), full: CGSize(width: 48000, height: 32000)) { img, _ in
            deep = true
            NSLog("lightcraft stress: deep zoom \(img.width)x\(img.height)")
        }
        for _ in 0..<80 {
            if deep { break }
            await wait(0.1)
        }
        log("deep zoom \(deep ? "ok" : "none")")
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
        // a brush stroke painted live (pieces while the finger moves, one undo step)
        editor.addMask("brush")
        await wait(1)
        let before = editor.history.count
        editor.strokeBegan()
        for k in 0..<6 {
            editor.strokePart((0..<12).map { CGPoint(x: 0.2 + Double(k * 12 + $0) * 0.004, y: 0.6) }, pressure: [Float](repeating: 1, count: 12))
            await wait(0.07)
        }
        editor.stroke([CGPoint(x: 0.5, y: 0.62)], pressure: [1])
        await wait(1.5)
        log("live brush ok (\(editor.history.count - before) step)")
        // a component subtracted, a one-tap subject, a band of depth
        editor.addPart("radial", op: "subtract")
        await wait(1.5)
        log("parts ok (\(editor.masks.first { $0.id == editor.selectedMask }?.parts.count ?? 0))")
        editor.addMask("subject")
        for _ in 0..<80 {
            if editor.masks.contains(where: { $0.kind == "subject" }) { break }
            await wait(0.1)
        }
        log("subject \(editor.masks.contains { $0.kind == "subject" } ? "ok" : "none")")
        editor.addMask("depthRange")
        for _ in 0..<150 {
            if editor.masks.contains(where: { $0.kind == "depthRange" }) { break }
            await wait(0.1)
        }
        if editor.masks.contains(where: { $0.kind == "depthRange" }) {
            editor.begin("Gamma profondità")
            for i in 0..<10 {
                editor.setDepthRange(near: 0, far: 0.2 + Double(i) * 0.03, feather: 0.1)
                await wait(0.05)
            }
            editor.end()
            await wait(1)
            log("depth range ok")
        } else {
            log("depth range none")
        }
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
        editor.visualizeSpots = true
        await wait(1.5)
        log("visualize spots \(editor.spotMap != nil ? "ok" : "none")")
        editor.visualizeSpots = false
        for p in presets.prefix(6) {
            editor.applyPreset(p.id, amount: 100)
            await wait(0.7)
        }
        log("styles ok")
        for _ in 0..<6 {
            editor.undo()
            await wait(0.3)
        }
        // all the way back: the photo as it came in (each undo once the last one is done)
        for _ in 0..<200 {
            for _ in 0..<50 where editor.busy { await wait(0.05) }
            if !editor.canUndo { break }
            editor.undo()
            await wait(0.02)
        }
        for _ in 0..<100 where editor.busy { await wait(0.1) }
        log("undo to the start ok (\(editor.cursor) of \(editor.history.count), first step \(editor.history.first ?? "?"))")
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

    /// Tests: how far apart two pictures are (mean difference of their 64 × 64 thumbnails, 0…255).
    nonisolated static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func small(_ i: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
            px.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
                ctx.interpolationQuality = .medium
                ctx.draw(i, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            return px
        }
        let x = small(a), y = small(b)
        var sum = 0.0
        for i in 0..<x.count where i % 4 != 3 { sum += abs(Double(x[i]) - Double(y[i])) }
        return sum / Double(64 * 64 * 3)
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
        case "paint":
            // a brush layer painted: its mask shows in red
            editor.addMask("brush")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            editor.stroke((0..<60).map { CGPoint(x: 0.25 + Double($0) * 0.008, y: 0.45 + 0.1 * sin(Double($0) / 9)) }, pressure: [Float](repeating: 1, count: 60))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            NSLog("lightcraft editor: mask overlay \(editor.maskImage != nil ? "shown" : "missing")")
        case "masks":
            // the Masking panel with a subject and a subtracted brush
            editor.addMask("subject")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            editor.addPart("brush", op: "subtract")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSLog("lightcraft editor: masks \(editor.masks.map { "\($0.kind)/\($0.parts.count)" })")
        case "lensrefine":
            var l = editor.lensBlur
            l.enabled = true
            l.amount = 80
            l.bokeh = "blade5"
            l.boost = 70
            editor.setLensBlur(l, live: false)
            editor.commitLensBlur()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            editor.cursorTool = .refine
            editor.showDepth = true
        case "import":
            // Files' way in: a copy of a shot imported as a new photo, under a name of its own
            let before = library.shots.count
            if let s = library.shots.first(where: { $0.photo != 0 }), let src = try? FileManager.default.contentsOfDirectory(at: shotsDir, includingPropertiesForKeys: nil).first(where: { stem($0.lastPathComponent) == s.key }) {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(src.lastPathComponent)
                try? FileManager.default.removeItem(at: tmp)
                try? FileManager.default.copyItem(at: src, to: tmp)
                importFiles([tmp])
                for _ in 0..<200 {
                    if library.shots.count > before && importing == nil { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            NSLog("lightcraft editor: import \(library.shots.count - before) photo, \(library.shots.last?.key ?? "")")
        case "cropdone":
            // in and out of the crop tool: the photo must be back on screen
            editor.enterCrop()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            editor.exitCrop()
        case "connectback":
            go(.connect)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            go(beforeConnect)
        case "home":
            goHome()
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

    /// A shot from the library into the viewer, flying out of its tile (`from`, screen points).
    func open(_ key: String, from: CGRect?) {
        current = key
        guard let f = from, let img = loupe.pics[key]?.image ?? library.shot(key)?.thumb else {
            withAnimation(Motion.screen) { screen = .workspace }
            return
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            heroFade = false
            hero = Hero(key: key, image: img, from: f, back: false)
            screen = .workspace
        }
    }

    /// From the viewer back to the library, the photo flying into its tile.
    func goHome() {
        guard screen == .workspace else { return go(.browser) }
        guard let k = current, let img = loupe.pics[k]?.image ?? library.shot(k)?.thumb, viewerFrame.width > 1 else {
            return withAnimation(Motion.screen) { screen = .browser }
        }
        let a = CGFloat(img.width) / CGFloat(max(1, img.height))
        let v = viewerFrame
        let size = v.width / max(1, v.height) > a ? CGSize(width: v.height * a, height: v.height) : CGSize(width: v.width, height: v.width / a)
        let from = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            heroFade = false
            hero = Hero(key: k, image: img, from: from, back: true)
            screen = .browser
        }
    }

    /// The flight is over: the photo under it takes its place.
    func heroLanded(_ id: UUID) {
        guard hero?.id == id else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            hero = nil
            heroFade = false
        }
    }

    /// The engine's caches: a share of what this process may still use before iPadOS stops it
    /// (`os_proc_available_memory`), so a heavy operation always has room.
    static func cacheBudget() -> Int {
        let free = Int(os_proc_available_memory() / 1_048_576)
        guard free > 0 else { return 768 }
        return max(384, min(1536, free / 4))
    }

    /// iPadOS asks for memory back: the caches empty (both engines), the viewer keeps the shot on
    /// screen only; the budget comes back a little later.
    private func memoryWarning() async {
        NSLog("lightcraft: memory warning")
        loupe.trim()
        _ = try? await engine.exec("app.memoryBudget", ["mb": 96])
        _ = try? await previews.exec("app.memoryBudget", ["mb": 64])
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        _ = try? await engine.exec("app.memoryBudget", ["mb": AppModel.cacheBudget()])
        _ = try? await previews.exec("app.memoryBudget", ["mb": 256])
    }

    /// Out of sight (another app in front): the caches go at once. iPadOS gives an app in the
    /// background little memory, and while it takes a large one back every other app stutters,
    /// switching between apps included. The pictures come back on return.
    private func leftForeground() async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "lightcraft-trim")
        loupe.paused = true
        loupe.trim()
        Bokeh.shared?.forget()
        _ = try? await engine.exec("app.memoryBudget", ["mb": 64])
        _ = try? await previews.exec("app.memoryBudget", ["mb": 48])
        NSLog("lightcraft: background, \(os_proc_available_memory() / 1_048_576) MB free")
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    private func backInForeground() async {
        loupe.paused = false
        loupe.pump()
        _ = try? await engine.exec("app.memoryBudget", ["mb": AppModel.cacheBudget()])
        _ = try? await previews.exec("app.memoryBudget", ["mb": 256])
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
        Breadcrumbs.mark("Zoom \(w)×\(h) di \(fw)×\(fh)")
        Task {
            let t0 = Date()
            guard let (r, rect) = try? await engine.renderRegion(p, fullW: fw, fullH: fh, x: x, y: y, w: w, h: h), current == k else { return }
            NSLog("lightcraft region: \(w)x\(h) of \(fw)x\(fh) -> \(r.image.width)x\(r.image.height) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            // the size the whole photo was developed at (100 % at most)
            let drawn = CGSize(width: CGFloat(r.image.width) / max(rect.width, 1e-6), height: CGFloat(r.image.height) / max(rect.height, 1e-6))
            let img = await editor.blurDetail(r.image, window: rect, full: drawn) ?? r.image
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

    /// The screen the camera's login was opened from (its back button returns there).
    private(set) var beforeConnect: Screen = .browser

    func go(_ s: Screen) {
        if s == .connect && screen != .connect { beforeConnect = screen }
        withAnimation(Motion.screen) { screen = s }
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
            let ok = (try? await engine.exec("preset.apply", ["id": id, "amount": 100, "ids": ids])) != nil
            await library.editLock.unlock()
            await changed(keys)
            if !ok { say("Stile non applicato") }
        }
    }

    /// The copied adjustments onto the library's selection.
    func paste(to keys: Set<String>) {
        let ids = library.shots.filter { keys.contains($0.key) && $0.photo != 0 }.map(\.photo)
        guard !ids.isEmpty else { return }
        Task {
            await library.editLock.lock()
            let ok = (try? await engine.exec("develop.paste", ["ids": ids])) != nil
            await library.editLock.unlock()
            await changed(keys)
            say(!ok ? "Incolla non riuscito" : (ids.count == 1 ? "Regolazioni incollate" : "Regolazioni incollate su \(ids.count) foto"))
        }
    }

    /// Lightroom's Sync: the settings of `groups` of the photo on screen onto the selection.
    func sync(to keys: Set<String>, groups: [String]) {
        guard let src = current.flatMap({ library.shot($0) })?.photo, src != 0 else { return }
        let ids = library.shots.filter { keys.contains($0.key) && $0.photo != 0 && $0.photo != src }.map(\.photo)
        guard !ids.isEmpty else { return }
        Task {
            await library.editLock.lock()
            let ok = (try? await engine.batch { e -> Void in
                _ = try e.execNow("library.select", ["ids": [src] + ids, "active": src])
                _ = try e.execNow("develop.sync", ["groups": groups])
            }) != nil
            await library.editLock.unlock()
            await changed(keys)
            say(!ok ? "Sincronizzazione non riuscita" : "Regolazioni sincronizzate su \(ids.count) foto")
        }
    }

    /// Photos whose settings changed outside the editor: their thumbnails made again, the editor
    /// reloaded when it shows one of them.
    private func changed(_ keys: Set<String>) async {
        for k in keys { library.edited(k) }
        if let c = current, keys.contains(c) { editor.reload() }
        for k in library.shots.map(\.key) where keys.contains(k) { await library.thumb(k) }
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
                Breadcrumbs.mark("Esportazione \(recipe.ext) di \(s.name)")
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
        // the Refine strokes are in the image's own coordinates: the crop takes them to the picture's
        let aspect = (try? await engine.renderUncropped(photo, 128, 128, draft: true)).map { CGFloat($0.image.width) / CGFloat(max(1, $0.image.height)) } ?? 1.5
        let crop = CropState.from(d, aspect: aspect)
        let scene = BlurScene(depth: depth, depthID: -Int(photo), refine: LensBlurRenderer.refineMask(s.refine, crop: crop, aspect: CGFloat(small.width) / CGFloat(max(1, small.height))))
        _ = await Task.detached(priority: .userInitiated) { LensBlurRenderer.apply(toFile: url, scene: scene, s, quality: quality) }.value
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
