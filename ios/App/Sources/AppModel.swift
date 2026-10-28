import Combine
import Photos
import SwiftUI

enum Screen { case connect, session, editor, library }

struct ExportState {
    let total: Int
    var done = 0
    var saved = 0
    var finished = false
}

/// Everything the app holds: settings, the two LightCraft engines, the shots, the viewer, the editor
/// and the camera link.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings { didSet { settings.save() } }
    @Published var screen: Screen
    @Published var current: String?
    @Published var selection = Set<String>()
    @Published private(set) var ready = false
    @Published private(set) var problem: String?
    @Published private(set) var controls: [String: Control] = [:]
    @Published private(set) var presets: [Preset] = []
    @Published var export: ExportState?
    @Published var note: String?
    /// Modifica touched before the raw was in: the editor opens when it is.
    @Published var pendingEdit: String?
    @Published var variants: [String: CGImage] = [:]

    let library: Library
    let loupe: Loupe
    let editor: EditorModel
    let tether = TetherLink()
    private let engine: Engine
    private let previews: Engine
    private let shotsDir: URL
    private var bag = Set<AnyCancellable>()
    private var noteTask: Task<Void, Never>?
    private var variantsTask: Task<Void, Never>?

    init() {
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let previewsDir = docs.appendingPathComponent("previews")
        try? FileManager.default.removeItem(at: previewsDir)
        engine = Engine(dir: docs.appendingPathComponent("library"), nice: 4)
        previews = Engine(dir: previewsDir.appendingPathComponent("library"), previews: true, maxEdge: 2560)
        shotsDir = docs.appendingPathComponent("shots")
        let s = Settings.load()
        settings = s
        screen = s.login.complete ? .session : .connect
        library = Library(engine: engine, previews: previews)
        loupe = Loupe(engine: engine)
        editor = EditorModel(engine: engine, loupe: loupe, library: library)
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
        loupe.previewDue = { [weak self] in
            guard let t = self?.tether.transfer else { return false }
            return t.name.lowercased().hasSuffix(".arw") && (self?.library.shot(stem(t.name))?.stage ?? .arriving) == .arriving
        }
        loupe.onPicture = { [weak self] p in self?.library.developed(p.key, photo: p.photo, p.image) }
        editor.onEdited = { [weak self] key in self?.library.edited(key) }
        editor.presetsChanged = { [weak self] in await self?.presetsChanged() }
        tether.onEvent = { [weak self] e in
            guard let self = self else { return }
            if e.str("type") == "fingerprint" {
                self.settings.login.fingerprint = e.str("value")
            } else {
                self.library.handle(e)
            }
            self.loupe.pump()
        }
        // the views follow the library and the link
        library.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        tether.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        loupe.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    private func boot() async {
        do {
            try await engine.open()
            try await previews.open()
            _ = try? await engine.exec("app.memoryBudget", ["mb": 1536])
            controls = Controls.from(try await engine.array("develop.controls"))
            presets = try await presetsOf(engine)
            await syncPreviews()
            await library.restore()
            ready = true
            if current == nil { current = library.shots.last?.key }
        } catch {
            problem = error.localizedDescription
        }
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
        screen = .session
        connect()
    }

    func setRaw(_ raw: Bool) {
        settings.raw = raw
        tether.setRaw(raw)
    }

    private func arrived(_ key: String) {
        // tests (`-autoEdit YES`): the editor opens on the first shot whose raw is in
        if UserDefaults.standard.bool(forKey: "autoEdit"), screen == .session {
            Task {
                for _ in 0..<1200 {
                    if let p = library.shot(key)?.photo, p != 0 { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if screen == .session { openEditor(key) }
            }
        }
        guard settings.followNewest, screen == .session else { return }
        Task {
            // go to it once its full picture is ready (rendered ahead as the next page), 2 s at most
            for _ in 0..<40 {
                if loupe.pics[key] != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            withAnimation(Motion.soft) { current = key }
        }
    }

    // ---- the editor

    func openEditor(_ key: String) {
        guard let s = library.shot(key) else { return }
        current = key
        if s.photo == 0 {
            pendingEdit = key
            Task {
                for _ in 0..<2400 {
                    if pendingEdit != key { return }
                    if let p = library.shot(key)?.photo, p != 0 { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if pendingEdit == key, screen == .session { pendingEdit = nil; openEditor(key) } else if pendingEdit == key { pendingEdit = nil }
            }
            return
        }
        pendingEdit = nil
        loupe.show([])
        editor.open(key)
        withAnimation(Motion.soft) { screen = .editor }
    }

    func go(_ s: Screen) {
        if screen == .editor && s != .editor { editor.close() }
        withAnimation(Motion.soft) { screen = s }
    }

    func say(_ text: String) {
        note = text
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if !Task.isCancelled { note = nil }
        }
    }

    // ---- presets

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
                if n == 0 { say("Nessun preset trovato nei file"); return }
                await presetsChanged()
                say(n == 1 ? "1 preset importato" : "\(n) preset importati")
            } catch {
                say("Importazione non riuscita: \(error.localizedDescription)")
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

    /// The preset every new shot gets ("" = none); `alsoTo`: the shot on screen gets it now too.
    func setTetherPreset(_ id: String, amount: Int, alsoTo key: String?) {
        settings.preset = id
        settings.presetAmount = amount
        guard let key = key, let s = library.shot(key), s.photo != 0, !id.isEmpty else { return }
        Task {
            await library.editLock.lock()
            _ = try? await engine.exec("preset.apply", ["id": id, "amount": amount, "ids": [s.photo]])
            await library.editLock.unlock()
            library.edited(key)
        }
    }

    /// Thumbnails of a photo with each preset (the tether preset sheet).
    func loadVariants(photo: Int64) {
        variantsTask?.cancel()
        variants = [:]
        guard photo != 0 else { return }
        let ids = presets.map(\.id)
        variantsTask = Task {
            for id in [""] + ids {
                if Task.isCancelled { break }
                if let r = try? await engine.variant(photo, preset: id) { variants[id] = r.image }
            }
        }
    }

    // ---- selection, export, delete

    func toggle(_ key: String) {
        if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
    }

    /// The selected shots to the Photos library as JPEGs, with their edits.
    func exportSelected(quality: Int, edge: Int) {
        let list = library.shots.filter { selection.contains($0.key) && $0.photo != 0 }
        guard !list.isEmpty, export?.finished != false else { return }
        settings.exportQuality = quality
        settings.exportEdge = edge
        export = ExportState(total: list.count)
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                export = ExportState(total: list.count, done: list.count, saved: 0, finished: true)
                say("Consenti l'accesso a Foto nelle Impostazioni dell'iPad")
                return
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("export")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            var saved = 0
            for (i, s) in list.enumerated() {
                export?.done = i
                let url = tmp.appendingPathComponent("\(s.key).jpg")
                do {
                    try await engine.exportJpeg(s.photo, to: url, quality: quality, longEdge: edge)
                    try await PHPhotoLibrary.shared().performChanges {
                        let req = PHAssetCreationRequest.forAsset()
                        let opts = PHAssetResourceCreationOptions()
                        opts.originalFilename = "\(s.key).jpg"
                        req.addResource(with: .photo, fileURL: url, options: opts)
                    }
                    saved += 1
                } catch {
                    NSLog("lightcraft export \(s.key): \(error)")
                }
                try? FileManager.default.removeItem(at: url)
            }
            export = ExportState(total: list.count, done: list.count, saved: saved, finished: true)
        }
    }

    func deleteSelected() {
        let keys = selection
        Task {
            keys.forEach { loupe.forget($0) }
            await library.remove(keys)
            selection = []
        }
    }
}
