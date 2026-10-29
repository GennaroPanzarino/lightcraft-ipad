import CoreGraphics
import Foundation

/// A picture of a shot as the engine rendered it, for a box of `boxW × boxH`.
struct Pic {
    let key: String
    let photo: Int64
    let revision: Int
    let boxW: Int
    let boxH: Int
    let image: CGImage
    let draft: Bool
    /// Already through the editor's own processing (the lens blur).
    var filtered = false
}

/// The viewer's pictures: the shot on screen rendered for the screen (its neighbours after it), the
/// last few kept so going back is instant. A shot whose look changed keeps its last picture until
/// the new one is there: the raw takes the place of its preview without a flicker. Pictures go to the
/// viewer directly (no SwiftUI on the way): a slider drag redraws the photo and nothing else.
@MainActor
final class Loupe {
    struct Want: Equatable {
        let key: String
        let photo: Int64
        let revision: Int
        let w: Int
        let h: Int
    }

    private(set) var pics: [String: Pic] = [:]
    private let engine: Engine
    private var wants: [Want] = []
    private var failed = Set<String>()
    private var order: [String] = []
    private var working = false
    /// A shot's preview is on its way: a picture that only improves on one shown waits.
    var previewDue: () -> Bool = { false }
    /// A finished picture (its thumbnail is cut from it).
    var onPicture: ((Pic) -> Void)?
    /// The shot the viewer shows, and where its pictures go.
    var viewerKey: String?
    var onViewer: ((Pic) -> Void)?
    /// The shot the editor is changing: its pictures come from the editor until it is done.
    var held: String?
    /// The editor takes a picture over (it shows it once processed): true when it does.
    var intercept: ((Pic) -> Bool)?
    /// The app is out of sight: nothing is rendered (the GPU is not the app's then, and memory is
    /// short) until it is back.
    var paused = false
    static let keep = 6

    init(engine: Engine) { self.engine = engine }

    func show(_ list: [Want]) {
        wants = list
        pump()
    }

    func put(_ p: Pic) {
        let taken = !p.filtered && (intercept?(p) ?? false)
        pics[p.key] = p
        order.removeAll { $0 == p.key }
        order.append(p.key)
        while order.count > Loupe.keep { pics[order.removeFirst()] = nil }
        if taken { return }
        if p.key == viewerKey { onViewer?(p) }
        if !p.draft { onPicture?(p) }
    }

    func forget(_ key: String) { pics[key] = nil }

    /// Only the shot on screen kept (memory is short).
    func trim() {
        for k in Array(pics.keys) where k != viewerKey { pics[k] = nil }
        order = order.filter { $0 == viewerKey }
    }

    private func tag(_ w: Want) -> String { "\(w.key)/\(w.photo)/\(w.revision)/\(w.w)x\(w.h)" }

    private func satisfied(_ w: Want) -> Bool {
        if w.photo == 0 || failed.contains(tag(w)) { return true }
        guard let have = pics[w.key] else { return false }
        return have.photo == w.photo && have.revision == w.revision && !have.draft && have.boxW >= w.w && have.boxH >= w.h
    }

    /// A picture that only improves on one already shown (the raw after its preview) is for the shot
    /// on screen, and waits while the next shot's preview is coming.
    private func wanted(_ i: Int, _ w: Want) -> Bool {
        if w.key == held || satisfied(w) { return false }
        let shown = pics[w.key] != nil
        return !(shown && (previewDue() || i > 0))
    }

    func pump() {
        guard !working, !paused, let next = wants.enumerated().first(where: { wanted($0.offset, $0.element) })?.element else { return }
        working = true
        Task {
            do {
                let r = try await engine.render(next.photo, next.w, next.h)
                put(Pic(key: next.key, photo: next.photo, revision: next.revision, boxW: next.w, boxH: next.h, image: r.image, draft: false))
            } catch {
                failed.insert(tag(next))
            }
            working = false
            pump()
        }
    }
}
