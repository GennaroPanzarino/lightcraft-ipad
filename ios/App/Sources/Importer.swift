import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Photos brought in without the camera: from the Photos library (the originals, RAW and ProRAW
/// included), from Files (single files or whole folders, iCloud Drive's downloaded on the way), or
/// dropped on the library from another app. Each is copied into the app first (the library keeps
/// developing it from there, whatever happens to the original), then imported one after another.
enum Importer {
    /// The image files LightCraft opens, by extension.
    static let extensions: Set<String> = [
        "arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf", "rw2", "rwl", "pef", "dng", "3fr", "fff", "iiq", "erf", "mef",
        "mos", "mrw", "x3f", "srw", "kdc", "dcr", "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "hif", "avif", "webp",
    ]

    /// Where copies live.
    static var folder: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A free name in the folder for `name` (a second "IMG_0001" becomes "IMG_0001-2"; `taken`: a
    /// name a shot has already).
    static func destination(for name: String, taken: (String) -> Bool = { _ in false }) -> URL {
        let base = (name as NSString).deletingPathExtension.isEmpty ? "Foto" : (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "jpg" : (name as NSString).pathExtension
        var n = 1
        while true {
            let stemName = n == 1 ? base : "\(base)-\(n)"
            let url = folder.appendingPathComponent("\(stemName).\(ext)")
            if !FileManager.default.fileExists(atPath: url.path) && !taken(stemName) { return url }
            n += 1
        }
    }

    /// The image files a picked URL holds (a folder: every image in it, its subfolders included).
    static func files(in url: URL) -> [URL] {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) else { return [url] }
        guard dir.boolValue else { return [url] }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var out: [URL] = []
        while let f = e?.nextObject() as? URL {
            if extensions.contains(f.pathExtension.lowercased()) { out.append(f) }
        }
        return out.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The formats LightCraft's engine doesn't open quickly: the iPad's and iPhone's HEIC (and HEIF),
    /// decoded by the iPad's own hardware into a file it does.
    static let converted: Set<String> = ["heic", "heif", "hif"]

    /// A photo the engine can't open quickly made into one it can, in place: 8 bits a channel (a
    /// phone's photo) into a JPEG at 98 %, deeper ones (a camera's 10-bit HEIF) into a 16-bit PNG;
    /// the colour profile, the capture data (EXIF, GPS) and the orientation kept. The original copy
    /// goes. Anything else (or a failure) is left as it is.
    static func convertIfNeeded(_ url: URL) -> URL {
        guard converted.contains(url.pathExtension.lowercased()),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return url }
        let deep = ((props[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8) > 8
        let out = destination(for: url.deletingPathExtension().lastPathComponent + (deep ? ".png" : ".jpg"))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, (deep ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return url }
        props[kCGImageDestinationLossyCompressionQuality] = 0.98
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            return url
        }
        try? FileManager.default.removeItem(at: url)
        return out
    }

    /// `src` copied to `dst`, through a file coordinator (a file of iCloud Drive comes down first).
    static func copy(_ src: URL, to dst: URL) -> Bool {
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [.withoutChanges], error: &err) { u in
            ok = (try? FileManager.default.copyItem(at: u, to: dst)) != nil
        }
        return ok && err == nil
    }

    /// The best file an item from Photos or a drop has: its raw (a camera's RAW, ProRAW) when it
    /// has one, else the original image, copied out while it exists (the system deletes it after).
    static func file(from provider: NSItemProvider) async -> URL? {
        let types = [UTType.rawImage, UTType.heic, UTType.jpeg, UTType.png, UTType.tiff, UTType.image]
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { return nil }
        let suggested = provider.suggestedName
        return await withCheckedContinuation { c in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url = url else { c.resume(returning: nil); return }
                var name = url.lastPathComponent
                if let s = suggested, !s.isEmpty {
                    name = (s as NSString).pathExtension.isEmpty ? "\(s).\(url.pathExtension)" : s
                }
                let dst = destination(for: name)
                c.resume(returning: (try? FileManager.default.copyItem(at: url, to: dst)) != nil ? dst : nil)
            }
        }
    }
}

extension AppModel {
    /// Photos from Files (security-scoped URLs: files or folders).
    func importFiles(_ urls: [URL]) {
        Task {
            var copies: [URL] = []
            importing = (0, max(1, urls.count))
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                let list = await Task.detached(priority: .userInitiated) { Importer.files(in: u) }.value
                for f in list {
                    let dst = Importer.destination(for: f.lastPathComponent)
                    if await Task.detached(priority: .userInitiated, operation: { Importer.copy(f, to: dst) }).value { copies.append(dst) }
                }
                if scoped { u.stopAccessingSecurityScopedResource() }
            }
            await importCopies(copies, failed: 0)
        }
    }

    /// Photos picked in Photos, or dropped on the library.
    func importItems(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        Task {
            importing = (0, providers.count)
            var copies: [URL] = []
            var failed = 0
            for p in providers {
                if let u = await Importer.file(from: p) { copies.append(u) } else { failed += 1 }
            }
            await importCopies(copies, failed: failed)
        }
    }

    /// The copies into the library, one after another, the count on screen.
    private func importCopies(_ copies: [URL], failed: Int) async {
        var done = 0, bad = failed
        importing = (0, max(1, copies.count))
        var first: String?
        for c in copies {
            // a HEIC made into a JPEG first (the iPad decodes it in an instant, the engine wouldn't)
            let u = await Task.detached(priority: .userInitiated) { Importer.convertIfNeeded(c) }.value
            if let k = await library.importPhoto(u) {
                first = first ?? k
                done += 1
            } else {
                bad += 1
                try? FileManager.default.removeItem(at: u)
            }
            importing = (done + bad - failed, copies.count)
        }
        importing = nil
        if current == nil, let k = first { current = k }
        if done == 0 && bad == 0 {
            say("Nessuna foto da importare")
        } else {
            say(bad == 0 ? (done == 1 ? "1 foto importata" : "\(done) foto importate") : "\(done) importate, \(bad) non leggibili")
        }
    }
}

