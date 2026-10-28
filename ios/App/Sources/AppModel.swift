import Photos
import SwiftUI

enum Screen { case connect, workspace, browser }

struct ExportState {
    let total: Int
    var done = 0
    var saved = 0
    var finished = false
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
    @Published private(set) var renderer = ""

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
        screen = s.login.complete ? .workspace : .connect
        library = Library(engine: engine, previews: previews)
        loupe = Loupe(engine: engine)
        editor = EditorModel(engine: engine, loupe: loupe, library: library)
        if UserDefaults.standard.string(forKey: "screen") == "browser" { screen = .browser }
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
            await syncPreviews()
            await library.restore()
            ready = true
            if current == nil { current = library.shots.last?.key }
            if UserDefaults.standard.bool(forKey: "benchmark") { Task { await benchmark() } }
        } catch {
            problem = error.localizedDescription
        }
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
        screen = .workspace
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

    /// The shots as JPEGs, with their edits: into Photos, or to the share sheet (Files, AirDrop…).
    func exportShots(_ keys: Set<String>, quality: Int, edge: Int, toPhotos: Bool) {
        let list = library.shots.filter { keys.contains($0.key) && $0.photo != 0 }
        guard !list.isEmpty, export?.finished != false else { return }
        settings.exportQuality = quality
        settings.exportEdge = edge
        export = ExportState(total: list.count)
        Task {
            if toPhotos {
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    export = ExportState(total: list.count, done: list.count, saved: 0, finished: true)
                    say("Consenti l'accesso a Foto nelle Impostazioni dell'iPad")
                    return
                }
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            var saved = 0
            var files: [URL] = []
            for (i, s) in list.enumerated() {
                export?.done = i
                let url = tmp.appendingPathComponent("\(s.key).jpg")
                do {
                    try await engine.exportJpeg(s.photo, to: url, quality: quality, longEdge: edge)
                    if toPhotos {
                        try await PHPhotoLibrary.shared().performChanges {
                            let req = PHAssetCreationRequest.forAsset()
                            let opts = PHAssetResourceCreationOptions()
                            opts.originalFilename = "\(s.key).jpg"
                            req.addResource(with: .photo, fileURL: url, options: opts)
                        }
                        try? FileManager.default.removeItem(at: url)
                    } else {
                        files.append(url)
                    }
                    saved += 1
                } catch {
                    NSLog("lightcraft export \(s.key): \(error)")
                }
            }
            export = ExportState(total: list.count, done: list.count, saved: saved, finished: true)
            if !toPhotos && !files.isEmpty { Share.present(files) }
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
