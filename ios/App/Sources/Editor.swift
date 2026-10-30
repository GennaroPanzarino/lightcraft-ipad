import CoreGraphics
import Foundation

/// What a touch on the photo does: Capture One's cursor tools.
enum CursorTool {
    case none, crop, spot, paint, shape, sample, focus
    /// Lens Blur's Refine brush (painted on the photo, kept by the app).
    case refine
}

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
    /// What a touch on the photo does (Capture One's cursor tools).
    @Published var cursorTool: CursorTool = .none {
        didSet {
            guard cursorTool != oldValue else { return }
            localAdjusting = false
            if cursorTool != .spot && visualizeSpots { visualizeSpots = false }
            if EditorModel.maskTools.contains(cursorTool) { refreshMask() }
        }
    }
    /// The tools that draw a layer's mask: the mask shows in red while they are on.
    static let maskTools: Set<CursorTool> = [.paint, .shape, .sample]
    /// Where the selected layer acts (alpha only), for the red overlay.
    @Published private(set) var maskImage: CGImage?
    /// The red overlay while a layer is drawn (Lightroom's "Show overlay").
    @Published var maskOverlay = true {
        didSet { if maskOverlay && !oldValue { refreshMask() } }
    }
    /// A layer slider is moving: the overlay steps aside to show the effect.
    @Published private(set) var localAdjusting = false
    /// A heavy change on its way (removing a spot, painting a mask…): what, for the photo's hint.
    @Published private(set) var working: String?
    /// Lens Corrections' "Constrain Crop" (the crop stays inside the corrected photo).
    @Published private(set) var constrainCrop = false
    private var maskTask: Task<Void, Never>?
    @Published private(set) var crop = CropState()
    @Published private(set) var masks: [MaskInfo] = []
    @Published var selectedMask: Int? {
        didSet {
            guard selectedMask != oldValue else { return }
            selectedPart = nil
            loadLocal()
            maskImage = nil
            rawMask = nil
            refreshMask()
        }
    }
    /// The component of the selected mask being edited (nil: its last one).
    @Published var selectedPart: Int?
    @Published private(set) var spots: [SpotInfo] = []
    @Published var brushSize = 0.03
    @Published var brushFeather = 50.0
    @Published var brushFlow = 100.0
    @Published var erasing = false
    @Published var spotSize = 0.015
    @Published var spotMode = "heal"
    @Published var brushDensity = 100.0
    /// Lightroom's Auto Mask: the brush keeps to the edges it meets.
    @Published var autoMask = false
    /// A tap with the colour picker adds a sample (Lightroom's ⇧-click) instead of starting over.
    @Published var sampleAdd = false
    /// The overlay's colour (one of `EditOverlay.overlayColors`) and opacity (0…100).
    @Published var overlayColor = 0 { didSet { if overlayColor != oldValue { retint() } } }
    @Published var overlayOpacity = 50.0 { didSet { if overlayOpacity != oldValue { retint() } } }
    /// The selected mask as the engine drew it (white on black), before the overlay's colour.
    private var rawMask: CGImage?
    /// The uncropped photo and its depth, for the one-tap selections (made once per photo).
    private var analyzed: (photo: Int64, image: CGImage, depth: DepthMap?)?
    private var selectNewestPart = false
    /// A stroke goes to the engine while it is painted (one undo step when the finger lifts).
    private var strokeLive = false
    /// A message for the user (a selection that found nothing…).
    var onNotice: ((String) -> Void)?
    /// Lightroom's Visualize Spots: the photo as its fine detail, so dust stands out.
    @Published var visualizeSpots = false { didSet { if visualizeSpots != oldValue { refreshSpotMap() } } }
    @Published var spotContrast = 50.0
    @Published private(set) var spotMap: CGImage?
    /// The photo without its crop: the crop tool draws the crop over it.
    @Published private(set) var uncropped: CGImage?
    /// The uncropped image's width / height.
    private var imageAspect: CGFloat = 1.5
    private var selectNewest = false
    /// The selected layer's sliders.
    let localStore = DevelopStore()
    /// Lightroom's Lens Blur as the photo keeps it; while a slider moves, `liveBlur` (not published:
    /// the panel draws nothing, only the photo changes).
    @Published private(set) var lensBlur = LensBlurState()
    @Published private(set) var depthSource = ""
    @Published private(set) var depthImage: CGImage?
    @Published var showDepth = false { didSet { if showDepth != oldValue { refreshDepthView() } } }
    /// How much of the scene lies at each distance (near → far), for the focal range.
    @Published private(set) var depthHistogram: [Float] = []
    /// The subject's depth (nearness, 0…1), the focus when none is set.
    @Published private(set) var subjectDepth: Double?
    /// Lens Blur's Refine brush: focus or blur, its size (fraction of the long edge), feather, flow.
    @Published var refineFocus = true
    @Published var refineSize = 0.04
    @Published var refineFeather = 50.0
    @Published var refineFlow = 100.0
    /// Changes with the depth (the GPU keeps its copy until then).
    private var depthID = 0
    private var refineCache: (key: String, mask: RefineMask?)?
    private var depthViewBusy = false
    private var depthViewPending = false
    private var liveBlur: LensBlurState?
    private var depth: DepthMap?
    private var depthKey = ""
    private var clean: Pic?
    private var blurBusy = false
    private var blurPending = false

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
        case local([String: Double])
        case cropDrag(String, CGPoint, CGPoint, CGRect)
        case shape(Int, Int?, [String: Any])
        case stroke([CGPoint], [Float])
        /// A piece of the stroke being painted (`connect`: it carries on from the last piece).
        case liveStroke([CGPoint], [Float], Bool)
        /// Engine commands as one change, drawn at once (`key`: a newer one with the same key
        /// replaces one still waiting).
        case edit([(String, [String: Any])], String)
        /// A setting kept with the photo that the engine does not draw (the lens blur): no new
        /// picture, no new panel, only the history.
        case quiet(String, [String: Any], String)
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
        localStore.setControls(LocalControls.all)
        localStore.onBegin = { [weak self] label in
            self?.localAdjusting = true
            self?.send(.begin(label))
        }
        localStore.onChange = { [weak self] id, v in self?.send(.local([id: v])) }
        localStore.onEnd = { [weak self] in self?.send(.end) }
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
        cursorTool = .none
        uncropped = nil
        selectedMask = nil
        maskImage = nil
        rawMask = nil
        analyzed = nil
        visualizeSpots = false
        spotMap = nil
        working = nil
        masks = []
        spots = []
        depth = nil
        depthKey = ""
        depthImage = nil
        depthHistogram = []
        subjectDepth = nil
        refineCache = nil
        clean = nil
        liveBlur = nil
        showDepth = false
        store.enabled = true
        Task {
            await loadAspect()
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
        cursorTool = .none
        uncropped = nil
        loupe.held = nil
        key = ""
        photo = 0
        store.enabled = false
        localStore.enabled = false
    }

    // ---- the lens blur

    /// The loupe hands the photo's pictures over while the lens blur is on: they are shown blurred.
    func intercept(_ p: Pic) -> Bool {
        guard p.key == key, photo != 0, (liveBlur ?? lensBlur).enabled else { return false }
        clean = p
        scheduleBlur()
        return true
    }

    /// A lens blur setting while a slider moves (`live`), or for good.
    func setLensBlur(_ s: LensBlurState, live: Bool) {
        let was = (liveBlur ?? lensBlur).enabled
        if live { liveBlur = s } else { liveBlur = nil; lensBlur = s }
        refreshDepthView()
        if s.enabled {
            if clean == nil || clean?.key != key, let p = loupe.pics[key], !p.filtered { clean = p }
            scheduleBlur()
        } else if was, var c = clean {
            c.filtered = true
            loupe.put(c)
        }
    }

    /// What the blur of the picture on screen is made from: the depth, and the Refine strokes
    /// (drawn again only when they or the crop change).
    private func scene(_ state: LensBlurState, aspect: CGFloat) -> BlurScene? {
        guard let d = depth else { return nil }
        let k = "\(state.refine.count)|\(state.refine.last?.points.count ?? 0)|\(crop.rect)|\(crop.angle)|\(aspect)"
        let mask: RefineMask?
        if let c = refineCache, c.key == k {
            mask = c.mask
        } else {
            mask = LensBlurRenderer.refineMask(state.refine, crop: crop, aspect: aspect)
            refineCache = (k, mask)
        }
        return BlurScene(depth: d, depthID: depthID, refine: mask)
    }

    /// A zoomed-in window (`n`, 0…1 of the picture) with the lens blur, when it is on.
    func blurDetail(_ image: CGImage, window n: CGRect, full: CGSize) async -> CGImage? {
        let state = liveBlur ?? lensBlur
        guard state.enabled else { return nil }
        guard let sc = scene(state, aspect: full.width / max(full.height, 1)) else {
            NSLog("lightcraft lensblur: zoomed window without blur (no depth yet)")
            return nil
        }
        let ref = max(full.width, full.height)
        let t0 = Date()
        let out = await Task.detached(priority: .userInitiated) { LensBlurRenderer.apply(image, scene: sc, state, window: n, reference: ref) }.value
        NSLog("lightcraft lensblur: zoomed window \(image.width)x\(image.height) \(out == nil ? "not blurred" : "blurred") in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        return out
    }

    /// The lens blur into the photo's settings (one undo step). The engine does not draw it, so
    /// nothing is developed again: the blurred picture on screen already is the result.
    func commitLensBlur() {
        if let l = liveBlur {
            lensBlur = l
            liveBlur = nil
        }
        send(.quiet("develop.merge", ["settings": lensBlur.settings, "label": "Sfocatura obiettivo"], "Sfocatura obiettivo"))
        // the picture at full quality (a slider drag showed a lighter one)
        scheduleBlur()
        refreshDepthView()
    }

    /// Focus where the photo was touched (0…1 of the picture on screen).
    func focus(at u: CGPoint) {
        guard let d = depth else { return }
        var s = lensBlur
        s.focus = Double(d.at(u))
        s.enabled = true
        setLensBlur(s, live: false)
        commitLensBlur()
    }

    /// Lightroom's focus box: what the box holds is the focal range (`r`, 0…1 of the picture).
    func focus(box r: CGRect) {
        guard let d = depth else { return }
        let part = d.sub(r).values.sorted()
        guard part.count > 4 else { return }
        let lo = part[part.count / 10], hi = part[part.count * 9 / 10]
        var s = lensBlur
        s.focus = Double((lo + hi) / 2)
        s.range = max(0.03, Double(hi - lo) + 0.02)
        s.enabled = true
        setLensBlur(s, live: false)
        commitLensBlur()
    }

    /// A Refine stroke (image coordinates): kept in focus or blurred, with the refine brush as set.
    func refineStroke(_ points: [CGPoint]) {
        guard !points.isEmpty else { return }
        var s = lensBlur
        s.refine.append(RefineStroke(points: points, size: refineSize, feather: refineFeather, flow: refineFlow, focus: refineFocus))
        s.enabled = true
        setLensBlur(s, live: false)
        commitLensBlur()
    }

    /// The Refine strokes gone (one undo step).
    func clearRefine() {
        var s = lensBlur
        guard !s.refine.isEmpty else { return }
        s.refine = []
        setLensBlur(s, live: false)
        commitLensBlur()
    }

    /// Visualize Depth: the depth in colour, the focal band lighter (one picture at a time: a
    /// finger moving the band asks for many, the latest is made).
    private func refreshDepthView() {
        guard showDepth, let d = depth, let p = clean else {
            if !showDepth { depthImage = nil }
            return
        }
        if depthViewBusy {
            depthViewPending = true
            return
        }
        depthViewBusy = true
        let s = liveBlur ?? lensBlur
        let f = Float(s.focus ?? Double(d.subject)), r = Float(s.range)
        // a quarter of the pixels while a finger moves
        let k = liveBlur != nil ? 4 : 2
        let w = max(1, p.image.width / k), h = max(1, p.image.height / k)
        Task {
            let img = await Task.detached(priority: .userInitiated) { d.colored(width: w, height: h, focus: f, range: r) }.value
            if showDepth { depthImage = img }
            depthViewBusy = false
            if depthViewPending {
                depthViewPending = false
                refreshDepthView()
            }
        }
    }

    private func scheduleBlur() {
        if blurBusy {
            blurPending = true
            return
        }
        guard let p = clean, p.key == key else { return }
        blurBusy = true
        Breadcrumbs.mark("Sfocatura obiettivo")
        let state = liveBlur ?? lensBlur
        // while a finger moves (a slider, a draft): half the pixels, and fewer samples
        let light = liveBlur != nil || p.draft
        let k = "\(photo)|\(crop.rect)|\(crop.angle)"
        Task {
            let t0 = Date()
            if depth == nil || (depthKey != k && !p.draft) {
                let small = await Task.detached(priority: .userInitiated) { scaled(p.image, edge: 1024) }.value
                let d = await DepthEstimator.shared.estimate(small)
                if p.key == key {
                    depth = d
                    depthKey = k
                    depthID += 1
                    depthSource = DepthEstimator.shared.source
                    depthHistogram = d?.histogram(64) ?? []
                    subjectDepth = d.map { Double($0.subject) }
                    refreshDepthView()
                }
                NSLog("lightcraft lensblur: depth \(Int(Date().timeIntervalSince(t0) * 1000)) ms (\(depthSource))")
            }
            var out = p
            let aspect = CGFloat(p.image.width) / CGFloat(max(1, p.image.height))
            if state.enabled, let sc = scene(state, aspect: aspect) {
                let img = p.image
                let t1 = Date()
                if let b = await Task.detached(priority: .userInitiated, operation: { LensBlurRenderer.apply(img, scene: sc, state, half: light, quality: light ? .live : .screen) }).value {
                    out = Pic(key: p.key, photo: p.photo, revision: p.revision, boxW: p.boxW, boxH: p.boxH, image: b, draft: p.draft || light)
                }
                NSLog("lightcraft lensblur: blur \(Int(Date().timeIntervalSince(t1) * 1000)) ms\(light ? " (light)" : "") \(Bokeh.shared == nil ? "CI" : "Metal")")
            }
            out.filtered = true
            if p.key == key { loupe.put(out) }
            blurBusy = false
            if blurPending {
                blurPending = false
                scheduleBlur()
            }
        }
    }

    // ---- crop, layers, spots (the cursor tools)

    /// The crop tool: the photo uncropped, the crop drawn over it.
    func enterCrop() {
        guard photo != 0 else { return }
        picking = false
        cursorTool = .crop
        let p = photo
        let (w, h) = viewport
        Task {
            if let r = try? await engine.renderUncropped(p, w, h), p == photo, cursorTool == .crop { uncropped = r.image }
        }
    }

    func exitCrop() {
        cursorTool = .none
        uncropped = nil
    }

    /// Lens Corrections' "Constrain Crop" on or off (one undo step).
    func setConstrainCrop(_ on: Bool) {
        constrainCrop = on
        merge(["geometry": ["constrain_crop": on]], label: "Vincola ritaglio")
    }

    /// A finger starts painting or shaping a layer: the overlay comes back.
    func strokeBegan() {
        localAdjusting = false
    }

    /// Whether the red overlay is on the photo now.
    var maskOverlayShown: Bool {
        maskOverlay && !localAdjusting && selectedMask != nil && EditorModel.maskTools.contains(cursorTool)
    }

    /// The selected layer's mask drawn again (after a stroke, a gradient moved, a colour sampled…),
    /// while the overlay is wanted.
    private func refreshMask() {
        maskTask?.cancel()
        guard let id = selectedMask, photo != 0, maskOverlay, EditorModel.maskTools.contains(cursorTool) else { return }
        let p = photo
        // half the viewer's size: a mask's edges are soft
        let (w, h) = (max(64, viewport.w / 2), max(64, viewport.h / 2))
        let color = EditOverlay.overlayColors[overlayColor], opacity = overlayOpacity / 100
        maskTask = Task {
            guard let r = try? await engine.renderMask(p, mask: id, w, h), !Task.isCancelled, p == photo, selectedMask == id else { return }
            let img = r.image
            let a = await Task.detached(priority: .userInitiated) { tintedMask(img, color: color, opacity: opacity) }.value
            if !Task.isCancelled, p == photo, selectedMask == id {
                rawMask = img
                maskImage = a
            }
        }
    }

    /// The overlay in another colour or opacity (the mask itself is the same).
    private func retint() {
        guard let m = rawMask else { return }
        let color = EditOverlay.overlayColors[overlayColor], opacity = overlayOpacity / 100
        Task {
            let a = await Task.detached(priority: .userInitiated) { tintedMask(m, color: color, opacity: opacity) }.value
            if rawMask === m { maskImage = a }
        }
    }

    // ---- Visualize Spots

    /// The picture on screen as its detail (what differs from its surroundings), white on black:
    /// sensor dust shows as small round marks.
    func refreshSpotMap() {
        guard visualizeSpots, let p = loupe.pics[key] else {
            spotMap = nil
            return
        }
        let img = p.image, k = spotContrast
        Task {
            let m = await Task.detached(priority: .userInitiated) { SpotMap.make(img, contrast: k) }.value
            if visualizeSpots { spotMap = m }
        }
    }

    /// A crop handle dragged (`from`/`to` in the turned frame, `start` the crop when the drag began).
    func cropDrag(_ handle: String, from: CGPoint, to: CGPoint, start: CGRect) {
        send(.cropDrag(handle, from, to, start))
    }

    func addMask(_ kind: String) {
        if Selections.kinds.contains(kind) {
            addSelection(kind, op: nil)
            return
        }
        selectNewest = true
        run("mask.add", ["kind": kind, "name": newMaskName(kind)])
        cursorTool = EditorModel.tool(for: kind)
    }

    private func newMaskName(_ kind: String) -> String {
        let n = masks.filter { $0.kind == kind }.count + 1
        return MaskKinds.label(kind) + (n > 1 ? " \(n)" : "")
    }

    /// The cursor tool that draws a component of `kind` on the photo.
    static func tool(for kind: String) -> CursorTool {
        switch kind {
        case "brush": return .paint
        case "linear", "radial": return .shape
        case "colorRange": return .sample
        default: return .none
        }
    }

    /// A component added to the selected mask (Lightroom's Add, Subtract, Intersect with).
    func addPart(_ kind: String, op: String) {
        guard let id = selectedMask else { return }
        if Selections.kinds.contains(kind) {
            addSelection(kind, op: op)
            return
        }
        selectNewestPart = true
        run("mask.addComponent", ["id": id, "op": op, "kind": kind])
        cursorTool = EditorModel.tool(for: kind)
    }

    /// One component's menu: invert, duplicate, delete, or how it joins (add, subtract, intersect).
    func partAction(_ index: Int, _ action: String, op: String? = nil) {
        guard let id = selectedMask else { return }
        var p: [String: Any] = ["id": id, "component": index, "action": action]
        if let o = op { p["op"] = o }
        if action == "delete" { selectedPart = nil }
        run("mask.component", p)
    }

    func renameMask(_ id: Int, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        run("mask.rename", ["id": id, "name": n])
    }

    /// Duplicate (and invert: Lightroom's Duplicate and Invert, the rest of the photo).
    func duplicateMask(_ id: Int, invert: Bool) {
        selectNewest = true
        run("mask.duplicate", ["id": id, "invert": invert])
    }

    /// Refine Edges: the mask's edges snap to the photo's.
    func setRefine(_ id: Int, _ v: Double) { run("mask.refine", ["id": id, "value": v]) }

    /// A one-tap selection (subject, sky, background, people, a band of depth), worked out on the
    /// iPad, as a new mask (`op` nil) or a component of the selected one.
    func addSelection(_ kind: String, op: String?) {
        guard photo != 0 else { return }
        let p = photo
        let mask = selectedMask
        working = kind == "depthRange" ? "Misuro la profondità…" : "Cerco: \(MaskKinds.label(kind).lowercased())…"
        Task {
            defer { if photo == p { working = nil } }
            guard let a = await analysis(), p == photo else { return }
            let range = (near: 0.0, far: 0.3, feather: 0.1)
            let cov: Coverage? = await Task.detached(priority: .userInitiated) {
                switch kind {
                case "people": return Selections.people(a.image)
                case "sky": return Selections.sky(a.image, depth: a.depth)
                case "background":
                    return Selections.subject(a.image, depth: a.depth).map { c in Coverage(width: c.width, height: c.height, values: c.values.map { 1 - $0 }) }
                case "depthRange": return a.depth.map { Selections.depthRange($0, near: range.near, far: range.far, feather: range.feather) }
                default: return Selections.subject(a.image, depth: a.depth)
                }
            }.value
            guard p == photo else { return }
            guard let c = cov, let seg = await Task.detached(priority: .userInitiated, operation: { Selections.seg(c) }).value else {
                onNotice?(kind == "depthRange" ? "La profondità non è disponibile" : "Nessun \(kind == "people" ? "volto o persona" : MaskKinds.label(kind).lowercased()) trovato")
                return
            }
            let name = kind == "depthRange" ? Selections.depthName(near: range.near, far: range.far, feather: range.feather) : MaskKinds.label(kind)
            if let o = op, let id = mask {
                selectNewestPart = true
                run("mask.addComponent", ["id": id, "op": o, "kind": "object", "seg": seg, "name": name])
            } else {
                selectNewest = true
                run("mask.add", ["kind": "object", "seg": seg, "name": newMaskName(kind), "componentName": name])
            }
        }
    }

    /// The selected depth-range component's band changed (0 = nearest … 1 = farthest).
    func setDepthRange(near: Double, far: Double, feather: Double) {
        guard let id = selectedMask, let part = masks.first(where: { $0.id == id })?.part(selectedPart), let d = analyzed?.depth, analyzed?.photo == photo else { return }
        let c = Selections.depthRange(d, near: near, far: far, feather: feather)
        guard let seg = Selections.seg(c) else { return }
        let shape: [String: Any] = ["kind": "object", "hint": [Any](), "seg": seg]
        send(.edit([
            ("mask.update", ["id": id, "component": part.index, "shape": shape]),
            ("mask.component", ["id": id, "component": part.index, "action": "rename", "name": Selections.depthName(near: near, far: far, feather: feather)]),
        ], "depth"))
    }

    /// The uncropped photo (and its depth) the selections are worked out on.
    func analysis() async -> (image: CGImage, depth: DepthMap?)? {
        if let a = analyzed, a.photo == photo { return (a.image, a.depth) }
        let p = photo
        guard let r = try? await engine.renderUncropped(p, 1024, 1024), p == photo else { return nil }
        let d = await DepthEstimator.shared.estimate(r.image)
        guard p == photo else { return nil }
        analyzed = (p, r.image, d)
        return (r.image, d)
    }

    func deleteMask(_ id: Int) {
        if selectedMask == id { selectedMask = nil; if cursorTool != .crop { cursorTool = .none } }
        run("mask.delete", ["id": id])
    }

    func setMaskVisible(_ id: Int, _ on: Bool) { run("mask.visible", ["id": id, "visible": on]) }
    func invertMask(_ id: Int) { run("mask.invert", ["id": id]) }

    /// The component being edited of mask `id` (its index).
    private func partIndex(_ id: Int) -> Int? {
        masks.first { $0.id == id }?.part(selectedPart)?.index
    }

    /// A shape of the selected component while a handle moves (one undo step per drag, between
    /// begin and end).
    func updateShape(_ id: Int, _ shape: [String: Any]) { send(.shape(id, partIndex(id), shape)) }

    /// A piece of the stroke being painted: it goes to the engine at once (the effect follows the
    /// finger); the whole stroke is one undo step.
    func strokePart(_ points: [CGPoint], pressure: [Float]) {
        guard selectedMask != nil, !points.isEmpty else { return }
        if !strokeLive {
            strokeLive = true
            send(.begin("Pennello"))
            send(.liveStroke(points, pressure, false))
        } else {
            send(.liveStroke(points, pressure, true))
        }
    }

    /// The stroke ends: its last piece (image coordinates; pen pressure 0…1 per point).
    func stroke(_ points: [CGPoint], pressure: [Float]) {
        if strokeLive {
            strokeLive = false
            if !points.isEmpty { send(.liveStroke(points, pressure, true)) }
            send(.end)
            return
        }
        guard selectedMask != nil, points.count > 0 else { return }
        send(.stroke(points, pressure))
    }

    /// The colour range of the selected component samples the colour at `p` (image coordinates).
    func sampleColor(_ p: CGPoint, add: Bool) {
        guard let id = selectedMask else { return }
        var params: [String: Any] = ["id": id, "x": Double(p.x), "y": Double(p.y), "add": add || sampleAdd]
        if let k = partIndex(id), masks.first(where: { $0.id == id })?.part(k)?.kind == "colorRange" { params["component"] = k }
        run("mask.sampleColor", params)
    }

    /// The selected luminance range: from `lo` to `hi` (0…1), each edge softened.
    func setLuminanceRange(_ id: Int, lo: Double, hi: Double, loFeather: Double? = nil, hiFeather: Double? = nil) {
        guard let part = masks.first(where: { $0.id == id })?.part(selectedPart) else { return }
        var s = part.shape
        s["lo"] = lo
        s["hi"] = hi
        if let f = loFeather { s["lo_feather"] = f }
        if let f = hiFeather { s["hi_feather"] = f }
        updateShape(id, s)
    }

    /// A shape setting of the selected component (a colour range's Refine, a radial's feather…).
    func setPartValue(_ id: Int, _ key: String, _ v: Any) {
        guard let part = masks.first(where: { $0.id == id })?.part(selectedPart) else { return }
        var s = part.shape
        s[key] = v
        send(.begin("Maschera"))
        updateShape(id, s)
        send(.end)
    }

    func addSpot(_ p: CGPoint) {
        run("spot.add", ["mode": spotMode, "points": [[Double(p.x), Double(p.y)]], "size": spotSize])
    }

    func deleteSpot(_ index: Int) { run("spot.delete", ["index": index]) }

    /// The selected mask's adjustments back to none (its Amount to 100 %), one undo step.
    func resetLocal() {
        guard selectedMask != nil else { return }
        var v: [String: Double] = [:]
        for k in LocalControls.ids { v["local.\(k)"] = LocalControls.def(k) }
        localStore.load(v)
        send(.begin("Azzera maschera"))
        send(.local(v))
        send(.end)
    }

    /// The selected layer's values into its sliders.
    private func loadLocal() {
        guard let id = selectedMask, let m = masks.first(where: { $0.id == id }) else {
            localStore.enabled = false
            localStore.load([:])
            return
        }
        var v: [String: Double] = [:]
        for k in LocalControls.ids { v["local.\(k)"] = m.adjust[k] ?? LocalControls.def(k) }
        localStore.enabled = true
        localStore.load(v)
    }

    /// The uncropped image's proportions (for the crop and the image coordinates).
    private func loadAspect() async {
        let p = photo
        if let r = try? await engine.renderUncropped(p, 128, 128, draft: true), p == photo, r.image.height > 0 {
            imageAspect = CGFloat(r.image.width) / CGFloat(r.image.height)
        }
    }

    /// Crop, layers and spots as LightCraft has them.
    private func loadState() async {
        let p = photo
        guard p != 0, let d = try? await engine.object("develop.get", ["id": p]), p == photo else { return }
        applyState(d)
    }

    private func applyState(_ d: [String: Any]) {
        update(\.crop, CropState.from(d, aspect: imageAspect))
        if liveBlur == nil { update(\.lensBlur, LensBlurState.from(d)) }
        update(\.masks, MaskInfo.list(d))
        update(\.spots, SpotInfo.list(d))
        if selectNewest {
            selectNewest = false
            // the newest has the highest id (a duplicate sits right after its original)
            selectedMask = masks.max { $0.id < $1.id }?.id
        } else if let s = selectedMask, !masks.contains(where: { $0.id == s }) {
            selectedMask = nil
        }
        if selectNewestPart {
            selectNewestPart = false
            selectedPart = masks.first(where: { $0.id == selectedMask })?.parts.last?.index
        } else if let k = selectedPart, masks.first(where: { $0.id == selectedMask })?.parts.contains(where: { $0.index == k }) != true {
            selectedPart = nil
        }
        let aspect = masks.first(where: { $0.id == selectedMask })?.adjust
        if let a = aspect, !interacting {
            var v: [String: Double] = [:]
            for k in LocalControls.ids { v["local.\(k)"] = a[k] ?? LocalControls.def(k) }
            localStore.enabled = true
            localStore.load(v)
        }
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

    /// Undo and redo, each saying what it took back or brought back.
    func undo() {
        if cursor > 0, cursor < history.count { onNotice?("Annullato: \(historyName(history[cursor]))") }
        run("history.previous")
    }

    func redo() {
        if cursor + 1 < history.count { onNotice?("Ripristinato: \(historyName(history[cursor + 1]))") }
        run("history.next")
    }
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
        let q = crop.toImage(p)
        run("develop.wbPick", ["x": Double(q.x), "y": Double(q.y)])
    }

    /// The photo's settings of `groups` copied (Lightroom's Copy Settings), for a paste on this
    /// photo or others.
    func copySettings(groups: [String]) {
        guard photo != 0 else { return }
        let p = photo
        Task {
            let ok = (try? await engine.batch { e in
                _ = try e.execNow("library.select", ["ids": [p], "active": p])
                _ = try e.execNow("develop.copy", ["groups": groups])
            }) != nil
            hasCopy = hasCopy || ok
            onNotice?(ok ? "Regolazioni copiate (\(groups.count) \(groups.count == 1 ? "gruppo" : "gruppi"))" : "Copia non riuscita")
        }
    }

    /// The photo's settings read again after they changed from elsewhere (a paste or a style on a
    /// selection in the library): the panel, the picture, the history.
    func reload() {
        guard photo != 0 else { return }
        Task {
            await refresh()
            await after(nil)
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
        if visualizeSpots { refreshSpotMap() }
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
        } else if case .local(let v) = op, case .local(let old)? = queue.last {
            queue[queue.count - 1] = .local(old.merging(v) { $1 })
        } else if case .cropDrag = op, case .cropDrag? = queue.last {
            queue[queue.count - 1] = op
        } else if case .shape = op, case .shape? = queue.last {
            queue[queue.count - 1] = op
        } else if case .edit(_, let k) = op, case .edit(_, let k0)? = queue.last, k == k0 {
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
        let started = Date()
        let label: String
        switch op {
        case .command(let name, _):
            label = name
            Breadcrumbs.mark("Comando \(name)")
            switch name {
            case "spot.add": working = "Rimuovo la macchia…"
            case "spot.findDust": working = "Cerco la polvere sul sensore…"
            case "spot.delete": working = "Tolgo la macchia…"
            case let n where n.hasPrefix("mask."): working = "Aggiorno il livello…"
            default: break
            }
        case .stroke:
            label = "stroke"
            Breadcrumbs.mark("Pennello")
            working = "Applico la pennellata…"
        case .preset:
            label = "preset"
            Breadcrumbs.mark("Stile")
        case .begin: label = "begin"
        case .end: label = "end"
        case .values: label = "values"
        case .curve: label = "curve"
        case .create: label = "create"
        case .local: label = "local"
        case .cropDrag: label = "cropDrag"
        case .shape: label = "shape"
        case .liveStroke: label = "liveStroke"
        case .edit(_, let k): label = "edit \(k)"
        case .quiet(let name, _, _): label = name
        }
        defer {
            working = nil
            NSLog("lightcraft op: \(label) \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
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
            case .local(let v):
                guard let mid = selectedMask else { break }
                let (w, h) = viewport
                let draft = interacting
                let wasHeld = held
                loupe.held = key
                var values: [String: Double] = [:]
                for (k, x) in v { values[String(k.dropFirst("local.".count))] = x }
                let r = try await engine.batch { e -> Rendered in
                    if !wasHeld { _ = try e.execNow("library.select", ["ids": [photo], "active": photo]) }
                    _ = try e.execNow("mask.adjust", ["id": mid, "values": values])
                    return try e.renderNow(photo, w, h, draft: draft)
                }
                if draft { show(r.image, draft: true) } else { await after(r.image) }
            case .cropDrag(let handle, let from, let to, let start):
                let r = try await engine.batch { e -> Any? in
                    _ = try e.execNow("library.select", ["ids": [photo], "active": photo])
                    _ = try e.execNow("crop.drag", ["handle": handle, "from": [Double(from.x), Double(from.y)], "to": [Double(to.x), Double(to.y)], "start": [Double(start.minX), Double(start.minY), Double(start.maxX), Double(start.maxY)]])
                    return try e.execNow("develop.get", ["id": photo])
                }
                if let d = r as? [String: Any] { crop = CropState.from(d, aspect: imageAspect) }
            case .shape(let mid, let comp, let shape):
                let (w, h) = viewport
                let draft = interacting
                let wasHeld = held
                loupe.held = key
                var params: [String: Any] = ["id": mid, "shape": shape]
                if let c = comp { params["component"] = c }
                let r = try await engine.batch { e -> Rendered in
                    if !wasHeld { _ = try e.execNow("library.select", ["ids": [photo], "active": photo]) }
                    _ = try e.execNow("mask.update", params)
                    return try e.renderNow(photo, w, h, draft: draft)
                }
                if draft {
                    show(r.image, draft: true)
                    refreshMask()
                } else {
                    await after(r.image)
                }
            case .liveStroke(let pts, let pressure, let connect):
                guard let mid = selectedMask else { break }
                let (w, h) = viewport
                loupe.held = key
                let params = strokeParams(mid, pts, pressure, connect: connect)
                let r = try await engine.batch { e -> Rendered in
                    _ = try e.execNow("mask.brushStroke", params)
                    return try e.renderNow(photo, w, h, draft: true)
                }
                show(r.image, draft: true)
                refreshMask()
            case .edit(let commands, _):
                let (w, h) = viewport
                let draft = interacting
                let wasHeld = held
                if !wasHeld { await lock.lock() }
                loupe.held = key
                do {
                    let r = try await engine.batch { e -> Rendered in
                        _ = try e.execNow("library.select", ["ids": [photo], "active": photo])
                        for (name, params) in commands { _ = try e.execNow(name, params) }
                        return try e.renderNow(photo, w, h, draft: draft)
                    }
                    if !wasHeld { await lock.unlock() }
                    if draft {
                        show(r.image, draft: true)
                        await loadState()
                        refreshMask()
                    } else {
                        await after(r.image)
                    }
                } catch {
                    if !wasHeld { await lock.unlock() }
                    throw error
                }
            case .stroke(let pts, let pressure):
                guard let mid = selectedMask else { break }
                await lock.lock()
                loupe.held = key
                let params = strokeParams(mid, pts, pressure, connect: false)
                do {
                    _ = try await engine.batch { e in
                        _ = try e.execNow("library.select", ["ids": [photo], "active": photo])
                        _ = try e.execNow("mask.brushStroke", params)
                    }
                } catch {
                    await lock.unlock()
                    throw error
                }
                await lock.unlock()
                await after(nil)
            case .quiet(let name, let params, _):
                await lock.lock()
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
                await loadHistory()
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

    /// A brush stroke's parameters: the brush as set, into the component being edited.
    private func strokeParams(_ mid: Int, _ pts: [CGPoint], _ pressure: [Float], connect: Bool) -> [String: Any] {
        var params: [String: Any] = [
            "id": mid, "points": pts.map { [Double($0.x), Double($0.y)] }, "size": brushSize,
            "feather": brushFeather, "flow": brushFlow, "density": brushDensity, "erase": erasing, "autoMask": autoMask, "connect": connect,
        ]
        if let k = partIndex(mid), masks.first(where: { $0.id == mid })?.part(k)?.kind == "brush" { params["component"] = k }
        if pressure.contains(where: { $0 < 0.999 }) { params["pressure"] = pressure.map { Double($0) } }
        return params
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
        await loadState()
        await loadHistory()
        refreshMask()
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
        if cs != curves {
            curves = cs
            curvesVersion += 1
        }
        update(\.bw, (d["treatment"] as? String) == "bw")
        update(\.wbMode, (d["wb"] as? [String: Any])?.str("mode") ?? "asShot")
        update(\.profile, (d["profile"] as? [String: Any])?.str("id") ?? "")
        let optics = d["optics"] as? [String: Any] ?? [:]
        update(\.lensProfile, (optics["lens_profile"] as? Bool) ?? false)
        update(\.removeCA, (optics["remove_ca"] as? Bool) ?? false)
        update(\.upright, (d["geometry"] as? [String: Any])?.str("upright") ?? "off")
        update(\.constrainCrop, ((d["geometry"] as? [String: Any])?["constrain_crop"] as? Bool) ?? false)
        update(\.vignetteStyle, (d["vignette"] as? [String: Any])?.str("style") ?? "highlightPriority")
        let aspect = (d["crop"] as? [String: Any])?["aspect"]
        if let a = aspect as? String {
            update(\.cropAspect, a)
        } else if let wh = aspect as? [Any], wh.count == 2 {
            // a locked shape (500 × 400): its lowest terms (5 × 4)
            var a = Int(double(wh[0])), b = Int(double(wh[1]))
            var x = a, y = b
            while y != 0 { (x, y) = (y, x % y) }
            if x > 0 { a /= x; b /= x }
            update(\.cropAspect, "\(a)x\(b)")
        } else {
            update(\.cropAspect, "")
        }
        update(\.disabled, Set((d["disabled_sections"] as? [Any] ?? []).compactMap { $0 as? String }))
        applyState(d)
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
        update(\.history, list)
        update(\.cursor, c)
        update(\.canUndo, c > 0)
        update(\.canRedo, c < n - 1)
    }

    /// A published value set only when it changes: every set redraws the whole tool column, and a
    /// switch or a slider animating meanwhile would stutter.
    private func update<T: Equatable>(_ kp: ReferenceWritableKeyPath<EditorModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
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
        let shutter = pick(["Exposure Time", "ExposureTime"])
        let fnum = pick(["F-Number", "FNumber", "F Number"])
        let iso = pick(["ISO Speed", "ISO", "ISOSpeedRatings", "PhotographicSensitivity", "ISO Speed Ratings"])
        let focal = pick(["Focal Length", "FocalLength"])
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