/// Photos's own picker (no permission needed: the user picks, the app gets only those), for the
/// originals, several at a time.
struct PhotoPicker: UIViewControllerRepresentable {
    let done: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var c = PHPickerConfiguration(photoLibrary: .shared())
        c.filter = .images
        c.selectionLimit = 0
        // the original files, not a compatible JPEG made for the app
        c.preferredAssetRepresentationMode = .current
        c.selection = .ordered
        let p = PHPickerViewController(configuration: c)
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let done: ([NSItemProvider]) -> Void
        init(_ done: @escaping ([NSItemProvider]) -> Void) { self.done = done }

        /// (the sheet showing the picker closes it: dismissing it here would leave the sheet's
        /// state open, and the picker could not come back)
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            done(results.map(\.itemProvider))
        }
    }
}

/// Import: from Photos or from Files, as a menu (the library's bar) or two buttons (an empty
/// library).
struct ImportMenu: View {
    @EnvironmentObject var model: AppModel
    var big = false
    @State private var photos = false
    @State private var files = false

    var body: some View {
        Group {
            if big {
                HStack(spacing: 10) {
                    FlatButton(title: "Importa da Foto", icon: "photo.on.rectangle", prominent: true) { photos = true }
                    FlatButton(title: "Importa da File", icon: "folder") { files = true }
                }
                .frame(width: 380)
            } else {
                Menu {
                    Button { photos = true } label: { Label("Dalla libreria Foto", systemImage: "photo.on.rectangle") }
                    Button { files = true } label: { Label("Da File", systemImage: "folder") }
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 16))
                        .foregroundColor(Lc.text)
                        .frame(width: 38, height: 32)
                        .background(Lc.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
        .sheet(isPresented: $photos) {
            PhotoPicker { providers in
                photos = false
                model.importItems(providers)
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.image, .rawImage, .folder], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { model.importFiles(urls) }
        }
    }
}
